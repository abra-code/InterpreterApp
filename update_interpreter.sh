#!/bin/bash
# update_interpreter.sh
# Build mlx-agent and assemble the git-excluded runtime pieces into Interpreter.app.
# Trimmed from MLXChat's update script: Interpreter needs ONLY the mlx-agent binary and its
# resource bundles (no replay, no MCP packages, no embedded Python).
#
# Steps: (1) build mlx-agent via xcodebuild (Metal shaders need the xcode build; there is no
# longer a Package.swift to `swift build` at all, and the products land in the repo's
# `build/` derived-data dir), (2) copy mlx-agent + mlx-swift_Cmlx.bundle (+ optional crypto/transformers
# bundles) to Contents/Support/MLX/, (3) ad-hoc codesign the copied binaries and the app,
# (4) verify the deployed agent launches and is the new build (its usage lists `map`).
#
# The .app bundle is auto-detected from this script's directory.

set -uo pipefail

GREEN=$(printf '\033[92m'); RED=$(printf '\033[91m'); YELLOW=$(printf '\033[93m'); RESET=$(printf '\033[0m')

CONFIG="Debug"
ARCH="auto"
SIGNING_IDENTITY="-"
DO_BUILD="yes"
DO_CODESIGN="yes"
# llama.cpp engine (gguf models): opt-in provisioning, PINNED by default to the release the
# mlx-agent map openai backend was verified against. Updating the pin means re-checking the
# /tokenize + /completion field names that backend relies on.
DO_LLAMA="no"
LLAMA_VERSION="b10056"

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "$0")" >/dev/null 2>&1 && pwd)"
AGENT_REPO="${MLX_AGENT_REPO:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --config=*) CONFIG="${1#*=}" ;;
        --release) CONFIG="Release" ;;
        --arch=*) ARCH="${1#*=}" ;;
        --agent-repo=*) AGENT_REPO="${1#*=}" ;;
        --skip-build) DO_BUILD="no" ;;
        --identity=*) SIGNING_IDENTITY="${1#*=}" ;;
        --no-codesign) DO_CODESIGN="no" ;;
        --with-llama) DO_LLAMA="yes" ;;
        --llama-version=*) DO_LLAMA="yes"; LLAMA_VERSION="${1#*=}" ;;
        --help)
            echo "Usage: $0 [--release] [--arch=arm64|x86_64] [--agent-repo=PATH] [--skip-build] [--identity=CERT] [--no-codesign] [--with-llama] [--llama-version=bNNNN]"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

fail() { echo "${RED}$*${RESET}" >&2; exit 1; }

[ "$ARCH" = "auto" ] && ARCH="$(/usr/bin/uname -m)"
case "$ARCH" in arm64|x86_64) ;; *) fail "Invalid --arch: $ARCH" ;; esac

