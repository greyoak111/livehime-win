#!/bin/sh
#
# Does the published patch series actually rebuild the LiveHime Windows tree?
#
# This checks the one claim a patch repository cannot make by assertion: that
# obs-fork/patches/ (the macOS project's series) followed by
# obs-fork/patches-windows/ (this port) applies cleanly to upstream OBS 32.2.2
# and lands a complete LiveHime plugin. It is a read-only check: it clones into
# a scratch directory and never touches this repository or an existing OBS tree.
#
# Usage:
#   build-aux/livehime-win/verify-patches.sh [work-dir]
#
# Env:
#   OBS_MIRROR  a local clone of obs-studio that contains the base commit, used
#               instead of the network. Cloning from it is a --shared clone, so
#               it is fast and works offline. Example:
#                 OBS_MIRROR=~/src/obs-studio ./verify-patches.sh
#
# Exit status: 0 when the series applies cleanly and the rebuilt tree passes
# every check; 1 otherwise. With no work-dir argument the scratch directory is
# removed on success and kept (and printed) on failure.
#
set -eu

BASE=ba2f32bdf791005443988a4955e963663e16b1ed
UPSTREAM=https://github.com/obsproject/obs-studio.git
EXPECT_MAC=53
EXPECT_WIN=19
EXPECT_ENTRY_POINTS=35

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "$here/../.." && pwd)

if [ "$#" -ge 1 ]; then
	work=$1
	auto=no
else
	work=$(mktemp -d "${TMPDIR:-/tmp}/livehime-verify.XXXXXX")
	auto=yes
fi
tree=$work/obs-studio
fail=0

say() { printf '%s\n' "$*"; }
ok() { printf '  ok    %s\n' "$*"; }
bad() {
	printf '  FAIL  %s\n' "$*"
	fail=1
}
need() { if [ -e "$tree/$1" ]; then ok "$1"; else bad "$1 is missing"; fi; }

mkdir -p "$work"
say "repository: $repo"
say "scratch:    $work"
say ''

# --------------------------------------------------------------- the base tree
if [ -n "${OBS_MIRROR:-}" ]; then
	say "1. base tree, cloned from OBS_MIRROR"
	rm -rf "$tree"
	git clone -q -c advice.detachedHead=false --shared "$OBS_MIRROR" "$tree"
	git -C "$tree" -c advice.detachedHead=false checkout -q --detach "$BASE"
else
	say "1. base tree, fetched from $UPSTREAM"
	rm -rf "$tree"
	git init -q "$tree"
	git -C "$tree" remote add origin "$UPSTREAM"
	git -C "$tree" fetch -q --depth 1 origin "$BASE"
	git -C "$tree" -c advice.detachedHead=false checkout -q --detach FETCH_HEAD
fi
got=$(git -C "$tree" rev-parse HEAD)
if [ "$got" = "$BASE" ]; then
	ok "at the base commit $(printf '%.7s' "$BASE") (upstream OBS 32.2.2)"
else
	bad "base is $got, wanted $BASE"
fi
say ''

