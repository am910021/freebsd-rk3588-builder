#!/bin/sh
set -eu

BUILDER_ROOT=${BUILDER_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}
BUILDER_LIBRARY=${BUILDER_LIBRARY:-${BUILDER_ROOT}/lib/builder-common.sh}
[ -r "${BUILDER_LIBRARY}" ] || {
	echo "${0##*/}: missing library: ${BUILDER_LIBRARY}" >&2
	exit 1
}
. "${BUILDER_LIBRARY}"

# fail MESSAGE
# Input: error text in "$*"; no required global variables.
# Input example: fail "BOARD is required"
# Output: writes "<script>: MESSAGE" to stderr and exits with status 1.
# Output example: build-u-boot-2026.07-complete.sh: BOARD is required
fail()
{
	echo "${0##*/}: $*" >&2
	exit 1
}

# validate_invocation
# Input: command-line arguments in "$@" and global BOARD from builder.conf.
# Input example: validate_invocation with BOARD=g98 and no positional arguments
# Output: returns 0 for a selected board and the supported empty argument list.
# Output example: no stdout and status 0
validate_invocation()
{
	[ -n "${BOARD}" ] || fail "BOARD is required"
	[ "$#" -eq 0 ] || {
		echo "usage: ${0##*/}" >&2
		exit 1
	}
}

# configure_firmware_layout
# Input: global FIRMWARE_MIB, BOARD, UBOOT_VERSION, WORK_ROOT and logo settings.
# Input example: FIRMWARE_MIB=16 BOARD=nanopc-t6-lts
# Output: calculates firmware offsets and initializes output/work globals.
# Output example: ENV_OFFSET_HEX=0xf80000 and FINAL_OUT=<WORK_ROOT>/nanopc-t6-lts-uboot-2026.07-16m
configure_firmware_layout()
{
	case "${FIRMWARE_MIB}" in
	16|32) ;;
	*) fail "firmware size must be 16 or 32 MiB" ;;
	esac

	FIRMWARE_BYTES=$((FIRMWARE_MIB * 1024 * 1024))
	ENV_OFFSET=$((FIRMWARE_BYTES - 512 * 1024))
	ENV_OFFSET_REDUND=$((ENV_OFFSET + 64 * 1024))
	ENV_OFFSET_HEX=$(printf '0x%x' "${ENV_OFFSET}")
	ENV_OFFSET_REDUND_HEX=$(printf '0x%x' "${ENV_OFFSET_REDUND}")
	FINAL_OUT=${WORK_ROOT}/${BOARD}-uboot-${UBOOT_VERSION}-${FIRMWARE_MIB}m
	WORK=${WORK:-}
	LOGO_BMP=${LOGO_BMP:-${UBOOT_LOGO_BMP}}
}

