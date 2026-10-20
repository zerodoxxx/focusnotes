<#
.SYNOPSIS
Lists every PE file we ship and classifies its signature.

.DESCRIPTION
Enumerates .exe/.dll in the installed layout and in every shipped installer artifact
(Setup.exe and the PE files inside each full/delta .nupkg), then records path, SHA-256,
Authenticode status and signer. Classes:
  1 ours        - our own binary (app, helper, Update.exe, Setup.exe); must be signed by our certificate
  2 vendor      - validly signed by someone else with a Trusted Root chain
  3 upstream    - unsigned, but an unmodified upstream binary on upstream-allowlist.json (by hash)
  unclassified  - anything else
-Enforce fails on any unclassified file, any class-1 file that is not validly signed by one of our
certificates, and an empty signer list. Our certificates are listed by thumbprint in the environment
variable WINDOWS_SIGNER_THUMBPRINTS (comma-separated). Without -Enforce the script only reports.

.PARAMETER Layout
The Velopack install root, <LocalAppData>\<packId> (covers Update.exe and current\).

.PARAMETER Packages
Directory holding Setup.exe, the .nupkg files and any Portable .zip.

.PARAMETER Out
JSON report path (signing-inventory-<arch>.json).
#>
param(
    [Parameter(Mandatory)][string] $Layout,
    [Parameter(Mandatory)][string] $Packages,
    [Parameter(Mandatory)][string] $Out,
    [switch] $Enforce
)

$ErrorActionPreference = 'Stop'
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$envFile = Join-Path (Split-Path -Parent (Split-Path -Parent $scriptDirectory)) 'Config/app.env'
$appName = [regex]::Match((Get-Content -Raw -Path $envFile), '(?m)^APPNAME=([^\r\n]+)').Groups[1].Value
if (-not $appName) { throw 'APPNAME is missing from Config/app.env' }

$allowlist = @{}
foreach ($entry in (Get-Content -Raw -Path (Join-Path $scriptDirectory 'upstream-allowlist.json') | ConvertFrom-Json).entries) {
    $allowlist[$entry.sha256.ToLowerInvariant()] = $entry
}

$ourThumbprints = @(($env:WINDOWS_SIGNER_THUMBPRINTS -split ',') | ForEach-Object { $_.Trim().ToUpperInvariant() } | Where-Object { $_ })
if ($Enforce -and $ourThumbprints.Count -eq 0) { throw 'WINDOWS_SIGNER_THUMBPRINTS is empty; -Enforce needs our signing certificate thumbprints.' }

function Test-Ours([string] $FileName) {
    return $FileName -like "$appName*" -or $FileName -like 'CaptureApp.*' -or $FileName -in @('Update.exe', 'Setup.exe') -or $FileName -like '*-Setup.exe'
}

function Get-Record([string] $DisplayPath, [string] $FilePath) {
    $signature = Get-AuthenticodeSignature -LiteralPath $FilePath
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $FilePath).Hash.ToLowerInvariant()
    $valid = $signature.Status -eq 'Valid'
    $class = if (Test-Ours (Split-Path -Leaf $FilePath)) { '1' }
    elseif ($valid) { '2' }
    elseif ($allowlist.ContainsKey($hash)) { '3' }
    else { 'unclassified' }
    $ours = $valid -and $signature.SignerCertificate -and ($ourThumbprints -contains $signature.SignerCertificate.Thumbprint.ToUpperInvariant())
    [pscustomobject]@{
        path   = $DisplayPath
        oursSigned = [bool] $ours
        sha256 = $hash
        status = [string] $signature.Status
        signer = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { $null }
        class  = $class
    }
}

function Get-PeFiles([string] $Root) {
    Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object { $_.Extension -in '.exe', '.dll' }
}

$records = @()
$layoutRoot = (Resolve-Path -LiteralPath $Layout).Path
foreach ($file in Get-PeFiles $layoutRoot) {
    $records += Get-Record ("layout:" + $file.FullName.Substring($layoutRoot.Length).TrimStart('\', '/')) $file.FullName
}

$packageRoot = (Resolve-Path -LiteralPath $Packages).Path
foreach ($setup in Get-ChildItem -LiteralPath $packageRoot -File -Filter '*Setup.exe') {
    $records += Get-Record "package:$($setup.Name)" $setup.FullName
}

$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("signing-inventory-" + [guid]::NewGuid().ToString('N'))
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archives = @(Get-ChildItem -LiteralPath $packageRoot -File | Where-Object { $_.Extension -in '.nupkg', '.zip' })
    foreach ($nupkg in $archives) {
        $target = Join-Path $scratch $nupkg.Name
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        [System.IO.Compression.ZipFile]::ExtractToDirectory($nupkg.FullName, $target)
        foreach ($file in Get-PeFiles $target) {
            $records += Get-Record "package:$($nupkg.Name)!/$($file.FullName.Substring($target.Length).TrimStart('\', '/'))" $file.FullName
        }
    }
}
finally {
    if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}

$unclassified = @($records | Where-Object { $_.class -eq 'unclassified' })
$unsignedOurs = @($records | Where-Object { $_.class -eq '1' -and -not $_.oursSigned })
$summary = [ordered]@{
    total        = $records.Count
    ours         = @($records | Where-Object { $_.class -eq '1' }).Count
    vendor       = @($records | Where-Object { $_.class -eq '2' }).Count
    upstream     = @($records | Where-Object { $_.class -eq '3' }).Count
    unclassified = $unclassified.Count
    unsignedOurs = $unsignedOurs.Count
}
[ordered]@{ generatedUtc = (Get-Date).ToUniversalTime().ToString('o'); enforce = [bool] $Enforce; summary = $summary; files = $records } |
    ConvertTo-Json -Depth 5 | Set-Content -Path $Out -Encoding utf8
Write-Host "Signing inventory: $($summary | ConvertTo-Json -Compress) -> $Out"

if ($unclassified.Count -gt 0 -or $unsignedOurs.Count -gt 0) {
    foreach ($record in $unclassified) { Write-Host "  unclassified: $($record.path) ($($record.status))" }
    foreach ($record in $unsignedOurs) { Write-Host "  not signed by our certificate: $($record.path) ($($record.status))" }
    if ($Enforce) { throw 'Signing inventory failed: unclassified or unsigned files shipped.' }
}
