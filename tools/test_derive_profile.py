# SPDX-License-Identifier: GPL-2.0-only
"""Host checks for the read-only capture-to-profile drafter.

The fixture reproduces a capture of the already documented GA104 machine
(issue #32 cold state), so the derived constants can be compared with the
reviewed profile that machine already has. No GPU or firmware is touched.
"""
import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import derive_profile  # noqa: E402

MARKER = derive_profile.MARKER
TARGET_PATH = bytes([
    2, 1, 12, 0, 0xd0, 0x41, 0x03, 0x0a, 0, 0, 0, 0,
    1, 1, 6, 0, 0, 1, 1, 1, 6, 0, 0, 0,
    2, 3, 8, 0, 32, 3, 1, 128, 127, 255, 4, 0,
])
# The same card's PCI handle only carries the PCI nodes; the boot display has an
# extra ACPI ADR endpoint node, which is the path a display route is matched on.
PCI_ONLY_PATH = TARGET_PATH[:24] + TARGET_PATH[-4:]
CONSOLE = 0x200


def config_dwords(ids=0x248210DE, subsystem=0x50521462, class_rev=0x030000A1,
                  bar0=0x82000000):
    words = [0] * 64
    words[0] = ids
    words[2] = class_rev
    words[3] = 0x00100000
    words[4] = bar0
    words[11] = subsystem
    return words


def probe_section(words, registers, targets=1):
    lines = [f"probe-pci-handles={3:016x}"]
    for _ in range(targets):
        lines += [
            "probe class=0x0000000003000000",
            "probe-target seg=0x0000 bus=0x0001 dev=0x0000 fun=0x0000",
            "cfg256 status=0x0000000000000000",
            "cfg dwords=" + " ".join(f"{word:08x}" for word in words),
            "subsystem=0x0000000050521462",
            "probe-bar0 base=0x0000000082000000",
        ]
        lines += [f"mmio off=0x{offset:08x} status=0x0000000000000000 value=0x{value:08x}"
                  for offset, value in registers]
        lines.append("prom sha256=" + "f4" * 32)
    lines.append("probe targets=0001")
    return "\n".join(lines)


def path_lines(path=TARGET_PATH):
    lines, at = [], 0
    while at + 4 <= len(path):
        length = path[at + 2] | (path[at + 3] << 8)
        lines.append("path-node raw=" + path[at:at + length].hex())
        at += length
    return lines


def graph(words, gop_path=TARGET_PATH, pci_path=TARGET_PATH, targets=1, registers=None):
    blocks = [
        ["handle id=0x0000000000000100", "protocol guid=00000000-0000-0000-0000-000000000001",
         "opens status=0x0 count=0x0", *path_lines(pci_path),
         "pci location-status=0x0 segment=0x0 bus=0x1 device=0x0 function=0x0",
         "pci config-status=0x0",
         "pci config-dwords=" + " ".join(f"{word:08x}" for word in words[:16])],
        ["handle id=0x0000000000000200", "protocol guid=" + derive_profile.GOP_GUID,
         "opens status=0x0 count=0x0", *path_lines(gop_path),
         "gop framebuffer=0x00000000f0000000 bytes=0x0000000001000000 mode=0x0 max-mode=0x1"],
        ["handle id=0x0000000000000300", "protocol guid=00000000-0000-0000-0000-000000000003",
         "opens status=0x0 count=0x0",
         "pci config-status=0x0",
         "pci config-dwords=" + " ".join(
             f"{word:08x}" for word in [0x164E1002] + [0] * 13 + [0x88771043][:1] + [0] * 1)],
    ]
    body = []
    for block in blocks:
        body += block
    return "\n".join([
        f"console out=0x{CONSOLE:016x} error=0x0000000000000200 input=0x0000000000000300",
        probe_section(words, REGISTERS if registers is None else registers, targets),
        "handles status=0x0000000000000000 count=0x0000000000000003",
        *body,
        "capture-complete=1",
    ])


REGISTERS = [
    (0x000000, 0xB74000A1), (0x1183A4, 0x2000), (0x1FA824, 0x0), (0x1FA828, 0x0),
    (0x1FA7C8, 0x45CB8F), (0x1FA82C, 0x100000), (0x1FA830, 0x5CFFFF0),
    (0x625F04, 0x1FFE0000), (0x823804, 0xFFFFFF8F), (0x82381C, 0x17743076),
    (0x823820, 0x7), (0x824140, 0x1),
]


def capture(**overrides):
    words = overrides.pop("words", config_dwords())
    registers = overrides.pop("registers", REGISTERS)
    targets = overrides.pop("targets", 1)
    return (MARKER + "\r\n" + graph(words, registers=registers, targets=targets,
                                    **overrides)).encode()


