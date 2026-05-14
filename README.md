# ONNX Runtime YOLO Lite

[English](README.md) | [中文](README.zh-CN.md)

`onnxruntime-yolo` is a YOLO-focused fork of [microsoft/onnxruntime](https://github.com/microsoft/onnxruntime). It keeps the ONNX Runtime inference path needed by common YOLO detection workloads, while reducing CUDA provider features that are not needed by this project.

This fork is maintained for the NeonSight / YoloDemoApp desktop detection pipeline. It is intended to provide compact, reproducible ONNX Runtime artifacts for YOLOv5, YOLOv8, YOLO11, and similar object detection ONNX models.

## Goals

- Provide a YOLO-friendly ONNX Runtime build for Windows x64.
- Keep CPU inference available as a reliable fallback.
- Prefer CUDA artifacts when the CI environment can prepare CUDA and cuDNN.
- Stay compatible with CUDA 13 without making CUDA 13 the only supported target.
- Publish release assets as install-root zip packages that can be consumed by desktop applications.

## What Is Different

This fork adds a YOLO lite build mode:

```text
onnxruntime_NEONSIGHT_YOLO_LITE=ON
```

When enabled, the CUDA provider build removes or disables components that are not required for normal YOLO image/video detection:

- CUDA LLM provider sources under `core/providers/cuda/llm/*`
- Triton kernel source entries
- selected Attention, RotaryEmbedding, and TensorScatter CUDA registrations
- FlashAttention, LeanAttention, MemoryEfficientAttention, FP8 KV cache, CUDA NHWC extensions, Float8, and Float4 build features

The CUDA architecture handling also avoids converting `120` into `120a-real`, which helps consumer RTX 50 series cards that target `sm_120`.

## Release Artifacts

Release packages are published from the `yolo-lite-v*` tags.

Each zip uses an install-root layout:

```text
onnxruntime-yolo-lite-win-x64-*/
  include/onnxruntime/*.h
  lib/onnxruntime.lib
  bin/onnxruntime.dll
  bin/onnxruntime_providers_shared.dll
  bin/onnxruntime_providers_cuda.dll
  BUILD_INFO.json
```

CPU artifacts do not contain `onnxruntime_providers_cuda.dll`. CUDA artifacts include it when the CUDA build succeeds.

## CI/CD Behavior

The release workflow is located at:

```text
.github/workflows/neonsight-yolo-lite-release.yml
```

It runs when a tag matching `yolo-lite-v*` is pushed, or when the workflow is started manually.

The workflow tries CUDA first:

1. Reuse existing `CUDA_PATH` / `CUDNN_HOME` if present.
2. If missing, download and install CUDA Toolkit and cuDNN in CI.
3. Build the CUDA YOLO lite shared library.
4. If any CUDA step fails, build the CPU install-root package instead.
5. Publish the successful artifact set to GitHub Releases.

The default CUDA installer path uses a reduced component list for faster CI setup. If that component install fails, the script automatically retries with the full CUDA silent installer. A custom component list can still be forced through `ORT_YOLO_CUDA_INSTALL_COMPONENTS`.

Useful repository variables:

```text
ORT_YOLO_CUDA_VERSION=13.0.2
ORT_YOLO_CUDNN_VERSION=9.17.0
ORT_YOLO_CUDA_ARCHITECTURES=86;89;120
ORT_YOLO_CUDA_RUNNER_LABELS=["self-hosted","Windows","X64","CUDA"]
ORT_YOLO_CUDA_INSTALLER_URL=<custom CUDA Windows network installer URL>
ORT_YOLO_CUDNN_MANIFEST_URL=<custom cuDNN redist manifest URL>
ORT_YOLO_CUDA_INSTALL_COMPONENTS=<CUDA silent installer component list>
```

GitHub-hosted Windows runners can compile CUDA artifacts if CUDA/cuDNN installation succeeds, but they do not provide reliable real GPU inference validation. Use a Windows self-hosted runner with an NVIDIA GPU for real CUDA runtime verification.

## Local Build

CPU install-root:

```powershell
python tools\ci_build\build.py `
  --update --build `
  --config Release `
  --build_dir .deps\ort-build-cpu `
  --skip_tests `
  --parallel `
  --cmake_generator "Visual Studio 17 2022" `
  --build_shared_lib `
  --cmake_extra_defines onnxruntime_DISABLE_ML_OPS=ON `
  --cmake_extra_defines onnxruntime_DISABLE_FLOAT8_TYPES=ON `
  --cmake_extra_defines onnxruntime_DISABLE_FLOAT4_TYPES=ON

pwsh -NoProfile -ExecutionPolicy Bypass -File tools\neonsight_yolo_lite\package_ort_install_root.ps1 `
  -BuildDir .deps\ort-build-cpu `
  -SourceRoot . `
  -OutputDir .deps\ort-artifacts `
  -PackageName onnxruntime-yolo-lite-win-x64-cpu `
  -PackageKind cpu
```

CUDA YOLO lite install-root:

```powershell
python tools\ci_build\build.py `
  --update --build `
  --config Release `
  --build_dir .deps\ort-build-cuda `
  --skip_tests `
  --parallel `
  --nvcc_threads 1 `
  --cmake_generator "Visual Studio 17 2022" `
  --build_shared_lib `
  --use_cuda `
  --cuda_home "$env:CUDA_PATH" `
  --cudnn_home "$env:CUDNN_HOME" `
  --cmake_extra_defines CMAKE_CUDA_ARCHITECTURES=86`;89`;120 `
  --cmake_extra_defines onnxruntime_NEONSIGHT_YOLO_LITE=ON `
  --cmake_extra_defines onnxruntime_USE_FLASH_ATTENTION=OFF `
  --cmake_extra_defines onnxruntime_USE_LEAN_ATTENTION=OFF `
  --cmake_extra_defines onnxruntime_USE_MEMORY_EFFICIENT_ATTENTION=OFF `
  --cmake_extra_defines onnxruntime_USE_FP8_KV_CACHE=OFF `
  --cmake_extra_defines onnxruntime_USE_CUDA_NHWC_OPS=OFF `
  --cmake_extra_defines onnxruntime_DISABLE_FLOAT8_TYPES=ON `
  --cmake_extra_defines onnxruntime_DISABLE_FLOAT4_TYPES=ON

pwsh -NoProfile -ExecutionPolicy Bypass -File tools\neonsight_yolo_lite\package_ort_install_root.ps1 `
  -BuildDir .deps\ort-build-cuda `
  -SourceRoot . `
  -OutputDir .deps\ort-artifacts `
  -PackageName onnxruntime-yolo-lite-win-x64-cuda `
  -PackageKind cuda
```

## Using the Artifact

Download the latest release zip, extract it, and point your application build to:

- `include/` for ONNX Runtime headers
- `lib/onnxruntime.lib` for linking
- `bin/` for runtime DLL deployment

For CUDA runtime packages, make sure the target machine has compatible NVIDIA driver support and the required CUDA/cuDNN runtime DLLs available beside the application or in `PATH`.

## Upstream Sync

The default branch of this fork is `yolo-lite-cicd`.

Recommended upstream sync flow:

```powershell
git switch yolo-lite-cicd
git fetch upstream
git switch -c sync-upstream-YYYYMMDD
git merge upstream/main
```

Resolve conflicts, run the YOLO lite CI/build checks, and then merge the sync branch back into `yolo-lite-cicd`.

Avoid force-resetting this branch to upstream `main`, because that would discard the YOLO lite build changes.

## More Documentation

- [YOLO lite build notes](docs/NEONSIGHT_YOLO_LITE_BUILD.md)
- [Official ONNX Runtime documentation](https://onnxruntime.ai/docs/)
- [Official ONNX Runtime repository](https://github.com/microsoft/onnxruntime)

## License

This fork follows the upstream ONNX Runtime license. See [LICENSE](LICENSE).
