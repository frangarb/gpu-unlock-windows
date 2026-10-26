/* GPL-2.0-only. Tensor-rate probe for the gpu-unlock port.
 *
 * The unlock restores the full (non-GeForce) rate of the tensor units for
 * FP16/BF16/TF32 with FP32 accumulation. This measures exactly that path with
 * cuBLAS at a fixed size, so a locked and an unlocked boot can be compared.
 *
 *   nvcc -O3 -arch=sm_86 tensor_rate.cu -lcublas -o tensor_rate.exe
 *   tensor_rate.exe            # default n=4096
 *
 * Nothing here reads or writes GPU state; it only runs GEMMs.
 */
#include <cstdio>
#include <cstdlib>
#include <cuda_fp16.h>
#include <cuda_runtime.h>
#include <cublas_v2.h>

#define CHECK(x) do { cudaError_t e = (x); if (e != cudaSuccess) { \
  std::printf("error: %s at line %d\n", cudaGetErrorString(e), __LINE__); return 1; } } while (0)
#define CUBLAS(x) do { cublasStatus_t s = (x); if (s != CUBLAS_STATUS_SUCCESS) { \
  std::printf("cublas error %d at line %d\n", (int)s, __LINE__); return 1; } } while (0)

static float Time(cublasHandle_t h, int n, const void *a, cudaDataType_t at, const void *b,
                  void *c, cublasComputeType_t compute, int reps) {
  const float alpha = 1.0f, beta = 0.0f;
  cudaEvent_t start, stop;
  cudaEventCreate(&start); cudaEventCreate(&stop);
  for (int i = 0; i < 3; i++) /* warm up clocks and the plan */
    cublasGemmEx(h, CUBLAS_OP_N, CUBLAS_OP_N, n, n, n, &alpha, a, at, n, b, at, n,
                 &beta, c, CUDA_R_32F, n, compute, CUBLAS_GEMM_DEFAULT_TENSOR_OP);
  cudaEventRecord(start);
  for (int i = 0; i < reps; i++)
    cublasGemmEx(h, CUBLAS_OP_N, CUBLAS_OP_N, n, n, n, &alpha, a, at, n, b, at, n,
                 &beta, c, CUDA_R_32F, n, compute, CUBLAS_GEMM_DEFAULT_TENSOR_OP);
  cudaEventRecord(stop);
  cudaEventSynchronize(stop);
  float ms = 0; cudaEventElapsedTime(&ms, start, stop);
  cudaEventDestroy(start); cudaEventDestroy(stop);
  return ms > 0 ? 2.0e-9 * (double)n * n * n * reps / (ms * 1e-3) / 1e3 : 0.0f;
}

int main(int argc, char **argv) {
  const int n = argc > 1 ? std::atoi(argv[1]) : 4096;
  const int reps = argc > 2 ? std::atoi(argv[2]) : 20;
  if (n < 1024 || n > 8192) { std::printf("n out of range\n"); return 2; }

  int device = 0; cudaDeviceProp prop;
  CHECK(cudaGetDevice(&device));
  CHECK(cudaGetDeviceProperties(&prop, device));
  std::printf("device: %s sm_%d%d\n", prop.name, prop.major, prop.minor);

  void *a = nullptr, *b = nullptr, *c = nullptr, *d = nullptr;
  /* Finite non-zero patterns only: no denormal or zero operands, so the timed
   * path cannot be a special case. */
  size_t f = (size_t)n * n * sizeof(float), h = (size_t)n * n * sizeof(__half);
  CHECK(cudaMalloc(&a, f)); CHECK(cudaMalloc(&b, f));
  CHECK(cudaMalloc(&c, f));
  CHECK(cudaMemset(a, 0x3c, f)); CHECK(cudaMemset(b, 0x3c, f));
  CHECK(cudaMalloc(&d, h));
  CHECK(cudaMemset(d, 0x3c, h));

  cublasHandle_t handle;
  CUBLAS(cublasCreate(&handle));

  /* The gated path: 16-bit inputs, FP32 accumulate. */
  float fp16 = Time(handle, n, d, CUDA_R_16F, d, c, CUBLAS_COMPUTE_32F, reps);
  /* Same accumulate, TF32 inputs: the other gated path. */
  float tf32 = Time(handle, n, a, CUDA_R_32F, b, c, CUBLAS_COMPUTE_32F_FAST_TF32, reps);
  /* Plain FP32 SIMT, ungated by the selectors, for reference. */
  float fp32 = Time(handle, n, a, CUDA_R_32F, b, c, CUBLAS_COMPUTE_32F, reps);

  std::printf("n=%d reps=%d\n", n, reps);
  std::printf("fp16-in fp32-acc : %8.2f TFLOPS\n", fp16);
  std::printf("tf32-in fp32-acc : %8.2f TFLOPS\n", tf32);
  std::printf("fp32 simt        : %8.2f TFLOPS\n", fp32);

  cublasDestroy(handle);
  cudaFree(a); cudaFree(b); cudaFree(c); cudaFree(d);
  return 0;
}
