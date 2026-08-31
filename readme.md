# FreeBSD RK3588 Image Builder

[Traditional Chinese](readme_zh-TW.md)

Build the following for RK3588 SBCs on a FreeBSD amd64 host:

- U-Boot 2026.07
- The `if_rge.ko` kernel module package
- A FreeBSD arm64 SD card image

The currently supported board is `nanopc-t6-lts`.

## Build Host Requirements

The builder is tested on a FreeBSD 14.3 amd64 host. Install the required
packages with `pkg` only:

```sh
pkg install -y git aarch64-none-elf-gcc gmake bison swig \
    python3 py312-setuptools py312-more-itertools py312-pyelftools
```

FreeBSD base provides the remaining host tools, including `cc`, `flex`,
`openssl`, `dtc`, `make`, `makefs`, `mdconfig`, and `gpart`.

Verify the two non-obvious U-Boot requirements with:

```sh
swig -version
python3 -c 'import elftools, setuptools'
```

Do not install Python 3.8, `ensurepip`, pipenv, or pip-managed build modules.
The scripts use the packaged `/usr/local/bin/python3`; U-Boot uses SWIG for
`pylibfdt` and pyelftools for the Rockchip FIT image assembled by binman.

## Quick Start

Clone the builder, select the board, and run the five build scripts in the
exact order shown below. Each step produces inputs consumed by a later step.

```sh
git clone https://github.com/am910021/freebsd-rk3588-builder.git
cd freebsd-rk3588-builder
export BOARD=nanopc-t6-lts
```

```text
checkout.sh -> build-u-boot-2026.07-complete.sh -> build-freebsd-release.sh -> build-ports.sh -> make-freebsd14-image.sh
```

```sh
./checkout.sh
./build-u-boot-2026.07-complete.sh
./build-freebsd-release.sh
./build-ports.sh
./make-freebsd14-image.sh
```

## Directory Layout

```text
freebsd-rk3588-builder/
|-- boards/                         Board-specific settings, DTS, menu, and file overlays
|-- output/                         Deliverable artifacts
|   `-- 14.3-p16/                   Images, txz archives, and checksums
|-- src/
|   |-- freebsd-src/
|   |-- ports/
|   |-- rkbin/
|   `-- u-boot-2026.07/
|-- work/                           Rebuildable objects and intermediate artifacts
|   |-- obj/
|   `-- uboot-2026.07-16m/
|-- builder.conf                    Shared settings
|-- checkout.sh                     Fetch and update source repositories
|-- build-freebsd-release.sh        Build FreeBSD base.txz and kernel.txz
|-- build-u-boot-2026.07-complete.sh
|-- build-ports.sh                  Build target FreeBSD packages from ports
`-- make-freebsd14-image.sh
```

`src/`, `work/`, and `output/` are not tracked by the builder Git repository.

## Configuration

Shared defaults are in `builder.conf`. Board-specific settings are in:

```text
boards/nanopc-t6-lts/board.conf
boards/g98/board.conf
```

All settings can be overridden with environment variables. Common settings:

```sh
export BOARD=nanopc-t6-lts
# or: export BOARD=g98
FIRMWARE_MIB=16
ESP_SIZE_MIB=256
SWAP_SIZE_MIB=512
ROOT_SIZE_MIB=1024
IMAGE_TAIL_MIB=96
JOBS=16
```

`builder.conf` does not provide a default board. The U-Boot and image build
scripts stop immediately when `BOARD` is not set. The board build examples
below assume that the preceding `export` command has been run.

Set `SWAP_SIZE_MIB=0` to omit the swap partition, making the root filesystem
`p3`. A value greater than zero keeps swap on `p3` and root on `p4`.

The root filesystem defaults to UFS. Allocate at least 2 GiB when building a
ZFS root image:

```sh
env ROOTFS_TYPE=zfs ROOT_SIZE_MIB=2048 \
    ./make-freebsd14-image.sh
```

The NanoPC-T6 LTS board settings use `nanopc_t6` as the ZFS pool and
`nanopc_t6/ROOT/default` as the bootfs. Override the pool name with
`ZFS_POOL_NAME`.

