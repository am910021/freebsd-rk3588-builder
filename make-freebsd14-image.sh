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

STAMP=${STAMP:-$(date +%Y%m%d-%H%M%S)}
LOGO_BMP=${LOGO_BMP:-${IMAGE_LOGO_BMP}}
ROOTFS_TYPE=${ROOTFS_TYPE:-ufs}
INSTALLER=${INSTALLER:-NO}
INSTALL_TARGET_ROOT_LABEL=${ROOT_LABEL}
ROOTFS_SUFFIX=
if [ "${ROOTFS_TYPE}" = "zfs" ]; then
	ROOTFS_SUFFIX=-zfs
fi
case "${INSTALLER}" in
YES)
	[ "${ROOTFS_TYPE}" = "ufs" ] ||
	    {
		echo "${0##*/}: installer image must use a UFS live root" >&2
		exit 1
	    }
	SWAP_SIZE_MIB=0
	ROOT_LABEL=${ROOT_LABEL}_installer
	if [ "${ROOT_SIZE_MIB}" -lt 1536 ]; then
		ROOT_SIZE_MIB=1536
	fi
	ROOTFS_SUFFIX=${ROOTFS_SUFFIX}-installer
	;;
NO) ;;
*)
	echo "${0##*/}: INSTALLER must be YES or NO" >&2
	exit 1
	;;
esac
OUT=${OUT:-${IMAGE_OUTPUT_DIR}/${BOARD}-freebsd${FREEBSD_OBJ_VERSION}${ROOTFS_SUFFIX}-uboot${UBOOT_VERSION}-${FIRMWARE_MIB}m-${STAMP}.img}
WORK=${WORK:-}
rge_pkg=

usage()
{
	echo "usage: ${0##*/} [base.txz kernel.txz realtek-rge-kmod.pkg [output.img]]" >&2
	exit 1
}

case $# in
	0) ;;
	3)
		BASE_TXZ=$1
		KERNEL_TXZ=$2
		rge_pkg=$3
		;;
	4)
		BASE_TXZ=$1
		KERNEL_TXZ=$2
		rge_pkg=$3
		OUT=$4
		;;
	*) usage ;;
esac

UBOOT_BIN=${UBOOT_DIR}/${BOARD}-uboot-${FIRMWARE_MIB}m.bin
IDBLOADER=${UBOOT_DIR}/idbloader.img
UBOOT_ITB=${UBOOT_DIR}/u-boot.itb
BOOTMENU_FILE=${UBOOT_DIR}/bootmenu.env
MANIFEST_SCRIPT=${FREEBSD_SRC_DIR}/release/scripts/make-manifest.sh

die()
{
	echo "${0##*/}: $*" >&2
	exit 1
}

partition_uuid()
{
	partition_provider=${1}p${2}
	gpart list "$1" | awk -v provider="${partition_provider}" '
	    $2 == "Name:" { current = $3 }
	    current == provider && $1 == "rawuuid:" { print $2; exit }
	'
}

[ -n "${ROOT_LABEL}" ] || die "ROOT_LABEL is not configured"
[ -n "${IMAGE_HOSTNAME}" ] || die "IMAGE_HOSTNAME is not configured"
[ -n "${FREEBSD_DTB_ESP_PATH}" ] ||
    die "FREEBSD_DTB_ESP_PATH is not configured"
