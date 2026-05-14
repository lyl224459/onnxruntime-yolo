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

function Get-CudaHomeMajorMinor {
  param([string]$CudaHome)

  if ([string]::IsNullOrWhiteSpace($CudaHome)) {
    return ""
  }

  $expanded = [Environment]::ExpandEnvironmentVariables($CudaHome)
  $leaf = Split-Path -Leaf $expanded
  if ($leaf -match "^v?(\d+\.\d+)") {
    return $Matches[1]
  }

  $versionJson = Join-Path $expanded "version.json"
  if (Test-Path -LiteralPath $versionJson -PathType Leaf) {
    try {
      $json = Get-Content -LiteralPath $versionJson -Raw | ConvertFrom-Json
      if ($json.cuda.version -match "^(\d+\.\d+)") {
        return $Matches[1]
      }
    } catch {
      Write-Verbose "读取 CUDA version.json 失败: $versionJson"
    }
  }

  $nvcc = Join-Path $expanded "bin\nvcc.exe"
  if (Test-Path -LiteralPath $nvcc -PathType Leaf) {
    try {
      $output = & $nvcc --version 2>$null
      $text = $output -join "`n"
      if ($text -match "release\s+(\d+\.\d+)") {
        return $Matches[1]
      }
    } catch {
      Write-Verbose "执行 nvcc --version 失败: $nvcc"
    }
  }

  return ""
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

function Add-PathCandidate {
  param(
    [System.Collections.Generic.List[string]]$Candidates,
    [string]$PathValue
  )

  if ([string]::IsNullOrWhiteSpace($PathValue)) {
    return
  }

  $expanded = [Environment]::ExpandEnvironmentVariables($PathValue)
  if (-not [string]::IsNullOrWhiteSpace($expanded) -and -not $Candidates.Contains($expanded)) {
    $Candidates.Add($expanded) | Out-Null
  }
}

function Add-CudaRegistryCandidates {
  param(
    [System.Collections.Generic.List[string]]$Candidates,
    [string]$CudaMajorMinor
  )

  $registryRoots = @(
    "HKLM:\SOFTWARE\NVIDIA Corporation\GPU Computing Toolkit\CUDA",
    "HKLM:\SOFTWARE\WOW6432Node\NVIDIA Corporation\GPU Computing Toolkit\CUDA"
  )
  foreach ($root in $registryRoots) {
    if (-not (Test-Path -LiteralPath $root)) {
      continue
    }

    $keys = @()
    $versionKey = Join-Path $root "v$CudaMajorMinor"
    if (Test-Path -LiteralPath $versionKey) {
      $keys += Get-Item -LiteralPath $versionKey
    }
    $keys += Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue

    foreach ($key in $keys) {
      try {
        $item = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
        foreach ($propertyName in @("InstallDir", "InstallPath", "CUDA_PATH")) {
          if ($item.PSObject.Properties.Name -contains $propertyName) {
            Add-PathCandidate -Candidates $Candidates -PathValue $item.$propertyName
          }
        }
      } catch {
        Write-Verbose "读取 CUDA 注册表项失败: $($key.PSPath)"
      }
    }
  }
}

function Find-CudaHome {
  param([string]$CudaMajorMinor)

  $candidates = [System.Collections.Generic.List[string]]::new()
  $envCudaVersionName = "CUDA_PATH_V$($CudaMajorMinor.Replace('.', '_'))"
  Add-PathCandidate -Candidates $candidates -PathValue ([Environment]::GetEnvironmentVariable($envCudaVersionName, "Process"))
  Add-PathCandidate -Candidates $candidates -PathValue ([Environment]::GetEnvironmentVariable($envCudaVersionName, "Machine"))
  Add-PathCandidate -Candidates $candidates -PathValue $env:CUDA_PATH
  Add-PathCandidate -Candidates $candidates -PathValue $env:CUDA_HOME

  Add-CudaRegistryCandidates -Candidates $candidates -CudaMajorMinor $CudaMajorMinor

  $programRoots = @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)}) |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -Unique
  foreach ($programRoot in $programRoots) {
    $cudaRoot = Join-Path $programRoot "NVIDIA GPU Computing Toolkit\CUDA"
    Add-PathCandidate -Candidates $candidates -PathValue (Join-Path $cudaRoot "v$CudaMajorMinor")
    if (Test-Path -LiteralPath $cudaRoot -PathType Container) {
      Get-ChildItem -LiteralPath $cudaRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Add-PathCandidate -Candidates $candidates -PathValue $_.FullName }
    }
  }

  $compatibleCandidate = ""
  $requestedMajor = $CudaMajorMinor.Split(".")[0]
  foreach ($candidate in $candidates) {
    if (Test-CudaHome $candidate) {
      $fullPath = ([System.IO.DirectoryInfo][Environment]::ExpandEnvironmentVariables($candidate)).FullName
      $candidateMajorMinor = Get-CudaHomeMajorMinor -CudaHome $fullPath
      if ($candidateMajorMinor -eq $CudaMajorMinor) {
        return $fullPath
      }
      if ([string]::IsNullOrWhiteSpace($compatibleCandidate) -and $candidateMajorMinor.StartsWith("$requestedMajor.")) {
        $compatibleCandidate = $fullPath
      }
    }
  }

  return $compatibleCandidate
}

