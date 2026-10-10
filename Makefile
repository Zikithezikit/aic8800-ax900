# aic8800-ax900 — top-level Makefile
#
# Single entry point for building, deploying, verifying and driving the
# AIC8800D80 driver. The kbuild fragment that actually compiles the modules
# lives in kernel/aic8800/Makefile and is not meant to be invoked directly.
#
#   make              list every target
#   make build        compile the three modules for the running kernel
#   sudo make install deploy everything
#   sudo make check   full verification pass
#
# Target a different kernel with KVER:
#   make build KVER=7.0.0-30-generic

SHELL       := /bin/bash
# Deliberately NOT using `-o pipefail`. This file leans on `cmd | grep -q`
# throughout, and grep -q exits on first match, which SIGPIPEs the writer and
# makes every one of those pipelines report failure.
.SHELLFLAGS := -c

REPO        := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
KERNEL_DIR  := $(REPO)/kernel/aic8800
FW_DIR      := $(REPO)/fw
SCRIPTS     := $(REPO)/packaging/scripts
THISFILE    := $(lastword $(MAKEFILE_LIST))

# Package identity. Keep in step with packaging/dkms.conf, which DKMS requires
# to be literal. `make stage` cross-checks the two and fails on a mismatch, so
# a version bump that misses one side is caught at deploy time, not at runtime.
PKG         := aic8800-ax900
VERSION     := 1.0.0
STAGE_DIR   := /usr/src/$(PKG)-$(VERSION)

KVER        ?= $(shell uname -r)
KDIR        ?= /lib/modules/$(KVER)/build
BUILD_DIR   := $(REPO)/build/$(KVER)
MODULES     := aic_load_fw aic8800_fdrv aic_zlp_quirk

# Exported so packaging/scripts/*.sh pick these up instead of repeating the
# version in three more places.
export AIC8800_PKG = $(PKG)
export AIC8800_VER = $(VERSION)

# Run as root when not already root.
SUDO        := $(if $(filter 0,$(shell id -u)),,sudo)

# Interface name of the dongle, e.g. wlx688fc98ff64a.
IFACE       ?= $(shell iw dev 2>/dev/null | awk '/Interface/{print $$2; exit}')

# Throughput probe used by `make speedtest`. Override for a mirror that is
# closer to you:  make speedtest URL=https://cachefly.cachefly.net/100mb.test
SPEEDTEST_URL ?= https://proof.ovh.net/files/100Mb.dat

.DEFAULT_GOAL := help

.PHONY: build clean install uninstall reinstall firmware user-groups \
        status logs modules scan link showvars \
        connect disconnect speedtest check \
        fix debug debug-on debug-off relink help

# =============================================================================
# Build
# =============================================================================

# Note: `make build` links the modules but does not sign them. DKMS signs during
# `make install`, and an unsigned module will not insert under an enforcing
# Secure Boot policy. For a build you intend to load, use `make install`.
## @Build build: compile all three modules for the target kernel
build:
	@echo "==> building for $(KVER)"
	@test -d "$(KDIR)" || { echo "error: no kernel headers at $(KDIR)"; exit 1; }
	$(MAKE) -C "$(KDIR)" M="$(KERNEL_DIR)" modules
	@mkdir -p "$(BUILD_DIR)"
	@missing=; for m in $(MODULES); do \
		if [ ! -f "$(KERNEL_DIR)/$$m/$$m.ko" ]; then \
			missing="$$missing $$m"; \
			continue; \
		fi; \
		cp -f "$(KERNEL_DIR)/$$m/$$m.ko" "$(BUILD_DIR)/"; \
	done; \
	if [ -n "$$missing" ]; then \
		echo "error: build did not produce:$$missing" >&2; exit 1; \
	fi
	@echo "==> artefacts in $(BUILD_DIR)"

## @Build clean: remove build artefacts
clean:
	@echo "==> cleaning"
	$(MAKE) -C "$(KDIR)" M="$(KERNEL_DIR)" clean 2>/dev/null || true
	rm -rf "$(REPO)/build"

# =============================================================================
# Deploy
# =============================================================================

