param(
    [string]$Preset = "win-amd64-debug",
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ArgsRest
)
$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Exe = Join-Path $Root "out\build\$Preset\saw2.exe"
if (-not (Test-Path $Exe)) { & (Join-Path $PSScriptRoot "build.ps1") -Preset $Preset }
Push-Location $Root
try { & $Exe @ArgsRest } finally { Pop-Location }
