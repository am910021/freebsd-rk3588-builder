#!/bin/sh
set -eu

BUILDER_ROOT=${BUILDER_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}
BUILDER_CONFIG=${BUILDER_CONFIG:-${BUILDER_ROOT}/builder.conf}
[ -r "${BUILDER_CONFIG}" ] || {
	echo "${0##*/}: missing config: ${BUILDER_CONFIG}" >&2
	exit 1
}
. "${BUILDER_CONFIG}"

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

FINAL_OUT=${WORK_ROOT}/uboot-2026.07-${FIRMWARE_MIB}m
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

for file in "${UBOOT_BL31}" "${UBOOT_ROCKCHIP_TPL}" "${MENU_CMD}" \
    "${LOGO_BMP}" "${FREEBSD_DTS}"; do
	[ -f "${file}" ] || fail "missing input: ${file}"
done
[ -d "${UBOOT_SRC_DIR}" ] || fail "missing source: ${UBOOT_SRC_DIR}"
[ -x "${MKIMAGE}" ] || fail "not executable: ${MKIMAGE}"
for cmd in git gmake mktemp python3 sha256; do
	command -v "${cmd}" >/dev/null 2>&1 || fail "missing command: ${cmd}"
done
command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1 ||
    fail "missing compiler: ${CROSS_COMPILE}gcc"

SOURCE_BRANCH=$(git -C "${UBOOT_SRC_DIR}" symbolic-ref --short HEAD)
SOURCE_COMMIT=$(git -C "${UBOOT_SRC_DIR}" rev-parse HEAD)
[ "${SOURCE_BRANCH}" = "${UBOOT_BRANCH}" ] ||
    fail "unexpected source branch: ${SOURCE_BRANCH}"
[ -z "$(git -C "${UBOOT_SRC_DIR}" status --porcelain)" ] ||
    fail "source tree is not clean: ${UBOOT_SRC_DIR}"

mkdir -p "${WORK_ROOT}/tmp"
AUTO_WORK=0
STAGING_OUT=
if [ -z "${WORK}" ]; then
	WORK=$(mktemp -d "${WORK_ROOT}/tmp/nanopc-t6-uboot.XXXXXX")
	AUTO_WORK=1
else
	[ ! -e "${WORK}" ] || fail "work directory already exists: ${WORK}"
	mkdir -p "${WORK}"
fi
cleanup()
{
	[ -z "${STAGING_OUT}" ] || rm -rf "${STAGING_OUT}"
	[ "${AUTO_WORK}" = "0" ] || rm -rf "${WORK}"
}
trap cleanup EXIT INT TERM

STAGING_OUT=$(mktemp -d \
    "${WORK_ROOT}/tmp/uboot-2026.07-${FIRMWARE_MIB}m.XXXXXX")
OUT=${STAGING_OUT}
BUILD_DIR=${WORK}/build

gmake -C "${UBOOT_SRC_DIR}" O="${BUILD_DIR}" \
    CROSS_COMPILE="${CROSS_COMPILE}" nanopc-t6-rk3588_defconfig
"${UBOOT_SRC_DIR}/scripts/config" --file "${BUILD_DIR}/.config" \
    --disable TOOLS_MKEFICAPSULE
"${UBOOT_SRC_DIR}/scripts/config" --file "${BUILD_DIR}/.config" \
    "${LOGO_CONFIG}" NANOPC_T6_SHOW_LOGO
gmake -C "${UBOOT_SRC_DIR}" O="${BUILD_DIR}" \
    CROSS_COMPILE="${CROSS_COMPILE}" olddefconfig
gmake -C "${UBOOT_SRC_DIR}" O="${BUILD_DIR}" \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    BL31="${UBOOT_BL31}" ROCKCHIP_TPL="${UBOOT_ROCKCHIP_TPL}" \
    -j"${JOBS}"

for file in idbloader.img u-boot.itb u-boot.bin u-boot.dtb .config; do
	[ -f "${BUILD_DIR}/${file}" ] ||
	    fail "build did not produce: ${file}"
done

FREEBSD_DTS_PP=${WORK}/rk3588-nanopc-t6-lts-freebsd.pp.dts
"${CROSS_COMPILE}gcc" -E -nostdinc -undef -D__DTS__ \
    -x assembler-with-cpp \
    -I"${UBOOT_SRC_DIR}/dts/upstream/src/arm64/rockchip" \
    -I"${UBOOT_SRC_DIR}/dts/upstream/src/arm64" \
    -I"${UBOOT_SRC_DIR}/dts/upstream/src" \
    -I"${UBOOT_SRC_DIR}/dts/upstream/include" \
    "${FREEBSD_DTS}" > "${FREEBSD_DTS_PP}"