# Auto-detect the single .app bundle beside this script.
APP_BUNDLE=""
for _c in "$SCRIPT_DIR"/*.app; do [ -d "$_c" ] && { APP_BUNDLE="$_c"; break; }; done
[ -n "$APP_BUNDLE" ] || fail "No .app bundle found in $SCRIPT_DIR"
MLX_DIR="$APP_BUNDLE/Contents/Support/MLX"
SUPPORT_DIR="$APP_BUNDLE/Contents/Support"
PDFTEXT_SRC="$SCRIPT_DIR/Tools/pdftext.swift"

# Locate the mlx-agent repo: env override, sibling dir, then ~/Development/mlx-agent.
# Identified by the Xcode PROJECT, not Package.swift: mlx-agent dropped its package manifest
# when it moved to an XcodeGen-generated project (the Metal shaders forced xcodebuild, and
# two manifests meant two dependency graphs that could drift). The .xcodeproj is committed.
if [ -z "$AGENT_REPO" ]; then
    for _cand in "$SCRIPT_DIR/../mlx-agent" "$HOME/Development/mlx-agent"; do
        [ -d "$_cand/mlx-agent.xcodeproj" ] && { AGENT_REPO="$(cd "$_cand" && pwd)"; break; }
    done
fi
[ -n "$AGENT_REPO" ] && [ -d "$AGENT_REPO/mlx-agent.xcodeproj" ] || fail "mlx-agent repo not found (looked for mlx-agent.xcodeproj); pass --agent-repo=PATH"
AGENT_BUILD_DIR="$AGENT_REPO/build/Build/Products/$CONFIG"

echo
echo "==== Updating $(basename "$APP_BUNDLE") ($CONFIG, $ARCH) ===="
echo "  mlx-agent : $AGENT_REPO"
echo "  deploy to : $MLX_DIR"
echo

# ── 1. Build mlx-agent ────────────────────────────────────────────────────
if [ "$DO_BUILD" = "yes" ]; then
    /usr/bin/xcrun --find metal >/dev/null 2>&1 || fail "Metal toolchain missing. Install once: xcodebuild -downloadComponent MetalToolchain"
    echo "  Building mlx-agent (compiles Metal shaders)..."
    ( cd "$AGENT_REPO" && /usr/bin/xcodebuild -project mlx-agent.xcodeproj -scheme mlx-agent \
        -destination "platform=macOS,arch=$ARCH" -derivedDataPath build \
        -configuration "$CONFIG" -skipPackagePluginValidation -skipMacroValidation build ) \
        2>&1 | /usr/bin/grep -iE "error:|BUILD (SUCCEEDED|FAILED)" | /usr/bin/tail -10
    [ "${PIPESTATUS[0]}" = 0 ] || fail "xcodebuild failed."
fi
[ -x "$AGENT_BUILD_DIR/mlx-agent" ] || fail "No built mlx-agent at $AGENT_BUILD_DIR (build first, or drop --skip-build)."
echo "  ${GREEN}Build OK${RESET}"

# ── 2. Deploy the binary + its resource bundles ───────────────────────────
/bin/mkdir -p "$MLX_DIR" || fail "Could not create $MLX_DIR"
/bin/cp -f "$AGENT_BUILD_DIR/mlx-agent" "$MLX_DIR/mlx-agent"
/bin/chmod +x "$MLX_DIR/mlx-agent"
required_bundle="mlx-swift_Cmlx.bundle"
[ -d "$AGENT_BUILD_DIR/$required_bundle" ] || fail "Required metallib bundle missing: $required_bundle"
for b in "$required_bundle" swift-crypto_Crypto.bundle swift-transformers_Hub.bundle; do
    if [ -d "$AGENT_BUILD_DIR/$b" ]; then
        /bin/rm -rf "$MLX_DIR/$b"
        /bin/cp -Rf "$AGENT_BUILD_DIR/$b" "$MLX_DIR/$b"
    fi
done
[ -f "$MLX_DIR/$required_bundle/Contents/Resources/default.metallib" ] || fail "default.metallib not found after copy."
echo "  ${GREEN}Deployed${RESET} mlx-agent + metallib"

# ── 2b. Build the pdftext helper ──────────────────────────────────────────
# Small single-file Swift tool (system frameworks only: PDFKit + Foundation) used by
# convert_to_plain_text for PDF inputs, which textutil cannot read. Compiled straight into
# Contents/Support/pdftext. No Metal, so a plain swiftc compile is enough (no xcodebuild).
if [ "$DO_BUILD" = "yes" ]; then
    [ -f "$PDFTEXT_SRC" ] || fail "pdftext source not found: $PDFTEXT_SRC"
    /usr/bin/xcrun swiftc -O -target "${ARCH}-apple-macos14.6" -o "$SUPPORT_DIR/pdftext" "$PDFTEXT_SRC" \
        || fail "swiftc failed to build pdftext"
    /bin/chmod +x "$SUPPORT_DIR/pdftext"
    echo "  ${GREEN}Built${RESET} pdftext"
fi
[ -x "$SUPPORT_DIR/pdftext" ] || fail "No pdftext at $SUPPORT_DIR/pdftext (build first, or drop --skip-build)."

# ── 2c. llama.cpp engine (gguf models, opt-in) ────────────────────────────
# Prebuilt upstream release tarball -> Contents/Support/Llama.cpp/ (llama-server + dylibs,
# @rpath-linked so they only need to sit together). Same provisioning as AIChat V2, but pinned:
# the map openai backend's wire mapping was verified against this build.
LLAMA_DIR="$APP_BUNDLE/Contents/Support/Llama.cpp"
if [ "$DO_LLAMA" = "yes" ]; then
    case "$LLAMA_VERSION" in b[0-9]*) ;; *) fail "Invalid --llama-version: $LLAMA_VERSION (expected bNNNN)" ;; esac
    case "$ARCH" in arm64) _lasset="llama-${LLAMA_VERSION}-bin-macos-arm64.tar.gz" ;;
                    *)     _lasset="llama-${LLAMA_VERSION}-bin-macos-x64.tar.gz" ;; esac
    _lwork="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/update-interp-llama.XXXXXX")" || fail "mktemp failed"
    echo "  Downloading llama.cpp $LLAMA_VERSION"
    /usr/bin/curl -L --fail --show-error --progress-bar -o "$_lwork/$_lasset" \
        "https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_VERSION}/${_lasset}" \
        || fail "llama.cpp download failed"
    /bin/mkdir -p "$_lwork/x" && /usr/bin/tar -xzf "$_lwork/$_lasset" -C "$_lwork/x" || fail "llama.cpp extract failed"
    _lbin=$(/usr/bin/find "$_lwork/x" -name llama-server -type f | /usr/bin/head -1)
    [ -n "$_lbin" ] || fail "llama-server not in the release archive"
    /bin/rm -rf "$LLAMA_DIR" && /bin/mkdir -p "$LLAMA_DIR"
    /bin/cp -f "$_lbin" "$LLAMA_DIR/llama-server" && /bin/chmod +x "$LLAMA_DIR/llama-server"
    /usr/bin/find "$(/usr/bin/dirname "$_lbin")" -name "*.dylib" -maxdepth 1 -exec /bin/cp -f {} "$LLAMA_DIR/" \;
    for _lic in "$_lwork/x/LICENSE" "$(/usr/bin/dirname "$_lbin")/../LICENSE"; do
        [ -f "$_lic" ] && { /bin/cp -f "$_lic" "$LLAMA_DIR/LICENSE"; break; }
    done
    /bin/rm -rf "$_lwork"
    echo "  ${GREEN}Deployed${RESET} llama.cpp $LLAMA_VERSION -> Contents/Support/Llama.cpp"
fi

# ── 3. Codesign ───────────────────────────────────────────────────────────
if [ "$DO_CODESIGN" = "yes" ]; then
    for target in \
        "$MLX_DIR/mlx-swift_Cmlx.bundle" "$MLX_DIR/swift-crypto_Crypto.bundle" \
        "$MLX_DIR/swift-transformers_Hub.bundle" "$MLX_DIR/mlx-agent" \
        "$LLAMA_DIR"/*.dylib "$LLAMA_DIR/llama-server" \
        "$SUPPORT_DIR/pdftext"; do
        [ -e "$target" ] || continue
        /usr/bin/codesign --force --timestamp=none --sign "$SIGNING_IDENTITY" "$target" >/dev/null 2>&1 \
            && echo "  signed $(basename "$target")" || echo "${RED}  FAILED $(basename "$target")${RESET}"
    done
    # Re-seal the whole app (deep) so the added Support pieces are covered.
    /usr/bin/codesign --force --deep --timestamp=none --sign "$SIGNING_IDENTITY" "$APP_BUNDLE" >/dev/null 2>&1 \
        && echo "  signed $(basename "$APP_BUNDLE")" || echo "${YELLOW}  app re-sign returned nonzero${RESET}"
fi

# ── 4. Verify ─────────────────────────────────────────────────────────────
if ( cd "$MLX_DIR" && ./mlx-agent 2>&1 ) | /usr/bin/grep -q -- "map "; then
    echo "  ${GREEN}Verify OK${RESET}: mlx-agent launches and lists the 'map' mode"
else
    fail "mlx-agent did not report 'map' mode - stale binary or a dylib load failure."
fi

# pdftext with no args prints usage and exits 2; that proves the binary loads (PDFKit linked).
"$SUPPORT_DIR/pdftext" >/dev/null 2>&1; pt_rc=$?
if [ "$pt_rc" = 2 ]; then
    echo "  ${GREEN}Verify OK${RESET}: pdftext launches"
else
    fail "pdftext did not launch (exit $pt_rc) - build/link failure."
fi

echo
echo "  ${GREEN}Done.${RESET} $(basename "$APP_BUNDLE") is ready."
echo
