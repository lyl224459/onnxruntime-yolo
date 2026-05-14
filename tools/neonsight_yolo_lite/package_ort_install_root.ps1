param(
    [Parameter(Mandatory = $true)]
    [string]$BuildDir,

    [string]$SourceRoot = ".",

    [Parameter(Mandatory = $true)]
    [string]$OutputDir,

    [Parameter(Mandatory = $true)]
    [string]$PackageName,

    [ValidateSet("cpu", "cuda")]
    [string]$PackageKind = "cpu"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Resolve-FullPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Find-BuildFile([string]$Root, [string]$Name, [switch]$Required) {
    $candidates = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter $Name -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notmatch '\\(_deps|CMakeFiles|Testing|testdata|models)\\'
        } |
        Sort-Object @{ Expression = { if ($_.FullName -match '\\Release\\') { 0 } else { 1 } } }, FullName

    $file = @($candidates | Select-Object -First 1)[0]
    if ($Required -and $null -eq $file) {
        throw "未找到构建产物: $Name"
    }
    return $file
}

function Copy-BuildFile([string]$Name, [string]$DestinationDir, [switch]$Required) {
    $file = Find-BuildFile $buildRoot $Name -Required:$Required
    if ($null -eq $file) {
        return $null
    }
    $target = Join-Path $DestinationDir $file.Name
    Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    return $target
}

$buildRoot = Resolve-FullPath $BuildDir
$sourceRootFull = Resolve-FullPath $SourceRoot
$outputRoot = Resolve-FullPath $OutputDir
$stagingRoot = Join-Path $outputRoot "_staging"
$packageRoot = Join-Path $stagingRoot $PackageName
$archivePath = Join-Path $outputRoot "$PackageName.zip"

if (-not (Test-Path -LiteralPath $buildRoot -PathType Container)) {
    throw "构建目录不存在: $buildRoot"
}
if (-not (Test-Path -LiteralPath $sourceRootFull -PathType Container)) {
    throw "源码目录不存在: $sourceRootFull"
}

Remove-Item -LiteralPath $packageRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path (Join-Path $packageRoot "include\onnxruntime") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $packageRoot "lib") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $packageRoot "bin") -Force | Out-Null

# 只复制 C/C++ 推理 API 头文件，保持制品面向桌面 YOLO 推理链路的最小 install-root 布局。
$headerRoot = Join-Path $sourceRootFull "include\onnxruntime\core\session"
if (-not (Test-Path -LiteralPath $headerRoot -PathType Container)) {
    throw "未找到 ORT session 头文件目录: $headerRoot"
}
Get-ChildItem -LiteralPath $headerRoot -Filter "onnxruntime*.h" -File |
    Copy-Item -Destination (Join-Path $packageRoot "include\onnxruntime") -Force

$copied = @()
$copied += Copy-BuildFile "onnxruntime.lib" (Join-Path $packageRoot "lib") -Required
$copied += Copy-BuildFile "onnxruntime.dll" (Join-Path $packageRoot "bin") -Required
$sharedProvider = Copy-BuildFile "onnxruntime_providers_shared.dll" (Join-Path $packageRoot "bin")
if ($sharedProvider) {
    $copied += $sharedProvider
}
if ($PackageKind -eq "cuda") {
    $copied += Copy-BuildFile "onnxruntime_providers_cuda.dll" (Join-Path $packageRoot "bin") -Required
}

$versionPath = Join-Path $sourceRootFull "VERSION_NUMBER"
$version = if (Test-Path -LiteralPath $versionPath -PathType Leaf) {
    (Get-Content -LiteralPath $versionPath -Raw).Trim()
} else {
    "unknown"
}

$commit = ""
try {
    $commit = (git -C $sourceRootFull rev-parse HEAD).Trim()
} catch {
    $commit = ""
}

$manifest = [ordered]@{
    name = $PackageName
    kind = $PackageKind
    version = $version
    sourceCommit = $commit
    generatedAt = (Get-Date).ToUniversalTime().ToString("o")
    layout = "include/lib/bin"
    requiredFiles = @(
        "include/onnxruntime/onnxruntime_cxx_api.h",
        "lib/onnxruntime.lib",
        "bin/onnxruntime.dll"
    )
    files = @(
        Get-ChildItem -LiteralPath $packageRoot -Recurse -File |
            ForEach-Object { $_.FullName.Substring($packageRoot.Length + 1).Replace("\", "/") }
    )
}
if ($PackageKind -eq "cuda") {
    $manifest.requiredFiles += "bin/onnxruntime_providers_cuda.dll"
}

$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $packageRoot "BUILD_INFO.json") -Encoding UTF8

New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
Compress-Archive -Path $packageRoot -DestinationPath $archivePath -CompressionLevel Optimal

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash.ToLowerInvariant()
$summary = @(
    "# NeonSight YOLO Lite ORT 制品",
    "",
    "- 名称: $PackageName",
    "- 类型: $PackageKind",
    "- ORT 版本: $version",
    "- 源码提交: $commit",
    "- 压缩包: $archivePath",
    "- SHA256: $hash",
    "",
    "## 文件",
    ""
)
$summary += Get-ChildItem -LiteralPath $packageRoot -Recurse -File |
    ForEach-Object { "- " + $_.FullName.Substring($packageRoot.Length + 1).Replace("\", "/") }
$summary | Set-Content -LiteralPath (Join-Path $outputRoot "$PackageName.md") -Encoding UTF8

Write-Host "已生成 ORT install-root 制品: $archivePath"
Write-Host "SHA256: $hash"
