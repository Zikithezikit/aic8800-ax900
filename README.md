# aic8800-ax900

Out-of-tree Linux driver for the **aicsemi AIC8800D80** (marketed as the UGREEN
AX900) USB dongle: Wi-Fi 6 (802.11ax) 2×2 + Bluetooth 5.3.

Packs as a DKMS package, so it rebuilds and reinstalls itself across kernel
upgrades. Installs three modules plus firmware, udev rules and modprobe config.

## Requirements

- Linux kernel with `CONFIG_CFG80211` and a matching headers package
  (`linux-headers-$(uname -r)`)
- `dkms`, `make`, `gcc`, `rsync`
- `usb-modeswitch` — optional but recommended; without it a dongle that
  enumerates as `1111:1111` stays stuck in mass-storage mode
- Bluetooth userspace (`bluez`) for the BT half; PipeWire for audio

## Install

```sh
git clone <this-repo> aic8800-ax900
cd aic8800-ax900
sudo make install
sudo make check
```

`make install` replaces the stock `aic8800/radxa` DKMS package, which builds
but binds neither stage of this dongle's boot handshake.

Add `--all-kernels` to build for every kernel in `/lib/modules` rather than
just the running one.

## Uninstall

```sh
sudo make uninstall                    # keeps /lib/firmware/aic8800*
sudo make uninstall -- --purge-firmware
```

## Usage

The checkout is disposable once installed: DKMS builds from a staged copy in
`/usr/src`, and the kernel loads modules from `/lib/modules`. After install a
wrapper in `/usr/local/bin` keeps the operational commands available, so you
can delete this folder and everything still works:

```sh
aic8800-ax900 check      # same as `make check`
aic8800-ax900 status     # same as `make status`
aic8800-ax900 next       # what is left to do
aic8800-ax900 uninstall
```

`make help` lists every target. `make speedtest URL=<url>` points the
throughput probe at a different mirror.

## How the dongle enumerates

Three states, each needing a different piece of the stack:

```
1111:1111   driverless "driver disk" CD-ROM
    |  usb_modeswitch, two SCSI CBWs ending F3/F2
    v
a69c:8d80   factory/download mode, 2 bulk endpoints, no driver
    |  aic_load_fw binds, pushes lmacfw_rf + fmacfw + fw_patch
    v
a69c:8d81   operational fullmac mode, 3 interfaces:
             1.0 / 1.1  class 0xe0/01/01  -> btusb
             1.2        class 0xff       -> aic8800_fdrv (Wi-Fi)
```

The chip reboots itself between `8d80` and `8d81`, so every udev rule is
matched per-enumeration rather than once. Some dongles re-enumerate onto the
`368b` vendor ID instead of staying on `a69c`; both are handled.

## Modules

| Module | Role |
| --- | --- |
| `aic_load_fw` | boot-mode firmware downloader (binds `a69c:8d80`) |
| `aic8800_fdrv` | fullmac Wi-Fi driver (binds `a69c:8d81` / `368b:8d85`) |
| `aic_zlp_quirk` | btusb ACL bulk-TX ZLP workaround (`368b:8d81`, `a69c:8d81`) |

`aic_load_fw` must load first; it is what performs the `8d80 -> 8d81`
transition. `aic8800_fdrv` registers early and binds once that has happened.

## Troubleshooting

**Bluetooth audio drops out after a minute or two, nothing in the log.**
The controller does not report completion for ACL bulk OUT transfers unless
each is ZLP-terminated. PipeWire reports *"Missing completion reports for
packet ... adapter firmware bug?"*, stops taking credits and tears the A2DP
transport down. `aic_zlp_quirk` works around this — check it is loaded:

```sh
lsmod | grep aic_zlp_quirk
make logs
```

**Audio stutters under load, but Bluetooth is fine.**
Usually not a driver fault. Without `RLIMIT_RTPRIO` the PipeWire A2DP feed loop
runs at normal priority and gets descheduled. Fix and re-login:

```sh
sudo make user-groups        # add account to audio groups + rtprio limits
# log out and back in
ps -L -C pipewire -o tid,cls,rtprio,comm   # data-loop.0 should read FF, not TS
```

**Scans fine, but never associates.**
Reloading the driver out from under `wpa_supplicant` leaves a scan permanently
in flight (`Reject scan trigger since one is already pending`) and it never
issues a connect again. Replugging does **not** clear it — the stale state is
in userspace:

```sh
sudo make fix
make connect SSID=<profile>
```

**Still enumerates as `1111:1111`.**
`usb_modeswitch` is missing or its data file is absent:
`/etc/usb_modeswitch.d/1111:1111`. `make check` reports both.

**Wi-Fi dies on replug and only returns after a manual unplug.**
The USB core performs a port reset while the driver holds the device. A udev
rule sets `avoid_reset_quirk=1` on add; see
`packaging/modprobe.d/aic8800-ax900.conf` for the boot-time equivalent.

**Turn up driver logging:**

```sh
sudo make debug-on      # full trace
make logs               # read it
sudo make debug-off
```

## Layout

```
Makefile                     entry point; `make help` is generated from it
kernel/aic8800/              driver sources (vendor) + aic_zlp_quirk (ours)
  aic_load_fw/               firmware downloader
  aic8800_fdrv/              fullmac Wi-Fi driver
  aic_zlp_quirk/             btusb ZLP workaround
fw/                          firmware blobs, per chip revision
packaging/
  dkms.conf                  the DKMS package definition
  scripts/                   install, uninstall, stage, post-install helpers
  udev/ modprobe.d/ modules-load.d/
tests/openwrt-backports/     build against a backported cfg80211
```

The driver sources under `kernel/` are the vendor's, unmodified apart from
the build glue in their `Makefile`s. `aic_zlp_quirk` is ours.

## Licence

Driver sources are GPL-2.0. Firmware blobs are the vendor's binaries and
carry their own terms.