#!/bin/sh
set -eu

BUILDER_ROOT=${BUILDER_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}
BUILDER_CONFIG=${BUILDER_CONFIG:-${BUILDER_ROOT}/builder.conf}
[ -r "${BUILDER_CONFIG}" ] || {
	echo "${0##*/}: missing config: ${BUILDER_CONFIG}" >&2
	exit 1
}
. "${BUILDER_CONFIG}"

[ -n "${BOARD}" ] || {
	echo "${0##*/}: BOARD is required" >&2
	exit 1
}
[ "$#" -eq 0 ] || {
	echo "usage: ${0##*/}" >&2
	exit 1
}
case "${FIRMWARE_MIB}" in
	16|32) ;;
	*)
		echo "${0##*/}: firmware size must be 16 or 32 MiB" >&2
		exit 1
		;;
esac
case "${UBOOT_FIRMWARE_LAYOUT}" in
	mmc|spi) ;;
	*)
		echo "${0##*/}: U-Boot firmware layout must be mmc or spi" >&2
		exit 1
		;;
esac

FINAL_OUT=${WORK_ROOT}/${BOARD}-uboot-${UBOOT_VERSION}-${FIRMWARE_MIB}m
WORK=${WORK:-}
LOGO_BMP=${LOGO_BMP:-${UBOOT_LOGO_BMP}}

fail()
{
	echo "${0##*/}: $*" >&2
	exit 1
}

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
[ -d "${UBOOT_SRC_DIR}" ] || fail "missing source: ${UBOOT_SRC_DIR}"
[ -z "${UBOOT_SOURCE_FILES_DIR}" ] ||
    [ -d "${UBOOT_SOURCE_FILES_DIR}" ] ||
    fail "missing U-Boot source files: ${UBOOT_SOURCE_FILES_DIR}"
for cmd in git gmake bison mktemp python3 sha256 swig tar; do
	command -v "${cmd}" >/dev/null 2>&1 || fail "missing command: ${cmd}"
done
command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1 ||
    fail "missing compiler: ${CROSS_COMPILE}gcc"
