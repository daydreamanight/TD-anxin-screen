#!/usr/bin/env python3
"""Decode Anxin AX diagnostic lines from saved text or stdin; never open a port.

Wire format: ASCII 'AX ' + 32 uppercase hex digits + CR LF.
One decoded JSON object is written per matching input line. Capture-tool timestamp
prefixes are accepted, and unrelated console lines are ignored.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Iterable

LINE = re.compile(r"(?:^|\s)AX ([0-9A-F]{32})(?=\s|$)")


def decode_payload(raw: str) -> dict:
    """Decode a canonical 128-bit payload, retaining raw data for future tools."""
    if not re.fullmatch(r"[0-9A-F]{32}", raw):
        raise ValueError("payload must contain exactly 32 uppercase hexadecimal digits")
    value = int(raw, 16)

    def bits(low: int, width: int) -> int:
        return (value >> low) & ((1 << width) - 1)

    version, record_type = bits(120, 8), bits(112, 8)
    result = {"version": version, "type": record_type, "raw": raw}
    if version != 1:
        result["kind"] = "unknown_version"
        return result
    if record_type == 0:
        result.update(
            kind="observer",
            uptime_seconds=bits(80, 32),
            reset_count=bits(64, 16),
            first_error=f"0x{bits(56, 8):02X}",
            locks=bits(52, 4),
            locks_binary=f"{bits(52, 4):04b}",
            system_pll_locked=bool(bits(52, 4) & 8),
            video_pll_locked=bool(bits(52, 4) & 4),
            audio_pll_locked=bool(bits(52, 4) & 2),
            reset_released=bool(bits(52, 4) & 1),
            mode=bits(50, 2),
            reserved=f"0x{bits(0, 50):013X}",
        )
    elif record_type == 1:
        mask = bits(0, 5)
        result.update(
            kind="sd",
            stage=bits(104, 8),
            error=f"0x{bits(96, 8):02X}",
            last_lba=bits(64, 32),
            crc32=f"0x{bits(32, 32):08X}",
            signature=f"0x{bits(16, 16):04X}",
            byte_count=bits(6, 10),
            initialized=bool(bits(5, 1)),
            resources_mask=mask,
            resources=[f"PIC{i + 1}.BMP" for i in range(5) if mask & (1 << i)],
        )
    elif record_type == 2:
        flags = bits(20, 4)
        result.update(
            kind="pixel",
            state=bits(104, 8),
            error=f"0x{bits(96, 8):02X}",
            uptime_seconds=bits(64, 32),
            cts=bits(44, 20),
            audio_samples=bits(28, 16),
            page=bits(24, 4),
            display_enabled=bool(flags & 8),
            auto_mode=bool(flags & 4),
            underflow=bool(flags & 2),
            prefetch_ready=bool(flags & 1),
            flags=flags,
            pcm_source_overflow=bool(bits(0, 1)),
            countdown_valid=bool(bits(5, 1)),
            seconds_remaining=bits(1, 4),
            brightness_level=bits(16, 4), contrast_level=bits(12, 4),
            edit_mode=bool(bits(11, 1)), selected_field=bits(9, 2),
            waveform_enabled=bool(bits(8, 1)), waveform_snapshot_valid=bool(bits(7, 1)),
            reserved=f"0x{bits(0, 20):05X}",
        )
    elif record_type == 3:
        flags = bits(104, 8)
        result.update(
            kind="hdmi_audio",
            hdmi_video_locked=bool(flags & 8),
            edid_at_least_128_bytes=bool(flags & 4),
            acr_parameters_saved=bool(flags & 2),
            audio_reset_released=bool(flags & 1),
            last_valid_cts=bits(84, 20), last_valid_n=bits(64, 20),
            acr_event_count=bits(48, 16), audio_event_count=bits(32, 16),
            edid_byte_count=bits(16, 16), edid_last_byte=f"0x{bits(8, 8):02X}",
            edid_stream_sum=f"0x{bits(0, 8):02X}",
            flags=flags,
        )
    elif record_type == 4:
        flags = bits(16, 8)
        result.update(
            kind="sd_protocol", init_state=bits(104, 8), error=f"0x{bits(96, 8):02X}",
            cmd_state=bits(88, 8), last_cmd=bits(80, 8), last_r1=f"0x{bits(72, 8):02X}",
            cmd_error_count=bits(56, 16), sector_head=f"0x{bits(24, 32):08X}",
            initialized=bool(flags & 2), reader_busy=bool(flags & 1),
            byte_count=bits(0, 16), flags=flags,
        )
    elif record_type == 5:
        flags = bits(104, 8)
        result.update(
            kind="sd_recovery", initialized=bool(flags & 2), reader_busy=bool(flags & 1),
            error=f"0x{bits(96, 8):02X}", last_lba=bits(64, 32),
            recovery_count=bits(48, 16), first_recovery_error=f"0x{bits(40, 8):02X}",
            last_cmd=bits(32, 8), cmd_state=bits(24, 8), init_state=bits(16, 8),
            byte_count=bits(0, 16), flags=flags,
        )
    elif record_type == 6:
        result.update(
            kind="image_scaling", stage=bits(104, 8), error=f"0x{bits(96, 8):02X}",
            source_width=bits(80, 16), source_height=bits(64, 16),
            target_pixels=bits(32, 32), reserved=f"0x{bits(0, 32):08X}",
        )
    elif record_type == 7:
        result.update(
            kind="scene_control", state=bits(104, 8), error=f"0x{bits(96, 8):02X}",
            uptime_seconds=bits(64, 32), emergency_requests=bits(48, 16),
            emergency_exits=bits(32, 16), pages_presented=bits(16, 16),
            page=bits(8, 3), emergency_pending=bool(bits(2, 1)),
            emergency_active=bool(bits(1, 1)), emergency_unavailable=bool(bits(0, 1)),
            flags=bits(0, 3),
        )
    elif record_type == 8:
        result.update(
            kind="scene_audio", state=bits(104, 8), error=f"0x{bits(96, 8):02X}",
            uptime_seconds=bits(64, 32), cue_event_count=bits(48, 16),
            audio_samples=bits(32, 16), page=bits(8, 3),
            page_presented=bool(bits(3, 1)), emergency_active=bool(bits(2, 1)),
            playing=bool(bits(1, 1)), scene_enabled=bool(bits(0, 1)),
        )
    elif record_type == 9:
        result.update(
            kind="mount_recovery", stage=bits(104, 8), error=f"0x{bits(96, 8):02X}",
            last_lba=bits(64, 32), sector_head=f"0x{bits(32, 32):08X}",
            signature=f"0x{bits(16, 16):04X}", first_mount_error=f"0x{bits(8, 8):02X}",
            retry_count=bits(3, 2), mount_failed=bool(bits(2, 1)),
            catalog_complete=bool(bits(1, 1)), mounted=bool(bits(0, 1)),
        )
    elif record_type == 10:
        flags = bits(104, 8)
        result.update(
            kind="offline_config", flags=flags,
            metadata_available=bool(flags & 128), started=bool(flags & 64),
            finished=bool(flags & 32), accepted=bool(flags & 16),
            applied=bool(flags & 8), parser_busy=bool(flags & 4),
            result_pending=bool(flags & 2), normal_mode=bool(flags & 1),
            parser_error=f"0x{bits(96, 8):02X}", source_error=f"0x{bits(88, 8):02X}",
            enabled_mask=bits(80, 5),
            order=[bits(64 + 3 * i, 3) + 1 for i in range(5)],
            hold_seconds=[bits(32 + 6 * i, 6) for i in range(5)],
            scene_mode=bool(bits(0, 1)),
        )
    else:
        result["kind"] = "unknown_type"
    return result


def decode_line(line: str) -> dict | None:
    match = LINE.search(line)
    return decode_payload(match.group(1)) if match else None


def read_lines(names: list[str]) -> Iterable[tuple[str, int, str]]:
    for name in names:
        if name == "-":
            for number, line in enumerate(sys.stdin, 1):
                yield "stdin", number, line
        else:
            with Path(name).open(encoding="utf-8-sig", errors="replace") as stream:
                for number, line in enumerate(stream, 1):
                    yield name, number, line


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", nargs="*", help="saved UTF-8 text files; '-' or no file reads stdin")
    parser.add_argument("--pretty", action="store_true", help="indent JSON for reading")
    parser.add_argument("--strict", action="store_true", help="exit 2 if a line containing 'AX ' is malformed")
    args = parser.parse_args(argv)
    decoded = malformed = 0
    try:
        for name, number, line in read_lines(args.logs or ["-"]):
            record = decode_line(line)
            if record is not None:
                print(json.dumps(record, ensure_ascii=False, indent=2 if args.pretty else None))
                decoded += 1
            elif "AX " in line:
                print(f"{name}:{number}: ignored malformed AX record", file=sys.stderr)
                malformed += 1
    except OSError as exc:
        print(f"read error: {exc}", file=sys.stderr)
        return 2
    if args.strict and malformed:
        return 2
    if not decoded:
        print("no valid AX records found", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
