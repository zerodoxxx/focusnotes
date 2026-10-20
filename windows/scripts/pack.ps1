<#
.SYNOPSIS
Builds one architecture's Velopack release: self-contained publish and vpk pack.

.PARAMETER Arch
x64 or arm64. Build on a matching runner (windows-latest / windows-11-arm).

.PARAMETER Version
SemVer2 package version (for CI: <VERSION>-ci.1).

.PARAMETER OutDir
Output root; this arch lands in <OutDir>/win-<arch>. Defaults to windows/dist.

.PARAMETER CiUpdateTests
Compiles the CI-only update overrides (CI_UPDATE_TESTS). Never use for release packs.
#>
param(
    [Parameter(Mandatory)][ValidateSet('x64', 'arm64')][string] $Arch,
    [Parameter(Mandatory)][string] $Version,
    [string] $OutDir,
    [switch] $CiUpdateTests
)

$ErrorActionPreference = 'Stop'
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$windowsDirectory = Split-Path -Parent $scriptDirectory
$envFile = Join-Path (Split-Path -Parent $windowsDirectory) 'Config/app.env'
if (-not $OutDir) { $OutDir = Join-Path $windowsDirectory 'dist' }
$OutDir = [System.IO.Path]::GetFullPath($OutDir)

function Get-EnvValue([string] $Name) {
    $match = [regex]::Match((Get-Content -Raw -Path $envFile), "(?m)^$Name=([^\r\n]*)")
    if (-not $match.Success -or -not $match.Groups[1].Value) { throw "$Name is missing from Config/app.env" }
    return $match.Groups[1].Value
}

function Invoke-Checked([string] $Description, [scriptblock] $Command) {
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "$Description failed with exit code $LASTEXITCODE" }
}

$appName = Get-EnvValue 'APPNAME'
$rid = "win-$Arch"
$packId = "$appName-$rid"
$archOut = Join-Path $OutDir $rid
$publishDir = Join-Path $OutDir "publish-$rid"

foreach ($path in @($archOut, $publishDir)) {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $path | Out-Null
}

Push-Location $windowsDirectory
try {
    Invoke-Checked 'dotnet tool restore' { dotnet tool restore }

    $publishArgs = @('publish', 'src/CaptureApp.App/CaptureApp.App.csproj', '-c', 'Release', '-r', $rid, '--self-contained', 'true', '-o', $publishDir, "-p:Version=$Version")
    if ($CiUpdateTests) { $publishArgs += '-p:CIUpdateTests=true' }
    Invoke-Checked 'dotnet publish' { dotnet @publishArgs }

    $packArgs = @('vpk', 'pack', '--packId', $packId, '--packVersion', $Version, '--packDir', $publishDir,
        '--runtime', $rid, '--channel', $rid, '--mainExe', "$appName.exe", '--outputDir', $archOut)
    if ($env:WINDOWS_SIGN_TEMPLATE) { $packArgs += @('--signTemplate', $env:WINDOWS_SIGN_TEMPLATE) }
    Invoke-Checked 'vpk pack' { dotnet @packArgs }
}
finally {
    Pop-Location
}

# Velopack names the installer <packId>-<channel>-Setup.exe; publish it as <packId>-Setup.exe.
$setup = Get-ChildItem -LiteralPath $archOut -Filter '*Setup.exe' | Select-Object -First 1
if (-not $setup) { throw "vpk produced no Setup.exe in $archOut" }
$setupName = "$packId-Setup.exe"
if ($setup.Name -ne $setupName) { Rename-Item -LiteralPath $setup.FullName -NewName $setupName }

# Every asset name must carry its own architecture, and no name may repeat across architectures.
$assets = @(Get-ChildItem -LiteralPath $archOut -File | Select-Object -ExpandProperty Name)
$stray = @($assets | Where-Object { $_ -notmatch [regex]::Escape($rid) })
if ($stray.Count -gt 0) { throw "Assets without $rid in their name: $($stray -join ', ')" }

$otherNames = @{}
foreach ($other in Get-ChildItem -LiteralPath $OutDir -Directory | Where-Object { $_.Name -ne $rid -and $_.Name -like 'win-*' }) {
    foreach ($file in Get-ChildItem -LiteralPath $other.FullName -File) { $otherNames[$file.Name] = $other.Name }
}
$duplicates = @($assets | Where-Object { $otherNames.ContainsKey($_) })
if ($duplicates.Count -gt 0) { throw "Duplicate asset names across architectures: $($duplicates -join ', ')" }

Write-Host "Packed $packId $Version -> $archOut"
$assets | ForEach-Object { Write-Host "  $_" }
