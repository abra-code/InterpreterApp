#!/bin/bash
# update_interpreter.sh
# Build mlx-agent and assemble the git-excluded runtime pieces into Interpreter.app.
# Trimmed from MLXChat's update script: Interpreter needs ONLY the mlx-agent binary and its
# resource bundles (no replay, no MCP packages, no embedded Python).
#
# Steps: (1) build mlx-agent via xcodebuild (Metal shaders need the xcode build; there is no
# longer a Package.swift to `swift build` at all, and the products land in the repo's
# `build/` derived-data dir), (2) copy mlx-agent + mlx-swift_Cmlx.bundle (+ optional crypto/transformers
# bundles) to Contents/Support/MLX/, build + embed pdfutil from its sibling repo, (3) ad-hoc
# codesign the copied binaries and the app, (4) verify the deployed agent launches and is the
# new build (its usage lists `map`) and pdfutil reports its version.
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

# Locate the pdfutil repo (PDF text extraction helper): env override, then sibling dir.
# Built by its own build.sh (plain swiftc, system frameworks only).
if [ -z "$PDFUTIL_REPO" ]; then
    for _cand in "$SCRIPT_DIR/../pdfutil"; do
        [ -f "$_cand/build.sh" ] && [ -d "$_cand/Sources" ] && { PDFUTIL_REPO="$(cd "$_cand" && pwd)"; break; }
    done
fi

# Locate the mlx-agent repo (github.com/abra-code/mlx-agent, Apache 2.0): env override,
# then sibling dir.
# Identified by the Xcode PROJECT, not Package.swift: mlx-agent dropped its package manifest
# when it moved to an XcodeGen-generated project (the Metal shaders forced xcodebuild, and
# two manifests meant two dependency graphs that could drift). The .xcodeproj is committed.
if [ -z "$AGENT_REPO" ]; then
    for _cand in "$SCRIPT_DIR/../mlx-agent"; do
        [ -d "$_cand/mlx-agent.xcodeproj" ] && { AGENT_REPO="$(cd "$_cand" && pwd)"; break; }
    done
fi
[ -n "$AGENT_REPO" ] && [ -d "$AGENT_REPO/mlx-agent.xcodeproj" ] || fail "mlx-agent repo not found (looked for mlx-agent.xcodeproj); clone github.com/abra-code/mlx-agent beside this repo or pass --agent-repo=PATH"
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
[ -f "$AGENT_REPO/LICENSE" ] && /bin/cp -f "$AGENT_REPO/LICENSE" "$MLX_DIR/mlx-agent.LICENSE"
echo "  ${GREEN}Deployed${RESET} mlx-agent + metallib"

# ── 2b. Build + embed the pdfutil helper ──────────────────────────────────
# pdfutil (github.com/abra-code/pdfutil, Apache 2.0) replaces the old in-repo pdftext.swift:
# its `text` verb does the PDF text extraction convert_to_plain_text needs (textutil cannot
# read PDF). Built by the repo's own build.sh (plain swiftc, system frameworks only) for this
# script's target arch, then copied to Contents/Support/pdfutil with its LICENSE beside it.
if [ "$DO_BUILD" = "yes" ]; then
    [ -n "$PDFUTIL_REPO" ] || fail "pdfutil repo not found (looked for build.sh + Sources); clone github.com/abra-code/pdfutil beside this repo or set PDFUTIL_REPO"
    ( cd "$PDFUTIL_REPO" && ./build.sh "$ARCH" ) || fail "pdfutil build.sh failed"
    /bin/cp -f "$PDFUTIL_REPO/build/pdfutil" "$SUPPORT_DIR/pdfutil" || fail "Could not copy pdfutil"
    /bin/chmod +x "$SUPPORT_DIR/pdfutil"
    [ -f "$PDFUTIL_REPO/LICENSE" ] && /bin/cp -f "$PDFUTIL_REPO/LICENSE" "$SUPPORT_DIR/pdfutil.LICENSE"
    /bin/rm -f "$SUPPORT_DIR/pdftext"   # retire the old helper on upgrade
    echo "  ${GREEN}Built${RESET} pdfutil ($ARCH)"
fi
[ -x "$SUPPORT_DIR/pdfutil" ] || fail "No pdfutil at $SUPPORT_DIR/pdfutil (build first, or drop --skip-build)."

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

