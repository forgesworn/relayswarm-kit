#!/usr/bin/env bash
set -euo pipefail

XCFRAMEWORK="${1:-build/DataChannel.xcframework}"
MAXIMUM_MINIMUM="${2:-14.0}"
ARCHIVE="$XCFRAMEWORK/macos-arm64/libdatachannel-merged.a"

if [[ ! -f "$ARCHIVE" ]]; then
    echo "missing xcframework archive: $ARCHIVE" >&2
    exit 1
fi

ARCHITECTURES="$(lipo -archs "$ARCHIVE")"
if [[ "$ARCHITECTURES" != "arm64" ]]; then
    echo "unexpected architectures: $ARCHITECTURES (expected arm64)" >&2
    exit 1
fi

METADATA="$(otool -l "$ARCHIVE" | awk '
    /cmd LC_BUILD_VERSION/ { in_build = 1; platform = ""; next }
    in_build && /platform/ { platform = $2; next }
    in_build && /minos/ { print platform, $2; in_build = 0 }
')"

OBJECT_COUNT="$(ar -t "$ARCHIVE" | awk '$0 != "__.SYMDEF" { count++ } END { print count + 0 }')"
METADATA_COUNT="$(printf '%s\n' "$METADATA" | awk 'NF { count++ } END { print count + 0 }')"
if [[ "$METADATA_COUNT" -ne "$OBJECT_COUNT" ]]; then
    echo "deployment metadata missing: inspected $METADATA_COUNT of $OBJECT_COUNT objects" >&2
    exit 1
fi

INVALID="$(printf '%s\n' "$METADATA" | awk -v maximum="$MAXIMUM_MINIMUM" '
    function number(version, parts, count) {
        count = split(version, parts, ".")
        return (parts[1] + 0) * 1000000 + (parts[2] + 0) * 1000 + (parts[3] + 0)
    }
    $1 != 1 || number($2) > number(maximum) { print }
')"
if [[ -n "$INVALID" ]]; then
    echo "xcframework contains non-macOS objects or objects newer than macOS $MAXIMUM_MINIMUM:" >&2
    printf '%s\n' "$INVALID" | sort | uniq -c >&2
    exit 1
fi

MINIMA="$(printf '%s\n' "$METADATA" | awk '{print $2}' | sort -u | paste -sd, -)"
echo "verified $OBJECT_COUNT arm64 macOS objects; deployment minima: $MINIMA (maximum $MAXIMUM_MINIMUM)"
