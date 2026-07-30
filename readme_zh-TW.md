# FreeBSD RK3588 Image Builder

在 FreeBSD amd64 主機上建立 RK3588 SBC 使用的：

- U-Boot 2026.07
- `if_rge.ko` kernel module 套件
- FreeBSD arm64 SD card image

目前支援的 board 是 `nanopc-t6-lts`。

## 必要建置順序

必須依照以下順序執行。更改順序可能產生不完整或內容不一致的 image。

1. Clone builder 並進入目錄：

   ```sh
   git clone https://github.com/am910021/freebsd-rk3588-builder.git
   cd freebsd-rk3588-builder
   ```

2. 選擇 board。只有需要客製化其他參數時才修改 `builder.conf`：

   ```sh
   export BOARD=nanopc-t6-lts
   ```

3. 取得或更新所有 source repositories：

   ```sh
   ./checkout.sh
   ```

4. 建立完整 U-Boot firmware bundle：

   ```sh
   ./build-u-boot-2026.07-complete.sh
   ```

5. 建立 FreeBSD base 與 kernel：

   ```sh
   ./build-freebsd-release.sh
   ```

6. 建立設定的 ports：

   ```sh
   ./build-ports.sh
   ```

7. 組合最終 FreeBSD image：

   ```sh
   ./make-freebsd14-image.sh
   ```

## 目錄

```text
freebsd-rk3588-builder/
├── boards/                         board 專屬設定、DTS、menu 與檔案覆蓋
├── output/                         可交付產物
│   └── 14.3-p16/                   image、txz 與 checksum
├── src/
│   ├── freebsd-src/
│   ├── ports/
│   ├── rkbin/
│   └── u-boot-2026.07/
├── work/                           可重建的 object 與中間產物
│   ├── obj/
│   └── uboot-2026.07-16m/
├── builder.conf                    共用設定
├── checkout.sh                     取得及更新原始碼
├── build-freebsd-release.sh        建立 FreeBSD base.txz 與 kernel.txz
├── build-u-boot-2026.07-complete.sh
├── build-ports.sh                  從 ports 建立 FreeBSD 目標套件
└── make-freebsd14-image.sh
```

`src/`、`work/` 與 `output/` 不納入 builder Git repository。

## 設定

共用預設值位於 `builder.conf`，board 專屬設定位於：

```text
boards/nanopc-t6-lts/board.conf
```

所有設定都可以用環境變數覆蓋。常用項目：

```sh
export BOARD=nanopc-t6-lts
FIRMWARE_MIB=16
ESP_SIZE_MIB=256
SWAP_SIZE_MIB=512
ROOT_SIZE_MIB=1024
IMAGE_TAIL_MIB=96
JOBS=16
```

`builder.conf` 不提供預設 board。未設定 `BOARD` 時，U-Boot 與 image
建置腳本會直接終止。以下 board 建置範例均假設已執行上述 `export`。

設定 `SWAP_SIZE_MIB=0` 時不建立 swap partition，root filesystem 會成為
`p2`；大於零時維持 `p2` swap、`p3` root。

Root filesystem 預設為 UFS。建立 ZFS root image 時建議至少配置 2 GiB：

```sh
env ROOTFS_TYPE=zfs ROOT_SIZE_MIB=2048 \
    ./make-freebsd14-image.sh
```

NanoPC-T6 LTS 的 board 設定將 ZFS pool 設為 `nanopc_t6`，bootfs 為
`nanopc_t6/ROOT/default`。可以用 `ZFS_POOL_NAME` 覆蓋 pool 名稱。

每個 board 指定衍生自 U-Boot upstream DTS 的 FreeBSD DTS：

```sh
FREEBSD_DTS=${BOARD_DIR}/dts/rk3588-nanopc-t6-lts-freebsd.dts
```

U-Boot control DTB 由 `src/u-boot-2026.07` 的
`nanopc-t6-rk3588_defconfig` 建置，不再嵌入 vendor 2017 的 runtime
DTB。

Git 來源可以使用 branch，或用 commit 固定版本：

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

設定 `*_COMMIT` 時會忽略對應的 `*_BRANCH`，將乾淨的 repository
重設到指定 commit。

## 取得原始碼

```sh
cd /root/freebsd-rk3588-builder
BOARD=nanopc-t6-lts ./checkout.sh
```

如果任何既有 source repository 有未提交修改，`checkout.sh` 會在更新
任何 repository 前終止。`BOARD` 只決定板級建置設定，不影響這四個
source repository 的同步。

## 輸入檔案

建立完整 image 前需要：

```text
output/14.3-p16/base.txz
output/14.3-p16/kernel.txz
output/14.3-p16/realtek-rge-kmod-20260728.pkg
work/uboot-latest/
```

`base.txz` 與 `kernel.txz` 由目前的 FreeBSD arm64 release build 產生。
它們會在步驟 5 使用 builder 內的 source 與 object 目錄建立。

預設路徑：

```sh
FREEBSD_SRC_DIR=${BUILDER_ROOT}/src/freebsd-src
FREEBSD_OBJ_VERSION=14.3-p16  # 從 sys/conf/newvers.sh 自動取得
FREEBSD_OBJ_ROOT=${BUILDER_ROOT}/work/obj/${FREEBSD_OBJ_VERSION}
FREEBSD_OBJ=${FREEBSD_OBJ_ROOT}/arm64.aarch64
KERNBUILDDIR=${FREEBSD_OBJ}/sys/RK3588-T6-NORE
```

`build-ports.sh` 會用同一套 FreeBSD object tree 與 arm64 toolchain
建置 `PORT_ORIGINS` 內的所有 origin。image 組裝只使用建好的 package，
不會在組裝期間編譯 port。

