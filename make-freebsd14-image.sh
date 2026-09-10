#!/bin/sh
set -eu

# Input: optional BUILDER_ROOT and BUILDER_CONFIG environment variables.
# Input example: BOARD=g98 BUILDER_CONFIG=/root/freebsd-rk3588-builder/builder.conf
# Output: loads builder.conf and board.conf, then initializes image-build globals.
# Output example: ROOTFS_TYPE=ufs and OUT=output/14.3-p16/g98-...img
load_configuration()
{
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
if [ "${INSTALLER}" = "YES" ]; then
	echo "== INSTALLER=YES: installer payload enabled =="
fi
OUT=${OUT:-${IMAGE_OUTPUT_DIR}/${BOARD}-freebsd${FREEBSD_OBJ_VERSION}${ROOTFS_SUFFIX}-uboot${UBOOT_VERSION}-${FIRMWARE_MIB}m-${STAMP}.img}
WORK=${WORK:-}
BOARD_PACKAGE_OVERRIDE=
board_registered_packages=
board_nonregistered_packages=
}

# Input: no positional parameters; script name is read from "$0".
# Input example: usage
# Output: prints the supported command line to stderr and exits with status 1.
# Output example: usage: make-freebsd14-image.sh [base.txz kernel.txz ...]
usage()
{
	echo "usage: ${0##*/} [base.txz kernel.txz board-package.pkg [output.img]]" >&2
	exit 1
}

# Input: zero, three or four command-line arguments in "$@" plus configured paths.
# Input example: parse_arguments base.txz kernel.txz board.pkg output.img
# Output: optionally overrides BASE_TXZ, KERNEL_TXZ, BOARD_PACKAGE_OVERRIDE and OUT.
# Output example: UBOOT_BIN=<UBOOT_DIR>/g98-uboot-16m-mmc.bin
parse_arguments()
{
case $# in
	0) ;;
	3)
		BASE_TXZ=$1
		KERNEL_TXZ=$2
		BOARD_PACKAGE_OVERRIDE=$3
		;;
	4)
		BASE_TXZ=$1
		KERNEL_TXZ=$2
		BOARD_PACKAGE_OVERRIDE=$3
		OUT=$4
		;;
	*) usage ;;
esac

UBOOT_BIN=${UBOOT_DIR}/${BOARD}-uboot-${FIRMWARE_MIB}m-mmc.bin
UBOOT_UPDATE_BIN=${UBOOT_DIR}/firmware-update-mmc.bin
IDBLOADER=${UBOOT_DIR}/idbloader.img
UBOOT_ITB=${UBOOT_DIR}/u-boot.itb
MANIFEST_SCRIPT=${FREEBSD_SRC_DIR}/release/scripts/make-manifest.sh
}

# Input: error text in "$*"; no required global variables.
# Input example: die "missing input: base.txz"
# Output: writes "<script>: MESSAGE" to stderr and exits with status 1.
# Output example: make-freebsd14-image.sh: missing input: base.txz
die()
{
	echo "${0##*/}: $*" >&2
	exit 1
}

# Input: provider name in "$1" and partition number in "$2".
# Input example: partition_uuid md0 2
# Output: prints the matching GPT partition raw UUID, or no output when absent.
# Output example: 01dd613e-a606-11f1-8811-00e04c68dedc
partition_uuid()
{
	partition_provider=${1}p${2}
	gpart list "$1" | awk -v provider="${partition_provider}" '
	    $2 == "Name:" { current = $3 }
	    current == provider && $1 == "rawuuid:" { print $2; exit }
	'
}

