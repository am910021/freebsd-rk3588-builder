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
[ -x "${TOOLBIN}/cc" ] || die "missing arm64 toolchain: ${TOOLBIN}"
[ -x "${FREEBSD_OBJ}/bin/sh/sh" ] ||
	die "missing target ABI executable: ${FREEBSD_OBJ}/bin/sh/sh"
[ -z "$(git -C "${PORTS_SRC_DIR}" status --porcelain)" ] ||
	die "ports source has uncommitted changes"

for cmd in make git pkg sha256 readelf tr date; do
	command -v "${cmd}" >/dev/null 2>&1 || die "missing command: ${cmd}"
done

osversion=$(awk '
    $1 == "#define" && $2 == "__FreeBSD_version" { print $3; exit }
' "${FREEBSD_SRC_DIR}/sys/sys/param.h")
[ -n "${osversion}" ] || die "cannot determine target OSVERSION"

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
	    PATH="${TOOLBIN}:${PATH}" \
	    make -C "${port_dir}" -DBATCH \
	    ALLOW_UNSUPPORTED_SYSTEM=yes \
	    SRC_BASE="${FREEBSD_SRC_DIR}" \
	    KERNBUILDDIR="${KERNBUILDDIR}" \
	    WRKDIR="${port_work}" \
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