# validate_build_inputs
# Input: U-Boot paths, source selection and tool globals from builder.conf.
# Input example: UBOOT_BRANCH=yuri/rk3588 CROSS_COMPILE=aarch64-none-elf-
# Output: validates files/tools/source and sets source and logo globals.
# Output example: SOURCE_BRANCH=yuri/rk3588 and LOGO_CONFIG=--enable
validate_build_inputs()
{
	# Convert the configured logo policy into scripts/config arguments.
	case "${UBOOT_LOGO_ENABLE}" in
	YES)
		LOGO_CONFIG=--enable
		;;
	NO)
		LOGO_CONFIG=--disable
		;;
	*)
		fail "UBOOT_LOGO_ENABLE must be YES or NO"
		;;
	esac

	# Verify configured input files and source-selection values.
	for file in "${UBOOT_BL31}" "${UBOOT_ROCKCHIP_TPL}" "${LOGO_BMP}" \
	    "${FREEBSD_DTS}"; do
		[ -f "${file}" ] || fail "missing input: ${file}"
	done
	[ -n "${UBOOT_BRANCH}${UBOOT_COMMIT}" ] ||
	    fail "UBOOT_BRANCH or UBOOT_COMMIT is not configured"
	[ -n "${UBOOT_DEFCONFIG}" ] || fail "UBOOT_DEFCONFIG is not configured"
	[ -n "${UBOOT_LOGO_CONFIG}" ] || fail "UBOOT_LOGO_CONFIG is not configured"
	[ -n "${UBOOT_BINARY_MARKER}" ] ||
	    fail "UBOOT_BINARY_MARKER is not configured"
	[ -n "${UBOOT_FIRMWARE_COMPAT}" ] ||
	    fail "UBOOT_FIRMWARE_COMPAT is not configured"
	[ -d "${UBOOT_SRC_DIR}" ] || fail "missing source: ${UBOOT_SRC_DIR}"
	[ -z "${UBOOT_SOURCE_FILES_DIR}" ] ||
	    [ -d "${UBOOT_SOURCE_FILES_DIR}" ] ||
	    fail "missing U-Boot source files: ${UBOOT_SOURCE_FILES_DIR}"

	# Check every host tool and Python module before creating work directories.
	for cmd in awk bison cp dd grep gmake git mktemp od pkg python3 sha256 \
	    stat swig tar tr wc; do
		command -v "${cmd}" >/dev/null 2>&1 || fail "missing command: ${cmd}"
	done
	command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1 ||
	    fail "missing compiler: ${CROSS_COMPILE}gcc"
	python_package_prefix=$(python3 -V 2>&1 | \
	    awk -F '[ .]' '{ print "py" $2 $3 }')
	case "${python_package_prefix}" in
	py[0-9]*) ;;
	*) fail "cannot determine the python3 package prefix" ;;
	esac
	for python_package in pyelftools setuptools more-itertools; do
		pkg info -e "${python_package_prefix}-${python_package}-*" ||
		    fail "missing Python package: ${python_package_prefix}-${python_package}"
	done

	# Pin the build to the configured clean branch or exact commit.
	SOURCE_COMMIT=$(git -C "${UBOOT_SRC_DIR}" rev-parse HEAD)
	SOURCE_BRANCH=$(git -C "${UBOOT_SRC_DIR}" symbolic-ref --short HEAD \
	    2>/dev/null || echo detached)
	if [ -n "${UBOOT_COMMIT}" ]; then
		EXPECTED_COMMIT=$(git -C "${UBOOT_SRC_DIR}" rev-parse \
	    "${UBOOT_COMMIT}^{commit}")
		[ "${SOURCE_COMMIT}" = "${EXPECTED_COMMIT}" ] ||
		    fail "unexpected source commit: ${SOURCE_COMMIT}"
	elif [ "${SOURCE_BRANCH}" != "${UBOOT_BRANCH}" ]; then
		fail "unexpected source branch: ${SOURCE_BRANCH}"
	fi
	[ -z "$(git -C "${UBOOT_SRC_DIR}" status --porcelain)" ] ||
	    fail "source tree is not clean: ${UBOOT_SRC_DIR}"
}

# cleanup
# Input: global WORK, AUTO_WORK, STAGING_OUT and PUBLISH_STAGING paths.
# Input example: AUTO_WORK=1 WORK=/work/tmp/g98-uboot.abcd
# Output: moves temporary paths into $HOME/ready-to-delete on exit.
# Output example: $HOME/ready-to-delete/g98-uboot.abcd-<timestamp>-<pid>
cleanup()
{
	# Preserve failed/interrupted work for later inspection instead of deleting it.
	mkdir -p "${HOME}/ready-to-delete"
	if [ -n "${STAGING_OUT}" ] && [ -e "${STAGING_OUT}" ]; then
		mv "${STAGING_OUT}" \
		    "${HOME}/ready-to-delete/${STAGING_OUT##*/}-$(date +%Y%m%d-%H%M%S)-$$"
	fi
	if [ -n "${PUBLISH_STAGING}" ] && [ -e "${PUBLISH_STAGING}" ]; then
		mv "${PUBLISH_STAGING}" \
		    "${HOME}/ready-to-delete/${PUBLISH_STAGING##*/}-$(date +%Y%m%d-%H%M%S)-$$"
	fi
	if [ "${AUTO_WORK}" = "1" ] && [ -e "${WORK}" ]; then
		mv "${WORK}" \
		    "${HOME}/ready-to-delete/${WORK##*/}-$(date +%Y%m%d-%H%M%S)-$$"
	fi
}

