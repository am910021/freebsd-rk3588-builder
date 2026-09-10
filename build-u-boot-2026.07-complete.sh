#!/bin/sh
set -eu

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

# load_configuration
# Input: optional BUILDER_ROOT and BUILDER_CONFIG environment variables.
# Input example: BOARD=g98 BUILDER_CONFIG=/root/freebsd-rk3588-builder/builder.conf
# Output: loads builder.conf and the selected board configuration into globals.
# Output example: UBOOT_DEFCONFIG=g98-rk3588_defconfig
load_configuration()
{
	BUILDER_ROOT=${BUILDER_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}
	BUILDER_CONFIG=${BUILDER_CONFIG:-${BUILDER_ROOT}/builder.conf}
	[ -r "${BUILDER_CONFIG}" ] ||
		fail "missing config: ${BUILDER_CONFIG}"

	# Load shared and board-specific U-Boot settings.
	. "${BUILDER_CONFIG}"
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
	for cmd in git gmake bison mktemp python3 sha256 swig tar; do
		command -v "${cmd}" >/dev/null 2>&1 || fail "missing command: ${cmd}"
	done
	command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1 ||
	    fail "missing compiler: ${CROSS_COMPILE}gcc"
	python3 -c 'import elftools, setuptools' >/dev/null 2>&1 ||
	    fail "missing Python modules: install py312-pyelftools, py312-setuptools, and py312-more-itertools"

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
	# Keep binary layout validation and image assembly in one deterministic Python pass.
	python3 - "${OUT}" "${FIRMWARE_MIB}" "${UBOOT_LOGO_ENABLE}" \
    "${BOARD}" "${UBOOT_BINARY_MARKER}" "${UBOOT_FIRMWARE_COMPAT}" <<'PY'
from pathlib import Path
import hashlib
import re
import sys

out = Path(sys.argv[1])
size_mib = int(sys.argv[2])
logo_enable = b"1" if sys.argv[3] == "YES" else b"0"
board = sys.argv[4]
binary_marker = sys.argv[5].encode()
firmware_compat = sys.argv[6]
mib = 1024 * 1024
sector = 512
idb_offset = 0x40 * sector
uboot_offset = 0x4000 * sector
logo_offset = 0x6000 * sector
logo_read_size = 0x961 * sector
env_offset = (size_mib * mib) - (512 * 1024)
env_offset_redund = env_offset + (64 * 1024)
env_size = 0x10000
env_reserve_end = size_mib * mib

binary = (out / "u-boot.bin").read_bytes()
for marker in (
    binary_marker,
    b"bootmenu_delay=3",
    b"logo_delay=0",
    b"logo_enable=" + logo_enable,
    b"show_logo=",
    b"freebsdboot",
    b"/uboot-env.request",
    b"boot_freebsd_target=",
    b"freebsd_default_boot=auto",
    b"rk_boot_storage",
    b"rockchip,boot-storage",
):
    if marker not in binary:
        raise SystemExit(f"u-boot.bin lacks marker: {marker!r}")

compat_prefix = b"RK3588-FW-COMPAT-V1:"
version_prefix = b"RK3588-FW-VERSION-V1:"
target_prefix = b"RK3588-FW-TARGET-V1:"
config = (out / "u-boot.config").read_text(encoding="utf-8")
spi_update = "CONFIG_RK3588_FREEBSD_SPI_UPDATE=y" in config.splitlines()
if bool(firmware_compat) != spi_update:
    raise SystemExit("firmware compatibility and SPI updater config disagree")
if spi_update:
    match = re.fullmatch(r"[A-Z0-9][A-Z0-9_-]*:SPI:(16|32)M", firmware_compat)
    if not match or int(match.group(1)) != size_mib:
        raise SystemExit(
            f"invalid firmware compatibility identity: {firmware_compat!r}"
        )
    compat_marker = compat_prefix + firmware_compat.encode() + b"\0"
    if binary.count(compat_prefix) != 1 or binary.count(compat_marker) != 1:
        raise SystemExit("u-boot.bin must contain exactly one compatibility marker")
    if binary.count(version_prefix) != 1:
        raise SystemExit("u-boot.bin must contain exactly one version marker")

logo = (out / "logo.bmp").read_bytes()
if logo[:2] != b"BM" or int.from_bytes(logo[2:6], "little") != len(logo):
    raise SystemExit("logo.bmp has an invalid BMP header or file size")
logo_raw = logo + b"\xff" * (-len(logo) % sector)
if len(logo_raw) > logo_read_size:
    raise SystemExit(
        f"logo.bmp needs {len(logo_raw)} bytes, "
        f"but U-Boot reads only {logo_read_size}"
    )

for setting in (
    f"CONFIG_ENV_OFFSET=0x{env_offset:x}",
    f"CONFIG_ENV_OFFSET_REDUND=0x{env_offset_redund:x}",
    f"CONFIG_ENV_SIZE=0x{env_size:x}",
    "CONFIG_ENV_REDUNDANT=y",
    "CONFIG_ENV_IS_IN_MMC=y",
    "CONFIG_ENV_IS_IN_SPI_FLASH=y",
):
    if setting not in config.splitlines():
        raise SystemExit(f"u-boot.config lacks setting: {setting}")
if spi_update:
    for setting in (
        f'CONFIG_RK3588_FREEBSD_SPI_COMPAT="{firmware_compat}"',
        f"CONFIG_RK3588_FREEBSD_SPI_LAYOUT_MIB={size_mib}",
    ):
        if setting not in config.splitlines():
            raise SystemExit(f"u-boot.config lacks setting: {setting}")

idb = (out / "idbloader.img").read_bytes()
uboot = (out / "u-boot.itb").read_bytes()
spi = (out / "u-boot-rockchip-spi.bin").read_bytes()
spi_uboot_offset = int(next(
    line.split("=", 1)[1] for line in config.splitlines()
    if line.startswith("CONFIG_SYS_SPI_U_BOOT_OFFS=")
), 0)
if spi[spi_uboot_offset:spi_uboot_offset + 4] != b"\xd0\x0d\xfe\xed":
    raise SystemExit("SPI image lacks FIT at CONFIG_SYS_SPI_U_BOOT_OFFS")

mmc_parts = (
    ("idbloader.img", idb_offset, idb, uboot_offset),
    ("u-boot.itb", uboot_offset, uboot, logo_offset),
    ("MMC logo.img", logo_offset, logo_raw, env_offset),
)
spi_parts = (
    ("u-boot-rockchip-spi.bin", 0, spi, logo_offset),
    ("SPI logo.img", logo_offset, logo_raw, env_offset),
)
for name, offset, data, limit in mmc_parts + spi_parts:
    if offset + len(data) > limit:
        raise SystemExit(
            f"{name} ends at {offset + len(data)} bytes, "
            f"past its {limit}-byte limit"
        )

board_identity = firmware_compat.split(":", 1)[0]
target_offset = env_offset - sector

def stamp_target(image, layout):
    """Stamp one firmware target marker.

    Input: mutable image bytearray and layout string such as "MMC" or "SPI".
    Output: updates image in place; for example, adds "G98:SPI:16M".
    """
    marker = target_prefix + f"{board_identity}:{layout}:{size_mib}M".encode() + b"\0"
    if any(value != 0xff for value in image[target_offset:target_offset + sector]):
        raise SystemExit("firmware target marker sector is not empty")
    image[target_offset:target_offset + len(marker)] = marker

mmc_firmware = bytearray(b"\xff") * (size_mib * mib)
spi_firmware = bytearray(b"\xff") * (size_mib * mib)
for _, offset, data, _ in mmc_parts:
    mmc_firmware[offset:offset + len(data)] = data
for _, offset, data, _ in spi_parts:
    spi_firmware[offset:offset + len(data)] = data
stamp_target(mmc_firmware, "MMC")
stamp_target(spi_firmware, "SPI")

mmc_name = f"{board}-uboot-{size_mib}m-mmc.bin"
spi_name = f"{board}-uboot-{size_mib}m-spi.bin"
(out / mmc_name).write_bytes(mmc_firmware)
(out / spi_name).write_bytes(spi_firmware)
mmc_firmware_update = bytes(mmc_firmware[:env_offset])
spi_firmware_update = bytes(spi_firmware[:env_offset])
(out / "firmware-update-mmc.bin").write_bytes(mmc_firmware_update)
(out / "firmware-update-spi.bin").write_bytes(spi_firmware_update)

for name, image in (
    ("firmware-update-mmc.bin", mmc_firmware_update),
    ("firmware-update-spi.bin", spi_firmware_update),
):
    if (image.count(compat_prefix) != 1 or
            image.count(compat_marker) != 1):
        raise SystemExit(
            f"{name} must contain exactly one compatibility marker"
        )
    if image.count(version_prefix) != 1:
        raise SystemExit(f"{name} must contain exactly one version marker")
(out / "uboot-spi-update.request").write_text(
    "version=1\n"
    f"size={len(spi_firmware_update)}\n"
    f"sha256={hashlib.sha256(spi_firmware_update).hexdigest()}\n"
)
(out / "logo.img").write_bytes(logo_raw)
(out / "FIRMWARE-LAYOUT.txt").write_text(
    f"Firmware size: {size_mib} MiB\n"
    "Fill byte: 0xff\n"
    f"Firmware compatibility: {firmware_compat or 'not applicable'}\n"
    f"MMC image: {mmc_name}\n"
    f"  idbloader.img: LBA 0x40, {len(idb)} bytes, limit 8 MiB\n"
    f"  u-boot.itb: LBA 0x4000, {len(uboot)} bytes, limit 12 MiB\n"
    f"SPI image: {spi_name}\n"
    f"  u-boot-rockchip-spi.bin: offset 0x0, {len(spi)} bytes, "
    "limit 12 MiB\n"
    f"  SPL payload: 0x{spi_uboot_offset:x}\n"
    f"logo.img: LBA 0x6000, {len(logo_raw)} bytes, "
    f"limit {env_offset} bytes\n"
    f"environment primary: 0x{env_offset:x}, {env_size} bytes\n"
    f"environment redundant: 0x{env_offset_redund:x}, {env_size} bytes\n"
    f"environment reserved area: 0x{env_offset:x}-0x{env_reserve_end:x}\n"
    f"MMC updater: firmware-update-mmc.bin, LBA 64-0x{env_offset // sector:x}\n"
    + ("SPI updater: firmware-update-spi.bin, "
       f"0x0-0x{env_offset:x}\n" if spi_update else "")
)
PY
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
# Input: staged OUT plus FINAL_OUT, WORK_ROOT and VERSION_OUTPUT_ROOT globals.
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
	mkdir -p "${VERSION_OUTPUT_ROOT}"
	PUBLISH_OUT=${VERSION_OUTPUT_ROOT}/${FINAL_OUT##*/}
	PUBLISH_STAGING=$(mktemp -d "${VERSION_OUTPUT_ROOT}/.${FINAL_OUT##*/}.XXXXXX")
	(cd "${OUT}" && tar -cpf - .) |
	    (cd "${PUBLISH_STAGING}" && tar -xpf -)
	if [ -e "${PUBLISH_OUT}" ]; then
		mkdir -p "${HOME}/ready-to-delete"
		mv "${PUBLISH_OUT}" \
		    "${HOME}/ready-to-delete/output-${PUBLISH_OUT##*/}-$(date +%Y%m%d-%H%M%S)-$$"
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
# Output example: output/14.3-p16/g98-uboot-2026.07-16m/
main()
{
	load_configuration
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
