param(
  [string]$CudaVersion = "13.0.2",
  [string]$CudnnVersion = "9.17.0",
  [string]$CudaInstallerUrl = "",
  [string]$CudnnManifestUrl = "",
  [string]$InstallRoot = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Get-MajorMinorVersion {
  param([string]$Version)
  $parts = $Version.Split(".")
  if ($parts.Count -lt 2) {
    throw "版本号格式无效: $Version"
  }
  return "$($parts[0]).$($parts[1])"
}

function Invoke-DownloadWithRetry {
  param(
    [string]$Uri,
    [string]$OutFile
  )

  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutFile) | Out-Null
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
      Write-Host "下载: $Uri"
      Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $OutFile -TimeoutSec 1800
      return
    } catch {
      if ($attempt -eq 3) {
        throw
      }
      Write-Warning "下载失败，准备重试 $attempt/3: $($_.Exception.Message)"
      Start-Sleep -Seconds 10
    }
  }
}

function Set-CiEnvironmentValue {
  param(
    [string]$Name,
    [string]$Value
  )

  [Environment]::SetEnvironmentVariable($Name, $Value, "Process")
  if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_ENV)) {
    "$Name=$Value" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
  }
}

function Add-CiPathValue {
  param([string]$PathValue)

  if ([string]::IsNullOrWhiteSpace($PathValue) -or -not (Test-Path -LiteralPath $PathValue -PathType Container)) {
    return
  }

  $env:PATH = "$PathValue;$env:PATH"
  if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_PATH)) {
    $PathValue | Out-File -FilePath $env:GITHUB_PATH -Append -Encoding utf8
  }
}

function Test-CudaHome {
  param([string]$Candidate)

  if ([string]::IsNullOrWhiteSpace($Candidate)) {
    return $false
  }

  $expanded = [Environment]::ExpandEnvironmentVariables($Candidate)
  return (Test-Path -LiteralPath (Join-Path $expanded "bin\nvcc.exe") -PathType Leaf) -and
    (Test-Path -LiteralPath (Join-Path $expanded "include\cuda.h") -PathType Leaf)
}

function Find-CudaHome {
  param([string]$CudaMajorMinor)

  $candidates = @(
    $env:CUDA_PATH,
    $env:CUDA_HOME,
    "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v$CudaMajorMinor"
  )

  $cudaRoot = "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA"
  if (Test-Path -LiteralPath $cudaRoot -PathType Container) {
    $candidates += Get-ChildItem -LiteralPath $cudaRoot -Directory -ErrorAction SilentlyContinue |
      Sort-Object Name -Descending |
      ForEach-Object { $_.FullName }
  }

  foreach ($candidate in $candidates) {
    if (Test-CudaHome $candidate) {
      return ([System.IO.DirectoryInfo][Environment]::ExpandEnvironmentVariables($candidate)).FullName
    }
  }

  return ""
}

function Install-CudaToolkit {
  param(
    [string]$CudaVersion,
    [string]$CudaMajorMinor,
    [string]$InstallerUrl,
    [string]$InstallRootPath
  )

  if ([string]::IsNullOrWhiteSpace($InstallerUrl)) {
    $InstallerUrl = "https://developer.download.nvidia.com/compute/cuda/$CudaVersion/network_installers/cuda_$($CudaVersion)_windows_network.exe"
  }

  $installerPath = Join-Path $InstallRootPath "downloads\cuda_$($CudaVersion)_windows_network.exe"
  Invoke-DownloadWithRetry -Uri $InstallerUrl -OutFile $installerPath

  $componentText = $env:ORT_YOLO_CUDA_INSTALL_COMPONENTS
  $useDefaultComponents = [string]::IsNullOrWhiteSpace($componentText)
  if ([string]::IsNullOrWhiteSpace($componentText)) {
    # 只安装 ORT CUDA Provider 编译所需的核心工具链和数学库，避免 CI 拉取不必要的 Nsight/文档组件。
    $componentText = @(
      "cccl_$CudaMajorMinor",
      "crt_$CudaMajorMinor",
      "cudart_$CudaMajorMinor",
      "nvcc_$CudaMajorMinor",
      "nvrtc_$CudaMajorMinor",
      "nvrtc_dev_$CudaMajorMinor",
      "cublas_$CudaMajorMinor",
      "cublas_dev_$CudaMajorMinor",
      "cufft_$CudaMajorMinor",
      "cufft_dev_$CudaMajorMinor",
      "curand_$CudaMajorMinor",
      "curand_dev_$CudaMajorMinor",
      "nvtx_$CudaMajorMinor",
      "nvml_dev_$CudaMajorMinor",
      "nvvm_$CudaMajorMinor",
      "nvptxcompiler_$CudaMajorMinor",
      "nvjitlink_$CudaMajorMinor"
    ) -join ";"
  }

  $components = $componentText -split "[;,\s]+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  $arguments = @("-s") + $components
  Write-Host "安装 CUDA Toolkit $CudaVersion，组件: $($components -join ', ')"

  $process = Start-Process -FilePath $installerPath -ArgumentList $arguments -Wait -PassThru -NoNewWindow
  if (@(0, 3010) -notcontains $process.ExitCode) {
    if ($useDefaultComponents) {
      Write-Warning "CUDA 组件化安装失败，返回代码: $($process.ExitCode)。将自动退回完整 CUDA silent 安装。"
      $process = Start-Process -FilePath $installerPath -ArgumentList @("-s") -Wait -PassThru -NoNewWindow
      if (@(0, 3010) -contains $process.ExitCode) {
        return
      }
    }
    throw "CUDA 安装器返回失败代码: $($process.ExitCode)"
  }
}

