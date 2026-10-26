# Unprofiled machine: read-only discovery

English | [Español](DISCOVERY.es.md) | [Portability gates](PORTABILITY.en.md) | [Internal boot](../internal-boot/README.md)

A write-enabled build compiles exactly one reviewed machine profile
([`machine-profile.h`](../internal-boot/unlock/machine-profile.h)). An
unprofiled card — for example an RTX 3060 (GA106, `10de:2503`, `2504`, `2507`)
— matches no profile, so `GuTargetConfig` and every later identity check refuse
it and no transaction can start. The way forward for such a machine is not to
relax those checks but to record what the machine actually is.

Discovery is that recording step. It builds one EFI application that reads the
machine and writes a text capture, then stops. It never writes PCI config,
MMIO, NVRAM or firmware variables, never enables bus mastering, allocates DMA,
resets the device or detaches a driver, and it has no card, board or display
identity to match, so it cannot reach a transaction even by accident: selecting
the profile in a write-enabled build is a compile error in [`port.h`](../internal-boot/unlock/port.h).

## Procedure

Prerequisites, all of them:

- a spare FAT32 EFI partition of at least 1 GiB that is **not** the Windows ESP
  (the internal-boot procedure in [INTERNAL-BOOT.en.md](INTERNAL-BOOT.en.md)
  describes creating one, and [DISCOVERY.es.md](DISCOVERY.es.md) works through a
  concrete shrink-and-create case);
- Secure Boot disabled (the image is unsigned), Fast Startup off
  (`powercfg /h off`) and `C:` **fully decrypted** — a suspended BitLocker
  volume still fails the staging check, which requires `VolumeStatus = 0`;
- one cold power-on, not a restart, so the card is in its pre-driver state.

From an elevated PowerShell in the repository root:

```powershell
# 1. Record the observation ESP identity; writes only internal-boot/local-config.json
.\internal-boot\Configure.ps1 -UnlockDriveLetter X -WindowsEspGuid <windows-esp-guid> -HardwareProfile discovery

# 2. Build the capture image (also stages OBSERVE.EFI under research/headless/build)
.\research\headless\build-observe.ps1 -UnlockDriveLetter X -WindowsEspGuid <windows-esp-guid> `
  -Clang <clang> -LldLink <lld-link> -HardwareProfile discovery

# 3. Stage it (no switches = observation mode), then add a menu entry at the end
.\research\headless\register-observe.ps1
.\research\headless\register-observe.ps1 -Register

# 4. Power off, boot the new entry once, return to Windows
#    Capture: \RTX3090-UNLOCK\DIAG00.TXT on the observation partition
```

Registration only appends a `{fwbootmgr}` entry and verifies that every existing
entry is byte-identical afterwards; it never sets `BootNext`, reorders or
reboots. Staging also creates `EFI\WindowsGPUUnlock` and `RTX3090-UNLOCK` on the
observation partition: the image writes its log inside the latter, and FAT32
cannot create a file in a directory that does not exist yet. It refuses to stage
`HEADLESS.EFI`/`R2-CONSOLE.EFI` modes here: the
observation branch is selected by passing neither `-HeadlessUnlock` nor
`-ConsoleR2`. The capture file name is a fixed constant in
[`handoff.c`](../internal-boot/boot/handoff.c) (`\RTX3090-UNLOCK\DIAG00.TXT`)
that predates generic discovery — on a non-3090 machine the directory name is
historical, the contents are not.

## From capture to a draft profile

```powershell
# The name comes from `Board` and `Bios` in internal-boot/local-config.json (SMBIOS),
# never from memory: a profile is one machine's contract and the name states it.
python tools\derive_profile.py --capture X:\RTX3090-UNLOCK\DIAG00.TXT `
  --name ASROCK-B450M-HDV-R4.0-P10.60-RTX3060 `
  --define GU_PROFILE_ASROCK_B450M_HDV_R4_0_RTX3060 `
  --output evidence\discovery-rtx3060\draft.json
```

The draft never overwrites (`--output` creates the file): delete it before
deriving again.

The drafter reads only what the discovery image writes — the same register
offsets, field spellings and GUID casing are asserted in
[`tools/test_derive_profile.py`](../tools/test_derive_profile.py) — and refuses
anything else: no marker, more than one capture section, an incomplete capture,
zero or several NVIDIA candidates, a non-NVIDIA or non-display function, a
64-bit or unassigned BAR0, a failed config read, missing WPR/PLM/selector
registers or a failed PROM digest.

