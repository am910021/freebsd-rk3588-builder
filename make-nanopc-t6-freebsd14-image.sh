#!/bin/sh
set -eu

BUILDER_ROOT=${BUILDER_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}
BUILDER_CONFIG=${BUILDER_CONFIG:-${BUILDER_ROOT}/builder.conf}
[ -r "${BUILDER_CONFIG}" ] || {
	echo "${0##*/}: missing config: ${BUILDER_CONFIG}" >&2
	exit 1
}
. "${BUILDER_CONFIG}"

STAMP=${STAMP:-$(date +%Y%m%d-%H%M%S)}
DTB=${DTB:-${IMAGE_DTB}}
LOGO_BMP=${LOGO_BMP:-${IMAGE_LOGO_BMP}}
OUT=${OUT:-${OUTPUT_ROOT}/nanopc-t6-lts-freebsd14.3-r26-${STAMP}.img}
WORK=${WORK:-}

usage()
{
	echo "usage: ${0##*/} [base.txz kernel.txz if_rge.txz [output.img]]" >&2
	exit 1
}

case $# in
	0) ;;
	3)
		BASE_TXZ=$1
		KERNEL_TXZ=$2
		RGE_TXZ=$3
		;;
	4)
		BASE_TXZ=$1
		KERNEL_TXZ=$2
		RGE_TXZ=$3
		OUT=$4
		;;
	*) usage ;;
esac

UBOOT_BIN=${UBOOT_DIR}/nanopc-t6-lts-uboot-${FIRMWARE_MIB}m.bin
IDBLOADER=${UBOOT_DIR}/idbloader.img
UBOOT_ITB=${UBOOT_DIR}/u-boot.itb
DUALBOOT_CMD=${UBOOT_DIR}/dualboot.cmd
DUALBOOT_SCR=${UBOOT_DIR}/dualboot.scr
ROOT_LABEL=nanopc_t6_root

SECTORS_PER_MIB=2048
ESP_END_MIB=$((FIRMWARE_MIB + ESP_SIZE_MIB))
SWAP_END_MIB=$((ESP_END_MIB + SWAP_SIZE_MIB))
ROOT_END_MIB=$((SWAP_END_MIB + ROOT_SIZE_MIB))
IMAGE_SIZE_MIB=$((ROOT_END_MIB + IMAGE_TAIL_MIB))

ESP_START=$((FIRMWARE_MIB * SECTORS_PER_MIB))
ESP_SECTORS=$((ESP_SIZE_MIB * SECTORS_PER_MIB))
SWAP_START=$((ESP_END_MIB * SECTORS_PER_MIB))
SWAP_SECTORS=$((SWAP_SIZE_MIB * SECTORS_PER_MIB))
ROOT_START=$((SWAP_END_MIB * SECTORS_PER_MIB))
ROOT_SECTORS=$((ROOT_SIZE_MIB * SECTORS_PER_MIB))
TOTAL_SECTORS=$((IMAGE_SIZE_MIB * SECTORS_PER_MIB))

md=
root_mnt=
esp_mnt=
AUTO_WORK=0

die()
{
	echo "${0##*/}: $*" >&2
	exit 1
}

case "${FIRMWARE_MIB}" in
	16|32) ;;
	*) die "firmware size must be 16 or 32 MiB" ;;
esac

if [ -z "${RGE_TXZ}" ]; then
	for candidate in "${TXZ_ROOT}"/if_rge*.txz; do
		[ -f "${candidate}" ] || continue
		[ -z "${RGE_TXZ}" ] ||
		    die "multiple if_rge packages in ${TXZ_ROOT}"
		RGE_TXZ=${candidate}
	done
	[ -n "${RGE_TXZ}" ] ||
	    die "no if_rge package found in ${TXZ_ROOT}"
fi

cleanup()
{
	if [ -n "${esp_mnt}" ]; then
		umount "${esp_mnt}" >/dev/null 2>&1 || true
	fi
	if [ -n "${root_mnt}" ]; then
		umount "${root_mnt}" >/dev/null 2>&1 || true
	fi
	if [ -n "${md}" ]; then
		mdconfig -d -u "${md#md}" >/dev/null 2>&1 || true
	fi
	if [ "${AUTO_WORK}" = "1" ]; then
		rm -rf "${WORK}"
	fi
}

for file in "${BASE_TXZ}" "${KERNEL_TXZ}" "${RGE_TXZ}" "${UBOOT_BIN}" \
    "${IDBLOADER}" "${UBOOT_ITB}" "${DUALBOOT_CMD}" "${DUALBOOT_SCR}" \
    "${DTB}" "${LOGO_BMP}"; do
	[ -f "${file}" ] || die "missing input: ${file}"
done
[ ! -e "${OUT}" ] || die "output already exists: ${OUT}"

