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

默认会先尝试构建 CUDA YOLO 精简版。CUDA job 会先复用 runner 上已有的 CUDA / cuDNN；如果缺失，则自动下载并安装 CUDA Toolkit 13.0.2 网络安装器和 cuDNN 9.17 CUDA 13 redist zip。若 CUDA 环境准备、依赖安装、编译、打包或上传任一步失败，workflow 会继续执行 CPU install-root 兜底构建，并把成功的制品发布到 Release。

CUDA 自动安装默认使用精简组件列表，以减少 GitHub runner 的下载和安装时间。如果默认组件化安装失败，脚本会自动退回完整 CUDA silent 安装。需要强制指定组件时，可设置 `ORT_YOLO_CUDA_INSTALL_COMPONENTS` 仓库变量。

未配置自托管 runner 时，CUDA job 会在 GitHub 托管 Windows runner 上尝试在线安装 CUDA / cuDNN 并编译 CUDA 制品。该路径可以做编译发布，但不能替代真实 GPU 推理验收；若要做真实 GPU 验证，仍建议配置带 NVIDIA GPU 的 Windows self-hosted runner，并在仓库变量中设置：

- `ORT_YOLO_CUDA_RUNNER_LABELS=["self-hosted","Windows","X64","CUDA"]`
- 可选：`ORT_YOLO_CUDA_ARCHITECTURES=86;89;120`
- 可选：`ORT_YOLO_CUDA_VERSION=13.0.2`
- 可选：`ORT_YOLO_CUDNN_VERSION=9.17.0`
- 可选：`ORT_YOLO_CUDA_INSTALLER_URL=<CUDA Windows 网络安装器 URL>`
- 可选：`ORT_YOLO_CUDNN_MANIFEST_URL=<cuDNN redist manifest URL>`
- 可选：`ORT_YOLO_CUDA_INSTALL_COMPONENTS=<CUDA silent installer 组件列表>`

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