# ── 2d. Sweep build/runtime droppings out of Support ──────────────────────
# LLVM coverage-instrumented binaries dump default.profraw into their CWD at exit - and the
# verify step below runs mlx-agent with CWD inside the bundle, which once shipped a stale
# profraw. Sweep profiling artifacts (and Finder droppings) before signing, and warn if a
# deployed binary is itself instrumented: instrumentation has no place in a shipping build.
/usr/bin/find "$SUPPORT_DIR" \( -name "*.profraw" -o -name "*.profdata" -o -name ".DS_Store" \) -delete
for _bin in "$MLX_DIR/mlx-agent" "$LLAMA_DIR/llama-server" "$SUPPORT_DIR/pdfutil"; do
    [ -f "$_bin" ] || continue
    if /usr/bin/otool -l "$_bin" 2>/dev/null | /usr/bin/grep -q "__llvm_prf"; then
        echo "${YELLOW}  WARNING: $(basename "$_bin") is coverage-instrumented (__llvm_prf) - rebuild without profiling for release${RESET}"
    fi
done

# ── 2e. Thin every Mach-O to $ARCH ────────────────────────────────────────
# Interpreter.app ships Apple-Silicon-only. The OMC executable and Abracode.framework pieces
# arrive UNIVERSAL from the AppletBuilder template, so any fat binary anywhere in the bundle
# is thinned to $ARCH here, before signing. In-place replacement via cat keeps the file's
# inode and permissions; already-thin files are untouched, so re-runs are no-ops, and a
# framework refresh that reintroduces fat binaries is caught on the next update.
/usr/bin/find "$APP_BUNDLE" -type f | while IFS= read -r _mf; do
    _archs=$(/usr/bin/lipo -archs "$_mf" 2>/dev/null) || continue
    case "$_archs" in *" "*) ;; *) continue ;; esac
    case " $_archs " in
        *" $ARCH "*) ;;
        *) echo "${YELLOW}  cannot thin (no $ARCH slice): ${_mf#$APP_BUNDLE/}${RESET}"; continue ;;
    esac
    _tmp="${TMPDIR:-/tmp}/thin.$$.$(/usr/bin/basename "$_mf")"
    if /usr/bin/lipo -thin "$ARCH" "$_mf" -output "$_tmp" 2>/dev/null; then
        /bin/cat "$_tmp" > "$_mf" && echo "  thinned ${_mf#$APP_BUNDLE/} -> $ARCH"
    fi
    /bin/rm -f "$_tmp"
done

# ── 3. Codesign ───────────────────────────────────────────────────────────
if [ "$DO_CODESIGN" = "yes" ]; then
    for target in \
        "$MLX_DIR/mlx-swift_Cmlx.bundle" "$MLX_DIR/swift-crypto_Crypto.bundle" \
        "$MLX_DIR/swift-transformers_Hub.bundle" "$MLX_DIR/mlx-agent" \
        "$LLAMA_DIR"/*.dylib "$LLAMA_DIR/llama-server" \
        "$SUPPORT_DIR/pdfutil"; do
        [ -e "$target" ] || continue
        /usr/bin/codesign --force --timestamp=none --sign "$SIGNING_IDENTITY" "$target" >/dev/null 2>&1 \
            && echo "  signed $(basename "$target")" || echo "${RED}  FAILED $(basename "$target")${RESET}"
    done
    # Re-seal the whole app (deep) so the added Support pieces are covered.
    /usr/bin/codesign --force --deep --timestamp=none --sign "$SIGNING_IDENTITY" "$APP_BUNDLE" >/dev/null 2>&1 \
        && echo "  signed $(basename "$APP_BUNDLE")" || echo "${YELLOW}  app re-sign returned nonzero${RESET}"
fi

# ── 4. Verify ─────────────────────────────────────────────────────────────
# LLVM_PROFILE_FILE=/dev/null: even if a future build slips through instrumented, its exit
# dump goes nowhere instead of into the bundle we just signed.
if ( cd "$MLX_DIR" && LLVM_PROFILE_FILE=/dev/null ./mlx-agent 2>&1 ) | /usr/bin/grep -q -- "map "; then
    echo "  ${GREEN}Verify OK${RESET}: mlx-agent launches and lists the 'map' mode"
else
    fail "mlx-agent did not report 'map' mode - stale binary or a dylib load failure."
fi

# pdfutil --version prints "pdfutil <ver>" and exits 0; that proves the binary loads (PDFKit
# linked). Bare pdfutil also exits 0 (usage), so match the output, not just the exit code.
if "$SUPPORT_DIR/pdfutil" --version 2>/dev/null | /usr/bin/grep -q "^pdfutil "; then
    echo "  ${GREEN}Verify OK${RESET}: pdfutil launches"
else
    fail "pdfutil did not report its version - build/link failure."
fi

echo
echo "  ${GREEN}Done.${RESET} $(basename "$APP_BUNDLE") is ready."
echo
