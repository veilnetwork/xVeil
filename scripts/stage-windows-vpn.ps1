param(
    [Parameter(Mandatory = $true)]
    [string]$Configuration,
    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$VeilManifest = Join-Path $ProjectRoot 'third_party\veil\Cargo.toml'
$CargoArguments = @(
    'build',
    '--manifest-path', $VeilManifest,
    '-p', 'veil-vpn-helper'
)
$RustProfile = 'debug'
if ($Configuration -ne 'Debug') {
    $CargoArguments += '--release'
    $RustProfile = 'release'
}

& cargo @CargoArguments
if ($LASTEXITCODE -ne 0) {
    throw "building veil-vpn-helper failed with exit code $LASTEXITCODE"
}

$MetadataText = & cargo metadata --manifest-path $VeilManifest --format-version 1
if ($LASTEXITCODE -ne 0) {
    throw "reading Cargo metadata failed with exit code $LASTEXITCODE"
}
$Metadata = $MetadataText | ConvertFrom-Json
$HelperSource = Join-Path $Metadata.target_directory "$RustProfile\veil_vpn_helper.dll"
if (-not (Test-Path -LiteralPath $HelperSource -PathType Leaf)) {
    throw "built VPN helper DLL is missing: $HelperSource"
}

$WintunPackage = $Metadata.packages |
    Where-Object { $_.name -eq 'wintun-bindings' } |
    Select-Object -First 1
if ($null -eq $WintunPackage) {
    throw 'Cargo metadata does not contain the locked wintun-bindings package'
}
$WintunRoot = Split-Path -Parent $WintunPackage.manifest_path
$TargetArchitecture = $env:VSCMD_ARG_TGT_ARCH
if ([string]::IsNullOrWhiteSpace($TargetArchitecture)) {
    $TargetArchitecture = $env:PROCESSOR_ARCHITECTURE
}
$WintunArchitecture = switch -Regex ($TargetArchitecture) {
    '^(x64|AMD64)$' { 'amd64'; break }
    '^(arm64|ARM64)$' { 'arm64'; break }
    '^(x86|X86)$' { 'x86'; break }
    default { throw "unsupported Windows target architecture: $TargetArchitecture" }
}
$WintunSource = Join-Path $WintunRoot "wintun\bin\$WintunArchitecture\wintun.dll"
$WintunLicense = Join-Path $WintunRoot 'wintun\LICENSE.txt'
if (-not (Test-Path -LiteralPath $WintunSource -PathType Leaf)) {
    throw "official Wintun DLL is missing from Cargo package: $WintunSource"
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
Copy-Item -LiteralPath $HelperSource -Destination (Join-Path $OutputDirectory 'veil_vpn_helper.dll') -Force
Copy-Item -LiteralPath $WintunSource -Destination (Join-Path $OutputDirectory 'wintun.dll') -Force
Copy-Item -LiteralPath $WintunLicense -Destination (Join-Path $OutputDirectory 'WINTUN-LICENSE.txt') -Force