## @Deploy user-groups: grant a desktop account real-time audio scheduling
##
##      Bluetooth dropouts are often not a Bluetooth fault. Without
##      RLIMIT_RTPRIO the PipeWire A2DP loop runs at normal priority, gets
##      descheduled under load, and the audio stutters with nothing in any log.
##      Determines the account from SUDO_USER, touches only groups that exist,
##      and does not overwrite an existing limits file.
# No argument by default: the script derives the account from SUDO_USER, which
# sudo sets correctly. Pass an explicit one only if you override it:
#   sudo make user-groups TARGET_USER=someone-else
user-groups:
	$(SUDO) $(SCRIPTS)/setup-user-groups.sh $(TARGET_USER)

## @Deploy install: DKMS, firmware, udev/modprobe config and user groups
install:
	$(SUDO) $(SCRIPTS)/install.sh

## @Deploy uninstall: remove modules, DKMS package and configuration
uninstall:
	$(SUDO) $(SCRIPTS)/uninstall.sh

## @Deploy reinstall: uninstall then install, for iterating on packaging changes
reinstall:
	$(SUDO) $(SCRIPTS)/uninstall.sh || true
	$(SUDO) $(SCRIPTS)/install.sh

## @Deploy firmware: copy the fw/ blobs into /lib/firmware without touching DKMS
firmware:
	@$(SUDO) $(SCRIPTS)/post_install.sh "$(FW_DIR)"

# =============================================================================
# Inspect
# =============================================================================

## @Inspect status: one-screen summary of the dongle's current state
status:
	@echo "=== USB ==="
	@lsusb | grep -iE 'aic|1111' | sed 's/^/  /' || echo "  (dongle not present)"
	@echo
	@echo "=== modules ==="
	@lsmod | grep -E '^aic' | sed 's/^/  /' || echo "  (aic modules not loaded)"
	@echo
	@echo "=== phy ==="
	@iw dev 2>/dev/null | sed 's/^/  /' || echo "  (no wireless interface)"
	@echo
	@echo "=== link ==="
	@if [ -n "$(IFACE)" ]; then iw dev $(IFACE) link 2>/dev/null | sed 's/^/  /'; \
		else echo "  (no interface)"; fi
	@echo
	@echo "=== addresses ==="
	@ip -br addr show "$(IFACE)" 2>/dev/null | sed 's/^/  /' || true
	@echo
	@echo "=== NetworkManager ==="
	@nmcli -f DEVICE,STATE,CONNECTION device status 2>/dev/null | grep -E 'DEVICE|wl' | sed 's/^/  /'
	@echo
	@echo "=== bluetooth ==="
	@btmgmt info 2>/dev/null | head -3 | sed 's/^/  /' || echo "  (no hci)"

## @Inspect logs: filtered kernel log for the driver (N=<lines>, default 60)
logs:
	@$(SUDO) dmesg | grep -iE 'aic|btusb' | tail -n $(or $(N),60)

## @Inspect modules: the USB aliases each built module claims to bind
modules:
	@for m in $(MODULES); do \
		ko="$(BUILD_DIR)/$$m.ko"; \
		[ -f "$$ko" ] || ko=$$(find "$(KERNEL_DIR)" -name "$$m.ko" 2>/dev/null | head -1); \
		if [ -f "$$ko" ]; then src="$$ko (local build)"; else src="$$m (installed)"; fi; \
		echo "=== $$m ==="; \
		modinfo "$${ko:-$$m}" 2>/dev/null | grep -E '^(alias|depends|vermagic)' | sed 's/^/  /' \
			|| echo "  not installed and not built — run 'make build'"; \
		echo "  source: $$src"; \
		echo; \
	done

## @Inspect scan: scan for networks (as root; without it you get EPERM)
scan:
	@if [ -z "$(IFACE)" ]; then echo "no wireless interface"; exit 1; fi
	$(SUDO) iw dev "$(IFACE)" scan

## @Inspect link: current association and PHY rates
link:
	@if [ -z "$(IFACE)" ]; then echo "no wireless interface"; exit 1; fi
	@iw dev "$(IFACE)" link

