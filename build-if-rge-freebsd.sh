#!/bin/sh

set -eu

BUILDER_ROOT=${BUILDER_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}
BUILDER_CONFIG=${BUILDER_CONFIG:-${BUILDER_ROOT}/builder.conf}
[ -r "${BUILDER_CONFIG}" ] || {
	echo "${0##*/}: missing config: ${BUILDER_CONFIG}" >&2
	exit 1
}
. "${BUILDER_CONFIG}"

OUTPUT_DIR=${OUTPUT_DIR:-${RGE_OUTPUT_DIR}}
OBJ_ROOT=${OBJ_ROOT:-${RGE_OBJ_ROOT}}

die()
{
	echo "${0##*/}: $*" >&2
	exit 1
}

[ -f "${RGE_DIR}/src/Makefile" ] || die "missing if_rge source: ${RGE_DIR}"
[ -d "${FREEBSD_SRC}/sys" ] || die "missing FreeBSD source: ${FREEBSD_SRC}"
[ -f "${KERNBUILDDIR}/opt_global.h" ] ||
	die "missing kernel build directory: ${KERNBUILDDIR}"
[ -x "${TOOLBIN}/cc" ] || die "missing arm64 toolchain: ${TOOLBIN}"
[ -z "$(git -C "${RGE_DIR}" status --porcelain)" ] ||
	die "if_rge source has uncommitted changes"

for cmd in make git tar sha256 readelf mktemp; do
	command -v "${cmd}" >/dev/null 2>&1 || die "missing command: ${cmd}"
done

commit=$(git -C "${RGE_DIR}" rev-parse --short HEAD)
package=${OUTPUT_DIR}/if_rge-${commit}-freebsd14.3-arm64.txz
work=$(mktemp -d "${TMPDIR:-/tmp}/if-rge-package.XXXXXX")
trap 'rm -rf "${work}"' EXIT INT TERM

mkdir -p "${OUTPUT_DIR}" "${OBJ_ROOT}" "${work}/boot/modules"

build_make()
{
	env MAKEOBJDIRPREFIX="${OBJ_ROOT}" \
	    MACHINE=arm64 MACHINE_ARCH=aarch64 \
	    TARGET=arm64 TARGET_ARCH=aarch64 \
	    PATH="${TOOLBIN}:${PATH}" \
	    make -C "${RGE_DIR}/src" SYSDIR="${FREEBSD_SRC}/sys" \
	    KERNBUILDDIR="${KERNBUILDDIR}" "$@"
}

build_make obj
build_make clean all
objdir=$(build_make -V .OBJDIR)
module=${objdir}/if_rge.ko

[ -f "${module}" ] || die "build did not produce ${module}"
readelf -h "${module}" | grep -q 'Machine:.*AArch64' ||
	die "module is not AArch64"

cp -p "${module}" "${OUTPUT_DIR}/if_rge.ko"
cp -p "${module}" "${work}/boot/modules/if_rge.ko"
tar -cJf "${package}" -C "${work}" boot/modules/if_rge.ko
ln -sfn "${package##*/}" "${OUTPUT_DIR}/if_rge.txz"

sha256 "${OUTPUT_DIR}/if_rge.ko" "${package}" > "${package}.sha256"

echo "if_rge module:  ${OUTPUT_DIR}/if_rge.ko"
echo "if_rge package: ${package}"
