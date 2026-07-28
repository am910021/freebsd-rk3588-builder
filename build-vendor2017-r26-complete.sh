#!/bin/sh
set -eu

BUILDER_ROOT=${BUILDER_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}
BUILDER_CONFIG=${BUILDER_CONFIG:-${BUILDER_ROOT}/builder.conf}
[ -r "${BUILDER_CONFIG}" ] || {
	echo "${0##*/}: missing config: ${BUILDER_CONFIG}" >&2
	exit 1
}
. "${BUILDER_CONFIG}"

case $# in
	0) ;;
	1) FIRMWARE_MIB=$1 ;;
	*)
		echo "usage: ${0##*/} [16|32]" >&2
		exit 1
		;;
esac
case "${FIRMWARE_MIB}" in
	16|32) ;;
	*)
		echo "${0##*/}: firmware size must be 16 or 32 MiB" >&2
		exit 1
		;;
esac

FINAL_OUT=${OUTPUT_ROOT}/uboot-r26-${FIRMWARE_MIB}m
WORK=${WORK:-}
LOGO_BMP=${LOGO_BMP:-${UBOOT_LOGO_BMP}}

fail()
{
	echo "${0##*/}: $*" >&2
	exit 1
}

for file in "${IDBLOADER_SRC}" "${KERNEL_DTB}" "${MENU_CMD}" \
    "${LOGO_BMP}"; do
	[ -f "${file}" ] || fail "missing input: ${file}"
done
[ -d "${VENDOR_SRC}" ] || fail "missing source: ${VENDOR_SRC}"
[ -d "${RKBIN_DIR}" ] || fail "missing rkbin: ${RKBIN_DIR}"
[ -x "${MKIMAGE}" ] || fail "not executable: ${MKIMAGE}"
for cmd in git rsync gmake gsed mktemp python3 sha256 \
    "${CROSS_COMPILE}gcc"; do
	command -v "${cmd}" >/dev/null 2>&1 || fail "missing command: ${cmd}"
done

SOURCE_BRANCH=$(git -C "${VENDOR_SRC}" symbolic-ref --short HEAD)
SOURCE_COMMIT=$(git -C "${VENDOR_SRC}" rev-parse HEAD)
[ "${SOURCE_BRANCH}" = "yuri/nanopc-t6_lts" ] ||
    fail "unexpected source branch: ${SOURCE_BRANCH}"
[ -z "$(git -C "${VENDOR_SRC}" status --porcelain)" ] ||
    fail "source tree is not clean: ${VENDOR_SRC}"

AUTO_WORK=0
STAGING_OUT=
if [ -z "${WORK}" ]; then
	WORK=$(mktemp -d "${TMPDIR:-/tmp}/nanopc-t6-uboot.XXXXXX")
	AUTO_WORK=1
else
	[ ! -e "${WORK}" ] || fail "work directory already exists: ${WORK}"
	mkdir -p "${WORK}"
fi
cleanup()
{
	if [ -n "${STAGING_OUT}" ]; then
		rm -rf "${STAGING_OUT}"
	fi
	if [ "${AUTO_WORK}" = "1" ]; then
		rm -rf "${WORK}"
	fi
}
trap cleanup EXIT INT TERM

mkdir -p "${OUTPUT_ROOT}"
STAGING_OUT=$(mktemp -d \
    "${OUTPUT_ROOT}/.uboot-r26-${FIRMWARE_MIB}m.XXXXXX")
OUT=${STAGING_OUT}
BUILD_SRC="${WORK}/u-boot"
rsync -aH --delete \
    --exclude '.git' \
    --exclude '/build-tools' \
    --exclude '/.config' \
    --exclude '/include/generated' \
    --exclude '/spl' \
    --exclude '/tpl' \
    --exclude '/u-boot' \
    --exclude '/u-boot.bin' \
    --exclude '/u-boot.cfg' \
    --exclude '/u-boot.config' \
    --exclude '/u-boot.dtb' \
    --exclude '/u-boot.its' \
    --exclude '/u-boot.itb' \
    --exclude '/u-boot.map' \
    --exclude '/u-boot.sym' \
    "${VENDOR_SRC}/" "${BUILD_SRC}/"
