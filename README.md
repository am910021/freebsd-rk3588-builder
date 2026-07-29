# FreeBSD RK3588 Image Builder

在 FreeBSD amd64 主機上建立 NanoPC-T6 LTS 使用的：

- FriendlyELEC/Rockchip vendor U-Boot 2017 R26
- `if_rge.ko` kernel module 套件
- FreeBSD 14.3 arm64 SD card image

目前支援的 board 是 `nanopc-t6-lts`。

## 目錄

```text
freebsd-rk3588-builder/
├── boards/                         board 專屬設定、DTB、menu 與檔案覆蓋
├── dtb/                            相容用的共用 DTB
├── output/                         可交付產物
│   └── 14.3-p16/                   image、txz 與 checksum
├── src/
│   ├── devicetree-rebasing/
│   ├── freebsd-src/
│   ├── if_rge_freebsd/
│   ├── rkbin/
│   └── u-boot-2017/
├── work/                           可重建的 object 與中間產物
│   ├── if_rge_freebsd/
│   ├── obj/
│   └── uboot-r26-16m/
├── builder.conf                    共用設定
├── checkout.sh                     取得及更新原始碼
├── build-freebsd-release.sh        建立 FreeBSD base.txz 與 kernel.txz
├── build-vendor2017-r26-complete.sh
├── build-if-rge-freebsd.sh
└── make-nanopc-t6-freebsd14-image.sh
```

`src/`、`work/` 與 `output/` 不納入 builder Git repository。

## 設定

共用預設值位於 `builder.conf`，board 專屬設定位於：

```text
boards/nanopc-t6-lts/board.conf
```

所有設定都可以用環境變數覆蓋。常用項目：

```sh
BOARD=nanopc-t6-lts
FIRMWARE_MIB=16
ESP_SIZE_MIB=256
SWAP_SIZE_MIB=1024
ROOT_SIZE_MIB=2048
IMAGE_TAIL_MIB=96
JOBS=16
```

每個 board 分別指定 U-Boot 階段與 FreeBSD 階段使用的 DTB：

```sh
UBOOT_RUNTIME_DTB=${BOARD_DIR}/dtb/rk3588-nanopi6-rev07.dtb
FREEBSD_DTB=${BOARD_DIR}/dtb/rk3588-nanopc-t6.dtb
```

Git 來源可以使用 branch，或用 commit 固定版本：

```sh
UBOOT_BRANCH=yuri/nanopc-t6_lts
UBOOT_COMMIT=
RKBIN_BRANCH=master
RKBIN_COMMIT=
```

設定 `*_COMMIT` 時會忽略對應的 `*_BRANCH`，將乾淨的 repository
重設到指定 commit。

## 取得原始碼

```sh
cd /root/freebsd-rk3588-builder
./checkout.sh
```

如果任何既有 source repository 有未提交修改，`checkout.sh` 會在更新
任何 repository 前終止。

## 輸入檔案

建立完整 image 前需要：

```text
output/14.3-p16/base.txz
output/14.3-p16/kernel.txz
output/14.3-p16/if_rge.txz
work/uboot-latest/
```

`base.txz` 與 `kernel.txz` 由目前的 FreeBSD arm64 release build 產生。
使用 builder 內的 source 與 object 目錄建立：

```sh
./build-freebsd-release.sh
```

預設路徑：

```sh
FREEBSD_SRC_DIR=${BUILDER_ROOT}/src/freebsd-src
FREEBSD_OBJ_VERSION=14.3-p16  # 從 sys/conf/newvers.sh 自動取得
FREEBSD_OBJ_ROOT=${BUILDER_ROOT}/work/obj/${FREEBSD_OBJ_VERSION}
FREEBSD_OBJ=${FREEBSD_OBJ_ROOT}/arm64.aarch64
KERNBUILDDIR=${FREEBSD_OBJ}/sys/RK3588-T6-NORE
```

`build-if-rge-freebsd.sh` 會直接使用同一套 kernel object 與 arm64
toolchain。

## 建立 FreeBSD base 與 kernel

```sh
cd /root/freebsd-rk3588-builder
./build-freebsd-release.sh
```

腳本使用：

- `src/freebsd-src`
- `work/obj/<FreeBSD 版本>/arm64.aarch64`
- `boards/nanopc-t6-lts/board.conf` 的 `FREEBSD_KERNCONF`

輸出：

```text
output/<FreeBSD 版本>/base.txz
output/<FreeBSD 版本>/kernel.txz
```

## 建立 U-Boot

預設建立 16 MiB firmware：

```sh
./build-vendor2017-r26-complete.sh
```

明確建立 16 或 32 MiB firmware：

```sh
./build-vendor2017-r26-complete.sh 16
./build-vendor2017-r26-complete.sh 32
```

輸出：

