#!/bin/sh

set -eu

BUILDER_ROOT=${BUILDER_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}
BUILDER_CONFIG=${BUILDER_CONFIG:-${BUILDER_ROOT}/builder.conf}
[ -r "${BUILDER_CONFIG}" ] || {
	echo "${0##*/}: missing config: ${BUILDER_CONFIG}" >&2
	exit 1
}
. "${BUILDER_CONFIG}"

OUTPUT_DIR=${OUTPUT_DIR:-${RGE_WORK_DIR}}

die()
{
	echo "${0##*/}: $*" >&2
	exit 1
}

[ -f "${IF_RGE_SRC_DIR}/src/Makefile" ] ||
	die "missing if_rge source: ${IF_RGE_SRC_DIR}"
[ -f "${RGE_PORT_DIR}/Makefile" ] ||
	die "missing if_rge port: ${RGE_PORT_DIR}"
[ -d "${FREEBSD_SRC_DIR}/sys" ] ||
	die "missing FreeBSD source: ${FREEBSD_SRC_DIR}"
[ -f "${KERNBUILDDIR}/opt_global.h" ] ||
	die "missing kernel build directory: ${KERNBUILDDIR}"
[ -x "${TOOLBIN}/cc" ] || die "missing arm64 toolchain: ${TOOLBIN}"
[ -x "${FREEBSD_OBJ}/bin/sh/sh" ] ||
	die "missing target ABI executable: ${FREEBSD_OBJ}/bin/sh/sh"
[ -z "$(git -C "${IF_RGE_SRC_DIR}" status --porcelain)" ] ||
	die "if_rge source has uncommitted changes"

for cmd in make git pkg sha256 readelf mktemp; do
	command -v "${cmd}" >/dev/null 2>&1 || die "missing command: ${cmd}"
done

commit=$(git -C "${IF_RGE_SRC_DIR}" rev-parse HEAD)
port_commit=$(make -C "${RGE_PORT_DIR}" ALLOW_UNSUPPORTED_SYSTEM=yes \
    -V GH_TAGNAME)
[ "${commit}" = "${port_commit}" ] ||
	die "if_rge source ${commit} does not match port ${port_commit}"
osversion=$(awk '
    $1 == "#define" && $2 == "__FreeBSD_version" { print $3; exit }
' "${FREEBSD_SRC_DIR}/sys/sys/param.h")
[ -n "${osversion}" ] || die "cannot determine target OSVERSION"

mkdir -p "${OUTPUT_DIR}" "${TXZ_ROOT}" "${WORK_ROOT}/tmp"
work=$(mktemp -d "${WORK_ROOT}/tmp/if-rge-package.XXXXXX")
trap 'rm -rf "${work}"' EXIT INT TERM

env MAKEOBJDIRPREFIX="${FREEBSD_OBJ_ROOT}" \
    MACHINE=arm64 MACHINE_ARCH=aarch64 \
    TARGET=arm64 TARGET_ARCH=aarch64 ARCH=aarch64 \
    OSVERSION="${osversion}" \
    PATH="${TOOLBIN}:${PATH}" \
    make -C "${RGE_PORT_DIR}" -DBATCH \
    ALLOW_UNSUPPORTED_SYSTEM=yes \
    SRC_BASE="${FREEBSD_SRC_DIR}" \
    KERNBUILDDIR="${KERNBUILDDIR}" \
    WRKDIR="${work}/port" \
    "PKG_ENV+=ABI_FILE=${FREEBSD_OBJ}/bin/sh/sh" \
    stage check-plist package

module=${work}/port/stage/boot/modules/if_rge.ko
package=
for candidate in "${work}"/port/pkg/realtek-rge-kmod-*.pkg; do
	[ -f "${candidate}" ] || continue
	[ -z "${package}" ] || die "multiple if_rge packages produced"
	package=${candidate}
done

[ -f "${module}" ] || die "build did not produce ${module}"
[ -n "${package}" ] || die "build did not produce an if_rge package"
readelf -h "${module}" | grep -q 'Machine:.*AArch64' ||
	die "module is not AArch64"
metadata=$(pkg query -F "${package}" '%n|%o|%q')
[ "${metadata}" = "realtek-rge-kmod|net/realtek-rge-kmod|FreeBSD:${FREEBSD_OBJ_VERSION%%.*}:aarch64" ] ||
	die "unexpected package metadata: ${metadata}"

cp -p "${module}" "${OUTPUT_DIR}/if_rge.ko"
output_package=${TXZ_ROOT}/${package##*/}
cp -p "${package}" "${output_package}"
ln -sfn "${output_package##*/}" "${TXZ_ROOT}/if_rge.pkg"

sha256 "${OUTPUT_DIR}/if_rge.ko" "${output_package}" \
    > "${output_package}.sha256"

echo "if_rge module:  ${OUTPUT_DIR}/if_rge.ko"
echo "if_rge package: ${output_package}"