# select_single_package OVERRIDE GLOB LABEL
# Input: optional exact path "$1", TXZ_ROOT-relative glob "$2" and label "$3".
# Input example: select_single_package '' 'board-driver-*.pkg' board-driver
# Output: sets selected_package to exactly one regular package or exits.
# Output example: selected_package=/output/14.3-p16/board-driver-1.0.pkg
select_single_package()
{
	package_override=$1
	package_glob=$2
	package_label=$3
	selected_package=
	if [ -n "${package_override}" ]; then
		[ -f "${package_override}" ] ||
		    die "missing ${package_label} package: ${package_override}"
		selected_package=${package_override}
		return
	fi
	for package_candidate in "${TXZ_ROOT}"/${package_glob}; do
		[ -f "${package_candidate}" ] || continue
		[ -z "${selected_package}" ] ||
		    die "multiple ${package_label} packages in ${TXZ_ROOT}"
		selected_package=${package_candidate}
	done
	[ -n "${selected_package}" ] ||
	    die "no ${package_label} package found in ${TXZ_ROOT}"
}

# add_board_package MODE OVERRIDE GLOB
# Input: mode "$1", optional exact path "$2" and TXZ_ROOT-relative glob "$3".
# Input example: add_board_package non-registered '' 'board-driver-*.pkg'
# Output: appends one resolved package path to the selected board package list.
# Output example: board_nonregistered_packages=".../board-driver-1.0.pkg"
add_board_package()
{
	package_mode=$1
	package_override=$2
	package_glob=$3
	select_single_package "${package_override}" "${package_glob}" \
	    "${package_glob}"
	case "${selected_package}" in
	*[[:space:]]*) die "package path contains whitespace: ${selected_package}" ;;
	esac
	case "${package_mode}" in
	registered)
		board_registered_packages="${board_registered_packages} ${selected_package}"
		board_registered_packages=${board_registered_packages# }
		;;
	non-registered)
		board_nonregistered_packages="${board_nonregistered_packages} ${selected_package}"
		board_nonregistered_packages=${board_nonregistered_packages# }
		;;
	*) die "unknown board package mode: ${package_mode}" ;;
	esac
}

# Input: archive paths and image-layout globals loaded by load_configuration().
# Input example: ROOTFS_TYPE=ufs FIRMWARE_MIB=16 SWAP_SIZE_MIB=512
# Output: validates configuration and initializes partition offsets plus runtime globals.
# Output example: ESP_START=32768 ROOT_PARTITION=4 and md=""
configure_image_layout()
{
	# Validate the two required FreeBSD release archives first.
for file in "${BASE_TXZ}" "${KERNEL_TXZ}"; do
	[ -f "${file}" ] || die "missing input: ${file}"
done

	# Reject invalid labels, sizes and filesystem selections before changing state.
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
ESP_PARTITION=2
ROOT_PARTITION=3
if [ "${SWAP_SIZE_MIB}" -gt 0 ]; then
	ROOT_PARTITION=4
fi

md=
root_mnt=
esp_mnt=
AUTO_WORK=0
}

# Input: TXZ_ROOT, PORT_ORIGINS and board hooks from configuration.
# Input example: TXZ_ROOT=output/14.3-p16 PORT_ORIGINS="ports-mgmt/pkg ..."
# Output: selects exactly one package for each required or configured component.
# Output example: pkg_package=<TXZ_ROOT>/pkg-2.1.2.pkg
discover_packages()
{
	# Select the bootstrap pkg package.
pkg_package=
for candidate in "${TXZ_ROOT}"/pkg-*.pkg; do
	[ -f "${candidate}" ] || continue
	[ -z "${pkg_package}" ] ||
	    die "multiple pkg packages in ${TXZ_ROOT}"
	pkg_package=${candidate}
done
[ -n "${pkg_package}" ] || die "no pkg package found in ${TXZ_ROOT}"

installer_pkg=
case " ${PORT_ORIGINS} " in
*" sysutils/rk3588-installer "*)
	for candidate in "${TXZ_ROOT}"/rk3588-installer-*.pkg; do
		[ -f "${candidate}" ] || continue
		[ -z "${installer_pkg}" ] ||
		    die "multiple rk3588-installer packages in ${TXZ_ROOT}"
		installer_pkg=${candidate}
	done
	[ -n "${installer_pkg}" ] ||
	    die "no rk3588-installer package found in ${TXZ_ROOT}"
	;;
