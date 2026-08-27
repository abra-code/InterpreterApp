#!/bin/bash
# update_interpreter.sh
# Build mlx-agent and assemble the git-excluded runtime pieces into Interpreter.app.
# Trimmed from MLXChat's update script: Interpreter needs ONLY the mlx-agent binary and its
# resource bundles (no replay, no MCP packages, no embedded Python).
#
# Steps: (1) build mlx-agent via xcodebuild (Metal shaders need the xcode build; there is no
# longer a Package.swift to `swift build` at all, and the products land in the repo's
# `build/` derived-data dir), (2) copy mlx-agent + mlx-swift_Cmlx.bundle (+ optional crypto/transformers
# bundles) to Contents/Support/MLX/, build + embed pdfutil from its sibling repo, (3) deep-sign
# the whole bundle via codesign_applet.sh, (4) verify the deployed agent launches and is the
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
LLAMA_VERSION_PIN="b10056"
LLAMA_VERSION="$LLAMA_VERSION_PIN"

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "$0")" >/dev/null 2>&1 && pwd)"
AGENT_REPO="${MLX_AGENT_REPO:-}"
PDFUTIL_REPO="${PDFUTIL_REPO:-}"

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
            echo "Usage: $0 [--release] [--arch=arm64|x86_64] [--agent-repo=PATH] [--skip-build] [--identity=CERT] [--no-codesign] [--with-llama] [--llama-version=bNNNN|latest|nightly]"
            echo "  --llama-version  implies --with-llama. Takes:"
            echo "                   bNNNN    an explicit llama.cpp build tag"
            echo "                   latest   upstream's newest official release (vX.Y.Z, resolved to its build)"
            echo "                   nightly  upstream's newest build, released or not"
            echo "                   default: $LLAMA_VERSION_PIN, the build the map openai backend was verified against"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

fail() { echo "${RED}$*${RESET}" >&2; exit 1; }

# A dependency repo is missing: offer to git-clone it into the sibling location and continue.
# Interactive runs only - without a TTY (CI, piped stdin) this declines silently and the
# caller's fail() fires with the manual instructions. $1 = repo URL, $2 = destination dir.
offer_clone() {
    [ -t 0 ] || return 1
    printf "%s  %s not found. Clone %s\n  into %s now? [y/N] %s" \
        "$YELLOW" "$(/usr/bin/basename "$2")" "$1" "$2" "$RESET"
    local _ans
    IFS= read -r _ans
    case "$_ans" in [yY]|[yY][eE][sS]) ;; *) return 1 ;; esac
    /usr/bin/git clone "$1" "$2"
}

[ "$ARCH" = "auto" ] && ARCH="$(/usr/bin/uname -m)"
case "$ARCH" in arm64|x86_64) ;; *) fail "Invalid --arch: $ARCH" ;; esac

