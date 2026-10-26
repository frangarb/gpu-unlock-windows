# Verified hardware and route-specific requirements

**English** | [한국어](COMPATIBILITY.ko.md)

The current implementation checks more than a model name. Three machines have
recorded successful internal headless boots; the GA106 one below also completed
written unlock transactions. Builds compile for exactly one
reviewed profile selected at build time in
[internal-boot/unlock/machine-profile.h](../internal-boot/unlock/machine-profile.h);
other GPUs or platforms remain unsupported.

## Profile 1: ASUS TUF B650M / RTX 3090 FE (original)

| Common GPU/platform item | Validated value |
|---|---|
| Card | NVIDIA RTX 3090 Founders Edition, 24 GiB |
| PCI identity | `10de:2204`, subsystem `10de:1454` |
| GPU BDF | `0000:01:00.0` |
| Chip / VRAM register | `0xb72000a1` / `0x6000` MiB |
| BAR0 | `0xf5000000`, 16 MiB |
| PROM SHA256 | `8ea297373e9e5d3600ff41ad9fae88f2d14c98c017d100669f7333981da673b4` |
| Motherboard / BIOS | ASUS TUF GAMING B650M-PLUS WIFI / 3057 |
| CPU | AMD Ryzen 7 7800X3D |
| Recorded Windows / driver | Windows 11 Home 26200 / NVIDIA 617.14 |
| UEFI / Secure Boot | x64 / disabled |
| Selector profile | `entryLatchedSs1Full`; targets SS0 `0x88888888`, SS1 `0x8` |

These are documented successful values, not an authorization list. Code also
checks configuration/capabilities, PROM, cold state, driver code, ownership,
DMA cleanup and failure containment. Internal EFI builds additionally contain
the user's own Windows/dedicated ESP GUID configuration.

| Route | Display policy and validation |
|---|---|
| Legacy USB / ordinary internal builds | Preserve AMD physical GOP, PCI `1002:164e`, subsystem `1043:8877`, BDF `0000:0c:00.0` and validated display ancestry |
| Internal headless profile | One RTX physical GOP before release, zero physical GOP afterward; stable console/input interfaces, protected ownership graph, file-only child logging |
| Headless USB | Not tested; the ordinary USB EFI retains AMD requirements |

The headless test had all monitors on RTX and no active AMD GOP. The 7800X3D
still contains an iGPU; BIOS disablement is not established by a missing GOP.
The B650M profile was not re-verified after the profile split; its code path
is preserved behind the same build-time checks.

## Profile 2: ASUS TUF B660M-E D4 / RTX 3070 Ti (aggregate console)

A second hardware-verified headless profile: Intel host **without an iGPU**,
so the NVIDIA driver owns the console GOP and the AMI GOP combo splitter
serves the system console on top of it. The wrapper releases the nvgop/EDID/
splitter ownership chain, runs one unlock transaction and chain-loads Windows
Boot Manager without reset.

| Common GPU/platform item | Validated value |
|---|---|
| Card | MSI RTX 3070 Ti, 8 GiB (GA104) |
| PCI identity | `10de:2482`, subsystem `1462:5052` |
| GPU BDF | `0000:01:00.0` |
| Chip / VRAM register | `0xb74000a1` / `0x2000` MiB |
| BAR0 | `0x82000000`, 16 MiB |
| PROM SHA256 | `f429aa1d5f0f18d11ed9a19503683a674fe3541ae77e959df8e732652c2b4df0` |
| Motherboard / BIOS | ASUS TUF GAMING B660M-E D4 / 4003 |
| CPU | Intel Core i7-12700F (no iGPU) |
| Recorded Windows / driver | Windows 11 Pro 22000 / NVIDIA 616.92 |
| UEFI / Secure Boot | x64 / disabled |
| Selector profile | `entryLatchedSs1Full`; targets SS0 `0x88888888`, SS1 `0x8` |

Measured on the same cuBLAS GEMM n=4096 protocol: FP16 88.7 TFLOPS and
BF16 88.6 TFLOPS medians (locked baseline ~43.7). S3 sleep invalidates the
unlock on this profile as well; there is no resume path.

