"""Check routed clock-domain crossing paths. --self-test checks this parser only.

The fixture mode never writes build/cdc_route_audit/acceptance.json and never
checks routing or timing. A real check reads
the native endpoint list and every exact-net report.
"""
from pathlib import Path
import argparse
import csv
import hashlib
import io
import json
import math
import os
import re
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SPECS = (("u_catalog", 6, 40.0), ("u_command", 4, 10.0),
         ("u_cfg_mailbox", 52, 40.0))
CFG_ZERO_BITS = frozenset((24, 25, 30, 31, 36, 37, 42, 43, 48, 49))
CONSTANT_CONTRACT = "cfg-HOLD-seconds-1-to-9-high2-zero"
MANIFEST_FIELDS = ("instance", "bit", "source_count", "target_count",
                   "disposition", "constant_value", "contract")
CONTROLS = (
    ("cfg_req_first", "u_cfg_mailbox/req_toggle", "u_cfg_mailbox/req_meta", 40.0, False),
    ("cfg_ack_first", "u_cfg_mailbox/ack_toggle", "u_cfg_mailbox/ack_meta", 10.0, False),
    ("cfg_applied_first", "cfg_ready_pix", "cfg_applied_sd_meta", 10.0, False),
    ("cfg_req_second", "u_cfg_mailbox/req_meta", "u_cfg_mailbox/req_sync", 40.0, True),
    ("cfg_ack_second", "u_cfg_mailbox/ack_meta", "u_cfg_mailbox/ack_sync", 10.0, True),
    ("cfg_applied_second", "cfg_applied_sd_meta", "cfg_applied_sd", 10.0, True),
)
NUM = r"(-?\d+(?:\.\d+)?)"


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check_report(path, source, target, limit, budget, ordinary_hold, errors):
    """Require exactly one setup and, when ordinary, one nonnegative hold."""
    if not path.is_file():
        errors.append(f"Missing report: {path.name}")
        return None
    content = path.read_text(encoding="utf-8-sig", errors="replace")
    blocks = re.split(r"(?m)^Slack\s+:\s+", content)[1:]
    values = {}
    for kind in (("setup", "hold") if ordinary_hold else ("setup",)):
        selected = [b for b in blocks if re.search(
            rf"(?m)^Check Type\s+:\s+{kind}\s*$", b)]
        if len(selected) != 1:
            errors.append(f"Expected exactly one {kind} path: {path.name}")
            continue
        block = selected[0]
        fields = {
            "slack_ns": re.match(NUM + r"ns", block),
            "data_delay_ns": re.search(r"(?m)^Data Path Delay\s+:\s+" + NUM + r"ns", block),
            "reported_budget_ns": re.search(r"(?m)^Budget\s+:\s+" + NUM + r"ns", block),
        }
        if any(match is None for match in fields.values()):
            errors.append(f"Incomplete {kind} report: {path.name}")
            continue
        parsed = {name: float(match.group(1)) for name, match in fields.items()}
        if any(not math.isfinite(v) for v in parsed.values()):
            errors.append(f"Nonfinite {kind} report: {path.name}")
            continue
        for net in (source, target):
            if f"net: {net}," not in block:
                errors.append(f"Logical {kind} net mapping failed: {path.name}: {net}")
        expected_budget = budget if kind == "setup" else 0.0
        if (parsed["slack_ns"] < 0 or parsed["data_delay_ns"] < 0
                or abs(parsed["reported_budget_ns"] - expected_budget) > 0.001
                or (kind == "setup" and parsed["data_delay_ns"] >= limit)):
            errors.append(f"{kind} budget/slack failed: {path.name}")
        values[kind] = parsed
    return {"report": path.name, "sha256": sha256(path),
            "source_net": source, "target_net": target,
            "propagation_limit_ns": limit, "checks": values}