## @Inspect showvars: print the resolved variables
showvars:
	@echo "REPO         = $(REPO)"
	@echo "PACKAGE      = $(PKG)/$(VERSION)"
	@echo "KERNEL_DIR   = $(KERNEL_DIR)"
	@echo "BUILD_DIR    = $(BUILD_DIR)"
	@echo "KVER         = $(KVER)"
	@echo "KDIR         = $(KDIR)"
	@echo "IFACE        = $(IFACE)"
	@echo "SUDO         = $(SUDO)"

# =============================================================================
# Act
# =============================================================================

## @Act connect: bring up a saved NM profile (SSID=<profile>)
connect:
	@test -n "$(SSID)" || { echo "usage: make connect SSID=<profile>"; exit 1; }
	$(SUDO) nmcli connection up "$(SSID)"

## @Act disconnect: bring down the current connection
disconnect:
	$(SUDO) nmcli connection down "$(if $(SSID),$(SSID),$(IFACE))" || true

## @Act speedtest: throughput over the air, bound to the dongle's interface
speedtest:
	@if [ -z "$(IFACE)" ]; then echo "no wireless interface"; exit 1; fi
	@echo "==> download bound to $(IFACE) from $(SPEEDTEST_URL)"
	@curl -s -o /dev/null --interface "$(IFACE)" --max-time 60 \
		-w '  http=%{http_code}  size=%{size_download}  time=%{time_total}s  speed=%{speed_download} B/s\n' \
		"$(SPEEDTEST_URL)" || echo "  (speedtest server unreachable)"
	@iw dev "$(IFACE)" link 2>/dev/null | grep -E 'signal|bitrate' | sed 's/^/  /'

