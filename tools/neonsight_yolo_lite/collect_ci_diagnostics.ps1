param(
  [string[]]$BuildRoots = @(),

  [Parameter(Mandatory = $true)]
  [string]$OutputDir,

  [int]$MaxFiles = 300,

  [int]$MaxFileSizeMb = 50
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Resolve-FullPath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return ""
  }
  return [System.IO.Path]::GetFullPath($Path)
}

function Copy-DiagnosticFile {
  param(
    [System.IO.FileInfo]$File,
    [string]$Root,
    [string]$DestinationRoot,
    [System.Collections.Generic.List[string]]$Manifest
  )

  if ($File.Length -gt ($MaxFileSizeMb * 1MB)) {
    $Manifest.Add("- 跳过过大文件: $($File.FullName) ($([Math]::Round($File.Length / 1MB, 2)) MB)") | Out-Null
    return $false
  }

  $relative = $File.FullName.Substring($Root.Length).TrimStart("\", "/")
  if ([string]::IsNullOrWhiteSpace($relative)) {
    $relative = $File.Name
  }
  $relative = $relative -replace '[:*?"<>|]', "_"
  $target = Join-Path $DestinationRoot $relative
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
  Copy-Item -LiteralPath $File.FullName -Destination $target -Force
  $Manifest.Add("- $relative ($([Math]::Round($File.Length / 1KB, 1)) KB)") | Out-Null
  return $true
}

$outputRoot = Resolve-FullPath $OutputDir
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null

$manifest = [System.Collections.Generic.List[string]]::new()
$manifest.Add("# NeonSight YOLO Lite CI 诊断文件") | Out-Null
$manifest.Add("") | Out-Null
$manifest.Add("- 生成时间: $((Get-Date).ToUniversalTime().ToString("o"))") | Out-Null
$manifest.Add("- 最大文件数: $MaxFiles") | Out-Null
$manifest.Add("- 单文件上限: ${MaxFileSizeMb}MB") | Out-Null
$manifest.Add("") | Out-Null

$copied = 0
$patterns = @("*.log", "*.err", "*.tlog", "*.binlog", "CMakeCache.txt")
foreach ($buildRoot in $BuildRoots) {
  $root = Resolve-FullPath $buildRoot
  if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root -PathType Container)) {
    continue
  }

  Write-Host "收集构建诊断目录: $root"
  $manifest.Add("## $root") | Out-Null
  $manifest.Add("") | Out-Null

  $files = Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object {
      $name = $_.Name
      $patterns | Where-Object { $name -like $_ }
    } |
    Sort-Object @{ Expression = { if ($_.FullName -match "\\CMakeFiles\\") { 0 } else { 1 } } }, FullName

  foreach ($file in $files) {
    if ($copied -ge $MaxFiles) {
      $manifest.Add("- 已达到最大文件数限制，停止继续收集。") | Out-Null
      break
    }
    if (Copy-DiagnosticFile -File $file -Root $root -DestinationRoot (Join-Path $outputRoot ([System.IO.Path]::GetFileName($root))) -Manifest $manifest) {
      $copied++
    }
  }

  $manifest.Add("") | Out-Null
}

$manifest.Add("## 汇总") | Out-Null
$manifest.Add("") | Out-Null
$manifest.Add("- 已复制文件数: $copied") | Out-Null
$manifest | Set-Content -LiteralPath (Join-Path $outputRoot "diagnostic_manifest.md") -Encoding UTF8

Write-Host "CI 诊断文件收集完成: $outputRoot"
