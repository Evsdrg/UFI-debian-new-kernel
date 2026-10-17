# 7.2.9 hardware validation (Linux 7.2.9, 2026-10-10)

The packaged five kernels were rebuilt with `NFT_CT` and `NFT_REJECT` support
and their Kconfig-derived IPv4/IPv6/inet reject modules. This resolves the
missing expressions that prevented NetworkManager 1.52.1 from committing
its shared-mode firewall transaction.

The newly rebuilt **GPU variant only** was RAM-booted twice on UFI103s.
Its boot image SHA256 is:

```text
11f975b280b357f96d06f72c490284a66c6ca0ebeeb0368778044e61e654bb51
```

The original boot partition was not written. The command line was overridden
to disable the unreliable serial console, as in the earlier validation.
Full matching modules and the companion project's updated sharing assets
were installed into the existing rootfs; the new rootfs images were **not
flashed or qualified as complete hardware installations**.

## Hardware checks

- NetworkManager automatically managed usb0 and activated the canonical
  shared profile at RAM boot, with gateway 10.42.0.1/24 and complete nft rules.
- An isolated host network namespace had **only the USB network interface**.
  DHCP, DNS, access to the upstream LAN and external HTTPS succeeded without
  a proxy. An upstream HTTP server observed the stick's WiFi source address,
  proving that traffic traversed the stick's NAT rather than the host's WiFi.
- The native sharing assets were temporarily tested on the same installation,
  with networkd managing only usb0. DHCP/DNS/NAT/HTTPS succeeded. Killing the
  foreground dnsmasq process triggered supervised restart. Stop removed only
  `inet openstick_usb`, preserving an unrelated sentinel table. Invalid
  dnsmasq configuration was rejected before sharing startup.
- Three gadget restarts recovered the shared connection. An unbound,
  partially created configfs gadget was correctly reported inactive despite
  its UDC attribute having stat size 4096, and subsequent start recovered it.

The companion rootfs builder now supplies nftables to both network stacks,
overrides the gadget's udev unmanaged flag for NM, supervises native DNS/DHCP,
and masks the unrelated global dnsmasq service. The gadget helper checks
writes and rolls back partial construction; it no longer writes the
nonexistent interface-level vendor-code attribute.

These userspace assets are **not inside the boot images in this repository**.
Flashing a boot image alone is not an installation of the full sharing fix,
and the rootfs must contain the matching full module tree, not just wcn36xx.

## Remaining boundaries

- Other four functional variants: rebuilt and delivery-checked, not booted
  on hardware. Other boards remain untested.
- Native service/path validation is not a cold-boot acceptance of all three
  native rootfs images or a cellular data test.
- MPEG-4 firmware fatal and sustained-load thermal limits remain unresolved;
  see the "Earlier round" section below.
- Windows/macOS RNDIS compatibility, SIM data/SMS and long-duration stress
  were not qualified. No ECM/NCM protocol redesign is included.
- The new images remain **not flashed**. No full-deployment claim is made.

---

## Earlier round: pre-fix RAM-boot survey

The first 7.2.9 hardware round (before the USB sharing fix) ran the GPU
variant twice with `fastboot boot`, verified a normal reboot back to 7.1.13,
and recorded the blocks below. That earlier image had

```text
5626c15b172b3c42ebb9425b6370f69343166b036f57610fc38765a896cfa035
```

as its SHA256, which is **not** the current artifact; the rebuilt image is the
one hashed above. Results from that round, still valid as a bound:

| Check | Result |
|---|---|
| WiFi TCP upload / download | 49.24 / 62.76 Mbit/s (20-second runs, 2-second warmup) |
| Same-setup old 7.1.13 control | 46.31 / 55.64 Mbit/s (15-second runs, 2-second warmup) |
| WiFi reconnect | Three successful disconnect/reconnect cycles, managed through USB |
| USB RNDIS | Host to stick 164.13, stick to host 148.69 Mbit/s; no retransmits |
| GPU | Mesa freedreno FD307; real headless composition and rendering |
| H.264 encode/decode | 640x480, 1280x736, 1920x1088; matching HW/SW decoded frames |
| VP8 decode | 45/45 frames, HW/SW hashes match |
| MPEG-2 decode | 45 frames; average PSNR 70.83 dB, max component difference 3 |
| MPEG-4 decode | Firmware fatal, reproduced with the same valid input on 7.1.13 |
| HEVC to H.264 | Software HEVC decoding plus hardware H.264 encoding passed |
| GPU to Venus streaming | Correct picture, about 25-27 actual fps at 1280x736@30; late join works |
| xrdp | Real TLS login and i3 desktop rendered |
| Bluetooth | Controller and discovery passed; no pairing or audio test |
| Cellular | Remote processors, QMI/AT and netdevs present; SIM missing |
| Storage | 64MiB ordinary file, fsync, three matching direct-I/O read hashes |

Those numbers came from the pre-fix image. The WiFi fix itself was measured on
6.18.49 and is not re-measured here. No claim is made that the rebuilt image
would give the same figures.

---

# 2026-10-17: `ufi103s-minimal` RAM boot

`ufi103s-minimal` is the one variant that subtracts rather than adds: it keeps
the baseline (WiFi-only) device tree and strips the kernel configuration down
to WiFi, USB RNDIS sharing and zram. Boot image
`6715aa44914fbad94020e9f758712a0dc7aaa0340798bc6c73472fb9d30f0f90`.

RAM-booted once via `fastboot boot` (boot partition **not** written) with a
no-serial cmdline, matching modules and the existing rootfs.

| Check | Result |
|---|---|
| Boot to SSH | 12-15 s, `7.2.9-ufix0x-minimal-dirty` |
| WiFi | `wcn36xx`+`mac80211`+`cfg80211` loaded; association succeeded, default route present |
| USB RNDIS sharing | Gadget `active UDC=ci_hdrc.0`; `usb0=10.42.0.1/24` |
| NAT egress | Isolated netns client reached a LAN service and the peer saw the **stick's WiFi address**; external HTTPS 200; DNS resolved via the stick |
| zram | `/dev/zram0` 350M, `zstd` |
| LEDs | 8 present, brightness writable |
| Reset button | `gpio-keys` event0 present |
| USB transfer | 32 MB in 3.24 s (~10 MB/s), sha256 matches at both ends |
| Failed units | 0 |
| No-WiFi state | `usb0` up on its own, `wlan0` down — the out-of-box case |

Measured against `ufi103s-venus-4g-gpu`: boot image 5,935,104 vs 8,003,584 B
(-26%), decompressed kernel 15,849,480 vs 21,723,144 B (-27%), 460 vs 696
modules (-34%). `MemTotal` is identical to `ufi103s-baseline` — the ~97 MB
gain against the GPU variant comes from the device tree disabling the
modem/PIL reservations, not from kernel configuration.

Not verified: flashing this image to flash, and first boot from flash. That
is why this directory's `build.json` carries its own `status` string rather
than the generic "has not been flashed" one used by the other five.