for cmd in mdconfig gpart newfs newfs_msdos mount umount tar \
    truncate dd mktemp sha256 mkimage python3 fsck_msdosfs fsck_ufs; do
	command -v "${cmd}" >/dev/null 2>&1 || die "missing command: ${cmd}"
done

if [ -z "${WORK}" ]; then
	WORK=$(mktemp -d "${TMPDIR:-/tmp}/nanopc-t6-image.XXXXXX")
	AUTO_WORK=1
else
	[ ! -e "${WORK}" ] || die "work directory already exists: ${WORK}"
	mkdir -p "${WORK}"
fi
trap cleanup EXIT INT TERM

mkdir -p "$(dirname "${OUT}")"
root_mnt="${WORK}/root"
esp_mnt="${WORK}/esp"
mkdir -p "${root_mnt}" "${esp_mnt}"

echo "== Creating GPT image =="
truncate -s $((TOTAL_SECTORS * 512)) "${OUT}"
echo "== Installing complete ${FIRMWARE_MIB} MiB U-Boot R26 firmware =="
dd if="${UBOOT_BIN}" of="${OUT}" bs=1m conv=notrunc,sync status=none
md=$(mdconfig -a -t vnode -f "${OUT}")
gpart create -s gpt "${md}"
gpart add -b "${ESP_START}" -s "${ESP_SECTORS}" -t efi -l EFI "${md}"
gpart add -b "${SWAP_START}" -s "${SWAP_SECTORS}" -t freebsd-swap \
    -l growfs_swap "${md}"
gpart add -b "${ROOT_START}" -s "${ROOT_SECTORS}" -t freebsd-ufs \
    -l freebsd_root "${md}"

echo "== Installing FreeBSD 14.3 root filesystem =="
newfs -U -L "${ROOT_LABEL}" "/dev/${md}p3" >/dev/null
mount "/dev/${md}p3" "${root_mnt}"
tar -xpf "${BASE_TXZ}" -C "${root_mnt}"
tar -xpf "${KERNEL_TXZ}" -C "${root_mnt}"
tar -xpf "${RGE_TXZ}" -C "${root_mnt}"
if [ -d "${BOARD_FILES_DIR}" ]; then
	(cd "${BOARD_FILES_DIR}" && tar -cpf - .) |
	    (cd "${root_mnt}" && tar -xpf -)
fi
[ -f "${root_mnt}/boot/modules/if_rge.ko" ] ||
    die "if_rge package did not install /boot/modules/if_rge.ko"

mkdir -p "${root_mnt}/boot/efi" "${root_mnt}/tmp" \
    "${root_mnt}/var/log" "${root_mnt}/var/tmp"
touch "${root_mnt}/firstboot"

cat > "${root_mnt}/etc/fstab" <<'EOF'
/dev/ufs/nanopc_t6_root	/		ufs	rw,noatime		1 1
/dev/msdosfs/EFI		/boot/efi	msdosfs	rw,noatime,noauto	0 0
/dev/gpt/growfs_swap		none		swap	sw			0 0
md				/tmp		mfs	rw,noatime,-s256m	0 0
md				/var/log	mfs	rw,noatime,-s64m	0 0
md				/var/tmp	mfs	rw,noatime,-s64m	0 0
EOF

cat > "${root_mnt}/etc/rc.conf" <<'EOF'
hostname="nanopc-t6"
ifconfig_DEFAULT="DHCP"
sshd_enable="YES"
growfs_enable="YES"
powerd_enable="YES"
sendmail_enable="NONE"
sendmail_submit_enable="NO"
sendmail_outbound_enable="NO"
sendmail_msp_queue_enable="NO"
EOF

cat > "${root_mnt}/boot/loader.conf" <<'EOF'
boot_multicons="YES"
boot_serial="YES"
beastie_disable="NO"
loader_color="NO"
console="comconsole,efi"
comconsole_speed="1500000"
autoboot_delay="10"
hw.rk3588.efi_fdt_highmem="1"
kern.msgbuf_show_timestamp="2"
kern.msgbufsize="1048576"
if_rge_load="YES"
if_rge_name="/boot/modules/if_rge.ko"
EOF

base_sha=$(sha256 -q "${BASE_TXZ}")
kernel_sha=$(sha256 -q "${KERNEL_TXZ}")
rge_sha=$(sha256 -q "${RGE_TXZ}")
firmware_sha=$(sha256 -q "${UBOOT_BIN}")
idb_sha=$(sha256 -q "${IDBLOADER}")
uboot_sha=$(sha256 -q "${UBOOT_ITB}")
dtb_sha=$(sha256 -q "${DTB}")
logo_sha=$(sha256 -q "${LOGO_BMP}")
src_commit=$(git -C /usr/src rev-parse --short HEAD 2>/dev/null || echo unknown)

