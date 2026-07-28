#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="HeicDrop"
BUNDLE="${APP_NAME}.app"
DEPLOYMENT_TARGET="13.0"
ARCH="$(uname -m)"

echo "==> Compiling ${APP_NAME} (target ${ARCH}-apple-macos${DEPLOYMENT_TARGET})"
swiftc -O \
	-target "${ARCH}-apple-macos${DEPLOYMENT_TARGET}" \
	main.swift \
	-o "${APP_NAME}"

echo "==> Assembling ${BUNDLE}"
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS"
cp "${APP_NAME}" "${BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Info.plist "${BUNDLE}/Contents/Info.plist"

echo "==> Ad-hoc signing"
codesign --force -s - "${BUNDLE}"

echo "==> Done: $(pwd)/${BUNDLE}"
echo "    CLI test mode: ${BUNDLE}/Contents/MacOS/${APP_NAME} --convert <input> --out <dir>"