# prepare_workspace
# Input: global WORK_ROOT, WORK, BOARD, UBOOT_VERSION and FIRMWARE_MIB.
# Input example: WORK=/tmp/g98-build or an empty WORK for automatic allocation
# Output: creates work/staging directories and initializes build path globals.
# Output example: OUT=<WORK_ROOT>/tmp/g98-uboot-2026.07-16m.abcd
prepare_workspace()
{
	mkdir -p "${WORK_ROOT}/tmp"
	AUTO_WORK=0
	STAGING_OUT=
	PUBLISH_STAGING=
	if [ -z "${WORK}" ]; then
		WORK=$(mktemp -d "${WORK_ROOT}/tmp/${BOARD}-uboot.XXXXXX")
		AUTO_WORK=1
	else
		[ ! -e "${WORK}" ] || fail "work directory already exists: ${WORK}"
		mkdir -p "${WORK}"
	fi
	trap cleanup EXIT INT TERM

	# Stage the public bundle separately so publication remains atomic.
	STAGING_OUT=$(mktemp -d \
	    "${WORK_ROOT}/tmp/${BOARD}-uboot-${UBOOT_VERSION}-${FIRMWARE_MIB}m.XXXXXX")
	OUT=${STAGING_OUT}
	BUILD_DIR=${WORK}/build
	BUILD_SOURCE_DIR=${UBOOT_SRC_DIR}
	BUILD_SOURCE_COMMIT=${SOURCE_COMMIT}
}

# prepare_build_source
# Input: clean UBOOT_SRC_DIR plus optional UBOOT_SOURCE_FILES_DIR overlay.
# Input example: UBOOT_SOURCE_FILES_DIR=/root/freebsd-rk3588-builder/boards/g98/u-boot/source
# Output: sets BUILD_SOURCE_DIR/BUILD_SOURCE_COMMIT to the exact build tree.
# Output example: BUILD_SOURCE_DIR=<WORK>/source with a reproducible overlay commit
prepare_build_source()
{
	if [ -n "${UBOOT_SOURCE_FILES_DIR}" ]; then
		# Clone the pinned source and overlay board-owned files without changing src/.
		BUILD_SOURCE_DIR=${WORK}/source
		git clone --quiet --shared --no-checkout "${UBOOT_SRC_DIR}" \
		    "${BUILD_SOURCE_DIR}"
		git -C "${BUILD_SOURCE_DIR}" checkout --quiet --detach \
		    "${SOURCE_COMMIT}"
		(cd "${UBOOT_SOURCE_FILES_DIR}" && tar -cpf - .) |
		    (cd "${BUILD_SOURCE_DIR}" && tar -xpf -)
		if [ -n "$(git -C "${BUILD_SOURCE_DIR}" status --porcelain)" ]; then
			# Commit the overlay with the source timestamp for reproducible metadata.
			SOURCE_COMMIT_DATE=$(git -C "${UBOOT_SRC_DIR}" show -s \
			    --format=%cI "${SOURCE_COMMIT}")
			git -C "${BUILD_SOURCE_DIR}" add -A
			env GIT_AUTHOR_DATE="${SOURCE_COMMIT_DATE}" \
			    GIT_COMMITTER_DATE="${SOURCE_COMMIT_DATE}" \
			    git -C "${BUILD_SOURCE_DIR}" \
			    -c user.name=Yuri -c user.email=am910021@gmail.com \
			    commit --quiet -m "builder: apply ${BOARD} source overlay"
			BUILD_SOURCE_COMMIT=$(git -C "${BUILD_SOURCE_DIR}" rev-parse HEAD)
		fi
	fi
}

