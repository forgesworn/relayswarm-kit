#!/bin/bash
# Builds DataChannel.xcframework: libdatachannel and its dependencies merged
# into one static library with the C API headers, so consumers of the
# transport product need SPM and nothing else - no cmake, no Homebrew.
#
# Usage: scripts/build-xcframework.sh /path/to/libdatachannel/build /path/to/openssl/lib
# Produces build/DataChannel.xcframework.zip and prints its SPM checksum.
#
# Today's slice is macos-arm64. Intel and iOS slices are additional cmake
# runs with CMAKE_OSX_ARCHITECTURES/SYSROOT set, merged the same way;
# they are follow-on work, not a different method.
set -euo pipefail

DCBUILD="${1:?libdatachannel build dir}"
SSLLIB="${2:-/opt/homebrew/opt/openssl@3/lib}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/build"
rm -rf "$OUT/headers" "$OUT/DataChannel.xcframework" "$OUT/DataChannel.xcframework.zip"
mkdir -p "$OUT/headers"

# One merged static library: datachannel, juice, usrsctp, and OpenSSL's
# libssl/libcrypto (Apache-2.0), all licence-compatible with MIT.
libtool -static -o "$OUT/libdatachannel-merged.a" \
    "$DCBUILD/libdatachannel.a" \
    "$DCBUILD/deps/libjuice/libjuice.a" \
    "$DCBUILD/deps/usrsctp/usrsctplib/libusrsctp.a" \
    "$SSLLIB/libssl.a" \
    "$SSLLIB/libcrypto.a" 2>/dev/null

SRC="$(dirname "$DCBUILD")"
cp "$SRC/include/rtc/rtc.h" "$SRC/include/rtc/version.h" "$OUT/headers/"
cat > "$OUT/headers/module.modulemap" <<'MAP'
module CDataChannel {
    header "rtc.h"
    export *
}
MAP

xcodebuild -create-xcframework \
    -library "$OUT/libdatachannel-merged.a" -headers "$OUT/headers" \
    -output "$OUT/DataChannel.xcframework"

(cd "$OUT" && zip -qry DataChannel.xcframework.zip DataChannel.xcframework)
echo "checksum: $(swift package compute-checksum "$OUT/DataChannel.xcframework.zip")"
