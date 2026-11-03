"""Check a finished implementation: tool messages, routing checks and final timing."""
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

PRJ = Path(__file__).resolve().parents[1]
SDC = PRJ / "../source_code/adc_sdc/anxin_screen.sdc"
LOCATION = ("is not honored. Cell's initial location is not legal at the beginning of ECO "
            "placement, and will be moved during placement. Please verify user location "
            "constraints through the adc file.")
ALLOWED_SDRAM = {
    f"PHY-7002 CRITICAL-WARNING: Instance u_sdram/sdram location (12, 12) {LOCATION}",
    f"PHY-7002 CRITICAL-WARNING: Instance u_sdram/sdram location (164, 288) {LOCATION}",
    "PHY-5079 CRITICAL-WARNING: Marked 1 clock net(s) utilize the local routing resources. "
    "Please check log message and the sinks of clock nets.",
}
FAIL_LINE = re.compile(
    r"^(?:(?:CDC|SDRAM|PCM|TIMING|AUDIO|CONTROL)_[A-Z0-9_]*FAIL|"
    r"OBSERVER_RESET_(?:REG_COUNT|DRIVER_COUNT|DRIVER_MISMATCH|DUPLICATE_Q|HOST_MISMATCH|"
    r"SR_COUNT|SR_MISMATCH|CROSS_GROUP_SR|CHAIN_COUNT|TOTAL_COUNT)\b|"
    r"RESET_RELEASE_(?:GROUP_COUNT|SR_SHARED_FUNCTIONAL_Q)\b).*$", re.M)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def run_check(script, marker, console, errors):
    if marker not in console:
        errors.append(f"missing marker: {marker}")
        return None
    result = subprocess.run([sys.executable, str(PRJ / "scripts" / script)], cwd=PRJ,
                            capture_output=True, text=True)
    if result.returncode != 0:
        errors.append(f"{script} failed: {result.stdout[-400:]}{result.stderr[-400:]}")
        return None
    return True


def main():
    errors = []
    console = (PRJ / "build" / "console.log").read_text(encoding="utf-8", errors="replace")
    if "ANXIN_IMPLEMENTATION_COMPLETED_CHECK_TIMING_BEFORE_RELEASE" not in console:
        errors.append("implementation did not complete")
    if "AUDIO_PROFILE_BOUND HDMI_ONLY_V1 external_pcm5102=0" not in console:
        errors.append("unexpected audio profile")

    reviewed = "SDRAM_PHYSICAL_REVIEW_ACCEPTED" in console
    for line in re.findall(r"^.*\b(?:ERROR|FATAL|CRITICAL-WARNING)\s*:.*$", console, re.M):
        line = line.rstrip()
        if not (reviewed and line in ALLOWED_SDRAM):
            errors.append(line)
    errors += [m.group(0).rstrip() for m in FAIL_LINE.finditer(console)]

    route_db = PRJ / "build" / "td" / "route.db"
    if not route_db.exists():
        errors.append("missing routed database")
    else:
        route_hash, sdc_hash = sha256(route_db), sha256(SDC)
        if run_check("check_cdc_paths.py", "CDC_ROUTED_MAILBOX_GATE_ACCEPTED logical_bits=62 ", console, errors):
            r = json.loads((PRJ / "build/cdc_route_audit/acceptance.json").read_text(encoding="utf-8"))
            if not (r.get("report_origin") == "routed_native_reports" and r.get("propagation_limits_pass") is True
                    and r.get("ordinary_setup_pass") is True and r.get("ordinary_hold_pass") is True
                    and r.get("expected_logical_bits") == 62 and r.get("route_db_sha256", "").upper() == route_hash
                    and r.get("sdc_sha256", "").upper() == sdc_hash):
                errors.append("CDC path check not accepted")
        if run_check("check_control_cdc.py", "CONTROL_CDC_NATIVE_ACCEPTED bits=62 controls=9 ordinary_payload_budget=20ns",
                     console, errors):
            r = json.loads((PRJ / "build/control_cdc_audit/acceptance.json").read_text(encoding="utf-8"))
            if not (r.get("physical_gate_pass") is True and r.get("synthetic") is False
                    and r.get("logical_bits") == 62 and r.get("controls") == 9 and r.get("pruned_bits") == 0
                    and r.get("route_db_sha256", "").upper() == route_hash
                    and r.get("sdc_sha256", "").upper() == sdc_hash):
                errors.append("serial-control path check not accepted")
    marker = ("PCM_DISABLED_STATIC_OUTPUT_GATE_ACCEPTED outputs=3 external_dac=NOT_APPLICABLE_DISABLED "
              "no_serial_timing_claim")
    if len(re.findall(r"^" + re.escape(marker) + r"\r?$", console, re.M)) != 1:
        errors.append("missing PCM output check")

    status = PRJ / "build" / "td" / "final_status.rpt"
    setup = hold = None
    if status.exists():
        text = status.read_text(encoding="utf-8", errors="replace")
        m = re.search(r"SWNS:\s*(-?[\d.]+)ns", text)
        setup = float(m.group(1)) if m else None
        m = re.search(r"HWNS:\s*(-?[\d.]+)ns", text)
        hold = float(m.group(1)) if m else None
    if setup is None or hold is None or setup < 0 or hold < 0:
        errors.append(f"timing not met: setup={setup} hold={hold}")

    bit = PRJ / "build" / "td" / "anxin_screen.bit"
    if not bit.exists():
        errors.append("missing bitstream")
    if errors:
        print("BUILD FAILED")
        for line in errors:
            print(" ", line)
        return 1
    print(f"BUILD OK setup={setup}ns hold={hold}ns")
    print("bitstream:", bit)
    return 0


if __name__ == "__main__":
    sys.exit(main())