# Auto-detect the single .app bundle beside this script.
APP_BUNDLE=""
for _c in "$SCRIPT_DIR"/*.app; do [ -d "$_c" ] && { APP_BUNDLE="$_c"; break; }; done
[ -n "$APP_BUNDLE" ] || fail "No .app bundle found in $SCRIPT_DIR"
MLX_DIR="$APP_BUNDLE/Contents/Support/MLX"
SUPPORT_DIR="$APP_BUNDLE/Contents/Support"

# Locate the pdfutil repo (PDF text extraction helper): env override, then sibling dir,
# offering to clone it there when missing (only when a build is requested - --skip-build
# reuses the already-deployed binary). Built by its own build.sh (plain swiftc, system
# frameworks only).
if [ -z "$PDFUTIL_REPO" ]; then
    for _cand in "$SCRIPT_DIR/../pdfutil"; do
        [ -f "$_cand/build.sh" ] && [ -d "$_cand/Sources" ] && { PDFUTIL_REPO="$(cd "$_cand" && pwd)"; break; }
    done
fi
if [ -z "$PDFUTIL_REPO" ] && [ "$DO_BUILD" = "yes" ]; then
    offer_clone "https://github.com/abra-code/pdfutil" "$(cd "$SCRIPT_DIR/.." && pwd)/pdfutil" \
        && [ -f "$SCRIPT_DIR/../pdfutil/build.sh" ] \
        && PDFUTIL_REPO="$(cd "$SCRIPT_DIR/../pdfutil" && pwd)"
fi

# Locate the mlx-agent repo (github.com/abra-code/mlx-agent, Apache 2.0): env override,
# then sibling dir, offering to clone it there when missing.
# Identified by the Xcode PROJECT, not Package.swift: mlx-agent dropped its package manifest
# when it moved to an XcodeGen-generated project (the Metal shaders forced xcodebuild, and
# two manifests meant two dependency graphs that could drift). The .xcodeproj is committed.
if [ -z "$AGENT_REPO" ]; then
    for _cand in "$SCRIPT_DIR/../mlx-agent"; do
        [ -d "$_cand/mlx-agent.xcodeproj" ] && { AGENT_REPO="$(cd "$_cand" && pwd)"; break; }
    done
fi
if [ -z "$AGENT_REPO" ]; then
    offer_clone "https://github.com/abra-code/mlx-agent" "$(cd "$SCRIPT_DIR/.." && pwd)/mlx-agent" \
        && [ -d "$SCRIPT_DIR/../mlx-agent/mlx-agent.xcodeproj" ] \
        && AGENT_REPO="$(cd "$SCRIPT_DIR/../mlx-agent" && pwd)"
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
/bin/cp -f "$AGENT_BUILD_DIR/mlx-agent" "$MLX_DIR/mlx-agent" || fail "Could not deploy mlx-agent"
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
[ -f "$AGENT_REPO/LICENSE" ] || fail "No LICENSE in $AGENT_REPO - mlx-agent's Apache 2.0 notice has to ship with it"
/bin/cp -f "$AGENT_REPO/LICENSE" "$MLX_DIR/mlx-agent.LICENSE" || fail "Could not deploy mlx-agent's LICENSE"

# mlx-agent's own LICENSE covers mlx-agent. The binary is a STATIC link of ~18 Swift packages
# under MIT/Apache/BSD terms, and three of them also ship the resource bundles copied just
# above - default.metallib is compiled Metal shader code from mlx-swift (MIT), redistributed
# with no notice of its own. Those licenses all require the notice to accompany the binary,
# so the agent repo generates one from its resolved package graph and it ships beside the
# binary. Generated rather than hand-maintained: a new dependency must not be able to arrive
# without its notice, and the generator fails if any package's license text is missing.
_notices_gen="$AGENT_REPO/tools/generate_third_party_notices.sh"
[ -x "$_notices_gen" ] || fail "No $_notices_gen - update the mlx-agent checkout (the third-party notices ship beside the binary)"
# Regeneration needs the SPM checkouts, which live in the agent repo's derived-data dir next
# to the products this script copies from. They normally live or die together, but an
# xcodebuild clean can take one and not the other - so under --skip-build, fall back to the
# copy already deployed rather than blocking a re-sign. The gate below still refuses to sign
# if that leaves nothing there.
if ! "$_notices_gen" --output "$MLX_DIR/mlx-agent.THIRD-PARTY-NOTICES.txt"; then
    if [ "$DO_BUILD" = "no" ] && [ -s "$MLX_DIR/mlx-agent.THIRD-PARTY-NOTICES.txt" ]; then
        echo "${YELLOW}  WARNING: could not regenerate the third-party notices; keeping the deployed copy (--skip-build)${RESET}"
    else
        fail "Could not generate mlx-agent's third-party notices"
    fi
fi
echo "  ${GREEN}Deployed${RESET} mlx-agent + metallib + third-party notices"

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
    [ -f "$PDFUTIL_REPO/LICENSE" ] || fail "No LICENSE in $PDFUTIL_REPO - pdfutil's Apache 2.0 notice has to ship with it"
    /bin/cp -f "$PDFUTIL_REPO/LICENSE" "$SUPPORT_DIR/pdfutil.LICENSE" || fail "Could not deploy pdfutil's LICENSE"
    /bin/rm -f "$SUPPORT_DIR/pdftext"   # retire the old helper on upgrade
    echo "  ${GREEN}Built${RESET} pdfutil ($ARCH)"
fi
[ -x "$SUPPORT_DIR/pdfutil" ] || fail "No pdfutil at $SUPPORT_DIR/pdfutil (build first, or drop --skip-build)."

# ── 2b2. Build + embed the langid helper ──────────────────────────────────
# langid identifies a document's source language (Tools/langid in THIS repo - unlike mlx-agent
# and pdfutil it is not a sibling checkout, so there is nothing to locate and no third-party
# LICENSE to ship beside it). NaturalLanguage only: no model, no Apple Intelligence, ~3 ms.
if [ "$DO_BUILD" = "yes" ]; then
    ( cd "$SCRIPT_DIR/Tools/langid" && ./build.sh "$ARCH" ) || fail "langid build.sh failed"
    /bin/cp -f "$SCRIPT_DIR/Tools/langid/build/langid" "$SUPPORT_DIR/langid" || fail "Could not copy langid"
    /bin/chmod +x "$SUPPORT_DIR/langid"
    echo "  ${GREEN}Built${RESET} langid ($ARCH)"
fi
[ -x "$SUPPORT_DIR/langid" ] || fail "No langid at $SUPPORT_DIR/langid (build first, or drop --skip-build)."

# ── 2c. llama.cpp engine (gguf models, opt-in) ────────────────────────────
# Prebuilt upstream release tarball -> Contents/Support/Llama.cpp/ (llama-server + dylibs,
# @rpath-linked so they only need to sit together). Same provisioning as AIChat V2, but pinned:
# the map openai backend's wire mapping was verified against this build.
#
# --llama-version=latest resolves upstream's newest official release instead. The pin stays
# the default deliberately: moving off it means re-checking the /tokenize + /completion field
# names the map openai backend reads, so it has to be an explicit act, never a silent one.
#
# llama.cpp changed its release scheme in August 2026. The macOS binaries still ship on the
# bNNNN build tags under unchanged asset names, but those tags are now all marked prerelease,
# and /releases/latest resolves to an official semver release (v0.3.0 as of this writing)
# whose only asset is nightly-tag.txt, naming the build the release was cut from. Reading a
# bNNNN tag straight off /releases/latest therefore matches nothing; resolving "latest" is now
# two hops. We follow the official release rather than the head of the build list, and never
# silently fall back from one to the other: an unresolvable release is an error the caller has
# to answer, because quietly installing the newest untagged build is exactly the behavior the
# official releases exist to end. --llama-version=nightly opts into that head build.

# Echoes the tag_name of the newest official (non-prerelease) release, or nothing.
latest_release_tag() {
    local _json="$(/usr/bin/curl -s --fail --max-time 10 \
        "https://api.github.com/repos/ggml-org/llama.cpp/releases/latest" 2>/dev/null)"
    # grep -o emits its matches in document order, so head -1 is the first tag_name in the
    # document whether or not the JSON is pretty-printed. A greedy sed would instead collapse
    # a minified (single-line) document down to its LAST occurrence.
    local _tag="$(echo "$_json" \
        | /usr/bin/grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | /usr/bin/head -1 | /usr/bin/sed -E 's/.*"([^"]+)"$/\1/')"
    if [ -n "$_tag" ]; then
        echo "$_tag"
        return 0
    fi

    # API unreachable or rate-limited (60 anonymous requests/hour): read the tag out of the
    # /releases/latest redirect instead, which is not rate-limited.
    local _redirect="$(/usr/bin/curl -s -I -o /dev/null -w '%{redirect_url}' --max-time 10 \
        "https://github.com/ggml-org/llama.cpp/releases/latest" 2>/dev/null)"
    echo "$_redirect" | /usr/bin/sed -n -E 's#.*/releases/tag/([^/?\#[:space:]]+)$#\1#p'
}

# Echoes the bNNNN build tag an official release points at, or nothing. $1 = release tag.
nightly_tag_of_release() {
    local _txt="$(/usr/bin/curl -sL --fail --max-time 10 \
        "https://github.com/ggml-org/llama.cpp/releases/download/$1/nightly-tag.txt" 2>/dev/null)"
    echo "$_txt" | /usr/bin/tr -d '[:space:]' | /usr/bin/grep -oE '^b[0-9]+$'
}

# Echoes the newest bNNNN tag in the releases list (build tags are prereleases now, so the
# list is the only place they appear). The list is newest-first.
newest_build_tag() {
    local _json="$(/usr/bin/curl -s --fail --max-time 15 \
        "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=30" 2>/dev/null)"
    # Document order via grep -o, as in latest_release_tag: with a greedy sed, a minified
    # response would silently yield the OLDEST build in the page instead of the newest.
    echo "$_json" \
        | /usr/bin/grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"b[0-9]+"' \
        | /usr/bin/head -1 | /usr/bin/grep -oE 'b[0-9]+'
}

# Replaces a LLAMA_VERSION of "latest" or "nightly" with the bNNNN build tag it resolves to.
resolve_llama_version() {
    local _tag
    if [ "$LLAMA_VERSION" = "nightly" ]; then
        echo "  Detecting newest llama.cpp build..."
        _tag="$(newest_build_tag)"
        [ -n "$_tag" ] \
            || fail "No bNNNN tag in the llama.cpp releases list - github.com unreachable, or the API rate-limited this host. Pass --llama-version=bNNNN explicitly."
        LLAMA_VERSION="$_tag"
        echo "    newest build: $LLAMA_VERSION"
        return 0
    fi

    echo "  Detecting latest llama.cpp release..."
    local _release="$(latest_release_tag)"
    [ -n "$_release" ] \
        || fail "Could not read a tag from github.com/ggml-org/llama.cpp/releases/latest - unreachable, or the API rate-limited this host. Pass --llama-version=bNNNN explicitly."

    case "$_release" in
        b|b*[!0-9]*)
            # b-prefixed but not a bare build number (say b10-rc1): a release tag, not a
            # build tag. Fall through to the nightly-tag.txt hop rather than build a URL.
            ;;
        b[0-9]*)
            # Upstream tagging official releases bNNNN directly (the pre-v0.1.2 scheme).
            LLAMA_VERSION="$_release"
            echo "    latest release: $LLAMA_VERSION"
            return 0
            ;;
    esac

    _tag="$(nightly_tag_of_release "$_release")"
    [ -n "$_tag" ] \
        || fail "Release $_release has no readable nightly-tag.txt, so the build tag carrying the macOS binaries is unknown - the release scheme has changed again. Check https://github.com/ggml-org/llama.cpp/releases and pass --llama-version=bNNNN, or --llama-version=nightly for the newest build."
    LLAMA_VERSION="$_tag"
    echo "    latest release $_release -> build $LLAMA_VERSION"
}

