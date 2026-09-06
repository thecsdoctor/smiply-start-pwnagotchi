# Pwnagotchi Installation and Usage Guides 

## For PCs
+ ([Pwnagotchi Jayofelony Image](https://github.com/jayofelony/pwnagotchi/releases)) [ Guide For Pwnagotchi over USB on Rocky Linux (native, no WSL)  SSH + Internet ](https://github.com/thecsdoctor/smiply-start-pwnagotchi/blob/main/pwnagotchi-usb-on-rocky-linux.md#pwnagotchi-over-usb-on-rocky-linux-native-no-wsl--ssh--internet)
+ ([Pwnagotchi Jayofelony Image](https://github.com/jayofelony/pwnagotchi/releases)) [ Guide For Pwnagotchi over USB via WSL2 (Ubuntu 24.04)  SSH + Internet ](https://github.com/thecsdoctor/smiply-start-pwnagotchi/blob/main/pwnagotchi-usb-on-wsl2-ubuntu.md)

## For Phones
+ ([Pwnagotchi Jayofelony Image](https://github.com/jayofelony/pwnagotchi/releases)) [ Guide For Pwnagotchi over iPhone  USB Ethernet + Bluetooth Tethering ](https://github.com/thecsdoctor/smiply-start-pwnagotchi/blob/main/pwnagotchi-usb-on-iphone.md)



## Troubleshooting Errors

What was already handled: each guide tells you to run ip link show fresh each session and re-export the variable, so a renamed interface won't silently break things  you'd just copy the new name.

What wasn't handled: the NetworkManager profiles (nmcli con add ... ifname "$PWN_IF") are pinned to a literal interface name. If that name changes between reboots/replugs  which happens because:

* enx<mac>-style names are derived from the MAC address, and pwnagotchi's USB gadget often generates a random MAC on every boot unless pinned
* iPhone's ipheth/predictable-naming interfaces are derived from USB bus topology, so a different physical port gives a different name

...then the old profile just sits there unused and matches nothing. That's a real gap against "idempotent and repeatable."

Two fixes, one for each side:

### Fix 1  pin the Pi's gadget MAC (fixes the Ubuntu/Rocky-side name)

If pwnagotchi's gadget is set via dtoverlay=dwc2,g_ether in /boot/firmware/config.txt, add fixed MACs:

dtoverlay=dwc2,g_ether,host_addr=aa:bb:cc:dd:ee:01,dev_addr=aa:bb:cc:dd:ee:02

Reboot once. enx<mac> will now be identical every time, on every host, forever  the nmcli/dhclient profiles bound to that name stay valid.

### Fix 2  auto-detect instead of hardcoding (fixes both sides, no MAC pinning required)

Replace the manual "look at ip link show and copy the name" step with a one-liner that finds the current USB network interface by bus location, not name:

```bash
    PWN_IF=$(for i in /sys/class/net/*; do
    n=$(basename "$i")
    readlink -f "$i/device" | grep -q "usb" && [ "$n" != "lo" ] && echo "$n"
    done | tail -n1)
    echo "$PWN_IF"
```

This finds whatever USB-attached NIC currently exists, regardless of what udev decided to call it, and works identically for the pwnagotchi-side and the iPhone ipheth side.

Additionaly you can replace the manual "note the interface name" steps so they're actually reboot/replug-proof, not just reboot/replug-aware!

### Fix 3 can the Image with same boot options be used by pwnagotchi for iphones and linux over usb connections ?

The USB controller (dwc2) can only be in one role at a time on a given port: peripheral (gadget, for Linux-over-USB/SSH) or host (for iPhone's ipheth tethering). There's no dynamic auto-detect-and-switch based on what's plugged in the role is set by config, not sensed from the cable.

### Per-board reality
Pi 3B+ / 4 / 5 (separate USB-A host ports + one OTG-capable port): use the OTG port for gadget mode (Linux-over-USB, permanently), and a regular USB-A port for the iPhone. Both work simultaneously, same image, same boot, no switching needed  this is what I already set up in the earlier guide's "Section 0."
Pi Zero / Zero 2 W (single data port): genuinely one role at a time. Same image supports both use cases, but switching means changing which role that one port boots into.
Making the switch less painful (Zero/Zero 2 W)

Instead of editing config.txt/cmdline.txt and rebooting every time, Raspberry Pi OS supports live overlay loading via the dtoverlay command  no reboot required:

```bash
    # Switch to host mode (for iPhone ipheth)
    sudo modprobe -r g_ether
    sudo dtoverlay -r dwc2
    sudo dtoverlay dwc2 dr_mode=host

    # Switch back to gadget mode (for Linux-over-USB)
    sudo dtoverlay -r dwc2
    sudo dtoverlay dwc2 dr_mode=peripheral
    sudo modprobe g_ether
```

This is board/kernel-version dependent and can be flaky (some kernels only fully apply dr_mode changes at boot), so it's worth testing rather than trusting blindly.

TODO: Create usb-mode-iphone.sh / usb-mode-linux.sh, so one can drop on the Pi and just run before switching cables, with a fallback that reboots automatically if the live switch doesn't take!
