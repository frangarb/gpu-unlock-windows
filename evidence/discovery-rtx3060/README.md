# Discovery capture — 2026-10-25

One ASRock B450M-HDV R4.0 (BIOS P10.60), Ryzen without a console iGPU,
GeForce RTX 3060 12GB (GA106, `10de:2504`, subsystem `1043:8816`). The
observation image from `research/headless/register-observe.ps1` ran once from
its own ESP entry and returned to Windows.

| Item | Value |
| --- | --- |
| Capture | `DIAG00.TXT`, 416 683 bytes, `sha256 46d909e89eb981e9f0fe970b55cfbd542c04c1405d5624fe4d33d33816e0e2b7` |
| Image dumps | `IMG00..IMG25.BIN`, 26 loaded images referenced by driver bindings |
| Profile | `discovery` / `DISCOVERY-READ-ONLY`, read-only probe only |
| Draft | [`draft.json`](draft.json), `authorizes_unlock: false` |

The raw capture, the image dumps and the PROM contents are not distributed,
for the same reason as the other evidence directories: they contain this
machine's firmware layout and identity. `draft.json` carries everything the
capture proves in constants, plus its own SHA-256 so the claim stays checkable.

## Cold state

The nine registers the release pre-flight reads (`ColdOffsets` in
`internal-boot/boot/full-release.c`) hold, on this capture:

| Offset | Value | Pre-flight expects |
| --- | --- | --- |
| `0x000000` | `0xb76000a1` | `GU_CHIP_ID` |
| `0x118128` | `0x00008b8f` | `0x8b8f` |
| `0x118234` | `0x000003ff` | `0x3ff` |
| `0x110100` | `0x00000010` | `0x10` |
| `0x1fa828` (WPR2 high) | `0x00000000` | `0` |
| `0x823804` (FEAT_OVR_PLM) | `0xffffff8f` | `0xffffff8f` |
| `0x82381c` (SS0) | `0x62130012` | not open, not unlocked, not `0xbadf` |
| `0x823820` (SS1) | `0x00000002` | `<= 15` |
| `0x1183a4` (FB MiB) | `0x00003000` | `GU_DEVICE_MEMORY_SIZE` |

Every write-enabled build starts from this gate, so the card was cold and
untouched by `nvlddmkm.sys` when it was recorded: WPR2 is off and the
selectors still carry their boot values. That is the precondition the whole
transaction needs, and this capture satisfies it.

`SS0` and `SS1` are this card's own values (`0x62130012`, `0x2`); they must not
be copied from another profile. The unlocked targets stay `0x88888888` / `0x8`.

## Display drivers

`python tools\derive_display.py --capture ... --images ... --agent
GU_NVGOP=name:nvgop-ga1xx --agent GU_EDID=guid:c7a7030c-...` reads these off the
capture and the dumped images. The code digest is the `.text` section the PE
header declares, which is the same range the release gate hashes (`0x280` for
nvgop, `0x1000` for the EDID driver).

| Macro | nvgop here | Reviewed GA104 profile |
| --- | --- | --- |
| `VERSION` | `0x60010` | `0x60010` |
| `IMAGE_SIZE` | `0x26ae0` | `0x26ae0` |
| `STOP` | `0x678` | `0x678` |
| `TEXT_BYTES` | `0x20d33` | `0x20d33` |
| `TEXT_SHA256` | `615b37a7…847b2b` | `615b37a7…847b2b` |

This board ships the same `nvgop-ga1xx` image as the reviewed RTX 3070 Ti
machine, byte for byte, and loads it by file name, so `Profile()` already
accepts it and no new nvgop constants are needed.

The EDID/mouse runtime driver is a *different* build:

| Macro | This machine | Reviewed GA104 profile |
| --- | --- | --- |
| image | `IMG07.BIN`, file GUID `c7a7030c-c3d8-45ee-bed9-5d9e76762953` | same GUID |
| `GU_EDID_IMAGE_SIZE` | `0x8000` | `0x9000` |
| `GU_EDID_STOP` | `0x1478` | `0x14d4` |
| `GU_EDID_TEXT_BYTES` | `0x2050` | `0x37da` |
| `GU_EDID_TEXT_SHA256` | `f803c0023b2e3f5c7a1998a79bba03065b6953de3ecce3406d51b62980cf33fd` | `a015d52f…` |

