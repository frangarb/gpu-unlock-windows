# Windows GPU UNLOCK — release history

## v0.4.1 — 2026-10-25: one-time boot, baseline in the window, permissions

- `GpuUnlock.ps1 -Activate` registers the entry **and arms the firmware's
  one-time boot slot** (`BootNext`, read back after writing): the next start runs
  the unlock with no F8 and no firmware menu, then Windows as usual. `-Restart`
  (or the window's RESTART FOR UNLOCK) restarts with that slot armed and Fast
  Startup off; `-Deactivate` cancels the slot and restores the previous order.
- The window can record the locked baseline — measure, set a value by hand, or
  forget it — and colours each row by consequence: green passes, red blocks,
  orange unknown.
- Every action that reads the unlock partition or changes the boot configuration
  now says it needs administrator and asks for it, instead of reporting a wrong
  partition. MEASURE and `-Status` still run unprivileged.
- Source-only, same scope: one reviewed machine, no NVIDIA firmware, no EFI
  binaries, no partition identifiers.

## v0.4.0 — 2026-10-25: GA106 RTX 3060 writes the unlock; end-user window

The first release where a second, deliberately different machine **wrote** the
unlock on hardware and carried the full tensor rate into Windows:

- ASRock B450M-HDV R4.0, BIOS P10.60, Ryzen without an iGPU, ASUS RTX 3060 12GB
  (`10de:2504`, subsystem `1043:8816`). The console is created on the target card
  by an EDID/mouse driver, so three owners are released and the screen stays dark
  until Windows returns. Transaction `result=0`, SS0 `0x88888888` and SS1 `0x8`
  after the PCIe FLR, driver 621.01, 45-48 TFLOPS FP16 and 23-25 TF32.
- Four rehearsals before the write, each with its log: read-only discovery,
  console verification, console release, and full release with EDID/nvgop
  release and PCI decode restore.
  [Evidence](evidence/discovery-rtx3060/README.md).
- `GpuUnlock.ps1` gained `-Status` (text or `-Json`), `-Baseline` and `-Gui` with
  the unchanged `-Activate` / `-Automatic` / `-Verify` / `-Deactivate`; the
  window opens with `GpuUnlock.cmd`. Mutations keep the verified-then-rollback
  policy and the CLI keeps its output and exit codes.
- `-Baseline` records the locked rate once per machine and `-Verify` then reports
  the measured gain; it refuses to save a measurement taken on an unlocked card.
- Source-only, as before: no NVIDIA firmware, no PROM dumps, no partition
  identifiers, no EFI binaries. All three verified profiles build from source
  with the documented steps.

Still not established: a locked baseline on this machine (one command, on a
clean boot), S3/hibernate resume, repeated cold-boot reliability, games and
ComfyUI.

---

이 문서는 **v0.1.0 USB 수동 릴리스 이력**입니다. 새 내부 부팅 소스·실험용 자동판은
[v0.2.0 안내](RELEASE-v0.2.0.md)와 [단계별 가이드](docs/INTERNAL-BOOT.ko.md)를 참고하세요.

실제 성공한 RTX3090 24GiB / AMD iGPU / ASUS B650M-PLUS WIFI 포트와 한국어 가이드입니다.

- 언락 후 재부팅 없이 **Boot Override → Windows Boot Manager**로 진입.
- Windows 드라이버 617.14 유지. 동일 CUDA12.6/cuBLAS 측정: FP16 70.55 → 125.91 TFLOPS (+78.5%), BF16 70.53 → 128.70 TFLOPS (+82.5%). 각 상태 3회 중앙값.
- 대응 공개 소스로 재빌드한 EFI가 실제 성공 USB EFI와 byte-for-byte 동일.
- host mock 10그룹, PE 음성 검사와 패키징 검사 5개 통과.

**특정 PC에 고정된 실험 코드입니다. 모든 RTX3090/30시리즈에서 그대로 작동하지 않습니다.** 지원 검사 거부를 우회하지 마세요. 장기 안정성과 ComfyUI 실제 속도는 별도 검증 대상입니다.

ZIP은 코드·문서·라이선스·성공 EFI를 포함합니다. **실행 펌웨어 5개는 포함하지 않습니다.** docs/ASSETS.ko.md의 생성 절차와 unlock/assets.json의 해시를 확인하세요. USB 준비·출력 조건·오류 대응은 docs/GUIDE.ko.md에 있습니다.

EFI SHA-256:

```text
f5cbf7ae2884d2707ee888589f725b18bbc8b0f9672a511e3467ada02af6b0f5
```

기존 Windows EFI/복구 파티션 변경과 드라이버 교체는 필요하지 않습니다. 내부 디스크 자동 부팅과 Windows 직접 chainload는 이 릴리스에 구현되지 않았습니다.
