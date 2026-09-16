#!/bin/sh

set -eu

# die MESSAGE
# Input: error text in "$*"; no required global variables.
# Input example: die "missing FreeBSD source: /root/freebsd-src"
# Output: writes "<script>: MESSAGE" to stderr and exits with status 1.
# Output example: build-freebsd-release.sh: missing FreeBSD source: /root/freebsd-src
die()
{
	echo "${0##*/}: $*" >&2
	exit 1
}

# load_configuration
# Input: optional BUILDER_ROOT and BUILDER_CONFIG environment variables.
# Input example: BUILDER_CONFIG=/root/freebsd-rk3588-builder/builder.conf
# Output: loads builder.conf and its board configuration into global variables.
# Output example: FREEBSD_KERNCONF=RK3588_G98_NORE
load_configuration()
{
	BUILDER_ROOT=${BUILDER_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}
	BUILDER_CONFIG=${BUILDER_CONFIG:-${BUILDER_ROOT}/builder.conf}
	[ -r "${BUILDER_CONFIG}" ] ||
		die "missing config: ${BUILDER_CONFIG}"

	# Load the shared and selected board settings.
	. "${BUILDER_CONFIG}"
}

# configure_clean_mode
# Input: global NO_CLEAN set to YES or NO.
# Input example: NO_CLEAN=YES
# Output: sets global no_clean_make_arg for subsequent make invocations.
# Output example: no_clean_make_arg=WITHOUT_CLEAN=yes
configure_clean_mode()
{
	case "${NO_CLEAN}" in
	YES) no_clean_make_arg=WITHOUT_CLEAN=yes ;;
	NO) no_clean_make_arg= ;;
	*) die "NO_CLEAN must be YES or NO" ;;
	esac
}

# validate_environment
# Input: FreeBSD source/object paths and revision variables from builder.conf.
# Input example: FREEBSD_SRC_DIR=/root/freebsd-rk3588-builder/src/freebsd-src
# Output: returns 0 when source, kernel config, Git state and tools are valid.
# Output example: no stdout and status 0
validate_environment()
{
	# Validate the source tree selected by the builder.
	[ -f "${FREEBSD_SRC_DIR}/Makefile" ] ||
		die "missing FreeBSD source: ${FREEBSD_SRC_DIR}"
	[ -f "${FREEBSD_SRC_DIR}/sys/arm64/conf/${FREEBSD_KERNCONF}" ] ||
		die "missing kernel configuration: ${FREEBSD_KERNCONF}"
	[ -z "$(git -C "${FREEBSD_SRC_DIR}" status --porcelain)" ] ||
		die "FreeBSD source has uncommitted changes"
	[ "${FREEBSD_SRC_COMMIT}" != unknown ] ||
		die "cannot determine FreeBSD source commit"

	# Check every host command used below before starting a long build.
	for cmd in chflags chmod cp git make mktemp mv sha256 tar; do
		command -v "${cmd}" >/dev/null 2>&1 ||
			die "missing command: ${cmd}"
	done
}

# freebsd_make TARGETS...
# Input: make targets/options in "$@" plus global source, object and build settings.
# Input example: freebsd_make -j16 buildworld buildkernel
# Output: runs FreeBSD top-level make and returns its status/output unchanged.
# Output example: objects under ${FREEBSD_OBJ_ROOT}
freebsd_make()
{
	env SB="${BUILDER_ROOT}" SB_OBJROOT="${FREEBSD_OBJ_ROOT}/" \
	    make -C "${FREEBSD_SRC_DIR}" \
	    TARGET=arm64 TARGET_ARCH=aarch64 \
	    KERNCONF="${FREEBSD_KERNCONF}" \
	    SRCCONF=/dev/null __MAKE_CONF=/dev/null \
	    WITHOUT_DEBUG_FILES=yes WITHOUT_KERNEL_SYMBOLS=yes \
	    ${no_clean_make_arg} "$@"
}

# release_make TARGETS...
# Input: release make targets/options in "$@" plus global build settings.
# Input example: release_make -j16 base.txz kernel.txz
# Output: runs release/Makefile and returns its status/output unchanged.
# Output example: base.txz and kernel.txz in the release object directory
release_make()
{
	env SB="${BUILDER_ROOT}" SB_OBJROOT="${FREEBSD_OBJ_ROOT}/" \
	    make -C "${FREEBSD_SRC_DIR}/release" \
	    TARGET=arm64 TARGET_ARCH=aarch64 \
	    KERNCONF="${FREEBSD_KERNCONF}" \
	    SRCCONF=/dev/null __MAKE_CONF=/dev/null \
	    WITHOUT_DEBUG_FILES=yes WITHOUT_KERNEL_SYMBOLS=yes \
	    NOPORTS=yes NOSRC=yes NOPKG=yes ${no_clean_make_arg} "$@"
}

