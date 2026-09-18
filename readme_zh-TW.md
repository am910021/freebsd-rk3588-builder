# FreeBSD RK3588 Image Builder

在 FreeBSD amd64 主機上建立 RK3588 SBC 使用的：

- U-Boot 2026.07
- `if_rge.ko` kernel module 套件
- FreeBSD arm64 SD card image

目前支援的 board 是 `nanopc-t6-lts`。

## 建置主機需求

Builder 已在 FreeBSD 14.3 amd64 主機驗證。所需套件全部使用 `pkg`
安裝：

```sh
pkg install -y git aarch64-none-elf-gcc gmake bison swig \
    python3 py312-setuptools py312-more-itertools py312-pyelftools
```

其餘 host 工具由 FreeBSD base 提供，包括 `cc`、`flex`、`openssl`、
`dtc`、`make`、`makefs`、`mdconfig` 與 `gpart`。

可用以下指令確認兩個較不明顯的 U-Boot 需求：

```sh
swig -version
python3 -c 'import elftools, setuptools'
```

不需要另外安裝 Python 3.8、`ensurepip`、pipenv 或由 pip 管理的建置
modules。Scripts 直接使用 package 提供的 `/usr/local/bin/python3`；
U-Boot 以 SWIG 建立 `pylibfdt`，Rockchip FIT image 的 binman 階段則使用
pyelftools。

## 快速開始

Clone builder、選擇 board，接著嚴格依照下列順序執行五支建置腳本。
每個步驟都會產生後續步驟需要的輸入檔案。

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

## 目錄

```text
freebsd-rk3588-builder/
├── boards/                         board 專屬設定、DTS、menu、Port patch 與檔案覆蓋
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
boards/g98/board.conf
```

所有設定都可以用環境變數覆蓋。常用項目：

```sh
export BOARD=nanopc-t6-lts
# 或：export BOARD=g98
FIRMWARE_MIB=16
ESP_SIZE_MIB=256
INSTALLER_ESP_SIZE_MIB=50
SWAP_SIZE_MIB=512
ROOT_SIZE_MIB=1024
IMAGE_TAIL_MIB=96
JOBS=16
```

`builder.conf` 不提供預設 board。未設定 `BOARD` 時，U-Boot 與 image
建置腳本會直接終止。以下 board 建置範例均假設已執行上述 `export`。

設定 `SWAP_SIZE_MIB=0` 時不建立 swap partition，root filesystem 會成為
`p3`；大於零時維持 `p3` swap、`p4` root。

Root filesystem 預設為 UFS。建立 ZFS root image 時建議至少配置 2 GiB：

```sh
env ROOTFS_TYPE=zfs ROOT_SIZE_MIB=2048 \
    ./make-freebsd14-image.sh
```

NanoPC-T6 LTS 的 board 設定將 ZFS pool 設為 `nanopc_t6`，bootfs 為
`nanopc_t6/ROOT/default`。可以用 `ZFS_POOL_NAME` 覆蓋 pool 名稱。

每個 board 都使用相同的外層結構：`board.conf`、`assets/`、`dts/`，以及
可選的 `loader.conf` 與 `hooks.sh`。`hooks.sh` 只能定義函式；共用腳本
會呼叫該板實際提供的 hook，未提供的 hook 視為 no-op。每個 board 指定
衍生自 U-Boot upstream DTS 的 FreeBSD DTS：

```sh
FREEBSD_DTS=${BOARD_DIR}/dts/rk3588-nanopc-t6-lts-freebsd.dts
```

U-Boot control DTB 使用 `board.conf` 選定的 defconfig 建置。G98 尚未
進入 upstream 的 board 檔案放在 `boards/g98/u-boot/`；建置時會在臨時
source clone 中套用，不會修改 `src/u-boot-2026.07`。系統不再嵌入
vendor 2017 的 runtime DTB。

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

## 步驟 1：取得原始碼

```sh
cd /root/freebsd-rk3588-builder
BOARD=nanopc-t6-lts ./checkout.sh
```

remote fetch 成功後，`checkout.sh` 會強制將每個既有 source repository
還原到設定的遠端分支或指定 commit。本地額外 commit、tracked 異動、
untracked 檔案與 ignored 檔案都會直接刪除且不備份。`BOARD` 只決定板級
建置設定，不影響這四個 source repository 的同步。

## 建置產物

建立完整 image 前需要：