# build_u_boot
# Input: BUILD_SOURCE_DIR/BUILD_DIR and configured toolchain, firmware and logo globals.
# Input example: UBOOT_DEFCONFIG=nanopc-t6-lts-rk3588_defconfig JOBS=16
# Output: creates and validates the required U-Boot build artifacts.
# Output example: <BUILD_DIR>/idbloader.img, u-boot.itb and u-boot-rockchip-spi.bin
build_u_boot()
{
	# Generate the board defconfig, then apply builder-controlled options.
	gmake -C "${BUILD_SOURCE_DIR}" O="${BUILD_DIR}" \
	    CROSS_COMPILE="${CROSS_COMPILE}" "${UBOOT_DEFCONFIG}"
	"${BUILD_SOURCE_DIR}/scripts/config" --file "${BUILD_DIR}/.config" \
	    --disable TOOLS_MKEFICAPSULE
	"${BUILD_SOURCE_DIR}/scripts/config" --file "${BUILD_DIR}/.config" \
	    --set-val ENV_OFFSET "${ENV_OFFSET_HEX}" \
	    --set-val ENV_OFFSET_REDUND "${ENV_OFFSET_REDUND_HEX}"
	[ -z "${UBOOT_FIRMWARE_COMPAT}" ] ||
	    "${BUILD_SOURCE_DIR}/scripts/config" --file "${BUILD_DIR}/.config" \
	    --set-str RK3588_FREEBSD_SPI_COMPAT "${UBOOT_FIRMWARE_COMPAT}" \
	    --set-val RK3588_FREEBSD_SPI_LAYOUT_MIB "${FIRMWARE_MIB}"
	"${BUILD_SOURCE_DIR}/scripts/config" --file "${BUILD_DIR}/.config" \
	    "${LOGO_CONFIG}" "${UBOOT_LOGO_CONFIG}"
	gmake -C "${BUILD_SOURCE_DIR}" O="${BUILD_DIR}" \
	    CROSS_COMPILE="${CROSS_COMPILE}" olddefconfig

	# Compile SPL, U-Boot and the Rockchip MMC/SPI firmware inputs.
	gmake -C "${BUILD_SOURCE_DIR}" O="${BUILD_DIR}" \
	    CROSS_COMPILE="${CROSS_COMPILE}" \
	    BL31="${UBOOT_BL31}" ROCKCHIP_TPL="${UBOOT_ROCKCHIP_TPL}" \
	    -j"${JOBS}"

	# Fail before packaging if any required build artifact is absent.
	for file in idbloader.img u-boot.itb u-boot.bin u-boot.dtb .config; do
		[ -f "${BUILD_DIR}/${file}" ] ||
		    fail "build did not produce: ${file}"
	done
	[ -f "${BUILD_DIR}/u-boot-rockchip-spi.bin" ] ||
	    fail "build did not produce: u-boot-rockchip-spi.bin"
}

# build_freebsd_dtb
# Input: FREEBSD_DTS, CROSS_COMPILE, BUILD_SOURCE_DIR, BUILD_DIR, WORK and OUT.
# Input example: FREEBSD_DTS=<BOARD_DIR>/freebsd/rk3588-g98.dts
# Output: preprocesses and compiles the FreeBSD runtime device tree.
# Output example: <OUT>/freebsd-runtime.dtb
build_freebsd_dtb()
{
	# Preprocess the FreeBSD DTS with the U-Boot/Linux DTS include tree.
	FREEBSD_DTS_PP=${WORK}/${BOARD}-freebsd.pp.dts
	"${CROSS_COMPILE}gcc" -E -nostdinc -undef -D__DTS__ \
	    -x assembler-with-cpp \
	    -I"${BUILD_SOURCE_DIR}/dts/upstream/src/arm64/rockchip" \
	    -I"${BUILD_SOURCE_DIR}/dts/upstream/src/arm64" \
	    -I"${BUILD_SOURCE_DIR}/dts/upstream/src" \
	    -I"${BUILD_SOURCE_DIR}/dts/upstream/include" \
	    "${FREEBSD_DTS}" > "${FREEBSD_DTS_PP}"
	"${BUILD_DIR}/scripts/dtc/dtc" -@ -I dts -O dtb \
	    -Wno-unique_unit_address -Wunique_unit_address_if_enabled \
	    -o "${OUT}/freebsd-runtime.dtb" "${FREEBSD_DTS_PP}"
}

