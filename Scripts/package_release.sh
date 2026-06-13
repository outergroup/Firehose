#!/bin/bash

set -euo pipefail
export COPYFILE_DISABLE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-${REPO_ROOT}/build/frontend}"
PACKAGE_ROOT="${PACKAGE_ROOT:-${REPO_ROOT}/build/linux-package}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${REPO_ROOT}/build/release}"
CONFIGURATION="${CONFIGURATION:-Release}"

require_file() {
    if [[ ! -f "$1" ]]; then
        echo "error: missing $1" >&2
        exit 1
    fi
}

require_file "${PACKAGE_ROOT}/RemoteLinuxBinaries/aarch64/FirehoseBackend"
require_file "${PACKAGE_ROOT}/RemoteLinuxBinaries/x86_64/FirehoseBackend"
require_file "${REPO_ROOT}/app-icon.png"

mkdir -p "${OUTPUT_ROOT}" "${PACKAGE_ROOT}/bundles"

echo "==> Building Firehose frontend"
/usr/bin/xcodebuild \
    -project "${REPO_ROOT}/Trace.xcodeproj" \
    -scheme Trace \
    -configuration "${CONFIGURATION}" \
    SYMROOT="${BUILD_ROOT}" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build

echo "==> Archiving FirehoseContent bundles"
"${REPO_ROOT}/Scripts/archive_trace_bundle.sh" \
    "${BUILD_ROOT}/${CONFIGURATION}/Trace.bundle" \
    "${PACKAGE_ROOT}/bundles" \
    FirehoseContent.bundle

STAGING_ROOT="$(mktemp -d)"
trap 'rm -rf "${STAGING_ROOT}"' EXIT

APP_ROOT="${STAGING_ROOT}/Firehose"
mkdir -p \
    "${APP_ROOT}/RemoteLinuxBinaries/aarch64" \
    "${APP_ROOT}/RemoteLinuxBinaries/x86_64" \
    "${APP_ROOT}/bundles"

install -m 0755 "${PACKAGE_ROOT}/RemoteLinuxBinaries/aarch64/FirehoseBackend" "${APP_ROOT}/RemoteLinuxBinaries/aarch64/FirehoseBackend"
install -m 0755 "${PACKAGE_ROOT}/RemoteLinuxBinaries/x86_64/FirehoseBackend" "${APP_ROOT}/RemoteLinuxBinaries/x86_64/FirehoseBackend"
install -m 0644 "${PACKAGE_ROOT}/bundles/FirehoseContent.bundle.macos-arm.aar" "${APP_ROOT}/bundles/FirehoseContent.bundle.macos-arm.aar"
install -m 0644 "${PACKAGE_ROOT}/bundles/FirehoseContent.bundle.macos-x86.aar" "${APP_ROOT}/bundles/FirehoseContent.bundle.macos-x86.aar"
install -m 0644 "${REPO_ROOT}/app-icon.png" "${APP_ROOT}/app-icon.png"

tar --format ustar --no-xattrs -C "${STAGING_ROOT}" -czf "${OUTPUT_ROOT}/Firehose.tar.gz" Firehose
echo "Packaged ${OUTPUT_ROOT}/Firehose.tar.gz"
