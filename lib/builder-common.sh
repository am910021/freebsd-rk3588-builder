#!/bin/sh

# builder_load_configuration
# Input: optional BUILDER_ROOT, BUILDER_CONFIG and BOARD environment variables.
# Input example: BOARD=g98 BUILDER_ROOT=/root/freebsd-rk3588-builder
# Output: loads shared/board settings and initializes all derived path variables.
# Output example: FREEBSD_OBJ_VERSION=14.3-p16 and FREEBSD_KERNCONF=RK3588-NORE
builder_load_configuration()
{
	BUILDER_ROOT=${BUILDER_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}
	BUILDER_CONFIG=${BUILDER_CONFIG:-${BUILDER_ROOT}/builder.conf}
	[ -r "${BUILDER_CONFIG}" ] || {
		echo "${0##*/}: missing config: ${BUILDER_CONFIG}" >&2
		return 1
	}
	. "${BUILDER_CONFIG}"

	if [ -n "${BOARD}" ]; then
		BOARD_DIR=${BOARD_DIR:-${BUILDER_ROOT}/boards/${BOARD}}
		BOARD_CONFIG=${BOARD_CONFIG:-${BOARD_DIR}/board.conf}
		[ -r "${BOARD_CONFIG}" ] || {
			echo "${0##*/}: missing board config: ${BOARD_CONFIG}" >&2
			return 1
		}
		. "${BOARD_CONFIG}"
		BOARD_FILES_DIR=${BOARD_FILES_DIR:-${BOARD_DIR}/files}
		BOARD_HOOKS=${BOARD_HOOKS:-${BOARD_DIR}/hooks.sh}
		[ ! -r "${BOARD_HOOKS}" ] || . "${BOARD_HOOKS}"
	fi

	builder_derive_defaults
}

# builder_derive_defaults
# Input: variables loaded from builder.conf and the optional board.conf.
# Input example: FREEBSD_SRC_DIR=<builder>/src/freebsd-src BOARD=g98
# Output: fills unset version, output, object, package and artifact paths.
# Output example: TXZ_ROOT=<builder>/output/14.3-p16/sets
builder_derive_defaults()
{
	if [ -z "${FREEBSD_OBJ_VERSION}" ]; then
		freebsd_newvers=${FREEBSD_SRC_DIR}/sys/conf/newvers.sh
		if [ -r "${freebsd_newvers}" ]; then
			eval "$(sh "${freebsd_newvers}" -V REVISION -V BRANCH)"
			FREEBSD_OBJ_VERSION=${REVISION}-${BRANCH#RELEASE-}
			unset REVISION BRANCH
		fi
	fi
	unset freebsd_newvers
	FREEBSD_OBJ_VERSION=${FREEBSD_OBJ_VERSION:-unversioned}

	if [ -z "${FREEBSD_SRC_COMMIT}" ]; then
		FREEBSD_SRC_COMMIT=$(git -C "${FREEBSD_SRC_DIR}" \
		    rev-parse --short=12 HEAD 2>/dev/null || true)
	fi
	FREEBSD_SRC_COMMIT=${FREEBSD_SRC_COMMIT:-unknown}

	PORT_ORIGINS=${PORT_ORIGINS:-"ports-mgmt/pkg sysutils/rk3588-installer sysutils/rk3588-uboot-tools"}
	FREEBSD_KERNCONF=${FREEBSD_KERNCONF:-GENERIC}
	VERSION_OUTPUT_ROOT=${VERSION_OUTPUT_ROOT:-${OUTPUT_ROOT}/${FREEBSD_OBJ_VERSION}}
	TXZ_ROOT=${TXZ_ROOT:-${VERSION_OUTPUT_ROOT}/sets}
	PORTS_OUTPUT_DIR=${PORTS_OUTPUT_DIR:-${VERSION_OUTPUT_ROOT}/ports}
	BOARD_PORTS_OUTPUT_DIR=${BOARD_PORTS_OUTPUT_DIR:-${PORTS_OUTPUT_DIR}/${BOARD}}
	IMAGE_OUTPUT_DIR=${IMAGE_OUTPUT_DIR:-${VERSION_OUTPUT_ROOT}/images}
	PORTS_SHARED_ORIGINS="${PORTS_SHARED_ORIGINS} ${BOARD_SHARED_PORT_ORIGINS:-}"
	FREEBSD_OBJ_ROOT=${FREEBSD_OBJ_ROOT:-${WORK_ROOT}/obj/${FREEBSD_OBJ_VERSION}}
	FREEBSD_OBJ=${FREEBSD_OBJ:-${FREEBSD_OBJ_ROOT}/arm64.aarch64}
	KERNBUILDDIR=${KERNBUILDDIR:-${FREEBSD_OBJ}/sys/${FREEBSD_KERNCONF}}
	UBOOT_OUTPUT_DIR=${UBOOT_OUTPUT_DIR:-${VERSION_OUTPUT_ROOT}/uboot-${UBOOT_VERSION}/${FIRMWARE_MIB}m/${BOARD}}
	JOBS=${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}
	BASE_TXZ=${BASE_TXZ:-${TXZ_ROOT}/base-${FREEBSD_OBJ_VERSION}_${FREEBSD_SRC_COMMIT}.txz}
	BASE_LIVE_TXZ=${BASE_LIVE_TXZ:-${TXZ_ROOT}/base-live-${FREEBSD_OBJ_VERSION}_${FREEBSD_SRC_COMMIT}.txz}
	KERNEL_TXZ=${KERNEL_TXZ:-${TXZ_ROOT}/kernel-${FREEBSD_OBJ_VERSION}_${FREEBSD_SRC_COMMIT}.txz}
	UBOOT_DIR=${UBOOT_DIR:-${UBOOT_OUTPUT_DIR}}
	FREEBSD_DTB=${FREEBSD_DTB:-${UBOOT_DIR}/freebsd-runtime.dtb}
	IMAGE_LOGO_BMP=${IMAGE_LOGO_BMP:-${UBOOT_DIR}/logo.bmp}
}

# run_board_hook NAME [ARG ...]
# Input: hook function name "$1" and optional hook arguments.
# Input example: run_board_hook board_image_add_packages
# Output: runs the board hook, or succeeds without output when it is absent.
# Output example: board package globals populated by board_image_add_packages
run_board_hook()
{
	rk_builder_hook=$1
	shift
	command -v "${rk_builder_hook}" >/dev/null 2>&1 || return 0
	"${rk_builder_hook}" "$@"
}
