# G98 package policy.  Common scripts provide the called helper functions.

# board_image_add_packages
# Input: BOARD_PORTS_OUTPUT_DIR and optional BOARD_PACKAGE_OVERRIDE.
# Input example: BOARD_PACKAGE_OVERRIDE=/tmp/realtek-rge-kmod.pkg
# Output: registers G98 if_rge and YT921x packages with the image builder.
# Output example: one non-registered and one registered board package
board_image_add_packages()
{
	add_board_package non-registered "${BOARD_PACKAGE_OVERRIDE:-}" \
	    'realtek-rge-kmod-*.pkg'
	add_board_package registered '' 'motorcomm-yt921x-kmod-*.pkg'
}