Each board uses the same outer layout: `board.conf`, `assets/`, `dts/`, and
an optional `loader.conf`. Each board specifies a FreeBSD DTS derived from
the upstream U-Boot DTS:

```sh
FREEBSD_DTS=${BOARD_DIR}/dts/rk3588-nanopc-t6-lts-freebsd.dts
```

The U-Boot control DTB is built from the defconfig selected by `board.conf`.
G98 keeps its not-yet-upstream board files under `boards/g98/u-boot/`; the
build uses a temporary source clone to apply them without modifying
`src/u-boot-2026.07`. The vendor 2017 runtime DTB is no longer embedded.

Git sources can follow a branch or be pinned to a commit:

```sh
FREEBSD_URL=https://github.com/am910021/freebsd-src.git
UBOOT_URL=https://github.com/am910021/u-boot.git
RKBIN_URL=https://github.com/am910021/rkbin.git
PORTS_URL=https://github.com/am910021/rk3588-ports.git
UBOOT_BRANCH=yuri/rk3588
UBOOT_COMMIT=
PORTS_BRANCH=main
PORTS_COMMIT=
RKBIN_BRANCH=master
RKBIN_COMMIT=
```

A non-empty `*_COMMIT` overrides the corresponding `*_BRANCH` and resets the
clean repository to that exact commit.

## Step 1: Fetch Sources

```sh
cd /root/freebsd-rk3588-builder
BOARD=nanopc-t6-lts ./checkout.sh
```

`checkout.sh` forcibly restores every existing source repository to its
configured remote branch or pinned commit after a successful fetch. It removes
local commits, tracked changes, untracked files, and ignored files without a
backup. `BOARD` selects board-level build settings and does not affect
synchronization of the four source repositories.

## Build Artifacts

A complete image requires:

```text
output/14.3-p16/base.txz
output/14.3-p16/kernel.txz
output/14.3-p16/realtek-rge-kmod-20260728.pkg
work/uboot-latest/
```

`base.txz` and `kernel.txz` come from the current FreeBSD arm64 release build.
They are produced by step 3 using the builder source and object directories.

Default paths:

```sh
FREEBSD_SRC_DIR=${BUILDER_ROOT}/src/freebsd-src
FREEBSD_OBJ_VERSION=14.3-p16  # Derived automatically from sys/conf/newvers.sh
FREEBSD_OBJ_ROOT=${BUILDER_ROOT}/work/obj/${FREEBSD_OBJ_VERSION}
FREEBSD_OBJ=${FREEBSD_OBJ_ROOT}/arm64.aarch64
KERNBUILDDIR=${FREEBSD_OBJ}/sys/RK3588-T6-NORE
```

`build-ports.sh` builds every origin in `PORT_ORIGINS` with the same FreeBSD
object tree and arm64 toolchain. Image assembly consumes only the resulting
packages, installs those packages into the image, and never builds ports
itself.

## Step 2: Build U-Boot

`FIRMWARE_MIB` in `builder.conf` selects the firmware size. Run:

```sh
./build-u-boot-2026.07-complete.sh
```

Supported values:

```text
FIRMWARE_MIB=16
FIRMWARE_MIB=32
```

Output:

```text
work/nanopc-t6-lts-uboot-2026.07-16m/
|-- idbloader.img
|-- u-boot.itb
|-- uboot-control.dtb
|-- freebsd-runtime.dtb
|-- logo.bmp
|-- logo.img
|-- nanopc-t6-lts-uboot-16m.bin
|-- firmware-update.bin
|-- FIRMWARE-LAYOUT.txt
|-- BUILD-INFO.txt
`-- SHA256SUMS
```

`work/uboot-latest` points to the most recently completed bundle.

U-Boot discovers `/EFI/FreeBSD/loader.efi` on eMMC, SD, USB, NVMe, and
SATA/SCSI, in that order, and builds the menu dynamically. Persistent menu
settings are kept in U-Boot's redundant raw environment.

The installed `rk3588-uboot-config` command writes a validated request to the
mounted ESP. Multiple settings can be changed in one transaction:

```sh
rk3588-uboot-config set \
    freebsd_default_boot=usb0:2 \
    bootmenu_delay=5 \
    'bootmenu_title=*** FreeBSD U-Boot Boot Menu ***'