function Find-VsWhere {
  $command = Get-Command "vswhere.exe" -ErrorAction SilentlyContinue
  if ($command) {
    return $command.Source
  }

  $candidates = @(
    (Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"),
    (Join-Path $env:ProgramFiles "Microsoft Visual Studio\Installer\vswhere.exe")
  )
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return $candidate
    }
  }
  return ""
}

function Find-VisualStudioRoots {
  $roots = [System.Collections.Generic.List[string]]::new()
  $vswhere = Find-VsWhere
  if (-not [string]::IsNullOrWhiteSpace($vswhere)) {
    try {
      & $vswhere -all -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath |
        ForEach-Object { Add-PathCandidate -Candidates $roots -PathValue $_ }
    } catch {
      Write-Verbose "vswhere 查询失败: $($_.Exception.Message)"
    }
  }

  $programRoots = @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)}) |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -Unique
  foreach ($programRoot in $programRoots) {
    $visualStudioRoot = Join-Path $programRoot "Microsoft Visual Studio"
    if (-not (Test-Path -LiteralPath $visualStudioRoot -PathType Container)) {
      continue
    }
    Get-ChildItem -LiteralPath $visualStudioRoot -Directory -ErrorAction SilentlyContinue |
      ForEach-Object {
        Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue |
          ForEach-Object { Add-PathCandidate -Candidates $roots -PathValue $_.FullName }
      }
  }

  return @($roots | Select-Object -Unique)
}

function Get-CudaVisualStudioTargets {
  param([string]$CudaMajorMinor)

  $targets = @()
  foreach ($vsRoot in Find-VisualStudioRoots) {
    $buildCustomizationsRoot = Join-Path $vsRoot "MSBuild\Microsoft\VC"
    if (-not (Test-Path -LiteralPath $buildCustomizationsRoot -PathType Container)) {
      continue
    }
    $targets += Get-ChildItem -LiteralPath $buildCustomizationsRoot -Recurse -File -Filter "CUDA $CudaMajorMinor.targets" -ErrorAction SilentlyContinue
  }
  return @($targets)
}

function Test-CudaVisualStudioIntegration {
  param([string]$CudaMajorMinor)
  return @((Get-CudaVisualStudioTargets -CudaMajorMinor $CudaMajorMinor) | Select-Object -First 1).Count -gt 0
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
      "nvjitlink_$CudaMajorMinor",
      "visual_studio_integration_$CudaMajorMinor"
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

  if ($useDefaultComponents -and -not (Test-CudaVisualStudioIntegration -CudaMajorMinor $CudaMajorMinor)) {
    Write-Warning "组件化安装后未找到 CUDA $CudaMajorMinor 的 Visual Studio 集成，将自动退回完整 CUDA silent 安装补齐依赖。"
    $process = Start-Process -FilePath $installerPath -ArgumentList @("-s") -Wait -PassThru -NoNewWindow
    if (@(0, 3010) -notcontains $process.ExitCode) {
      throw "完整 CUDA 安装器返回失败代码: $($process.ExitCode)"
    }
  }
}

