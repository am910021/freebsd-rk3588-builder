echo "NanoPC-T6 LTS FreeBSD 14.3 image R26-BOOTMENU-3S"
echo "Default after timeout: FreeBSD 14.3"

if test -z "${scriptaddr}"; then setenv scriptaddr 0x00500000; fi
if test -z "${kernel_addr_r}"; then setenv kernel_addr_r 0x02000000; fi
if test -z "${fdt_addr_r}"; then setenv fdt_addr_r 0x0a100000; fi
if test -z "${fdtoverlay_addr_r}"; then setenv fdtoverlay_addr_r 0x0a300000; fi
if test -z "${overlay_config_addr_r}"; then setenv overlay_config_addr_r 0x0a500000; fi

setenv apply_fdt_overlays 'setenv fdt_overlay_failed; setenv fdt_overlays; if load mmc 1:1 ${overlay_config_addr_r} /EFI/overlays.conf; then if env import -t ${overlay_config_addr_r} ${filesize}; then for overlay in ${fdt_overlays}; do echo Applying FDT overlay ${overlay}; if load mmc 1:1 ${fdtoverlay_addr_r} /EFI/overlays/${overlay}; then if fdt apply ${fdtoverlay_addr_r}; then echo Applied ${overlay}; else echo Failed to apply ${overlay}; setenv fdt_overlay_failed 1; fi; else echo Failed to load ${overlay}; setenv fdt_overlay_failed 1; fi; done; else echo Failed to import /EFI/overlays.conf; setenv fdt_overlay_failed 1; fi; else echo No /EFI/overlays.conf; fi; test -z "${fdt_overlay_failed}"'
setenv boot_freebsd_image 'setenv stdout serial,vidconsole; setenv stderr serial,vidconsole; coninfo; mmc dev 1; run usb_vbus_on; echo Booting FreeBSD 14.3 from mmc 1:1; if load mmc 1:1 ${fdt_addr_r} /dtb/rk3588-nanopc-t6.dtb; then if fdt addr ${fdt_addr_r} && fdt resize 0x100000; then if run apply_fdt_overlays; then if load mmc 1:1 ${kernel_addr_r} /EFI/FreeBSD/loader.efi || load mmc 1:1 ${kernel_addr_r} /EFI/BOOT/BOOTAA64.EFI; then bootefi ${kernel_addr_r} ${fdt_addr_r}; fi; fi; fi; fi; echo FreeBSD boot failed'
setenv bootmenu_0 'FreeBSD 14.3=run boot_freebsd_image'
setenv bootmenu_1 'U-Boot CLI=exit'
setenv bootmenu_delay 3

setenv stdout serial,vidconsole
setenv stderr serial,vidconsole
bootmenu 3
run boot_freebsd_image
