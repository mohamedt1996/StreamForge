#!/bin/bash
# Builds torrserverkit.aar (TorrServer's Go engine via gomobile) for the Android app.
# Requires Go, Node/Yarn (for TorrServer's web UI embed) and an Android NDK (ANDROID_NDK_HOME).
set -euo pipefail

TORRSERVER_COMMIT="${TORRSERVER_COMMIT:-98cdbacaddfac278a21a4a4d6424bd3a9dcd407f}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${ROOT}/.build/torrserver-android"
OUT="${ROOT}/android/app/libs/torrserverkit.aar"

rm -rf "${WORK}"
mkdir -p "${WORK}" "$(dirname "${OUT}")"
git -C "${WORK}" init -q
git -C "${WORK}" remote add origin https://github.com/YouROK/TorrServer.git
git -C "${WORK}" fetch -q --depth 1 origin "${TORRSERVER_COMMIT}"
git -C "${WORK}" checkout -q FETCH_HEAD

cd "${WORK}"
export NODE_OPTIONS="${NODE_OPTIONS:---openssl-legacy-provider}"
go run gen_web.go

cd "${WORK}/server"
go install github.com/swaggo/swag/cmd/swag@latest
"$(go env GOPATH)/bin/swag" init -g web/server.go --parseInternal --parseDepth 5

go install golang.org/x/mobile/cmd/gomobile@latest
go install golang.org/x/mobile/cmd/gobind@latest
export PATH="$(go env GOPATH)/bin:${PATH}"
gomobile init

cd "${WORK}/server/mobile/torrserverkit"
go mod tidy
gomobile bind \
  -target=android/arm64,android/arm,android/amd64 \
  -androidapi 26 \
  -tags=nosqlite \
  -ldflags="-s -w -checklinkname=0" \
  -trimpath \
  -o "${OUT}" \
  .
ls -lh "${OUT}"