```text
output/14.3-p16/sets/base-14.3-p16_<commit>.txz
output/14.3-p16/sets/kernel-14.3-p16_<commit>.txz
output/14.3-p16/ports/realtek-rge-kmod-<版本>.pkg
output/14.3-p16/uboot-2026.07/16m/nanopc-t6-lts/
```

`base.txz` 與 `kernel.txz` 由目前的 FreeBSD arm64 release build 產生。
它們會在步驟 3 使用 builder 內的 source 與 object 目錄建立。

預設路徑：

```sh
FREEBSD_SRC_DIR=${BUILDER_ROOT}/src/freebsd-src
FREEBSD_OBJ_VERSION=14.3-p16  # 從 sys/conf/newvers.sh 自動取得
FREEBSD_OBJ_ROOT=${BUILDER_ROOT}/work/obj/${FREEBSD_OBJ_VERSION}
FREEBSD_OBJ=${FREEBSD_OBJ_ROOT}/arm64.aarch64
KERNBUILDDIR=${FREEBSD_OBJ}/sys/RK3588-NORE
```

`build-ports.sh` 會用同一套 FreeBSD object tree 與 arm64 toolchain
建置所選 board 的 `PORT_ORIGINS`。可選的
`board_ports_publish_extra_packages` hook 會發布不是由此 Ports tree 建立的
runtime package。image 組裝只使用這些輸出，不會在組裝期間編譯 port。

每個 Port 建置前，符合
`boards/<board>/ports/<category>/<port>/files/patch-*` 的板級 patch 會透過
標準 Ports `EXTRA_PATCHES` 機制套用。G98 使用這個機制保存 PCB 專屬的
RTL8125B 與 YT9215S LED profile，共用驅動 repository 不包含板級設定。

## 步驟 2：建立 U-Boot

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
output/14.3-p16/uboot-2026.07/16m/nanopc-t6-lts/
├── idbloader.img
├── u-boot.itb
├── uboot-control.dtb
├── freebsd-runtime.dtb
├── logo.bmp
├── logo.img
├── nanopc-t6-lts-uboot-16m-mmc.bin
├── nanopc-t6-lts-uboot-16m-spi.bin
├── firmware-update-mmc.bin
├── firmware-update-spi.bin
├── uboot-spi-update.request
├── FIRMWARE-LAYOUT.txt
├── BUILD-INFO.txt
└── SHA256SUMS
```

同一份 bundle 仍會保留在 `work/nanopc-t6-lts-uboot-2026.07-16m/`。
`work/<board>-uboot-latest` 會指向該板型最新完成的 bundle；image builder
改從 `output/` 下對應板型與容量的目錄讀取。相容用的 `work/uboot-latest` 仍會指向所有板型中
最後完成的 bundle；不可用它選取其他板型的 artifact。

每個板型 bundle 都會同時產生兩份供外部完整燒錄的映像：eMMC/SD 使用
`<board>-uboot-<size>m-mmc.bin`，SPI NOR 使用
`<board>-uboot-<size>m-spi.bin`。另外也會產生保留 environment 的對應線上更新
payload：`firmware-update-mmc.bin` 與 `firmware-update-spi.bin`。四者的
U-Boot 功能相同，但 Rockchip raw boot layout 不能互換；installer 的 GPT
firmware partition 永遠使用完整 MMC 映像。

U-Boot 會依 eMMC、SD、USB、NVMe、SATA/SCSI 順序尋找
`/EFI/FreeBSD/loader.efi` 並動態產生選單。持久選單設定保存在 U-Boot
redundant raw environment。

安裝後的 `rk3588-uboot-tools` 指令會在已掛載的 ESP 寫入經驗證的
request，並可在同一筆 request 變更多個設定：

```sh
rk3588-uboot-tools set \
    freebsd_default_boot=usb0:2 \
    bootmenu_delay=5 \
    'bootmenu_title=*** FreeBSD U-Boot Boot Menu ***'