```

Allowed settings are `freebsd_default_boot`, `bootmenu_title`,
`bootmenu_delay`, and `logo_delay`. The first valid request found in eMMC,
SD, USB, NVMe, then SATA/SCSI order is applied at the next startup. U-Boot
saves the raw environment only when a value changed, then removes every
`/uboot-env.request` found on initialized storage. A failed environment save
leaves every request in place.

### Device Trees

The control DTB in the U-Boot FIT is built directly from the U-Boot 2026.07
source. The builder only disables the `TOOLS_MKEFICAPSULE` host tool, which is
not part of the target firmware, so the FreeBSD build host does not require
additional GnuTLS headers.

The board `FREEBSD_DTS` includes the upstream U-Boot 2026.07 DTS and adds the
crypto node, low-frequency CPU OPPs, USB3-A configuration, and fixed Type-C
host mode required by FreeBSD. The resulting `freebsd-runtime.dtb` is copied
to the ESP and passed to FreeBSD `loader.efi` by U-Boot. Type-C host mode is
compiled directly into the DTB, so a runtime DTBO is no longer required.

### idbloader

The standard U-Boot build directly produces `idbloader.img`:

```sh
gmake O=<build-dir> \
    BL31="${UBOOT_BL31}" \
    ROCKCHIP_TPL="${UBOOT_ROCKCHIP_TPL}"
```

The defaults use verified rkbin commit
`feab2172b40f831a1f0c0e2eacc348c19ea2f780`, BL31 v1.48, and DDR TPL v1.18.
Updating rkbin requires another complete cold-boot test.

### Firmware Layout

16 MiB:

```text
0-8 MiB       Reserved for idbloader/SPL; idbloader starts at LBA 0x40
8-12 MiB      u-boot.itb at LBA 0x4000
12-15.5 MiB   Raw logo area
15.5-16 MiB   Redundant U-Boot environment reserve
```

32 MiB:

```text
0-8 MiB       Reserved for idbloader/SPL
8-12 MiB      Reserved for u-boot.itb
12-15.5 MiB   Raw logo area
15.5-16 MiB   Redundant U-Boot environment reserve
16-32 MiB     Future firmware reserve
```

The primary and redundant environments are 64 KiB at `0xf80000` and
`0xf90000`. `firmware-update.bin` ends at `0xf80000`, so firmware updates do
not overwrite either copy. The full board firmware image is for newly
created disk images or complete external flashing.

The current R81 bundle includes the raw logo, HDMI/vidconsole, FreeBSD EFI
boot, and a built-in three-second U-Boot menu:

```text
NanoPC-T6-LTS-2026.07-R81-LOGO
```

## Step 3: Build FreeBSD Base and Kernel

```sh
cd /root/freebsd-rk3588-builder
./build-freebsd-release.sh
```

Set `NO_CLEAN=YES` to reuse existing world, kernel, and release objects:

```sh
NO_CLEAN=YES ./build-freebsd-release.sh
```

The script uses:

- `src/freebsd-src`
- `work/obj/<FreeBSD version>/arm64.aarch64`
- `FREEBSD_KERNCONF` from `boards/nanopc-t6-lts/board.conf`

Output:

```text
output/<FreeBSD version>/base.txz
output/<FreeBSD version>/kernel.txz
```

## Step 4: Build Ports

```sh
./build-ports.sh
```

Output:

```text
output/<FreeBSD version>/realtek-rge-kmod-<version>.pkg
output/<FreeBSD version>/realtek-rge-kmod-<version>.pkg.sha256
output/<FreeBSD version>/pkg-<version>.pkg
output/<FreeBSD version>/pkg-<version>.pkg.sha256
output/<FreeBSD version>/rk3588-installer-<version>.pkg
output/<FreeBSD version>/rk3588-installer-<version>.pkg.sha256
output/<FreeBSD version>/rk3588-uboot-config-<version>.pkg
output/<FreeBSD version>/rk3588-uboot-config-<version>.pkg.sha256
output/<FreeBSD version>/rtlbt-firmware-<version>.pkg
output/<FreeBSD version>/rtlbt-firmware-<version>.pkg.sha256
```

`build-ports.sh` builds the local `pkg`, driver, and installer ports, then
fetches the architecture-neutral `rtlbt-firmware` package from the configured
official FreeBSD pkg repository.

## Step 5: Build the FreeBSD Image

Use the default inputs from `builder.conf`:

```sh
./make-freebsd14-image.sh
```

Or explicitly specify the txz archives and output image:

```sh
./make-freebsd14-image.sh \
    output/14.3-p16/base.txz \
    output/14.3-p16/kernel.txz \
    output/14.3-p16/realtek-rge-kmod-20260728.pkg \
    output/14.3-p16/nanopc-t6-lts-freebsd14.3.img
