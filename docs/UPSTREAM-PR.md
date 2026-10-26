# Upstream pull request draft — `windows/ga106` → `Zagitta/gpu-unlock`

Ready to paste. Open the PR from `frangarb/gpu-unlock-windows`, branch
`windows/ga106`, against `Zagitta/gpu-unlock` `main`.

Suggested title:

> Windows port: V67/PLM unlock from UEFI, written and measured on an RTX 3060 (GA106)

Body:

---

This adds a Windows implementation of `unlock_610` that runs **before** the NVIDIA
driver takes the card, so the transaction sees the same cold state your initramfs
module does. It has written the unlock on real hardware and the card keeps the
full tensor rate into Windows.

**Verified on hardware (2026-10-25).** ASRock B450M-HDV R4.0, BIOS P10.60, Ryzen
without an iGPU, ASUS RTX 3060 12GB (`10de:2504`, subsystem `1043:8816`, driver
621.01):

- one transaction, `result=0 containment=0 fault=0 retained=0 maps=0 FLR=1`
- `SS0=0x88888888` and `SS1=0x8` survive the PCIe FLR, `WPR2=1ffffe00:00000000`
- cuBLAS GEMM 4096×4096: **45–48 TFLOPS FP16→FP32** and **23–25 TFLOPS
  TF32→FP32**, against the ~25/~13 GeForce rates for this part

Your README says the 3060 path works under Linux; this matches it on Windows
from the other direction, including the `SS0`/`SS1` read-back after the FLR.

## How it runs without a kernel module

Windows cannot unload `nvlddmkm.sys` early enough, so the port is a
`SERVICE_BOOT_START`-style UEFI application instead of a driver:

1. Windows Boot Manager hands over to `WRITE3060.EFI` from a dedicated ESP.
2. It releases the firmware console owners (three on this board: the AMI
   text-out and gfx drivers plus an EDID/mouse runtime driver that also owns the
   console input protocols), which leaves the target GOP as the only one.
3. It runs the transaction with the same 11 stages as `unlock_610.c`, using the
   same `booter_load_ga102.bin` and the V67 payload derived from the GA10x GSP
   firmware — `kgspGetBinArchiveBooterLoadUcode` maps GA102…GA107 to one archive,
   so GA106 needs no new asset.
4. It restores PCI decoding and chain-loads `bootmgfw.efi` directly. No reboot:
   a reboot in between would let the driver initialize the card and close WPR2.

Nothing is written to the GPU, its vBIOS or the driver: the unlock lives in
firmware RAM and a full power-off returns the card to factory state.

## What is deliberately not portable

Everything around the transaction is compiled as immutable per-machine
constants — PCI id/subsystem, BAR0, chip id, VRAM, the live PROM hash, the
console owner fingerprints and the 36-byte display device path. The guards
refuse a machine they do not recognize, and a build without those constants does
not write. `docs/PORTING.es.md` documents the five evidence steps for a new
board (read-only capture → derived profile → console verify → release
rehearsals → write), and `docs/PORTABILITY.en.md` has the criteria.

So this is not a universal RTX 3000 binary, and I do not think one can exist
without deleting the checks that make it safe. Three machines are verified
today: the 3060 above, an RTX 3090 FE (ASUS B650M), and an RTX 3070 Ti
(ASUS B660M-E, aggregate AMI console).

## Source layout

- `kernel/` — your `unlock_610.c` / `prep_610.c` / `vbios_610.c`, unmodified,
  kept as the reference implementation and for the Linux build
- `internal-boot/` — the UEFI wrapper, the transaction child, the console
  release policy and the per-profile constants
- `research/headless/` — build and registration scripts for each rehearsal
- `tools/` — `derive_profile.py` / `derive_display.py`, which derive profile
  constants from a read-only capture and refuse ambiguity
- `docs/` — port and discovery guides (Spanish), compatibility, evidence

License stays GPL-2.0-only. No NVIDIA firmware, PROM dump, driver or EFI binary
is included; the five assets are fetched locally and their hashes are pinned in
`internal-boot/unlock/assets.json`.

## What this does not establish

Games, ComfyUI, S3/hibernate resume (the unlock does not survive sleep), repeated
cold-boot reliability, and any machine beyond the three above. The locked
baseline for the 3060 is one command away but has not been recorded yet.

Evidence with logs and register tables:
`evidence/discovery-rtx3060/README.md`.
