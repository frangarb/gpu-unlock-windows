# Windows GPU UNLOCK

[English](README.md) | **한국어**

> **2026-10-25:** 이 문서는 v0.3.1 시점의 RTX 3090 사례를 설명합니다. RTX 3060(GA106)
> 포트, 데스크톱 창, 기준선 기록은 [English](README.md),
> [사용 안내(es)](docs/USER-GUIDE.es.md), [호환성](docs/COMPATIBILITY.en.md)에
> 정리되어 있습니다.

한 대의 **RTX 3090 Founders Edition / ASUS BIOS 3057** 시스템에서 검증한 실험용 UEFI
언락과 Windows 직접 인계 구현입니다. **v0.3.1은 소스 전용 사전 릴리스**입니다.
자신의 파티션 GUID로 내부 EFI를 빌드해야 하며, 펌웨어와 개인 파티션 설정이 들어간
EFI 바이너리는 이번 릴리스에 포함하지 않습니다.

2026-10-24에는 모든 모니터를 RTX에 연결한 내부 **headless 언락**을 완료했습니다.
해제 전 RTX 물리 GOP 1개, 해제 후 물리 GOP 0개를 확인하고, 자동 언락 1회와 Windows
화면 복귀를 거쳤습니다. 이후 Windows 3회 측정 중앙값은 **FP16 124.97 / BF16 128.93
TFLOPS**였습니다. [근거와 한계](evidence/headless-handoff/README.md).

v0.3.1은 펌웨어가 RTX 디스플레이 자식 핸들을 2개보다 많이 노출할 때 사전 검사가
거부하던 문제를 수정했습니다. 수정 빌드로 자동 언락 후 Windows 화면 복귀까지 다시
확인했으며, 이 빌드의 새 성능 벤치마크는 아직 없습니다.

한 시스템·한 부팅의 결과이며 모든 3090의 지원을 의미하지 않습니다.
CPU는 **iGPU가 있는 Ryzen 7 7800X3D**입니다. 활성 AMD GOP 없이 성공했지만,
iGPU 없는 CPU·Intel 호스트·다른 카드·다른 BIOS는 미검증입니다.
먼저 [호환성](docs/COMPATIBILITY.ko.md)을 확인하세요.

## 부팅 경로 선택

| 경로 | 화면·입력 조건 | 안내 |
|---|---|---|
| **내부 headless** | 모니터는 RTX, 도중 화면 제거, T/U/Enter 불필요 | [Headless 안내](docs/HEADLESS.ko.md): 실제 언락·Windows 인계 1회 검증 |
| 기존 내부 AMD 화면 manual / Auto | 메인보드/iGPU 화면 유지, manual은 U 필요 | [기존 내부 부팅 안내](docs/INTERNAL-BOOT.ko.md) |
| 기존 USB manual | AMD/iGPU 화면, U 한 번, 리셋 없이 Boot Override로 Windows | [USB 안내](docs/GUIDE.ko.md) |

**Headless USB 부팅은 시험하지 않았습니다.** 기존 USB EFI에는 AMD 출력 조건이 있습니다.
BIOS를 `USB → Windows`로 설정하는 것만으로 직접 인계가 구현되지는 않습니다.

## 내부 headless 빠른 시작

부팅 설정을 바꾸기 전에 [상세 절차와 복구 방법](docs/HEADLESS.ko.md)을 읽으세요.
정확한 지원 하드웨어, Secure Boot 꺼짐, 완전히 복호화되고 BitLocker 보호가 꺼진
Windows C:, 연결된 키보드가 필요합니다. 도구는 암호화 설정을 해제하지 않습니다.

**기존 Windows ESP와 복구 파티션은 보존**하세요. U: 같은 문자를 가진 별도 GPT FAT32
**EFI 시스템 파티션 1 GiB 이상**을 준비합니다. 도구는 파티션을 생성·축소·삭제·포맷하지
않습니다. 일반 FAT32 데이터 파티션만으로는 ESP 조건을 충족하지 않습니다.

Python 3.9+, clang/lld-link **20.1.8**, 저장소의 고정 의존성과 직접 준비한
[펌웨어 파일 5개](docs/ASSETS.ko.md)가 필요합니다. Host 통합 시험에는 추가로
MSVC/Windows SDK와 개인 fixture가 필요합니다.

저장소 루트의 관리자 PowerShell에서 실행합니다.

```powershell
# GUID와 도구 경로를 자신의 값으로 바꾸세요.
.\internal-boot\Configure.ps1 -UnlockDriveLetter U `
  -WindowsEspGuid 'YOUR-WINDOWS-ESP-GUID'
.\research\headless\build-unlock.ps1 `
  -Clang 'C:\TOOLS\LLVM20\bin\clang.exe' `
  -LldLink 'C:\TOOLS\LLVM20\bin\lld-link.exe'