## 建立 U-Boot

Firmware 大小由 `builder.conf` 的 `FIRMWARE_MIB` 決定，只需執行：

```sh
./build-u-boot-2026.07-complete.sh
```

支援的值為：

```text
FIRMWARE_MIB=16
FIRMWARE_MIB=32
```

輸出：

```text
work/nanopc-t6-lts-uboot-2026.07-16m/
├── idbloader.img
├── u-boot.itb
├── uboot-control.dtb
├── freebsd-runtime.dtb
├── logo.bmp
├── logo.img
├── bootmenu.env
├── nanopc-t6-lts-uboot-16m.bin
├── FIRMWARE-LAYOUT.txt
├── BUILD-INFO.txt
└── SHA256SUMS
```

`work/uboot-latest` 會指向最新完成的 bundle。

映像檔會將 `bootmenu.env` 安裝為 `/bootmenu.env`。U-Boot 只會匯入
`bootmenu_title`、`bootmenu_delay` 與 `bootmenu_0` 到 `bootmenu_9`，
並依序嘗試 `mmc1:1`、`mmc0:1`。檔案不存在或格式錯誤時會使用內建的
FreeBSD/CLI 安全選單。

### Device trees

U-Boot FIT 內的 control DTB 直接由 U-Boot 2026.07 source 建置。
Builder 只關閉不參與目標 firmware 的 `TOOLS_MKEFICAPSULE` host tool，
因此 FreeBSD build host 不需要額外安裝 GnuTLS headers。

Board 的 `FREEBSD_DTS` 會 include U-Boot 2026.07 upstream DTS，再加入
FreeBSD 所需的 crypto、低頻 CPU OPP、USB3-A 與固定 Type-C host 設定。
建置結果 `freebsd-runtime.dtb` 會複製到 ESP，並由 U-Boot 交給 FreeBSD
`loader.efi`。Type-C host 設定已直接編入 DTB，不再需要 runtime DTBO。

### idbloader

`idbloader.img` 由標準 U-Boot build 直接產生：

```sh
gmake O=<build-dir> \
    BL31="${UBOOT_BL31}" \
    ROCKCHIP_TPL="${UBOOT_ROCKCHIP_TPL}"
```

預設固定使用已驗證的 rkbin commit
`feab2172b40f831a1f0c0e2eacc348c19ea2f780`、BL31 v1.48 與 DDR TPL
v1.18。更新 rkbin 後必須重新進行冷開機測試。

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
8-12 MiB      u-boot.itb 保留區
12-32 MiB     logo raw 區域
```

目前 R81 包含 raw logo、HDMI/vidconsole、FreeBSD EFI 啟動，以及
3 秒內建 U-Boot menu：

```text
NanoPC-T6-LTS-2026.07-R81-LOGO
```

## 建立 FreeBSD base 與 kernel

```sh
cd /root/freebsd-rk3588-builder
./build-freebsd-release.sh
```

設定 `NO_CLEAN=YES` 可沿用既有 world、kernel 與 release objects：

```sh
NO_CLEAN=YES ./build-freebsd-release.sh
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

## 建立 Ports

```sh
./build-ports.sh
```

輸出：

```text
output/<FreeBSD 版本>/realtek-rge-kmod-<版本>.pkg
output/<FreeBSD 版本>/realtek-rge-kmod-<版本>.pkg.sha256
output/<FreeBSD 版本>/rk3588-installer-<版本>.pkg
output/<FreeBSD 版本>/rk3588-installer-<版本>.pkg.sha256
```

## 建立 FreeBSD image

使用 `builder.conf` 的預設輸入：

```sh
./make-freebsd14-image.sh
```

或明確指定 txz 與輸出檔：

```sh
./make-freebsd14-image.sh \
    output/14.3-p16/base.txz \
    output/14.3-p16/kernel.txz \
    output/14.3-p16/realtek-rge-kmod-20260728.pkg \
    output/14.3-p16/nanopc-t6-lts-freebsd14.3.img
```

`build-u-boot-2026.07-complete.sh` 與 image builder 都使用
`builder.conf` 的 `FIRMWARE_MIB`，不需分別傳入。

預設 image layout：

```text
0-16 MiB       raw U-Boot firmware 與 GPT metadata
16-272 MiB     p1 EFI System Partition
272-784 MiB    p2 FreeBSD swap
784-1808 MiB   p3 FreeBSD UFS root
1808-1904 MiB  未分配空間，供 growfs 使用
```

不建立 swap：

```sh
env SWAP_SIZE_MIB=0 ./make-freebsd14-image.sh
```

這同時適用於 UFS 與 ZFS；腳本會設定 `growfs_swap_size="0"`，避免
first boot 的 `growfs` 自動補建 swap。

對應 layout：

```text
0-16 MiB       raw U-Boot firmware 與 GPT metadata
16-272 MiB     p1 EFI System Partition
272-1296 MiB   p2 FreeBSD UFS root
1296-1392 MiB  未分配空間，供 growfs 使用
```

Image 內會安裝：

- `/EFI/FreeBSD/loader.efi`
- `FREEBSD_DTB`
- U-Boot 2026.07 內建 boot menu
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

1. UART 顯示 DDR、SPL 與 U-Boot 2026.07 版本 marker。
2. HDMI 在 U-Boot menu 前顯示 logo。
3. U-Boot menu 倒數為 3 秒。
4. FreeBSD loader menu 可由 HDMI 與 UART 顯示。
5. FreeBSD 能掛載 UFS root，或 `zfs:nanopc_t6/ROOT/default`。
6. `if_rge.ko` 載入且網路可用。