function Test-CudnnHome {
  param([string]$Candidate)

  if ([string]::IsNullOrWhiteSpace($Candidate) -or -not (Test-Path -LiteralPath $Candidate -PathType Container)) {
    return $false
  }

  $hasHeader = Test-Path -LiteralPath (Join-Path $Candidate "include\cudnn.h") -PathType Leaf
  $hasLibrary = [bool](Get-ChildItem -LiteralPath $Candidate -Recurse -Filter "cudnn*.lib" -File -ErrorAction SilentlyContinue | Select-Object -First 1)
  $hasRuntime = [bool](Get-ChildItem -LiteralPath $Candidate -Recurse -Filter "cudnn*.dll" -File -ErrorAction SilentlyContinue | Select-Object -First 1)
  return $hasHeader -and $hasLibrary -and $hasRuntime
}

function Find-CudnnHome {
  $candidates = @($env:CUDNN_HOME, $env:CUDNN_PATH)
  foreach ($candidate in $candidates) {
    if (Test-CudnnHome $candidate) {
      return ([System.IO.DirectoryInfo][Environment]::ExpandEnvironmentVariables($candidate)).FullName
    }
  }
  return ""
}

function Get-CudnnArchiveRoot {
  param([string]$ExpandedRoot)

  $candidates = @()
  if (Test-Path -LiteralPath (Join-Path $ExpandedRoot "include\cudnn.h") -PathType Leaf) {
    $candidates += Get-Item -LiteralPath $ExpandedRoot
  }
  $candidates += Get-ChildItem -LiteralPath $ExpandedRoot -Directory -Recurse -ErrorAction SilentlyContinue |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "include\cudnn.h") -PathType Leaf }

  if (-not $candidates -or $candidates.Count -eq 0) {
    throw "cuDNN 解压目录中没有找到 include\cudnn.h"
  }

  return $candidates[0].FullName
}

function Copy-CudnnFiles {
  param(
    [string]$SourceRoot,
    [string]$TargetRoot
  )

  if (Test-Path -LiteralPath $TargetRoot) {
    Remove-Item -LiteralPath $TargetRoot -Recurse -Force
  }

  New-Item -ItemType Directory -Force -Path (Join-Path $TargetRoot "include") | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $TargetRoot "lib") | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $TargetRoot "lib\x64") | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $TargetRoot "bin") | Out-Null

  Copy-Item -Path (Join-Path $SourceRoot "include\*") -Destination (Join-Path $TargetRoot "include") -Recurse -Force

  $libraries = Get-ChildItem -LiteralPath $SourceRoot -Recurse -Filter "cudnn*.lib" -File -ErrorAction SilentlyContinue
  $runtimes = Get-ChildItem -LiteralPath $SourceRoot -Recurse -Filter "cudnn*.dll" -File -ErrorAction SilentlyContinue

  if (-not $libraries) {
    throw "cuDNN 解压目录中没有找到 cudnn*.lib"
  }
  if (-not $runtimes) {
    throw "cuDNN 解压目录中没有找到 cudnn*.dll"
  }

  foreach ($library in $libraries) {
    Copy-Item -LiteralPath $library.FullName -Destination (Join-Path $TargetRoot "lib") -Force
    Copy-Item -LiteralPath $library.FullName -Destination (Join-Path $TargetRoot "lib\x64") -Force
  }
  foreach ($runtime in $runtimes) {
    Copy-Item -LiteralPath $runtime.FullName -Destination (Join-Path $TargetRoot "bin") -Force
  }

  return $TargetRoot
}

