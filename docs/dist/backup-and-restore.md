# Backup and restore (mandatory before flashing)

> **中文摘要 / Chinese summary**
> 在刷任何分区之前,**必须**先用 Miko 做一次整片 eMMC 全量备份。备份会得到一个完整的
> `img`(本机型约 **3.9 GB**),把它解包还能得到各分区的独立镜像。之所以不可跳过:
> `modemst1` / `modemst2` / `fsg` / `fsc` 这四个分区存的是**这台设备独有的 modem
> 校准数据**,一旦被覆盖就再也无法恢复——任何我们提供的镜像都救不回来,4G 会永久失效。
> 全量镜像里包含 GPT,所以它是完整的还原点。

Flashing writes to the boot chain. The reason a backup is required rather than
merely recommended is in the "Why this is not optional" section below — briefly,
part of what is on that eMMC cannot be recreated from any image we could ever
give you.

## Why this is not optional

These sticks carry per-device data that is not part of any downloadable firmware:

| Partition | Size | What it holds |
|---|---|---|
| `modemst1` | 2 MiB | per-device modem NV / calibration |
| `modemst2` | 2 MiB | second copy of the above |
| `fsg` | 2 MiB | per-device modem configuration |
| `fsc` | 1 KiB | modem file-system cache counters |
| `devinfo` | 1 MiB | bootloader state |

`modemst1`/`modemst2`/`fsg`/`fsc` are written at manufacture and are specific to
that radio. Overwrite them and the 4G modem stops working; **no image in this
repository (or anywhere else) can regenerate them**. The only way back is a
backup taken before you touched anything.

The boot chain (`sbl1`, `rpm`, `tz`, `hyp`, `aboot`) and the partition table
itself are also worth having, and a full-disk image captures all of it.

## What Miko produces

Miko's backup reads the **entire eMMC** and writes a single raw image. Extracting
that image yields the individual partitions, so one backup gives you both:

- a complete restore point (the raw image includes the GPT, so restoring it
  restores the partition table too), and
- per-partition images if you only need to put one partition back.

**Size to expect: 3,909,091,328 bytes (3.64 GiB)** for this eMMC. Have at least
~4 GB free, on a disk that is not the one you are about to write to. Do not
interrupt the read.

## Partition layout for reference

Read from a device running the OpenStick-family layout, for sanity-checking your
backup and for understanding what a restore covers:

```
partition        offset        length        size
cdt              0x04000000    0x00000800     2 KiB
sbl1             0x08000000    0x00080000   512 KiB
rpm              0x08080000    0x00080000   512 KiB
tz               0x08100000    0x00100000     1 MiB
hyp              0x08200000    0x00080000   512 KiB
sec              0x08280000    0x00004000    16 KiB
modemst1         0x08284000    0x00200000     2 MiB
modemst2         0x08484000    0x00200000     2 MiB
fsc              0x08684000    0x00000400     1 KiB
fsg              0x0c000000    0x00200000     2 MiB
aboot            0x10000000    0x00100000     1 MiB
boot             0x10100000    0x04000000    64 MiB
devinfo          0x14100000    0x00100000     1 MiB
rootfs           0x14200000    0xd4dfbe00  3406 MiB

total disk       0xe9000000  7,634,944 sectors  3.64 GiB
```

If your GPT does not match this, your device is on a different layout — take the
backup anyway (that is the point), but tell us, because our images assume this
one and `rootfs` is referenced by partition label in the kernel command line.

## Procedure

### 0. Get the device into EDL (9008)

**Hold the reset button down, then plug the stick into the computer.** Keep
holding it while the USB connection is made, then release.

If your board has no button but exposes a reset pad ("reset 触点" on the
OpenStick boards), short that pad to ground instead of pressing — the two are
the same thing electrically, since the reset button itself just connects that
point to ground.

The order matters: the boot ROM samples the reset line while it is starting up,
so reset has to be held **before** power arrives on USB, not after. If the device
boots normally into an OS instead, unplug it and try again.

Confirm it worked before starting: the device must enumerate as USB `05c6:9008`.

- Windows: it appears in Device Manager as `Qualcomm HS-USB QDLoader 9008`
- Linux: `lsusb | grep 9008`

EDL is USB-only; no serial port is involved at this stage.

### 1. Use Miko's backup/read function

Do not use the flashing functions yet. Miko's readback writes the whole eMMC to
one image file; pick a location with ~4 GB free.

**Loader note.** Public Firehose loaders do **not** work on these sticks — the
device enters Sahara but rejects them (`END OF IMAGE ... status: 1` was observed
with the loader OpenStick's own package specifies). Miko ships a working
MSM8916 loader and uses it automatically, so **use Miko for EDL on these
devices** rather than a generic `edl`/`qdl` invocation. The working loader is
`loader/MSM8916` inside the Miko package, SHA256
`081b5fa07a28fd9702a54980a149fd4430e3686eb82e530181571c3f73bc0771`.

### 2. Verify the backup before going further

Check the file exists, is **not** a suspiciously round number or zero, and is
close to 3.64 GiB:

```sh
ls -l backup.img                 # expect ~3,909,091,328 bytes
sha256sum backup.img > backup.img.sha256   # keep this next to the image
```

A truncated readback is worse than none, because it looks like a backup. If the
size is off, redo it.

If you are not going to flash right away, leave EDL first — use Miko's
reboot/reset action, or simply unplug the stick and plug it back in without
holding reset. EDL is entered by the boot ROM at power-on, so it does not persist
on its own.

### 3. Then, and only then, flash

See [../../builds/README.md](../../builds/README.md) for what each image is, and note
that the WiFi fix is delivered by a **kernel module in the rootfs**, not by a
boot image. Option A in [TESTING.md](TESTING.md) needs no flashing at all and is
the recommended route — consider it before touching partitions.

## Restoring

**Whole device:** write the raw image back in EDL mode, the same way it was read.
This restores the partition table and every partition including the modem data.

**Single partition:** extract the partition from the backup image and write only
that. Useful after a bad `boot` or `rootfs` flash when the rest is known good.

After restoring, the device returns to exactly the state it was in when the
backup was taken — so if you had already flashed an OpenStick package before
backing up, that is what you get back, not the stock Android state.

## Keeping the backup safe

- Store it somewhere other than the device and other than the machine you flash
  from.
- Keep `backup.img.sha256` with it.
- For a fleet of test devices, label each backup with the device's serial
  (`androidboot.serialno`, visible in `/proc/cmdline`) so images cannot be
  restored to the wrong unit.