case "${FREEBSD_DTB_ESP_PATH}" in
	/*) ;;
	*) die "FREEBSD_DTB_ESP_PATH must be absolute" ;;
esac
case "${FIRMWARE_MIB}" in
	16|32) ;;
	*) die "firmware size must be 16 or 32 MiB" ;;
esac
case "${SWAP_SIZE_MIB}" in
	''|*[!0-9]*) die "swap size must be a non-negative integer" ;;
esac
case "${ROOTFS_TYPE}" in
	ufs|zfs) ;;
	*) die "root filesystem must be ufs or zfs" ;;
esac
case "${ZFS_POOL_NAME}" in
	''|[!A-Za-z]*|*[!A-Za-z0-9_-]*)
		die "invalid ZFS pool name: ${ZFS_POOL_NAME}"
		;;
esac

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
ROOT_PARTITION=2
if [ "${SWAP_SIZE_MIB}" -gt 0 ]; then
	ROOT_PARTITION=3
fi

md=
root_mnt=
esp_mnt=
AUTO_WORK=0

if [ -z "${rge_pkg}" ]; then
	for candidate in "${TXZ_ROOT}"/realtek-rge-kmod-*.pkg; do
		[ -f "${candidate}" ] || continue
		[ -z "${rge_pkg}" ] ||
		    die "multiple if_rge packages in ${TXZ_ROOT}"
		rge_pkg=${candidate}
	done
	[ -n "${rge_pkg}" ] ||
	    die "no if_rge package found in ${TXZ_ROOT}"
fi

installer_pkg=
if [ "${INSTALLER}" = "YES" ]; then
	for candidate in "${TXZ_ROOT}"/rk3588-installer-*.pkg; do
		[ -f "${candidate}" ] || continue
		[ -z "${installer_pkg}" ] ||
		    die "multiple rk3588-installer packages in ${TXZ_ROOT}"
		installer_pkg=${candidate}
	done
	[ -n "${installer_pkg}" ] ||
	    die "no rk3588-installer package found in ${TXZ_ROOT}"
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
		chflags -R noschg,nouchg "${WORK}" >/dev/null 2>&1 || true
		rm -rf "${WORK}"
	fi
}

for file in "${BASE_TXZ}" "${KERNEL_TXZ}" "${rge_pkg}" "${UBOOT_BIN}" \
    "${IDBLOADER}" "${UBOOT_ITB}" "${BOOTMENU_FILE}" \
    "${FREEBSD_DTB}" "${LOGO_BMP}"; do
	[ -f "${file}" ] || die "missing input: ${file}"
done
if [ "${INSTALLER}" = "YES" ]; then
	for file in "${MANIFEST_SCRIPT}" "${installer_pkg}"; do
		[ -f "${file}" ] || die "missing installer input: ${file}"
	done
fi
[ ! -e "${OUT}" ] || die "output already exists: ${OUT}"

for cmd in awk mdconfig gpart newfs newfs_msdos mount umount tar chflags \
    truncate dd mktemp sha256 python3 fsck_msdosfs fsck_ufs pkg; do
	command -v "${cmd}" >/dev/null 2>&1 || die "missing command: ${cmd}"
done
if [ "${ROOTFS_TYPE}" = "zfs" ]; then
	for cmd in makefs zdb; do
		command -v "${cmd}" >/dev/null 2>&1 ||
		    die "missing command: ${cmd}"
	done
fi

if [ -z "${WORK}" ]; then
	mkdir -p "${WORK_ROOT}/tmp"
	WORK=$(mktemp -d "${WORK_ROOT}/tmp/${BOARD}-image.XXXXXX")
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
echo "== Installing complete ${FIRMWARE_MIB} MiB U-Boot ${UBOOT_VERSION} firmware =="
dd if="${UBOOT_BIN}" of="${OUT}" bs=1m conv=notrunc,sync status=none
md=$(mdconfig -a -t vnode -f "${OUT}")
gpart create -s gpt "${md}"
gpart add -b "${ESP_START}" -s "${ESP_SECTORS}" -t efi -l EFI "${md}"
if [ "${SWAP_SIZE_MIB}" -gt 0 ]; then
	gpart add -b "${SWAP_START}" -s "${SWAP_SECTORS}" -t freebsd-swap \
	    -l growfs_swap "${md}"
fi
gpart add -b "${ROOT_START}" -s "${ROOT_SECTORS}" -t "freebsd-${ROOTFS_TYPE}" \
    -l freebsd_root "${md}"

esp_uuid=$(partition_uuid "${md}" 1)
root_uuid=$(partition_uuid "${md}" "${ROOT_PARTITION}")
[ -n "${esp_uuid}" ] || die "cannot determine ESP partition GUID"
[ -n "${root_uuid}" ] || die "cannot determine root partition GUID"
swap_uuid=
if [ "${SWAP_SIZE_MIB}" -gt 0 ]; then
	swap_uuid=$(partition_uuid "${md}" 2)
	[ -n "${swap_uuid}" ] || die "cannot determine swap partition GUID"
fi

echo "== Installing FreeBSD ${FREEBSD_OBJ_VERSION} root filesystem =="
if [ "${ROOTFS_TYPE}" = "ufs" ]; then
	newfs -U -L "${ROOT_LABEL}" "/dev/${md}p${ROOT_PARTITION}" >/dev/null
	mount "/dev/${md}p${ROOT_PARTITION}" "${root_mnt}"
fi
tar -xpf "${BASE_TXZ}" -C "${root_mnt}"
tar -xpf "${KERNEL_TXZ}" -C "${root_mnt}"
ASSUME_ALWAYS_YES=yes pkg -r "${root_mnt}" add "${rge_pkg}"
if [ -d "${BOARD_FILES_DIR}" ]; then
	(cd "${BOARD_FILES_DIR}" && tar -cpf - .) |
	    (cd "${root_mnt}" && tar -xpf -)
fi
[ -f "${root_mnt}/boot/modules/if_rge.ko" ] ||
    die "if_rge package did not install /boot/modules/if_rge.ko"

mkdir -p "${root_mnt}/boot/efi" "${root_mnt}/tmp" \
    "${root_mnt}/var/log" "${root_mnt}/var/tmp"
touch "${root_mnt}/firstboot"

if [ "${INSTALLER}" = "YES" ]; then
	distdir="${root_mnt}/usr/freebsd-dist"
	payload="${root_mnt}/usr/local/share/rk3588-installer"
	ASSUME_ALWAYS_YES=yes pkg -r "${root_mnt}" add "${installer_pkg}"
	mkdir -p "${distdir}" "${payload}" \
	    "${root_mnt}/usr/local/sbin"
	cp -p "${BASE_TXZ}" "${distdir}/base.txz"
	cp -p "${KERNEL_TXZ}" "${distdir}/kernel.txz"
	(
		cd "${distdir}"
		sh "${MANIFEST_SCRIPT}" base.txz kernel.txz > MANIFEST
	)
	cp -p "${UBOOT_BIN}" "${payload}/firmware.bin"
	cp -p "${rge_pkg}" "${payload}/if_rge.pkg"
	cp -p "${FREEBSD_DTB}" "${payload}/freebsd.dtb"
	cp -p "${BOOTMENU_FILE}" "${payload}/bootmenu.env"
	cat > "${payload}/config" <<EOF
FIRMWARE_MIB=${FIRMWARE_MIB}
ESP_MIB=${ESP_SIZE_MIB}
ROOT_LABEL=${INSTALL_TARGET_ROOT_LABEL}
ZFS_POOL_NAME=${ZFS_POOL_NAME}
EOF
fi

if [ "${ROOTFS_TYPE}" = "ufs" ]; then
	printf '/dev/gptid/%s\t/\t\tufs\trw,noatime\t\t1 1\n' \
	    "${root_uuid}" > "${root_mnt}/etc/fstab"
else
	: > "${root_mnt}/etc/fstab"
fi
cat >> "${root_mnt}/etc/fstab" <<EOF
/dev/gptid/${esp_uuid}	/boot/efi	msdosfs	rw,noatime,noauto	0 0
EOF
if [ "${SWAP_SIZE_MIB}" -gt 0 ]; then
	cat >> "${root_mnt}/etc/fstab" <<EOF
/dev/gptid/${swap_uuid}	none		swap	sw			0 0
EOF
fi
cat >> "${root_mnt}/etc/fstab" <<'EOF'
md				/tmp		mfs	rw,noatime,-s256m	0 0
md				/var/log	mfs	rw,noatime,-s64m	0 0
md				/var/tmp	mfs	rw,noatime,-s64m	0 0
EOF

cat > "${root_mnt}/etc/rc.conf" <<EOF
hostname="${IMAGE_HOSTNAME}"
ifconfig_DEFAULT="DHCP"
sshd_enable="YES"
growfs_enable="YES"
powerd_enable="YES"
sendmail_enable="NONE"
sendmail_submit_enable="NO"
sendmail_outbound_enable="NO"
sendmail_msp_queue_enable="NO"
EOF
if [ "${SWAP_SIZE_MIB}" -eq 0 ]; then
	echo 'growfs_swap_size="0"' >> "${root_mnt}/etc/rc.conf"
fi
if [ "${ROOTFS_TYPE}" = "zfs" ]; then
	echo 'zfs_enable="YES"' >> "${root_mnt}/etc/rc.conf"
fi

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
if [ "${ROOTFS_TYPE}" = "ufs" ]; then
	cat >> "${root_mnt}/boot/loader.conf" <<EOF
vfs.root.mountfrom="ufs:/dev/gptid/${root_uuid}"
EOF
else
	cat >> "${root_mnt}/boot/loader.conf" <<EOF
kern.geom.label.disk_ident.enable="0"
zfs_load="YES"
vfs.root.mountfrom="zfs:${ZFS_POOL_NAME}/ROOT/default"
EOF
fi

base_sha=$(sha256 -q "${BASE_TXZ}")
kernel_sha=$(sha256 -q "${KERNEL_TXZ}")
rge_sha=$(sha256 -q "${rge_pkg}")
firmware_sha=$(sha256 -q "${UBOOT_BIN}")
idb_sha=$(sha256 -q "${IDBLOADER}")
uboot_sha=$(sha256 -q "${UBOOT_ITB}")
dtb_sha=$(sha256 -q "${FREEBSD_DTB}")
logo_sha=$(sha256 -q "${LOGO_BMP}")
src_commit=$(git -C "${FREEBSD_SRC_DIR}" rev-parse --short HEAD 2>/dev/null ||
    echo unknown)

cat > "${root_mnt}/etc/${BOARD}-image-build.txt" <<EOF
Board: ${BOARD}
FreeBSD source commit: ${src_commit}
base.txz: ${base_sha}
kernel.txz: ${kernel_sha}
if_rge.pkg: ${rge_sha}
firmware.bin: ${firmware_sha}
idbloader.img: ${idb_sha}
u-boot.itb: ${uboot_sha}
FreeBSD DTB: ${dtb_sha}
logo.bmp: ${logo_sha}
ESP partition GUID: ${esp_uuid}
Root partition GUID: ${root_uuid}
Root filesystem: ${ROOTFS_TYPE}
Installer image: ${INSTALLER}
EOF
if [ -n "${swap_uuid}" ]; then
	echo "Swap partition GUID: ${swap_uuid}" \
	    >> "${root_mnt}/etc/${BOARD}-image-build.txt"
fi

sync
if [ "${ROOTFS_TYPE}" = "ufs" ]; then
	df -h "${root_mnt}"
	umount "${root_mnt}"
	root_mnt=
else
	du -sh "${root_mnt}"
	zfs_image="${WORK}/root.zfs"
	makefs -t zfs -s $((ROOT_SIZE_MIB * 1024 * 1024)) \
	    -o ashift=12 -o poolname="${ZFS_POOL_NAME}" \
	    -o bootfs="${ZFS_POOL_NAME}/ROOT/default" -o rootpath=/ \
	    -o fs="${ZFS_POOL_NAME};mountpoint=none" \
	    -o fs="${ZFS_POOL_NAME}/ROOT;mountpoint=none" \
	    -o fs="${ZFS_POOL_NAME}/ROOT/default;mountpoint=/;canmount=noauto" \
	    "${zfs_image}" "${root_mnt}"
	dd if="${zfs_image}" of="/dev/${md}p${ROOT_PARTITION}" \
	    bs=1m conv=sync status=none
fi

echo "== Installing ESP =="
newfs_msdos -L EFI -F 16 "/dev/${md}p1" >/dev/null
mount -t msdosfs "/dev/${md}p1" "${esp_mnt}"
mkdir -p "${esp_mnt}/EFI/BOOT" "${esp_mnt}/EFI/FreeBSD" \
    "${esp_mnt}/EFI/overlays" \
    "$(dirname "${esp_mnt}${FREEBSD_DTB_ESP_PATH}")"

loader_tmp="${WORK}/loader.efi"
if [ "${ROOTFS_TYPE}" = "ufs" ]; then
	root_mnt="${WORK}/root"
	mount -o ro "/dev/${md}p${ROOT_PARTITION}" "${root_mnt}"
fi
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
if [ "${ROOTFS_TYPE}" = "ufs" ]; then
	umount "${root_mnt}"
	root_mnt=
fi

printf 'fdt_overlays=%s\n' "${UBOOT_FDT_OVERLAYS}" \
    > "${esp_mnt}/EFI/overlays.conf"
cp -p "${loader_tmp}" "${esp_mnt}/EFI/BOOT/BOOTAA64.EFI"
cp -p "${loader_tmp}" "${esp_mnt}/EFI/FreeBSD/loader.efi"
cp -p "${FREEBSD_DTB}" "${esp_mnt}${FREEBSD_DTB_ESP_PATH}"
cp -p "${BOOTMENU_FILE}" "${esp_mnt}/bootmenu.env"
sync
umount "${esp_mnt}"
esp_mnt=

echo "== Verifying image =="
gpart show -p "${md}"
fsck_msdosfs -n "/dev/${md}p1"
if [ "${ROOTFS_TYPE}" = "ufs" ]; then
	fsck_ufs -n "/dev/${md}p${ROOT_PARTITION}"
else
	zdb -l "/dev/${md}p${ROOT_PARTITION}" >/dev/null
fi

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
Board: ${BOARD}
FreeBSD source commit: ${src_commit}
Root filesystem: ${ROOTFS_TYPE}
Installer image: ${INSTALLER}
U-Boot: ${UBOOT_DIR}
U-Boot firmware: ${UBOOT_BIN}
U-Boot firmware SHA256: ${firmware_sha}
FreeBSD DTB: ${FREEBSD_DTB}
U-Boot FDT overlays: ${UBOOT_FDT_OVERLAYS}
if_rge.pkg: ${rge_pkg}
if_rge.pkg SHA256: ${rge_sha}
Layout:
  raw firmware:  0-${FIRMWARE_MIB} MiB
  p1 ESP:        ${FIRMWARE_MIB}-${ESP_END_MIB} MiB
EOF
if [ "${SWAP_SIZE_MIB}" -gt 0 ]; then
	cat >> "${OUT}.build-info.txt" <<EOF
  p2 swap:       ${ESP_END_MIB}-${SWAP_END_MIB} MiB
  p3 ${ROOTFS_TYPE} root:   ${SWAP_END_MIB}-${ROOT_END_MIB} MiB
EOF
else
	cat >> "${OUT}.build-info.txt" <<EOF
  p2 ${ROOTFS_TYPE} root:   ${ESP_END_MIB}-${ROOT_END_MIB} MiB
EOF
fi
cat >> "${OUT}.build-info.txt" <<EOF
  free tail:     ${ROOT_END_MIB}-${IMAGE_SIZE_MIB} MiB
EOF

mdconfig -d -u "${md#md}"
md=
echo "== Complete =="
ls -lh "${OUT}" "${OUT}.sha256" "${OUT}.build-info.txt"
