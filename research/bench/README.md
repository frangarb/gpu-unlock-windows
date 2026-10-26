# Tensor-rate probe

`tensor_rate.cu` measures the exact path the unlock restores: tensor units fed
with FP16 or TF32 and accumulating in FP32. It runs three GEMMs through cuBLAS
at one size and prints TFLOPS; it never reads or writes GPU state.

```powershell
# Needs the MSVC host tools on PATH (nvcc uses cl.exe).
nvcc -O3 -arch=sm_86 tensor_rate.cu -lcublas -o build/tensor_rate.exe
build\tensor_rate.exe 4096 20
```

Compare two boots of the same machine, same wall power and no other GPU work:

1. **Cold boot without the unlock entry** and run it: this is the GeForce rate.
2. Power off completely, boot the unlock entry, wait for Windows, run it again.

The unlocked boot should show roughly twice the FP16 and TF32 numbers of the
locked one, with FP32 SIMT unchanged (the selectors do not touch it).

Measured on the ASRock B450M / RTX 3060 profile after a successful unlock
(`AUTO000002/REPORT.TXT`), driver 621.01, two runs:

| Path | TFLOPS |
| --- | --- |
| FP16 in, FP32 accumulate | 45.1 / 47.7 |
| TF32 in, FP32 accumulate | 23.4 / 24.9 |
| FP32 SIMT | 8.0 / 7.9 |

Those are full-rate numbers for this part; the locked baseline run is still
missing, which is what the two-step procedure above produces.
