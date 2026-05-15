param(
  [Parameter(Mandatory = $true)]
  [string]$BuildRoot,

  [string]$CudaArchitectures = "89;120",
  [string]$CudaVersion = "",
  [string]$CudaHome = $env:CUDA_PATH,
  [string]$CudnnHome = $env:CUDNN_HOME,
  [string]$PreferredGenerator = "Ninja"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Get-CudaMajorMinor {
  param([string]$Version)

  if ([string]::IsNullOrWhiteSpace($Version)) {
    return "13.0"
  }

  $parts = $Version.Split(".")
  if ($parts.Count -lt 2) {
    throw "CUDA 版本号格式无效: $Version"
  }
  return "$($parts[0]).$($parts[1])"
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

function Import-MsvcDevEnvironment {
  if (Get-Command "cl.exe" -ErrorAction SilentlyContinue) {
    return
  }

  $vswhere = Find-VsWhere
  if ([string]::IsNullOrWhiteSpace($vswhere)) {
    throw "未找到 vswhere.exe，无法为 Ninja 初始化 MSVC 编译环境。"
  }

  $vsRoot = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1)
  if ([string]::IsNullOrWhiteSpace($vsRoot)) {
    throw "未找到包含 VC 工具链的 Visual Studio。"
  }

  $devShell = Join-Path $vsRoot "Common7\Tools\Launch-VsDevShell.ps1"
  if (Test-Path -LiteralPath $devShell -PathType Leaf) {
    try {
      & $devShell -Arch amd64 -HostArch amd64 -SkipAutomaticLocation
    } catch {
      Write-Warning "Launch-VsDevShell.ps1 初始化失败，将继续尝试 vcvars64.bat: $($_.Exception.Message)"
    }
  }

  if (Get-Command "cl.exe" -ErrorAction SilentlyContinue) {
    return
  }

  $vcvars = Join-Path $vsRoot "VC\Auxiliary\Build\vcvars64.bat"
  if (-not (Test-Path -LiteralPath $vcvars -PathType Leaf)) {
    throw "未找到 vcvars64.bat: $vcvars"
  }

  $cmd = "`"$vcvars`" && set"
  cmd.exe /d /s /c $cmd | ForEach-Object {
    if ($_ -match "^(.*?)=(.*)$") {
      [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], "Process")
    }
  }

  if (-not (Get-Command "cl.exe" -ErrorAction SilentlyContinue)) {
    throw "MSVC 环境初始化后仍未找到 cl.exe。"
  }
}

function Ensure-Ninja {
  if (Get-Command "ninja.exe" -ErrorAction SilentlyContinue) {
    return
  }

  Write-Host "未找到 ninja.exe，使用 pip 安装 Ninja。"
  python -m pip install ninja
  if ($LASTEXITCODE -ne 0) {
    throw "pip 安装 Ninja 失败。"
  }

  $scriptsPath = (python -c "import sysconfig; print(sysconfig.get_path('scripts'))").Trim()
  Add-CiPathValue -PathValue $scriptsPath

  if (-not (Get-Command "ninja.exe" -ErrorAction SilentlyContinue)) {
    throw "安装 Ninja 后仍未找到 ninja.exe。"
  }
}

function Normalize-CmakeGenerator {
  param([string]$Generator)

  $value = if ([string]::IsNullOrWhiteSpace($Generator)) { "Ninja" } else { $Generator.Trim() }
  switch -Regex ($value) {
    "^(?i)ninja$" { return "Ninja" }
    "^(?i)(vs|vs2022|visual studio|visual studio 2022|visual studio 17 2022)$" { return "Visual Studio 17 2022" }
    default {
      throw "不支持的 CMake 生成器: $Generator。当前 CI 只支持 Ninja 或 Visual Studio 17 2022。"
    }
  }
}

function Add-GeneratorCandidate {
  param(
    [System.Collections.Generic.List[string]]$Generators,
    [string]$Generator
  )

  $normalized = Normalize-CmakeGenerator -Generator $Generator
  if (-not $Generators.Contains($normalized)) {
    $Generators.Add($normalized) | Out-Null
  }
}

function Get-BuildDirectory {
  param([string]$Generator)

  if ($Generator -eq "Ninja") {
    return "$BuildRoot-ninja"
  }

  return "$BuildRoot-vs"
}

function Get-DiagnosticsRoot {
  $root = $env:RUNNER_TEMP
  if ([string]::IsNullOrWhiteSpace($root)) {
    $root = $env:TEMP
  }
  if ([string]::IsNullOrWhiteSpace($root)) {
    $root = [System.IO.Path]::GetTempPath()
  }

  $diagnosticsRoot = Join-Path $root "ort-yolo-diagnostics"
  New-Item -ItemType Directory -Force -Path $diagnosticsRoot | Out-Null
  if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_ENV)) {
    "ORT_YOLO_CUDA_DIAGNOSTIC_DIR=$diagnosticsRoot" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
  }
  return $diagnosticsRoot
}

function Invoke-PythonBuildWithLog {
  param(
    [string[]]$BuildArgs,
    [string]$Generator
  )

  $diagnosticsRoot = Get-DiagnosticsRoot
  $safeGenerator = $Generator -replace "[^A-Za-z0-9_.-]", "_"
  $logPath = Join-Path $diagnosticsRoot "cuda-$safeGenerator-build.log"
  Write-Host "CUDA 构建完整日志: $logPath"

  & python @BuildArgs 2>&1 | Tee-Object -FilePath $logPath | Out-Host
  $pythonExitCode = $LASTEXITCODE
  return $pythonExitCode
}

function New-BuildArguments {
  param(
    [string]$Generator,
    [string]$BuildDir
  )

  $cudaMajorMinor = Get-CudaMajorMinor -Version $CudaVersion
  $nvccPath = Join-Path $CudaHome "bin\nvcc.exe"
  if (-not (Test-Path -LiteralPath $nvccPath -PathType Leaf)) {
    throw "未找到 CUDA 编译器 nvcc.exe: $nvccPath"
  }
  $nvccCmakePath = ([System.IO.FileInfo]$nvccPath).FullName.Replace("\", "/")
  $buildArgs = @(
    "tools\ci_build\build.py",
    "--update",
    "--build",
    "--config", "Release",
    "--build_dir", $BuildDir,
    "--skip_tests",
    "--parallel",
    "--nvcc_threads", "1",
    "--cmake_generator", $Generator,
    "--build_shared_lib",
    "--use_cuda",
    "--cuda_home", $CudaHome,
    "--cudnn_home", $CudnnHome,
    "--disable_cuda_nhwc_ops",
    "--disable_types", "float8", "float4",
    "--no_kleidiai",
    "--no_sve"
  )

  if (-not [string]::IsNullOrWhiteSpace($env:ORT_YOLO_CMAKE_DEPS_MIRROR_DIR) -and
      (Test-Path -LiteralPath $env:ORT_YOLO_CMAKE_DEPS_MIRROR_DIR -PathType Container)) {
    $buildArgs += @("--cmake_deps_mirror_dir", $env:ORT_YOLO_CMAKE_DEPS_MIRROR_DIR)
  }

  $defines = @(
    "CMAKE_CUDA_ARCHITECTURES=$CudaArchitectures",
    "CMAKE_CUDA_COMPILER=$nvccCmakePath",
    "CMAKE_CUDA_FLAGS=-allow-unsupported-compiler -Xcompiler=/Zc:preprocessor -DCCCL_IGNORE_MSVC_TRADITIONAL_PREPROCESSOR_WARNING",
    "onnxruntime_CUDA_VERSION=$cudaMajorMinor",
    "onnxruntime_NEONSIGHT_YOLO_LITE=ON",
    "onnxruntime_USE_FLASH_ATTENTION=OFF",
    "onnxruntime_USE_LEAN_ATTENTION=OFF",
    "onnxruntime_USE_MEMORY_EFFICIENT_ATTENTION=OFF",
    "onnxruntime_USE_FP8_KV_CACHE=OFF"
  )

  if ($Generator -eq "Visual Studio 17 2022") {
    $cudaToolkitDir = ([System.IO.DirectoryInfo]$CudaHome).FullName.Replace("\", "/")
    $defines += "CMAKE_VS_GLOBALS=UseMultiToolTask=true;EnforceProcessCountAcrossBuilds=true;CudaToolkitDir=$cudaToolkitDir"
  } else {
    $cl = Get-Command "cl.exe" -ErrorAction SilentlyContinue
    if ($cl) {
      $defines += "CMAKE_CUDA_HOST_COMPILER=$($cl.Source.Replace('\', '/'))"
    }
  }

  foreach ($define in $defines) {
    $buildArgs += @("--cmake_extra_defines", $define)
  }

  return $buildArgs
}

function Invoke-CudaBuild {
  param([string]$Generator)

  if ($Generator -eq "Ninja") {
    Import-MsvcDevEnvironment
    Ensure-Ninja
  }

  $buildDir = Get-BuildDirectory -Generator $Generator
  $buildArgs = New-BuildArguments -Generator $Generator -BuildDir $buildDir

  Write-Host "CUDA YOLO lite build.py 参数（$Generator）:"
  $buildArgs | ForEach-Object { Write-Host "  $_" }
  $exitCode = Invoke-PythonBuildWithLog -BuildArgs $buildArgs -Generator $Generator
  if ($exitCode -ne 0) {
    throw "$Generator 构建失败，退出代码: $exitCode"
  }

  if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_ENV)) {
    "ORT_YOLO_CUDA_BUILD_DIR=$buildDir" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
  }
  Write-Host "CUDA YOLO 精简版构建成功，生成器: $Generator"
  Write-Host "ORT_YOLO_CUDA_BUILD_DIR=$buildDir"
}

if ([string]::IsNullOrWhiteSpace($CudaHome) -or -not (Test-Path -LiteralPath $CudaHome -PathType Container)) {
  throw "CUDA_HOME/CUDA_PATH 无效: $CudaHome"
}
if ([string]::IsNullOrWhiteSpace($CudnnHome) -or -not (Test-Path -LiteralPath $CudnnHome -PathType Container)) {
  throw "CUDNN_HOME 无效: $CudnnHome"
}

$generators = [System.Collections.Generic.List[string]]::new()
Add-GeneratorCandidate -Generators $generators -Generator $PreferredGenerator
Add-GeneratorCandidate -Generators $generators -Generator "Visual Studio 17 2022"

$lastError = $null
foreach ($generator in $generators) {
  try {
    Invoke-CudaBuild -Generator $generator
    exit 0
  } catch {
    $lastError = $_
    Write-Warning "$generator 构建未完成: $($_.Exception.Message)"
  }
}

throw "CUDA YOLO 精简版构建失败，最后错误: $($lastError.Exception.Message)"
