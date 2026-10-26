# Changes

## 2026-10-25 — one-time boot arm, baseline in the window, honest permissions

- `-Activate` also arms the next start in the firmware's own one-time slot
  (`BootNext`, read back after writing), so the unlock runs without the F8 menu
  and without touching the boot order; Fast Startup goes off for that start and
  `-Deactivate` restores it. A firmware refusal keeps the F8 entry and says so.
- `-Restart` and the window's RESTART FOR UNLOCK restart in 20 s with the slot
  armed; the window asks after activation instead of trusting memory.
  `-Activate -Restart` does both without prompting.
- Reading the unlock partition now reports that it needs administrator, which is
  what Windows does: the ESP is hidden and `Get-Volume` returns a volume with no
  path. It no longer claims the partition is the wrong one; the boot-entry and
  Secure Boot rows distinguish "unknown" from "off". CLI errors print one line
  and exit 1 (usage errors 2).
- Window: BASELINE button with a measure / set-by-hand / forget dialog, rows for
  administrator and next start, and colour by consequence (green passes, red
  blocks, orange unknown). VERIFY, LOGS and every write path ask for elevation;
  MEASURE stays unprivileged.
- Window contrast: text colours now clear 8:1 on white (was 5:1), the value
  rows are 9.75 pt, buttons are flat with a visible border, and a rule separates
  the state rows from the actions. A refused UAC prompt keeps the window open
  with a `Cancelled: ...` line instead of a .NET error dialog; a thread-exception
  handler covers any other handler failure.
- Not verified yet: this board's handling of `BootNext` (one restart is the
  test).

## 2026-10-25 — GA106 RTX 3060 written and unlocked; window and baseline recorder

- Second machine completed the whole chain and **wrote the unlock**: ASRock
  B450M-HDV R4.0, BIOS P10.60, Ryzen without an iGPU, ASUS RTX 3060 12GB
  (`10de:2504`, subsystem `1043:8816`). The console lives on the target card,
  so three owners are released instead of two and nothing is left to display
  with. Transaction `result=0` with SS0 `0x88888888` and SS1 `0x8` surviving the
  PCIe FLR; Windows starts on driver 621.01 and the card measures 45-48 TFLOPS
  FP16 / 23-25 TF32, the full rate for this part.
- Four rehearsals preceded the write: read-only discovery capture, console
  verification, console-consumer release and full release with EDID/nvgop
  release and PCI decode restore. Evidence, all logs and the register tables
  are in `evidence/discovery-rtx3060/`.
- New GA106 machine profile `ASROCK_B450M_RTX3060` (console on the target, own
  nvgop/EDID fingerprints). `tools/derive_profile.py` and
  `tools/derive_display.py` derive profiles from a local capture instead of
  hand-edited constants, and both refuse ambiguity.
- `GpuUnlock.ps1` is now a function library with the same CLI behaviour and
  exit codes, plus `-Status` (text or `-Json`), `-Baseline` and `-Gui`.
  `GpuUnlock.cmd` opens the window by double click. Mutations keep the existing
  step/verify/rollback policy.
- `-Baseline` records the locked rate once per machine in
  `%ProgramData%\WindowsGPUUnlock\baseline.json`; it refuses to save a number
  measured on an unlocked card, and `-Verify` then reports the measured gain.
- The window shows the state read-only (board, card, Secure Boot, boot entry,
  last attempt, transaction) and the measured rate, runs the same functions as
  the console and asks for administrator only for activate/deactivate.
