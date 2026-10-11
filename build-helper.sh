#!/bin/bash
#
# build-helper.sh — build the LocalNook root fan helper from this source tree.
#
# Copyright (C) 2026 Krish Kowli
# Licensed under the GNU General Public License v3.0 or later. See LICENSE.
#
# This is the build the LocalNook app's release script does for the helper,
# without the rest of the app: compile the one product, strip the debug map,
# sign it as com.localnook.app.fan-helper with the hardened runtime and no
# entitlements, and check the result. Requires macOS 15 or later and a Swift
# 6.2 toolchain (Xcode Command Line Tools are enough). No network access, no
# package dependencies, and no use of sudo: nothing here installs anything.
#
#   ./build-helper.sh                    # release build, ad-hoc signed, into ./build
#   ./build-helper.sh --self-test        # ...then run the helper's own checks
#   ./build-helper.sh --debug            # debug configuration
#   ./build-helper.sh --sign "<identity>"
#       sign with a code-signing identity from your keychain instead of ad hoc
#       (or set LOCALNOOK_SIGN_IDENTITY). The helper serves only an app signed
#       by the very same certificate; an ad-hoc helper builds and passes its
#       self-test but never listens (see README.md).
#   ./build-helper.sh --out DIR          # where the result goes (default ./build)
#   ./build-helper.sh --jobs N           # passed to swift build
#   ./build-helper.sh --arch ARCH        # default arm64, as the shipped helper
#   ./build-helper.sh --timestamp        # ask codesign for a secure timestamp
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# The launchd label, Mach service name and signing identifier: one name
# (Sources/LocalNookSMC/FanControlProtocol.swift, FanHelperIdentity).
HELPER_LABEL="com.localnook.app.fan-helper"
PRODUCT="LocalNookFanHelper"

CONFIG="release"
ARCH="arm64"
OUT="$ROOT/build"
JOBS=""
SIGN_IDENTITY="${LOCALNOOK_SIGN_IDENTITY:--}"
RUN_SELF_TEST=0
TIMESTAMP=0

usage() { sed -n '3,26p' "$ROOT/build-helper.sh" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --debug)      CONFIG="debug" ;;
    --self-test)  RUN_SELF_TEST=1 ;;
    --timestamp)  TIMESTAMP=1 ;;
    --sign)       [ $# -ge 2 ] || { echo "--sign needs an identity" >&2; exit 2; }; SIGN_IDENTITY="$2"; shift ;;
    --out)        [ $# -ge 2 ] || { echo "--out needs a directory" >&2; exit 2; }; OUT="$2"; shift ;;
    --jobs)       [ $# -ge 2 ] || { echo "--jobs needs a number" >&2; exit 2; }; JOBS="$2"; shift ;;
    --arch)       [ $# -ge 2 ] || { echo "--arch needs a name" >&2; exit 2; }; ARCH="$2"; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

case "$JOBS" in
  "") ;;
  *[!0-9]*) echo "--jobs needs a number" >&2; exit 2 ;;
esac

step() { printf '\n==> %s\n' "$*"; }

BUILD_ARGS=(-c "$CONFIG" --arch "$ARCH")
[ -z "$JOBS" ] || BUILD_ARGS+=(--jobs "$JOBS")

# ── 1. Compile ───────────────────────────────────────────────────────────────
step "Building $PRODUCT ($CONFIG, $ARCH)…"
swift build "${BUILD_ARGS[@]}" --product "$PRODUCT"
BIN_PATH="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
BUILT="$BIN_PATH/$PRODUCT"
[ -x "$BUILT" ] || { echo "build produced no helper at $BUILT" >&2; exit 1; }

# ── 2. Assemble ──────────────────────────────────────────────────────────────
mkdir -p "$OUT"
HELPER="$OUT/$HELPER_LABEL"
HELPER_PLIST="$OUT/$HELPER_LABEL.plist"
rm -f "$HELPER" "$HELPER_PLIST"
cp "$BUILT" "$HELPER"
cmp "$BUILT" "$HELPER"
cp "$ROOT/Resources/$HELPER_LABEL.plist" "$HELPER_PLIST"
plutil -lint "$HELPER_PLIST" >/dev/null \
  || { echo "the launchd job ($HELPER_LABEL.plist) is malformed" >&2; exit 1; }

# The linker leaves a debug map in a release executable: one absolute path per
# object file, all under the builder's home directory. `-S` removes only the
# debugging symbols; the symbol table stays, so a crash report names functions.
if [ "$CONFIG" = "release" ]; then
  strip -S "$HELPER"
fi

# ── 3. Sign ──────────────────────────────────────────────────────────────────
# Hardened runtime, the helper's own identifier and *no* entitlements: a root
# daemon is granted nothing. Signing replaces the linker's ad-hoc signature.
if [ "$SIGN_IDENTITY" = "-" ]; then SIGN_LABEL="ad hoc"; else SIGN_LABEL="$SIGN_IDENTITY"; fi
step "Signing as $HELPER_LABEL ($SIGN_LABEL)…"
SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --options runtime --identifier "$HELPER_LABEL")
[ "$TIMESTAMP" -eq 0 ] || SIGN_ARGS+=(--timestamp)
codesign "${SIGN_ARGS[@]}" "$HELPER"

# ── 4. Check ─────────────────────────────────────────────────────────────────
step "Checking the result…"
codesign --verify --strict "$HELPER" \
  || { echo "the helper's signature does not verify" >&2; exit 1; }
HELPER_ID="$(codesign -d -v "$HELPER" 2>&1 | sed -n 's/^Identifier=//p' | head -1)"
[ "$HELPER_ID" = "$HELPER_LABEL" ] \
  || { echo "the helper is signed as \"$HELPER_ID\", not $HELPER_LABEL" >&2; exit 1; }
if codesign -d --entitlements - "$HELPER" 2>/dev/null | grep -q -e '\[Key\]' -e '<key>'; then
  echo "the helper carries entitlements; a root daemon must carry none" >&2
  exit 1
fi
echo "    $HELPER_LABEL: signature verified, no entitlements"
# The launchd job must be the one the helper accepts, key for key (the app's
# installer asks the same, as root, before it loads a job).
"$HELPER" --verify-plist "$HELPER_PLIST" \
  || { echo "the helper refuses its own launchd job" >&2; exit 1; }
echo "    launchd job matches what the helper accepts"

if [ "$RUN_SELF_TEST" -eq 1 ]; then
  # Needs no privilege and touches no fan, no pmset and no file outside a
  # temporary directory: the controllers run against doubles.
  step "Running the helper's self-test…"
  set +e
  "$HELPER" --self-test | grep -E '✗|^helper self-test'
  RC=${PIPESTATUS[0]}
  set -e
  [ "$RC" -eq 0 ] || { echo "HELPER SELF-TEST FAILED" >&2; exit 1; }
fi

step "Done"
echo "    helper:  $HELPER"
echo "    job:     $HELPER_PLIST"
echo "    sha256:  $(shasum -a 256 "$HELPER" | cut -d ' ' -f1)"
echo "    Nothing was installed. README.md says how to install and remove it."
