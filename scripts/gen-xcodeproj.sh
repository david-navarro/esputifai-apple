#!/usr/bin/env bash
# Regenerates Esputifai.xcodeproj and App/Info.plist from project.yml with XcodeGen, in Docker
# (XcodeGen 2.44.1 built from source on first use, pinned by commit; its dependencies come pinned
# by revision in its Package.resolved). Run it after changing project.yml or adding,
# moving or deleting source files, and commit the result.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="swift@sha256:3459518b2e723a7c363d0f8cfa44fc796c77ecd8c18e92fd10e6f92dd78c0b12"
XCODEGEN_COMMIT="21ac9944b0ab546a07422dbed86f33dd2ebd76f8" # tag 2.44.1
CACHE="${HOME}/.cache/esputifai-ios-xcodegen"
SRC="${CACHE}-src"
mkdir -p "$CACHE"
if [ ! -x "$CACHE/release/xcodegen" ]; then
  [ -d "$SRC" ] || git clone -q --depth 1 --branch 2.44.1 https://github.com/yonaskolb/XcodeGen.git "$SRC"
  [ "$(git -C "$SRC" rev-parse HEAD)" = "$XCODEGEN_COMMIT" ] || { echo "XcodeGen source is not $XCODEGEN_COMMIT" >&2; exit 1; }
  docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$SRC:/src" -v "$CACHE:/build" -w /src \
    "$IMAGE" swift build -c release --scratch-path /build --product xcodegen
fi
# XcodeGen finds its setting presets (PRODUCT_NAME and the like) at the source path it was built
# from, /src/SettingPresets; without that mount the project has no presets and Xcode can't build it.
docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -e USER=esputifai -v "$PWD:/proj" -v "$CACHE:/build" -v "$SRC:/src:ro" -w /proj \
  "$IMAGE" /build/release/xcodegen generate
