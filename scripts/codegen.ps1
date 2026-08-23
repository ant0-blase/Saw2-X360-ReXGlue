param(
    [string]$Preset = "win-amd64-debug",
    [switch]$Force
)
$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Sdk = Join-Path $Root "thirdparty\rexglue-sdk"

if (-not (Test-Path $Sdk)) { & (Join-Path $PSScriptRoot "bootstrap-sdk.ps1") }
cmake --preset $Preset -S $Root -DREXSDK_DIR="$Sdk"
if ($Force) {
    cmake --build --preset $Preset --target saw2_codegen_force --parallel
} else {
    cmake --build --preset $Preset --target saw2_codegen --parallel
}
cmake --preset $Preset -S $Root -DREXSDK_DIR="$Sdk"