LLAMA_DIR="$APP_BUNDLE/Contents/Support/Llama.cpp"
if [ "$DO_LLAMA" = "yes" ]; then
    case "$LLAMA_VERSION" in
        latest|nightly) resolve_llama_version ;;
    esac
    case "$LLAMA_VERSION" in b[0-9]*) ;; *) fail "Invalid --llama-version: $LLAMA_VERSION (expected latest, nightly, or a build tag bNNNN)" ;; esac
    # Off the pin: say so once, here, rather than leaving it to be discovered as a wire-format
    # mismatch at runtime.
    [ "$LLAMA_VERSION" = "$LLAMA_VERSION_PIN" ] \
        || echo "  ${YELLOW}llama.cpp $LLAMA_VERSION is not the pinned $LLAMA_VERSION_PIN - re-check the /tokenize + /completion field names the map openai backend reads.${RESET}"
    case "$ARCH" in arm64) _lasset="llama-${LLAMA_VERSION}-bin-macos-arm64.tar.gz" ;;
                    *)     _lasset="llama-${LLAMA_VERSION}-bin-macos-x64.tar.gz" ;; esac
    _lwork="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/update-interp-llama.XXXXXX")" || fail "mktemp failed"
    # Every fail() below this point exits with the tarball plus its extracted copy (~80 MB)
    # still in TMPDIR, so hang the cleanup off EXIT rather than repeating it at each site.
    # The signal traps must exit: a handler that just cleans up and returns resumes the script
    # at the point of interruption, so Ctrl-C during the ~80 MB download would carry on into
    # thinning and signing and print "Done." Exiting re-fires the EXIT trap, so the temp tree
    # is still reclaimed on every path.
    trap '/bin/rm -rf "$_lwork"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    trap 'exit 131' QUIT
    echo "  Downloading llama.cpp $LLAMA_VERSION"
    /usr/bin/curl -L --fail --show-error --progress-bar -o "$_lwork/$_lasset" \
        "https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_VERSION}/${_lasset}" \
        || fail "llama.cpp download failed"
    /bin/mkdir -p "$_lwork/x" && /usr/bin/tar -xzf "$_lwork/$_lasset" -C "$_lwork/x" || fail "llama.cpp extract failed"
    _lbin=$(/usr/bin/find "$_lwork/x" -name llama-server -type f | /usr/bin/head -1)
    [ -n "$_lbin" ] || fail "llama-server not in the release archive"
    /bin/rm -rf "$LLAMA_DIR" && /bin/mkdir -p "$LLAMA_DIR"
    # An unchecked copy here would be the whole bug again by another door: the dylibs below are
    # MIT too, so llama-server going missing while they land would leave a payload the license
    # gate does not key on.
    /bin/cp -f "$_lbin" "$LLAMA_DIR/llama-server" || fail "Could not deploy llama-server"
    /bin/chmod +x "$LLAMA_DIR/llama-server" || fail "Could not make llama-server executable"
    # cp -R, NOT cp -f: 18 of the archive's 35 dylibs are symlinks in a two-deep chain
    # (libggml-base.dylib -> .0.dylib -> .0.16.0.dylib). cp -f follows them, so every library
    # landed three times - 51 MB where 33 would do, each copy separately thinned and separately
    # signed. BSD cp -R copies a symlink as a symlink. codesign_applet.sh only signs regular
    # files, and the thinning loop below is -type f, so both correctly skip the links.
    #
    # Counted, because find -exec (and a piped while) returns 0 when NOTHING matched: a moved
    # archive layout would otherwise deploy llama-server plus its notice and no libraries - a
    # gate-passing, non-functional engine, which is the failure this whole block guards against.
    # Via a list file rather than a pipe: a piped `while` runs in a subshell, so the count would
    # not survive it, and process substitution would make this the one bashism in the file.
    _ldylibs="$_lwork/dylibs.list"
    # -type f -o -type l, because cp -R would happily recurse into a DIRECTORY named *.dylib -
    # the old cp -f failed loudly on that, so the type filter has to replace the protection
    # that switching to -R gave up.
    /usr/bin/find "$(/usr/bin/dirname "$_lbin")" -maxdepth 1 \( -type f -o -type l \) -name "*.dylib" -print > "$_ldylibs" \
        || { /bin/rm -rf "$LLAMA_DIR"; fail "Could not list the llama.cpp dylibs"; }
    _ln=$(/usr/bin/wc -l < "$_ldylibs" | /usr/bin/tr -d " ")
    [ "${_ln:-0}" -gt 0 ] || { /bin/rm -rf "$LLAMA_DIR"; fail "No dylibs beside llama-server in the llama.cpp $LLAMA_VERSION archive - the layout changed. Contents/Support/Llama.cpp has been removed."; }
    while IFS= read -r _d; do
        /bin/cp -R "$_d" "$LLAMA_DIR/" || { /bin/rm -rf "$LLAMA_DIR"; fail "Could not deploy $(/usr/bin/basename "$_d") (Contents/Support/Llama.cpp has been removed)"; }
    done < "$_ldylibs"
    # A nonzero count is not the same as a working engine: if a future layout kept the symlink
    # chain here and moved the real libraries elsewhere, every link would deploy dangling and
    # the count would still pass. -e follows the link, so this catches exactly that.
    for _l in "$LLAMA_DIR"/*.dylib; do
        [ -e "$_l" ] || { /bin/rm -rf "$LLAMA_DIR"; fail "Deployed a dangling symlink ($(/usr/bin/basename "$_l")) - the llama.cpp $LLAMA_VERSION layout changed. Contents/Support/Llama.cpp has been removed."; }
    done
    # llama.cpp is MIT: the notice must travel with the binaries we ship, so a missing LICENSE
    # is fatal, not a shrug - 1.0 shipped bare because this was written as [ -f ] && cp, which
    # cannot fail a build. b10056 keeps LICENSE beside llama-server; search outward from there
    # rather than guessing at fixed paths, since the archive layout has moved before. Both the
    # probe and the copy must happen before the EXIT trap reclaims $_lwork.
    # The fallback filters by CONTENT first and only then takes the shallowest survivor. Depth
    # alone is not evidence: a vendored MIT notice sitting one level above llama.cpp's own would
    # win on position and pass a bare "is it MIT?" check, deploying the wrong text with a zero
    # exit - worse than failing. Filtering first also stops a shallower non-MIT decoy from being
    # picked and then rejected, which would fail a build whose archive did contain the notice.
    _lfound="$(/usr/bin/dirname "$_lbin")/LICENSE"
    if [ ! -f "$_lfound" ]; then
        _lfound=$(/usr/bin/find "$_lwork/x" -maxdepth 4 -name "LICENSE*" -type f \
                  -exec /usr/bin/grep -qi "ggml" {} \; -print \
                  | /usr/bin/awk '{ print gsub(/\//,"/"), $0 }' \
                  | /usr/bin/sort -n | /usr/bin/head -1 | /usr/bin/cut -d" " -f2-)
        # A newline in a filename splits one find record into two; the tail fragment has no
        # slashes, so it always sorts first. Anything not under the temp tree is not a path.
        case "$_lfound" in "$_lwork"/*) ;; *) _lfound="" ;; esac
    fi
    # Roll the half-deployed engine back before bailing: leaving the binaries without their
    # notice would trip the pre-signing gate on every later run, including plain re-signs.
    [ -n "$_lfound" ] && [ -f "$_lfound" ] || { /bin/rm -rf "$LLAMA_DIR"; fail "No LICENSE in the llama.cpp $LLAMA_VERSION archive - the MIT notice has to ship beside llama-server. Contents/Support/Llama.cpp has been removed; re-run with --with-llama once the archive layout is sorted out."; }
    # Whatever the search turned up has to actually be llama.cpp's notice, not a neighbor's -
    # including a neighbor that is ALSO MIT. Both assertions apply to the primary probe too, so
    # a LICENSE sitting beside llama-server still has to look like the right one.
    /usr/bin/grep -q "MIT License" "$_lfound" && /usr/bin/grep -qi "ggml" "$_lfound" \
        || { /bin/rm -rf "$LLAMA_DIR"; fail "The LICENSE at $_lfound is not llama.cpp's MIT notice (expected the MIT text naming the ggml authors) - Contents/Support/Llama.cpp has been removed"; }
    /bin/cp -f "$_lfound" "$LLAMA_DIR/LICENSE" || { /bin/rm -rf "$LLAMA_DIR"; fail "Could not deploy the llama.cpp LICENSE (Contents/Support/Llama.cpp has been removed)"; }
    echo "  ${GREEN}Deployed${RESET} llama.cpp $LLAMA_VERSION -> Contents/Support/Llama.cpp"
fi

# ── 2d. Sweep build/runtime droppings out of Support ──────────────────────
# LLVM coverage-instrumented binaries dump default.profraw into their CWD at exit - and the
# verify step below runs mlx-agent with CWD inside the bundle, which once shipped a stale
# profraw. Sweep profiling artifacts (and Finder droppings) before signing, and warn if a
# deployed binary is itself instrumented: instrumentation has no place in a shipping build.
/usr/bin/find "$SUPPORT_DIR" \( -name "*.profraw" -o -name "*.profdata" -o -name ".DS_Store" \) -delete
for _bin in "$MLX_DIR/mlx-agent" "$LLAMA_DIR/llama-server" "$SUPPORT_DIR/pdfutil" "$SUPPORT_DIR/langid"; do
    [ -f "$_bin" ] || continue
    if /usr/bin/otool -l "$_bin" 2>/dev/null | /usr/bin/grep -q "__llvm_prf"; then
        echo "${YELLOW}  WARNING: $(basename "$_bin") is coverage-instrumented (__llvm_prf) - rebuild without profiling for release${RESET}"
    fi
done

# Every bundled third-party binary must carry its license notice - MIT and Apache 2.0 both
# require the notice to accompany the binary form we redistribute. The deploy steps above each
# fail loudly on a missing LICENSE, but they only run when their stage runs: a --skip-build or
# a plain run inherits whatever an EARLIER run left in Support. 1.0 shipped llama-server with
# no LICENSE that way (the copy probed the wrong path and failed silently), so gate on what is
# actually in the bundle, on every run, right before signing.
#
# $1 = payload that must be covered (a bundled binary, or a directory holding several),
# $2 = the license file that has to sit with it, $3 = how to regenerate it. Two arguments, not
# one packed "bin:license" string: a colon is legal in a macOS path (Finder writes a typed "/"
# as ":"), and splitting such a string yields two wrong paths whose missing-binary check then
# passes the gate silently - the exact failure mode this gate exists to catch.
# $4 is an optional display name: basename of a DIRECTORY payload reads oddly ("MLX is in the
# bundle"), so the legs that key on a directory name what is actually in it.
require_license() {
    [ -e "$1" ] || return 0
    [ -s "$2" ] && return 0
    fail "${4:-$(/usr/bin/basename "$1")} is in the bundle but ${2#"$APP_BUNDLE"/} is missing or empty - its license notice must ship with it. Re-run with $3."
}
require_license "$MLX_DIR/mlx-agent"   "$MLX_DIR/mlx-agent.LICENSE" "a full build (no --skip-build)"
require_license "$SUPPORT_DIR/pdfutil" "$SUPPORT_DIR/pdfutil.LICENSE" "a full build (no --skip-build)"
# Keyed on the resource bundles as well as the binary: mlx-swift's default.metallib and the
# swift-crypto / swift-transformers bundles are third-party payload in their own right, so a
# deploy that landed them without the binary must still be caught.
if [ -f "$MLX_DIR/mlx-agent" ] || [ -n "$(/usr/bin/find "$MLX_DIR" -maxdepth 1 -name "*.bundle" -print -quit 2>/dev/null)" ]; then
    require_license "$MLX_DIR" "$MLX_DIR/mlx-agent.THIRD-PARTY-NOTICES.txt" "a full build (no --skip-build)" "mlx-agent and its resource bundles"
fi
# Keyed on the directory, not on llama-server: the ~30 ggml/llama dylibs beside it are MIT in
# their own right, so a deploy that dropped the server but landed the libraries must still be
# caught. Anything in there other than the notice itself counts as payload - "! -type d" and
# not "-type f", because 18 of those dylibs are now symlinks and -type f would look straight
# past a directory holding nothing else.
if [ -n "$(/usr/bin/find "$LLAMA_DIR" ! -type d ! -name LICENSE -print -quit 2>/dev/null)" ]; then
    require_license "$LLAMA_DIR" "$LLAMA_DIR/LICENSE" "--with-llama" "the llama.cpp engine"
fi

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
# Deep-sign with codesign_applet.sh (shipped beside this script): it signs every
# loose Mach-O and nested code bundle deepest-first - the added Support/ engines
# included - then the app itself, replacing the deprecated `codesign --deep`, and
# verifies the result. --brief keeps its output to per-bundle summary lines.
if [ "$DO_CODESIGN" = "yes" ]; then
    if [ -x "$SCRIPT_DIR/codesign_applet.sh" ]; then
        "$SCRIPT_DIR/codesign_applet.sh" --brief "$APP_BUNDLE" "$SIGNING_IDENTITY" \
            || echo "${YELLOW}  codesign_applet.sh returned nonzero${RESET}"
    else
        echo "${YELLOW}  codesign_applet.sh not found beside this script - skipping codesign${RESET}"
    fi
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

# langid --version prints "langid <ver>" and exits 0, proving NaturalLanguage linked. Bare
# langid with no stdin prints usage and exits 2, so match the output rather than the status.
if "$SUPPORT_DIR/langid" --version 2>/dev/null | /usr/bin/grep -q "^langid "; then
    echo "  ${GREEN}Verify OK${RESET}: langid launches"
else
    fail "langid did not report its version - build/link failure."
fi

echo
echo "  ${GREEN}Done.${RESET} $(basename "$APP_BUNDLE") is ready."
echo