esac

uboot_tools_pkg=
for candidate in "${TXZ_ROOT}"/rk3588-uboot-tools-*.pkg; do
	[ -f "${candidate}" ] || continue
	[ -z "${uboot_tools_pkg}" ] ||
	    die "multiple rk3588-uboot-tools packages in ${TXZ_ROOT}"
	uboot_tools_pkg=${candidate}
done
[ -n "${uboot_tools_pkg}" ] ||
    die "no rk3588-uboot-tools package found in ${TXZ_ROOT}"

run_board_hook board_image_add_packages
}

# Input: global mount/device/work variables updated during image construction.
# Input example: md=md0 root_mnt=/work/root AUTO_WORK=1
# Output: best-effort unmount/detach and archives an automatically allocated work tree.
# Output example: $HOME/ready-to-delete/g98-image.abcd-<timestamp>-<pid>
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
		mkdir -p "${HOME}/ready-to-delete"
		mv "${WORK}" \
		    "${HOME}/ready-to-delete/${WORK##*/}-$(date +%Y%m%d-%H%M%S)-$$"
	fi
}

# Input: all selected artifacts, OUT, INSTALLER, ROOTFS_TYPE and host PATH.
# Input example: INSTALLER=YES ROOTFS_TYPE=ufs OUT=output/g98-installer.img
# Output: returns 0 only when every input and required host command is available.
# Output example: no stdout and status 0
validate_inputs_and_tools()
{
	# Verify every artifact selected for this board and image type.
for file in "${pkg_package}" "${uboot_tools_pkg}" "${UBOOT_BIN}" \
    "${UBOOT_UPDATE_BIN}" \
    "${IDBLOADER}" "${UBOOT_ITB}" "${FREEBSD_DTB}" \
    "${LOGO_BMP}"; do
	[ -f "${file}" ] || die "missing input: ${file}"
done
for file in ${board_registered_packages} ${board_nonregistered_packages}; do
	[ -f "${file}" ] || die "missing board package: ${file}"
done
if [ "${INSTALLER}" = "YES" ]; then
	[ -f "${MANIFEST_SCRIPT}" ] ||
	    die "missing installer input: ${MANIFEST_SCRIPT}"
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
}

# Input: optional WORK plus WORK_ROOT, BOARD and OUT globals.
# Input example: WORK="" WORK_ROOT=/root/freebsd-rk3588-builder/work BOARD=g98
# Output: creates work/mount directories, installs cleanup trap and sets WORK paths.
# Output example: WORK=<WORK_ROOT>/tmp/g98-image.abcd and AUTO_WORK=1
prepare_workspace()
{
	# Allocate a disposable work tree unless the caller supplied one.
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
}

# Input: output/layout/U-Boot globals and prepared WORK mount paths.
# Input example: OUT=output/g98.img FIRMWARE_MIB=16 ROOTFS_TYPE=ufs
# Output: creates the raw image, attaches md, writes firmware/GPT and records UUIDs.
# Output example: md=md0 esp_uuid=<UUID> root_uuid=<UUID>
create_partitioned_image()
{
	# Create the raw image and write the complete MMC firmware before GPT metadata.
echo "== Creating GPT image =="
truncate -s $((TOTAL_SECTORS * 512)) "${OUT}"
echo "== Installing complete ${FIRMWARE_MIB} MiB U-Boot ${UBOOT_VERSION} firmware =="
dd if="${UBOOT_BIN}" of="${OUT}" bs=1m conv=notrunc,sync status=none
md=$(mdconfig -a -t vnode -f "${OUT}")
gpart create -s gpt "${md}"
FIRMWARE_START=$(gpart show -p "${md}" |
	awk '$3 == "-" && $4 == "free" { print $1; exit }')
case "${FIRMWARE_START}" in
	''|*[!0-9]*) die "cannot determine first usable GPT sector" ;;
