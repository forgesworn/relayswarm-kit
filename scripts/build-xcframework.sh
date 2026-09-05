#!/usr/bin/env bash
# Builds DataChannel.xcframework: libdatachannel and its dependencies merged
# into one static library with the C API headers, so consumers of the
# transport product need SPM and nothing else - no cmake, no Homebrew.
#
# Usage: scripts/build-xcframework.sh /path/to/libdatachannel/build /path/to/openssl/lib [macOS minimum]
# Produces the checked-in xcframework, its release zip and provenance record.
#
# Today's slice is macos-arm64. Intel and iOS slices are additional cmake
# runs with CMAKE_OSX_ARCHITECTURES/SYSROOT set, merged the same way;
# they are follow-on work, not a different method.
set -euo pipefail

DCBUILD="${1:?libdatachannel build dir}"
SSLLIB="${2:-/opt/homebrew/opt/openssl@3/lib}"
MACOS_MINIMUM="${3:-14.0}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/build"
SRC="$(dirname "$DCBUILD")"

INPUTS=(
    "$DCBUILD/libdatachannel.a"
    "$DCBUILD/deps/libjuice/libjuice.a"
    "$DCBUILD/deps/usrsctp/usrsctplib/libusrsctp.a"
    "$SSLLIB/libssl.a"
    "$SSLLIB/libcrypto.a"
)

for input in "${INPUTS[@]}" "$SRC/include/rtc/rtc.h" "$SRC/include/rtc/version.h"; do
    if [[ ! -f "$input" ]]; then
        echo "missing build input: $input" >&2
        exit 1
    fi
done

mkdir -p "$OUT"
STAGE="$(mktemp -d "$OUT/.datachannel-xcframework.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/headers"

# One merged static library: datachannel, juice, usrsctp, and OpenSSL's
# libssl/libcrypto (Apache-2.0), all licence-compatible with MIT.
libtool -static -o "$STAGE/libdatachannel-merged.a" "${INPUTS[@]}" 2>/dev/null

cp "$SRC/include/rtc/rtc.h" "$SRC/include/rtc/version.h" "$STAGE/headers/"
cat > "$STAGE/headers/module.modulemap" <<'MAP'
module CDataChannel {
    header "rtc.h"
    export *
}
MAP

xcodebuild -create-xcframework \
    -library "$STAGE/libdatachannel-merged.a" -headers "$STAGE/headers" \
    -output "$STAGE/DataChannel.xcframework"

"$HERE/scripts/verify-xcframework.sh" "$STAGE/DataChannel.xcframework" "$MACOS_MINIMUM"

(cd "$STAGE" && zip -qry DataChannel.xcframework.zip DataChannel.xcframework)

SOURCE_COMMIT="$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo unknown)"
SOURCE_VERSION="$(awk '/RTC_VERSION "/ {gsub(/"/, "", $3); print $3}' "$SRC/include/rtc/version.h")"
OPENSSL_VERSION="$(strings "$SSLLIB/libcrypto.a" | awk '/^OpenSSL [0-9]/ {print; exit}')"
{
    echo "format=1"
    echo "libdatachannel_commit=$SOURCE_COMMIT"
    echo "libdatachannel_version=$SOURCE_VERSION"
    echo "openssl_version=$OPENSSL_VERSION"
    echo "macos_minimum=$MACOS_MINIMUM"
    echo "architecture=arm64"
    echo "merged_sha256=$(shasum -a 256 "$STAGE/libdatachannel-merged.a" | awk '{print $1}')"
    echo "swiftpm_checksum=$(swift package compute-checksum "$STAGE/DataChannel.xcframework.zip")"
} > "$STAGE/DataChannel.provenance"

rm -rf \
    "$OUT/headers" \
    "$OUT/DataChannel.xcframework" \
    "$OUT/DataChannel.xcframework.zip" \
    "$OUT/libdatachannel-merged.a" \
    "$OUT/DataChannel.provenance"
mv "$STAGE/headers" "$OUT/headers"
mv "$STAGE/DataChannel.xcframework" "$OUT/DataChannel.xcframework"
mv "$STAGE/DataChannel.xcframework.zip" "$OUT/DataChannel.xcframework.zip"
mv "$STAGE/libdatachannel-merged.a" "$OUT/libdatachannel-merged.a"
mv "$STAGE/DataChannel.provenance" "$OUT/DataChannel.provenance"

echo "checksum: $(swift package compute-checksum "$OUT/DataChannel.xcframework.zip")"
