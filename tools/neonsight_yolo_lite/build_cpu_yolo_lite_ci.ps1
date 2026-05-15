param(
  [Parameter(Mandatory = $true)]
  [string]$BuildRoot,

  [string]$PreferredGenerator = "Ninja"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

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

function Invoke-CpuBuild {
  param([string]$Generator)

  if ($Generator -eq "Ninja") {
    Import-MsvcDevEnvironment
    Ensure-Ninja
  }

  $buildDir = Get-BuildDirectory -Generator $Generator
  $buildArgs = @(
    "tools\ci_build\build.py",
    "--update",
    "--build",
    "--config", "Release",
    "--build_dir", $buildDir,
    "--skip_tests",
    "--parallel",
    "--cmake_generator", $Generator,
    "--build_shared_lib"
  )

  if (-not [string]::IsNullOrWhiteSpace($env:ORT_YOLO_CMAKE_DEPS_MIRROR_DIR) -and
      (Test-Path -LiteralPath $env:ORT_YOLO_CMAKE_DEPS_MIRROR_DIR -PathType Container)) {
    $buildArgs += @("--cmake_deps_mirror_dir", $env:ORT_YOLO_CMAKE_DEPS_MIRROR_DIR)
  }

  $defines = @(
    "onnxruntime_DISABLE_ML_OPS=ON",
    "onnxruntime_DISABLE_FLOAT8_TYPES=ON",
    "onnxruntime_DISABLE_FLOAT4_TYPES=ON"
  )
  foreach ($define in $defines) {
    $buildArgs += @("--cmake_extra_defines", $define)
  }

  Write-Host "CPU YOLO lite build.py 参数（$Generator）:"
  $buildArgs | ForEach-Object { Write-Host "  $_" }
  python @buildArgs
  if ($LASTEXITCODE -ne 0) {
    throw "$Generator 构建失败，退出代码: $LASTEXITCODE"
  }

  if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_ENV)) {
    "ORT_YOLO_CPU_BUILD_DIR=$buildDir" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
  }
}

$generators = [System.Collections.Generic.List[string]]::new()
Add-GeneratorCandidate -Generators $generators -Generator $PreferredGenerator
Add-GeneratorCandidate -Generators $generators -Generator "Visual Studio 17 2022"

$lastError = $null
foreach ($generator in $generators) {
  try {
    Invoke-CpuBuild -Generator $generator
    exit 0
  } catch {
    $lastError = $_
    Write-Warning "$generator 构建未完成: $($_.Exception.Message)"
  }
}

throw "CPU YOLO 精简版构建失败，最后错误: $($lastError.Exception.Message)"