ln -s "${RKBIN_DIR}" "${WORK}/rkbin"
mkdir -p "${BUILD_SRC}/build-tools"
ln -s /usr/local/bin/gmake "${BUILD_SRC}/build-tools/make"
ln -s /usr/local/bin/gsed "${BUILD_SRC}/build-tools/sed"

(
	cd "${BUILD_SRC}"
	PATH="${BUILD_SRC}/build-tools:${PATH}" \
	    gmake CROSS_COMPILE="${CROSS_COMPILE}" nanopi6_defconfig
	cp -p "${KERNEL_DTB}" dts/kern.dtb
	grep -q '^CONFIG_EMBED_KERNEL_DTB=y$' .config ||
	    echo 'CONFIG_EMBED_KERNEL_DTB=y' >> .config
	PATH="${BUILD_SRC}/build-tools:${PATH}" \
	    gmake CROSS_COMPILE="${CROSS_COMPILE}" olddefconfig
	PATH="${BUILD_SRC}/build-tools:${PATH}" \
	    gmake CROSS_COMPILE="${CROSS_COMPILE}" -j"${JOBS}"
	PATH="${BUILD_SRC}/build-tools:${PATH}" \
	    ./make.sh "CROSS_COMPILE=${CROSS_COMPILE}" itb
)

for file in u-boot.itb u-boot.bin .config include/configs/nanopi6.h \
    dts/kern.dtb; do
	[ -f "${BUILD_SRC}/${file}" ] ||
	    fail "build did not produce: ${file}"
done

cp -p "${IDBLOADER_SRC}" "${OUT}/idbloader.img"
cp -p "${BUILD_SRC}/u-boot.itb" "${OUT}/u-boot.itb"
cp -p "${BUILD_SRC}/u-boot.bin" "${OUT}/u-boot.bin"
cp -p "${BUILD_SRC}/.config" "${OUT}/u-boot.config"
cp -p "${BUILD_SRC}/include/configs/nanopi6.h" "${OUT}/nanopi6.h"
cp -p "${BUILD_SRC}/dts/kern.dtb" \
    "${OUT}/rk3588-nanopi6-rev07.dtb"
if [ -f "${BUILD_SRC}/u-boot.its" ]; then
	cp -p "${BUILD_SRC}/u-boot.its" "${OUT}/u-boot.its"
fi

cat > "${OUT}/BUILD-INFO.txt" <<EOF
Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Builder root: ${BUILDER_ROOT}
Vendor source: ${VENDOR_SRC}
rkbin: ${RKBIN_DIR}
idbloader: ${IDBLOADER_SRC}
Embedded kernel DTB: ${KERNEL_DTB}
Cross compile: ${CROSS_COMPILE}
Jobs: ${JOBS}
Work dir: ${WORK}
Output dir: ${FINAL_OUT}
EOF

cp -p "${LOGO_BMP}" "${OUT}/logo.bmp"
cp -p "${MENU_CMD}" "${OUT}/dualboot.cmd"
"${MKIMAGE}" -A arm -T script -C none \
    -n "NanoPC-T6 FreeBSD14 R26 bootmenu 3s" \
    -d "${OUT}/dualboot.cmd" "${OUT}/dualboot.scr" >/dev/null

python3 - "${OUT}" <<'PY'
from pathlib import Path
import sys

out = Path(sys.argv[1])
script = (out / "dualboot.scr").read_bytes()
if len(script) < 72 or script[68:72] != b"\0\0\0\0":
    raise SystemExit("dualboot.scr lacks the standard zero terminator")

binary = (out / "u-boot.bin").read_bytes()
for marker in (
    b"NanoPC-T6-SD-FULL-R26-BOOTMENU-3S",
    b"NanoPC-T6 LTS SD full U-Boot R26-BOOTMENU-3S",
    b"bootmenu_delay=3",
    b"LOGO: raw blocks",
):
    if marker not in binary:
        raise SystemExit(f"u-boot.bin lacks marker: {marker!r}")

command = (out / "dualboot.cmd").read_text()
for marker in ("R26-BOOTMENU-3S", "bootmenu_delay 3", "bootmenu 3"):
    if marker not in command:
        raise SystemExit(f"dualboot.cmd lacks marker: {marker!r}")
PY

python3 - "${OUT}" "${FIRMWARE_MIB}" <<'PY'
from pathlib import Path
import sys