# ------------------------------------------------------------- the patch series
say "2. applying the series"
n_mac=$(ls "$repo"/obs-fork/patches/*.patch | wc -l | tr -d ' ')
n_win=$(ls "$repo"/obs-fork/patches-windows/*.patch | wc -l | tr -d ' ')
if [ "$n_mac" = "$EXPECT_MAC" ]; then
	ok "obs-fork/patches: $n_mac patches"
else
	bad "obs-fork/patches: $n_mac patches, expected $EXPECT_MAC"
fi
if [ "$n_win" = "$EXPECT_WIN" ]; then
	ok "obs-fork/patches-windows: $n_win patches"
else
	bad "obs-fork/patches-windows: $n_win patches, expected $EXPECT_WIN"
fi

am() { # am <patch-dir> <label>
	if git -C "$tree" -c user.name=verify -c user.email=verify@example.invalid \
		am "$1"/*.patch >"$work/am.log" 2>&1; then
		ok "$2: every patch applied cleanly"
	else
		bad "$2: a patch did not apply"
		sed 's/^/        /' "$work/am.log" | tail -20
		return 1
	fi
}
am "$repo/obs-fork/patches" "the macOS series" || true
am "$repo/obs-fork/patches-windows" "the Windows series" || true

total=$(git -C "$tree" rev-list --count "$BASE"..HEAD 2>/dev/null || echo 0)
want=$((EXPECT_MAC + EXPECT_WIN))
if [ "$total" = "$want" ]; then
	ok "$total commits rebuilt"
else
	bad "$total commits rebuilt, expected $want"
fi
say ''

# ---------------------------------------------------------- is it a LiveHime?
say "3. is the rebuilt tree a complete LiveHime?"
plug=$tree/plugins/livehime
need plugins/livehime/CMakeLists.txt
need plugins/livehime/core/include/livehime-core.h
need plugins/livehime/core/win/livehime-core.cpp
need plugins/livehime/src/window-native.cpp
need plugins/livehime/src/account-panel.cpp
need build-aux/livehime-win/build-win.ps1
need docs/WINDOWS_PORT.md
need docs/port-spec/CONTRACT.md
need docs/port-spec/http-api.md
need docs/port-spec/session-and-login.md
need docs/port-spec/danmaku-protocol.md

# The C ABI is the contract: every entry point the header declares has to have
# a real definition in the Windows core. A stub would fail this.
hdr=$plug/core/include/livehime-core.h
src=$plug/core/win/livehime-core.cpp
if [ -f "$hdr" ] && [ -f "$src" ]; then
	names=$(grep -oE '\blivehime_core_[a-z_]+' "$hdr" | sort -u)
	n=$(printf '%s\n' "$names" | wc -l | tr -d ' ')
	if [ "$n" = "$EXPECT_ENTRY_POINTS" ]; then
		ok "the C ABI declares $n entry points"
	else
		bad "the C ABI declares $n entry points, expected $EXPECT_ENTRY_POINTS"
	fi
	defined=$(grep -cE '^[A-Za-z_].*livehime_core_[a-z_]+[[:space:]]*\(' "$src" || true)
	if [ "$defined" = "$EXPECT_ENTRY_POINTS" ]; then
		ok "the Windows core defines all $defined of them"
	else
		bad "the Windows core defines $defined of them, expected $EXPECT_ENTRY_POINTS"
	fi
	missing=
	for name in $names; do
		grep -qE "^[A-Za-z_].*\b$name[[:space:]]*\(" "$src" || missing="$missing $name"
	done
	if [ -z "$missing" ]; then
		ok "no entry point is left unimplemented"
	else
		bad "unimplemented:$missing"
	fi
fi

# The Windows branch has to compile the C++ core, not the historical stub.
if grep -q 'core/win/livehime-core\.cpp' "$plug/CMakeLists.txt" 2>/dev/null; then
	ok "CMakeLists.txt builds core/win/livehime-core.cpp for Windows"
else
	bad "CMakeLists.txt does not reference the Windows core"
fi

# The WebView2 SDK is deliberately not in the series: the build script fetches
# it. Absent here is correct; present would mean 21 MB leaked into the patches.
if [ -e "$plug/core/win/web/sdk" ]; then
	bad "core/win/web/sdk is in the tree — it is meant to be fetched, not patched"
else
	ok "core/win/web/sdk is absent, as intended"
fi
if grep -q 'Microsoft\.Web\.WebView2' "$tree/build-aux/livehime-win/build-win.ps1" 2>/dev/null; then
	ok "build-win.ps1 fetches the WebView2 SDK from NuGet"
else
	bad "build-win.ps1 does not fetch the WebView2 SDK"
fi
say ''

# ------------------------------------------------------------------- the verdict
if [ "$fail" -eq 0 ]; then
	say "PASS — the published series rebuilds the source tree."
	[ "$auto" = yes ] && rm -rf "$work"
	exit 0
fi
say "FAIL — see above. The scratch tree is at $tree."
exit 1