```text
work/uboot-r26-16m/
├── idbloader.img
├── u-boot.itb
├── uboot-runtime.dtb
├── logo.bmp
├── logo.img
├── dualboot.cmd
├── dualboot.scr
├── nanopc-t6-lts-uboot-16m.bin
├── FIRMWARE-LAYOUT.txt
├── BUILD-INFO.txt
└── SHA256SUMS
```

`work/uboot-latest` 會指向最新完成的 bundle。

### Device trees

`UBOOT_RUNTIME_DTB` 會以 `dts/kern.dtb` 嵌入 `u-boot.itb` 的
`kern-fdt`，供 vendor U-Boot runtime 初始化硬體。

`FREEBSD_DTB` 會複製到 ESP；U-Boot menu 載入它、套用 DTBO，再透過
`bootefi` 交給 FreeBSD `loader.efi`。

### idbloader

`idbloader.img` 不再使用固定的 prebuilt。腳本在完成 U-Boot 編譯後執行：

```sh
./make.sh "CROSS_COMPILE=${CROSS_COMPILE}" --idblock
```

Vendor `make.sh` 會讀取 rkbin 的 `RKBOOT/RK3588MINIALL.ini`，將
`FlashData` 指定的 DDR/TPL 與 `FlashBoot` 指定的 SPL 封裝為 Rockchip
`rksd` ID block。

因此 DDR 與 SPL 版本由 `RKBIN_BRANCH` 或 `RKBIN_COMMIT` 決定。更新
rkbin 後必須重新進行冷開機測試。

### Firmware layout

16 MiB：

```text
0-8 MiB       idbloader/SPL 保留區，idbloader 位於 LBA 0x40
8-12 MiB      u-boot.itb，位於 LBA 0x4000
12-16 MiB     logo.bmp 與 logo_kernel.bmp raw 區域
```

32 MiB：

```text
0-8 MiB       idbloader/SPL 保留區
8-16 MiB      u-boot.itb 保留區
16-32 MiB     logo raw 區域
```

目前 R26 包含固定 raw logo 讀取、logo 邊界檢查、vidconsole 初始化後
恢復 logo，以及 3 秒 U-Boot menu：

```text
NanoPC-T6-SD-FULL-R26-BOOTMENU-3S-LOGOFIX1
```

## 建立 if_rge

```sh
./build-if-rge-freebsd.sh
```

輸出：

```text
work/if_rge_freebsd/if_rge.ko
output/14.3-p16/if_rge-<commit>-freebsd14.3-p16-arm64.txz
output/14.3-p16/if_rge.txz -> if_rge-<commit>-freebsd14.3-p16-arm64.txz
```

## 建立 FreeBSD image

使用 `builder.conf` 的預設輸入：

```sh
./make-nanopc-t6-freebsd14-image.sh
```

或明確指定 txz 與輸出檔：

```sh
./make-nanopc-t6-freebsd14-image.sh \
    output/14.3-p16/base.txz \
    output/14.3-p16/kernel.txz \
    output/14.3-p16/if_rge.txz \
    output/14.3-p16/nanopc-t6-lts-freebsd14.3.img
```

使用 32 MiB U-Boot 時，兩個階段必須使用相同設定：

```sh
./build-vendor2017-r26-complete.sh 32
FIRMWARE_MIB=32 ./make-nanopc-t6-freebsd14-image.sh
```

預設 image layout：

```text
0-16 MiB       raw U-Boot firmware 與 GPT metadata
16-272 MiB     p1 EFI System Partition
272-1296 MiB   p2 FreeBSD swap
1296-3344 MiB  p3 FreeBSD UFS root
3344-3440 MiB  未分配空間，供 growfs 使用
```

Image 內會安裝：

- `/EFI/FreeBSD/loader.efi`
- `FREEBSD_DTB`
- `/EFI/overlays.conf` 與 board 指定的 DTBO
- R26 U-Boot menu
- `if_rge.ko`
- `growfs_enable="YES"`
- `boot_multicons="YES"`
- `console="comconsole,efi"`

輸出 image 旁會同時產生：

```text
<image>.sha256
<image>.build-info.txt
```

## 寫入與驗證

寫入前必須再次確認目標裝置名稱；這個動作會覆蓋整個裝置：

```sh
dd if=output/<FreeBSD 版本>/<image>.img of=/dev/daX bs=1m conv=sync status=progress
sync
```

每次變更 U-Boot、rkbin、任一 DTB 或 FreeBSD kernel 後，至少確認：

1. UART 顯示 DDR、SPL 與 R26 版本 marker。
2. HDMI 在 U-Boot menu 前顯示 logo。
3. U-Boot menu 倒數為 3 秒。
4. FreeBSD loader menu 可由 HDMI 與 UART 顯示。
5. FreeBSD 能掛載 `ufs:/dev/ufs/nanopc_t6_root`。
6. `if_rge.ko` 載入且網路可用。