### The console chain this board actually has

Read from the open-protocol graph of `DIAG00.TXT`, on the target GOP handle
`0xb599bc98`:

| Role | Edge on the target GOP | Driver image |
| --- | --- | --- |
| console text | `SimpleTextOut` `BY_DRIVER`, plus `BY_CHILD_CONTROLLER` for the console handle `0xb7563998` | `OutFile` `628a497d-2bf6-4264-8741-069dbd3399d6`, `0x5c60`, v`0x10`, stop `0xf30` |
| graphics | `GraphicsOutput` `BY_DRIVER` | `GfxFile` `43e7abdd-e352-4cfb-a230-4cdc1d350e5c`, `0x3a80`, v`0x10`, stop `0xa38` |
| EDID + input | `EdidDiscovered` `BY_DRIVER`; the same driver registers the console's input protocols | `c7a7030c-c3d8-45ee-bed9-5d9e76762953`, `0x8000`, v`1`, stop `0x1478`, runtime code |

So this board loads the same AMI text-out and gfx drivers the other profiles
pin (`GU_CONSOLE_TEXT_*`, `GU_CONSOLE_GFX_*` now carry this board's builds),
and adds a third owner: the version-1 EDID/mouse runtime driver that supplies
the console's input protocols. There is no `ComboFile` aggregate and no second
display adapter, so `GU_CONSOLE_AGGREGATE` stays off and the only GOP is the
target's, which the preflight accepts through `GU_CONSOLE_ON_TARGET`.

An earlier revision of this file said the two console drivers were absent. That
was wrong: the capture shows both, and the third owner is what the detach plan
has to account for.

## Console-chain verification build

`research/headless/build-console-verify.ps1` compiles the single-RTX diagnostic
for this profile with `GU_CONSOLE_VERIFY_ONLY`: it walks the live graph, pins the
display route and the three owners above by image fingerprint (size, `Stop`
offset, binding version, code type, runtime type for the EDID driver), records
the stage name in `\RTX3090-UNLOCK\CVnn.TXT` and then starts Windows. It never
detaches a driver, never writes GPU state and cannot unlock.

```powershell
.\research\headless\build-console-verify.ps1 -Clang .\.tools\llvm\bin\clang.exe `
  -LldLink .\.tools\llvm\bin\lld-link.exe -Stage
.\research\headless\register-observe.ps1 -ConsoleVerify -Register   # elevated
```

Staged image: `\EFI\WindowsGPUUnlock\CONSOLE-VERIFY.EFI`, 19 968 bytes,
`sha256 bb1201979fb245c0129866374d8a87694add545c26ef0f3f6289dfc8944a7138`. The
`-Stage` step needs no elevation; the boot entry does, and
`register-observe.ps1` refuses to overwrite a different image at that path.

## First console-verify attempt, 2026-10-25

`CONSOLE-VERIFY.EFI` (`sha256 b483e11c…85e`) ran once from its own firmware
entry. It wrote `CV00.TXT` (11 380 lines, 796 kB) and stopped at

```
console-prepare-preflight status=0x8000000000000003
```

`0x8000000000000003` is `EFI_UNSUPPORTED` from the preflight itself: no
`detach-*` record exists, so nothing was detached, no register was written and
no NVRAM was touched. Windows was reachable afterwards, and the screen simply
stayed on the banner because that build disables its own output before the
preflight and never reached Windows. One defect explains it, and it is fixed:

1. `GU_RTX_PATH_BYTES` held the 28-byte PCI-only path. `DisplayRoute` compares
   the 36-byte boot-display endpoint path (ACPI root, root port, the card, its
   ACPI ADR endpoint, END), which is what the capture records on the GOP handle,
   so the very first display check refused. The constant now carries all 36
   bytes and a `_Static_assert` refuses a truncated one at build time. The
   drafter (`tools/derive_profile.py`) was the source: it emitted the PCI
   handle's path, and now emits the target GOP's display path.

## Second attempt, 2026-10-25

That fix carried the preflight past `Displays()` and `Snapshot()` — the display
route now matches — and it stopped one stage later:

```
console-preflight-consumers status=0x800000000000000f
```

`0x800000000000000f` is `EFI_ACCESS_DENIED` from `Consumers()`, and again no
`detach-*` record follows, so nothing was released. The cause was a change made
in this same round, not the board: the third console owner had been moved to the
console handle, keyed on the `8d59d32b…` protocol found there. That is a
different AMI protocol. `EFI_EDID_DISCOVERED_PROTOCOL_GUID` is `1c0c34f6…`, and
on this machine it sits on the **PCI handle**, opened `BY_DRIVER` by the
runtime EDID/mouse driver with that handle as controller — exactly the shape
`Consumers()` already checked. The check is back on the PCI handle; only the
truncated path constant was ever wrong.

The staged image is now `sha256 bb120197…4a38` (19 968 bytes, still
`CanDetach=false`, `CanWriteGpu=false`) at the same ESP path, so the existing
menu entry runs it. Earlier builds are kept as `CONSOLE-VERIFY.R1.EFI` and
`CONSOLE-VERIFY.R2.EFI`. The verification build no longer silences its own
output: run 2 ended on a readable `HANDOFF STOPPED` banner instead of a frozen
screen, and that banner now carries the failing status, because the last checks
run after the log is closed.

## Third attempt, 2026-10-25: the chain verifies

`CV03.TXT` ends with all four stages and no failure:

```
console-preflight-alive status=0x0000000000000000
console-prepare-result  status=0x0000000000000000
```

The display route, both console consumers and the runtime EDID owner matched
their pinned fingerprints on the real machine, nothing was released, and the
image started Windows itself — no `handoff-stopped` line follows because the log
is closed before the handoff. The read-only console gate for this board is now
hardware-verified.

## Console-release rehearsal

`research/headless/build-r2.ps1 -HardwareProfile asrock-b450m-rtx3060` builds the
release-only experiment (`R2-CONSOLE.EFI`, `CanDetach=true`, `CanUnlock=false`,
`CanWriteGpu` still absent). Its host replay runs the real `prepare-console.c`
over this machine's capture (`DIAG00.TXT`, 505 handles, 162 ownership records)
and passes 575 checks: both console consumers are released, the graph after each
step must equal the reviewed one, and late GOP/config/input/graph drift still
stops the handoff.

This board's console child belongs to the text-out consumer, so releasing it can
take the console and its input with it. `GU_CONSOLE_LEAVES_WITH_CONSUMERS` makes
that expected: after a release the console identity is only asserted while the
same console is still the system console, and the GPU/graph checks always run.
Before this round the rehearsal would have refused at its own first check.

Three research tools stopped being 3090-only to make that possible:
`analyze_capture.py` classifies any NVIDIA display controller, and
`make-console-fixture.py` / `build-r2.ps1` derive the roles and take the profile
from the capture instead of a hardcoded id.

## Release rehearsal: green on hardware

`CONSOLE-RELEASE.EFI` (`sha256 6343154e…d9f4`) ran from its own firmware entry and
`R2C00.TXT` records every step at zero:

```
console-preflight-alive                0x0000000000000000
detach-rtx-textout-intent/return       0x0000000000000000
detach-textout-verified                0x0000000000000000
detach-rtx-graphics-console-intent/…   0x0000000000000000
detach-graphics-console-verified       0x0000000000000000
stage2a-success-no-unlock-no-gop-removal 0x0000000000000000
console-prepare-result                 0x0000000000000000
```

No `handoff-stopped`: the image closed its log and started Windows, which came
up. The two captures in the same log are complete (`handles status=0 count=0x1f9`
in both) and record what the release did and did not touch:

- Handle count is unchanged (505 before and after) and the console handle
  `0xb7563998` is still the system console. On this board the release takes the
  text-out and gfx drivers off the target but leaves the console handle itself
  in place, so the image kept writing to the screen instead of going dark.
- Target GOP `0xb599bc98`, exactly three edges changed: the `SimpleTextIn`
  `BY_DRIVER` open (`0x10`, agent `0xb755dc18`) is gone, the `BY_CHILD_CONTROLLER`
  open (`0x08`) that same agent held on the console handle `0xb7563998` is gone,
  and the GOP `BY_DRIVER` open (`0xb755fc18`) is gone — the GOP protocol now has
  only this image's `BY_HANDLE_PROTOCOL`. Its geometry is unchanged.
- Untouched on the same handle: `EdidDiscovered` still carries the runtime EDID
  driver's `BY_DRIVER` open (`0xb7cd8d98`) plus nvgop's passive `GET_PROTOCOL`
  query (`0xb7564e98`), and the four `DevicePath` child opens.
- PCI `0xb7ca5918`: nvgop `0xb7564e98`, binding version `0x60010`, loaded from
  that same PCI handle, byte-identical fingerprint.

So this board survives both console consumers being released, and the two owners
a write path still has to release are exactly the remaining ones: the runtime
EDID/mouse driver and nvgop. Note the `EXCLUSIVE` open the EDID driver holds on
`EdidDiscovered`; stopping nvgop has to uninstall a protocol that open still
references, which is the first thing the next rehearsal answers.

## Full release rehearsal (`RELEASE-FULL.EFI`)

The remaining two owners are released by the same code the write path uses, in
the same order, with no unlock and no register write:

```powershell
.\research\headless\build-release-full.ps1 `
  -Clang .\.tools\llvm\bin\clang.exe -LldLink .\.tools\llvm\bin\lld-link.exe
.\research\headless\register-observe.ps1 -ReleaseFull -Register
```

`76abffb1…bcf2`, 32 256 B, `CanUnlock=false CanWriteGpu=false`, log
`\RTX3090-UNLOCK\R2C##.TXT` (it shares the console-prepare log prefix because it
is a `GU_CONSOLE_PREPARE` build). Flow: console consumers (1-2) → runtime
EDID/mouse driver (3) → nvgop (4) → PCI decode restore → cold verification →
Windows.

Two things this board needed in `full-release.c`, both compile-time:

- `Alive()` calls now pass `GU_CONSOLE_LEAVES_WITH_CONSUMERS`. The full-release
  path stopped compiling when `Alive()` gained its third parameter; the callers
  were left at two arguments.
- `NothingLeft()` replaces `AmdOnly()` where the other profiles assert an AMD
  console survives. This machine has no second display, so after stage 4 the
  only correct state is zero GOP handles; the 3090 and B660M branches are
  untouched and all three still compile.

## Full release passed on hardware (`R2C01.TXT`)

The same image ran and released every owner, restored decode and verified the
cold state. Every recorded step is zero, including the two the rehearsal exists
for:

```
full-release-preflight                    0x0000000000000000
detach-rtx-edid-intent-shared-pointer-pauses 0x0000000000000000
detach-edid-return / edid-detach-verified 0x0000000000000000
detach-nvidia-gop-intent / return         0x0000000000000000
nvidia-detach-verified                    0x0000000000000000
pci-decode-restore-intent-io-mem-only     0x0000000000000000
pci-decode-restore-result                 0x0000000000000000
full-release-ready-for-original-unlock    0x0000000000000000
console-prepare-result                    0x0000000000000000
```

No `handoff-stopped`, both captures complete, Windows came up. So the `BY_DRIVER`
open the EDID driver holds on `EdidDiscovered` did not block nvgop's stop, and the
decode restore found the IO/MEM bits nvgop had cleared and put them back.

That is the last prerequisite `machine-profile.h` listed for this profile, so the
write build now exists: `-DGU_EXPERIMENTAL_3090`/`-DGU_FULL_UNLOCK` are allowed
for it, and `research/headless/build-write-3060.ps1` builds the child
(`7dd8853e…cf08`, 67 584 B) plus the wrapper (`a54d3c17…d392`, 36 352 B,
`CanUnlock=true CanWriteGpu=true`), staging-free.

Staged and registered as F8 `GPU 3060 UNLOCK - HEADLESS` (`{fa22ef4d-d0ba-11f1-bec7-eb55eeb2dd8a}`,
last in the menu, default order untouched): `\EFI\WindowsGPUUnlock\WRITE3060.EFI`
plus its child `\EFI\WindowsGPUUnlock\UNLOCK-HEADLESS.EFI`, which the wrapper hashes
before `LoadImage` and only then runs.

## First write run: stopped at the assets, nothing written

`HLS000000.TXT` / `HLS000001.TXT` (two identical attempts) released all three
owners and passed every gate up to arming:

```
full-release-ready-for-original-unlock   0x0000000000000000
automatic-unlock-start-Esc-cancels       0x0000000000000000
original-unlock-return                   0x800000000000000e
```

The child's own `AUTO000000/REPORT.TXT` shows where it stopped:

```
CHECK stage=cold-state status=0
CHECK stage=assets     status=0x800000000000000e
FINAL status=0x800000000000000e stage=assets attempted=0 driver_release=0 clean=1
```

`0x…0e` is `EFI_NOT_FOUND`: the five firmware assets the child reads from
`\RTX3090-UNLOCK\ASSETS` were never staged on this ESP, so it stopped before
arming (`attempted=0`), before any driver release inside the child, and left the
card clean. Nothing was written and Windows was recoverable with a power cycle.

`-WriteFull` now stages those assets too, hash-checked against
`internal-boot/unlock/assets.json` and read back, with an 84 MB `gsp_ga10x.bin`
among them.

## Unlock ran and reported success

`HLS000002.TXT` + `AUTO000002/REPORT.TXT`, third attempt, every gate green:

```
CHECK stage=assets / arming / armed-config / armed-display   0
FWSEC WPR2: low=0x2ffe000 high=0x2ffee00 expected_page=0x2ffe00
selector intent: SS0target=0x88888888 SS1entry=0x2 SS1target=0x8 (one SS1 write)
pre-FLR selectors: ss0=0x88888888 ss1=0x8
PCIe FLR returned: result=0
post-FLR SEC2 reset released ... WPR2=1ffffe00:00000000 SS0=88888888 SS1=00000008
transaction result=0 containment=0 started=1 quiesced=1 fault=0 FLR=1
FINAL status=0 stage=transaction attempted=1 driver_release=0 clean=1
```

The wrapper then reported `original-unlock-return 0 status=0`, `verify-complete
0`, and started Windows; the card came up under driver 621.01 as an RTX 3060.

Throughput on that boot, `research/bench/tensor_rate.cu` at n=4096:

| Path | TFLOPS |
| --- | --- |
| FP16 in, FP32 accumulate | 45.1 / 47.7 |
| TF32 in, FP32 accumulate | 23.4 / 24.9 |
| FP32 SIMT | 8.0 / 7.9 |

Those are the full-rate figures for a GA106, so the selectors survived the FLR
and the driver's own initialisation. The locked baseline is still missing: it
needs one cold boot straight into Windows without the unlock entry, then the
same probe (procedure in `research/bench/README.md`).

Note the cold selectors differ between boots (`SS0=0x62130012` in the preflight
and the first two attempts, `0x60130010` in the run that unlocked). That is why
the stock profile is `entryLatchedSs1Full`: it latches whatever the cold entry
reports instead of pinning a constant.

## Read-only preflight for this profile

The profile `ASROCK-B450M-HDV-R4.0-P10.60-RTX3060` still has no write-enabled
build: `machine-profile.h` refuses `GU_FULL_UNLOCK` and `GU_EXPERIMENTAL_3090`
for it until the detach rehearsal for those three owners has run on hardware.

```powershell
.\internal-boot\unlock\build.ps1 -Clang .\.tools\llvm\bin\clang.exe `
  -LldLink .\.tools\llvm\bin\lld-link.exe `
  -HardwareProfile asrock-b450m-rtx3060 -InternalBoot
.\research\headless\register-observe.ps1 -Preflight            # stage
.\research\headless\register-observe.ps1 -Preflight -Register  # menu entry
```

`-InternalBoot` only widens which media the log accepts, so the image can run
from this internal ESP instead of a USB stick; it cannot arm anything. The
preflight stops after `diagnostic-cold-state`, writes `REPORT.TXT` under
`\RTX3090-PREFLIGHT\RUNnn\` and returns to the firmware. Boot it from the F8
menu after a full power-off (a restart leaves WPR2 up and `cold-state` fails, by
design). Removing the entry: `bcdedit /delete` the id in
`research/headless/preflight-registration.local.json`.

Because this board has no second adapter, the read-only display gate accepts a
single GOP whose device path equals the target's own (`GU_CONSOLE_ON_TARGET`);
the iGPU console rule of the original machine is unchanged for every other
profile. Registered image: `\EFI\WindowsGPUUnlock\PREFLIGHT.EFI`,
56 320 bytes, `sha256 577d9cc5a3a3081a645cf76c4eb3229baa0fd571c1972fa44250beee1ce364c2`,
entry name `GPU 3060 Preflight - NO WRITE`, last in the F8 menu.

## Preflight run on this machine (2026-10-25)

The registered read-only image (`PREFLIGHT.EFI`, 56 320 bytes,
`sha256 577d9cc5…364c2`) ran three times from its own F8 entry and returned to
Windows each time. The logs are 1 971 bytes each and differ only in the `RUNnn`
line, so the run is deterministic:

| Run | sha256 |
| --- | --- |
| `RUN00` | `c66f361a31d215667c80726b06c361e0af885c196493acb070a86a83c696de07` |
| `RUN01` | `604830f0d9927b9bdb00b1d445ef6d667f0edf67cbee5f7cd77eae3c82dcc95d` |
| `RUN02` | `8506b0338ef80ea946792163bd715d3355d8cf933505e150c34a1ab9116dad2e` |

Every gate that this profile pins matched on hardware:

| Gate | Observed |
| --- | --- |
| `secure-boot`, `watchdog` | `status=0` both |
| PCI enumeration | 38 handles, 1 `10de:2504` match, target `0:1:0.0`, `checks=1` |
| config space | 256 bytes, class `0x030000a1`, subsystem `1043:8816`, `pcicaps` `pm=0x60` `pcie=0x78` `msi=0x68` `msix=0` |
| BAR0 | `0xfb000000`–`0xfbffffff`, length `0x1000000`, translation `0`, type `0` |
| display | 1 GOP, `route=2`, `console=0`, `f800000000`, 6 291 456 bytes, 1366x768 stride 2048, `valid=1` |
| PROM | `live PROM hash matched=1` |
| cold state | `chip=0xb76000a1` `plm=0xffffff8f` `gfw=0x8b8f/0x3ff/0x10` `WPR2_HI=0` `SS0=0x62130012` `SS1=0x2` `memory=0x3000` (12 GiB) |

These are the same card and the same cold state as the discovery capture: `draft.json`
records `chip 0xb76000a1`, `feat_plm 0xffffff8f`, `ss0 0x62130012`, `ss1 2`,
`wpr2_hi 0`, `bar0_base 0xfb000000` (16 MiB), `fb_mb 12288` and the same PROM
hash, and the preflight reproduces every one of them.

`FINAL status=0x8000000000000006 stage=diagnostic-cold-state attempted=0
driver_release=0 clean=1`. That status is `EFI_NOT_READY`, which is this
read-only profile's designed terminal result: the cold-state gate reports
`baseline=UNKNOWN` for every non-experimental build instead of pinning a
baseline, so it can neither pass nor fail. Nothing it read disagrees with the
tables above.

Two things a reader of the log should not misread:

- The banner still says `RTX3090 AMD read-only cold-state preflight`: that string
  predates this profile and is shared by every preflight build. The image is
  registered by hash and `register-observe.ps1` refuses to overwrite a
  different one, so the label was left alone rather than desyncing the entry.
- `msix=0` is the linked-list walk, not a missing capability: the chain ends at
  the `0x09` vendor cap (`0xb4`), while MSI-X sits at `0xc8` (`0x00050011`),
  which `ConfigCheck` already requires by offset.

## Firmware assets are family-level, not per-card

The pinned transaction assets already cover GA106:

- `kgspGetBinArchiveBooterLoadUcode` maps `GA102 | GA103 | GA104 | GA106 | GA107`
  to a single archive (`g_kernel_gsp_nvoc.c`, generated constructor). The pinned
  `booter_load_ga102.bin` is therefore this card's SEC2 booter; nothing has to be
  extracted from `roms/GA106.rom` to build the transaction.
- The V67 payload is derived from the GA10x GSP firmware (`assets/_gen/generate_v67.py`),
  which is the same family archive for every GA10x part.
- What this card contributes is verification data, not code: the PROM hash above,
  the fuse read at `0x00824140` = `0x3`, and the cold PLM/selector baselines.
  `roms/GA106.rom` is an NVFlash container holding this card's VBIOS at `0x9200`;
  it lets the PROM hash be reproduced offline.

## What this capture cannot establish

- The text-out/GOP splitter fingerprints for a write-enabled build: the agents
  the aggregate path names do not exist on this machine (see above).
- Freshness and provenance: a text file cannot prove which machine produced
  it. The registration and the image hash in `research/headless/` are the only
  local record.
- Any unlock outcome. No transaction has run on this card.