- Boot cleanup: development entries removed and the surviving entry renamed;
  the ESP now holds only the write pair and the assets, with the removed EFI
  images and logs archived under `%ProgramData%\WindowsGPUUnlock\Final\`.

## 2026-10-24 — v0.3.1 variable headless display-child discovery

- Fixed preflight rejection when ASUS firmware exposes three RTX display
  children instead of exactly two. The wrapper now discovers and validates up
  to four unique RTX display children, then releases each guarded EDID
  connection before the NVIDIA GOP.
- The rebuilt wrapper completed automatic unlock and Windows handoff on the
  same system. The user observed the RTX display go dark during release and
  return after Windows started. No new performance benchmark was run for this
  build.
- Release remains source-only. Do not publish local EFI binaries, firmware,
  PROM captures, raw boot logs, partition identifiers or machine-local config.

## 2026-10-24 — GA104 RTX 3070 Ti machine profile (second verified machine)

- Added compile-time machine profiles in internal-boot/unlock/machine-profile.h:
  -DGU_PROFILE_B650M_3090FE (default, original verified machine) and
  -DGU_PROFILE_B660M_3070TI. PCI/subsystem, BAR0, chip/VRAM, PROM, root-port,
  display-path and all EFI driver fingerprints are profile constants; a build
  remains exact-machine and a user-editable file never selects them.
- New aggregate-console headless topology (GU_CONSOLE_AGGREGATE) for hosts
  without a second display GPU: nvgop owns the target PCI function, the AMI
  GOP combo splitter serves the console through an aggregate GOP, and the
  wrapper releases the nvgop/EDID/combo/text chain instead of the two-child
  nvgop console used on the B650M profile.
- Hardware verified on TUF GAMING B660M-E D4 BIOS 4003, i7-12700F, MSI
  RTX 3070 Ti: one headless unlock transaction, direct Windows start with
  display recovery, cuBLAS GEMM n=4096 medians FP16 88.7 / BF16 88.6 TFLOPS.
  S3 sleep still invalidates the unlock; no resume path exists.
- internal-boot/unlock/build.ps1, research/headless/build-unlock.ps1,
  Configure.ps1 and Headless.ps1 take -HardwareProfile (default b650m-3090fe);
  installer board/BIOS gates follow the built package profile. The B650M
  profile keeps its original code paths and constants behind the same checks.
- Added a read-only diagnostic probe (probe.c, -DGU_DIAGNOSTIC_PROBE) used to
  fingerprint new platforms; it performs no writes and is compiled into
  diagnostic/headless wrapper builds.

## 2026-10-24 — v0.3.0 headless internal handoff, public setup and recovery

- Verified one internal headless boot on the exact ASUS BIOS 3057 / RTX 3090 FE
  system: RTX GOP 1 → 0, one successful unlock transaction, direct Windows
  return and three Tensor benchmark trials. FP16/BF16 medians were
  124.969948/128.931534 TFLOPS. No active AMD display was required; the CPU
  still has an iGPU, and other boards/CPUs/headless USB are not validated.
- Added a separate headless compile profile: two reviewed EDID children, exact
  NVIDIA ownership release, zero-physical-GOP policy, file-only child logging,
  TPL-protected observations and original PROM/cold/containment/cleanup gates.
- Added public configuration/build provenance, stage/register/confirmed automatic
  promotion and Windows-first recovery. Registration preserves default priority;
  promotion explicitly orders Headless then Windows and saves Fast Startup
  recovery data before mutation. Source/include/config/asset contracts are rechecked.
- Rewrote English/Korean README and setup guides, retained distinct legacy USB
  and AMD-display paths, and published sanitized headless evidence. Firmware,
  PROM/BIOS, private partition configuration and generated EFI images stay local.
- Original manual child, automatic child and automatic wrapper EFI hashes remain
  identical. Public installer mutation paths are mock-tested; cross-machine
  registration, repeated cold-boot reliability and sleep/resume remain unverified.

## 2026-10-23 — v0.2.0 internal handoff and experimental automatic boot

- Added a separate `internal-boot/` source tree; original USB release source and EFI remain unchanged.
- Reviewed RTX console/EDID/GOP release, original IO/MEM restoration without BME, and direct Windows handoff. Original unlock transaction and card guards retained.
- Discovered display ADR per boot while pinning PCI ancestry, GPU identity and subsequent whole-path checks. Allowed only old CED/URD status clearing after successful unlock; other config changes still fail.
- Added precise handoff failure stages and config differences. Internal manual handoff and Tensor performance were verified on one BIOS 3057 system.
- Added a separate compile-time automatic child with two Esc windows, strict input failures, fresh hardware gates and rejection of unexpected owners. Automatic firmware boot remains unverified.
- Added local partition configuration, builds, stage/manual/automatic/recovery scripts and bilingual walkthroughs. Private partition GUIDs, firmware/PROM and raw boot graphs are excluded.
- Public-source builds reproduced all four locally installed EFI hashes. Public installer registration/promotion remains experimental; host and policy tests are not hardware evidence.

## 2026-10-23 — International documentation and compatibility inventory

- English default README and complete English USB, assets, build, compatibility, benchmark and results guides; Korean README and guides remain available through language links.
- Added a local read-only Windows model/version inventory and manual compatibility issue form. Private identifier fields and PnP instance suffixes are excluded; reports never authorize unlock.
- Added a staged portability design distinguishing host discovery, GPU policy, software tests and hardware evidence. This update adds no new write-enabled EFI profile or hardware support.
- USB package readme links both languages. Refreshed the public source inventory for these documentation/tool additions; successful EFI and its corresponding C/header hashes are unchanged.

## 2026-10-20 — Windows GPU UNLOCK public case study

- Base: rough2515-hub/rtx3080-unlock-public at a08254d269af30ace9e57237abd3d8e6c261e8f5; original core and licenses retained.
- Local changes made 2026-10-19/20: exact RTX3090 24GiB and AMD iGPU identity checks, memory layout, firmware ownership/PCI access checks, default read-only mode, explicit experimental profiles, immutable entry-selector latch and one SS1 write for entryLatchedSs1Full, phase guards, corresponding host mock tests.
- Modified upstream files: unlock/app.c, app_io.c, build.ps1, checks.c, checks.h, port.c, port.h, test-all.ps1, tests/test_app.c, test_checks.c, test_efi_transaction.c, test_master_attributes.c, test_pe.py, test_port.c, test_sha256.c, vendor/unlock_610.c. Additional RTX3090 tests are under unlock/tests/.
- Public packaging only: portable LLVM defaults, configurable MSVC environment and PE negative tests that inspect the selected profile rather than requiring a separate preflight build; no further GPU transaction changes. Success EFI is tied to hashes of the corresponding C sources and headers. Changed source files carry dated notices; C notices share an existing line to preserve diagnostic __LINE__ values and reproduce the successful EFI byte for byte.
- Added Korean USB/ASUS boot handoff guide, measured results and benchmark sources. Changed benchmark device selection to RTX3090, added inspect-only mode, and kept the original GEMM helper/measure path.
- The release deliberately excludes NVIDIA firmware, drivers, CUDA DLLs, original PROM dumps, private paths, credentials and unrelated repositories.
- Direct Windows chainload and internal disk automatic boot are not implemented.