```

在支援 compatibility marker 的目標上，同一工具會先驗證板型、開機媒體、
容量、映像大小、版本 marker 與 SHA-256，再把一次性更新要求放入 ESP：

```sh
rk3588-uboot-tools upgrade verify firmware-update-mmc.bin
rk3588-uboot-tools upgrade firmware-update-mmc.bin
```

只有 U-Boot 本身從 SPI 執行時才改用 `firmware-update-spi.bin`。固定位置的
target marker 對 eMMC/SD 為 `MMC`，對 SPI NOR 為 `SPI`；不符合時會在移除
request 或寫入儲存裝置前拒絕更新。

U-Boot 會再次驗證 request 與映像，依自己的開機媒體選擇 MMC 或 SPI、保留
raw environment，並在 reset 前完成整段寫入回讀比對。不支援的目標不會寫入。

允許的設定為 `freebsd_default_boot`、`bootmenu_title`、
`bootmenu_delay` 與 `logo_delay`。下次啟動時會依 eMMC、SD、USB、NVMe、
SATA/SCSI 順序套用第一筆有效 request。只有設定值改變時才會寫入 raw
environment，成功後移除所有已初始化儲存裝置上的
`/uboot-env.request`；environment 寫入失敗時則全部保留。

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
12-15.5 MiB   logo raw 區域
15.5-16 MiB   redundant U-Boot environment 保留區
```

32 MiB：

```text
0-8 MiB       idbloader/SPL 保留區
8-12 MiB      u-boot.itb 保留區
12-31.5 MiB   logo 與 firmware 擴充區域
31.5-32 MiB   redundant U-Boot environment 保留區
```

16 MiB 的 primary/redundant environment 位於 `0xf80000`/`0xf90000`；
32 MiB 則位於 `0x1f80000`/`0x1f90000`。更新映像結束於所選容量的 primary
environment 前，因此不會覆蓋任一份環境。

`uboot-spi-update.request` 會記錄配對映像的大小與 SHA-256。Builder 只把
兩個更新檔留在輸出 bundle，不會自動將 request 複製到 EFI System
Partition；只有準備讓 SPI 更新在下次開機執行時，才使用
`rk3588-uboot-tools upgrade` 驗證並 staging 到 ESP。

支援更新的板子會在每個映像內嵌板型／容量識別，以及固定位置的目標媒體
marker（`MMC` 或 `SPI`）。U-Boot 在移除 one-shot request 前，會將兩者與自己
的開機媒體比對。同容量更新允許；eMMC/SD 的 16→32 MiB 與所有媒體的
32→16 MiB 都拒絕。SPI 16→32 MiB 遷移程式會保留，但依專案決定暫不執行
實機測試。版本只供診斷，不阻擋同容量升級或降級。

目前 R81 包含 raw logo、HDMI/vidconsole、FreeBSD EFI 啟動，以及
3 秒內建 U-Boot menu：

```text
NanoPC-T6-LTS-2026.07-R81-LOGO
```

## 步驟 3：建立 FreeBSD base 與 kernel

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
- 所選板卡 `board.conf` 中的 `FREEBSD_KERNCONF`

輸出：

```text
output/<FreeBSD 版本>/sets/base-<版本>_<commit>.txz
output/<FreeBSD 版本>/sets/base-live-<版本>_<commit>.txz
output/<FreeBSD 版本>/sets/kernel-<版本>_<commit>.txz
```

有版本資訊的 `base-live-*.txz` 會沿用同一份 world objects，以
`MK_TOOLCHAIN=no MK_TESTS=no MK_DEBUG_FILES=no MK_LIB32=no`
`MK_INSTALLLIB=no MK_MAN=no MK_DICT=no` 隔離安裝後打包。
installer image 的 live root 使用此精簡檔，但 `/usr/freebsd-dist` 仍保留
完整的 `base-*.txz` 供安裝目標系統使用。非 installer image 繼續使用完整 base。

## 步驟 4：建立 Ports

```sh
./build-ports.sh
```

輸出：

```text
output/<FreeBSD 版本>/ports/pkg-<版本>.pkg
output/<FreeBSD 版本>/ports/rk3588-installer-<版本>.pkg
output/<FreeBSD 版本>/ports/rk3588-uboot-tools-<版本>.pkg
output/<FreeBSD 版本>/ports/realtek-rge-kmod-<版本>.pkg
output/<FreeBSD 版本>/ports/nanopc-t6-lts/rtlbt-firmware-<版本>.pkg
output/<FreeBSD 版本>/ports/g98/realtek-rge-kmod-<版本>.pkg
output/<FreeBSD 版本>/ports/g98/motorcomm-yt921x-kmod-<版本>.pkg
```