class DeriveTests(unittest.TestCase):
    def test_derives_the_documented_ga104_profile(self):
        result = derive_profile.derive(capture(), "ASUS-TUF-GAMING-B660M-E-D4-4003-RTX3070TI",
                                      "GU_PROFILE_B660M_3070TI")
        self.assertEqual(result["status"], "captured-profile-draft")
        self.assertFalse(result["authorizes_unlock"])
        pci = result["pci"]
        self.assertEqual(pci["vendor_device"], "10de:2482")
        self.assertEqual(pci["subsystem"], "1462:5052")
        self.assertEqual(pci["bar0_base"], 0x82000000)
        self.assertEqual(pci["bus"], 1)
        self.assertEqual(result["registers"]["chip"], 0xB74000A1)
        self.assertEqual(result["display"]["target_gop"], True)
        self.assertEqual(result["display"]["console_on_target"], True)
        self.assertEqual(result["prom_sha256"], "f4" * 32)
        header = result["machine_profile_h"]
        for expected in ("#define GU_BOARD_ID 0x248210deU",
                         "#define GU_BOARD_SUBSYSTEM 0x50521462U",
                         "#define GU_BAR0_BASE 0x82000000ULL",
                         "#define GU_BAR0_END 0x82ffffffULL",
                         "#define GU_DEVICE_MEMORY_SIZE 0x2000U",
                         "#define GU_CHIP_ID 0xb74000a1U",
                         "#define GU_ROOT_PORT_DEVICE 1U",
                         "#define GU_ROOT_PORT_FUNCTION 0U"):
            self.assertIn(expected, header)
        self.assertIn("  " + ",".join(str(byte) for byte in TARGET_PATH), header)
        self.assertIn("'b660m_3070ti'", result["build_table_entry"])
        self.assertIn("#define GU_PROFILE_NAME \"ASUS-TUF-GAMING-B660M-E-D4-4003-RTX3070TI\"",
                      header)

    def test_path_constant_is_the_boot_display_not_the_pci_handle(self):
        """A derived GU_RTX_PATH_BYTES must be the path a display route matches."""
        header = derive_profile.derive(capture(pci_path=PCI_ONLY_PATH), "X-Y-Z",
                                       "GU_PROFILE_X")["machine_profile_h"]
        self.assertIn("  " + ",".join(str(byte) for byte in TARGET_PATH), header)

    def test_chip_shape_warning_only_for_non_ga10x(self):
        """Retail cards read 0xb7<family>00a1; that must not warn as unknown."""
        retail = derive_profile.derive(capture(), "X-Y-Z", "GU_PROFILE_X")
        self.assertEqual([w for w in retail["warnings"] if "chip id" in w.lower()], [])
        garbage = [(offset, 0x123400A1 if offset == 0 else value)
                   for offset, value in REGISTERS]
        draft = derive_profile.derive(capture(registers=garbage), "X-Y-Z", "GU_PROFILE_X")
        self.assertIn("Chip id 0x123400a1 is not a GA10x chip id.", draft["warnings"])

    def test_refuses_two_candidates(self):
        with self.assertRaises(derive_profile.CaptureError):
            derive_profile.derive(capture(targets=2), "X-Y-Z", "GU_PROFILE_X")

    def test_refuses_64bit_bar(self):
        words = config_dwords()
        words[4] |= 0x4
        with self.assertRaises(derive_profile.CaptureError):
            derive_profile.derive(capture(words=words), "X-Y-Z", "GU_PROFILE_X")

    def test_refuses_missing_prom(self):
        raw = capture().replace(b"prom sha256=" + b"f4" * 32, b"incomplete reason=prom-read")
        with self.assertRaises(derive_profile.CaptureError):
            derive_profile.derive(raw, "X-Y-Z", "GU_PROFILE_X")

    def test_refuses_incomplete_capture(self):
        raw = capture().replace(b"capture-complete=1", b"capture-complete=0")
        with self.assertRaises(derive_profile.CaptureError):
            derive_profile.derive(raw, "X-Y-Z", "GU_PROFILE_X")

    def test_refuses_non_nvidia_target(self):
        words = config_dwords(ids=0x10021682)
        with self.assertRaises(derive_profile.CaptureError):
            derive_profile.derive(capture(words=words), "X-Y-Z", "GU_PROFILE_X")

    def test_generator_matches_the_capture_firmware(self):
        """The drafter must read exactly what the discovery build writes."""
        boot = Path(__file__).resolve().parents[1] / "internal-boot" / "boot"
        probe = (boot / "probe.c").read_text(encoding="utf-8")
        diagnostic = (boot / "diagnostic.c").read_text(encoding="utf-8")
        probe_registers = {int(offset, 16) for offset in
                           __import__("re").findall(r"0x([0-9a-f]{6})", probe)}
        missing = sorted(name for offset, name in derive_profile.REGISTERS.items()
                         if offset not in probe_registers)
        self.assertEqual(missing, [], "probe.c no longer reads these registers")
        self.assertIn("EfiPciIoWidthUint32,0x08", probe.replace(" ", ""),
                      "probe must read the class code the drafter matches on")
        for token in ("console out=0x", "handle id=0x", "path-node raw=",
                      "pci config-dwords=", "pci config-status=0x",
                      "gop framebuffer=0x", "capture-complete=1",
                      derive_profile.MARKER, "GopGuid=EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID"):
            self.assertIn(token, diagnostic, token)
        # Protocol GUIDs are formatted by the capture itself, so the drafter's
        # lowercase GUID constants only hold while the hex alphabet stays one.
        self.assertIn('s[i]="0123456789abcdef"', diagnostic.replace(" ", ""))
        for token in ("probe-pci-handles=", "probe-target seg=0x", "probe targets=",
                      "cfg256 status=0x", "cfg dwords=", "mmio off=0x",
                      "prom sha256=", "probe class=0x"):
            self.assertIn(token, probe, token)


if __name__ == "__main__":
    unittest.main()
