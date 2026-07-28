echo "NanoPC-T6 LTS FreeBSD 14.3 image R26-BOOTMENU-3S"
echo "Default after timeout: FreeBSD 14.3"

if test -z "${scriptaddr}"; then setenv scriptaddr 0x00500000; fi
if test -z "${kernel_addr_r}"; then setenv kernel_addr_r 0x02000000; fi
if test -z "${fdt_addr_r}"; then setenv fdt_addr_r 0x0a100000; fi

setenv boot_freebsd_image 'setenv stdout serial,vidconsole; setenv stderr serial,vidconsole; coninfo; mmc dev 1; run usb_vbus_on; echo Booting FreeBSD 14.3 from mmc 1:1; load mmc 1:1 ${fdt_addr_r} /dtb/rk3588-nanopc-t6.dtb; load mmc 1:1 ${kernel_addr_r} /EFI/FreeBSD/loader.efi || load mmc 1:1 ${kernel_addr_r} /EFI/BOOT/BOOTAA64.EFI; bootefi ${kernel_addr_r} ${fdt_addr_r}'
setenv bootmenu_0 'FreeBSD 14.3=run boot_freebsd_image'
setenv bootmenu_1 'U-Boot CLI=exit'
setenv bootmenu_delay 3

setenv stdout serial,vidconsole
setenv stderr serial,vidconsole
bootmenu 3
run boot_freebsd_image
