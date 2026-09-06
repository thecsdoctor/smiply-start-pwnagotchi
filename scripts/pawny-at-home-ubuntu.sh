#!/usr/bin/env bash
# pawny-at-home-ubuntu.sh
#
# Idempotent day-to-day script: bring up the USB link to the pwnagotchi on
# an Ubuntu PC (native or inside WSL2), confirm SSH, and share this PC's
# internet to the Pi. Detects interface-name/MAC drift across reboots and
# replugs and cleans up stale profiles/NAT rules interactively.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/pwny-lib.sh"

info "=== pawny-at-home-ubuntu: starting ==="

IS_WSL=false
grep -qi microsoft /proc/version 2>/dev/null && IS_WSL=true
if $IS_WSL; then
  info "WSL detected."
  if ! ip link show 2>/dev/null | grep -q "enx"; then
    warn "No enx* interface visible yet in WSL."
    confirm "Have you run 'usbipd attach --wsl --busid <BUSID>' in Windows PowerShell?" || die "Run that first, then re-run this script."
  fi
fi

IFACE="$(wait_for_usb_iface 15)"
[ -z "$IFACE" ] && die "No USB network interface found. Check the cable / usbipd attach."

MAC="$(get_iface_mac "$IFACE")"
PREV_IFACE="$(state_get LAST_IFACE_NAME)"
PREV_MAC="$(state_get LAST_IFACE_MAC)"

if [ -n "$PREV_IFACE" ] && [ "$PREV_IFACE" != "$IFACE" ]; then
  warn "Interface name changed: '$PREV_IFACE' -> '$IFACE'."
fi
if [ -n "$PREV_MAC" ] && [ "$PREV_MAC" != "$MAC" ]; then
  warn "MAC address changed: '$PREV_MAC' -> '$MAC'."
fi

if [ -n "$PREV_IFACE" ] && { [ "$PREV_IFACE" != "$IFACE" ] || [ "$PREV_MAC" != "$MAC" ]; }; then
  warn "This usually happens after a reboot (unpinned gadget MAC) or a different USB port."
  if confirm "Clean up the old profile/NAT rules for '$PREV_IFACE' now?"; then
    nmcli -t -f NAME,DEVICE con show | grep ":$PREV_IFACE\$" | cut -d: -f1 | while read -r old_con; do
      sudo nmcli con delete "$old_con" && info "Deleted old profile: $old_con"
    done
    OLD_UPLINK="$(state_get LAST_UPLINK)"
    if [ -n "$OLD_UPLINK" ]; then
      sudo iptables -D FORWARD -i "$OLD_UPLINK" -o "$PREV_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
      sudo iptables -D FORWARD -i "$PREV_IFACE" -o "$OLD_UPLINK" -j ACCEPT 2>/dev/null || true
      info "Removed old forwarding rules referencing $PREV_IFACE."
    fi
  fi
fi
state_set LAST_IFACE_NAME "$IFACE"
state_set LAST_IFACE_MAC "$MAC"

info "Bringing up $IFACE..."
sudo ip link set "$IFACE" up

if ! nmcli -t -f NAME,DEVICE con show | grep -q ":$IFACE\$"; then
  sudo nmcli con add type ethernet ifname "$IFACE" con-name pwn-usb ipv4.method auto ipv6.method disabled
  ok "Created pwn-usb profile for $IFACE."
else
  ok "pwn-usb profile already exists."
fi
sudo nmcli con up pwn-usb || die "Failed to bring up pwn-usb."
sleep 2
ip addr show "$IFACE" | tee -a "$LOG_FILE"

PI_TARGET="pi@10.12.194.1"
check_ssh "$PI_TARGET" || die "Interface is up but SSH to $PI_TARGET failed. Is the Pi powered on?"
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
ssh_run "$PI_TARGET" "sudo ip route replace default via $PC_IP dev usb0"
ssh_run "$PI_TARGET" "echo 'nameserver 8.8.8.8' | sudo tee /etc/resolv.conf >/dev/null"

if check_pi_internet "$PI_TARGET"; then
  ok "SSH + internet both confirmed working. Pawny is home and online."
else
  warn "SSH works but internet check failed — verify uplink '$UPLINK' actually has internet."
fi

ok "=== pawny-at-home-ubuntu: done. Log: $LOG_FILE ==="
