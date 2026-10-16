#!/bin/bash
# Builds TorrServerKit.xcframework (TorrServer's Go engine via gomobile) into Frameworks/.
# Requires macOS + full Xcode + Go + Node. Pinned to a known-good TorrServer commit.
set -euo pipefail

TORRSERVER_COMMIT="${TORRSERVER_COMMIT:-98cdbacaddfac278a21a4a4d6424bd3a9dcd407f}"
IOS_VERSION_MIN="${IOS_VERSION_MIN:-17.0}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${ROOT}/.build/torrserver"
OUT="${ROOT}/Frameworks/TorrServerKit.xcframework"

if [[ -d "${OUT}" && "${FORCE:-0}" != "1" ]]; then
  echo "TorrServerKit.xcframework already present (FORCE=1 to rebuild)"
  exit 0
fi

rm -rf "${WORK}"
mkdir -p "${WORK}"
git -C "${WORK}" init -q
git -C "${WORK}" remote add origin https://github.com/YouROK/TorrServer.git
git -C "${WORK}" fetch -q --depth 1 origin "${TORRSERVER_COMMIT}"
git -C "${WORK}" checkout -q FETCH_HEAD

cd "${WORK}"
IOS_VERSION_MIN="${IOS_VERSION_MIN}" ./build-ios.sh

mkdir -p "${ROOT}/Frameworks"
rm -rf "${OUT}"
cp -R "${WORK}/dist/TorrServerKit.xcframework" "${OUT}"
echo "Built ${OUT}"
