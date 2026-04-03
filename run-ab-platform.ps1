<#
.SYNOPSIS
Downloads Airbyte Docker Compose assets (if needed) and starts the platform.

.DESCRIPTION
This repo doesn't ship the OSS Docker Compose assets directly. The canonical assets
live in the airbyte-platform repo under a versioned tag (e.g. v0.63.0).

This script mirrors the behavior of Airbyte's historical `run-ab-platform.sh`:
- Downloads `docker-compose.yaml`, `docker-compose.debug.yaml`, `flags.yml`,
  and `temporal/dynamicconfig/development.yaml`.
- Keeps your existing `.env` / `.env.dev` unless you ask to refresh them.
- Runs `docker compose up` (optionally detached / with debug override).
#>

[CmdletBinding()]
param(
  [string] $Version,
  [switch] $DownloadOnly,
  [switch] $Refresh,
  [switch] $DownloadEnv,
  [switch] $ComposeDebug,
  [switch] $Background
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-EnvValueFromFile {
  param(
    [Parameter(Mandatory = $true)][string] $Path,
    [Parameter(Mandatory = $true)][string] $Key
  )
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  $line = (Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue) |
    Where-Object { $_ -match "^\s*$([regex]::Escape($Key))\s*=" } |
    Select-Object -First 1
  if (-not $line) { return $null }
  $value = $line -replace "^\s*$([regex]::Escape($Key))\s*=\s*", ''
  return $value.Trim()
}

function Ensure-ParentDir {
  param([Parameter(Mandatory = $true)][string] $Path)
  $parent = Split-Path -Parent $Path
  if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent | Out-Null
  }
}

function Should-Redownload {
  param(
    [Parameter(Mandatory = $true)][string] $Path,
    [Parameter(Mandatory = $true)][int] $MinBytes
  )

  if ($Refresh) { return $true }
  if (-not (Test-Path -LiteralPath $Path)) { return $true }

  try {
    $len = (Get-Item -LiteralPath $Path).Length
    if ($len -lt $MinBytes) { return $true }
  } catch {
    return $true
  }

  return $false
}

function Download-Asset {
  param(
    [Parameter(Mandatory = $true)][string] $BaseUrl,
    [Parameter(Mandatory = $true)][string] $RemotePath,
    [Parameter(Mandatory = $true)][string] $LocalPath
  )

  Ensure-ParentDir -Path $LocalPath
  $uri = ($BaseUrl.TrimEnd('/') + '/' + $RemotePath.TrimStart('/'))
  Write-Host ("Downloading: {0}" -f $uri)

  # Older Windows / PowerShell sometimes negotiate TLS poorly; force TLS 1.2+ when available.
  try {
    [Net.ServicePointManager]::SecurityProtocol = `
      [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
  } catch {
    # Ignore on older frameworks without TLS 1.3
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
  }

  $iwr = Get-Command Invoke-WebRequest -ErrorAction Stop
  if ($iwr.Parameters.ContainsKey('UseBasicParsing')) {
    Invoke-WebRequest -Uri $uri -OutFile $LocalPath -UseBasicParsing
  } else {
    Invoke-WebRequest -Uri $uri -OutFile $LocalPath
  }
}

function Try-DownloadAssetsForVersion {
  param(
    [Parameter(Mandatory = $true)][string] $ResolvedVersion
  )

  $baseUrl = "https://raw.githubusercontent.com/airbytehq/airbyte-platform/v$ResolvedVersion/"

  # Paths are relative to the tag root.
  $assets = @(
    @{ Remote = "docker-compose.yaml"; Local = "docker-compose.yaml"; MinBytes = 500; Always = $true },
    @{ Remote = "docker-compose.debug.yaml"; Local = "docker-compose.debug.yaml"; MinBytes = 200; Always = $true },
    @{ Remote = "flags.yml"; Local = "flags.yml"; MinBytes = 10; Always = $true },
    @{ Remote = "temporal/dynamicconfig/development.yaml"; Local = "temporal/dynamicconfig/development.yaml"; MinBytes = 10; Always = $true }
  )

  $envAssets = @(
    @{ Remote = ".env"; Local = ".env"; MinBytes = 10 },
    @{ Remote = ".env.dev"; Local = ".env.dev"; MinBytes = 10 }
  )

  foreach ($a in $assets) {
    $should = Should-Redownload -Path $a.Local -MinBytes $a.MinBytes
    if ($should) {
      Download-Asset -BaseUrl $baseUrl -RemotePath $a.Remote -LocalPath $a.Local
    }
  }

  foreach ($a in $envAssets) {
    # Don't overwrite a user's local `.env` on refresh unless explicitly requested.
    if ($DownloadEnv -or (-not (Test-Path -LiteralPath $a.Local))) {
      Download-Asset -BaseUrl $baseUrl -RemotePath $a.Remote -LocalPath $a.Local
    }
  }

  return $baseUrl
}

$pinnedFallbackVersion = "0.63.13"
$resolvedVersion =
  $(if ($Version) { $Version }
    else {
      $fromEnv = Get-EnvValueFromFile -Path ".env" -Key "VERSION"
      if ($fromEnv) { $fromEnv } else { $pinnedFallbackVersion }
    })

Write-Host ("Using version: {0}" -f $resolvedVersion)

$baseUrlUsed = $null
try {
  $baseUrlUsed = Try-DownloadAssetsForVersion -ResolvedVersion $resolvedVersion
} catch {
  Write-Warning ("Failed downloading assets for v{0}. Error: {1}" -f $resolvedVersion, $_.Exception.Message)
  if ($resolvedVersion -ne $pinnedFallbackVersion) {
    Write-Host ("Retrying with pinned fallback version: {0}" -f $pinnedFallbackVersion)
    $baseUrlUsed = Try-DownloadAssetsForVersion -ResolvedVersion $pinnedFallbackVersion
    $resolvedVersion = $pinnedFallbackVersion
  } else {
    throw
  }
}

Write-Host ("Assets source: {0}" -f $baseUrlUsed)

if ($DownloadOnly) {
  Write-Host "Download-only mode; not starting Docker Compose."
  exit 0
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  throw "Docker CLI not found. Install Docker Desktop and ensure `docker` is on PATH."
}

$composeArgs = @("compose", "-f", "docker-compose.yaml")
if ($ComposeDebug) {
  $composeArgs += @("-f", "docker-compose.debug.yaml")
}
$composeArgs += "up"
if ($Background) {
  $composeArgs += "-d"
}

Write-Host ("Running: docker {0}" -f ($composeArgs -join ' '))
& docker @composeArgs
