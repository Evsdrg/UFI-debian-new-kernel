# 构建文档

这里说明如何选择内核变体与 rootfs 档位，以及如何构建和检查产物。

| 文档 | 内容 |
|---|---|
| [`BUILD-MATRIX.md`](BUILD-MATRIX.md) | 板型、内核变体、rootfs 档位与网络栈的对应关系 |
| [`TRIMMING.md`](TRIMMING.md) | max/basic/slim/micro 四档的取舍，以及 QEMU 冒烟流程 |
| [`TOOLING.md`](TOOLING.md) | 构建与验证工具清单、已知缺口 |
| [`UPSTREAM.md`](UPSTREAM.md) | 上游 stable 版本、平台相关变更与补丁预检 |

常用命令：

```sh
bash tools/build-board-set.sh   # 内核、模块树和 boot 镜像
bash tools/build-matrix.sh      # UFI103s 的七张 rootfs
bash tools/verify-layout.sh     # 布局与产物检查
```

构建前先确认三条约定：

1. 内核版本只在 `source/kernel-version.env` 中维护；脚本通过
   `tools/kver.sh` / `kver.py` 派生版本与路径。
2. boot 镜像和 rootfs 中的模块树必须属于同一 release，不能只替换其中一个。
3. 构建产物放在 `artifacts/`，`boards/` 只放设备树源码；可分发 boot 镜像放在
   `builds/`。

修改 rootfs 档位或软件包后，先运行 `bash tools/smoke-all.sh`。
QEMU 冒烟只能检查通用启动问题，不能替代 msm8916 实机验证。
