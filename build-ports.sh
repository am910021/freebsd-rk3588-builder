#!/bin/sh

set -eu

# die MESSAGE
# Input: error text in "$*"; no required global variables.
# Input example: die "PORT_ORIGINS is empty"
# Output: writes "<script>: MESSAGE" to stderr and exits with status 1.
# Output example: build-ports.sh: PORT_ORIGINS is empty
die()
{
	echo "${0##*/}: $*" >&2
	exit 1
}

# load_configuration
# Input: optional BUILDER_ROOT and BUILDER_CONFIG environment variables.
# Input example: BOARD=g98 BUILDER_CONFIG=/root/freebsd-rk3588-builder/builder.conf
# Output: loads builder.conf and the selected board configuration into globals.
# Output example: PORT_ORIGINS="ports-mgmt/pkg net/realtek-rge-kmod ..."
load_configuration()
{
	BUILDER_ROOT=${BUILDER_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}
	BUILDER_CONFIG=${BUILDER_CONFIG:-${BUILDER_ROOT}/builder.conf}
	[ -r "${BUILDER_CONFIG}" ] ||
		die "missing config: ${BUILDER_CONFIG}"

	# Load the shared and board-specific build settings.
	. "${BUILDER_CONFIG}"
}

# validate_environment
# Input: source/object/package globals loaded from builder.conf.
# Input example: FREEBSD_OBJ=/root/freebsd-rk3588-builder/work/obj/14.3-p16/arm64.aarch64
# Output: validates prerequisites and sets host_pkg, osversion, cross_target and target_sysroot.
# Output example: cross_target=aarch64-unknown-freebsd14.3
validate_environment()
{
	# Validate the target source, object tree, sysroot and ABI probe.
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

	# Check every host command before changing the output workspace.
	for cmd in make git pkg sha256 readelf tr date cc c++ cpp; do
		command -v "${cmd}" >/dev/null 2>&1 ||
			die "missing command: ${cmd}"
	done
	host_pkg=$(command -v pkg-static) ||
		die "missing command: pkg-static"

	# Derive the target ABI values from the selected FreeBSD source/object tree.
	osversion=$(awk '
	    $1 == "#define" && $2 == "__FreeBSD_version" { print $3; exit }
	' "${FREEBSD_SRC_DIR}/sys/sys/param.h")
	[ -n "${osversion}" ] || die "cannot determine target OSVERSION"
	cross_target=aarch64-unknown-freebsd${FREEBSD_OBJ_VERSION%%-*}
	target_sysroot=${FREEBSD_OBJ}/tmp
}

# prepare_workspace
# Input: global WORK_ROOT, BUILDER_ROOT and Ports output directories.
# Input example: WORK_ROOT=/root/freebsd-rk3588-builder/work
# Output: archives an old ports work tree and sets global ports_work.
# Output example: ports_work=/root/freebsd-rk3588-builder/work/ports
prepare_workspace()
{
	ports_work=${WORK_ROOT}/ports
	if [ -e "${ports_work}" ]; then
		archive=${BUILDER_ROOT}/ready-to-delete/ports-$(date +%Y%m%d-%H%M%S)-$$
		mkdir -p "${archive}"
		mv "${ports_work}" "${archive}/"
	fi

	# Create clean work and package output roots for this run.
	mkdir -p "${ports_work}" "${PORTS_OUTPUT_DIR}"
}

# collect_board_patches ORIGIN
# Input: Port origin in "$1" and global BOARD_DIR.
# Input example: collect_board_patches net/motorcomm-yt921x-kmod
# Output: prints a space-separated list of existing board patch paths.
# Output example: /root/freebsd-rk3588-builder/boards/g98/ports/net/.../patch-led
collect_board_patches()
{
	origin=$1
	board_patches=
	for patch in "${BOARD_DIR}/ports/${origin}/files"/patch-*; do
		[ -f "${patch}" ] || continue
		board_patches="${board_patches} ${patch}"
	done
	printf '%s\n' "${board_patches# }"
}

# run_port_build ORIGIN PORT_DIR PORT_WORK BOARD_PATCHES
# Input: origin "$1", source directory "$2", work directory "$3", patches "$4".
# Input example: run_port_build net/realtek-rge-kmod /src/ports/net/... \
#   /work/ports/net_realtek-rge-kmod ""
# Output: stages, plist-checks and packages the target AArch64 Port.
# Output example: package files under <PORT_WORK>/pkg/
run_port_build()
{
	origin=$1
	port_dir=$2
	port_work=$3
	board_patches=$4

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
	    EXTRA_PATCHES="${board_patches}" \
	    WRKDIR="${port_work}" \
	    PKG_BIN="${host_pkg}" \
	    "PKG_ENV+=ABI_FILE=${FREEBSD_OBJ}/bin/sh/sh" \
	    stage check-plist package
}

# validate_port_modules PORT_WORK
# Input: staged Port work directory in "$1".
# Input example: validate_port_modules /work/ports/net_realtek-rge-kmod
# Output: returns 0 when every staged .ko reports AArch64 machine type.
# Output example: no stdout and status 0
validate_port_modules()
{
	port_work=$1
	for module in "${port_work}"/stage/boot/modules/*.ko; do
		[ -f "${module}" ] || continue
		readelf -h "${module}" | grep -q 'Machine:.*AArch64' ||
			die "module is not AArch64: ${module}"
	done
}

# archive_package PACKAGE
# Input: existing output package path in "$1" and global BUILDER_ROOT.
# Input example: archive_package /work/txz/realtek-rge-kmod-1.0.pkg
# Output: moves the package and optional checksum into a timestamped archive.
# Output example: ready-to-delete/ports-output-<timestamp>-<pid>/
archive_package()
{
	existing=$1
	archive=${BUILDER_ROOT}/ready-to-delete/ports-output-$(date +%Y%m%d-%H%M%S)-$$
	mkdir -p "${archive}"
	mv "${existing}" "${archive}/"
	[ ! -e "${existing}.sha256" ] ||
		mv "${existing}.sha256" "${archive}/"
}

# publish_port_packages ORIGIN PORT_WORK
# Input: expected origin "$1", Port work directory "$2", plus target ABI globals.
# Input example: publish_port_packages net/realtek-rge-kmod /work/ports/net_realtek-rge-kmod
# Output: validates and copies packages plus SHA-256 files into shared or board output.
# Output example: Package: /output/14.3-p16/ports/g98/realtek-rge-kmod-<version>.pkg
publish_port_packages()
{
	origin=$1
	port_work=$2
	case " ${PORTS_SHARED_ORIGINS} " in
	*" ${origin} "*) package_output_dir=${PORTS_OUTPUT_DIR} ;;
	*)
		[ -n "${BOARD}" ] ||
		    die "BOARD is required for board-specific Port: ${origin}"
		package_output_dir=${BOARD_PORTS_OUTPUT_DIR}
		;;
	esac
	mkdir -p "${package_output_dir}"
	found=0
	for package in "${port_work}"/pkg/*.pkg; do
		[ -f "${package}" ] || continue
		found=1

		# Verify package provenance and target ABI before publishing.
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

		# Retire an older package with the same package name.
		output_package=${package_output_dir}/${package##*/}
		for existing in "${package_output_dir}"/*.pkg; do
			[ -f "${existing}" ] || continue
			existing_name=$(pkg query -F "${existing}" '%n' 2>/dev/null ||
			    true)
			[ "${existing_name}" = "${pkg_name}" ] || continue
			archive_package "${existing}"
		done

		# Publish the package and a matching checksum.
		cp -p "${package}" "${output_package}"
		sha256 "${output_package}" > "${output_package}.sha256"
		echo "Package: ${output_package}"
	done
	[ "${found}" = "1" ] || die "no package produced for ${origin}"
}

# build_port ORIGIN
# Input: Port origin in "$1" plus source, board and work globals.
# Input example: build_port sysutils/rk3588-installer
# Output: builds, validates and publishes every package from the Port.
# Output example: one or more .pkg and .pkg.sha256 files in ports/<board>/
build_port()
{
	origin=$1
	port_dir=${PORTS_SRC_DIR}/${origin}
	[ -f "${port_dir}/Makefile" ] || die "missing port: ${origin}"

	# Give each origin a stable, filesystem-safe work directory.
	slug=$(printf '%s\n' "${origin}" | tr / _)
	port_work=${ports_work}/${slug}
	board_patches=$(collect_board_patches "${origin}")

	run_port_build "${origin}" "${port_dir}" "${port_work}" "${board_patches}"
	validate_port_modules "${port_work}"
	publish_port_packages "${origin}" "${port_work}"
}

# build_configured_ports
# Input: space-separated global PORT_ORIGINS.
# Input example: PORT_ORIGINS="ports-mgmt/pkg net/realtek-rge-kmod"
# Output: builds and publishes each configured origin in order.
# Output example: shared packages in ports/ and board packages in ports/<board>/
build_configured_ports()
{
	for origin in ${PORT_ORIGINS}; do
		build_port "${origin}"
	done
}

# fetch_runtime_package NAME ORIGIN
# Input: package name "$1", expected origin "$2" and target/output globals.
# Input example: fetch_runtime_package rtlbt-firmware comms/rtlbt-firmware
# Output: fetches and publishes one board-specific runtime package.
# Output example: /output/14.3-p16/ports/nanopc-t6-lts/rtlbt-firmware-20251111.pkg
fetch_runtime_package()
{
	[ -n "${BOARD}" ] || die "BOARD is required for runtime package"
	runtime_name=$1
	runtime_origin=$2
	runtime_fetch=${ports_work}/${runtime_name}-fetch
	mkdir -p "${runtime_fetch}"

	# Fetch the architecture-independent runtime firmware package.
	pkg fetch -y -o "${runtime_fetch}" "${runtime_name}"
	set -- $(find "${runtime_fetch}" -type f -name "${runtime_name}-*.pkg")
	[ "$#" -eq 1 ] || die "expected one fetched ${runtime_name} package"
	package=$1

	# Verify origin and ABI before replacing the published copy.
	pkg_origin=$(pkg query -F "${package}" '%o')
	pkg_abi=$(pkg query -F "${package}" '%q')
	[ "${pkg_origin}" = "${runtime_origin}" ] ||
		die "unexpected ${runtime_name} origin: ${pkg_origin}"
	[ "${pkg_abi}" = "FreeBSD:${FREEBSD_OBJ_VERSION%%.*}:*" ] ||
		die "unexpected ${runtime_name} ABI: ${pkg_abi}"
	mkdir -p "${BOARD_PORTS_OUTPUT_DIR}"
	for existing in "${BOARD_PORTS_OUTPUT_DIR}"/${runtime_name}-*.pkg; do
		[ -f "${existing}" ] || continue
		archive_package "${existing}"
	done

	# Publish the fetched package and checksum under its original filename.
	output_package=${BOARD_PORTS_OUTPUT_DIR}/${package##*/}
	cp -p "${package}" "${output_package}"
	sha256 "${output_package}" > "${output_package}.sha256"
	echo "Package: ${output_package}"
}

# main
# Input: no command-line arguments; configuration comes from the environment/files.
# Input example: BOARD=g98 ./build-ports.sh
# Output: publishes configured Ports and board-selected runtime packages.
# Output example: /root/freebsd-rk3588-builder/work/txz/14.3-p16/*.pkg
main()
{
	load_configuration
	validate_environment
	prepare_workspace
	build_configured_ports
	run_board_hook board_ports_publish_extra_packages
}

main "$@"
