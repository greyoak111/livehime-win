#!/usr/bin/env pwsh
#
# Configure and build the LiveHime Windows plugin inside OBS Studio.
#
# This is the Windows counterpart of build-aux/livehime/build-macos.sh. Like
# that script it drives upstream OBS's own build path rather than inventing a
# new one, and it only ever adds LiveHime options to the configure step.
#
#   Target          x64 (default) or arm64
#   Configuration   RelWithDebInfo (default), Release, MinSizeRel, Debug
#   Output          build_<Target>/install/LiveHime/…  (OBS's install tree)
#                   build_<Target>/rundir/<Configuration>/obs64.exe for a run
#
# Requirements, all installed by `.github/scripts/Build-Windows.ps1`'s helper
# (winget, driven by .github/scripts/.Wingetfile):
#   Visual Studio 2022+ with the "Desktop development with C++" workload,
#   CMake 3.28+, Git, PowerShell 7.2+, and the obs-deps packages the
#   windows-<target> preset downloads. Run this from a shell where winget works.
#
# ATL IS REQUIRED AND IS NOT IN .Wingetfile. GitHub's windows-2022 runner image
# ships it preinstalled, so upstream CI never has to ask; a bare Build Tools
# install does not. Without it three plugins fail with C1083 on atlbase.h:
#   plugins/frontend-tools   (captions-mssapi.cpp -> sphelper.h -> atlbase.h)
#   plugins/obs-qsv11
#   plugins/win-dshow/virtualcam-module
# Install it once, elevated, with:
#   & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\setup.exe" `
#       modify --installPath "<VS install path>" `
#       --add Microsoft.VisualStudio.Component.VC.ATL --quiet --norestart --wait
# The rest of the build is unaffected: everything else compiles without ATL.
#
# The WebView2 SDK is fetched by this script into
# plugins/livehime/core/win/web/sdk/ when it is missing. It is deliberately not
# in the patch series: WebView2.h is 69k lines and the two static loaders are
# 21 MB of binary between them.
#
# The source tree must have submodules. A plain `git clone --depth 1` leaves
# deps/libdshowcapture empty and CMake then fails on a missing
# dshowcapture.hpp, so run once before configuring:
#   git submodule update --init --recursive --depth 1
#
# Status: RUN ON WINDOWS. Verified on Windows 11 ARM64 (Parallels) against
# Visual Studio 2022 Build Tools 17.14 with the x64 preset under emulation:
# obs64.exe and livehime.dll both build, obs64.exe reports ProductName
# "LiveHime" / ProductVersion 0.2.10, creates %APPDATA%\LiveHime\obs-studio,
# and its log records "[livehime] control dock loaded". See
# docs/WINDOWS_PORT.md for what is real and what is still a stub.

[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64')]
    [string] $Target = 'x64',

    [ValidateSet('Debug', 'RelWithDebInfo', 'Release', 'MinSizeRel')]
    [string] $Configuration = 'RelWithDebInfo',

    # Skip the winget dependency step when the toolchain is already present.
    [switch] $SkipDependencies,

    # Use the windows-ci-<target> preset, which turns warnings into errors.
    # Off by default: a first build on a new port has warnings.
    [switch] $WarningsAsErrors
)

$ErrorActionPreference = 'Stop'

if ( $PSVersionTable.PSVersion -lt '7.2.0' ) {
    Write-Error 'This script requires PowerShell Core 7.2 or newer.'
    exit 1
}

if ( ! ( [System.Environment]::Is64BitOperatingSystem ) ) {
    Write-Error 'obs-studio requires a 64-bit system to build and run.'
    exit 1
}

$SourceDir = Resolve-Path -Path "$PSScriptRoot/../.."
$BuildDir  = Join-Path $SourceDir "build_$Target"

# Reuse upstream's helpers so dependency installation and command logging stay
# identical to a normal obs-studio build.
$UtilityFunctions = Get-ChildItem -Path "$SourceDir/.github/scripts/utils.pwsh/*.ps1" -Recurse
foreach ( $Utility in $UtilityFunctions ) {
    . $Utility.FullName
}

