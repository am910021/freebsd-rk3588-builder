#!/bin/sh

set -eu

BUILDER_ROOT=${BUILDER_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}
BUILDER_CONFIG=${BUILDER_CONFIG:-${BUILDER_ROOT}/builder.conf}
[ -r "${BUILDER_CONFIG}" ] || {
	echo "${0##*/}: missing config: ${BUILDER_CONFIG}" >&2
	exit 1
}
. "${BUILDER_CONFIG}"

die()
{
	echo "${0##*/}: $*" >&2
	exit 1
}

[ -n "${PORT_ORIGINS}" ] || die "PORT_ORIGINS is empty"
[ -d "${FREEBSD_SRC_DIR}/sys" ] ||
	die "missing FreeBSD source: ${FREEBSD_SRC_DIR}"
[ -f "${KERNBUILDDIR}/opt_global.h" ] ||
	die "missing kernel build directory: ${KERNBUILDDIR}"
[ -f "${FREEBSD_OBJ}/tmp/usr/include/sys/param.h" ] ||
	die "missing arm64 sysroot: ${FREEBSD_OBJ}/tmp"
[ -x "${FREEBSD_OBJ}/bin/sh/sh" ] ||
	die "missing target ABI executable: ${FREEBSD_OBJ}/bin/sh/sh"
[ -z "$(git -C "${PORTS_SRC_DIR}" status --porcelain)" ] ||
	die "ports source has uncommitted changes"

for cmd in make git pkg sha256 readelf tr date cc c++ cpp; do
	command -v "${cmd}" >/dev/null 2>&1 || die "missing command: ${cmd}"
done
host_pkg=$(command -v pkg-static) || die "missing command: pkg-static"

osversion=$(awk '
    $1 == "#define" && $2 == "__FreeBSD_version" { print $3; exit }
' "${FREEBSD_SRC_DIR}/sys/sys/param.h")
[ -n "${osversion}" ] || die "cannot determine target OSVERSION"
cross_target=aarch64-unknown-freebsd${FREEBSD_OBJ_VERSION%%-*}
target_sysroot=${FREEBSD_OBJ}/tmp

ports_work=${WORK_ROOT}/ports
if [ -e "${ports_work}" ]; then
	archive=${BUILDER_ROOT}/ready-to-delete/ports-$(date +%Y%m%d-%H%M%S)-$$
	mkdir -p "${archive}"
	mv "${ports_work}" "${archive}/"
fi
mkdir -p "${ports_work}" "${TXZ_ROOT}"

for origin in ${PORT_ORIGINS}; do
	port_dir=${PORTS_SRC_DIR}/${origin}
	[ -f "${port_dir}/Makefile" ] || die "missing port: ${origin}"
	slug=$(printf '%s\n' "${origin}" | tr / _)
	port_work=${ports_work}/${slug}

	echo "== Building ${origin} =="
	env MAKEOBJDIRPREFIX="${FREEBSD_OBJ_ROOT}" \
	    MACHINE=arm64 MACHINE_ARCH=aarch64 \
	    TARGET=arm64 TARGET_ARCH=aarch64 ARCH=aarch64 \
	    OSVERSION="${osversion}" \
	    make -C "${port_dir}" -DBATCH \
	    ALLOW_UNSUPPORTED_SYSTEM=yes \
	    CC="cc --target=${cross_target} --sysroot=${target_sysroot}" \
	    CXX="c++ --target=${cross_target} --sysroot=${target_sysroot}" \
	    CPP="cpp --target=${cross_target} --sysroot=${target_sysroot}" \
	    SRC_BASE="${FREEBSD_SRC_DIR}" \
	    KERNBUILDDIR="${KERNBUILDDIR}" \
	    WRKDIR="${port_work}" \
	    PKG_BIN="${host_pkg}" \
	    "PKG_ENV+=ABI_FILE=${FREEBSD_OBJ}/bin/sh/sh" \
	    stage check-plist package

	for module in "${port_work}"/stage/boot/modules/*.ko; do
		[ -f "${module}" ] || continue
		readelf -h "${module}" | grep -q 'Machine:.*AArch64' ||
		    die "module is not AArch64: ${module}"
	done

	found=0
	for package in "${port_work}"/pkg/*.pkg; do
		[ -f "${package}" ] || continue
		found=1
		pkg_origin=$(pkg query -F "${package}" '%o')
		pkg_abi=$(pkg query -F "${package}" '%q')
		pkg_name=$(pkg query -F "${package}" '%n')
		[ "${pkg_origin}" = "${origin}" ] ||
		    die "unexpected package origin: ${pkg_origin}"
		case "${pkg_abi}" in
		"FreeBSD:${FREEBSD_OBJ_VERSION%%.*}:aarch64" | \
		"FreeBSD:${FREEBSD_OBJ_VERSION%%.*}:*") ;;
		*) die "unexpected package ABI: ${pkg_abi}" ;;
		esac

		output_package=${TXZ_ROOT}/${package##*/}
		for existing in "${TXZ_ROOT}"/*.pkg; do
			[ -f "${existing}" ] || continue
			existing_name=$(pkg query -F "${existing}" '%n' 2>/dev/null ||
			    true)
			[ "${existing_name}" = "${pkg_name}" ] || continue
			archive=${BUILDER_ROOT}/ready-to-delete/ports-output-$(date +%Y%m%d-%H%M%S)-$$
			mkdir -p "${archive}"
			mv "${existing}" "${archive}/"
			if [ -e "${existing}.sha256" ]; then
				mv "${existing}.sha256" "${archive}/"
			fi
		done
		cp -p "${package}" "${output_package}"
		sha256 "${output_package}" > "${output_package}.sha256"
		echo "Package: ${output_package}"
	done
	[ "${found}" = "1" ] || die "no package produced for ${origin}"
done

rtlbt_fetch=${ports_work}/rtlbt-firmware-fetch
mkdir -p "${rtlbt_fetch}"
pkg fetch -y -o "${rtlbt_fetch}" rtlbt-firmware
set -- $(find "${rtlbt_fetch}" -type f -name 'rtlbt-firmware-*.pkg')
[ "$#" -eq 1 ] || die "expected one fetched rtlbt-firmware package"
package=$1
pkg_origin=$(pkg query -F "${package}" '%o')
pkg_abi=$(pkg query -F "${package}" '%q')
pkg_version=$(pkg query -F "${package}" '%v')
[ "${pkg_origin}" = "comms/rtlbt-firmware" ] ||
	die "unexpected rtlbt-firmware origin: ${pkg_origin}"
[ "${pkg_abi}" = "FreeBSD:${FREEBSD_OBJ_VERSION%%.*}:*" ] ||
	die "unexpected rtlbt-firmware ABI: ${pkg_abi}"
for existing in "${TXZ_ROOT}"/rtlbt-firmware-*.pkg; do
	[ -f "${existing}" ] || continue
	archive=${BUILDER_ROOT}/ready-to-delete/ports-output-$(date +%Y%m%d-%H%M%S)-$$
	mkdir -p "${archive}"
	mv "${existing}" "${archive}/"
	[ ! -e "${existing}.sha256" ] || mv "${existing}.sha256" "${archive}/"
done
output_package=${TXZ_ROOT}/rtlbt-firmware-${pkg_version}.pkg
cp -p "${package}" "${output_package}"
sha256 "${output_package}" > "${output_package}.sha256"
echo "Package: ${output_package}"
