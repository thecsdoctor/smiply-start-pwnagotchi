#!/usr/bin/env bash
# pwny-lib.sh — shared functions for the pwnagotchi walk/home scripts.
# This file is meant to be SOURCED, not executed directly.

set -uo pipefail

PWNY_HOME="${PWNY_HOME:-$HOME/.pwnagotchi-scripts}"
PWNY_LOG_DIR="$PWNY_HOME/logs"
PWNY_STATE_FILE="$PWNY_HOME/state.env"
mkdir -p "$PWNY_LOG_DIR"

# --- logging -----------------------------------------------------------
_script_name="$(basename "${0:-pwny}")"
LOG_FILE="$PWNY_LOG_DIR/${_script_name%.sh}-$(date +%Y%m%d-%H%M%S).log"

log() {
  local level="$1"; shift
  local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '[%s] [%-5s] %s\n' "$ts" "$level" "$*" | tee -a "$LOG_FILE"
}
info()  { log INFO  "$@"; }
warn()  { log WARN  "$@"; }
error() { log ERROR "$@"; }
ok()    { log OK    "$@"; }
die()   { error "$*"; exit 1; }

# --- interactive input ---------------------------------------------------
ask() {
  # ask "prompt" "default"
  local prompt="$1" default="${2:-}" reply
  if [ -n "$default" ]; then
    read -r -p "$prompt [$default]: " reply
    echo "${reply:-$default}"
  else
    read -r -p "$prompt: " reply
    echo "$reply"
  fi
}

confirm() {
  local prompt="$1" reply
  read -r -p "$prompt [y/N]: " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# --- state persistence (survives between runs, on this PC) ---------------
state_get() {
  local key="$1"
  [ -f "$PWNY_STATE_FILE" ] && grep -E "^${key}=" "$PWNY_STATE_FILE" 2>/dev/null | tail -n1 | cut -d= -f2-
}
state_set() {
  local key="$1" val="$2"
  touch "$PWNY_STATE_FILE"
  if grep -qE "^${key}=" "$PWNY_STATE_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$PWNY_STATE_FILE"
  else
    echo "${key}=${val}" >> "$PWNY_STATE_FILE"
  fi
}

# --- SSH helpers -----------------------------------------------------------
ssh_run() {
  local target="$1"; shift
  ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$target" "$@"
}

check_ssh() {
  local target="$1"
  info "Checking SSH to $target ..."
  if ssh_run "$target" "echo pwny-ssh-ok" >/dev/null 2>&1; then
    ok "SSH to $target works."; return 0
  else
    warn "SSH to $target failed."; return 1
  fi
}

check_pi_internet() {
  local target="$1"
  info "Checking internet on $target ..."
  if ssh_run "$target" "ping -c1 -W3 1.1.1.1" >/dev/null 2>&1; then
    ok "Pi has internet."; return 0
  else
    warn "Pi does NOT currently have internet."; return 1
  fi
}

# --- USB interface auto-detection (name-independent) ------------------------
detect_usb_iface() {
  local best=""
  for i in /sys/class/net/*; do
    local n; n="$(basename "$i")"
    [ "$n" = "lo" ] && continue
    if readlink -f "$i/device" 2>/dev/null | grep -q "usb"; then
      best="$n"
    fi
  done
  echo "$best"
}

get_iface_mac() {
  cat "/sys/class/net/$1/address" 2>/dev/null
}

wait_for_usb_iface() {
  local timeout="${1:-15}" waited=0 iface=""
  info "Waiting up to ${timeout}s for a USB network interface to appear..."
  while [ "$waited" -lt "$timeout" ]; do
    iface="$(detect_usb_iface)"
    [ -n "$iface" ] && { echo "$iface"; return 0; }
    sleep 1
    waited=$((waited+1))
  done
  echo ""
  return 1
}

# --- SD-card boot-partition recovery (no display/keyboard needed) -----------
# When the Pi's microSD card is pulled and read on this PC, the card's boot
# partition is exactly what appears as /boot/firmware/ on the running Pi —
# so config.txt, cmdline.txt, and any .bak files made by go-for-a-walk are
# sitting right at the root of that partition once it's mounted here.

find_boot_partition() {
  local base hit
  for base in "/media/$USER" /media/* /run/media/"$USER" /run/media/* /mnt; do
    [ -d "$base" ] || continue
    hit="$(find "$base" -maxdepth 2 -iname 'config.txt' 2>/dev/null | head -n1)"
    if [ -n "$hit" ]; then
      dirname "$hit"
      return 0
    fi
  done
  return 1
}

restore_gadget_mode_on_sdcard() {
  # restore_gadget_mode_on_sdcard <path-to-mounted-boot-partition>
  local bootdir="$1"
  local cfg="$bootdir/config.txt"
  local cmd="$bootdir/cmdline.txt"

  if [ ! -f "$cfg" ] || [ ! -f "$cmd" ]; then
    warn "$bootdir doesn't look like the boot partition (missing config.txt/cmdline.txt)."
    return 1
  fi

  info "Found boot partition at: $bootdir"

  if [ -f "$cfg.bak" ] && [ -f "$cmd.bak" ] && confirm "Backups found (config.txt.bak / cmdline.txt.bak). Restore them?"; then
    cp -f "$cfg.bak" "$cfg"
    cp -f "$cmd.bak" "$cmd"
    ok "Restored config.txt and cmdline.txt from backups."
    return 0
  fi

  info "Patching lines directly."
  if grep -q '^#dtoverlay=dwc2' "$cfg"; then
    sed -i 's/^#dtoverlay=dwc2/dtoverlay=dwc2/' "$cfg"
    ok "config.txt: changed '#dtoverlay=dwc2' -> 'dtoverlay=dwc2'."
  elif grep -q '^dtoverlay=dwc2' "$cfg"; then
    ok "config.txt already has 'dtoverlay=dwc2' enabled."
  else
    echo "dtoverlay=dwc2" >> "$cfg"
    ok "config.txt: appended 'dtoverlay=dwc2' (no existing line to uncomment)."
  fi

  if grep -q 'modules-load=dwc2,g_ether' "$cmd"; then
    ok "cmdline.txt already contains 'modules-load=dwc2,g_ether'."
  else
    sed -i 's/$/ modules-load=dwc2,g_ether/' "$cmd"
    ok "cmdline.txt: appended ' modules-load=dwc2,g_ether' to the end of the line."
  fi
  return 0
}
