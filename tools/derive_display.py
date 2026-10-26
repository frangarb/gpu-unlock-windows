#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Derive the display-driver identity macros from one discovery capture.

A capture records, per driver binding, the loaded image's base, size, code
type, stop address and device path, and dumps each image to IMG<nn>.BIN. The
release gate identifies three agents (nvgop, the EDID/mouse runtime driver and,
on aggregate boards, the combo/text-out splitter) by image size, stop offset
and a digest of their code. This tool reads those numbers off the capture and
the dumps instead of guessing them.

Output is never sufficient for support: it names constants, not a decision.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import struct
import sys
from pathlib import Path


class CaptureError(ValueError):
    pass


def bindings(text: str) -> list[dict]:
    """Every DriverBinding record with its loaded image, path and dump index."""
    dumps = {}
    for index, block in enumerate(re.finditer(r"(?m)^img base=0x(\w+)\nimg size=0x(\w+)", text)):
        dumps.setdefault((int(block.group(1), 16), int(block.group(2), 16)), index)
    found = []
    for block in re.split(r"(?m)^handle id=0x", text)[1:]:
        driver = re.search(r"(?m)^driver image=0x\w+ binding=0x\w+ version=0x(\w+) "
                           r"stop-address=0x(\w+)$", block)
        if not driver:
            continue
        image = re.search(r"(?m)^image parent=0x\w+ device=0x\w+ base=0x(\w+) "
                          r"size=0x(\w+) code-type=0x(\w+)$", block)
        if not image:
            continue
        base, size = int(image.group(1), 16), int(image.group(2), 16)
        found.append({
            "version": int(driver.group(1), 16),
            "stop": int(driver.group(2), 16),
            "base": base,
            "size": size,
            "code_type": int(image.group(3), 16),
            "path": device_path(block),
            "dump": dumps.get((base, size)),
        })
    return found


def device_path(block: str) -> dict:
    """The loaded image's first identifying node: a file name or a file GUID."""
    node = re.search(r"(?m)^image-file-path-node raw=(\w+)$", block)
    if not node:
        return {"kind": "none"}
    raw = bytes.fromhex(node.group(1))
    if len(raw) < 4:
        raise CaptureError("short image path node")
    node_type, node_subtype = raw[0], raw[1]
    length = raw[2] | (raw[3] << 8)
    if length != len(raw):
        raise CaptureError("image path node length disagrees with its dump")
    if (node_type, node_subtype) == (4, 4):
        name = raw[4:].decode("utf-16-le", "strict").rstrip("\x00")
        return {"kind": "name", "name": name}
    if (node_type, node_subtype) == (4, 6) and length == 20:
        return {"kind": "guid", "guid": guid(raw[4:20])}
    return {"kind": "other"}


def guid(raw: bytes) -> str:
    first, second, third = struct.unpack_from("<IHH", raw)
    return f"{first:08x}-{second:04x}-{third:04x}-{raw[8:10].hex()}-{raw[10:16].hex()}"


def text_section(image: bytes) -> tuple[int, int]:
    """(.text virtual address, .text virtual size) of a loaded PE32+ image."""
    if image[:2] != b"MZ":
        raise CaptureError("image is not a PE image (no MZ header)")
    at = struct.unpack_from("<I", image, 0x3C)[0]
    if at + 24 > len(image) or image[at:at + 4] != b"PE\0\0":
        raise CaptureError("image is not a PE image (no PE signature)")
    count = struct.unpack_from("<H", image, at + 6)[0]
    optional = struct.unpack_from("<H", image, at + 20)[0]
    if struct.unpack_from("<H", image, at + 24)[0] != 0x20B:
        raise CaptureError("image is not PE32+ (not an x64 EFI driver)")
    table = at + 24 + optional
    for index in range(count):
        entry = table + index * 40
        if entry + 40 > len(image):
            raise CaptureError("section table runs past the image")
        name = image[entry:entry + 8].rstrip(b"\x00")
        size, address = struct.unpack_from("<II", image, entry + 8)
        if name == b".text":
            if not size or address + size > len(image):
                raise CaptureError("code range runs past the dumped image")
            return address, size
    raise CaptureError("image has no .text section")


def resolve(records: list[dict], selector: str) -> dict:
    if selector.startswith("guid:"):
        key, value = "guid", selector[5:].lower()
    elif selector.startswith("name:"):
        key, value = "name", selector[5:]
    else:
        raise CaptureError(f"selector must be name:<text> or guid:<guid>: {selector}")
    matching = [record for record in records
                if record["path"]["kind"] == key and record["path"].get(key) == value]
    if len(matching) != 1:
        raise CaptureError(f"{len(matching)} agents match {selector}: ambiguity is a refusal")
    return matching[0]


def macros(record: dict, images: Path, prefix: str) -> dict:
    if record["dump"] is None:
        raise CaptureError(f"no image dump for {prefix}: the capture skipped it")
    path = images / f"IMG{record['dump']:02d}.BIN"
    image = path.read_bytes()
    if len(image) != record["size"]:
        raise CaptureError(f"{path.name} is {len(image)} bytes, the capture recorded {record['size']}")
    if not 0 < record["stop"] - record["base"] < record["size"]:
        raise CaptureError(f"{prefix}: stop address is outside the loaded image")
    address, size = text_section(image)
    return {
        "image": path.name,
        "version": record["version"],
        "image_size": record["size"],
        "stop_offset": record["stop"] - record["base"],
        "code_type": record["code_type"],
        "text_rva": address,
        "text_bytes": size,
        "text_sha256": hashlib.sha256(image[address:address + size]).hexdigest(),
        "path": record["path"],
    }


def emit(name: str, found: dict) -> str:
    return "\n".join([
        f"#define {name}_VERSION 0x{found['version']:x}U",
        f"#define {name}_IMAGE_SIZE 0x{found['image_size']:x}U",
        f"#define {name}_STOP 0x{found['stop_offset']:x}U",
        f"#define {name}_TEXT_BYTES 0x{found['text_bytes']:x}U",
        f"#define {name}_TEXT_SHA256 \"{found['text_sha256']}\"",
    ])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--capture", type=Path, required=True, help="DIAG file from the observation build")
    parser.add_argument("--images", type=Path, required=True, help="directory with the IMG<nn>.BIN dumps")
    parser.add_argument("--agent", action="append", required=True, metavar="MACRO=SELECTOR",
                        help="macro prefix and selector, e.g. GU_NVGOP=name:nvgop-ga1xx")
    args = parser.parse_args()
    try:
        text = args.capture.read_bytes().decode("utf-8-sig").replace("\r\n", "\n")
        records = bindings(text)
        if not records:
            raise CaptureError("capture has no driver bindings")
        result = {}
        for agent in args.agent:
            macro, _, selector = agent.partition("=")
            if not macro or not selector:
                raise CaptureError(f"agent must be MACRO=SELECTOR: {agent}")
            found = macros(resolve(records, selector), args.images, macro)
            result[macro] = found
            result[macro]["macros"] = emit(macro, found)
    except (OSError, UnicodeError, ValueError) as error:
        parser.exit(2, f"capture rejected: {error}\n")
    print(json.dumps(result, indent=2) + "\n")
    for found in result.values():
        print(found["macros"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
