# NeonSight YOLO 精简版 ONNX Runtime

此 fork 额外提供一套面向 NeonSight / YOLO 检测链路的 ONNX Runtime 构建方式。目标是保留常见 YOLOv5 / YOLOv8 / YOLO11 ONNX 推理所需能力，同时减少桌面应用不需要的 CUDA LLM / Attention / Triton 训练内核带来的编译体积和 CUDA 13 新架构初始化风险。

## 精简策略

- 新增 CMake 开关 `onnxruntime_NEONSIGHT_YOLO_LITE`。
- 开启该开关时，CUDA Provider 源列表会排除 `core/providers/cuda/llm/*` 和 Triton 内核源。
- 开启该开关时，CUDA Kernel 注册表会跳过 YOLO 检测不需要的 Attention、RotaryEmbedding、TensorScatter 等 CUDA kernel。
- CUDA 架构规范化不再把 `120` 强制转换为 `120a-real`，以兼容 RTX 50 系消费卡上常见的 `sm_120` 构建。
- 构建参数默认关闭 FlashAttention、LeanAttention、MemoryEfficientAttention、FP8 KV Cache、CUDA NHWC 扩展、Float8 / Float4 类型。

## CI/CD

新增 workflow：`.github/workflows/neonsight-yolo-lite-release.yml`。

触发方式：

- 推送 `yolo-lite-v*` 标签：自动构建并发布 GitHub Release。
- 手动运行 workflow：可只生成 artifact，也可填写 `release_tag` 并启用 `publish_release` 发布 Release。

默认会先尝试构建 CUDA YOLO 精简版。如果 CUDA 环境不存在、依赖检查失败、编译失败或打包失败，workflow 会继续执行 CPU install-root 兜底构建，并把成功的制品发布到 Release。

未配置自托管 runner 时，CUDA job 会在 GitHub 托管 Windows runner 上快速完成环境检查；由于托管 runner 通常没有 CUDA / cuDNN，它会转入 CPU 兜底。若要真正产出 CUDA 制品，需要配置带 CUDA / cuDNN 的 Windows self-hosted runner，并在仓库变量中设置：

- `ORT_YOLO_CUDA_RUNNER_LABELS=["self-hosted","Windows","X64","CUDA"]`
- 可选：`ORT_YOLO_CUDA_ARCHITECTURES=86;89;120`
- runner 环境中存在 `CUDA_PATH` 和 `CUDNN_HOME`

手动运行 workflow 时，可以通过 `cuda_architectures` 输入覆盖本次 CUDA 架构列表。

## 本地构建示例

CPU install-root：

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

CUDA YOLO 精简版：

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

## 发布给 NeonSight 使用

Release 资产会输出 zip，内部布局为：

```text
onnxruntime-yolo-lite-win-x64-*/
  include/onnxruntime/*.h
  lib/onnxruntime.lib
  bin/onnxruntime.dll
  bin/onnxruntime_providers_shared.dll
  bin/onnxruntime_providers_cuda.dll
  BUILD_INFO.json
```

将 zip 上传到 GitHub Release 后，可把 URL 和 SHA256 写入 NeonSight 仓库的 `manifests/onnxruntime-artifacts.local.json`，再通过 NeonSight 的 `release_with_ort_artifact.ps1` 拉取并打包。
