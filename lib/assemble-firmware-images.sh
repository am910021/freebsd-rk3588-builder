#!/bin/sh

set -eu

fail()
{
	echo "${0##*/}: $*" >&2
	exit 1
}

# file_size FILE
# Input example: file_size output/u-boot.itb
# Output: prints the file size in bytes.
file_size()
{
	stat -f %z "$1"
}

# require_marker FILE TEXT
# Input example: require_marker u-boot.bin bootmenu_delay=3
# Output: succeeds only when the binary contains the literal marker.
require_marker()
{
	LC_ALL=C grep -aFq -- "$2" "$1" ||
	    fail "${1##*/} lacks marker: $2"
}

# marker_count FILE TEXT
# Input example: marker_count u-boot.bin RK3588-FW-COMPAT-V1:
# Output: prints the number of literal marker occurrences.
marker_count()
{
	LC_ALL=C grep -aFo -- "$2" "$1" 2>/dev/null | wc -l | tr -d ' '
}

# require_exact_nul_marker FILE TEXT
# Input example: require_exact_nul_marker u-boot.bin RK3588-FW-COMPAT-V1:G98:SPI:16M
# Output: verifies one TEXT marker immediately followed by a NUL byte.
require_exact_nul_marker()
{
	marker_file=$1
	marker_text=$2
	marker_location=$(LC_ALL=C grep -aobF -- "$marker_text" "${marker_file}" |
	    awk -F: 'NR == 1 { print $1 }')
	[ -n "${marker_location}" ] || fail "missing marker: ${marker_text}"
	marker_bytes=$((${#marker_text} + 1))
	actual_hex=$(dd if="${marker_file}" bs=1 skip="${marker_location}" \
	    count="${marker_bytes}" status=none | od -An -tx1 | tr -d ' \n')
	expected_hex=$(printf '%s\000' "${marker_text}" |
	    od -An -tx1 | tr -d ' \n')
	[ "${actual_hex}" = "${expected_hex}" ] ||
	    fail "marker is not NUL terminated: ${marker_text}"
}

# require_config_setting TEXT
# Input example: require_config_setting CONFIG_ENV_REDUNDANT=y
# Output: succeeds only when u-boot.config contains the exact line.
require_config_setting()
{
	grep -Fqx -- "$1" "${config_file}" ||
	    fail "u-boot.config lacks setting: $1"
}

# require_part_fit NAME OFFSET FILE LIMIT
# Input example: require_part_fit u-boot.itb 8388608 u-boot.itb 12582912
# Output: rejects a component that crosses its reserved firmware region.
require_part_fit()
{
	part_name=$1
	part_offset=$2
	part_file=$3
	part_limit=$4
	part_end=$((part_offset + $(file_size "${part_file}")))
	[ "${part_end}" -le "${part_limit}" ] ||
	    fail "${part_name} ends at ${part_end} bytes, past its ${part_limit}-byte limit"
}

# fill_ff FILE BYTES
# Input example: fill_ff firmware.bin 16777216
# Output: creates a file of the requested size filled with 0xff.
fill_ff()
{
	fill_file=$1
	fill_bytes=$2
	dd if=/dev/zero bs=1m count=$((fill_bytes / mib)) status=none |
	    LC_ALL=C tr '\000' '\377' > "${fill_file}"
}

# write_at IMAGE OFFSET FILE
# Input example: write_at firmware.bin 8388608 u-boot.itb
# Output: copies FILE into IMAGE at the exact byte offset.
write_at()
{
	write_image=$1
	write_offset=$2
	write_file=$3
	[ $((write_offset % sector)) -eq 0 ] ||
	    fail "unaligned firmware offset: ${write_offset}"
	dd if="${write_file}" of="${write_image}" bs=512 \
	    seek=$((write_offset / sector)) \
	    conv=notrunc status=none
}

# stamp_target IMAGE LAYOUT
# Input example: stamp_target g98-uboot-16m-spi.bin SPI
# Output: writes the board/layout target marker into its reserved sector.
stamp_target()
{
	target_image=$1
	target_layout=$2
	target_marker="${target_prefix}${board_identity}:${target_layout}:${size_mib}M"
	[ $((${#target_marker} + 1)) -le "${sector}" ] ||
	    fail "firmware target marker exceeds one sector"
	non_ff=$(dd if="${target_image}" bs=1 skip="${target_offset}" \
	    count="${sector}" status=none | LC_ALL=C tr -d '\377' | wc -c |
	    tr -d ' ')
	[ "${non_ff}" -eq 0 ] ||
	    fail "firmware target marker sector is not empty"
	printf '%s\000' "${target_marker}" |
	    dd of="${target_image}" bs=1 seek="${target_offset}" \
	        conv=notrunc status=none
}

[ "$#" -eq 6 ] ||
    fail "usage: ${0##*/} OUT SIZE_MIB LOGO_ENABLE BOARD BINARY_MARKER FIRMWARE_COMPAT"

out=$1
size_mib=$2
logo_enable=$3
board=$4
binary_marker=$5
firmware_compat=$6

case "${size_mib}" in 16|32) ;; *) fail "firmware size must be 16 or 32 MiB" ;; esac
case "${logo_enable}" in YES) logo_value=1 ;; *) logo_value=0 ;; esac
case "${firmware_compat}" in
*:SPI:${size_mib}M) ;;
*) fail "invalid firmware compatibility identity: ${firmware_compat}" ;;
esac
board_identity=${firmware_compat%%:*}
case "${board_identity}" in
''|[!A-Z0-9]*|*[!A-Z0-9_-]*)
	fail "invalid firmware board identity: ${board_identity}"
	;;