Push-Location $SourceDir
try {
    if ( ! $SkipDependencies ) {
        Log-Group "Installing build dependencies (winget)..."
        Install-BuildDependencies -WingetFile "$SourceDir/.github/scripts/.Wingetfile"
    }

    # The WebView2 SDK is not in the patch series: its header alone is 69k lines
    # and its static loaders are 21 MB of binary, which a patch cannot carry.
    # Fetch it once, from the same NuGet package the tree was developed against.
    # Skipped when it is already there, so a second build is offline.
    $WebView2Sdk = Join-Path $SourceDir 'plugins/livehime/core/win/web/sdk'
    if ( ! ( Test-Path ( Join-Path $WebView2Sdk 'WebView2.h' ) ) ) {
        Log-Group "Fetching the WebView2 SDK (nuget.org)..."
        $nuget = 'https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2'
        $zip = Join-Path $env:TEMP 'Microsoft.Web.WebView2.zip'
        $extract = Join-Path $env:TEMP 'Microsoft.Web.WebView2'
        Invoke-WebRequest -Uri $nuget -OutFile $zip -UseBasicParsing
        if ( Test-Path $extract ) { Remove-Item $extract -Recurse -Force }
        Expand-Archive -Path $zip -DestinationPath $extract -Force
        New-Item -ItemType Directory -Force -Path $WebView2Sdk | Out-Null
        Copy-Item (Join-Path $extract 'build/native/include/WebView2.h') $WebView2Sdk -Force
        Copy-Item (Join-Path $extract 'build/native/x64/WebView2LoaderStatic.lib') `
                  (Join-Path $WebView2Sdk 'WebView2LoaderStatic.x64.lib') -Force
        Copy-Item (Join-Path $extract 'build/native/arm64/WebView2LoaderStatic.lib') `
                  (Join-Path $WebView2Sdk 'WebView2LoaderStatic.arm64.lib') -Force
        Copy-Item (Join-Path $extract 'LICENSE.txt') $WebView2Sdk -Force
        Copy-Item (Join-Path $extract 'NOTICE.txt') $WebView2Sdk -Force
    }

    $preset = if ( $WarningsAsErrors ) { "windows-ci-$Target" } else { "windows-$Target" }

    # Mirrors build-macos.sh: upstream's defaults, plus only what LiveHime
    # needs to differ. ENABLE_BROWSER=OFF and the version override match the
    # macOS build so both report the same OBS version.
    #
    # The LIVEHIME_* / OBS_USER_CONFIG_SUBDIR values are the Windows
    # counterpart of the LIVEHIME_APP_* block build-macos.sh passes. Defaults
    # (see cmake/windows/defaults.cmake) keep plain OBS Studio behavior.
    # The executable stays obs64.exe; only the product identity changes.
    $cmakeArgs = @(
        '--preset', $preset
        '-DENABLE_BROWSER=OFF'
        '-DOBS_VERSION_OVERRIDE=32.2.2'
        '-DLIVEHIME_APP_NAME=LiveHime'
        '-DLIVEHIME_APP_DISPLAY_NAME=LiveHime'
        '-DLIVEHIME_APP_VERSION=0.2.10'
        '-DLIVEHIME_COMPANY_NAME=LiveHime'
        '-DLIVEHIME_APP_ICON=cmake/windows/livehime-win.ico'
        '-DOBS_USER_CONFIG_SUBDIR=LiveHime'
    )

    Log-Group "Configuring obs-studio (LiveHime Windows, $Target)..."
    Invoke-External cmake @cmakeArgs

    Log-Group "Building obs-studio (LiveHime Windows, $Configuration)..."
    Invoke-External cmake `
        --build --preset "windows-$Target" `
        --config $Configuration `
        --parallel `
        -- '/consoleLoggerParameters:Summary' '/noLogo'

    Log-Group "Installing obs-studio..."
    Invoke-External cmake `
        --install $BuildDir `
        --prefix (Join-Path $BuildDir 'install') `
        --config $Configuration

    Log-Group "Done."
    Write-Output "Run tree:  $BuildDir/rundir/$Configuration/obs64.exe"
    Write-Output "Plugin:    $BuildDir/rundir/$Configuration/obs-plugins/64bit/livehime.dll"
}
finally {
    Pop-Location
}