function Get-CudnnLayout {
  param(
    [string]$Candidate,
    [string]$CudaMajorMinor = ""
  )

  if ([string]::IsNullOrWhiteSpace($Candidate) -or -not (Test-Path -LiteralPath $Candidate -PathType Container)) {
    return $null
  }

  $expanded = [Environment]::ExpandEnvironmentVariables($Candidate)
  $layouts = @()
  if (-not [string]::IsNullOrWhiteSpace($CudaMajorMinor)) {
    $layouts += [ordered]@{
      Root = $expanded
      Include = Join-Path $expanded "include\$CudaMajorMinor"
      Lib = Join-Path $expanded "lib\$CudaMajorMinor\x64"
      Bin = Join-Path $expanded "bin\$CudaMajorMinor\x64"
    }
  }
  $layouts += [ordered]@{
    Root = $expanded
    Include = Join-Path $expanded "include"
    Lib = Join-Path $expanded "lib\x64"
    Bin = Join-Path $expanded "bin"
  }
  $layouts += [ordered]@{
    Root = $expanded
    Include = Join-Path $expanded "include"
    Lib = Join-Path $expanded "lib"
    Bin = Join-Path $expanded "bin"
  }

  foreach ($layout in $layouts) {
    $hasHeader = Test-Path -LiteralPath (Join-Path $layout.Include "cudnn.h") -PathType Leaf
    $hasLibrary = (Test-Path -LiteralPath $layout.Lib -PathType Container) -and
      [bool](Get-ChildItem -LiteralPath $layout.Lib -Filter "cudnn*.lib" -File -ErrorAction SilentlyContinue | Select-Object -First 1)
    $hasRuntime = (Test-Path -LiteralPath $layout.Bin -PathType Container) -and
      [bool](Get-ChildItem -LiteralPath $layout.Bin -Filter "cudnn*.dll" -File -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($hasHeader -and $hasLibrary -and $hasRuntime) {
      return [pscustomobject]$layout
    }
  }

  return $null
}

function Test-CudnnHome {
  param(
    [string]$Candidate,
    [string]$CudaMajorMinor = ""
  )

  return $null -ne (Get-CudnnLayout -Candidate $Candidate -CudaMajorMinor $CudaMajorMinor)
}

function Find-CudnnHome {
  param(
    [string]$CudaMajorMinor,
    [string]$InstallRootPath
  )

  $candidates = [System.Collections.Generic.List[string]]::new()
  Add-PathCandidate -Candidates $candidates -PathValue $env:CUDNN_HOME
  Add-PathCandidate -Candidates $candidates -PathValue $env:CUDNN_PATH

  $programRoots = @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)}) |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -Unique
  foreach ($programRoot in $programRoots) {
    $nvidiaRoot = Join-Path $programRoot "NVIDIA\CUDNN"
    if (Test-Path -LiteralPath $nvidiaRoot -PathType Container) {
      Get-ChildItem -LiteralPath $nvidiaRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Add-PathCandidate -Candidates $candidates -PathValue $_.FullName }
    }
  }

  foreach ($candidate in $candidates) {
    $layout = Get-CudnnLayout -Candidate $candidate -CudaMajorMinor $CudaMajorMinor
    if ($layout) {
      $candidateFull = ([System.IO.DirectoryInfo][Environment]::ExpandEnvironmentVariables($candidate)).FullName
      $isCanonical = ($layout.Include -eq (Join-Path $candidateFull "include")) -and
        (($layout.Lib -eq (Join-Path $candidateFull "lib")) -or ($layout.Lib -eq (Join-Path $candidateFull "lib\x64"))) -and
        ($layout.Bin -eq (Join-Path $candidateFull "bin"))
      if ($isCanonical) {
        return $candidateFull
      }

      $normalizedRoot = Join-Path $InstallRootPath "cudnn-system-$CudaMajorMinor"
      return Copy-CudnnLayout -Layout $layout -TargetRoot $normalizedRoot
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

function Copy-CudnnLayout {
  param(
    [object]$Layout,
    [string]$TargetRoot
  )

  if (Test-Path -LiteralPath $TargetRoot) {
    Remove-Item -LiteralPath $TargetRoot -Recurse -Force
  }

  New-Item -ItemType Directory -Force -Path (Join-Path $TargetRoot "include") | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $TargetRoot "lib") | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $TargetRoot "lib\x64") | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $TargetRoot "bin") | Out-Null

  Copy-Item -Path (Join-Path $Layout.Include "*") -Destination (Join-Path $TargetRoot "include") -Recurse -Force

  $libraries = Get-ChildItem -LiteralPath $Layout.Lib -Filter "cudnn*.lib" -File -ErrorAction SilentlyContinue
  $runtimes = Get-ChildItem -LiteralPath $Layout.Bin -Filter "cudnn*.dll" -File -ErrorAction SilentlyContinue

  if (-not $libraries) {
    throw "cuDNN 布局中没有找到 cudnn*.lib: $($Layout.Lib)"
  }
  if (-not $runtimes) {
    throw "cuDNN 布局中没有找到 cudnn*.dll: $($Layout.Bin)"
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
$actualCudaMajorMinor = Get-CudaHomeMajorMinor -CudaHome $cudaHome
if ([string]::IsNullOrWhiteSpace($actualCudaMajorMinor)) {
  $actualCudaMajorMinor = $cudaMajorMinor
}
$cudaMajorMinor = $actualCudaMajorMinor
$cudaMajor = $cudaMajorMinor.Split(".")[0]
if (-not (Test-CudaVisualStudioIntegration -CudaMajorMinor $cudaMajorMinor)) {
  $vsRoots = Find-VisualStudioRoots
  $rootText = if ($vsRoots.Count -gt 0) { $vsRoots -join "; " } else { "未找到 Visual Studio VC 安装路径" }
  throw "CUDA $cudaMajorMinor 的 Visual Studio BuildCustomizations 缺失，CMake Visual Studio CUDA toolset 无法配置。请确认已安装 visual_studio_integration_$cudaMajorMinor 组件或完整 CUDA Toolkit。Visual Studio 路径: $rootText"
}

$cudnnHome = Find-CudnnHome -CudaMajorMinor $cudaMajorMinor -InstallRootPath $InstallRoot
if ([string]::IsNullOrWhiteSpace($cudnnHome)) {
  $cudnnHome = Install-Cudnn -CudnnVersion $CudnnVersion -CudaMajor $cudaMajor -ManifestUrl $CudnnManifestUrl -InstallRootPath $InstallRoot
}
if (-not (Test-CudnnHome -Candidate $cudnnHome -CudaMajorMinor $cudaMajorMinor)) {
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
  "cuda_version=$cudaMajorMinor" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
  "cudnn_home=$cudnnHome" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}

Write-Host "CUDA_HOME=$cudaHome"
Write-Host "CUDA_VERSION=$cudaMajorMinor"
Write-Host "CUDNN_HOME=$cudnnHome"
& (Join-Path $cudaHome "bin\nvcc.exe") --version
