#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$repository_root"

case "${1:-}" in
    --lint)
        xcrun swift-format lint \
            --configuration .swift-format \
            --recursive \
            --parallel \
            --strict \
            PocketFinancer PocketFinancerTests PocketFinancerUITests
        ;;
    "" | --fix)
        xcrun swift-format format \
            --configuration .swift-format \
            --recursive \
            --parallel \
            --in-place \
            PocketFinancer PocketFinancerTests PocketFinancerUITests
        ;;
    *)
        echo "Usage: scripts/format.sh [--lint|--fix]" >&2
        exit 64
        ;;
esac
