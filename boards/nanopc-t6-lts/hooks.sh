# NanoPC-T6-LTS package policy.  Common scripts provide the called helpers.

# board_ports_publish_extra_packages
# Input: runtime package helpers and target/output globals from build-ports.sh.
# Input example: TXZ_ROOT=/output/14.3-p16
# Output: publishes the architecture-independent rtlbt-firmware package.
# Output example: <TXZ_ROOT>/rtlbt-firmware-20251111.pkg
board_ports_publish_extra_packages()
{
	fetch_runtime_package rtlbt-firmware comms/rtlbt-firmware
}

# board_image_add_packages
# Input: TXZ_ROOT and optional BOARD_PACKAGE_OVERRIDE from the image builder.
# Input example: BOARD_PACKAGE_OVERRIDE=/tmp/realtek-rge-kmod.pkg
# Output: registers NanoPC if_rge and RTL Bluetooth packages with the builder.
# Output example: one non-registered and one registered board package
board_image_add_packages()
{
	add_board_package non-registered "${BOARD_PACKAGE_OVERRIDE:-}" \
	    'realtek-rge-kmod-*.pkg'
	add_board_package registered '' 'rtlbt-firmware-*.pkg'
}