esac
[ "${FIRMWARE_START}" -le 64 ] ||
    die "GPT metadata overlaps idbloader at LBA 64"
FIRMWARE_SECTORS=$((ESP_START - FIRMWARE_START))
gpart add -b "${FIRMWARE_START}" -s "${FIRMWARE_SECTORS}" \
    -t freebsd-boot -l rk3588_firmware "${md}"
gpart add -b "${ESP_START}" -s "${ESP_SECTORS}" -t efi -l EFI "${md}"
if [ "${SWAP_SIZE_MIB}" -gt 0 ]; then
	gpart add -b "${SWAP_START}" -s "${SWAP_SECTORS}" -t freebsd-swap \
	    -l growfs_swap "${md}"
fi
gpart add -b "${ROOT_START}" -s "${ROOT_SECTORS}" -t "freebsd-${ROOTFS_TYPE}" \
    -l freebsd_root "${md}"

esp_uuid=$(partition_uuid "${md}" "${ESP_PARTITION}")
root_uuid=$(partition_uuid "${md}" "${ROOT_PARTITION}")
[ -n "${esp_uuid}" ] || die "cannot determine ESP partition GUID"
[ -n "${root_uuid}" ] || die "cannot determine root partition GUID"
swap_uuid=
if [ "${SWAP_SIZE_MIB}" -gt 0 ]; then
	swap_uuid=$(partition_uuid "${md}" 3)
	[ -n "${swap_uuid}" ] || die "cannot determine swap partition GUID"
fi
}

# Input: attached md partitions, root_mnt, release archives and selected packages.
# Input example: ROOTFS_TYPE=ufs md=md0 ROOT_PARTITION=4
# Output: populates the target root and installs all configured offline packages.
# Output example: board-selected packages are installed below <root_mnt>
install_root_filesystem()
{
	# Create/mount UFS when selected; ZFS is assembled from this directory later.
echo "== Installing FreeBSD ${FREEBSD_OBJ_VERSION} root filesystem =="
if [ "${ROOTFS_TYPE}" = "ufs" ]; then
	newfs -U -L "${ROOT_LABEL}" "/dev/${md}p${ROOT_PARTITION}" >/dev/null
	mount "/dev/${md}p${ROOT_PARTITION}" "${root_mnt}"
fi
tar -xpf "${BASE_TXZ}" -C "${root_mnt}"
tar -xpf "${KERNEL_TXZ}" -C "${root_mnt}"
ASSUME_ALWAYS_YES=yes pkg -r "${root_mnt}" -o REPO_AUTOUPDATE=false \
    add "${pkg_package}"
[ -x "${root_mnt}/usr/local/sbin/pkg" ] ||
    die "pkg package did not install /usr/local/sbin/pkg"
for board_package in ${board_registered_packages} \
    ${board_nonregistered_packages}; do
	ASSUME_ALWAYS_YES=yes pkg -r "${root_mnt}" -o REPO_AUTOUPDATE=false \
	    add "${board_package}"
done
ASSUME_ALWAYS_YES=yes pkg -r "${root_mnt}" -o REPO_AUTOUPDATE=false \
    add "${uboot_tools_pkg}"
if [ -n "${installer_pkg}" ]; then
	ASSUME_ALWAYS_YES=yes pkg -r "${root_mnt}" -o REPO_AUTOUPDATE=false \
	    add "${installer_pkg}"
fi
if [ -d "${BOARD_FILES_DIR}" ]; then
	(cd "${BOARD_FILES_DIR}" && tar -cpf - .) |
	    (cd "${root_mnt}" && tar -xpf -)
fi
mkdir -p "${root_mnt}/boot/efi" "${root_mnt}/tmp" \
    "${root_mnt}/var/log" "${root_mnt}/var/tmp"
touch "${root_mnt}/firstboot"
}

