#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$repository_root"

derived_data_path=${DERIVED_DATA_PATH:-/tmp/PocketFinancerDerivedData}
test_destination=${TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro,OS=latest}
xcodebuild_jobs=${XCODEBUILD_JOBS:-2}
enable_code_coverage=${ENABLE_CODE_COVERAGE:-NO}

case "$xcodebuild_jobs" in
    "" | 0 | *[!0-9]*)
        echo "XCODEBUILD_JOBS must be a positive integer." >&2
        exit 64
        ;;
esac

case "$enable_code_coverage" in
    YES | NO) ;;
    *)
        echo "ENABLE_CODE_COVERAGE must be YES or NO." >&2
        exit 64
        ;;
esac

set -- xcodebuild \
    -project PocketFinancer.xcodeproj \
    -scheme PocketFinancer \
    -configuration Debug \
    -destination "$test_destination" \
    -derivedDataPath "$derived_data_path" \
    -jobs "$xcodebuild_jobs" \
    -enableCodeCoverage "$enable_code_coverage" \
    -parallel-testing-enabled NO \
    -maximum-concurrent-test-simulator-destinations 1

if [ -n "${RESULT_BUNDLE_PATH:-}" ]; then
    set -- "$@" -resultBundlePath "$RESULT_BUNDLE_PATH"
fi

set -- "$@" CODE_SIGNING_ALLOWED=NO test
exec "$@"
