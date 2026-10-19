#!/usr/bin/env bash
# Builds the engine (lib/magpie/mobile) into apps/build/Mobile.xcframework
# with gomobile, for the Mac (macos) or the iPhone and its Simulator (ios).
#   apps/build-engine.sh macos|ios|all
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-all}" in
  macos) TARGETS=macos ;;
  ios) TARGETS=ios,iossimulator ;;
  all) TARGETS=macos,ios,iossimulator ;;
  *) echo "usage: $0 macos|ios|all" >&2; exit 2 ;;
esac
export PATH=$(go env GOPATH)/bin:$PATH
go install golang.org/x/mobile/cmd/gomobile@latest
go install golang.org/x/mobile/cmd/gobind@latest
gomobile init
# gomobile needs its bind package in the module; add it for this build only
cp go.mod go.mod.orig && cp go.sum go.sum.orig
trap 'mv go.mod.orig go.mod; mv go.sum.orig go.sum' EXIT
go get golang.org/x/mobile/bind@latest
mkdir -p apps/build
rm -rf apps/build/Mobile.xcframework
gomobile bind -target="$TARGETS" -iosversion 17.0 -ldflags="-s -w" -trimpath \
  -o apps/build/Mobile.xcframework ./lib/magpie/mobile
ls apps/build/Mobile.xcframework