# Input: INSTALLER and installer artifact/config globals plus populated root_mnt.
# Input example: INSTALLER=YES with payload below <root_mnt>/usr/local/share
# Output: for installer images, stages distributions, packages, firmware and config.
# Output example: <root_mnt>/usr/freebsd-dist/MANIFEST
stage_installer_payload()
{
	# Non-installer images intentionally skip this payload block.
if [ "${INSTALLER}" = "YES" ]; then
	distdir="${root_mnt}/usr/freebsd-dist"
	payload="${root_mnt}/usr/local/share/rk3588-installer"
	mkdir -p "${distdir}" "${payload}" \
	    "${root_mnt}/usr/local/sbin"
	cp -p "${BASE_TXZ}" "${distdir}/base.txz"
	cp -p "${KERNEL_TXZ}" "${distdir}/kernel.txz"
	(
		cd "${distdir}"
		sh "${MANIFEST_SCRIPT}" base.txz kernel.txz > MANIFEST
	)
	cp -p "${UBOOT_UPDATE_BIN}" "${payload}/firmware-update.bin"
	cp -p "${pkg_package}" "${payload}/pkg.pkg"
	cp -p "${uboot_tools_pkg}" "${payload}/uboot-tools.pkg"
	for board_package in ${board_registered_packages}; do
		cp -p "${board_package}" "${payload}/${board_package##*/}"
	done
	if [ -n "${board_nonregistered_packages}" ]; then
		mkdir -p "${payload}/non-registered"
		for board_package in ${board_nonregistered_packages}; do
			cp -p "${board_package}" \
			    "${payload}/non-registered/${board_package##*/}"
		done
	fi
	cp -p "${FREEBSD_DTB}" "${payload}/freebsd.dtb"
	if [ -f "${BOARD_DIR}/loader.conf" ]; then
		cp -p "${BOARD_DIR}/loader.conf" "${payload}/loader.conf.board"
	fi
	firmware_update_bytes=$(stat -f %z "${UBOOT_UPDATE_BIN}")
	cat > "${payload}/config" <<EOF
FIRMWARE_MIB=${FIRMWARE_MIB}
FIRMWARE_UPDATE_BYTES=${firmware_update_bytes}
ESP_MIB=${ESP_SIZE_MIB}
ROOT_LABEL=${INSTALL_TARGET_ROOT_LABEL}
ZFS_POOL_NAME=${ZFS_POOL_NAME}
EOF
fi
}

# Input: filesystem UUIDs, image settings, board files and populated root_mnt.
# Input example: ROOTFS_TYPE=zfs ZFS_POOL_NAME=nanopc_t6
# Output: writes fstab, rc.conf and loader.conf for the resulting system.
# Output example: <root_mnt>/boot/loader.conf
write_system_configuration()
{
	# Write filesystem mounts from generated GPT UUIDs.
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
sshd_enable="YES"
growfs_enable="YES"
powerd_enable="YES"
ntpd_enable="YES"
ntpd_sync_on_start="YES"
sendmail_enable="NONE"
sendmail_submit_enable="NO"
sendmail_outbound_enable="NO"
sendmail_msp_queue_enable="NO"
EOF
if [ -n "${DEVMATCH_BLOCKLIST:-}" ]; then
	echo "devmatch_blocklist=\"${DEVMATCH_BLOCKLIST}\"" >> \
	    "${root_mnt}/etc/rc.conf"
fi
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
# The installer applies loader.conf.board separately to the installed target.
if [ "${INSTALLER}" = "YES" ]; then
	cp -p "${root_mnt}/etc/rc.conf" "${payload}/rc.conf.base"
	sed '/^[[:space:]]*vfs\.root\.mountfrom[[:space:]]*=/d' \
	    "${root_mnt}/boot/loader.conf" > "${payload}/loader.conf.base"
fi
if [ -f "${BOARD_DIR}/loader.conf" ]; then
	cat "${BOARD_DIR}/loader.conf" >> "${root_mnt}/boot/loader.conf"
fi
}

