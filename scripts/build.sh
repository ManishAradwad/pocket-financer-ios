#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$repository_root"

derived_data_path=${DERIVED_DATA_PATH:-/tmp/PocketFinancerDerivedData}
configuration=${CONFIGURATION:-Debug}
xcodebuild_jobs=${XCODEBUILD_JOBS:-2}

case "$xcodebuild_jobs" in
    "" | 0 | *[!0-9]*)
        echo "XCODEBUILD_JOBS must be a positive integer." >&2
        exit 64
        ;;
esac

xcodebuild \
    -project PocketFinancer.xcodeproj \
    -scheme PocketFinancer \
    -configuration "$configuration" \
    -destination "generic/platform=iOS Simulator" \
    -derivedDataPath "$derived_data_path" \
    -jobs "$xcodebuild_jobs" \
    CODE_SIGNING_ALLOWED=NO \
    build
