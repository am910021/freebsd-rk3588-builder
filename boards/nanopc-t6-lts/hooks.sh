# NanoPC-T6-LTS package policy.  Common scripts provide the called helpers.

# board_ports_publish_extra_packages
# Input: runtime package helpers and target/output globals from build-ports.sh.
# Input example: BOARD_PORTS_OUTPUT_DIR=/output/14.3-p16/ports/nanopc-t6-lts
# Output: publishes the architecture-independent rtlbt-firmware package.
# Output example: <BOARD_PORTS_OUTPUT_DIR>/rtlbt-firmware-20251111.pkg
board_ports_publish_extra_packages()
{
	fetch_runtime_package rtlbt-firmware comms/rtlbt-firmware
}

# board_image_add_packages
# Input: PORTS_OUTPUT_DIR, BOARD_PORTS_OUTPUT_DIR and optional BOARD_PACKAGE_OVERRIDE.
# Input example: BOARD_PACKAGE_OVERRIDE=/tmp/realtek-rge-kmod.pkg
# Output: registers NanoPC if_rge and RTL Bluetooth packages with the builder.
# Output example: one non-registered and one registered board package
board_image_add_packages()
{
	add_board_package non-registered "${BOARD_PACKAGE_OVERRIDE:-}" \
	    'realtek-rge-kmod-*.pkg' "${PORTS_OUTPUT_DIR}"
	add_board_package registered '' 'rtlbt-firmware-*.pkg'
}