# Input: installed artifact paths, UUIDs and source/configuration globals.
# Input example: BOARD=g98 FREEBSD_SRC_DIR=<builder>/src/freebsd-src
# Output: calculates component hashes and writes board image provenance in the root.
# Output example: <root_mnt>/etc/g98-image-build.txt
write_root_provenance()
{
	# Hash every installed source artifact for reproducibility.
base_sha=$(sha256 -q "${BASE_TXZ}")
kernel_sha=$(sha256 -q "${KERNEL_TXZ}")
pkg_sha=$(sha256 -q "${pkg_package}")
uboot_tools_sha=$(sha256 -q "${uboot_tools_pkg}")
firmware_sha=$(sha256 -q "${UBOOT_BIN}")
firmware_update_sha=$(sha256 -q "${UBOOT_UPDATE_BIN}")
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
pkg.pkg: ${pkg_sha}
rk3588-uboot-tools.pkg: ${uboot_tools_sha}
firmware.bin: ${firmware_sha}
firmware-update.bin: ${firmware_update_sha}
idbloader.img: ${idb_sha}
u-boot.itb: ${uboot_sha}
FreeBSD DTB: ${dtb_sha}
logo.bmp: ${logo_sha}
ESP partition GUID: ${esp_uuid}
Root partition GUID: ${root_uuid}
Root filesystem: ${ROOTFS_TYPE}
Installed ports: ${PORT_ORIGINS}
Installer payload: ${INSTALLER}
EOF
for board_package in ${board_registered_packages}; do
	echo "Board package (registered): ${board_package##*/} $(sha256 -q "${board_package}")" \
	    >> "${root_mnt}/etc/${BOARD}-image-build.txt"
done
for board_package in ${board_nonregistered_packages}; do
	echo "Board package (non-registered): ${board_package##*/} $(sha256 -q "${board_package}")" \
	    >> "${root_mnt}/etc/${BOARD}-image-build.txt"
done
if [ -n "${swap_uuid}" ]; then
	echo "Swap partition GUID: ${swap_uuid}" \
	    >> "${root_mnt}/etc/${BOARD}-image-build.txt"
fi
}

# Input: ROOTFS_TYPE, root_mnt, md and calculated root partition sizing.
# Input example: ROOTFS_TYPE=zfs ROOT_SIZE_MIB=2048 ZFS_POOL_NAME=nanopc_t6
# Output: flushes UFS or creates and writes the final ZFS root partition image.
# Output example: /dev/md0p3 contains the completed root filesystem
finalize_root_filesystem()
{
	# Flush staged files before unmounting or converting the root tree.
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
}

# Input: attached ESP partition, root filesystem, DTB and overlay globals.
# Input example: ESP_PARTITION=2 FREEBSD_DTB_ESP_PATH=/dtb/freebsd.dtb
# Output: formats and fills the ESP with loader, DTB and configured overlays.
# Output example: EFI/BOOT/BOOTAA64.EFI and dtb/freebsd.dtb
install_esp()
{
	# Format and mount the EFI System Partition.
echo "== Installing ESP =="
newfs_msdos -L EFI -F 16 "/dev/${md}p${ESP_PARTITION}" >/dev/null
mount -t msdosfs "/dev/${md}p${ESP_PARTITION}" "${esp_mnt}"
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
sync
umount "${esp_mnt}"
esp_mnt=
}

# Input: attached md, OUT, UBOOT_BIN, ROOTFS_TYPE and partition globals.
# Input example: md=md0 OUT=output/g98.img ROOTFS_TYPE=ufs
# Output: verifies GPT/filesystems and byte-compares embedded raw firmware.
# Output example: fsck status 0 and no raw firmware verification error
verify_image()
{
	# Verify partition metadata and filesystem integrity without modifying them.
echo "== Verifying image =="
gpart show -p "${md}"
fsck_msdosfs -n "/dev/${md}p${ESP_PARTITION}"
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
}