# stage_build_artifacts
# Input: BUILD_DIR, LOGO_BMP and OUT paths.
# Input example: OUT=/work/tmp/g98-uboot-2026.07-16m.abcd
# Output: copies raw U-Boot, configs, DTBs, logo and SPI image into OUT.
# Output example: <OUT>/u-boot.bin and <OUT>/u-boot-rockchip-spi.bin
stage_build_artifacts()
{
	# Copy immutable build inputs needed for packaging and later provenance review.
	cp -p "${BUILD_DIR}/idbloader.img" "${OUT}/idbloader.img"
	cp -p "${BUILD_DIR}/u-boot.itb" "${OUT}/u-boot.itb"
	cp -p "${BUILD_DIR}/u-boot.bin" "${OUT}/u-boot.bin"
	cp -p "${BUILD_DIR}/u-boot.dtb" "${OUT}/uboot-control.dtb"
	cp -p "${BUILD_DIR}/.config" "${OUT}/u-boot.config"
	cp -p "${LOGO_BMP}" "${OUT}/logo.bmp"
	SPI_FIRMWARE_FILE=u-boot-rockchip-spi.bin
	cp -p "${BUILD_DIR}/${SPI_FIRMWARE_FILE}" "${OUT}/${SPI_FIRMWARE_FILE}"
}

# assemble_firmware_images
# Input: staged artifacts plus firmware size, board, marker and compatibility globals.
# Input example: BOARD=g98 FIRMWARE_MIB=16 UBOOT_FIRMWARE_COMPAT=G98:SPI:16M
# Output: validates layout and writes complete MMC/SPI images and update payloads.
# Output example: <OUT>/g98-uboot-16m-mmc.bin and firmware-update-spi.bin
assemble_firmware_images()
{
	sh "${BUILDER_ROOT}/lib/assemble-firmware-images.sh" \
	    "${OUT}" "${FIRMWARE_MIB}" "${UBOOT_LOGO_ENABLE}" \
	    "${BOARD}" "${UBOOT_BINARY_MARKER}" "${UBOOT_FIRMWARE_COMPAT}"
}

# write_build_info
# Input: source/build/toolchain/board globals from the completed build.
# Input example: BOARD=nanopc-t6-lts SOURCE_BRANCH=yuri/rk3588
# Output: writes human-readable provenance to BUILD-INFO.txt.
# Output example: <OUT>/BUILD-INFO.txt
write_build_info()
{
	# Record the exact inputs used to create this bundle.
	cat > "${OUT}/BUILD-INFO.txt" <<EOF
Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Builder root: ${BUILDER_ROOT}
Board: ${BOARD}
U-Boot source: ${UBOOT_SRC_DIR}
Source branch: ${SOURCE_BRANCH}
Source commit: ${SOURCE_COMMIT}
Build source commit: ${BUILD_SOURCE_COMMIT}
Source files: ${UBOOT_SOURCE_FILES_DIR:-none}
BL31: ${UBOOT_BL31}
Rockchip TPL: ${UBOOT_ROCKCHIP_TPL}
Cross compile: ${CROSS_COMPILE}
Jobs: ${JOBS}
Logo: ${LOGO_BMP}
Logo enabled: ${UBOOT_LOGO_ENABLE}
FreeBSD DTS: ${FREEBSD_DTS}
Firmware MMC image: ${BOARD}-uboot-${FIRMWARE_MIB}m-mmc.bin
Firmware SPI image: ${BOARD}-uboot-${FIRMWARE_MIB}m-spi.bin
Firmware update MMC image: firmware-update-mmc.bin
Firmware update SPI image: firmware-update-spi.bin
Firmware update request: uboot-spi-update.request
Firmware size: ${FIRMWARE_MIB} MiB
EOF
}

# write_checksums
# Input: complete artifact bundle in OUT and global BOARD/FIRMWARE_MIB/SPI_FIRMWARE_FILE.
# Input example: OUT=/work/tmp/nanopc-t6-lts-uboot-2026.07-16m.abcd
# Output: writes SHA256SUMS covering every published artifact.
# Output example: <OUT>/SHA256SUMS
write_checksums()
{
	# Hash from inside OUT so checksum entries remain relative and portable.
	(
		cd "${OUT}"
		sha256 idbloader.img u-boot.itb u-boot.bin u-boot.config \
		    uboot-control.dtb freebsd-runtime.dtb \
		    logo.bmp logo.img \
		    "${BOARD}-uboot-${FIRMWARE_MIB}m-mmc.bin" \
		    "${BOARD}-uboot-${FIRMWARE_MIB}m-spi.bin" \
		    firmware-update-mmc.bin firmware-update-spi.bin \
		    uboot-spi-update.request \
		    ${SPI_FIRMWARE_FILE} \
		    FIRMWARE-LAYOUT.txt BUILD-INFO.txt > SHA256SUMS
	)
}