python3 -c 'import elftools, setuptools' >/dev/null 2>&1 ||
    fail "missing Python modules: install py312-pyelftools, py312-setuptools, and py312-more-itertools"

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
cleanup()
{
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
trap cleanup EXIT INT TERM

STAGING_OUT=$(mktemp -d \
    "${WORK_ROOT}/tmp/${BOARD}-uboot-${UBOOT_VERSION}-${FIRMWARE_MIB}m.XXXXXX")
OUT=${STAGING_OUT}
BUILD_DIR=${WORK}/build
BUILD_SOURCE_DIR=${UBOOT_SRC_DIR}
BUILD_SOURCE_COMMIT=${SOURCE_COMMIT}

if [ -n "${UBOOT_SOURCE_FILES_DIR}" ]; then
	BUILD_SOURCE_DIR=${WORK}/source
	git clone --quiet --shared --no-checkout "${UBOOT_SRC_DIR}" \
	    "${BUILD_SOURCE_DIR}"
	git -C "${BUILD_SOURCE_DIR}" checkout --quiet --detach \
	    "${SOURCE_COMMIT}"
	(cd "${UBOOT_SOURCE_FILES_DIR}" && tar -cpf - .) |
	    (cd "${BUILD_SOURCE_DIR}" && tar -xpf -)
	if [ -n "$(git -C "${BUILD_SOURCE_DIR}" status --porcelain)" ]; then
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

gmake -C "${BUILD_SOURCE_DIR}" O="${BUILD_DIR}" \
    CROSS_COMPILE="${CROSS_COMPILE}" "${UBOOT_DEFCONFIG}"
"${BUILD_SOURCE_DIR}/scripts/config" --file "${BUILD_DIR}/.config" \
    --disable TOOLS_MKEFICAPSULE
"${BUILD_SOURCE_DIR}/scripts/config" --file "${BUILD_DIR}/.config" \
    "${LOGO_CONFIG}" "${UBOOT_LOGO_CONFIG}"
gmake -C "${BUILD_SOURCE_DIR}" O="${BUILD_DIR}" \
    CROSS_COMPILE="${CROSS_COMPILE}" olddefconfig
gmake -C "${BUILD_SOURCE_DIR}" O="${BUILD_DIR}" \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    BL31="${UBOOT_BL31}" ROCKCHIP_TPL="${UBOOT_ROCKCHIP_TPL}" \
    -j"${JOBS}"

for file in idbloader.img u-boot.itb u-boot.bin u-boot.dtb .config; do
	[ -f "${BUILD_DIR}/${file}" ] ||
	    fail "build did not produce: ${file}"
done
[ "${UBOOT_FIRMWARE_LAYOUT}" != "spi" ] ||
    [ -f "${BUILD_DIR}/u-boot-rockchip-spi.bin" ] ||
    fail "build did not produce: u-boot-rockchip-spi.bin"

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

cp -p "${BUILD_DIR}/idbloader.img" "${OUT}/idbloader.img"
cp -p "${BUILD_DIR}/u-boot.itb" "${OUT}/u-boot.itb"
cp -p "${BUILD_DIR}/u-boot.bin" "${OUT}/u-boot.bin"
cp -p "${BUILD_DIR}/u-boot.dtb" "${OUT}/uboot-control.dtb"
cp -p "${BUILD_DIR}/.config" "${OUT}/u-boot.config"
cp -p "${LOGO_BMP}" "${OUT}/logo.bmp"
SPI_FIRMWARE_FILE=
if [ "${UBOOT_FIRMWARE_LAYOUT}" = "spi" ]; then
	SPI_FIRMWARE_FILE=u-boot-rockchip-spi.bin
	cp -p "${BUILD_DIR}/${SPI_FIRMWARE_FILE}" "${OUT}/${SPI_FIRMWARE_FILE}"
fi

python3 - "${OUT}" "${FIRMWARE_MIB}" "${UBOOT_LOGO_ENABLE}" \
    "${BOARD}" "${UBOOT_BINARY_MARKER}" "${UBOOT_FIRMWARE_LAYOUT}" <<'PY'
from pathlib import Path
import sys

out = Path(sys.argv[1])
size_mib = int(sys.argv[2])
logo_enable = b"1" if sys.argv[3] == "YES" else b"0"
board = sys.argv[4]
binary_marker = sys.argv[5].encode()
firmware_layout = sys.argv[6]
mib = 1024 * 1024
sector = 512
idb_offset = 0x40 * sector
uboot_offset = 0x4000 * sector
logo_offset = 0x6000 * sector
logo_read_size = 0x961 * sector
env_offset = 0xf80000
env_offset_redund = 0xf90000
env_size = 0x10000
env_reserve_end = 16 * mib

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

logo = (out / "logo.bmp").read_bytes()
if logo[:2] != b"BM" or int.from_bytes(logo[2:6], "little") != len(logo):
    raise SystemExit("logo.bmp has an invalid BMP header or file size")
logo_raw = logo + b"\xff" * (-len(logo) % sector)
if len(logo_raw) > logo_read_size:
    raise SystemExit(
        f"logo.bmp needs {len(logo_raw)} bytes, "
        f"but U-Boot reads only {logo_read_size}"
    )

config = (out / "u-boot.config").read_text(encoding="utf-8")
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

idb = (out / "idbloader.img").read_bytes()
uboot = (out / "u-boot.itb").read_bytes()
if firmware_layout == "spi":
    spi = (out / "u-boot-rockchip-spi.bin").read_bytes()
    spi_uboot_offset = int(next(
        line.split("=", 1)[1] for line in config.splitlines()
        if line.startswith("CONFIG_SYS_SPI_U_BOOT_OFFS=")
    ), 0)
    if spi[spi_uboot_offset:spi_uboot_offset + 4] != b"\xd0\x0d\xfe\xed":
        raise SystemExit("SPI image lacks FIT at CONFIG_SYS_SPI_U_BOOT_OFFS")
    limits = (
        ("u-boot-rockchip-spi.bin", 0, spi, logo_offset),
        ("logo.img", logo_offset, logo_raw, env_offset),
    )
    boot_layout = (
        f"u-boot-rockchip-spi.bin: offset 0x0, {len(spi)} bytes, "
        "limit 12 MiB\n"
        f"SPL payload: 0x{spi_uboot_offset:x}\n"
    )
else:
    limits = (
        ("idbloader.img", idb_offset, idb, uboot_offset),
        ("u-boot.itb", uboot_offset, uboot, logo_offset),
        ("logo.img", logo_offset, logo_raw, env_offset),
    )
    boot_layout = (
        f"idbloader.img: LBA 0x40, {len(idb)} bytes, limit 8 MiB\n"
        f"u-boot.itb: LBA 0x4000, {len(uboot)} bytes, limit 12 MiB\n"
    )
for name, offset, data, limit in limits:
    if offset + len(data) > limit:
        raise SystemExit(
            f"{name} ends at {offset + len(data)} bytes, "
            f"past its {limit}-byte limit"
        )

firmware = bytearray(b"\xff") * (size_mib * mib)
for _, offset, data, _ in limits:
    firmware[offset:offset + len(data)] = data

firmware_name = f"{board}-uboot-{size_mib}m.bin"
(out / firmware_name).write_bytes(firmware)
(out / "firmware-update.bin").write_bytes(firmware[:env_offset])
(out / "logo.img").write_bytes(logo_raw)
(out / "FIRMWARE-LAYOUT.txt").write_text(
    f"Firmware size: {size_mib} MiB\n"
    "Fill byte: 0xff\n"
    f"Firmware layout: {firmware_layout}\n"
    f"{boot_layout}"
    f"logo.img: LBA 0x6000, {len(logo_raw)} bytes, "
    f"limit {env_offset} bytes\n"
    f"environment primary: 0x{env_offset:x}, {env_size} bytes\n"
    f"environment redundant: 0x{env_offset_redund:x}, {env_size} bytes\n"
    f"environment reserved area: 0x{env_offset:x}-0x{env_reserve_end:x}\n"
    f"firmware-update.bin: 0x0-0x{env_offset:x}; preserves environment\n"
)
PY

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
Firmware image: ${BOARD}-uboot-${FIRMWARE_MIB}m.bin
Firmware update image: firmware-update.bin
Firmware size: ${FIRMWARE_MIB} MiB
Firmware layout: ${UBOOT_FIRMWARE_LAYOUT}
EOF

(
	cd "${OUT}"
	sha256 idbloader.img u-boot.itb u-boot.bin u-boot.config \
	    uboot-control.dtb freebsd-runtime.dtb \
	    logo.bmp logo.img \
	    "${BOARD}-uboot-${FIRMWARE_MIB}m.bin" \
	    firmware-update.bin \
	    ${SPI_FIRMWARE_FILE} \
	    FIRMWARE-LAYOUT.txt BUILD-INFO.txt > SHA256SUMS
)

if [ -e "${FINAL_OUT}" ]; then
	mkdir -p "${HOME}/ready-to-delete"
	mv "${FINAL_OUT}" \
	    "${HOME}/ready-to-delete/${FINAL_OUT##*/}-$(date +%Y%m%d-%H%M%S)-$$"
fi
mv "${OUT}" "${FINAL_OUT}"
STAGING_OUT=
OUT=${FINAL_OUT}

ln -sfn "${OUT}" "${WORK_ROOT}/uboot-latest"
mkdir -p "${VERSION_OUTPUT_ROOT}"
PUBLISH_OUT=${VERSION_OUTPUT_ROOT}/${FINAL_OUT##*/}
PUBLISH_STAGING=$(mktemp -d "${VERSION_OUTPUT_ROOT}/.${FINAL_OUT##*/}.XXXXXX")
(cd "${OUT}" && tar -cpf - .) | (cd "${PUBLISH_STAGING}" && tar -xpf -)
if [ -e "${PUBLISH_OUT}" ]; then
	mkdir -p "${HOME}/ready-to-delete"
	mv "${PUBLISH_OUT}" \
	    "${HOME}/ready-to-delete/output-${PUBLISH_OUT##*/}-$(date +%Y%m%d-%H%M%S)-$$"
fi
mv "${PUBLISH_STAGING}" "${PUBLISH_OUT}"
PUBLISH_STAGING=
echo "== ${BOARD} U-Boot ${UBOOT_VERSION} complete bundle =="
ls -lh "${OUT}/idbloader.img" "${OUT}/u-boot.itb" \
    "${OUT}/logo.img" \
    "${OUT}/firmware-update.bin" \
    "${OUT}/${BOARD}-uboot-${FIRMWARE_MIB}m.bin"
[ -z "${SPI_FIRMWARE_FILE}" ] || ls -lh "${OUT}/${SPI_FIRMWARE_FILE}"
echo "${OUT}"
echo "${PUBLISH_OUT}"