`draft.json` contains the constants the capture can prove
(`GU_BOARD_ID`, `GU_BOARD_SUBSYSTEM`, `GU_BAR0_BASE`/`END`, `GU_CHIP_ID`,
`GU_DEVICE_MEMORY_SIZE`, `GU_PROM_SHA256`, `GU_ROOT_PORT_*`,
`GU_RTX_PATH_BYTES`) plus in `machine_profile_h` a ready-to-review block. It
carries `"authorizes_unlock": false` and a `pending_review` list on purpose:

- display-driver fingerprints the capture cannot identify (a console splitter
  agent the machine does not load) stay manual work; see below;
- cold selector semantics (entry SS0/SS1 for this exact card) must be confirmed
  against a rehearsal, not assumed;
- memory/WPR layout inputs need the first full transaction rehearsal;
- the new profile needs its own negative host tests before any write build
  (stage 4 in [PORTABILITY.en.md](PORTABILITY.en.md)).

## Display fingerprints

```powershell
python tools\derive_display.py --capture X:\RTX3090-UNLOCK\DIAG00.TXT `
  --images X:\RTX3090-UNLOCK `
  --agent GU_NVGOP=name:nvgop-ga1xx `
  --agent GU_EDID=guid:c7a7030c-c3d8-45ee-bed9-5d9e76762953
```

Each driver binding records its version, image size, stop address and device
path (a file name or a firmware-volume file GUID); the probe dumps the loaded
image next to the capture. The deriver pairs the two and reports the `.text`
section the image's own PE header declares — the range the release gate hashes at
`0x280` (nvgop) and `0x1000` (EDID driver). It refuses a selector that matches no
agent or several of them, a capture that skipped the dump, a dump whose size
disagrees with the capture, and a code range outside the image, and it is
asserted in [`tools/test_derive_display.py`](../tools/test_derive_display.py).

A capture is software evidence about one boot. It cannot prove freshness or
provenance, and agreement between a draft profile and a mock test still does not
establish GPU success.

## What discovery already records

| Item | Where |
|---|---|
| Console out/err/in handles, `ConOut`/`ErrOut`/`ConIn` device paths | `diagnostic.c` |
| Full handle graph with protocol GUIDs and open records | `diagnostic.c` |
| PCI identity, location and 64-dword config per display function | `diagnostic.c`, `probe.c` |
| GOP framebuffer base/size, and which PCI device owns each GOP | `diagnostic.c` |
| BAR0 base and read-only register reads (chip, FB size, WPR2, PLM, SS0/SS1, fuse) | `probe.c` |
| SHA-256 of the 1 MiB VBIOS PROM mirror | `probe.c` |

## Verified on this tree

These were run locally with LLVM/clang + lld, no GPU involved:

| Check | Result |
|---|---|
| `internal-boot/unlock/build.ps1` (default preflight) | builds, PE verify passes |
| `internal-boot/unlock/build.ps1 -ExperimentalUnlock -StockProfile entryLatchedSs1Full -InternalBoot` | builds, PE verify passes |
| `internal-boot/boot/build.ps1` (handoff) | builds, PE verify passes |
| `internal-boot/boot/build-diagnostic.ps1 -HardwareProfile b650m-3090fe` / `discovery` | both build, PE verify passes, different hashes |
| `tests/test_stock_selection.py` | 23 compile-time selector cases + 15 parameter rejections |
| host groups `port`, `preflight-lock`, `master-attributes`, `profile-lock`, `runtime` | pass |
| `python -m unittest test_derive_profile` | 8 tests pass, including the capture-seam test |
| pinned firmware assets vs `internal-boot/unlock/assets.json` | 5/5 size and SHA-256 match |

Not verified: any of it on hardware. `test-all.ps1` groups `checks`,
`preflight`, `sha` and the experimental transaction groups need the original
RTX 3090 `PROM.BIN` and preflight capture, which are not in this tree, so they
remain unexecuted here.

The discovery capture has now been taken once on a real unprofiled machine
(2026-10-25, ASRock B450M-HDV R4.0 P10.60 with an RTX 3060 12GB; see
[`evidence/discovery-rtx3060`](../evidence/discovery-rtx3060/README.md)). That
proves the cold state of one card. No transaction and no unlock has run on it.