# publish_bundle
# Input: staged OUT plus FINAL_OUT, WORK_ROOT and UBOOT_OUTPUT_DIR globals.
# Input example: FINAL_OUT=<WORK_ROOT>/g98-uboot-2026.07-16m
# Output: atomically publishes copies, refreshes latest links and sets OUT/PUBLISH_OUT.
# Output example: <WORK_ROOT>/g98-uboot-latest -> <OUT>
publish_bundle()
{
	# Archive an older work bundle before replacing it.
	if [ -e "${FINAL_OUT}" ]; then
		mkdir -p "${HOME}/ready-to-delete"
		mv "${FINAL_OUT}" \
		    "${HOME}/ready-to-delete/${FINAL_OUT##*/}-$(date +%Y%m%d-%H%M%S)-$$"
	fi
	mv "${OUT}" "${FINAL_OUT}"
	STAGING_OUT=
	OUT=${FINAL_OUT}

	# Keep a stable latest link per board; retain the global link for compatibility.
	ln -sfn "${OUT}" "${WORK_ROOT}/${BOARD}-uboot-latest"
	ln -sfn "${OUT}" "${WORK_ROOT}/uboot-latest"

	# Copy the bundle through a staging directory before publishing it.
	mkdir -p "$(dirname "${UBOOT_OUTPUT_DIR}")"
	PUBLISH_OUT=${UBOOT_OUTPUT_DIR}
	PUBLISH_STAGING=$(mktemp -d "${UBOOT_OUTPUT_DIR}.XXXXXX")
	(cd "${OUT}" && tar -cpf - .) |
	    (cd "${PUBLISH_STAGING}" && tar -xpf -)
	if [ -e "${PUBLISH_OUT}" ]; then
		mkdir -p "${HOME}/ready-to-delete"
		mv "${PUBLISH_OUT}" \
		    "${HOME}/ready-to-delete/uboot-${UBOOT_VERSION}-${FIRMWARE_MIB}m-${BOARD}-$(date +%Y%m%d-%H%M%S)-$$"
	fi
	mv "${PUBLISH_STAGING}" "${PUBLISH_OUT}"
	PUBLISH_STAGING=
}

# report_outputs
# Input: published OUT/PUBLISH_OUT and artifact-name globals.
# Input example: OUT=<WORK_ROOT>/g98-uboot-2026.07-16m
# Output: prints sizes for key images followed by both bundle paths.
# Output example: final lines contain OUT and PUBLISH_OUT
report_outputs()
{
	echo "== ${BOARD} U-Boot ${UBOOT_VERSION} complete bundle =="
	ls -lh "${OUT}/idbloader.img" "${OUT}/u-boot.itb" \
	    "${OUT}/logo.img" \
	    "${OUT}/firmware-update-mmc.bin" \
	    "${OUT}/firmware-update-spi.bin" \
	    "${OUT}/${BOARD}-uboot-${FIRMWARE_MIB}m-mmc.bin" \
	    "${OUT}/${BOARD}-uboot-${FIRMWARE_MIB}m-spi.bin" \
	    "${OUT}/${SPI_FIRMWARE_FILE}" "${OUT}/uboot-spi-update.request"
	echo "${OUT}"
	echo "${PUBLISH_OUT}"
}

# main
# Input: no command-line arguments; configuration comes from the environment/files.
# Input example: BOARD=g98 ./build-u-boot-2026.07-complete.sh
# Output: builds and publishes a complete, checksummed MMC/SPI U-Boot bundle.
# Output example: output/14.3-p16/uboot-2026.07/16m/g98/
main()
{
	builder_load_configuration
	validate_invocation "$@"
	configure_firmware_layout
	validate_build_inputs
	prepare_workspace
	prepare_build_source
	build_u_boot
	build_freebsd_dtb
	stage_build_artifacts
	assemble_firmware_images
	write_build_info
	write_checksums
	publish_bundle
	report_outputs
}

main "$@"
