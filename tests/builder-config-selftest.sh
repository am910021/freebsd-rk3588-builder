#!/bin/sh

set -eu

BUILDER_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

if grep -Eq '^[[:space:]]*(if|then|else|elif|fi|case|esac|for|while|until|[A-Za-z_][A-Za-z0-9_]*\(\))([[:space:]]|$)' \
    "${BUILDER_ROOT}/builder.conf" || grep -q '\$(' "${BUILDER_ROOT}/builder.conf"; then
	echo "builder.conf must contain settings only" >&2
	exit 1
fi

# check_board BOARD ZFS_POOL KERNCONF
# Input example: check_board g98 g98 RK3588-NORE
# Output: returns success when the common loader derives the expected settings.
check_board()
{
	board=$1
	pool=$2
	kernconf=$3
	env -i PATH="${PATH}" BUILDER_ROOT="${BUILDER_ROOT}" BOARD="${board}" \
	    EXPECTED_POOL="${pool}" EXPECTED_KERNCONF="${kernconf}" sh -c '
		. "${BUILDER_ROOT}/lib/builder-common.sh"
		builder_load_configuration
		test "${ZFS_POOL_NAME}" = "${EXPECTED_POOL}"
		test "${INSTALLER_ZFS_POOL_NAME}" = "${BOARD}_installer"
		test "${FREEBSD_KERNCONF}" = "${EXPECTED_KERNCONF}"
		test -n "${FREEBSD_OBJ_VERSION}"
		test -n "${FREEBSD_SRC_COMMIT}"
		test "${VERSION_OUTPUT_ROOT}" = "${OUTPUT_ROOT}/${FREEBSD_OBJ_VERSION}"
		test "${UBOOT_OUTPUT_DIR}" = "${VERSION_OUTPUT_ROOT}/uboot-${UBOOT_VERSION}/${FIRMWARE_MIB}m/${BOARD}"
	'
}

check_board g98 g98 RK3588-NORE
check_board nanopc-t6-lts nanopc_t6 RK3588-NORE

echo "builder configuration selftest passed"