"${BUILD_DIR}/scripts/dtc/dtc" -@ -I dts -O dtb \
    -o "${OUT}/freebsd-runtime.dtb" "${FREEBSD_DTS_PP}"

cp -p "${BUILD_DIR}/idbloader.img" "${OUT}/idbloader.img"
cp -p "${BUILD_DIR}/u-boot.itb" "${OUT}/u-boot.itb"
cp -p "${BUILD_DIR}/u-boot.bin" "${OUT}/u-boot.bin"
cp -p "${BUILD_DIR}/u-boot.dtb" "${OUT}/uboot-control.dtb"
cp -p "${BUILD_DIR}/.config" "${OUT}/u-boot.config"
cp -p "${LOGO_BMP}" "${OUT}/logo.bmp"
cp -p "${MENU_CMD}" "${OUT}/dualboot.cmd"
"${MKIMAGE}" -A arm -T script -C none \
    -n "NanoPC-T6 FreeBSD14 U-Boot 2026.07 menu 3s" \
    -d "${OUT}/dualboot.cmd" "${OUT}/dualboot.scr" >/dev/null

python3 - "${OUT}" "${FIRMWARE_MIB}" "${UBOOT_LOGO_ENABLE}" <<'PY'
from pathlib import Path
import sys

out = Path(sys.argv[1])
size_mib = int(sys.argv[2])
logo_enable = b"1" if sys.argv[3] == "YES" else b"0"
mib = 1024 * 1024
sector = 512
idb_offset = 0x40 * sector
uboot_offset = 0x4000 * sector
logo_offset = 0x6000 * sector
logo_read_size = 0x961 * sector

script = (out / "dualboot.scr").read_bytes()
if len(script) < 72 or script[68:72] != b"\0\0\0\0":
    raise SystemExit("dualboot.scr lacks the standard zero terminator")

binary = (out / "u-boot.bin").read_bytes()
for marker in (
    b"NanoPC-T6-LTS-2026.07",
    b"bootmenu_delay=3",
    b"logo_enable=" + logo_enable,
    b"show_logo=",
    b"boot_freebsd=",
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

idb = (out / "idbloader.img").read_bytes()
uboot = (out / "u-boot.itb").read_bytes()
limits = (
    ("idbloader.img", idb_offset, idb, 8 * mib),
    ("u-boot.itb", uboot_offset, uboot, logo_offset),
    ("logo.img", logo_offset, logo_raw, size_mib * mib),
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

firmware_name = f"nanopc-t6-lts-uboot-{size_mib}m.bin"
(out / firmware_name).write_bytes(firmware)
(out / "logo.img").write_bytes(logo_raw)
(out / "FIRMWARE-LAYOUT.txt").write_text(
    f"Firmware size: {size_mib} MiB\n"
    "Fill byte: 0xff\n"
    f"idbloader.img: LBA 0x40, {len(idb)} bytes, limit 8 MiB\n"
    f"u-boot.itb: LBA 0x4000, {len(uboot)} bytes, limit 12 MiB\n"
    f"logo.img: LBA 0x6000, {len(logo_raw)} bytes, "
    f"region {size_mib - 12} MiB\n"
)
PY

cat > "${OUT}/BUILD-INFO.txt" <<EOF
Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Builder root: ${BUILDER_ROOT}
U-Boot source: ${UBOOT_SRC_DIR}
Source branch: ${SOURCE_BRANCH}
Source commit: ${SOURCE_COMMIT}
BL31: ${UBOOT_BL31}
Rockchip TPL: ${UBOOT_ROCKCHIP_TPL}
Cross compile: ${CROSS_COMPILE}
Jobs: ${JOBS}
Logo: ${LOGO_BMP}
Logo enabled: ${UBOOT_LOGO_ENABLE}
ESP menu: ${MENU_CMD}
FreeBSD DTS: ${FREEBSD_DTS}
Firmware image: nanopc-t6-lts-uboot-${FIRMWARE_MIB}m.bin
Firmware size: ${FIRMWARE_MIB} MiB
EOF

(
	cd "${OUT}"
	sha256 idbloader.img u-boot.itb u-boot.bin u-boot.config \
	    uboot-control.dtb freebsd-runtime.dtb \
	    logo.bmp logo.img dualboot.cmd dualboot.scr \
	    nanopc-t6-lts-uboot-${FIRMWARE_MIB}m.bin \
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
echo "== U-Boot 2026.07 complete bundle =="
ls -lh "${OUT}/idbloader.img" "${OUT}/u-boot.itb" \
    "${OUT}/logo.img" \
    "${OUT}/nanopc-t6-lts-uboot-${FIRMWARE_MIB}m.bin"
echo "${OUT}"
