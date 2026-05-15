param(
  [Parameter(Mandatory = $true)]
  [string]$MirrorRoot,

  [string]$DepsFile = "cmake\deps.txt",

  [string[]]$IncludeNames = @()
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Invoke-DownloadWithRetry {
  param(
    [string]$Uri,
    [string]$OutFile
  )

  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutFile) | Out-Null
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
      Write-Host "下载 CMake 依赖: $Uri"
      Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $OutFile -TimeoutSec 1800
      return
    } catch {
      if ($attempt -eq 3) {
        throw
      }
      Write-Warning "CMake 依赖下载失败，准备重试 $attempt/3: $($_.Exception.Message)"
      Start-Sleep -Seconds 10
    }
  }
}

function Convert-HttpsUrlToMirrorPath {
  param(
    [string]$Root,
    [string]$Url
  )

  $relativePath = $Url -replace "^https://", ""
  $segments = $relativePath -split "/"
  $path = $Root
  foreach ($segment in $segments) {
    $path = Join-Path $path $segment
  }
  return $path
}

function Test-FileSha1 {
  param(
    [string]$Path,
    [string]$ExpectedSha1
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $false
  }

  $file = Get-Item -LiteralPath $Path
  if ($file.Length -le 0) {
    return $false
  }

  $actualSha1 = (Get-FileHash -LiteralPath $Path -Algorithm SHA1).Hash.ToLowerInvariant()
  return $actualSha1 -eq $ExpectedSha1.ToLowerInvariant()
}

$mirrorRootFull = [System.IO.Path]::GetFullPath($MirrorRoot)
$depsFileFull = [System.IO.Path]::GetFullPath($DepsFile)
New-Item -ItemType Directory -Force -Path $mirrorRootFull | Out-Null
$includeSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$matchedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($name in $IncludeNames) {
  if (-not [string]::IsNullOrWhiteSpace($name)) {
    $includeSet.Add($name) | Out-Null
  }
}

$downloaded = 0
$reused = 0
foreach ($line in Get-Content -LiteralPath $depsFileFull) {
  $trimmed = $line.Trim()
  if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
    continue
  }

  $parts = $trimmed -split ";"
  if ($parts.Count -lt 3) {
    continue
  }

  $name = $parts[0]
  $url = $parts[1]
  $sha1 = $parts[2].ToLowerInvariant()
  if ($includeSet.Count -gt 0 -and -not $includeSet.Contains($name)) {
    continue
  }
  $matchedSet.Add($name) | Out-Null

  if (-not $url.StartsWith("https://", [System.StringComparison]::OrdinalIgnoreCase)) {
    continue
  }

  $targetPath = Convert-HttpsUrlToMirrorPath -Root $mirrorRootFull -Url $url
  if (Test-FileSha1 -Path $targetPath -ExpectedSha1 $sha1) {
    Write-Host "使用缓存 CMake 依赖: $targetPath"
    $reused++
    continue
  }

  if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
    Write-Warning "缓存 CMake 依赖校验失败，重新下载: $targetPath"
    Remove-Item -LiteralPath $targetPath -Force
  }

  Invoke-DownloadWithRetry -Uri $url -OutFile $targetPath

  $actualSha1 = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA1).Hash.ToLowerInvariant()
  if ($actualSha1 -ne $sha1) {
    Remove-Item -LiteralPath $targetPath -Force
    throw "CMake 依赖 SHA1 校验失败: $url，期望 $sha1，实际 $actualSha1"
  }

  $downloaded++
}

foreach ($requestedName in $includeSet) {
  if (-not $matchedSet.Contains($requestedName)) {
    Write-Warning "请求缓存的 CMake 依赖未在 deps.txt 中找到: $requestedName"
  }
}

if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_ENV)) {
  "ORT_YOLO_CMAKE_DEPS_MIRROR_DIR=$mirrorRootFull" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
}

Write-Host "CMake 依赖镜像准备完成: $mirrorRootFull"
Write-Host "复用: $reused，新增下载: $downloaded"
