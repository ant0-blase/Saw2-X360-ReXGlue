param([string]$Preset = "win-amd64-debug")
$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Sdk = Join-Path $Root "thirdparty\rexglue-sdk"

if (-not (Test-Path (Join-Path $Root "generated\default\sources.cmake"))) {
    Write-Host "Generated code not found; running first-pass codegen..."
    & (Join-Path $PSScriptRoot "codegen.ps1") -Preset $Preset
}
cmake --preset $Preset -S $Root -DREXSDK_DIR="$Sdk"
cmake --build --preset $Preset --parallel