function Install-Cudnn {
  param(
    [string]$CudnnVersion,
    [string]$CudaMajor,
    [string]$ManifestUrl,
    [string]$InstallRootPath
  )

  if ([string]::IsNullOrWhiteSpace($ManifestUrl)) {
    $ManifestUrl = "https://developer.download.nvidia.com/compute/cudnn/redist/redistrib_$CudnnVersion.json"
  }

  $manifestPath = Join-Path $InstallRootPath "downloads\cudnn_$CudnnVersion.json"
  Invoke-DownloadWithRetry -Uri $ManifestUrl -OutFile $manifestPath
  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

  $platform = $manifest.cudnn."windows-x86_64"
  $variantName = "cuda$CudaMajor"
  $entry = $platform.$variantName
  if (-not $entry) {
    throw "cuDNN $CudnnVersion manifest 中没有 windows-x86_64/$variantName 条目"
  }

  $archiveUrl = "https://developer.download.nvidia.com/compute/cudnn/redist/$($entry.relative_path)"
  $archivePath = Join-Path $InstallRootPath ("downloads\" + [System.IO.Path]::GetFileName($entry.relative_path))
  Invoke-DownloadWithRetry -Uri $archiveUrl -OutFile $archivePath

  $hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($hash -ne $entry.sha256.ToLowerInvariant()) {
    throw "cuDNN SHA256 校验失败。期望 $($entry.sha256)，实际 $hash"
  }

  $expandedRoot = Join-Path $InstallRootPath "expanded\cudnn-$CudnnVersion-$variantName"
  if (Test-Path -LiteralPath $expandedRoot) {
    Remove-Item -LiteralPath $expandedRoot -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $expandedRoot | Out-Null
  Expand-Archive -LiteralPath $archivePath -DestinationPath $expandedRoot -Force

  $archiveRoot = Get-CudnnArchiveRoot -ExpandedRoot $expandedRoot
  $normalizedRoot = Join-Path $InstallRootPath "cudnn-$CudnnVersion-$variantName"
  return Copy-CudnnFiles -SourceRoot $archiveRoot -TargetRoot $normalizedRoot
}

$cudaMajorMinor = Get-MajorMinorVersion $CudaVersion
$cudaMajor = $cudaMajorMinor.Split(".")[0]
if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
  $InstallRoot = if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    Join-Path $env:TEMP "ort-yolo-cuda"
  } else {
    Join-Path $env:RUNNER_TEMP "ort-yolo-cuda"
  }
}
New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null

$cudaHome = Find-CudaHome -CudaMajorMinor $cudaMajorMinor
if ([string]::IsNullOrWhiteSpace($cudaHome)) {
  Install-CudaToolkit -CudaVersion $CudaVersion -CudaMajorMinor $cudaMajorMinor -InstallerUrl $CudaInstallerUrl -InstallRootPath $InstallRoot
  $cudaHome = Find-CudaHome -CudaMajorMinor $cudaMajorMinor
}
if ([string]::IsNullOrWhiteSpace($cudaHome)) {
  throw "CUDA Toolkit 安装后仍未找到 nvcc.exe"
}

$cudnnHome = Find-CudnnHome
if ([string]::IsNullOrWhiteSpace($cudnnHome)) {
  $cudnnHome = Install-Cudnn -CudnnVersion $CudnnVersion -CudaMajor $cudaMajor -ManifestUrl $CudnnManifestUrl -InstallRootPath $InstallRoot
}
if (-not (Test-CudnnHome $cudnnHome)) {
  throw "cuDNN 安装后校验失败: $cudnnHome"
}

Set-CiEnvironmentValue -Name "CUDA_PATH" -Value $cudaHome
Set-CiEnvironmentValue -Name "CUDA_HOME" -Value $cudaHome
Set-CiEnvironmentValue -Name "CUDNN_HOME" -Value $cudnnHome
Set-CiEnvironmentValue -Name "CUDNN_PATH" -Value $cudnnHome
Add-CiPathValue -PathValue (Join-Path $cudaHome "bin")
Add-CiPathValue -PathValue (Join-Path $cudnnHome "bin")

if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
  "cuda_home=$cudaHome" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
  "cudnn_home=$cudnnHome" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}

Write-Host "CUDA_HOME=$cudaHome"
Write-Host "CUDNN_HOME=$cudnnHome"
& (Join-Path $cudaHome "bin\nvcc.exe") --version
