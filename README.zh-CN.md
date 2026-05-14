# ONNX Runtime YOLO 精简版

[English](README.md) | [中文](README.zh-CN.md)

`onnxruntime-yolo` 是基于 [microsoft/onnxruntime](https://github.com/microsoft/onnxruntime) 的 YOLO 定向精简 fork。它保留常见 YOLO 检测链路所需的 ONNX Runtime 推理能力，同时减少本项目不需要的 CUDA Provider 组件。

这个 fork 主要服务于 NeonSight / YoloDemoApp 桌面检测管线，用于为 YOLOv5、YOLOv8、YOLO11 以及类似目标检测 ONNX 模型提供更紧凑、可复现的 ONNX Runtime 制品。

## 项目目标

- 提供面向 Windows x64 的 YOLO 友好 ONNX Runtime 构建。
- 保留 CPU 推理作为稳定兜底能力。
- CI 环境可以准备 CUDA/cuDNN 时优先发布 CUDA 制品。
- 兼容 CUDA 13，但不把 CUDA 13 作为唯一支持目标。
- 以 install-root zip 形式发布 Release 制品，方便桌面应用直接集成。

## 主要差异

本 fork 新增 YOLO 精简构建开关：

```text
onnxruntime_NEONSIGHT_YOLO_LITE=ON
```

开启后，CUDA Provider 构建会移除或关闭普通 YOLO 图片/视频检测不需要的组件：

- `core/providers/cuda/llm/*` 下的 CUDA LLM Provider 源码
- Triton kernel 源文件条目
- 部分 Attention、RotaryEmbedding、TensorScatter CUDA kernel 注册
- FlashAttention、LeanAttention、MemoryEfficientAttention、FP8 KV Cache、CUDA NHWC 扩展、Float8、Float4 构建特性

CUDA 架构处理也不再把 `120` 强制转换为 `120a-real`，以便更好兼容常见消费级 RTX 50 系显卡的 `sm_120` 构建目标。

## Release 制品

Release 制品由 `yolo-lite-v*` 标签触发发布。

每个 zip 使用 install-root 目录结构：

```text
onnxruntime-yolo-lite-win-x64-*/
  include/onnxruntime/*.h
  lib/onnxruntime.lib
  bin/onnxruntime.dll
  bin/onnxruntime_providers_shared.dll
  bin/onnxruntime_providers_cuda.dll
  BUILD_INFO.json
```

CPU 制品不包含 `onnxruntime_providers_cuda.dll`。CUDA 构建成功时，CUDA 制品会包含该 Provider DLL。

## CI/CD 行为

Release workflow 位于：

```text
.github/workflows/neonsight-yolo-lite-release.yml
```

推送匹配 `yolo-lite-v*` 的标签，或手动运行 workflow 时会触发构建。

workflow 会优先尝试 CUDA：

1. 如果 runner 已经存在 `CUDA_PATH` / `CUDNN_HOME`，优先复用。
2. 如果缺失，则在 CI 中自动下载并安装 CUDA Toolkit 和 cuDNN。
3. 构建 CUDA YOLO 精简版共享库。
4. 如果任意 CUDA 步骤失败，继续构建 CPU install-root 兜底包。
5. 将成功产出的制品发布到 GitHub Releases。

可用仓库变量：

```text
ORT_YOLO_CUDA_VERSION=13.0.2
ORT_YOLO_CUDNN_VERSION=9.17.0
ORT_YOLO_CUDA_ARCHITECTURES=86;89;120
ORT_YOLO_CUDA_RUNNER_LABELS=["self-hosted","Windows","X64","CUDA"]
ORT_YOLO_CUDA_INSTALLER_URL=<自定义 CUDA Windows 网络安装器 URL>
ORT_YOLO_CUDNN_MANIFEST_URL=<自定义 cuDNN redist manifest URL>
ORT_YOLO_CUDA_INSTALL_COMPONENTS=<CUDA silent installer 组件列表>
```

GitHub 托管 Windows runner 可以在 CUDA/cuDNN 安装成功时编译 CUDA 制品，但它不能替代真实 GPU 推理验证。若要做真实 CUDA 运行时验收，建议使用带 NVIDIA GPU 的 Windows self-hosted runner。

## 本地构建

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

CUDA YOLO 精简版 install-root：

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

## 使用制品

下载最新 Release zip，解压后在应用构建中使用：

- `include/`：ONNX Runtime 头文件
- `lib/onnxruntime.lib`：链接库
- `bin/`：运行时 DLL 部署目录

如果使用 CUDA 制品，需要确保目标机器有兼容的 NVIDIA 驱动，并且所需 CUDA/cuDNN 运行时 DLL 位于应用目录或 `PATH` 中。

## 同步上游

本 fork 的默认分支是 `yolo-lite-cicd`。

推荐的上游同步流程：

```powershell
git switch yolo-lite-cicd
git fetch upstream
git switch -c sync-upstream-YYYYMMDD
git merge upstream/main
```

解决冲突、运行 YOLO 精简版 CI/构建检查后，再把同步分支合并回 `yolo-lite-cicd`。

不要把该分支强制 reset 到上游 `main`，否则会丢失 YOLO 精简构建改动。

## 更多文档

- [YOLO 精简版构建说明](docs/NEONSIGHT_YOLO_LITE_BUILD.md)
- [ONNX Runtime 官方文档](https://onnxruntime.ai/docs/)
- [ONNX Runtime 官方仓库](https://github.com/microsoft/onnxruntime)

## 许可证

本 fork 沿用上游 ONNX Runtime 许可证。详见 [LICENSE](LICENSE)。
