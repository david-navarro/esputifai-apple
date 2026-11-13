#!/usr/bin/env bash
# Builds and tests Core/ (EsputifaiCore) in the official Swift image, so it runs on Linux with
# nothing installed on the host. Smoke tests hit the real YouTube Music.
# Usage: scripts/test-core.sh [--filter <test>]
set -euo pipefail
cd "$(dirname "$0")/.."

# swift:6.2-noble, pinned by digest.
IMAGE="swift@sha256:3459518b2e723a7c363d0f8cfa44fc796c77ecd8c18e92fd10e6f92dd78c0b12"
CACHE="${HOME}/.cache/esputifai-ios-swiftpm"
mkdir -p "$CACHE"

docker run --rm \
  -u "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$PWD/Core:/src" -v "$CACHE:/build" -w /src \
  "$IMAGE" swift test --scratch-path /build "$@"
