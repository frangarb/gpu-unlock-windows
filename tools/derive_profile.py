#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Draft a reviewed-profile proposal from one read-only discovery capture.

Input is the DIAG file written by the discovery observation build
(docs/DISCOVERY.en.md): a graph capture with the read-only GPU probe inside it.
Output is a JSON summary plus the machine-profile.h constants the capture can
prove. Display-driver fingerprints and any write-enabled decision stay manual;
this tool never authorizes an unlock.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "research" / "headless"))
from analyze_capture import device_path  # noqa: E402  (same strict path parser)

MARKER = "gpu-console-graph-v1 observational-only; no-detach no-unlock no-nvram-write"
GOP_GUID = "9042a9de-23dc-4a38-96fb-7aded080516a"
NVIDIA = 0x10DE
BAR0_BYTES = 16 * 1024 * 1024  # GA10x display BAR0; a non-GA10x shape is refused
CHIP_FAMILIES = {
    0x172: "GA102", 0x173: "GA103", 0x174: "GA104", 0x176: "GA106", 0x177: "GA107",
    0x1B2: "GA102", 0x1B7: "GA106",
}

# Register offsets the probe reads, with the name each one feeds in a profile.
REGISTERS = {
    0x000000: "chip",
    0x1183A4: "fb_mb",
    0x1FA824: "wpr2_lo",
    0x1FA828: "wpr2_hi",
    0x1FA7C8: "mmu_plm",
    0x1FA82C: "mmu_lock_lo",
    0x1FA830: "mmu_lock_hi",
    0x625F04: "vga_workspace",
    0x823804: "feat_plm",
    0x82381C: "ss0",
    0x823820: "ss1",
    0x824140: "fuse_sec2_ucode1",
}
REQUIRED_REGISTERS = ("chip", "fb_mb", "wpr2_hi", "feat_plm", "ss0", "ss1")


def ga10x_chip(chip: int) -> bool:
    """GA10x samples read as 0x17<family>00a1 (engineering) or 0xB7<family>00a1."""
    return ((chip & 0xFF) == 0xA1 and (chip >> 8) & 0xFF == 0 and
            (chip >> 16) & 0x0F == 0 and chip >> 24 in (0x17, 0xB7))


class CaptureError(ValueError):
    pass


def hexint(text: str) -> int:
    return int(text, 16)


def sections(text: str) -> list[str]:
    parts = text.split(MARKER)[1:]
    if not parts:
        raise CaptureError("no discovery capture marker found")
    if len(parts) != 1:
        raise CaptureError("multiple captures: keep exactly one DIAG file")
    section = parts[0]
    if "capture-complete=1" not in section or "capture-complete=0" in section:
        raise CaptureError("incomplete capture (capture-complete=0 or missing)")
    return section.split("capture-complete=1")[0]


def probe_block(section: str) -> str:
    start = section.find("probe-pci-handles=")
    if start < 0:
        raise CaptureError("no probe section: build the discovery profile, not a profile build")
    end = section.find("handles status=", start)
    return section[start:end if end > 0 else len(section)]


def targets(probe: str) -> list[str]:
    starts = [m.start() for m in re.finditer(r"^probe-target seg=", probe, re.M)]
    if not starts:
        raise CaptureError("probe found no target GPU")
    if len(starts) > 1:
        raise CaptureError(f"probe found {len(starts)} candidate GPUs: ambiguity is a refusal")
    end = probe.find("probe targets=", starts[0])
    return [probe[starts[0]:end if end > 0 else len(probe)]]


