#!/bin/sh
# Build langid as a command-line binary.
#
# Usage:
#   ./build.sh                   # produces build/langid (universal, ad-hoc signed)
#   ./build.sh arm64|x86_64      # produces a single-architecture build/langid
#
# Mirrors pdfutil's build.sh deliberately - same contract, same shape, so update_interpreter.sh
# treats the two helpers identically. The contract downstream is build/langid: an ad-hoc signed
# binary at a fixed path. Keep that path and the CLI stable.
#
# Always an optimized release build; the compiler flags are SwiftPM's business (see
# Package.swift). This script only picks architectures, strips and signs.

set -e

cd "$(dirname "$0")"

want="${1:-universal}"
case "$want" in
    universal)    arch_flags="--arch x86_64 --arch arm64" ;;
    arm64|x86_64) arch_flags="--arch $want" ;;
    *) echo "usage: ./build.sh [arm64|x86_64]" >&2; exit 1 ;;
esac

# SwiftPM's scratch directory, in the visible build/ rather than a hidden .build, alongside the
# binary handed to consumers. SwiftPM only creates subdirectories in here, so build/langid does
# not collide with anything it owns.
scratch="build"

# `swift build` runs lipo itself when given more than one --arch, so there is no separate
# universal step. Repeating the flags for --show-bin-path is not a rebuild: it re-resolves and
# prints the path, which differs by architecture selection, so it must not be hardcoded.
# shellcheck disable=SC2086  # $arch_flags must word-split into separate args.
swift build -c release --scratch-path "$scratch" $arch_flags
# shellcheck disable=SC2086
bin_path="$(swift build -c release --scratch-path "$scratch" $arch_flags --show-bin-path)"

# Assemble under a temporary name and rename into place only when the binary is finished. A cp
# that dies partway - full disk, killed build - would otherwise leave a truncated binary that
# still looks like a build product. A rename within one filesystem is atomic.
rm -f build/langid.new
cp "$bin_path/langid" build/langid.new

# Drop the local symbol table before signing; stripping a signed binary invalidates the
# signature, and SwiftPM ad-hoc signs its own output so there is always one to invalidate.
strip -x build/langid.new

codesign -s - build/langid.new

mv build/langid.new build/langid

if [ -d "$bin_path/langid.dSYM" ]; then
    rm -rf build/langid.dSYM.new
    cp -R "$bin_path/langid.dSYM" build/langid.dSYM.new
    rm -rf build/langid.dSYM
    mv build/langid.dSYM.new build/langid.dSYM
fi

lipo -info build/langid

echo "Done."