# build_world_and_kernel
# Input: global FREEBSD_SRC_COMMIT, FREEBSD_KERNCONF, NO_CLEAN and JOBS.
# Input example: FREEBSD_SRC_COMMIT=eba0d85 FREEBSD_KERNCONF=RK3588_G98_NORE JOBS=16
# Output: creates or updates the arm64 world and kernel object trees.
# Output example: ${FREEBSD_OBJ}/tmp and ${KERNBUILDDIR}
build_world_and_kernel()
{
	# Create output roots before make writes objects or release archives.
	mkdir -p "${FREEBSD_OBJ_ROOT}" "${TXZ_ROOT}"

	echo "== Building FreeBSD ${FREEBSD_SRC_COMMIT} with ${FREEBSD_KERNCONF} =="
	echo "== NO_CLEAN=${NO_CLEAN} =="
	freebsd_make -j"${JOBS}" buildworld buildkernel
}

# package_release_archives
# Input: completed world/kernel objects and global BASE_TXZ/KERNEL_TXZ paths.
# Input example: BASE_TXZ=/root/freebsd-rk3588-builder/work/txz/base.txz
# Output: copies versioned base.txz and kernel.txz to the configured output paths.
# Output example: ${BASE_TXZ} and ${KERNEL_TXZ}
package_release_archives()
{
	echo "== Packaging versioned base and kernel archives =="

	# Recreate only the release packaging object directory.
	release_make clean
	release_make obj
	release_make -j"${JOBS}" base.txz kernel.txz
	release_obj=$(release_make -V .OBJDIR)

	# Refuse to publish an incomplete release build.
	[ -f "${release_obj}/base.txz" ] ||
		die "release did not produce ${release_obj}/base.txz"
	[ -f "${release_obj}/kernel.txz" ] ||
		die "release did not produce ${release_obj}/kernel.txz"
	cp -p "${release_obj}/base.txz" "${BASE_TXZ}"
	cp -p "${release_obj}/kernel.txz" "${KERNEL_TXZ}"
}

# package_live_archive
# Input: the completed world objects and global BASE_LIVE_TXZ/WORK_ROOT paths.
# Input example: BASE_LIVE_TXZ=output/14.3-p16/base-live-14.3-p16_<commit>.txz
# Output: stages an installer-only world and publishes its compressed archive.
# Output example: ${BASE_LIVE_TXZ}, without changing the full base.txz.
package_live_archive()
{
	echo "== Packaging reduced live-system archive =="
	mkdir -p "${WORK_ROOT}/tmp"
	live_stage=$(mktemp -d "${WORK_ROOT}/tmp/base-live.XXXXXXXX")
	live_archive=$(mktemp "${BASE_LIVE_TXZ}.tmp.XXXXXXXX")
	trap 'chflags -R 0 "${live_stage}" 2>/dev/null || true; rm -rf -- "${live_stage}"; rm -f -- "${live_archive}"' EXIT HUP INT TERM

	# The same full buildworld objects supply the reduced installworld.
	freebsd_make DESTDIR="${live_stage}" -DDB_FROM_SRC \
	    MK_TOOLCHAIN=no MK_TESTS=no MK_DEBUG_FILES=no \
	    MK_LIB32=no MK_INSTALLLIB=no MK_MAN=no MK_DICT=no \
	    installworld distribution
	[ -x "${live_stage}/bin/sh" ] ||
		die "live stage did not install /bin/sh"
	[ -f "${live_stage}/etc/master.passwd" ] ||
		die "live stage did not install /etc/master.passwd"
	tar -cJpf "${live_archive}" -C "${live_stage}" .
	chmod 644 "${live_archive}"
	mv -f -- "${live_archive}" "${BASE_LIVE_TXZ}"
	# installworld marks select files immutable on FreeBSD hosts.
	chflags -R 0 "${live_stage}"
	rm -rf -- "${live_stage}"
	trap - EXIT HUP INT TERM
}

# report_outputs
# Input: global BASE_TXZ, KERNEL_TXZ, FREEBSD_OBJ and TXZ_ROOT.
# Input example: TXZ_ROOT=/root/freebsd-rk3588-builder/work/txz/14.3-p16
# Output: verifies archive hashes and prints the final object/output locations.
# Output example: SHA-256 lines followed by "Release packages: <TXZ_ROOT>"
report_outputs()
{
	sha256 "${BASE_TXZ}" "${BASE_LIVE_TXZ}" "${KERNEL_TXZ}"
	echo "FreeBSD objects: ${FREEBSD_OBJ}"
	echo "Release packages: ${TXZ_ROOT}"
}

# main
# Input: no command-line arguments; configuration comes from the environment/files.
# Input example: BOARD=g98 NO_CLEAN=YES ./build-freebsd-release.sh
# Output: builds world/kernel and publishes base.txz plus kernel.txz.
# Output example: ${TXZ_ROOT}/base.txz and ${TXZ_ROOT}/kernel.txz
main()
{
	load_configuration
	configure_clean_mode
	validate_environment
	build_world_and_kernel
	package_release_archives
	package_live_archive
	report_outputs
}

main "$@"
