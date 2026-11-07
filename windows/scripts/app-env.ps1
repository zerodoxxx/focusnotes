# Dot-sourced by the Windows scripts and workflow steps. First KEY= line wins; an empty value counts as missing.
function Get-AppEnv([string] $EnvFile, [string] $Name) {
    $match = [regex]::Match((Get-Content -Raw -Path $EnvFile), "(?m)^$Name=([^\r\n]*)")
    if (-not $match.Success -or -not $match.Groups[1].Value) { throw "$Name is missing from Config/app.env" }
    return $match.Groups[1].Value
}
