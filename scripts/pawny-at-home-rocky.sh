#!/usr/bin/env bash
# pawny-at-home-rocky.sh
#
# Idempotent day-to-day script: bring up the USB link to the pwnagotchi on
# a native Rocky Linux PC, confirm SSH, and share this PC's internet to
# the Pi via firewalld. Detects interface-name/MAC drift across reboots
# and replugs and cleans up stale profiles/zone assignments interactively.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/pwny-lib.sh"

info "=== pawny-at-home-rocky: starting ==="

IFACE="$(wait_for_usb_iface 15)"
[ -z "$IFACE" ] && die "No USB network interface found. Check the cable."

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
  if confirm "Clean up the old profile/zone/policy references for '$PREV_IFACE' now?"; then
    nmcli -t -f NAME,DEVICE con show | grep ":$PREV_IFACE\$" | cut -d: -f1 | while read -r old_con; do
      sudo nmcli con delete "$old_con" && info "Deleted old profile: $old_con"
    done
    info "Note: firewalld's 'internal' zone interface binding will simply be reassigned"
    info "to the new interface below — nothing further to clean up there."
  fi
fi
state_set LAST_IFACE_NAME "$IFACE"
state_set LAST_IFACE_MAC "$MAC"

info "Ensuring NetworkManager profile exists for $IFACE (idempotent)..."
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
UPLINK_ZONE="$(state_get LAST_UPLINK_ZONE)"
UPLINK_ZONE="$(ask "firewalld zone of that uplink" "${UPLINK_ZONE:-public}")"
state_set LAST_UPLINK "$UPLINK"
state_set LAST_UPLINK_ZONE "$UPLINK_ZONE"

info "Setting up internet sharing PC -> Pi via firewalld..."
sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
sudo firewall-cmd --zone=internal --change-interface="$IFACE"
sudo firewall-cmd --zone="$UPLINK_ZONE" --query-masquerade >/dev/null 2>&1 || \
  sudo firewall-cmd --zone="$UPLINK_ZONE" --add-masquerade
sudo firewall-cmd --permanent --new-policy pwn-forward 2>/dev/null || true
sudo firewall-cmd --permanent --policy=pwn-forward --add-ingress-zone=internal
sudo firewall-cmd --permanent --policy=pwn-forward --add-egress-zone="$UPLINK_ZONE"
sudo firewall-cmd --permanent --policy=pwn-forward --set-target=ACCEPT
sudo firewall-cmd --reload

PC_IP="$(ip -4 addr show "$IFACE" | awk '/inet /{print $2}' | cut -d/ -f1)"
ssh_run "$PI_TARGET" "sudo ip route replace default via $PC_IP dev usb0"
ssh_run "$PI_TARGET" "echo 'nameserver 8.8.8.8' | sudo tee /etc/resolv.conf >/dev/null"

if check_pi_internet "$PI_TARGET"; then
  ok "SSH + internet both confirmed working. Pawny is home and online."
else
  warn "SSH works but internet check failed — verify uplink '$UPLINK'/zone '$UPLINK_ZONE'."
fi

ok "=== pawny-at-home-rocky: done. Log: $LOG_FILE ==="
