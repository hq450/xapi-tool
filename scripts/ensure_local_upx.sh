#!/bin/sh

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
BASE_DIR="${ROOT_DIR}/.upx-cache"
UPX_VERSION="${UPX_VERSION:-5.0.2}"
OS_NAME="$(uname -s | tr 'A-Z' 'a-z')"
ARCH_NAME="$(uname -m)"
UPX_ARCH=""
UPX_DIR=""
UPX_BIN=""
UPX_TARBALL=""

case "${OS_NAME}" in
linux)
	;;
*)
	echo "unsupported host OS: ${OS_NAME}" >&2
	exit 1
	;;
esac

case "${ARCH_NAME}" in
x86_64|amd64)
	UPX_ARCH="amd64"
	;;
aarch64|arm64)
	UPX_ARCH="arm64"
	;;
*)
	echo "unsupported host arch: ${ARCH_NAME}" >&2
	exit 1
	;;
esac

mkdir -p "${BASE_DIR}"
UPX_DIR="${BASE_DIR}/upx-${UPX_VERSION}-${UPX_ARCH}_${OS_NAME}"
UPX_BIN="${UPX_DIR}/upx"
UPX_TARBALL="${BASE_DIR}/upx-${UPX_VERSION}-${UPX_ARCH}_${OS_NAME}.tar.xz"

if [ ! -x "${UPX_BIN}" ]; then
	if [ ! -f "${UPX_TARBALL}" ]; then
		curl -fsSL --connect-timeout 20 --retry 3 --retry-delay 1 \
			"https://github.com/upx/upx/releases/download/v${UPX_VERSION}/upx-${UPX_VERSION}-${UPX_ARCH}_${OS_NAME}.tar.xz" \
			-o "${UPX_TARBALL}"
	fi
	rm -rf "${UPX_DIR}"
	tar -C "${BASE_DIR}" -xf "${UPX_TARBALL}"
fi

printf '%s\n' "${UPX_BIN}"