esac

mib=$((1024 * 1024))
sector=512
firmware_bytes=$((size_mib * mib))
idb_offset=$((0x40 * sector))
uboot_offset=$((0x4000 * sector))
logo_offset=$((0x6000 * sector))
logo_read_size=$((0x961 * sector))
env_offset=$((firmware_bytes - 512 * 1024))
env_offset_redund=$((env_offset + 64 * 1024))
env_size=$((0x10000))
target_offset=$((env_offset - sector))

binary=${out}/u-boot.bin
config_file=${out}/u-boot.config
logo=${out}/logo.bmp
idb=${out}/idbloader.img
uboot=${out}/u-boot.itb
spi=${out}/u-boot-rockchip-spi.bin
for input in "${binary}" "${config_file}" "${logo}" "${idb}" "${uboot}" "${spi}"; do
	[ -f "${input}" ] || fail "missing input: ${input}"
done

for marker in "${binary_marker}" bootmenu_delay=3 logo_delay=0 \
    "logo_enable=${logo_value}" show_logo= freebsdboot /uboot-env.request \
    boot_freebsd_target= freebsd_default_boot=auto rk_boot_storage \
    rockchip,boot-storage; do
	require_marker "${binary}" "${marker}"
done

compat_prefix=RK3588-FW-COMPAT-V1:
version_prefix=RK3588-FW-VERSION-V1:
target_prefix=RK3588-FW-TARGET-V1:
compat_marker=${compat_prefix}${firmware_compat}
[ "$(marker_count "${binary}" "${compat_prefix}")" -eq 1 ] ||
    fail "u-boot.bin must contain exactly one compatibility marker"
require_exact_nul_marker "${binary}" "${compat_marker}"
[ "$(marker_count "${binary}" "${version_prefix}")" -eq 1 ] ||
    fail "u-boot.bin must contain exactly one version marker"

require_config_setting CONFIG_RK3588_FREEBSD_SPI_UPDATE=y
require_config_setting "CONFIG_ENV_OFFSET=0x$(printf '%x' "${env_offset}")"
require_config_setting "CONFIG_ENV_OFFSET_REDUND=0x$(printf '%x' "${env_offset_redund}")"
require_config_setting "CONFIG_ENV_SIZE=0x$(printf '%x' "${env_size}")"
require_config_setting CONFIG_ENV_REDUNDANT=y
require_config_setting CONFIG_ENV_IS_IN_MMC=y
require_config_setting CONFIG_ENV_IS_IN_SPI_FLASH=y
require_config_setting "CONFIG_RK3588_FREEBSD_SPI_COMPAT=\"${firmware_compat}\""
require_config_setting "CONFIG_RK3588_FREEBSD_SPI_LAYOUT_MIB=${size_mib}"

logo_size=$(file_size "${logo}")
logo_magic=$(dd if="${logo}" bs=1 count=2 status=none | od -An -tx1 | tr -d ' \n')
logo_header_size=$(od -An -tu4 -j 2 -N 4 "${logo}" | tr -d ' \n')
[ "${logo_magic}" = 424d ] && [ "${logo_header_size}" -eq "${logo_size}" ] ||
    fail "logo.bmp has an invalid BMP header or file size"
logo_padding=$(((sector - logo_size % sector) % sector))
logo_raw=${out}/logo.img
cp -p "${logo}" "${logo_raw}"
if [ "${logo_padding}" -gt 0 ]; then
	dd if=/dev/zero bs=1 count="${logo_padding}" status=none |
	    LC_ALL=C tr '\000' '\377' >> "${logo_raw}"
