$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Sdk = Join-Path $Root "thirdparty\rexglue-sdk"
$Tag = "v0.9.0"

foreach ($cmd in @("git", "cmake", "ninja", "clang", "clang++")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        throw "Missing dependency: $cmd"
    }
}

if (-not (Test-Path (Join-Path $Sdk ".git"))) {
    git clone --branch $Tag --depth 1 --recurse-submodules --shallow-submodules `
        https://github.com/rexglue/rexglue-sdk.git $Sdk
} else {
    git -C $Sdk fetch --tags --force
    git -C $Sdk checkout $Tag
    git -C $Sdk submodule update --init --recursive
}

Write-Host "ReXGlue SDK ready: $Sdk"