out = Path(sys.argv[1])
size_mib = int(sys.argv[2])
layouts = {
    16: (12, 12, 4),
    32: (16, 16, 16),
}
uboot_limit_mib, logo_start_mib, logo_size_mib = layouts[size_mib]
mib = 1024 * 1024
sector = 512
idb_offset = 0x40 * sector
uboot_offset = 0x4000 * sector
idb_limit = 8 * mib
uboot_limit = uboot_limit_mib * mib
logo_offset = logo_start_mib * mib
logo_limit = (logo_start_mib + logo_size_mib) * mib

idb = (out / "idbloader.img").read_bytes()
uboot = (out / "u-boot.itb").read_bytes()
logo = (out / "logo.bmp").read_bytes()
if logo[:2] != b"BM" or int.from_bytes(logo[2:6], "little") != len(logo):
    raise SystemExit("logo.bmp has an invalid BMP header or file size")
logo_raw = logo + b"\xff" * (-len(logo) % sector) + logo

for name, offset, data, limit in (
    ("idbloader.img", idb_offset, idb, idb_limit),
    ("u-boot.itb", uboot_offset, uboot, uboot_limit),
    ("logo.img", logo_offset, logo_raw, logo_limit),
):
    if offset + len(data) > limit:
        raise SystemExit(
            f"{name} ends at {offset + len(data)} bytes, "
            f"past its {limit}-byte limit"
        )

firmware = bytearray(b"\xff") * (size_mib * mib)
firmware[idb_offset:idb_offset + len(idb)] = idb
firmware[uboot_offset:uboot_offset + len(uboot)] = uboot
firmware[logo_offset:logo_offset + len(logo_raw)] = logo_raw

firmware_name = f"nanopc-t6-lts-uboot-{size_mib}m.bin"
(out / firmware_name).write_bytes(firmware)
(out / "logo.img").write_bytes(logo_raw)
(out / "FIRMWARE-LAYOUT.txt").write_text(
    f"Firmware size: {size_mib} MiB\n"
    f"Fill byte: 0xff\n"
    f"idbloader.img: LBA 0x40, {len(idb)} bytes, limit 8 MiB\n"
    f"u-boot.itb: LBA 0x4000, {len(uboot)} bytes, "
    f"limit {uboot_limit_mib} MiB\n"
    f"logo.img: LBA 0x{logo_offset // sector:x}, "
    f"{len(logo_raw)} bytes, region {logo_size_mib} MiB\n"
)
PY

"${MKIMAGE}" -l "${OUT}/dualboot.scr" >/dev/null
cat >> "${OUT}/BUILD-INFO.txt" <<EOF

Complete bundle: NanoPC-T6 LTS vendor U-Boot 2017 R26
Source branch: ${SOURCE_BRANCH}
Source commit: ${SOURCE_COMMIT}
Built-in menu timeout: 3 seconds
ESP menu: ${MENU_CMD}
ESP menu timeout: 3 seconds
Logo: ${LOGO_BMP}
Firmware image: nanopc-t6-lts-uboot-${FIRMWARE_MIB}m.bin
Firmware size: ${FIRMWARE_MIB} MiB
EOF

(
	cd "${OUT}"
	sha256 idbloader.img u-boot.itb u-boot.bin u-boot.config nanopi6.h \
	    rk3588-nanopi6-rev07.dtb logo.bmp dualboot.cmd dualboot.scr \
	    logo.img nanopc-t6-lts-uboot-${FIRMWARE_MIB}m.bin \
	    FIRMWARE-LAYOUT.txt BUILD-INFO.txt \
	    > SHA256SUMS
)

rm -rf "${FINAL_OUT}"
mv "${OUT}" "${FINAL_OUT}"
STAGING_OUT=
OUT=${FINAL_OUT}

ln -sfn "${OUT}" "${OUTPUT_ROOT}/uboot-latest"
echo "== R26 complete bundle =="
ls -lh "${OUT}/idbloader.img" "${OUT}/u-boot.itb" \
    "${OUT}/logo.img" \
    "${OUT}/nanopc-t6-lts-uboot-${FIRMWARE_MIB}m.bin" \
    "${OUT}/dualboot.cmd" "${OUT}/dualboot.scr"
echo "${OUT}"