## @Act check: verify the whole chain, from toolchain to radio to bluetooth
check:
	@fail=0; \
	pass() { printf '  \033[1;32mPASS\033[0m  %s\n' "$$1"; }; \
	fail() { printf '  \033[1;31mFAIL\033[0m  %s\n' "$$1"; fail=1; }; \
	note() { printf '        \033[0;33mnote\033[0m  %s\n' "$$1"; }; \
	echo "== toolchain and DKMS package =="; \
	command -v dkms >/dev/null && pass "dkms present" || fail "dkms missing"; \
	[ -d "$(KDIR)" ] && pass "kernel headers for $(KVER)" || fail "no headers for $(KVER)"; \
	$(SUDO) dkms status | grep -q "^$(PKG)/$(VERSION), $(KVER)" \
		&& pass "DKMS package installed for $(KVER)" \
		|| fail "DKMS package not installed for $(KVER)"; \
	$(SUDO) dkms status | grep -q '^aic8800/radxa' \
		&& fail "superseded aic8800/radxa is still present" \
		|| pass "superseded aic8800/radxa absent"; \
	repo=$$(cd "$(REPO)" && pwd); \
	leak=$$(grep -lF "$$repo" /etc/udev/rules.d/50-$(PKG).rules \
	          /etc/modprobe.d/$(PKG).conf \
	          /etc/modules-load.d/$(PKG).conf \
	          $(STAGE_DIR)/dkms.conf 2>/dev/null | wc -l); \
	if [ "$$leak" -eq 0 ]; then \
		pass "nothing installed references this checkout"; \
		note "so the folder can be deleted; 'aic8800-ax900 check' still works"; \
	else \
		fail "$$leak installed file(s) still point at this checkout"; \
	fi; \
	src=$$(readlink -f /var/lib/dkms/$(PKG)/$(VERSION)/source 2>/dev/null || echo ""); \
	if [ "$$src" = "$(STAGE_DIR)" ]; then \
		pass "DKMS builds from $$src"; \
	else \
		fail "DKMS source is '$${src:-unset}', expected $(STAGE_DIR)"; \
	fi; \
	[ -x /usr/local/bin/$(PKG) ] \
		&& pass "$(PKG) command installed (checkout not required)" \
		|| note "$(PKG) command missing — re-run: sudo make install"; \
	echo "== firmware blobs =="; \
	for b in fmacfw_8800d80_u02.bin lmacfw_rf_8800d80_u02.bin fw_patch_8800d80_u02.bin \
	         fw_adid_8800d80_u02.bin aic_userconfig_8800d80.txt; do \
		[ -f /lib/firmware/aic8800D80/$$b ] && pass "$$b" || fail "$$b missing"; \
	done; \
	echo "== modules =="; \
	for m in aic_load_fw aic8800_fdrv; do \
		lsmod | grep -q "^$$m " && pass "$$m loaded" || fail "$$m not loaded"; \
	done; \
	$(SUDO) modinfo aic8800_fdrv 2>/dev/null | grep -q 'usb:vA69Cp8D81' \
		&& pass "fdrv claims a69c:8d81 (this dongle's post-flash ID)" \
		|| fail "fdrv has no a69c:8d81 alias"; \
	$(SUDO) modinfo aic_load_fw 2>/dev/null | grep -q 'usb:vA69Cp8D80' \
		&& pass "load_fw claims a69c:8d80 (boot mode)" \
		|| fail "load_fw has no a69c:8d80 alias"; \
	echo "== USB device =="; \
	usb=$$(lsusb | grep -i aic | sed -n 's/.*ID \([0-9a-fA-F]\{4\}:[0-9a-fA-F]\{4\}\).*/\1/p'); \
	case "$$usb" in \
		a69c:8d81) pass "enumerated a69c:8d81 — firmware downloaded";; \
		a69c:8d80) fail "still a69c:8d80 — aic_load_fw did not push firmware";; \
		1111:1111) fail "still 1111:1111 — usb_modeswitch did not run";; \
		"")        fail "dongle not present on USB";; \
		*)         fail "unexpected USB ID $$usb";; \
	esac; \
	quirk=$$(for d in /sys/bus/usb/devices/*; do \
		[ -r "$$d/idVendor" ] && [ -r "$$d/avoid_reset_quirk" ] || continue; \
		case "$$(cat "$$d/idVendor"):$$(cat "$$d/idProduct")" in \
			a69c:8d80|a69c:8d81|368b:8d83|368b:8d85) \
				cat "$$d/avoid_reset_quirk"; break;; \
		esac; \
	done); \
	if [ "$$quirk" = "1" ]; then pass "avoid_reset_quirk set"; \
	else note "avoid_reset_quirk is '$${quirk:-not found}' (udev rule applies it on add)"; fi; \
	echo "== radio =="; \
	iw dev >/dev/null 2>&1 && pass "phy present" || fail "no phy"; \
	if rfkill list wifi 2>/dev/null | grep -q 'Soft blocked: no'; then \
		pass "wifi not soft blocked"; \
	else \
		fail "wifi soft blocked — run: sudo rfkill unblock wifi"; \
	fi; \
	$(SUDO) iw phy 2>/dev/null | grep -q 'HE PHY Capabilities' \
		&& pass "802.11ax (HE) advertised" \
		|| fail "no HE PHY Capabilities — not Wi-Fi 6 capable"; \
	$(SUDO) iw phy 2>/dev/null | grep -q 'Band 1:' && pass "2.4 GHz band" || fail "no 2.4 GHz band"; \
	$(SUDO) iw phy 2>/dev/null | grep -q 'Band 2:' && pass "5 GHz band"   || fail "no 5 GHz band"; \
	echo "== scan (root) =="; \
	if [ -z "$(IFACE)" ]; then \
		fail "no interface to scan"; \
	else \
		bss=$$(timeout 45 $(SUDO) iw dev "$(IFACE)" scan 2>/dev/null | grep -c '^BSS '); \
		if [ "$$bss" -gt 0 ]; then pass "scan found $$bss BSS"; \
		else note "scan found nothing — expected if associated and idle"; fi; \
	fi; \
	echo "== real-time audio scheduling =="; \
	if pgrep -x pipewire >/dev/null 2>&1; then \
		rt=$$(ps -L -C pipewire -o cls= 2>/dev/null | grep -c 'FF' || true); \
		if [ "$$rt" -gt 0 ]; then \
			pass "PipeWire has $$rt real-time thread(s)"; \
		else \
			fail "PipeWire is not real-time (audio loop on TS) — Bluetooth audio will stutter"; \
			note "audio stutters under load with nothing in any log"; \
			note "fix: sudo make user-groups, then log out and back in"; \
		fi; \
		cur=$$(ulimit -r 2>/dev/null || echo 0); \
		[ "$$cur" -gt 0 ] && pass "RLIMIT_RTPRIO = $$cur" \
			|| note "RLIMIT_RTPRIO = 0 in this shell (expected: PAM applies it at login)"; \
	else \
		note "pipewire not running, skipped"; \
	fi; \
	echo "== bluetooth =="; \
	if btmgmt info >/dev/null 2>&1; then \
		pass "hci0 up (BT version $$(btmgmt info 2>/dev/null | grep -o 'version [0-9]*' | head -1 | cut -d' ' -f2))"; \
	else \
		fail "no bluetooth controller"; \
	fi; \
	echo; \
	if [ "$$fail" -eq 0 ]; then echo "RESULT: all checks passed"; \
	else echo "RESULT: some checks failed (see above)"; fi; \
	exit $$fail

# =============================================================================
# Debug
# =============================================================================

# Reloading the driver out from under wpa_supplicant leaves a scan permanently
# in flight ("Reject scan trigger since one is already pending"), after which it
# never issues a connect again. Replugging does NOT clear it: the stale state
# lives in userspace.
## @Debug fix: clear wpa_supplicant's stale scan state
fix:
	$(SUDO) systemctl restart wpa_supplicant
	@echo "wpa_supplicant restarted; now run: make connect SSID=<profile>"

## @Debug debug: show the current driver log level
debug:
	@for m in aic_load_fw aic8800_fdrv; do \
		if [ ! -d /sys/module/$$m ]; then \
			v="not loaded"; \
		elif v=$$($(SUDO) cat /sys/module/$$m/parameters/aicwf_dbg_level 2>/dev/null); then \
			:; \
		else \
			v="unreadable without root"; \
		fi; \
		printf '  %-14s %s\n' "$$m" "$$v"; \
	done
	@echo "  levels: 1=ERROR  3=+INFO  7=+TRACE  15=+DEBUG"

## @Debug debug-on: turn full driver logging on
debug-on:
	$(SUDO) sh -c 'echo 15 > /sys/module/aic8800_fdrv/parameters/aicwf_dbg_level'
	$(SUDO) sh -c 'echo 15 > /sys/module/aic_load_fw/parameters/aicwf_dbg_level'
	@echo "driver logging on; read it with: make logs"

## @Debug debug-off: quiet the driver back down to errors only
debug-off:
	$(SUDO) sh -c 'echo 1 > /sys/module/aic8800_fdrv/parameters/aicwf_dbg_level'
	$(SUDO) sh -c 'echo 1 > /sys/module/aic_load_fw/parameters/aicwf_dbg_level'
	@echo "driver logging off"

# A port reset is not a power cycle: the chip returns as a69c:8d81 still
# running its firmware, rather than going back to a69c:8d80.
## @Debug relink: USB port reset (not a power cycle)
relink:
	@test -n "$(IFACE)" || { echo "no wireless interface; pass IFACE=<name>"; exit 1; }
	$(SUDO) sh -c 'd=$$(basename $$(readlink -f /sys/class/net/$(IFACE)/device)); \
		echo $$d > /sys/bus/usb/drivers/usb/unbind; sleep 3; \
		echo $$d > /sys/bus/usb/drivers/usb/bind; sleep 8'
	@lsusb | grep -i aic | sed 's/^/  /'

# =============================================================================
# Help — generated from the "@Group target: description" comments above,
# so the list can never drift from the targets that exist.
# =============================================================================

help:
	@echo "aic8800-ax900 — AIC8800D80 WiFi 6 + BT 5.3 USB dongle driver"
	@echo
	@echo "Usage: make <target>        override kernel with KVER=<version>"
	@echo
	@for g in Build Deploy Inspect Act Debug; do \
		grep -q "^## @$$g " $(THISFILE) || continue; \
		printf '  \033[1m%s\033[0m\n' "$$g"; \
		grep -h "^## @$$g " $(THISFILE) | sed -e 's/^## @[^ ]* //' | \
		awk '{ i = index($$0, ": "); \
		       printf "    \033[1m%-15s\033[0m %s\n", substr($$0, 1, i-1), substr($$0, i+2) }'; \
		printf '\n'; \
	done
	@echo "  Typical session:"
	@echo "    make build && sudo make install && sudo make check"
	@echo "    sudo make connect SSID=<ssid_name> && make speedtest"
	@echo
	@echo "  See README.md for troubleshooting and architecture notes."