# 파일 배치와 별도 F8 시험 항목 추가. 기존 기본 우선순위는 유지합니다.
.\internal-boot\Headless.ps1 -Assets '.\assets' -Register
```

동작 스위치 없이 `Headless.ps1 -Assets '.\assets'`만 실행하면 파일만 배치합니다.
설정·빌드는 부팅 항목을 등록하지 않습니다.

1. 작업을 저장하고 완전히 전원을 끕니다. 시험한 ASUS에서는
   **F8 → GPU Headless UNLOCK - EXPERIMENTAL**을 선택합니다.
2. **T·U·Enter를 누르지 말고 기다립니다.** 최초 5초 안의 Esc는 해제·언락을 생략하고
   Windows로 직접 들어갑니다.
3. RTX GOP를 제거하면 화면이 검게 변합니다. Child가 한 번 시도하고 wrapper가
   Windows를 직접 시작합니다. 언락과 Windows 사이에 리셋하지 마세요.
   화면 복귀를 확인하고 [성능을 측정](docs/BENCHMARK.ko.md)합니다.
4. 그 F8 시험에 성공한 뒤에만 기본 자동 부팅을 활성화합니다.

   ```powershell
   .\internal-boot\Headless.ps1 -EnableAutomatic -ConfirmedSuccess
   ```

이 명령은 headless를 첫 번째, Windows Boot Manager를 두 번째로 배치하고 Windows
빠른 시작을 끕니다. 시험 항목 등록만으로는 바뀌지 않습니다. 릴리스 공개 작업 자체는
연구 PC의 현재 기본 부팅 선택을 변경하지 않습니다.

**Esc 구간은 두 개이며 효과가 다릅니다.** 최초 wrapper Esc는 해제 없이 Windows로
갑니다. 나중에 나오는 child의 3초 Esc 구간은 이미 해제한 뒤이므로 취소하고 정지합니다.
화면을 복구하거나 Windows로 계속 진행하지 않습니다. 실패하거나 Windows가 돌아오지
않으면 완전히 전원을 끈 다음 **F8 → Windows Boot Manager**를 선택하세요.

```powershell
.\internal-boot\Headless.ps1 -RestoreWindowsFirst
```

Windows 우선순위 복구는 실험 EFI·빌드 산출물·저장된 상태 없이도 진행합니다.
이전 빠른 시작 값 복원에는 로컬 상태가 필요하므로 상태와 백업을 보존하세요.
[자세한 복구 설명](docs/HEADLESS.ko.md#recovery)을 참고하세요.

## 결과와 한계

성공한 child는 SS0 `0x88888888`, SS1 `0x8`, BME 꺼짐, 남은 mapping 없음,
정리 완료와 FLR 1회를 기록했습니다. Wrapper가 Windows 시작 전 해제 토폴로지를
검증했고, 운영자가 Windows 화면 복귀를 확인했습니다.

| CUDA 12.6 / cuBLAS 12.6, 4096 × 4096 행렬 | 3회 중앙값 |
|---|---:|
| FP32 pedantic | 22.85 TFLOPS |
| FP16 Tensor / FP32 누산 | 124.97 TFLOPS |
| BF16 Tensor / FP32 누산 | 128.93 TFLOPS |

이번 headless 부팅에는 **동시대의 통제된 잠금 상태 기준 측정이 없습니다.** 언락 증가율을
계산하지 않습니다. 게임·ComfyUI 향상, 장기 안정성, 절전·최대 절전 복귀, 반복 자동 콜드
부팅의 신뢰성을 입증하지도 않습니다. [공개 측정 요약](evidence/headless-handoff/summary.json)과
[이전 결과](docs/RESULTS.ko.md)는 서로 다른 실험입니다.

## 구현과 경계

Headless는 별도 컴파일 프로필입니다. 정확한 GPU·PROM·PCI 상태·펌웨어 드라이버 코드·
소유권·cold 상태·불변 selector와 정리 검사를 유지합니다. Child는 파일에만 기록하고
물리 GOP 재등장이나 콘솔·입력 인터페이스 변경을 거부합니다. 일반 빌드의 AMD 화면
검사는 그대로입니다. 다른 PC에서 실행하려고 guard를 삭제하거나 PROM 해시만 바꾸지 마세요.

| 경로 | 내용 |
|---|---|
| `internal-boot/`, `research/headless/` | 내부·headless 소스, 로컬 빌드·설치·host 시험 |
| `unlock/`, `release/` | 보존한 기존 USB 수동 구현과 과거 산출물 |
| `benchmark/`, `evidence/` | 측정 도구와 선택한 공개 근거 |
| `docs/` | 호환성·assets·부팅 안내와 한계 |

VBIOS 플래싱이나 Windows 드라이버 교체는 절차에 포함하지 않습니다. 기록된 실행에서
617.14 드라이버는 그대로였습니다. Host mock 시험이 지원 하드웨어를 추가하지는 않습니다.
새 시스템은 [호환성 보고](docs/CONTRIBUTING.ko.md)와
[포팅 기준](docs/PORTABILITY.en.md)을 참고하세요.

## 라이선스와 출처

포트와 재사용 코어는 **GPL-2.0-only**이며 EDK2 등 별도 구성 요소의 라이선스는 유지합니다.
[rough2515-hub/rtx3080-unlock-public](https://github.com/rough2515-hub/rtx3080-unlock-public/tree/a08254d269af30ace9e57237abd3d8e6c261e8f5)와
[Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock/tree/0ebdb1c6308b6a2072be5bf04513472942541956)에 기반합니다.
[LICENSE](LICENSE), [외부 코드 고지](THIRD_PARTY_NOTICES.md), [변경 이력](CHANGES.md)을
보존하세요. NVIDIA 펌웨어·PROM/BIOS 이미지·드라이버·CUDA DLL은 이번 소스 릴리스에
재배포하지 않습니다.
