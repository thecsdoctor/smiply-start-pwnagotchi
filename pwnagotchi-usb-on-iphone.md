# Pwnagotchi (Jayofelony image) ↔ iPhone — USB Ethernet + Bluetooth Tethering

Jayofelony's pwnagotchi image is based on Raspberry Pi OS Bookworm, which uses
**NetworkManager** (not `dhcpcd`), so all steps below use `nmcli`.

---

## 0. Read this first — the port conflict

Pwnagotchi normally configures its USB-C/micro-USB port as a **USB gadget**
(`dwc2` + `g_ether`), so the Pi presents itself as a network *device* to a host
computer for SSH (that's the `10.0.0.2` / `10.12.194.1` behavior from earlier).

iPhone's Personal Hotspot-over-cable works the opposite way: **the iPhone is the
peripheral**, and the connected device must act as a USB **host** running Apple's
`ipheth` driver to get an IP from it. A port in gadget mode cannot also act as a
host — that's why you saw `169.254.x.x` (APIPA) earlier: the Pi was still in
peripheral mode, so the iPhone had nothing to talk to.

- **Pi Zero / Zero 2 W** (single USB-C/micro-USB data port): you must temporarily
  disable gadget mode on that port to use it as a host for the iPhone. You lose
  USB-SSH access while tethered this way — use Bluetooth (Section 4) if you want
  both at once.
- **Pi 3B+/4/5** (separate USB-A host ports plus one OTG-capable port): leave
  gadget mode as-is on the OTG port, and plug the iPhone into a regular **USB-A**
  port instead (with a USB-A→Lightning or USB-A→USB-C cable). No config change
  needed for this case — skip to Section 2.

---

## 1. Pi-side config changes (only needed if disabling gadget mode — Zero/Zero 2 W)

Back up first:

```bash
sudo cp /boot/firmware/config.txt /boot/firmware/config.txt.bak
sudo cp /boot/firmware/cmdline.txt /boot/firmware/cmdline.txt.bak
```

Comment out the gadget overlay in `/boot/firmware/config.txt`:

```bash
sudo sed -i 's/^dtoverlay=dwc2/#dtoverlay=dwc2/' /boot/firmware/config.txt
```

Remove `g_ether` (or `dwc2`) from `/boot/firmware/cmdline.txt` — open it and delete
`modules-load=dwc2,g_ether` if present:

```bash
sudo sed -i 's/modules-load=dwc2,g_ether//' /boot/firmware/cmdline.txt
```

Reboot for this to take effect:

```bash
sudo reboot
```

> To revert later: restore the two `.bak` files and reboot again.

---

## 2. iPhone-side settings (before connecting)

- **Settings → Personal Hotspot → ON**
- **Settings → Personal Hotspot → Maximize Compatibility → ON** (helps older
  Linux `ipheth` drivers negotiate correctly)
- Keep the Settings app open on the "Personal Hotspot" screen while you plug in —
  iOS is more reliable at recognizing the accessory this way.

---

## 3. Connect via USB and verify (ipheth)

Plug the cable in (Pi host port ↔ iPhone). The `ipheth` kernel module ships with
Raspberry Pi OS and should auto-load.

Check the kernel saw it:

```bash
dmesg | tail -20
```

You're looking for lines mentioning `ipheth` and a new network interface.

List interfaces and let NetworkManager pick it up:

```bash
nmcli device status
```

You should see a new Ethernet-type device (often `eth1` or `usb0` depending on
what else is attached). If it's `unmanaged`, tell NetworkManager to manage it:

```bash
sudo nmcli device set <iface> managed yes
```

Bring it up with DHCP (idempotent if a profile already exists):

```bash
nmcli -t -f NAME,DEVICE con show | grep ":<iface>" || \
  sudo nmcli con add type ethernet ifname <iface> con-name iphone-usb ipv4.method auto ipv6.method disabled

sudo nmcli con up iphone-usb
```

Verify the lease:

```bash
ip addr show <iface>
```

Expect an address in the `172.20.10.2–14/28` range with gateway `172.20.10.1`.

Test:

```bash
ping -c 3 172.20.10.1
ping -c 3 google.com
```

---

## 4. Bluetooth PAN tethering (works alongside gadget-mode USB-SSH — no port conflict)

This is the better option if you want to **keep** USB-SSH access to the Pi while
also getting internet from the iPhone.

### On the iPhone
- **Settings → Personal Hotspot → ON**
- **Settings → Bluetooth → ON**, keep the Bluetooth settings screen open.

### On the Pi

Make sure Bluetooth is running:

```bash
sudo systemctl status bluetooth
sudo rfkill unblock bluetooth
```

Pair with the iPhone:

```bash
bluetoothctl
```

Inside the `bluetoothctl` prompt:

```
agent on
default-agent
scan on
```

Wait for your iPhone's name to appear, then (replace with the actual MAC):

```
pair XX:XX:XX:XX:XX:XX
trust XX:XX:XX:XX:XX:XX
connect XX:XX:XX:XX:XX:XX
```

Accept the pairing prompt that appears on the iPhone screen. Exit with `quit`.

### Bring up the PAN connection

If NetworkManager has Bluetooth support (default on Bookworm):

```bash
sudo nmcli con add type bluetooth ifname '*' con-name iphone-bt \
  bluetooth.type panu bluetooth.bdaddr XX:XX:XX:XX:XX:XX
sudo nmcli con up iphone-bt
```

Verify:

```bash
nmcli device status
ip addr show bnep0
```

Expect an address in the `172.20.10.x/28` range again, gateway `172.20.10.1`.

Test:

```bash
ping -c 3 google.com
```

> If `nmcli con up iphone-bt` fails with "not available" errors, the
> `bluez`/`network` plugin combination may need `sudo dnf install bluez-tools` or
> (Raspberry Pi OS) `sudo apt install bluez-tools`, then retry.

---

## 5. Notes on pwnagotchi itself

None of this requires changing `/etc/pwnagotchi/config.toml`. Pwnagotchi's core
capture/deauth loop runs on `wlan0`/`wlan0mon` regardless of what's happening on
the USB/Bluetooth interfaces — this tethering is purely for giving the Pi outbound
internet (e.g. for `pwnagotchi --check-update`, `wpa-sec` uploads, or
`gdrivesync`), or for restoring SSH if you went the "disable gadget mode" USB
route in Section 1.

---

## 6. Reverting / cleanup

- **USB (ipheth) route (Zero/Zero 2 W only):** restore `config.txt.bak` and
  `cmdline.txt.bak` from Section 1, then reboot to get gadget mode (and USB-SSH)
  back.
- **Bluetooth route:** no Pi boot config was touched — just
  `sudo nmcli con down iphone-bt` when done, or `sudo nmcli con delete iphone-bt`
  to remove the profile entirely.
