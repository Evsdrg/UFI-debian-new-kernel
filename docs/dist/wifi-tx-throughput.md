# Low WiFi upload speed on OpenStick: diagnosis and fix

## Symptom

On a Handsome OpenStick UFI103s (MSM8916, WCN3620 radio), with a clean link:

- **Download: ~45-50 Mbit/s**, PHY rate `MCS 6`-`MCS 7` (135-150 Mbit/s).
- **Upload: ~5-8 Mbit/s**, PHY rate stuck at `MCS 0` (13.5 Mbit/s).

The asymmetry is the tell. A weak link or interference degrades both directions;
here only transmit was affected, and it was pinned at the single lowest HT rate.

Confirming details:

- Device CPU stayed at 7-8% during the transfer, so it was not a host limit.
- Power save on/off made no difference.
- Signal was -27 dBm, 40 MHz channel, and `tx retries`/`tx failed` stayed at 0.
- Four parallel upload streams aggregated to the same throughput as one stream,
  which rules out single-flow TCP behaviour and points at a PHY/MAC ceiling.
- Mean TX frame size during upload was 1529 bytes (full MSS), so it was not
  fragmenting or sending small frames.

## Investigation

### The firmware owns the rate

The driver sets `IEEE80211_HW_HAS_RATE_CONTROL`, so rate selection is entirely
the firmware's job. Confirmed at run time:

```
$ cat /sys/kernel/debug/ieee80211/phy0/rate_ctrl_alg
hw/driver
```

There is no host-to-firmware "set rate" message, and `bd_rate` in the TX buffer
descriptor is only a 2-bit frame-class field (data / management / control), not a
rate. The driver also never feeds per-packet rates back to mac80211 — the firmware
TX-completion message carries a status word only — so host-side rate control is
not possible even in principle.

### Rate adaptation starts high, then collapses

The config table already asks the firmware to start rate adaptation at MCS5
(`ENABLE_DYNAMIC_RA_START_RATE = 133`, i.e. `0x80|5`), and management frames are
observed at `MCS 4`. Only *data* frames fall to and stay at `MCS 0`.

### Things that turned out NOT to be the cause

- **TX aggregation.** The station's `agg_status` showed BA sessions established on
  TID 0/1 throughout the transfer, and frames were full-size. Aggregation was
  working.
- **The firmware capability list.** It reports `RATECTRL` (and no `BLOCKACK`, but
  the driver only uses that list for debug names and for scan-offload gating, so
  it does not gate aggregation).
- **`FIXED_RATE`.** This is the most misleading knob. It *does* work, but only for
  legacy rates: setting 1 / 2 / 4 produced 1 / 2 / 11 Mbit/s, proving the value
  reaches the firmware. Every HT encoding tried (128, 130, 133, 135) left data
  frames at MCS0. The firmware will not accept a host-specified HT rate.
- **Other rate/retry knobs.** `ENABLE_DYNAMIC_RA_START_RATE` (0, 64, 133, 134,
  135), `RA_FILTER_ENABLE`, `RA_RATE_LIMIT_INTERVAL`, `MCS_RATES`,
  `RETRYRATE_POLICY`, `FORCE_POLICY_PROTECTION` — all had no effect.

### The cause: MAX_MEDIUM_TIME

`MAX_MEDIUM_TIME` (HAL config id 9) is the firmware's per-channel occupancy
budget, in microseconds. The WCN3620/WCN3660B table set it to **6000**.

Raising it restores the transmit rate. Measured on the same link, same AP,
single stream, device to host (`MAX_MEDIUM_TIME` set at module load, link
re-started, then measured):

| MAX_MEDIUM_TIME | PHY rate | TCP throughput |
|---|---|---|
| 6000 (was default) | MCS0 13.5 Mbit/s | ~6 Mbit/s |
| 8000 | MCS0 | ~6 Mbit/s |
| **10000** | MCS4 90 Mbit/s | 43-45 Mbit/s |
| **12000** | MCS4 | 44-46 Mbit/s |
| 16000 | MCS0 | ~6 Mbit/s |
| **20000 (now default)** | MCS4-MCS5 | 44-50 Mbit/s |
| 30000 | MCS4 | 44-47 Mbit/s |

Two things about this table are worth stating plainly, because they are
uncomfortable:

1. **The response is not monotonic.** 8000 and 16000 fall back to MCS0 while
   10000, 12000, 20000 and 30000 work. The value therefore had to be measured,
   not derived. We do not have the firmware source, so we cannot explain this.

2. **A smaller value exists in the other table.** The WCN3680 table sets
   `MAX_MEDIUM_TIME` to 4096 — smaller than the 6000 called "too small" here —
   and there is no comparable complaint from WCN3680 users. So the honest
   reading is that the threshold is a property of this firmware build
   (`CNSS-PR-1-4-2-c4-00084`, `WCN v2.0`), not a universal rule. This is
   precisely why results from other radios (WCN3660B, and ideally WCN3680) are
   wanted: they would either widen the fix into a general one or confine it to
   the build where it was observed.

## Verification

With 20000 baked into the driver table and **no** module parameters set, after a
clean boot:

```
sustained1: 47 Mbit/s  tx=[MCS 4 40MHz short GI]
sustained2: 45 Mbit/s  tx=[MCS 4 40MHz short GI]
sustained3: 44 Mbit/s  tx=[MCS 4 40MHz short GI]
tx retries: 0    tx failed: 0    temperature 52 C
```

Download unchanged: device RX still `MCS 6`-`MCS 7`, 45-50 Mbit/s. Reverting the
value to 6000 reproduces the ~6 Mbit/s failure immediately, which is what
establishes the causal link rather than a coincidence.

## The patch

`source/patches/0002-wifi-wcn36xx-raise-max-medium-time-for-ht-tx.patch` changes the one
value and documents the measurement in a comment. It applies standalone to a
pristine `linux-7.2.9` tree. The numbers above were measured on 6.18.49;
the patch text is unchanged. It passes `checkpatch.pl --strict` with no
errors or warnings.

Two companion patches exist:

- `0001` makes the driver's `firmware_feat_caps` debugfs file readable. Upstream
  registers it with mode `0200` (write-only) while attaching a *read* handler, so
  the firmware capability list cannot be read by anyone. `0444` fixes that. This
  is an independent, self-evident bug fix.
- `0003` adds a `cfg_override` module parameter and a debugfs knob that let any
  HAL config value be overridden at load time. This is what made the sweep above
  possible without a rebuild per value; it is a diagnostic tool rather than part
  of the fix.

## Related notes

- Reading the firmware capability list requires `CONFIG_WCN36XX_DEBUGFS` (and, for
  the aggregation view, `CONFIG_MAC80211_DEBUGFS` plus `CONFIG_CFG80211_DEBUGFS`).
  None of these are on in the default config.
- The same `MAX_MEDIUM_TIME = 6000` appears in Qualcomm's downstream vendor
  driver, so this is inherited from the vendor BSP rather than introduced by
  mainline.
- WCN3620 and WCN3660B share the config table; WCN3680 has its own.
