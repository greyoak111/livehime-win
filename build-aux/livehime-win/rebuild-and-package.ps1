# Rebuild LiveHime for Windows from nothing, then package both release assets.
#
# This is the whole flow the README describes, as one script, because doing it
# by hand is how the two prerequisite traps get missed: `core.autocrlf` turns
# the patch series into CRLF and every `git am` fails on the first hunk, and a
# clone without submodules leaves deps/libdshowcapture empty.
#
# Output:
#   build_x64/run/LiveHimeWinRundir-v<Version>-<Arch>.zip   the updater's asset
#   build_x64/run/LiveHime-Setup-v<Version>-<Arch>.exe     the human's installer
#
# Requires: git, CMake 3.28+, PowerShell 7.2+, Visual Studio 2022+ with the ATL
# component, and Inno Setup 6 for the installer half.

[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64')]
    [string] $Target = 'x64',

    [string] $Version = '0.2.10',

    [string] $Work = 'C:\build',

    # Skip the two clones when the tree is already there.
    [switch] $SkipClone
)

$ErrorActionPreference = 'Stop'

function Step($text) { Write-Host "`n=== $text ===" -ForegroundColor Cyan }
function Say($text)  { Write-Host "  $text" }

$fork   = Join-Path $Work 'obs-livehime'
$patches = Join-Path $Work 'livehime-win'
$run    = Join-Path $Work 'run'
New-Item -ItemType Directory -Force -Path $Work, $run | Out-Null

if ( ! $SkipClone ) {
    Step 'git must not rewrite line endings, or every patch fails'
    # A patch series is not text to be normalised: core.autocrlf=true turns it
    # into CRLF and git am then reports "git diff header lacks filename
    # information" on the very first hunk.
    & git config --global core.autocrlf false
    Say ("core.autocrlf = " + (& git config --global core.autocrlf))

    Step 'clone the patch repository'
    if ( Test-Path $patches ) { Remove-Item $patches -Recurse -Force }
    & git clone --depth 1 https://github.com/greyoak111/livehime-win.git $patches
    if ( $LASTEXITCODE -ne 0 ) { throw 'clone of livehime-win failed' }

    Step 'clone OBS Studio 32.2.2 at the commit the series is based on'
    if ( Test-Path $fork ) { Remove-Item $fork -Recurse -Force }
    & git clone --depth 1 --branch 32.2.2 https://github.com/obsproject/obs-studio.git $fork
    if ( $LASTEXITCODE -ne 0 ) { throw 'clone of obs-studio failed' }
    Push-Location $fork
    & git fetch --depth 1 origin ba2f32bdf791005443988a4955e963663e16b1ed
    & git checkout -q ba2f32bdf791005443988a4955e963663e16b1ed
    & git checkout -q -b livehime/main
    Pop-Location

    Step 'submodules (a plain clone leaves deps/libdshowcapture empty and CMake then fails)'
    Push-Location $fork
    & git submodule update --init --recursive --depth 1
    if ( $LASTEXITCODE -ne 0 ) { throw 'submodule update failed' }
    Pop-Location

}

Step 'apply the series'
# Deliberately OUTSIDE the -SkipClone guard. With this step inside it, a
# -SkipClone run left the tree at the base commit and the build then failed on a
# missing build-win.ps1 — the guard is about the clones, not about this. It is
# idempotent instead, so re-running over an already-patched tree is a no-op.
# PowerShell does not expand globs for native commands either: passing
# 'obs-fork/patches/*.patch' hands git the literal string and it answers
# "could not open ... *.patch". The files are enumerated here.
function PatchList($dir, $pattern) {
    $found = Get-ChildItem (Join-Path $dir $pattern) -ErrorAction SilentlyContinue |
             Sort-Object Name | ForEach-Object { $_.FullName }
    if ( ! $found ) { throw "no patches matched $pattern under $dir" }
    return , $found
}

Push-Location $fork
$applied = & git log --oneline | Select-String -Pattern 'LiveHime' -Quiet
if ( $applied ) {
    Say 'the series is already applied; skipping'
} else {
    $macPatches = PatchList $patches 'obs-fork/patches/*.patch'
    $winPatches = PatchList $patches 'obs-fork/patches-windows/*.patch'
    Say ("{0} macOS patches, {1} Windows patches" -f $macPatches.Count, $winPatches.Count)

    & git -c user.name=build -c user.email=build@local am @macPatches
    if ( $LASTEXITCODE -ne 0 ) { throw 'the macOS patch series did not apply' }
    & git -c user.name=build -c user.email=build@local am @winPatches
    if ( $LASTEXITCODE -ne 0 ) { throw 'the Windows patch series did not apply' }
}
Say ((& git rev-list --count HEAD) + ' commits')
Pop-Location

Step 'build'
Push-Location $fork
& (Join-Path $fork 'build-aux/livehime-win/build-win.ps1') -Target $Target `
    -SkipDependencies -Configuration RelWithDebInfo
if ( $LASTEXITCODE -ne 0 ) { throw 'the build failed' }
Pop-Location

$config = 'RelWithDebInfo'
$rundir = Join-Path $fork "build_$Target/rundir/$config"
if ( ! ( Test-Path (Join-Path $rundir 'bin/64bit/obs64.exe') ) ) {
    throw "no obs64.exe under $rundir"
}

Step 'stage without debug symbols'
$stage = Join-Path $Work 'stage'
if ( Test-Path $stage ) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
foreach ( $d in @('bin', 'obs-plugins', 'data') ) {
    $src = Join-Path $rundir $d
    if ( Test-Path $src ) { Copy-Item $src (Join-Path $stage $d) -Recurse -Force }
}
Get-ChildItem $stage -Recurse -File -Include '*.pdb', '*.ilk' | Remove-Item -Force
$files = Get-ChildItem $stage -Recurse -File
Say ("{0} files, {1} MB" -f $files.Count, [math]::Round(($files | Measure-Object Length -Sum).Sum / 1MB, 1))

Step 'the updater asset'
$zip = Join-Path $run "LiveHimeWinRundir-v$Version-$Target.zip"
Remove-Item $zip -Force -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal -Force
Say ("{0}  ({1} MB)" -f $zip, [math]::Round((Get-Item $zip).Length / 1MB, 1))
Say ("sha256 = " + (Get-FileHash $zip -Algorithm SHA256).Hash)
Say 'The release must carry this as a GitHub asset: the updater refuses an'
Say 'asset whose digest GitHub has not computed.'

Step 'the installer'
$iscc = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
    'C:\Program Files\Inno Setup 6\ISCC.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if ( ! $iscc ) {
    Write-Warning 'Inno Setup 6 not found; skipping the installer.'
    Write-Warning 'winget install --id JRSoftware.InnoSetup --exact'
} else {
    $iss = Join-Path $patches 'build-aux/livehime-win/package-installer.iss'
    & $iscc "/DAppVersion=$Version" "/DSourceDir=$stage" "/DOutputDir=$run" "/DAppArch=$Target" $iss
    if ( $LASTEXITCODE -ne 0 ) { throw 'ISCC failed' }
    Get-ChildItem $run -Filter '*.exe' | ForEach-Object {
        Say ("{0}  ({1} MB)" -f $_.Name, [math]::Round($_.Length / 1MB, 1))
    }
}

Step 'done'
Get-ChildItem $run | ForEach-Object { Say $_.Name }
