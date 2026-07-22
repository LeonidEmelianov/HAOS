# HAOS 0.1.0

First release. HAOS is a macOS menu bar app that runs [Home Assistant OS](https://www.home-assistant.io/) in a virtual machine, bridged onto your local network. No Dock icon, no window to keep open — a house icon in the menu bar, and the VM starts at login.

## Highlights

- **Zero-setup first run.** On first launch the app fetches the latest `haos_generic-aarch64` release from GitHub, unpacks the `.img.xz` in-process, and boots it. Nothing to download or convert by hand.
- **Real presence on your LAN.** The guest is bridged onto your physical network with `vmnet.framework`, in-process — no privileged helper. It gets an address from your router's DHCP and joins multicast, which is what mDNS, SSDP and Matter discovery need to find your devices. The vmnet interface ID is persisted, so the guest keeps the same MAC and DHCP lease across restarts.
- **Menu bar control.** Start, shut down, open the guest console, or jump to the web UI at `homeassistant.local:8123`. The icon is a filled house while running and a dimmed outline otherwise.
- **Clean shutdown.** Quitting sends an ACPI power-button event and waits up to 30 seconds for Home Assistant to power off properly before forcing it.
- **Stays awake.** While the VM runs, the app holds a power assertion so an idle host doesn't freeze the guest and drop your automations.
- **Adjustable resources.** CPU cores and memory are set in Settings, clamped to what the host allows; changes apply on the next start.

## Installing

Requires **macOS 27 or later** on **Apple Silicon**.

```sh
git clone https://github.com/LeonidEmelianov/HAOS.git
cd HAOS
make install
```

This builds a Release configuration, ad-hoc signs it (no Apple Developer account needed), installs it to `/Applications`, and launches it. First launch asks for local network access and a one-time bridged-networking authorization.

See the [README](README.md) for the full build and usage details.

## Known limitations

- **macOS 27 minimum.** Bridged `vmnet` without a privileged helper relies on entitlement behavior introduced in recent macOS; the deployment target is 27 and there is no fallback for older systems.
- **No USB passthrough.** Zigbee, Z-Wave and Matter USB sticks can't be handed to the guest. Use a network-attached coordinator (a Zigbee/Z-Wave-to-Ethernet bridge, or SkyConnect over a USB-to-IP server) instead. Network-based integrations work normally.
- **Bridged networking only.** No NAT/shared-networking fallback; if no interface is available to bridge, the VM won't start.
- **One VM, one image.** No snapshots, multiple instances or UTM import. Home Assistant updates itself from inside the guest, as usual.
- **Apple Silicon only.** The app boots the `aarch64` build of Home Assistant OS.

## Notes

- Guest disk image: `~/Library/HAOS/HAOS.img` (48 GiB virtual, sparse on APFS).
- VM state (machine identity, EFI store, vmnet interface ID): `~/Library/Application Support/HAOS/`.

Home Assistant and Home Assistant OS are projects of the [Open Home Foundation](https://www.openhomefoundation.org/); this app downloads and boots their published images and is not affiliated with them.
