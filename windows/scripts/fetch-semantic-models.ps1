param([string] $Destination)

$ErrorActionPreference = 'Stop'

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$windowsDirectory = Split-Path -Parent $scriptDirectory
$manifestPath = Join-Path $windowsDirectory 'src/CaptureApp.ModelInstall/ModelManifest.cs'
if (-not $Destination) { $Destination = Join-Path $windowsDirectory '.semantic-models' }
New-Item -ItemType Directory -Force -Path $Destination | Out-Null
$Destination = (Resolve-Path -LiteralPath $Destination).Path

function Get-Sha256([string] $Path) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

$source = Get-Content -Raw -Path $manifestPath
$repo = [regex]::Match($source, 'const string Repo = "([^"]+)"').Groups[1].Value
$revision = [regex]::Match($source, 'const string Revision = "([^"]+)"').Groups[1].Value
$baseUrl = "https://huggingface.co/$repo/resolve/$revision"

foreach ($match in [regex]::Matches($source, 'Artifact\("([^"]+)", "([0-9a-f]{64})", (\d+)\)')) {
    $path = $match.Groups[1].Value
    $expectedSha = $match.Groups[2].Value
    $expectedBytes = [long]$match.Groups[3].Value
    $target = Join-Path $Destination $path

    if (Test-Path -LiteralPath $target -PathType Leaf) {
        if ((Get-Sha256 $target) -eq $expectedSha -and (Get-Item -LiteralPath $target).Length -eq $expectedBytes) { continue }
        Remove-Item -LiteralPath $target -Force
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    $temporaryPath = "$target.partial"
    Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    Write-Host "Downloading $path"
    Invoke-WebRequest -Uri "$baseUrl/$path" -OutFile $temporaryPath -MaximumRedirection 10
    $actualSha = Get-Sha256 $temporaryPath
    $actualBytes = (Get-Item -LiteralPath $temporaryPath).Length
    if ($actualSha -ne $expectedSha -or $actualBytes -ne $expectedBytes) {
        Remove-Item -LiteralPath $temporaryPath -Force
        throw "SHA-256 or size mismatch for ${path}: $actualSha ($actualBytes bytes)"
    }
    Move-Item -LiteralPath $temporaryPath -Destination $target -Force
}

Write-Host "All semantic model files are present and verified in $Destination"
