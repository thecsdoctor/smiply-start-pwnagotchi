# Pwnagotchi over USB on Rocky Linux (native, no WSL) — SSH + Internet

For a pwnagotchi (`rpi-usb-gadget`, SHARED mode) plugged directly into a Rocky Linux
machine's USB-C port. No `usbipd` needed — Rocky sees the USB gadget natively.

Rocky uses **NetworkManager** (not plain `dhclient`) and **firewalld** (not raw
`iptables`) by default, so the steps differ from the WSL/Ubuntu version even though
the goal is the same.

All steps are safe to re-run.

---

## Step 1 — Plug in the Pi and find the interface

```bash
ip link show
```

Look for a new interface named like `enx<mac>` (e.g. `enx9a3b6b6f9f03`) that
appeared after plugging in the USB-C cable.

```bash
export PWN_IF=enx9a3b6b6f9f03   # <-- replace with your actual interface name
```

---

## Step 2 — Create (or reuse) a NetworkManager DHCP-client profile for the link

The Pi's `rpi-usb-gadget` acts as the DHCP server (`10.12.194.1/28`), so this host
must be a **DHCP client**, not another server.

Check if a profile already exists for this interface:

```bash
nmcli -t -f NAME,DEVICE con show | grep ":$PWN_IF"
```

If nothing is returned, create one:

```bash
sudo nmcli con add type ethernet ifname "$PWN_IF" con-name pwn-usb \
  ipv4.method auto ipv6.method disabled
```

(Running `add` twice creates a duplicate profile — the `grep` check above prevents
that. If you already ran this once, skip straight to Step 3.)

Bring it up (idempotent — no-ops if already active):

```bash
sudo nmcli con up pwn-usb
```

---

## Step 3 — Verify the lease

```bash
ip addr show "$PWN_IF"
```

You should see an address in `10.12.194.2–14/28`, e.g. `10.12.194.4/28`.

> If no lease appears, unplug/replug the cable or reboot the Pi so
> `rpi-usb-gadget` re-enters SHARED mode, then repeat from Step 2.

---

## Step 4 — SSH into the Pi

```bash
ssh pi@10.12.194.1
```

SSH works at this point even without internet on the Pi — skip to Step 7 if that's
all you need.

---

## Step 5 — Identify your uplink interface and zone

```bash
nmcli -t -f DEVICE,TYPE,STATE con show --active
sudo firewall-cmd --get-active-zones
```

Note which interface has real internet (e.g. `eth0`/`enp1s0`) and which firewalld
zone it's in (commonly `public`). Set:

```bash
export UPLINK_IF=eth0    # <-- replace with your actual uplink interface
export UPLINK_ZONE=public
```

---

## Step 6 — Enable forwarding and NAT via firewalld

```bash
sudo sysctl -w net.ipv4.ip_forward=1
```

Put the USB link into its own zone (idempotent — re-running just re-applies the
same assignment):

```bash
sudo firewall-cmd --zone=internal --change-interface="$PWN_IF"
```

Enable masquerade on the uplink zone (check first so it's not toggled off by a
second run):

```bash
sudo firewall-cmd --zone="$UPLINK_ZONE" --query-masquerade || \
  sudo firewall-cmd --zone="$UPLINK_ZONE" --add-masquerade
```

Allow forwarding from the internal (USB) zone to the uplink zone using a firewalld
policy (requires firewalld ≥ 0.9; Rocky 8.3+/9 have this):

```bash
sudo firewall-cmd --permanent --new-policy pwn-forward 2>/dev/null || true
sudo firewall-cmd --permanent --policy=pwn-forward --add-ingress-zone=internal
sudo firewall-cmd --permanent --policy=pwn-forward --add-egress-zone="$UPLINK_ZONE"
sudo firewall-cmd --permanent --policy=pwn-forward --set-target=ACCEPT
sudo firewall-cmd --reload
```

All four `--permanent --policy=pwn-forward` lines are safe to re-run — firewalld
ignores duplicate ingress/egress/target entries.

---

## Step 7 — Point the Pi's default route at this host, and fix DNS

Run these on the **Pi** (over the SSH session from Step 4). SHARED mode never
requests a default route on its own, so it's added manually each session.

Get this host's current address on the link (from Step 3) — e.g. `10.12.194.4` —
then on the Pi:

```bash
sudo ip route replace default via 10.12.194.4 dev usb0
```

`replace` (not `add`) makes this safe to re-run even if a route already exists.

Set DNS:

```bash
echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf
```

Test:

```bash
ping -c 3 google.com
```

---

## Step 8 — Done

- SSH: `ssh pi@10.12.194.1`
- Internet on Pi: routed via this host's uplink through firewalld masquerade.

`ip_forward` and the Pi's default route reset on reboot; the NetworkManager
profile (`pwn-usb`) and firewalld zone/policy assignments persist across reboots
on the host side. Re-run Steps 1, 3, 6 (sysctl only), and 7 each session.