def check_sdc_policy(path, errors):
    """These three precise first-stage exceptions must not expand silently."""
    if not path.is_file():
        errors.append("Missing SDC input")
        return
    lines = [line.strip() for line in path.read_text(encoding="utf-8-sig").splitlines()
             if line.strip() and not line.lstrip().startswith("#")]
    cfg_lines = [line for line in lines if any(name in line for name in
                 ("u_cfg_mailbox", "cfg_ready_pix", "cfg_applied_sd"))]
    expected = []
    for _, source, target, limit, _ in CONTROLS[:3]:
        expected.append(f"set_max_delay {limit:.3f} -datapath_only -from "
                        + "[get_regs -regexp {^" + source + "$}] -to "
                        + "[get_regs -regexp {^" + target + "$}]")
    if sorted(cfg_lines) != sorted(expected):
        errors.append("CFG SDC policy changed: only the three exact first stages are allowed")


def audit(reports, route_db, sdc, *, report_origin="routed_native_reports"):
    errors, rows, pruned, controls = [], [], [], []
    expected = {(instance, bit): limit for instance, width, limit in SPECS
                for bit in range(width)}
    manifest = reports / "endpoint_manifest.tsv"
    entries = {}
    if not manifest.is_file():
        errors.append("Missing native endpoint manifest")
    else:
        reader = csv.DictReader(io.StringIO(manifest.read_text(encoding="utf-8-sig")), delimiter="\t")
        if tuple(reader.fieldnames or ()) != MANIFEST_FIELDS:
            errors.append("Native endpoint manifest header changed")
        for row in reader:
            try:
                key = (row["instance"], int(row["bit"]))
                counts = (int(row["source_count"]), int(row["target_count"]))
            except (KeyError, TypeError, ValueError):
                errors.append("Malformed native endpoint row")
                continue
            if key in entries:
                errors.append(f"Duplicate native endpoint row: {key}")
            if key not in expected:
                errors.append(f"Unexpected native endpoint row: {key}")
            entries[key] = (row, counts)
        if set(entries) != set(expected):
            errors.append(f"Native endpoint manifest must cover all 62 bits; missing={sorted(set(expected)-set(entries))}")
    for (instance, bit), limit in expected.items():
        if (instance, bit) not in entries:
            continue
        row, counts = entries[(instance, bit)]
        path = reports / f"{instance}_bit{bit}.rpt"
        if row["disposition"] == "constant-zero-pruned":
            if (instance != "u_cfg_mailbox" or bit not in CFG_ZERO_BITS
                    or counts != (0, 0) or row["constant_value"] != "0"
                    or row["contract"] != CONSTANT_CONTRACT):
                errors.append(f"Illegal constant pruning: {instance} bit={bit}")
            elif path.exists():
                errors.append(f"Pruned bit has conflicting/stale report: {path.name}")
            else:
                pruned.append({"instance": instance, "bit": bit, "source_count": 0,
                               "target_count": 0, "value": 0, "contract": CONSTANT_CONTRACT,
                               "basis": "native get_regs found neither endpoint"})
            continue
        if (row["disposition"] != "routed" or counts != (1, 1)
                or row["constant_value"] != "-" or row["contract"] != "ordinary-setup-hold"):
            errors.append(f"Invalid routed endpoint counts/disposition: {instance} bit={bit}")
            continue
        result = check_report(path, f"{instance}/payload[{bit}]",
                              f"{instance}/dst_data[{bit}]", limit, 10.0, True, errors)
        if result is not None:
            rows.append({"instance": instance, "bit": bit, **result})
    for label, source, target, budget, hold in CONTROLS:
        result = check_report(reports / f"{label}.rpt", source, target, budget, budget, hold, errors)
        if result is not None:
            controls.append({"label": label, "ordinary_setup_hold": hold, **result})
    check_sdc_policy(sdc, errors)
    if not route_db.is_file():
        errors.append("Missing current routed database")
    if len(rows) + len(pruned) != 62 or not 52 <= len(rows) <= 62 or len(controls) != 6:
        errors.append(f"Incomplete audited coverage: routed={len(rows)} pruned={len(pruned)} controls={len(controls)}")
    checks_pass = not errors
    native = report_origin == "routed_native_reports"
    return {
        "kind": "routed_mailbox_propagation_audit" if native else "synthetic_cdc_parser_fixture",
        "report_origin": report_origin, "checks_pass": checks_pass,
        "expected_logical_bits": 62, "cfg_logical_bits": 52, "cfg_required_routed_bits": 42,
        "expected_bits": 62, "verified_bits": len(rows), "constant_pruned_bits": len(pruned),
        "propagation_limits_pass": native and checks_pass,
        "ordinary_setup_pass": native and checks_pass, "ordinary_hold_pass": native and checks_pass,
        "sdc_policy": "ordinary_setup_hold_no_catalog_command_cfg_payload_exception",
        "exception_label_check": "exact_first_stages_only_payload_and_second_stages_ordinary",
        "route_db_sha256": sha256(route_db) if route_db.is_file() else None,
        "sdc_sha256": sha256(sdc) if sdc.is_file() else None,
        "endpoint_manifest_sha256": sha256(manifest) if manifest.is_file() else None,
        "global_timing_closure_verified": False, "hardware_verified": False,
        "rows": rows, "pruned": pruned, "control_rows": controls, "errors": errors,
    }