cat > "${root_mnt}/etc/nanopc-t6-image-build.txt" <<EOF
FreeBSD source commit: ${src_commit}
base.txz: ${base_sha}
kernel.txz: ${kernel_sha}
if_rge.txz: ${rge_sha}
firmware.bin: ${firmware_sha}
idbloader.img: ${idb_sha}
u-boot.itb: ${uboot_sha}
rk3588-nanopc-t6.dtb: ${dtb_sha}
logo.bmp: ${logo_sha}
EOF

sync
df -h "${root_mnt}"
umount "${root_mnt}"
root_mnt=

echo "== Installing ESP =="
newfs_msdos -L EFI -F 16 "/dev/${md}p1" >/dev/null
mount -t msdosfs "/dev/${md}p1" "${esp_mnt}"
mkdir -p "${esp_mnt}/EFI/BOOT" "${esp_mnt}/EFI/FreeBSD" \
    "${esp_mnt}/EFI/overlays" "${esp_mnt}/dtb"

loader_tmp="${WORK}/loader.efi"
root_mnt="${WORK}/root"
mount -o ro "/dev/${md}p3" "${root_mnt}"
[ -e "${root_mnt}/firstboot" ] || die "missing firstboot sentinel"
cp -p "${root_mnt}/boot/loader.efi" "${loader_tmp}"
for overlay in ${UBOOT_FDT_OVERLAYS}; do
	case "${overlay}" in
		*.dtbo) ;;
		*) die "overlay name must end in .dtbo: ${overlay}" ;;
	esac
	case "${overlay}" in
		*/*|*..*) die "invalid overlay name: ${overlay}" ;;
	esac
	overlay_src="${root_mnt}/boot/dtb/overlays/${overlay}"
	[ -f "${overlay_src}" ] || die "missing overlay: ${overlay_src}"
	cp -p "${overlay_src}" "${esp_mnt}/EFI/overlays/${overlay}"
done
umount "${root_mnt}"
root_mnt=

printf 'fdt_overlays=%s\n' "${UBOOT_FDT_OVERLAYS}" \
    > "${esp_mnt}/EFI/overlays.conf"
cp -p "${loader_tmp}" "${esp_mnt}/EFI/BOOT/BOOTAA64.EFI"
cp -p "${loader_tmp}" "${esp_mnt}/EFI/FreeBSD/loader.efi"
cp -p "${DTB}" "${esp_mnt}/dtb/rk3588-nanopc-t6.dtb"

cp -p "${DUALBOOT_CMD}" "${esp_mnt}/dualboot.cmd"
cp -p "${DUALBOOT_SCR}" "${esp_mnt}/dualboot.scr"
cp -p "${DUALBOOT_CMD}" "${esp_mnt}/EFI/dualboot.cmd"
cp -p "${DUALBOOT_SCR}" "${esp_mnt}/EFI/dualboot.scr"
sync
umount "${esp_mnt}"
esp_mnt=

echo "== Verifying image =="
gpart show -p "${md}"
fsck_msdosfs -n "/dev/${md}p1"
fsck_ufs -n "/dev/${md}p3"
mkimage -l "${DUALBOOT_SCR}" >/dev/null

python3 - "${OUT}" "${UBOOT_BIN}" <<'PY'
from pathlib import Path
import sys

image, firmware = map(Path, sys.argv[1:])
offset = 0x40 * 512
expected = firmware.read_bytes()[offset:]
with image.open("rb") as stream:
    stream.seek(offset)
    actual = stream.read(len(expected))
if actual != expected:
    raise SystemExit(f"raw firmware verification failed at offset {offset}")
PY

image_sha=$(sha256 -q "${OUT}")
cat > "${OUT}.sha256" <<EOF
SHA256 (${OUT}) = ${image_sha}
EOF
cat > "${OUT}.build-info.txt" <<EOF
Image: ${OUT}
SHA256: ${image_sha}
FreeBSD source commit: ${src_commit}
Root label: ${ROOT_LABEL}
U-Boot: ${UBOOT_DIR}
U-Boot firmware: ${UBOOT_BIN}
U-Boot firmware SHA256: ${firmware_sha}
DTB: ${DTB}
U-Boot FDT overlays: ${UBOOT_FDT_OVERLAYS}
if_rge.txz: ${RGE_TXZ}
if_rge.txz SHA256: ${rge_sha}
Layout:
  raw firmware:  0-${FIRMWARE_MIB} MiB
  p1 ESP:        ${FIRMWARE_MIB}-${ESP_END_MIB} MiB
  p2 swap:       ${ESP_END_MIB}-${SWAP_END_MIB} MiB
  p3 UFS root:   ${SWAP_END_MIB}-${ROOT_END_MIB} MiB
  free tail:     ${ROOT_END_MIB}-${IMAGE_SIZE_MIB} MiB
EOF

mdconfig -d -u "${md#md}"
md=
echo "== Complete =="
ls -lh "${OUT}" "${OUT}.sha256" "${OUT}.build-info.txt"
