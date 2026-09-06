# Pwnagotchi over USB via WSL2 (Ubuntu 24.04) — SSH + Internet

Connects a pwnagotchi (running `rpi-usb-gadget` in SHARED mode) to a Windows 11 host,
passes the USB interface into WSL2, and gives the Pi both SSH access and internet
(routed out through WSL's own uplink).

Run this every time after a fresh WSL restart or USB replug — all steps are safe to
re-run (idempotent).

---

## Prerequisites (one-time only)

- `usbipd-win` installed on Windows 11.
- Raspberry Pi with `rpi-usb-gadget` enabled, connected via USB-C.

---

## Step 1 — Bind and attach the USB device (Windows, PowerShell as Administrator)

```powershell
usbipd list
```

Find the pwnagotchi's USB Ethernet/gadget device in the list and note its `BUSID`.

```powershell
usbipd bind --busid <BUSID>
usbipd attach --wsl --busid <BUSID>
```

- `bind` is a one-time action per device; running it again on an already-bound
  device is harmless (it will just report it's already shared).
- `attach` must be re-run every time WSL is restarted or the Pi is replugged.

---

## Step 2 — Confirm the interface appears in WSL

```bash
ip link show
```

Look for an interface named like `enx<mac>` (e.g. `enx9a3b6b6f9f03`). Note its exact
name — it can change if you use a different USB port or cable.

```bash
export PWN_IF=enx9a3b6b6f9f03   # <-- replace with your actual interface name
```

---

## Step 3 — Bring the interface up (idempotent)

```bash
sudo ip link set "$PWN_IF" up
```

Do **not** assign a static IP manually — the Pi's `rpi-usb-gadget` service runs in
SHARED mode and acts as the DHCP server on this link (`10.12.194.1/28`). WSL must be
a **DHCP client**, not another server.

If a stale static IP was set on a previous attempt, clear it first:

```bash
sudo ip addr flush dev "$PWN_IF"
```

---

## Step 4 — Get an IP from the Pi via DHCP

Install the DHCP client once (safe to re-run — apt skips if already installed):

```bash
sudo apt-get update
sudo apt-get install -y isc-dhcp-client
```

Request a lease:

```bash
sudo dhclient "$PWN_IF"
```

Verify:

```bash
ip addr show "$PWN_IF"
```

You should see an address in `10.12.194.2–14/28`, e.g. `10.12.194.4/28`.

> If this hangs with no lease, the Pi hasn't come up in SHARED mode yet — unplug/
> replug the cable or reboot the Pi, then repeat from Step 2.

---

## Step 5 — SSH into the Pi

```bash
ssh pi@10.12.194.1
```

(Default pwnagotchi credentials unless changed: user `pi`.)

SSH works at this point even without internet on the Pi — skip to Step 8 if that's
all you need.

---

## Step 6 — Share WSL's internet with the Pi (NAT)

Run these on the **WSL** side. All are idempotent thanks to the `-C` (check) guard
before each `-A` (append) on the iptables rules, and `sysctl` simply re-applies the
same value.

```bash
sudo sysctl -w net.ipv4.ip_forward=1

sudo iptables -t nat -C POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null || \
  sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

sudo iptables -C FORWARD -i eth0 -o "$PWN_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
  sudo iptables -A FORWARD -i eth0 -o "$PWN_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT

sudo iptables -C FORWARD -i "$PWN_IF" -o eth0 -j ACCEPT 2>/dev/null || \
  sudo iptables -A FORWARD -i "$PWN_IF" -o eth0 -j ACCEPT
```

(`iptables` itself must be installed — `sudo apt-get install -y iptables` if the
commands above report "command not found".)

---

## Step 7 — Point the Pi's default route at WSL, and fix DNS

Run these on the **Pi** (over the SSH session from Step 5). The Pi's SHARED-mode
profile never requests a default route on its own, so it must be added manually
every boot.

First, get WSL's current address on the link (from Step 4's output) — e.g.
`10.12.194.4` — then on the Pi:

```bash
sudo ip route replace default via 10.12.194.4 dev usb0
```

Using `replace` instead of `add` makes this safe to re-run even if a default route
already exists.

Set DNS:

```bash
echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf
```

Test:

```bash
ping -c 3 google.com
```

> The `10.12.194.x` address WSL holds can change between leases/reboots — always
> re-check it with `ip addr show "$PWN_IF"` in WSL before setting the Pi's route.

---

## Step 8 — Done

- SSH: `ssh pi@10.12.194.1`
- Internet on Pi: routed via WSL's `eth0` through NAT.

Neither the WSL-side iptables rules nor the Pi-side default route persist across
reboots — re-run Steps 1, 3–4, 6–7 (in that order) each session. Steps are all
written to be safe to run repeatedly without side effects.