每個 package 旁也有對應的 `.pkg.sha256`。兩板需分別執行
`BOARD=g98 ./build-ports.sh` 與 `BOARD=nanopc-t6-lts ./build-ports.sh`。
共用套件放在 `ports/`；板級套件即使同名同版本也各自保留。NanoPC
使用共用版 Realtek 套件，G98 則使用帶板級 patch 的版本。
`build-ports.sh` 會建立本地 `pkg`、driver 與 installer ports。其他 runtime
package 由 board hook 加入：NanoPC-T6-LTS 會從已設定的 FreeBSD 官方 pkg
repository 擷取架構無關的 `rtlbt-firmware`；G98 不會取得或攜帶藍牙
firmware。

使用 `BOARD=g98` 時，建置受影響的驅動套件也會套用
`boards/g98/ports/` 內的 G98 專用 patch；其他 board 不會套用。

## 步驟 5：建立 FreeBSD image

使用 `builder.conf` 的預設輸入：

```sh
./make-freebsd14-image.sh
```

也可透過位置參數明確指定 `base.txz`、`kernel.txz`、板級 driver package 與
輸出 image。預設從 `sets/`、`ports/<board>/`、
`uboot-<版本>/<容量>/<board>/` 讀取，並寫入 `images/`。

`build-u-boot-2026.07-complete.sh` 與 image builder 都使用
`builder.conf` 的 `FIRMWARE_MIB`，不需分別傳入。

### Installer package 與 payload

`PORT_ORIGINS` 與 `INSTALLER=YES` 彼此獨立：

- `PORT_ORIGINS` 包含 `sysutils/rk3588-installer` 時，image 會安裝
  `rk3588-installer` package。
- image 與 installer 安裝完成的目標都會保留 `rk3588-uboot-tools`；
  installer payload 內含其離線 package。
- 安裝成功後，`rk3588-install` 會用此工具在新 ESP 寫入一次性 request，
  下次開機時自動把剛安裝的 eMMC、SD、USB、NVMe 或 SATA 磁碟設為 U-Boot
  預設目標。
- `INSTALLER=YES` 只負責放入 `base.txz`、`kernel.txz`、firmware、DTB
  與離線 packages，不會自行安裝 installer package。
- installer 的 UFS root 依組裝完成的 live 系統與離線 payload 動態決定容量，
  image 完成後至少保留 100 MiB 可用空間；固定的 `ROOT_SIZE_MIB` 僅用於
  非 installer image。installer image 的 ESP 使用 `INSTALLER_ESP_SIZE_MIB`
  （預設 50 MiB，最小 4 MiB），並保留 1 MiB GPT 尾端；小於 4 MiB 會在
  建置 image 前直接報錯。建置時可用
  `INSTALLER_ESP_SIZE_MIB=64 BOARD=g98 INSTALLER=YES ./make-freebsd14-image.sh`
  調整；安裝目標起初使用 `ESP_SIZE_MIB`（預設 256 MiB）。若使用者選擇安裝
  U-Boot，installer 會詢問目標 ESP 容量（預設 64 MiB、最小 48 MiB）。
- `boards/<board>/hooks.sh` 決定安裝至 live image 及複製到 installer payload
  的硬體 package。NanoPC-T6-LTS 包含 if_rge 與 RTL 藍牙 firmware；G98
  包含 if_rge 與 YT921x。
- Installer payload 根目錄的 `*.pkg` 會透過 offline `pkg add` 一次安裝；
  `payload/non-registered/` 下的 package 只解壓、不登記至 package database。
  目前兩張板的 if_rge 都放在 non-registered 類別。
- `rk3588-installer` 本身仍只安裝在 live image，不複製到 target payload。
- image 與 installer payload 會包含本地編譯的 `pkg` package，避免 base
  system 的 pkg bootstrap stub 在安裝本地 package 前需要網路連線。

只有 `INSTALLER=YES` 的 image，可以日後再安裝 `rk3588-installer`
package 後使用。只有 package 而沒有 payload 時，`rk3588-install`
會回報缺少 payload 並拒絕執行安裝。

image builder 與 `rk3588-install` 會產生新的 GPT partition GUID，並以
`/dev/gptid/<GUID>` 指定 UFS root、ESP 與 swap。filesystem 與 GPT label
只保留作辨識，不再因同名 label 導向錯誤磁碟。

預設 image layout：

第 1 分割區使用 RK3588 firmware 專屬 type GUID
`b88672e6-80ac-46b0-b8b4-627b87f63119`，不再用 `freebsd-boot`。
`gpart show` 會顯示其原始 type（`!GUID`），`gpart show -l` 則顯示
`rk3588_firmware`；ESP 仍使用標準 `efi` type。

