# artifacts/ — 产物唯一存放位置

**本目录是构建产物的唯一位置。** 2026-10-11 之前产物分放在
`shared/{rootfs,modules,firmware}` 与 `boards/<家族>/<机型>/boot/` 两处，
现已全部收进这里。新增产物请放进对应子目录，不要再散落到别处。

脚本**不要自己拼 `artifacts/...` 字面路径** —— 一律用
`tools/kver.sh`（shell）或 `tools/kver.py`（Python）派生的变量，
它们都从 `source/kernel-version.env` 算出。这样升级内核只改一个文件。

## 结构

```
artifacts/
├── boot/<机型>/          boot 镜像 + 打包中间态 + 产物元数据
├── rootfs/               rootfs 镜像（板无关）
├── modules/              内核模块树（每板型一棵，release 名区分）
├── dtb/                  各机型的裸板 DTB
└── firmware/             固件集（构建输入，不可再生）
```

### boot/<机型>/

每个机型一个目录，目录名是**机型名，不带家族前缀**（`ufi103s-ufi003`、
`ufi001b`、`ufi001c`、`sp970`、`uz801`），与 `boards/` 下的家族嵌套结构不同。

| 文件 | 入库 | 说明 |
|---|---|---|
| `boot-board-<板型>-<版本>.img` | ❌ | 可刷产物。`<板型>` 是功能组合（`baseline`/`4g`/`venus`/`venus-4g`/`venus-4g-gpu`） |
| `board-<板型>-<版本>-build.json` | ✅ | **产物元数据**：内核 release、cmdline、镜像与 DTB 的 sha256、`flash_status`。`flash.sh` 刷前比对它 |
| `kernel-board-<板型>-<版本>-dtb` | ❌ | `Image.gz` + DTB 的拼接中间态，可从内核镜像与 DTS 重建 |
| `empty-ramdisk` | ❌ | 空的 initramfs（legacy boot image 需要这个字段） |

只有 ufi103s 的五个功能组合有 7.2.9 镜像；其它机型的裸 DTB 在 `artifacts/dtb/`。

### rootfs/

`ufi103s-<版本>-<档>.ext4`，七张：`max`/`basic`/`slim`/`micro` ×
nm|native（`max` 无 native 变体）。板无关——所有机型共用同一张。
档位含义见 `docs/build/TRIMMING.md`。

### modules/

每棵模块树是一个 `<版本>-ufix0x<板型后缀>-dirty` 目录，内层结构与
`/lib/modules/` 一致（`lib/modules/<release>/kernel/...`）。
**模块树与内核必须成对**：vermagic 含 release 字符串，拿错树会让
`modprobe` 静默失败（见 `CONTRIBUTING.md` §2.8）。

### dtb/

各机型的裸板 DTB（`<机型>.dtb`）。ufi103s 的 DTB 已并入它的 boot 镜像；
其它机型当前只有 DTB，没有 7.2.9 boot 镜像。

### firmware/

构建 rootfs 时拷进镜像的固件。**不可再生**——从设备自身导出，
每台机器的校准值唯一。

| 子目录 | 内容 |
|---|---|
| `common/` | 所有机型共用的固件集（含 `regulatory.db` 等） |
| `ufi103s-venus/` | 比 `common` 多一个 `qcom/venus-1.8/venus.mbn`（硬编解码） |
| `board-overrides/` | 按机型覆盖的固件 |

固件**不入库也不授权再分发**，见仓库根 `NOTICE`。

## 从 Git 角度看

`.gitignore` 排除大体积产物，只保留**小体积、有追溯价值**的部分：

- ✅ 入库：`*-build.json`（产物元数据）、`artifacts/dtb/*.dtb`、本 README
- ❌ 排除：`*.img`、`*.ext4`、模块树、固件、`kernel-*-dtb`、`empty-ramdisk`

所以克隆仓库后**能拿到设备树与构建记录，但拿不到可刷镜像**——
镜像需要本机构建（见顶层 `README.md` 的构建命令）。

## 清理与重建

这些都是可再生产物，但重建代价不小（内核编译数十分钟，rootfs 需要
mmdebstrap + 网络）。`artifacts/` 已排除在版本库外，删掉不会污染 git。

回退靠 `recovery/` 与 `out/rollback/` 的分区读回，**不是**靠这里的镜像。