# Input: verified OUT plus image/component hashes, layout and provenance globals.
# Input example: OUT=output/g98.img BOARD=g98 ROOTFS_TYPE=ufs
# Output: writes the image checksum and human-readable build information files.
# Output example: <OUT>.sha256 and <OUT>.build-info.txt
write_image_metadata()
{
	# Record the final image hash and complete component provenance.
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
Installed ports: ${PORT_ORIGINS}
Installer payload: ${INSTALLER}
U-Boot: ${UBOOT_DIR}
U-Boot firmware: ${UBOOT_BIN}
U-Boot firmware SHA256: ${firmware_sha}
U-Boot update payload: ${UBOOT_UPDATE_BIN}
U-Boot update payload SHA256: ${firmware_update_sha}
FreeBSD DTB: ${FREEBSD_DTB}
U-Boot FDT overlays: ${UBOOT_FDT_OVERLAYS}
pkg.pkg: ${pkg_package}
pkg.pkg SHA256: ${pkg_sha}
rk3588-uboot-tools.pkg: ${uboot_tools_pkg}
rk3588-uboot-tools.pkg SHA256: ${uboot_tools_sha}
EOF
for board_package in ${board_registered_packages}; do
	echo "Board package (registered): ${board_package} $(sha256 -q "${board_package}")" \
	    >> "${OUT}.build-info.txt"
done
for board_package in ${board_nonregistered_packages}; do
	echo "Board package (non-registered): ${board_package} $(sha256 -q "${board_package}")" \
	    >> "${OUT}.build-info.txt"
done
cat >> "${OUT}.build-info.txt" <<EOF
Layout:
  p1 firmware:   0-${FIRMWARE_MIB} MiB
  p2 ESP:        ${FIRMWARE_MIB}-${ESP_END_MIB} MiB
EOF
if [ "${SWAP_SIZE_MIB}" -gt 0 ]; then
	cat >> "${OUT}.build-info.txt" <<EOF
  p3 swap:       ${ESP_END_MIB}-${SWAP_END_MIB} MiB
  p4 ${ROOTFS_TYPE} root:   ${SWAP_END_MIB}-${ROOT_END_MIB} MiB
EOF
else
	cat >> "${OUT}.build-info.txt" <<EOF
  p3 ${ROOTFS_TYPE} root:   ${ESP_END_MIB}-${ROOT_END_MIB} MiB
EOF
fi
cat >> "${OUT}.build-info.txt" <<EOF
  free tail:     ${ROOT_END_MIB}-${IMAGE_SIZE_MIB} MiB
EOF
}

# Input: attached md and completed OUT metadata paths.
# Input example: md=md0 OUT=output/g98.img
# Output: detaches the image vnode and prints the three final artifact paths.
# Output example: output/g98.img, output/g98.img.sha256 and .build-info.txt
report_outputs()
{
	# Detach explicitly so cleanup has no remaining md device to process.
mdconfig -d -u "${md#md}"
md=
echo "== Complete =="
ls -lh "${OUT}" "${OUT}.sha256" "${OUT}.build-info.txt"
}

# Input: optional environment configuration and zero, three or four CLI arguments.
# Input example: BOARD=g98 INSTALLER=YES ./make-freebsd14-image.sh
# Output: creates and verifies a complete RK3588 FreeBSD disk image and metadata.
# Output example: output/14.3-p16/g98-freebsd14.3-p16-installer-...img
main()
{
	load_configuration
	parse_arguments "$@"
	configure_image_layout
	discover_packages
	validate_inputs_and_tools
	prepare_workspace
	create_partitioned_image
	install_root_filesystem
	stage_installer_payload
	write_system_configuration
	write_root_provenance
	finalize_root_filesystem
	install_esp
	verify_image
	write_image_metadata
	report_outputs
}

main "$@"
