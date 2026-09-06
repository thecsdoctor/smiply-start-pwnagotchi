#!/usr/bin/env bash
# came-from-a-walk-ubuntu.sh
#
# Run on an Ubuntu PC (native OR inside WSL2) after returning home with the
# pwnagotchi. Detects the USB link (name/MAC-independent), restores gadget
# mode if it was disabled for iPhone/Android host-tethering, brings up
# networking, and re-establishes SSH + internet sharing to the Pi.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/pwny-lib.sh"

info "=== came-from-a-walk-ubuntu: starting ==="

IS_WSL=false
grep -qi microsoft /proc/version 2>/dev/null && IS_WSL=true

if $IS_WSL; then
  warn "WSL detected. In an elevated Windows PowerShell you should have already run:"
  warn "  usbipd list"
  warn "  usbipd attach --wsl --busid <BUSID>"
  confirm "Has the device been attached to WSL already?" || die "Attach it first, then re-run this script."
fi

STRATEGY="$(state_get LAST_WALK_STRATEGY)"
info "Last recorded walk strategy: ${STRATEGY:-unknown}"

if [ "$STRATEGY" = "usb-host" ]; then
  warn "Pi was left in USB-HOST mode (for iPhone/Android host tethering)."
  warn "It cannot enumerate to this PC until it boots back into gadget mode."
  IFACE="$(wait_for_usb_iface 10)"
  if [ -z "$IFACE" ]; then
    warn "No USB interface appeared yet."
    if confirm "Can you reach the Pi another way right now (e.g. its own WiFi)?"; then
      WIFI_TARGET="$(ask "SSH target over WiFi (user@ip)")"
      if check_ssh "$WIFI_TARGET"; then
        ssh_run "$WIFI_TARGET" "
          sudo cp -f /boot/firmware/config.txt.bak /boot/firmware/config.txt 2>/dev/null
          sudo cp -f /boot/firmware/cmdline.txt.bak /boot/firmware/cmdline.txt 2>/dev/null
          sudo reboot
        " && ok "Requested revert + reboot over WiFi." || warn "Revert command failed — you may need to do this manually."
        info "Waiting ~25s for the Pi to reboot and enumerate over USB..."
        sleep 25
        IFACE="$(wait_for_usb_iface 20)"
      fi
    fi
  fi
  if [ -z "$IFACE" ]; then
    warn "Still no USB interface after the WiFi attempt (or no WiFi available)."
    echo
    echo "Fix it directly from the SD card instead:"
    echo "  1) Power off the Pi and remove the microSD card."
    echo "  2) Insert it into this PC's card reader — the boot partition should auto-mount."
    echo
    BOOTDIR="$(find_boot_partition || true)"
    if [ -z "$BOOTDIR" ]; then
      BOOTDIR="$(ask "Couldn't auto-detect the boot partition — enter its mount path (blank to see manual instructions)" "")"
    fi
    if [ -n "$BOOTDIR" ] && [ -f "$BOOTDIR/config.txt" ]; then
      restore_gadget_mode_on_sdcard "$BOOTDIR"
      confirm "Files updated. Eject the card, put it back in the Pi, power it on, and reconnect the cable. Press y once that's done" 
      IFACE="$(wait_for_usb_iface 20)"
    else
      warn "No boot partition found/entered. Edit it manually once mounted:"
      echo "  In config.txt   : change the line '#dtoverlay=dwc2' to 'dtoverlay=dwc2'"
      echo "  In cmdline.txt  : add ' modules-load=dwc2,g_ether' to the end of the single line"
      echo "  (or simpler: copy config.txt.bak -> config.txt and cmdline.txt.bak -> cmdline.txt, if those exist)"
      echo "Then eject the card, put it back in the Pi, power it on, reconnect the cable, and re-run this script."
    fi
  fi
  [ -z "$IFACE" ] && die "Still no USB interface. Follow the instructions above, then re-run this script."
else
  IFACE="$(wait_for_usb_iface 15)"
  [ -z "$IFACE" ] && die "No USB interface detected. Check the cable and that the Pi is powered on."
fi

info "Using interface: $IFACE"
MAC="$(get_iface_mac "$IFACE")"
PREV_MAC="$(state_get LAST_IFACE_MAC)"
if [ -n "$PREV_MAC" ] && [ "$PREV_MAC" != "$MAC" ]; then
  warn "MAC changed since last time ($PREV_MAC -> $MAC) — normal after a reboot if the gadget MAC isn't pinned."
fi
state_set LAST_IFACE_MAC "$MAC"
state_set LAST_IFACE_NAME "$IFACE"

info "Bringing up $IFACE (idempotent)..."
sudo ip link set "$IFACE" up

if ! nmcli -t -f NAME,DEVICE con show | grep -q ":$IFACE$"; then
  sudo nmcli con add type ethernet ifname "$IFACE" con-name pwn-usb ipv4.method auto ipv6.method disabled
  ok "Created pwn-usb profile."
else
  ok "pwn-usb profile already exists."
fi
sudo nmcli con up pwn-usb || die "Could not bring up pwn-usb connection."
sleep 2
ip addr show "$IFACE" | tee -a "$LOG_FILE"

PI_TARGET="pi@10.12.194.1"
check_ssh "$PI_TARGET" || die "Interface is up but SSH to $PI_TARGET still fails. Check the Pi's usb0 address."
state_set PI_SSH_TARGET "$PI_TARGET"

UPLINK="$(state_get LAST_UPLINK)"
UPLINK="$(ask "PC uplink interface with real internet" "${UPLINK:-eth0}")"
state_set LAST_UPLINK "$UPLINK"

info "Setting up internet sharing PC -> Pi..."
sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
sudo iptables -t nat -C POSTROUTING -o "$UPLINK" -j MASQUERADE 2>/dev/null || \
  sudo iptables -t nat -A POSTROUTING -o "$UPLINK" -j MASQUERADE
sudo iptables -C FORWARD -i "$UPLINK" -o "$IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
  sudo iptables -A FORWARD -i "$UPLINK" -o "$IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -C FORWARD -i "$IFACE" -o "$UPLINK" -j ACCEPT 2>/dev/null || \
  sudo iptables -A FORWARD -i "$IFACE" -o "$UPLINK" -j ACCEPT

PC_IP="$(ip -4 addr show "$IFACE" | awk '/inet /{print $2}' | cut -d/ -f1)"
info "This PC's address on the link: $PC_IP"
ssh_run "$PI_TARGET" "sudo ip route replace default via $PC_IP dev usb0" \
  && ok "Set Pi default route via $PC_IP." || warn "Could not set Pi default route."
ssh_run "$PI_TARGET" "echo 'nameserver 8.8.8.8' | sudo tee /etc/resolv.conf >/dev/null"

if check_pi_internet "$PI_TARGET"; then
  ok "SSH + internet both confirmed. Welcome home, Pawny."
else
  warn "Pi still has no internet — double check the uplink interface name and NAT rules."
fi

state_set LAST_WALK_STRATEGY "home"
ok "=== came-from-a-walk-ubuntu: done. Log: $LOG_FILE ==="
