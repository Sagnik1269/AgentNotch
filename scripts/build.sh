#!/usr/bin/env bash
# Builds AgentNotch and wraps it into build/AgentNotch.app.
# Calls swiftc/clang directly (no SwiftPM), so it works with just the Command Line Tools.
#
# Env overrides:
#   SDK=/path/to/MacOSX.sdk        SDK to compile against
#   SIGN_IDENTITY="Developer ID…"  codesigning identity ("-" for ad-hoc)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
ARCH="$(uname -m)"
MIN_OS="14.0"
# The bundle lives outside the project: iCloud-synced folders (like Desktop) keep adding
# Finder metadata that codesign rejects. build/AgentNotch.app is a symlink to it.
OUT_DIR="${OUT_DIR:-$HOME/Library/Developer/AgentNotch}"
APP="$OUT_DIR/AgentNotch.app"

# Pick an SDK built by the same Swift version as our compiler. Command Line Tools updates
# sometimes ship a newer default SDK than the compiler can read.
compiler_ver="$(swiftc --version 2>&1 | sed -nE 's/.*Apple Swift version ([0-9]+\.[0-9]+).*/\1/p' | head -1)"
SDK="${SDK:-}"
if [[ -z "$SDK" ]]; then
    default_sdk="$(xcrun --sdk macosx --show-sdk-path)"
    for candidate in "$default_sdk" $(ls -d "$(dirname "$default_sdk")"/MacOSX*.sdk 2>/dev/null | sort -rV); do
        iface="$candidate/usr/lib/swift/Swift.swiftmodule/arm64e-apple-macos.swiftinterface"
        [[ -f "$iface" ]] || continue
        if grep -m1 swift-compiler-version "$iface" | grep -q "Apple Swift version $compiler_ver"; then
            SDK="$candidate"; break
        fi
    done
    SDK="${SDK:-$default_sdk}"
fi

# Signing is ad-hoc by default and never touches the keychain.
# Opt in to a real identity with SIGN_IDENTITY="…" (list yours: security find-identity -v -p codesigning).
# A stable identity keeps privacy grants (Accessibility, System Audio Recording) across rebuilds;
# ad-hoc signatures change every build, so macOS may ask again after each one.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

echo "Swift $compiler_ver · SDK $(basename "$SDK") · signing: $SIGN_IDENTITY"

if [[ "$CONFIG" == "release" ]]; then OPT=(-O -whole-module-optimization); COPT=(-O2); else OPT=(-Onone -g); COPT=(-O0 -g); fi

SOURCES=()
while IFS= read -r -d '' f; do SOURCES+=("$f"); done < <(find Sources/AgentNotch -name '*.swift' -print0)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build
ln -sfn "$APP" build/AgentNotch.app

# App executable
swiftc "${OPT[@]}" \
    -swift-version 5 \
    -module-name AgentNotch \
    -target "$ARCH-apple-macos$MIN_OS" \
    -sdk "$SDK" \
    "${SOURCES[@]}" \
    -o "$APP/Contents/MacOS/AgentNotch"

# Now-playing bridge (loaded into /usr/bin/perl at runtime)
clang "${COPT[@]}" -fobjc-arc -dynamiclib -Wall \
    -isysroot "$SDK" -mmacosx-version-min="$MIN_OS" -arch "$ARCH" \
    -framework Foundation \
    Helpers/NowPlayingBridge/NowPlayingBridge.m \
    -o "$APP/Contents/Resources/NowPlayingBridge.dylib"
cp Helpers/NowPlayingBridge/nowplaying.pl "$APP/Contents/Resources/nowplaying.pl"

# Hook scripts for Claude Code and zsh (copied to Application Support at launch)
mkdir -p "$APP/Contents/Resources/Integrations"
cp Helpers/Integrations/* "$APP/Contents/Resources/Integrations/"

cp Resources/Info.plist "$APP/Contents/Info.plist"

xattr -cr "$APP"
# With pipefail, a codesign failure fails the build (the grep only filters noise).
sign() { codesign --force --timestamp=none --sign "$SIGN_IDENTITY" "$1" 2>&1 | { grep -v "replacing existing signature" || true; }; }
sign "$APP/Contents/Resources/NowPlayingBridge.dylib"
sign "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP ($CONFIG, signed: $SIGN_IDENTITY)"