```text
0-16 MiB       GPT metadata 與 p1 rk3588_firmware
16-272 MiB     p2 EFI System Partition
272-784 MiB    p3 FreeBSD swap
784-1808 MiB   p4 FreeBSD UFS root
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
0-16 MiB       GPT metadata 與 p1 rk3588_firmware
16-272 MiB     p2 EFI System Partition
272-1296 MiB   p3 FreeBSD UFS root
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
dd if=output/<FreeBSD 版本>/images/<image>.img of=/dev/daX bs=1m conv=sync status=progress
sync
```

每次變更 U-Boot、rkbin、任一 DTB 或 FreeBSD kernel 後，至少確認：

1. UART 顯示 DDR、SPL 與 U-Boot 2026.07 版本 marker。
2. HDMI 在 U-Boot menu 前顯示 logo。
3. U-Boot menu 倒數為 3 秒。
4. FreeBSD loader menu 可由 HDMI 與 UART 顯示。
5. FreeBSD 能掛載 UFS root，或 `zfs:nanopc_t6/ROOT/default`。
6. `if_rge.ko` 載入且網路可用。

## U-Boot 韌體安裝、停用與啟用指令

`rkspi install` 已納入 U-Boot 原始碼，尚未進入發佈 image。指令要在
**U-Boot CLI** 執行，不是在 FreeBSD shell。`<介面> <裝置:分割區>` 指的是
**映像檔來源**，寫入目標固定為板上的 SPI NOR。先用 `ls` 確認來源分割區；
USB 來源可先執行 `usb start`：

```text
=> ls mmc 0:2 /
=> rkspi install mmc 0:2 /nanopc-t6-lts-uboot-16m-spi.bin
=> rkspi install mmc 0:2 /firmware-update-spi.bin
=> usb start
=> ls usb 0:2 /
=> rkspi install usb 0:2 /firmware-update-spi.bin
```

完整的 `*-uboot-16m-spi.bin` 會重設 SPI environment；較短的
`firmware-update-spi.bin` 會保留 environment。指令依驗證過的檔案長度
判斷模式，不依檔名；寫入前檢查板型、SPI 目標／版型，以及映像長度不得
超過實際 SPI 容量，再要求輸入 `INSTALL SPI`。寫入後會回讀比對，不會
建立自動更新 request，也不會自動重開。16M→32M 版型升級不屬於
`install`，應走現有的 SPI update／upgrade 流程。

同一份 U-Boot 原始碼也提供 `rkboot` 指令，適用 SPI、eMMC 與 SD。`disable` 只作用
於目前執行中的 U-Boot；`enable` 才指定另一個開機媒體。
`mmc 0`／`mmc 1` 是 **U-Boot** 的裝置編號；先用 `mmc list` 確認，
不要直接套用 FreeBSD 的 `/dev/mmcsd*` 編號：

```text
=> rkboot disable
=> rkboot enable spi
=> rkboot enable mmc 0
```

`disable` 只把目前執行中的韌體在 `0x8000` 的四位元組 `RKNS` BootROM 識別碼清為
零；必須先找到另一份板型相符、表面可開機的 SPI／eMMC／SD 韌體，並輸入
`DISABLE BOOT` 確認，最後回讀比對。`enable` 要求目標識別碼為零、板型／
媒體／容量標記相符、FIT 有效，且目前運作的另一份 U-Boot 有有效識別碼；
只寫入程式內建的四位元組 `RKNS` 識別碼，輸入 `ENABLE BOOT` 後回讀比對。
SPI 啟用時，會保留 4 KiB erase sector 其餘內容，擦除後整個 sector 寫回。
兩個指令都不自動重開，也不替換目標的其餘韌體。如果目標韌體不存在或
已損毀，應使用 `rkspi install`，不能靠 `rkboot enable` 修復。

檢查備援映像仍不能保證 BootROM 一定會回退。NanoPC-T6-LTS 的 SPI 安裝、
自行停用及回退 eMMC 已通過實機驗證；**SPI 重新啟用尚未驗證**。G98 沒裝
eMMC，在沒有已驗證的備援開機來源前不可停用 SPI。NanoPC 的 eMMC
自行停用、SD 回退、重新啟用也已於 2026-09-17 使用 U-Boot CLI 通過驗證；
指令、回退證據與備份資訊記錄於工作目錄的
`feature/rk3588-uboot-manual-spi-install-and-removal.md`。