fi
logo_raw_size=$(file_size "${logo_raw}")
[ "${logo_raw_size}" -le "${logo_read_size}" ] ||
    fail "logo.bmp needs ${logo_raw_size} bytes, but U-Boot reads only ${logo_read_size}"

spi_uboot_value=$(awk -F= '$1 == "CONFIG_SYS_SPI_U_BOOT_OFFS" { print $2; exit }' \
    "${config_file}")
[ -n "${spi_uboot_value}" ] || fail "u-boot.config lacks CONFIG_SYS_SPI_U_BOOT_OFFS"
spi_uboot_offset=$((spi_uboot_value))
spi_magic=$(dd if="${spi}" bs=1 skip="${spi_uboot_offset}" count=4 \
    status=none | od -An -tx1 | tr -d ' \n')
[ "${spi_magic}" = d00dfeed ] ||
    fail "SPI image lacks FIT at CONFIG_SYS_SPI_U_BOOT_OFFS"

require_part_fit idbloader.img "${idb_offset}" "${idb}" "${uboot_offset}"
require_part_fit u-boot.itb "${uboot_offset}" "${uboot}" "${logo_offset}"
require_part_fit 'MMC logo.img' "${logo_offset}" "${logo_raw}" "${env_offset}"
require_part_fit u-boot-rockchip-spi.bin 0 "${spi}" "${logo_offset}"
require_part_fit 'SPI logo.img' "${logo_offset}" "${logo_raw}" "${env_offset}"

mmc_name=${board}-uboot-${size_mib}m-mmc.bin
spi_name=${board}-uboot-${size_mib}m-spi.bin
mmc_firmware=${out}/${mmc_name}
spi_firmware=${out}/${spi_name}
fill_ff "${mmc_firmware}" "${firmware_bytes}"
fill_ff "${spi_firmware}" "${firmware_bytes}"
write_at "${mmc_firmware}" "${idb_offset}" "${idb}"
write_at "${mmc_firmware}" "${uboot_offset}" "${uboot}"
write_at "${mmc_firmware}" "${logo_offset}" "${logo_raw}"
write_at "${spi_firmware}" 0 "${spi}"
write_at "${spi_firmware}" "${logo_offset}" "${logo_raw}"
stamp_target "${mmc_firmware}" MMC
stamp_target "${spi_firmware}" SPI

mmc_update=${out}/firmware-update-mmc.bin
spi_update=${out}/firmware-update-spi.bin
dd if="${mmc_firmware}" of="${mmc_update}" bs=512 \
    count=$((env_offset / sector)) status=none
dd if="${spi_firmware}" of="${spi_update}" bs=512 \
    count=$((env_offset / sector)) status=none
for update in "${mmc_update}" "${spi_update}"; do
	[ "$(marker_count "${update}" "${compat_prefix}")" -eq 1 ] ||
	    fail "${update##*/} must contain exactly one compatibility marker"
	require_exact_nul_marker "${update}" "${compat_marker}"
	[ "$(marker_count "${update}" "${version_prefix}")" -eq 1 ] ||
	    fail "${update##*/} must contain exactly one version marker"
done

spi_update_size=$(file_size "${spi_update}")
cat > "${out}/uboot-spi-update.request" <<EOF
version=1
size=${spi_update_size}
sha256=$(sha256 -q "${spi_update}")
EOF

idb_size=$(file_size "${idb}")
uboot_size=$(file_size "${uboot}")
spi_size=$(file_size "${spi}")
cat > "${out}/FIRMWARE-LAYOUT.txt" <<EOF
Firmware size: ${size_mib} MiB
Fill byte: 0xff
Firmware compatibility: ${firmware_compat}
MMC image: ${mmc_name}
  idbloader.img: LBA 0x40, ${idb_size} bytes, limit 8 MiB
  u-boot.itb: LBA 0x4000, ${uboot_size} bytes, limit 12 MiB
SPI image: ${spi_name}
  u-boot-rockchip-spi.bin: offset 0x0, ${spi_size} bytes, limit 12 MiB
  SPL payload: 0x$(printf '%x' "${spi_uboot_offset}")
logo.img: LBA 0x6000, ${logo_raw_size} bytes, limit ${env_offset} bytes
environment primary: 0x$(printf '%x' "${env_offset}"), ${env_size} bytes
environment redundant: 0x$(printf '%x' "${env_offset_redund}"), ${env_size} bytes
environment reserved area: 0x$(printf '%x' "${env_offset}")-0x$(printf '%x' "${firmware_bytes}")
MMC updater: firmware-update-mmc.bin, LBA 64-0x$(printf '%x' $((env_offset / sector)))
SPI updater: firmware-update-spi.bin, 0x0-0x$(printf '%x' "${env_offset}")
EOF