def self_test(output=None):
    """Parser self-test."""
    outcomes = []
    def report(source, target, budget=10.0, hold=True):
        def block(kind, b):
            return (f"Slack               : 1.000ns\nCheck Type          : {kind}\n"
                    f"Budget              : {b:.3f}ns\nData Path Delay     : 1.000ns\n"
                    f"net: {source}, fixture\nnet: {target}, fixture\n")
        return block("setup", budget) + (block("hold", 0.0) if hold else "")
    def fixture(base, prune):
        base.mkdir(parents=True)
        entries = []
        for instance, width, _ in SPECS:
            for bit in range(width):
                gone = instance == "u_cfg_mailbox" and bit in prune
                entries.append(dict(zip(MANIFEST_FIELDS,
                    (instance, bit, 0 if gone else 1, 0 if gone else 1,
                     "constant-zero-pruned" if gone else "routed", "0" if gone else "-",
                     CONSTANT_CONTRACT if gone else "ordinary-setup-hold"))))
                if not gone:
                    (base / f"{instance}_bit{bit}.rpt").write_text(report(
                        f"{instance}/payload[{bit}]", f"{instance}/dst_data[{bit}]"), encoding="utf-8")
        write_manifest(base, entries)
        for label, source, target, budget, hold in CONTROLS:
            (base / f"{label}.rpt").write_text(report(source, target, budget, hold), encoding="utf-8")
        (base / "route.db").write_bytes(b"SYNTHETIC FIXTURE - NOT A ROUTED TD DATABASE")
        (base / "design.sdc").write_bytes((ROOT / "../source_code/adc_sdc/anxin_screen.sdc").read_bytes())
        return entries
    def write_manifest(base, entries):
        with (base / "endpoint_manifest.tsv").open("w", encoding="utf-8", newline="") as stream:
            writer = csv.DictWriter(stream, MANIFEST_FIELDS, delimiter="\t")
            writer.writeheader(); writer.writerows(entries)
    def mutate_text(base, filename, old, new):
        path = base / filename
        path.write_text(path.read_text().replace(old, new), encoding="utf-8")
    def test(name, action=None, *, prune=CFG_ZERO_BITS, accepted=False):
        with tempfile.TemporaryDirectory(prefix="anxin-cdc-fixture-") as temporary:
            base = Path(temporary) / "reports"
            entries = fixture(base, prune)
            if action:
                action(base, entries)
            result = audit(base, base / "route.db", base / "design.sdc",
                           report_origin="synthetic_parser_fixture")
            passed = result["checks_pass"] == accepted and not result["propagation_limits_pass"]
            outcomes.append({"name": name, "passed": passed,
                             "expected_parser_accept": accepted, "errors": result["errors"]})
            if not passed:
                raise AssertionError(f"Fixture failed: {name}: {result['errors']}")
    target = "u_cfg_mailbox_bit0.rpt"
    test("all_62_routed_bits", prune=frozenset(), accepted=True)
    test("all_10_allowed_high_bits_pruned_52_routed", accepted=True)
    test("mixed_high_bit_retention", prune=frozenset((24, 31)), accepted=True)
    test("missing_required_report", lambda b, e: (b / target).unlink())
    test("missing_manifest_bit", lambda b, e: write_manifest(b, e[:-1]))
    test("duplicate_manifest_bit", lambda b, e: write_manifest(b, e + [e[0]]))
    test("wrong_source_net", lambda b, e: mutate_text(b, target, "payload[0]", "payload[1]"))
    test("wrong_target_net", lambda b, e: mutate_text(b, target, "dst_data[0]", "dst_data[1]"))
    test("negative_setup", lambda b, e: mutate_text(b, target, "Slack               : 1.000ns", "Slack               : -0.001ns"))
    test("relaxed_payload_setup_budget", lambda b, e: mutate_text(b, target, "Budget              : 10.000ns", "Budget              : 40.000ns"))
    test("payload_hold_missing", lambda b, e: mutate_text(b, target, "Check Type          : hold", "Check Type          : suppressed"))
    test("payload_hold_budget_changed", lambda b, e: mutate_text(b, target, "Budget              : 0.000ns", "Budget              : 10.000ns"))
    test("propagation_equal_limit_rejected", lambda b, e: mutate_text(b, target, "Data Path Delay     : 1.000ns", "Data Path Delay     : 40.000ns"))
    test("catalog_original_gate_preserved", lambda b, e: (b / "u_catalog_bit5.rpt").unlink())
    test("command_original_10ns_limit_preserved", lambda b, e: mutate_text(b, "u_command_bit0.rpt", "Data Path Delay     : 1.000ns", "Data Path Delay     : 10.000ns"))
    def prune_required(base, entries):
        row = next(r for r in entries if r["instance"] == "u_cfg_mailbox" and r["bit"] == 0)
        row.update(source_count=0, target_count=0, disposition="constant-zero-pruned",
                   constant_value="0", contract=CONSTANT_CONTRACT)
        (base / target).unlink();write_manifest(base, entries)
    test("illegal_dynamic_bit_pruning", prune_required)
    def one_sided(base, entries):
        row = next(r for r in entries if r["instance"] == "u_cfg_mailbox" and r["bit"] == 24)
        row["target_count"] = 1;write_manifest(base, entries)
    test("one_sided_pruning", one_sided)
    test("stale_report_for_pruned_bit", lambda b, e: (b / "u_cfg_mailbox_bit24.rpt").write_text("stale", encoding="utf-8"))
    test("missing_first_stage_control", lambda b, e: (b / "cfg_req_first.rpt").unlink())
    test("first_stage_wrong_budget", lambda b, e: mutate_text(b, "cfg_ack_first.rpt", "Budget              : 10.000ns", "Budget              : 40.000ns"))
    test("second_stage_hold_missing", lambda b, e: mutate_text(b, "cfg_req_second.rpt", "Check Type          : hold", "Check Type          : suppressed"))
    test("second_stage_budget_relaxed", lambda b, e: mutate_text(b, "cfg_ack_second.rpt", "Budget              : 10.000ns", "Budget              : 40.000ns"))
    test("sdc_second_stage_exception_rejected", lambda b, e: (b / "design.sdc").write_text(
         (b / "design.sdc").read_text() + "\nset_false_path -to [get_regs {u_cfg_mailbox/req_sync}]\n", encoding="utf-8"))
    test("missing_route_db", lambda b, e: (b / "route.db").unlink())
    import tkinter
    tcl_source = ROOT / "scripts/check_cdc_route.tcl"
    for case in ("all62", "pruned10", "required_missing", "one_sided",
                 "negative_setup", "wrong_net", "relaxed_budget", "missing_hold",
                 "native_report_missing"):
        with tempfile.TemporaryDirectory(prefix="anxin-cdc-tcl-fixture-") as temporary:
            base = Path(temporary) / "build/cdc_route_audit"
            fixture(base, CFG_ZERO_BITS if case == "pruned10" else frozenset())
            tcl = tkinter.Tcl()
            def get_regs(*args):
                name = re.sub(r"\\(.)", r"\1", args[-1][1:-1])
                match = re.fullmatch(r"u_cfg_mailbox/(payload|dst_data)\[(\d+)\]", name)
                if match:
                    end, bit = match.group(1), int(match.group(2))
                    if ((case == "pruned10" and bit in CFG_ZERO_BITS)
                            or (case == "required_missing" and bit == 0)
                            or (case == "one_sided" and bit == 24 and end == "payload")):
                        return ""
                return name
            def report_timing_path(*args):
                options = dict(zip(args[::2], args[1::2]))
                path = Path(options["-file"])
                if case == "native_report_missing" and path.name == target:
                    return ""
                source, destination = options["-from"], options["-to"]
                spec = next((r for r in CONTROLS if r[0] == path.stem), None)
                budget, hold = (spec[3], spec[4]) if spec else (10.0, True)
                text = report(source, destination, budget, hold)
                if path.name == target:
                    if case == "negative_setup":
                        text = text.replace("Slack               : 1.000ns", "Slack               : -0.001ns")
                    if case == "wrong_net":
                        text = text.replace("payload[0]", "payload[1]")
                    if case == "relaxed_budget":
                        text = text.replace("Budget              : 10.000ns", "Budget              : 40.000ns")
                    if case == "missing_hold":
                        text = text.replace("Check Type          : hold", "Check Type          : suppressed")
                path.write_text(text, encoding="utf-8")
                return ""
            tcl.createcommand("get_regs", get_regs)
            tcl.createcommand("report_timing_path", report_timing_path)
            tcl.eval("rename puts __anxin_puts; proc puts {args} {if {[llength $args]>1} {__anxin_puts {*}$args}}")
            tcl.call("source", str(tcl_source))
            original_cwd = Path.cwd()
            failure = None
            try:
                os.chdir(temporary)
                tcl.call("anxin_check_routed_mailboxes")
            except tkinter.TclError as error:
                failure = str(error)
            finally:
                os.chdir(original_cwd)
            expected_accept = case in ("all62", "pruned10")
            passed = (failure is None) == expected_accept
            manifest_present = (base / "endpoint_manifest.tsv").is_file()
            passed = passed and manifest_present == expected_accept
            if expected_accept:
                result = audit(base, base / "route.db", base / "design.sdc",
                               report_origin="synthetic_parser_fixture")
                passed = passed and result["checks_pass"] and not result["propagation_limits_pass"]
            outcomes.append({"name": "actual_Tcl_with_mock_native_" + case,
                             "passed": passed, "expected_parser_accept": expected_accept,
                             "error": failure, "completed_manifest": manifest_present})
            if not passed:
                raise AssertionError(f"Tcl fixture failed: {case}: {failure}")
    summary = {"kind": "synthetic_cdc_parser_self_test", "passed": all(t["passed"] for t in outcomes),
               "cases": len(outcomes), "tests": outcomes, "script_sha256": sha256(Path(__file__)),
               "tcl_script_sha256": sha256(tcl_source),
               "routed_acceptance": False, "global_timing_closure_verified": False,
               "hardware_verified": False}
    if output:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"CDC_PARSER_FIXTURES_PASS cases={len(outcomes)} synthetic_only=True routed_acceptance=False")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--self-test-output", type=Path)
    args = parser.parse_args()
    if args.self_test:
        return self_test(args.self_test_output)
    if args.self_test_output:
        parser.error("--self-test-output requires --self-test")
    reports = ROOT / "build/cdc_route_audit"
    result = audit(reports, ROOT / "build/td/route.db", ROOT / "../source_code/adc_sdc/anxin_screen.sdc")
    reports.mkdir(parents=True, exist_ok=True)
    (reports / "acceptance.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"CDC_ROUTE_PROPAGATION_ACCEPTED={result['propagation_limits_pass']} "
          f"logical=62 routed={result['verified_bits']} pruned={result['constant_pruned_bits']}")
    print(f"CDC_MAILBOX_ORDINARY_SETUP_ACCEPTED={result['ordinary_setup_pass']}")
    print(f"CDC_MAILBOX_ORDINARY_HOLD_ACCEPTED={result['ordinary_hold_pass']}")
    for error in result["errors"]:
        print("FAIL " + error)
    return 0 if result["propagation_limits_pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