def parse_target(block: str) -> dict:
    head = re.search(
        r"^probe-target seg=0x([0-9a-f]+) bus=0x([0-9a-f]+) dev=0x([0-9a-f]+) fun=0x([0-9a-f]+)$",
        block, re.M)
    if not head:
        raise CaptureError("malformed probe-target record")
    config = re.search(r"^cfg dwords=([0-9a-f ]+)$", block, re.M)
    if not config:
        raise CaptureError("missing 256-byte config snapshot")
    words = [hexint(word) for word in config.group(1).split()]
    if len(words) != 64:
        raise CaptureError(f"config snapshot has {len(words)} dwords, expected 64")
    if "cfg256 status=0x0000000000000000" not in block:
        raise CaptureError("config snapshot failed on hardware")
    ids = words[0]
    if ids & 0xFFFF != NVIDIA:
        raise CaptureError(f"target {ids:#010x} is not an NVIDIA function")
    if words[2] >> 24 != 0x03:
        raise CaptureError("target is not a display controller")
    bar = words[0x10 // 4]
    if bar & 0x6:
        raise CaptureError("BAR0 is not a 32-bit memory BAR: unsupported shape")
    base = bar & ~0xF
    if not base or base == 0xFFFFFFF0:
        raise CaptureError("BAR0 has no assigned address")
    return {
        "segment": hexint(head.group(1)), "bus": hexint(head.group(2)),
        "device": hexint(head.group(3)), "function": hexint(head.group(4)),
        "vendor_device": f"{ids & 0xFFFF:04x}:{ids >> 16:04x}",
        "subsystem": f"{words[0x2C // 4] & 0xFFFF:04x}:{words[0x2C // 4] >> 16:04x}",
        "class_code": f"{words[2] >> 8 & 0xFFFFFF:06x}",
        "revision": words[2] & 0xFF,
        "bar0_base": base,
        "bar0_bytes": BAR0_BYTES,
        "_ids": ids, "_subsystem": words[0x2C // 4],
    }


def parse_registers(block: str) -> dict:
    values = {}
    for match in re.finditer(
            r"^mmio off=0x([0-9a-f]+) status=0x([0-9a-f]+) value=0x([0-9a-f]+)$", block, re.M):
        status, value = hexint(match.group(2)), hexint(match.group(3))
        name = REGISTERS.get(hexint(match.group(1)))
        if status or name is None:
            continue
        if name in values:
            raise CaptureError(f"duplicate register read for {name}")
        values[name] = value
    missing = [name for name in REQUIRED_REGISTERS if name not in values]
    if missing:
        raise CaptureError("register reads failed for: " + ", ".join(missing))
    return values


def parse_prom(block: str) -> str:
    match = re.search(r"^prom sha256=([0-9a-f]{64})$", block, re.M)
    if not match:
        raise CaptureError("PROM digest missing: the 1 MiB read at 0x300000 failed")
    return match.group(1)


def graph_blocks(section: str) -> dict[int, str]:
    records = re.findall(r"^handle id=(0x[0-9a-f]+)\n(.*?)(?=^handle id=|\Z)", section, re.M | re.S)
    blocks = {}
    for handle, body in records:
        key = hexint(handle)
        if key in blocks:
            raise CaptureError("duplicate handle record")
        blocks[key] = body
    if not blocks:
        raise CaptureError("empty handle snapshot")
    return blocks


def block_path(body: str) -> bytes | None:
    return device_path(body)


def topology(section: str, target: dict) -> dict:
    blocks = graph_blocks(section)
    console = re.search(r"^console out=(0x[0-9a-f]+) error=(0x[0-9a-f]+) input=(0x[0-9a-f]+)$",
                        section, re.M)
    if not console:
        raise CaptureError("system console handles missing")
    console_out = hexint(console.group(1))

    matching = []
    for handle, body in blocks.items():
        cfg = re.search(r"^pci config-dwords=([0-9a-f ]+)$", body, re.M)
        if not cfg:
            continue
        words = [hexint(word) for word in cfg.group(1).split()]
        if len(words) != 16:
            raise CaptureError("short PCI identity record in the handle graph")
        if words[0] == target["_ids"] and words[0x2C // 4] == target["_subsystem"]:
            path = block_path(body)
            if not path:
                raise CaptureError("target PCI handle has no device path")
            matching.append((handle, path))
    if len(matching) != 1:
        raise CaptureError(f"{len(matching)} handle(s) match the probe target: ambiguity is a refusal")
    _, target_path = matching[0]

    gops, other_display = [], []
    prefix = target_path[:-4]
    for handle, body in blocks.items():
        cfg = re.search(r"^pci config-dwords=([0-9a-f ]+)$", body, re.M)
        if cfg:
            words = [hexint(word) for word in cfg.group(1).split()]
            if len(words) == 16 and words[2] >> 24 == 0x03 and words[0] != target["_ids"]:
                other_display.append({
                    "vendor_device": f"{words[0] & 0xFFFF:04x}:{words[0] >> 16:04x}",
                    "class_code": f"{words[2] >> 8 & 0xFFFFFF:06x}",
                })
        if "protocol guid=" + GOP_GUID not in body:
            continue
        mode = re.search(r"^gop framebuffer=0x([0-9a-f]+) bytes=0x([0-9a-f]+)", body, re.M)
        if not mode:
            continue
        framebuffer, size = hexint(mode.group(1)), hexint(mode.group(2))
        path = block_path(body)
        on_target = bool(path and path[:-4].startswith(prefix))
        if framebuffer and size:
            gops.append({"handle": handle, "framebuffer": framebuffer, "bytes": size,
                         "target": on_target, "console": handle == console_out,
                         "path": path})
    if not gops:
        raise CaptureError("no physical GOP observed: nothing describes the boot display")

    # GU_RTX_PATH_BYTES is compared against the boot display's endpoint path,
    # so the target GOP's own path is the constant. The PCI handle carries the
    # shorter PCI-only path, which no display route ever matches.
    display_path = next((gop["path"] for gop in gops if gop["target"] and gop["console"]), None) \
        or next((gop["path"] for gop in gops if gop["target"]), None)

    return {
        "physical_gop_count": len(gops),
        "target_gop": any(gop["target"] for gop in gops),
        "console_on_target": any(gop["target"] and gop["console"] for gop in gops),
        "other_display_functions": other_display,
        "target_path_bytes": list(display_path or target_path),
    }


def profile_blocks(name: str, define: str, pci: dict, registers: dict, prom: str,
                   display: dict) -> tuple[str, str]:
    path = display["target_path_bytes"]
    nodes = []
    at = 0
    while at + 4 <= len(path):
        length = path[at + 2] | (path[at + 3] << 8)
        nodes.append(path[at:at + length])
        at += length
    if len(nodes) < 3 or nodes[1][0] != 1 or nodes[2][0] != 1:
        raise CaptureError("device path is not ACPI root + PCI root port + endpoint")
    root_port_device, root_port_function = nodes[1][5], nodes[1][4]
    chip = registers["chip"]
    family = CHIP_FAMILIES.get((chip >> 20) & 0xFFF) or CHIP_FAMILIES.get((chip >> 16) & 0xFFF)
    header = "\n".join([
        f"#if defined({define})",
        f"/* {name}. Captured from a read-only discovery build; display-driver",
        " * fingerprints are still pending review (docs/DISCOVERY.en.md). */",
        f"#define GU_PROFILE_NAME \"{name}\"",
        f"#define GU_BOARD_ID 0x{pci['_ids']:08x}U",
        f"#define GU_BOARD_SUBSYSTEM 0x{pci['_subsystem']:08x}U",
        f"#define GU_BAR0_BASE 0x{pci['bar0_base']:08x}ULL",
        f"#define GU_BAR0_END 0x{pci['bar0_base'] + BAR0_BYTES - 1:08x}ULL",
        f"#define GU_DEVICE_MEMORY_SIZE 0x{registers['fb_mb']:x}U",
        f"#define GU_CHIP_ID 0x{chip:08x}U",
        f"#define GU_PROM_SHA256 \"{prom}\"",
        f"#define GU_ROOT_PORT_DEVICE {root_port_device}U",
        f"#define GU_ROOT_PORT_FUNCTION {root_port_function}U",
        "#define GU_RTX_PATH_BYTES \\",
        "  " + ",".join(str(byte) for byte in path),
        "#endif",
    ])
    slug = define.removeprefix("GU_PROFILE_").lower()
    table = (
        f" '{slug}'=[ordered]@{{Define='-D{define}';Name='{name}';"
        f"TargetPci='{pci['vendor_device'].replace(':', '')}';"
        f"Subsystem='{pci['subsystem'].replace(':', '')}';Chip='0x{chip:08x}';"
        f"Prom='{prom}';Memory='0x{registers['fb_mb']:x}';HeadlessOnly=$true}}"
    )
    return header, table


def derive(raw: bytes, name: str, define: str) -> dict:
    if len(raw) > 8 * 1024 * 1024:
        raise CaptureError("capture exceeds the diagnostic format limit")
    text = raw.decode("utf-8-sig").replace("\r\n", "\n")
    section = sections(text)
    probe = probe_block(section)
    block = targets(probe)[0]
    pci = parse_target(block)
    registers = parse_registers(block)
    prom = parse_prom(block)
    display = topology(section, pci)
    header, table = profile_blocks(name, define, pci, registers, prom, display)

    warnings = [
        "A capture is software evidence: it cannot establish capture freshness or provenance.",
        "BAR0 size is taken as the GA10x 16 MiB shape, not measured: the BAR was never written.",
        "Display-driver fingerprints (nvgop/combo/EDID image and text digests) are not derived here.",
        "Mock and capture agreement does not prove GPU success; hardware evidence is separate.",
    ]
    if not display["target_gop"]:
        warnings.append("No GOP belongs to the target: the boot display is on another GPU.")
    if display["console_on_target"]:
        warnings.append("The system console is on the target: FLR blanks it until a driver returns.")
    if not ga10x_chip(registers["chip"]):
        warnings.append(f"Chip id {registers['chip']:#010x} is not a GA10x chip id.")
    if registers["wpr2_hi"] >> 4:
        warnings.append("WPR2 is enabled at capture time: the machine was not cold.")
    if registers["feat_plm"] == 0xFFFFFFFF:
        warnings.append("FEAT_OVR_PLM is already open: the card was already unlocked.")
    if registers["ss0"] == 0x88888888:
        warnings.append("SS0 is already the unlocked value at capture time.")

    return {
        "schema_version": 1,
        "status": "captured-profile-draft",
        "authorizes_unlock": False,
        "capture_sha256": hashlib.sha256(raw).hexdigest(),
        "profile_name": name,
        "profile_define": define,
        "pci": {key: value for key, value in pci.items() if not key.startswith("_")},
        "registers": registers,
        "prom_sha256": prom,
        "display": display,
        "warnings": warnings,
        "pending_review": [
            "Console/driver image fingerprints for the display release policy.",
            "Cold-selector semantics: confirm SS0 and SS1 entry values on this exact card.",
            "Memory/WPR layout inputs against the first full transaction rehearsal.",
            "Host negative tests for this profile before any write-enabled build.",
        ],
        "machine_profile_h": header,
        "build_table_entry": table,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--capture", type=Path, required=True, help="DIAG file from the observation build")
    parser.add_argument("--name", required=True, help="profile name, e.g. ASUS-B550-RTX3060")
    parser.add_argument("--define", required=True, help="profile define, e.g. GU_PROFILE_ASUS_B550_RTX3060")
    parser.add_argument("--output", type=Path, help="write JSON here instead of stdout")
    args = parser.parse_args()
    if not re.fullmatch(r"GU_PROFILE_[A-Z0-9_]+", args.define):
        parser.exit(2, "define must look like GU_PROFILE_ASUS_B550_RTX3060\n")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{2,63}", args.name):
        parser.exit(2, "name must be 3-64 characters of letters, digits, dot, dash or underscore\n")
    try:
        result = derive(args.capture.read_bytes(), args.name, args.define)
    except (OSError, UnicodeError, ValueError) as error:
        parser.exit(2, f"capture rejected: {error}\n")
    text = json.dumps(result, indent=2) + "\n"
    if args.output:
        try:
            with args.output.open("x", encoding="utf-8", newline="\n") as stream:
                stream.write(text)
        except OSError as error:
            parser.exit(2, f"cannot write {args.output}: {error}\n")
    else:
        print(text, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
