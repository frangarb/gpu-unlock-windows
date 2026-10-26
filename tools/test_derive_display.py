# SPDX-License-Identifier: GPL-2.0-only
"""Host checks for the display-fingerprint deriver.

The fixture is a synthetic capture plus a synthetic loaded image: the deriver
must read exactly what the discovery build writes, and refuse everything it
cannot prove. No GPU, firmware or real driver is touched.
"""
import hashlib
import struct
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import derive_display  # noqa: E402

TEXT_RVA = 0x200
TEXT_SIZE = 0x180
IMAGE_SIZE = 0x1000


def pe_image(text: bytes) -> bytes:
    image = bytearray(IMAGE_SIZE)
    image[:2] = b"MZ"
    struct.pack_into("<I", image, 0x3C, 0x80)
    image[0x80:0x84] = b"PE\0\0"
    struct.pack_into("<HHIIIHH", image, 0x84, 0x8664, 1, 0, 0, 0, 0xF0, 0x2022)
    struct.pack_into("<H", image, 0x98, 0x20B)
    struct.pack_into("<II", image, 0x98 + 0x40, 0x1000, 0x200)  # SizeOfImage / SizeOfHeaders
    table = 0x80 + 24 + 0xF0
    image[table:table + 8] = b".text\0\0\0"
    struct.pack_into("<II", image, table + 8, len(text), TEXT_RVA)
    image[TEXT_RVA:TEXT_RVA + len(text)] = text
    return bytes(image)


def name_node(name: str) -> bytes:
    payload = name.encode("utf-16-le") + b"\0\0"
    return bytes([4, 4, 4 + len(payload), 0]) + payload


def guid_node(text: str) -> bytes:
    first, second, third, fourth, fifth = text.split("-")
    raw = struct.pack("<IHH", int(first, 16), int(second, 16), int(third, 16))
    raw += bytes.fromhex(fourth) + bytes.fromhex(fifth)
    return bytes([4, 6, 20, 0]) + raw


def capture(path_node: bytes, base=0x1000, size=IMAGE_SIZE, stop=0x1100, version=0x60010) -> str:
    return "\n".join([
        f"img base=0x{base:016x}",
        f"img size=0x{size:016x}",
        "img code-type=0x0000000000000003",
        "handle id=0x0000000000000001",
        f"driver image=0x1 binding=0x1 version=0x{version:016x} stop-address=0x{stop:016x}",
        f"image parent=0x0 device=0x0 base=0x{base:016x} size=0x{size:016x} "
        "code-type=0x0000000000000003",
        "image-file-path-node raw=" + path_node.hex(),
        "path-node raw=7fff0400",
    ])


class DisplayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.images = Path(self.temp.name)
        self.code = (bytes(range(256)) * (TEXT_SIZE // 256 + 1))[:TEXT_SIZE]
        (self.images / "IMG00.BIN").write_bytes(pe_image(self.code))

    def tearDown(self):
        self.temp.cleanup()

    def derive(self, text, selector="name:nvgop-ga1xx"):
        records = derive_display.bindings(text)
        return derive_display.macros(derive_display.resolve(records, selector), self.images, "GU_X")

    def test_derives_the_code_range_of_the_dumped_image(self):
        found = self.derive(capture(name_node("nvgop-ga1xx")))
        self.assertEqual(found["image"], "IMG00.BIN")
        self.assertEqual(found["version"], 0x60010)
        self.assertEqual(found["image_size"], IMAGE_SIZE)
        self.assertEqual(found["stop_offset"], 0x100)
        self.assertEqual(found["text_rva"], TEXT_RVA)
        self.assertEqual(found["text_bytes"], TEXT_SIZE)
        self.assertEqual(found["text_sha256"], hashlib.sha256(self.code).hexdigest())
        self.assertIn('#define GU_X_TEXT_SHA256 "' + hashlib.sha256(self.code).hexdigest() + '"',
                      derive_display.emit("GU_X", found))

    def test_resolves_a_firmware_volume_file_guid(self):
        text = capture(guid_node("c7a7030c-c3d8-45ee-bed9-5d9e76762953"))
        found = self.derive(text, "guid:c7a7030c-c3d8-45ee-bed9-5d9e76762953")
        self.assertEqual(found["path"]["kind"], "guid")
        self.assertEqual(found["text_bytes"], TEXT_SIZE)

    def test_refuses_a_selector_with_no_agent(self):
        with self.assertRaises(derive_display.CaptureError):
            self.derive(capture(name_node("nvgop-ga1xx")), "name:nvgop-ga2xx")

    def test_refuses_two_agents_on_one_selector(self):
        text = capture(name_node("nvgop-ga1xx")) + "\n" + capture(name_node("nvgop-ga1xx"), base=0x9000)
        with self.assertRaises(derive_display.CaptureError):
            self.derive(text)

    def test_refuses_a_capture_that_skipped_the_dump(self):
        text = "\n".join(line for line in capture(name_node("nvgop-ga1xx")).split("\n")
                         if not line.startswith("img "))
        with self.assertRaises(derive_display.CaptureError):
            self.derive(text)

    def test_refuses_a_dump_whose_size_disagrees(self):
        text = capture(name_node("nvgop-ga1xx"), size=0x800)
        with self.assertRaises(derive_display.CaptureError):
            self.derive(text)

    def test_refuses_a_stop_address_outside_the_image(self):
        text = capture(name_node("nvgop-ga1xx"), stop=0x4000)
        with self.assertRaises(derive_display.CaptureError):
            self.derive(text)

    def test_refuses_a_non_pe_image(self):
        (self.images / "IMG00.BIN").write_bytes(b"\0" * IMAGE_SIZE)
        with self.assertRaises(derive_display.CaptureError):
            self.derive(capture(name_node("nvgop-ga1xx")))

    def test_refuses_a_code_range_past_the_dump(self):
        image = bytearray(pe_image(self.code))
        struct.pack_into("<I", image, 0x80 + 24 + 0xF0 + 8, IMAGE_SIZE)
        (self.images / "IMG00.BIN").write_bytes(bytes(image))
        with self.assertRaises(derive_display.CaptureError):
            self.derive(capture(name_node("nvgop-ga1xx")))


if __name__ == "__main__":
    unittest.main()
