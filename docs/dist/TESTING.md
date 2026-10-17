# Testing guide

Two ways to test, depending on how much you are willing to do to your device.

**Option A** replaces one kernel module on a system that already boots. No
partition is written, no bootloader is touched, and reverting is one command.
Start here.

**Option B** flashes a boot image from `builds/`. Only do this if Option A is not
possible for you, and read [the flashing warning](../../builds/README.md)
first — in particular, the WiFi calibration blob in the rootfs was dumped from a
different physical unit.

Either way, the question being answered is the same: **does raising
`MAX_MEDIUM_TIME` restore the transmit rate on this radio?**

## What we need from you

The single most valuable result is a **before/after pair on the same device, same
AP, same position**. If you can only do "after", say so — it is still useful,
just less conclusive.

Please report:

1. Board name (`ufi001b`, `sp970`, ...) and the `wifi_chip=` line from the test.
2. The complete output block from `tools/dist/wifi-tx-test.sh` for each state.
3. For Option A, the numbers **before** the module swap and **after**.
4. Your default `MAX_MEDIUM_TIME` value if the driver sources are available to
   you (see below), otherwise just the driver version.

Paste it into an issue. The output is already key=value lines so it needs no
reformatting.

## Quick check: which value does your driver use?

If you have the kernel sources, or the built module, this tells you whether your
tree is already fixed:

```sh
grep -n MAX_MEDIUM_TIME drivers/net/wireless/ath/wcn36xx/smd.c
```

The two tables are the WCN3620/WCN3660B one and the WCN3680 one:

| What you see | Meaning |
|---|---|
| `MAX_MEDIUM_TIME, 6000` in the first table | unfixed — this is the bug |
| `MAX_MEDIUM_TIME, 20000` in the first table | fix already applied |
| `MAX_MEDIUM_TIME, 4096` in the second table | WCN3680 table, unrelated |

## Option A — swap the module, no flashing

You need: an existing working system on the stick, its matching kernel sources
(or just the ability to build one module), and a second machine with `iperf3`
for the measurement.

### 1. Measure the "before" state

On the peer machine:

```sh
iperf3 -s
```

On the stick, copy `tools/dist/wifi-tx-test.sh` over and run it:

```sh
./wifi-tx-test.sh <peer-ip> 10
```

Keep that output.

### 2. Build and install the fixed module

Apply the fix to your kernel tree and rebuild just the driver. Two things to
know, both learned the hard way:

- Build with `make modules` on the whole tree. A directory target such as
  `make drivers/net/wireless/ath/wcn36xx/` only runs `checksyscalls` and will
  not relink the module.
- Do not use `make M=<dir>` when building with `O=`; it writes objects into the
  *source* tree.

```sh
cd linux-<your-version>
git am /source/patches/0001-*.patch /source/patches/0002-*.patch
make <your existing defconfig target>       # keep your current config
make modules
```

Or, if you only want to try the value without committing to the patch, apply
`0003` instead and set it at load time — it adds a `cfg_override` parameter:

```sh
# after applying 0003 only
modprobe wcn36xx cfg_override="9=20000"
```

Note that `cfg_override` only takes effect at module load: the firmware latches
its configuration when the MAC starts, so a `modprobe` cycle (or a link
down/up) is required after changing it. The same is true of the patched default.

### 3. Install it

The module is at `drivers/net/wireless/ath/wcn36xx/wcn36xx.ko` in the build tree.
Replace the installed copy and rebuild the module index:

```sh
cp wcn36xx.ko /usr/lib/modules/$(uname -r)/kernel/drivers/net/wireless/ath/wcn36xx/
depmod -a
reboot
```

Keep the module you replaced — reverting is copying it back and rebooting.

The module only loads if its `vermagic` matches your running kernel exactly.
Check both with `modinfo -F vermagic wcn36xx` before and after.

### 4. Measure the "after" state

Same command as step 1. Upload should move from roughly 5-8 Mbit/s to roughly
40-50 Mbit/s, and `rate_during_upload` from `MCS 0` to `MCS 4` or better.
Download should not change.

If it does not improve, that is a valid and interesting result — please report it
with the test output. It would mean the WCN3660B behaves differently from the
WCN3620 this fix was found on, which is exactly the case we are trying to detect.

### Reverting

```sh
cp <your backup>/wcn36xx.ko /usr/lib/modules/$(uname -r)/kernel/drivers/net/wireless/ath/wcn36xx/
depmod -a
reboot
```

## Option B — flash a boot image

Only if Option A is impossible. Flashing writes to the boot chain, and part of
what is on that eMMC is per-device data that no image can recreate, so:

### 0. Take a full backup first — this is required, not advisory

Read [backup-and-restore.md](backup-and-restore.md) and follow it. In short: use
Miko to read the whole eMMC to a single image (~3.9 GB) before writing anything.
The `modemst1` / `modemst2` / `fsg` / `fsc` partitions hold this unit's modem
calibration; overwrite them and 4G is gone permanently, with no recovery from any
image we could supply. **Do not skip this, and do not skip verifying the backup
file's size before flashing.**

Then, before flashing:

1. Check the `build.json` next to the image in `builds/boot/<variant>/`.
   The `status` field states exactly what has and has not been verified, and
   the `cmdline` is a PARTUUID for one rootfs. Do not assume more than it says.
2. Export your own WiFi calibration as well:
   `tools/dist/dump-nv.sh` saves `WCNSS_qcom_wlan_nv.bin` from your unit. The one in
   the shipped rootfs came from a different device and may give you no WiFi.
   (This is separate from the eMMC backup and is a much smaller file, but it is
   the WiFi equivalent of the same problem.)
3. Note that the WiFi fix is **not** in any boot image — it is a kernel module,
   so a boot flash alone will not change your upload speed. See
   [../../builds/README.md](../../builds/README.md).

## Interpreting the numbers

Some context for judging a result:

| Observation | Reading |
|---|---|
| upload ~5-8 Mbit/s, tx `MCS 0` | unfixed behaviour |
| upload ~40-50 Mbit/s, tx `MCS 4`-`MCS 5` | fix working |
| upload fine but download broken | regression, report immediately |
| both directions slow | unrelated to this bug (AP, interference, distance) |
| `upload_retrans` high (hundreds) | link problem, treat the rate as unreliable |

Signal strength matters: at -25 to -40 dBm expect the numbers above. Beyond
about -65 dBm the radio will not hold MCS4 regardless of this fix, so note your
`signal_dbm`.

## A note on what "fixed" means here

The change raises a firmware configuration value. We measured that this value
makes the rate adaptation hold a high MCS on a WCN3620, and that the response is
not monotonic — 8000 and 16000 fall back to MCS0 while 10000, 12000 and 20000
work. We do not have the firmware source, so the exact mechanism is not known;
what is known is the measured behaviour and its reproducibility. Results from
other radios are what would turn that into a general fix.
