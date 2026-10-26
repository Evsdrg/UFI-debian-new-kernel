# 构建文档

本目录回答三件事：**选什么组合、怎么构建、还缺什么工具**。

| 文档 | 内容 |
|---|---|
| [`BUILD-MATRIX.md`](BUILD-MATRIX.md) | 设备 × 档位 × 网络栈的完整矩阵；六个内核板型与 rootfs 档位的配对；minimal 变体的裁剪范围与实测收益 |
| [`TRIMMING.md`](TRIMMING.md) | 四档（max/basic/slim/micro）的体积与取舍、四个正交开关、QEMU 冒烟流程（**改档位/砍包后必做**） |
| [`TOOLING.md`](TOOLING.md) | 已有脚本清单与**已知缺口**（全片 eMMC 备份脚本化是最大缺口） |

## 最常用的三条命令

```sh
# 六个板型的内核 + 模块树 + boot 镜像（表驱动，缺省只建未完成的）
bash tools/build-board-set.sh

# 7 张 rootfs（四档 × NM/native 双栈）
bash tools/build-matrix.sh

# 布局与产物自检（应 exit 0）
bash tools/verify-layout.sh
```

## 三条不能忘的约定

1. **版本只有一个事实来源**：`source/kernel-version.env`。升级内核只改它，
   脚本一律用 `tools/kver.sh` / `kver.py` 派生路径，不要硬编码版本号。
2. **boot 与 rootfs 必须成对**：vermagic 含 release，只刷 boot 不换模块树会
   静默失配。配对表在 `BUILD-MATRIX.md` 与 `tools/build-matrix.sh`。
3. **产物只放 `artifacts/`**：`boards/` 只放源码（DTS）。
   可分发镜像在根目录 `builds/`（入库），构建产物在 `artifacts/`（不入库）。

改完档位或砍包后，先跑 `bash tools/smoke-all.sh`（QEMU，不碰真机），
再考虑实机刷入。注意 **QEMU 通过 ≠ 实机通过**：QEMU 没有 msm8916 的
APCS、真实 UDC 等硬件，平台驱动问题只有实机能暴露（见 `../ISSUES.md` 第 16 条）。