Select this profile with `research/headless/build-unlock.ps1 -HardwareProfile b660m-3070ti`
and `internal-boot/Configure.ps1 -HardwareProfile b660m-3070ti`; the default
`b650m-3090fe` profile is unchanged.

## Profile 3: ASRock B450M-HDV R4.0 / RTX 3060 (console on the target)

Intel-free, splitter-free host: the Ryzen has no console iGPU, the only GOP is
the target's, and the BIOS console is created on top of the card by an
EDID/mouse runtime driver. Releasing the console therefore releases **three**
owners and leaves nothing to display with until Windows starts.

| Common GPU/platform item | Validated value |
|---|---|
| Card | ASUS RTX 3060 12GB (GA106) |
| PCI identity | `10de:2504`, subsystem `1043:8816` |
| Chip / VRAM register | `0xb76000a1` / `0x3000` MiB (12 GiB) |
| BAR0 | `0xfb000000`, 16 MiB |
| PROM SHA256 | `a61344ca9e10b06a0538067cae05bd3387b2109583fea5e63cec6191d43214ee` |
| Motherboard / BIOS | ASRock B450M-HDV R4.0 / P10.60 |
| CPU | AMD Ryzen (no iGPU, no AMD GOP) |
| Recorded Windows / driver | Windows 11 / NVIDIA 621.01 |
| UEFI / Secure Boot | x64 / disabled |
| Selector profile | `entryLatchedSs1Full`; cold SS0 `0x62130012`, SS1 `0x2` are latched and the transaction reports SS0 `0x88888888`, SS1 `0x8` |
| Console chain | AMI text-out + gfx drivers, plus an EDID/mouse runtime driver that also owns the console input protocols |

Measured on the same cuBLAS GEMM 4096 x 4096 protocol: 45-48 TFLOPS FP16 and
23-25 TFLOPS TF32 while unlocked. No locked baseline was recorded on this
machine yet; `GpuUnlock.ps1 -Baseline` records one on a clean boot and `-Verify`
then reports the gain. S3 sleep invalidates the unlock here as well.

End-user tool: `GpuUnlock.ps1` (console) and `GpuUnlock.cmd` (window).
Evidence: [discovery, rehearsals and the written run](../evidence/discovery-rtx3060/README.md).

| Other configuration | Status |
|---|---|
| Same exact machine, F8-selected headless automatic child | One unlock + Windows display recovery + Tensor measurement verified on 2026-10-24 |
| Default automatic startup across repeated cold boots | Not established by that one F8 trial |
| Another RTX 3090, even a Founders Edition in another PC | Unverified; exact checks may reject |
| Another ASUS BIOS, AMD board/CPU or Intel host | Unverified; separate profile and validation required |
| CPU without iGPU (Intel host, aggregate console) | One hardware-verified profile below; still not generalized |
| Multiple discrete GPUs, laptop/hybrid setup | Unverified |
| Other NVIDIA models/architectures | Separate GPU port and validation required |
| AMD Radeon / Intel discrete unlock target | No unlock implementation here |
| Games, ComfyUI, sleep/hibernate resume, long-term stability | Not established by GEMM/boot evidence |

See [headless instructions](HEADLESS.en.md), [legacy USB instructions](GUIDE.en.md)
and [sanitized evidence](../evidence/headless-handoff/README.md).
The ordinary source guards remain in [root unlock](../unlock/app.c); the separate
headless implementation is in [internal unlock](../internal-boot/unlock/app.c),
[headless policy](../internal-boot/unlock/headless-policy.h) and
[wrapper release policy](../internal-boot/boot/full-release.c).

Changing constants, replacing a PROM hash or deleting a display check is not a
validated port. New support requires memory/WPR layout, firmware compatibility,
ownership, DMA cleanup and failure-path evidence.
[Portability criteria](PORTABILITY.en.md) / [compatibility reporting](CONTRIBUTING.en.md).
