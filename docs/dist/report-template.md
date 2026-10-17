# Test report template

Copy the block below into an issue. Fill in what you have; delete lines you
cannot provide rather than guessing at them. The `before`/`after` pair from the
same device and the same position is the important part — an `after`-only
result is still useful, just say so.

```markdown
## Board

- board:                  (ufi103s-ufi003 / ufi001b / ufi001c / sp970 / uz801 / other)
- wifi_chip:              (copy the `wifi_chip=` line from the test output)
- kernel:                (uname -r)
- running this rootfs/os: (e.g. the venus-led image from this project, pmOS, ...)

## What I did

- [ ] Option A: swapped wcn36xx.ko on my existing system (no flashing)
- [ ] Option B: flashed a boot image from builds/
- [ ] (Option B only) I took a full eMMC backup with Miko first, and verified
      the image size before flashing
- module source:          (built from patches/ myself / used builds/boot/<variant>/wcn36xx.ko)
- MAX_MEDIUM_TIME in my driver before the test:
                          (6000 / 20000 / other / unknown)

## Before (only if Option A, or your previous state)

```
<paste the full output of tools/dist/wifi-tx-test.sh here>
```

## After

```
<paste the full output of tools/dist/wifi-tx-test.sh here>
```

## Anything else

- AP and band:            (e.g. your AP, 2.4 GHz ch1 / 5 GHz)
- distance / obstacles:   (e.g. same room, ~2 m)
- did anything else break? (services, bluetooth, modem, ...)
- notes:
```

## What good data looks like

A complete `after` run looks like this. It is the author's UFI103s log from
the 6.18.49 measurement, kept as the reference shape — the prebuilt modules
in this repo are 7.2.9 and were not the binaries that produced these
numbers. Your radio may give different numbers, and that is the point:

```
# ==== wifi-tx-test ====
kernel=<uname -r>
hostname=ufi103s
iface=wlan0
ap_ssid=<your-ap-ssid>
ap_freq_mhz=2412.0
signal_dbm=-25
wifi_chip=qcom,wcn3620
firmware=WCN v2.0 RadioPhy vUnknown with 19.2MHz XO
driver_vermagic=<from modinfo wcn36xx>
--- rates before traffic ---
  tx bitrate:	90.0 MBit/s MCS 4 40MHz short GI
  rx bitrate:	150.0 MBit/s MCS 7 40MHz short GI
upload_mbps=42.7
upload_retrans=5
rate_during_upload=tx bitrate:	90.0 MBit/s MCS 4 40MHz short GI rx bitrate:	150.0 MBit/s MCS 7 40MHz short GI
download_mbps=72.2
tx_retries=0
tx_failed=0
# ==== end ====
```

Two lines are easy to misread:

- `rate_during_upload` is sampled while traffic is flowing. This matters: an
  idle link often reports a management-frame rate, which is not the data rate.
  The bug shows up here as `MCS 0`, and a working link as `MCS 4` or better.
- `signal_dbm` sets your expectations. Above roughly -60 dBm the radio will not
  hold MCS4 no matter what this fix does, so a weak signal explains a low number
  on its own.
