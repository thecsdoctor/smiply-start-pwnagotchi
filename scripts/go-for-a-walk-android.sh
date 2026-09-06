#!/usr/bin/env bash
# go-for-a-walk-android.sh
#
# Run on the PC while the pwnagotchi is STILL connected via USB.
# Precondition: SSH to the Pi works AND the Pi currently has internet.
# Prepares the Pi to be tethered to an Android phone (Bluetooth PAN, or
# USB-host mode on single-port boards) once you disconnect and head out.
#
# Note on Android USB tethering: when you flip "USB tethering" ON in
# Android, the PHONE presents an RNDIS/NCM network adapter to whatever
# it's plugged into — same as iPhone's cable-hotspot behavior. That means
# the Pi still needs to be the USB HOST to consume it (same dwc2 dr_mode
# constraint as the iPhone case).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/pwny-lib.sh"

info "=== go-for-a-walk-android: starting ==="

PI_TARGET="$(state_get PI_SSH_TARGET)"
PI_TARGET="$(ask "SSH target for pwnagotchi (user@host)" "${PI_TARGET:-pi@10.12.194.1}")"
state_set PI_SSH_TARGET "$PI_TARGET"

check_ssh "$PI_TARGET" || die "Precondition failed: cannot SSH to $PI_TARGET. Aborting."
check_pi_internet "$PI_TARGET" || die "Precondition failed: Pi has no internet yet. Run the pawny-at-home script first, then retry."

echo
echo "How do you want to tether to the Android phone on your walk?"
echo "  1) Bluetooth PAN  (Settings > Connected devices > Bluetooth tethering)"
echo "  2) USB host mode  (Settings > Network & internet > Hotspot & tethering >"
echo "     USB tethering; only needed on single-port boards, disables"
echo "     gadget mode / USB-SSH until you run came-from-a-walk)"
MODE="$(ask "Choose 1 or 2" "1")"

case "$MODE" in
  1)
    info "Selected: Bluetooth PAN"
    ssh_run "$PI_TARGET" "sudo rfkill unblock bluetooth; sudo systemctl enable --now bluetooth" \
      && ok "Bluetooth service enabled on Pi." \
      || die "Could not enable Bluetooth on Pi."

    ANDROID_MAC="$(state_get ANDROID_BT_MAC)"
    if [ -z "$ANDROID_MAC" ] || ! confirm "Reuse saved Android Bluetooth MAC ($ANDROID_MAC)?"; then
      info "Scanning for 10s — make sure the Android phone's Bluetooth settings screen is open..."
      ssh_run "$PI_TARGET" "timeout 10 bluetoothctl scan on" 2>/dev/null | tee -a "$LOG_FILE" || true
      ANDROID_MAC="$(ask "Enter the Android phone's Bluetooth MAC address (XX:XX:XX:XX:XX:XX)")"
      state_set ANDROID_BT_MAC "$ANDROID_MAC"
    fi

    info "Pairing/trusting $ANDROID_MAC (idempotent)..."
    if ssh_run "$PI_TARGET" "bluetoothctl info '$ANDROID_MAC'" >/dev/null 2>&1; then
      ok "Already known to bluetoothctl — skipping pair."
    else
      ssh_run "$PI_TARGET" "bluetoothctl <<EOF
agent on
default-agent
pair $ANDROID_MAC
trust $ANDROID_MAC
EOF" | tee -a "$LOG_FILE"
    fi

    info "Ensuring NetworkManager PAN profile exists (idempotent)..."
    if ssh_run "$PI_TARGET" "nmcli -t -f NAME con show | grep -qx android-bt"; then
      ok "Profile android-bt already exists."
    else
      ssh_run "$PI_TARGET" "sudo nmcli con add type bluetooth ifname '*' con-name android-bt bluetooth.type panu bluetooth.bdaddr '$ANDROID_MAC'" \
        && ok "Created android-bt profile." || die "Failed to create Bluetooth profile."
    fi

    state_set LAST_WALK_STRATEGY "bluetooth"
    ok "Ready. On your walk: enable Bluetooth tethering on Android, then on the Pi: sudo nmcli con up android-bt"
    ;;
  2)
    info "Selected: USB host mode"
    confirm "This disables USB-SSH until you run came-from-a-walk. Continue?" || die "Aborted by user."

    ssh_run "$PI_TARGET" "
      sudo cp -n /boot/firmware/config.txt /boot/firmware/config.txt.bak
      sudo cp -n /boot/firmware/cmdline.txt /boot/firmware/cmdline.txt.bak
      sudo sed -i 's/^dtoverlay=dwc2/#dtoverlay=dwc2/' /boot/firmware/config.txt
      sudo sed -i 's/modules-load=dwc2,g_ether//' /boot/firmware/cmdline.txt
    " && ok "Gadget mode disabled in boot config (backups preserved if they already existed)." \
      || die "Failed to edit boot config over SSH."

    state_set LAST_WALK_STRATEGY "usb-host"
    if confirm "Reboot the Pi now to apply?"; then
      ssh_run "$PI_TARGET" "sudo reboot" || true
      warn "Pi is rebooting — USB-SSH will drop until you run came-from-a-walk."
    else
      warn "Remember: the Pi won't act as a USB host for the Android phone until it's rebooted."
    fi
    ;;
  *)
    die "Invalid choice."
    ;;
esac

ok "=== go-for-a-walk-android: done. Log: $LOG_FILE ==="
