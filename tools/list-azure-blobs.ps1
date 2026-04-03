param(
  [Parameter(Mandatory = $true)]
  [string]$AccountName,

  [Parameter(Mandatory = $true)]
  [string]$Container,

  [Parameter(Mandatory = $false)]
  [string]$AccountKey,

  [Parameter(Mandatory = $false)]
  [string]$SasToken,

  [Parameter(Mandatory = $false)]
  [int]$MaxResults = 5000,

  [Parameter(Mandatory = $false)]
  [string]$Prefix,

  [Parameter(Mandatory = $false)]
  [switch]$Detailed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CanonicalizedResource {
  param(
    [string]$AccountName,
    [string]$Container,
    [hashtable]$Query
  )

  $lines = @("/$AccountName/$Container")
  foreach ($key in ($Query.Keys | Sort-Object)) {
    $value = [string]$Query[$key]
    $lines += ("{0}:{1}" -f $key.ToLowerInvariant(), $value)
  }
  return ($lines -join "`n")
}

function Get-SharedKeyAuthorizationHeader {
  param(
    [string]$AccountName,
    [string]$AccountKey,
    [string]$XmsDate,
    [string]$XmsVersion,
    [string]$CanonicalizedResource
  )

  $canonicalizedHeaders = @(
    "x-ms-date:$XmsDate"
    "x-ms-version:$XmsVersion"
  ) -join "`n"
  $canonicalizedHeaders += "`n"

  $stringToSign =
    "GET`n" +
    "`n" + # Content-Encoding
    "`n" + # Content-Language
    "`n" + # Content-Length
    "`n" + # Content-MD5
    "`n" + # Content-Type
    "`n" + # Date
    "`n" + # If-Modified-Since
    "`n" + # If-Match
    "`n" + # If-None-Match
    "`n" + # If-Unmodified-Since
    "`n" + # Range
    $canonicalizedHeaders +
    $CanonicalizedResource

  $keyBytes = [Convert]::FromBase64String($AccountKey)
  $hmac = [System.Security.Cryptography.HMACSHA256]::new($keyBytes)
  $sigBytes = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($stringToSign))
  $signature = [Convert]::ToBase64String($sigBytes)
  return "SharedKey $AccountName:$signature"
}

if ([string]::IsNullOrWhiteSpace($SasToken) -and [string]::IsNullOrWhiteSpace($AccountKey)) {
  throw "Provide either -SasToken (starts with '?sv=...') or -AccountKey (base64)."
}

$query = @{
  'restype' = 'container'
  'comp' = 'list'
  'maxresults' = $MaxResults
}
if (-not [string]::IsNullOrWhiteSpace($Prefix)) {
  $query['prefix'] = $Prefix
}

$qs = ($query.Keys | Sort-Object | ForEach-Object {
    "{0}={1}" -f $_, [Uri]::EscapeDataString([string]$query[$_])
  }) -join '&'

$baseUri = "https://$AccountName.blob.core.windows.net/$Container"
$uri = "$baseUri`?$qs"

$headers = @{
  'x-ms-version' = '2020-10-02'
  'x-ms-date' = [DateTime]::UtcNow.ToString('R')
}

if (-not [string]::IsNullOrWhiteSpace($SasToken)) {
  $sas = $SasToken.Trim()
  if ($sas.StartsWith('?')) { $sas = $sas.Substring(1) }
  $uri = "$uri&$sas"
} else {
  $canonicalizedResource = Get-CanonicalizedResource -AccountName $AccountName -Container $Container -Query $query
  $headers['Authorization'] = Get-SharedKeyAuthorizationHeader `
    -AccountName $AccountName `
    -AccountKey $AccountKey `
    -XmsDate $headers['x-ms-date'] `
    -XmsVersion $headers['x-ms-version'] `
    -CanonicalizedResource $canonicalizedResource
}

$resp = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers

# Invoke-RestMethod returns an XmlDocument for XML responses.
$items = @()
if ($null -ne $resp.EnumerationResults -and $null -ne $resp.EnumerationResults.Blobs) {
  foreach ($blob in @($resp.EnumerationResults.Blobs.Blob)) {
    if ($null -eq $blob.Name) { continue }

    if ($Detailed) {
      $props = $blob.Properties
      $items += [pscustomobject]@{
        Name         = [string]$blob.Name
        ContentLength = if ($null -ne $props -and $null -ne $props.'Content-Length') { [int64]$props.'Content-Length' } else { $null }
        ContentType  = if ($null -ne $props -and $null -ne $props.'Content-Type') { [string]$props.'Content-Type' } else { $null }
        LastModified = if ($null -ne $props -and $null -ne $props.'Last-Modified') { [datetime]$props.'Last-Modified' } else { $null }
      }
    } else {
      $items += [string]$blob.Name
    }
  }
}

$items