```

Both `build-u-boot-2026.07-complete.sh` and the image builder use
`FIRMWARE_MIB` from `builder.conf`; it does not need to be passed separately.

### Installer package and payload

`PORT_ORIGINS` and `INSTALLER=YES` are independent:

- Including `sysutils/rk3588-installer` in `PORT_ORIGINS` installs the
  `rk3588-installer` package into the image.
- The image and every installed target include `rk3588-uboot-config`; the
  installer carries its package in the offline payload.
- `INSTALLER=YES` embeds `base.txz`, `kernel.txz`, firmware, DTB, and the
  offline packages. It does not install the installer package by itself.
- The image installs `rtlbt-firmware`, and the installer payload installs that
  official package into the target system. The target does not register the
  image-only `realtek-rge-kmod` or `rk3588-installer` packages.
- The image and installer payload include the locally built `pkg` package.
  This prevents the base-system pkg bootstrap stub from requiring a network
  connection before local packages can be installed.

An image with only `INSTALLER=YES` becomes usable after installing the
`rk3588-installer` package later. An image containing only the package has no
payload, so `rk3588-install` reports the missing payload and refuses to
install.

The image builder and `rk3588-install` generate new GPT partition GUIDs and
use `/dev/gptid/<GUID>` for UFS root, ESP, and swap references. Filesystem and
GPT labels remain descriptive only, so duplicate labels cannot redirect boot.

Default image layout:

```text
0-16 MiB       GPT metadata and p1 rk3588_firmware
16-272 MiB     p2 EFI System Partition
272-784 MiB    p3 FreeBSD swap
784-1808 MiB   p4 FreeBSD UFS root
1808-1904 MiB  Unallocated space for growfs
```

Omit the swap partition:

```sh
env SWAP_SIZE_MIB=0 ./make-freebsd14-image.sh
```

This applies to both UFS and ZFS. The script sets `growfs_swap_size="0"` to
prevent first-boot `growfs` from automatically creating a swap partition.

Corresponding layout:

```text
0-16 MiB       GPT metadata and p1 rk3588_firmware
16-272 MiB     p2 EFI System Partition
272-1296 MiB   p3 FreeBSD UFS root
1296-1392 MiB  Unallocated space for growfs
```

The image installs:

- `/EFI/FreeBSD/loader.efi`
- `FREEBSD_DTB`
- The built-in U-Boot 2026.07 boot menu
- `if_rge.ko`
- `growfs_enable="YES"`
- `boot_multicons="YES"`
- `console="comconsole,efi"`

The following files are generated next to the output image:

```text
<image>.sha256
<image>.build-info.txt
```

## Writing and Validation

Confirm the target device name again before writing. This operation
overwrites the entire target device:

```sh
dd if=output/<FreeBSD version>/<image>.img of=/dev/daX bs=1m conv=sync status=progress
sync
```

After changing U-Boot, rkbin, any DTB, or the FreeBSD kernel, verify at least:

1. UART shows the DDR, SPL, and U-Boot 2026.07 version markers.
2. HDMI displays the logo before the U-Boot menu.
3. The U-Boot menu countdown is three seconds.
4. The FreeBSD loader menu is visible on both HDMI and UART.
5. FreeBSD mounts the UFS root, or `zfs:nanopc_t6/ROOT/default`.
6. `if_rge.ko` loads and networking works.
