# HAOS

A menu bar app that runs [Home Assistant OS](https://www.home-assistant.io/installation/macos/) in a virtual machine on your Mac, bridged onto your local network.

No Dock icon, no window to keep open — a house icon in the menu bar tells you whether Home Assistant is up, and the VM starts automatically at login.

## Features

- **One-click start.** The VM boots when the app launches; a menu item starts and stops it by hand.
- **Automatic first-run setup.** On first launch the app fetches the latest `haos_generic-aarch64` release from GitHub, unpacks it, and boots it. Nothing to download or convert yourself.
- **Real LAN presence.** The guest is bridged onto your physical network via `vmnet.framework`, so it gets an address from your router's DHCP and participates in multicast — which is what mDNS, SSDP and Matter discovery need to find your devices.
- **Stable address.** The vmnet interface ID is persisted, so the guest keeps the same MAC and therefore the same DHCP lease across restarts.
- **Console access.** "Show Console" opens the guest's framebuffer when you need to look at the boot log or use the HA CLI.
- **Clean shutdown.** Quitting sends an ACPI power-button event and waits up to 30 seconds for Home Assistant to shut down properly before forcing it.
- **Stays awake.** While the VM runs, the app holds a power assertion so an idle host doesn't freeze the guest and drop your automations.

## Requirements

- **macOS 27 or later.** This is a hard floor, not a recommendation — see [Limitations](#limitations).
- **Apple Silicon.** The app boots the `aarch64` build of Home Assistant OS.
- A **network interface that supports bridging** — Wi-Fi or Ethernet. Wired adapters are preferred automatically when both are available.

## Installing

```sh
git clone https://github.com/LeonidEmelianov/HAOS.git
cd HAOS
make install
```

That builds a Release configuration, ad-hoc signs it, installs it to `/Applications`, and launches it. No Apple Developer account is required: `com.apple.security.virtualization` is honored under an ad-hoc signature. Signing can't be skipped entirely, though — an unsigned bundle carries no entitlements and the VM won't start.

If a copy is already running, the script asks it to quit and waits for the guest to shut down cleanly before replacing it.

| Target | |
| --- | --- |
| `make install` | Build, install to `/Applications`, relaunch |
| `make build` | Build and verify only, no install |
| `make uninstall` | Remove the app (leaves your VM data alone) |
| `make clean` | Delete build products |

The script accepts `--no-launch` and `--build-only`, and honors `DEST_DIR` and `DEVELOPER_DIR`.

Autostart registers itself only when the app runs from `/Applications`, so a debug build in DerivedData won't quietly add itself to your login items. Turn it off under **System Settings → General → Login Items**.

The first launch triggers two system prompts: one to allow local network access, and a one-time authorization for bridged networking.

## Building in Xcode

```sh
open HAOS.xcodeproj
```

Set your development team in the target's Signing & Capabilities tab, then build and run.

Build products go to `~/Library/Caches/HAOS`, deliberately outside the repo — this project is developed in a directory synced by iCloud Drive, where the file provider stamps extended attributes that make `codesign` fail with *"resource fork, Finder information, or similar detritus not allowed"*, and where build intermediates would otherwise be uploaded.

There is **no GitHub Actions workflow**, and can't be one yet: HAOS targets macOS 27, the newest GitHub-hosted runner is `macos-26`, and its Xcode versions ship SDKs no newer than macOS 26.5. You cannot build against an SDK older than the deployment target. Once a macos-27 image exists, a build workflow becomes a few lines.

## Usage

Click the menu bar icon:

| Item | What it does |
| --- | --- |
| *(status line)* | Current state — download progress, Starting…, Running, Stopping… |
| Start Home Assistant | Boots the VM (hidden while something is already in flight) |
| Shut Down | Graceful ACPI shutdown |
| Show Console | Opens the guest's display in a window |
| Open Web UI | Opens <http://homeassistant.local:8123> |
| Settings… | CPU cores and memory |
| Quit | Shuts the guest down, then exits |

The icon is a filled house while the VM is running and a dimmed outline otherwise.

## Settings

CPU count and memory are adjustable and take effect the next time the VM starts. Defaults are **2 cores** and **4 GiB**; the floor is 2 GiB, below which the guest runs out of memory during onboarding. Both values are clamped to what `Virtualization.framework` reports the host allows, so a setting carried over from a bigger machine can't produce an invalid configuration.

## Data layout

| Path | Contents |
| --- | --- |
| `~/Library/HAOS/HAOS.img` | The guest disk image |
| `~/Library/Application Support/HAOS/NVRAM` | EFI variable store |
| `~/Library/Application Support/HAOS/MachineIdentifier` | VM machine identifier |
| `~/Library/Application Support/HAOS/BridgedInterfaceID` | vmnet interface UUID (keeps the MAC stable) |

The disk image is created at a 64 GiB virtual size — Home Assistant expands its data partition to fill the disk on boot, and the Supervisor's containers don't fit in the ~6 GiB the stock image ships with. The file stays sparse on APFS, so it only occupies what the guest has actually written.

To start over, quit the app and delete both directories.

## Limitations

**macOS 27 or later is required.** Bridged `vmnet` used to need root or the Apple-gated `com.apple.vm.networking` entitlement. macOS 26 lifted that for apps holding the ordinary virtualization entitlement, which is what lets this app bridge in-process instead of shipping a privileged helper. The deployment target is set to 27 to stay on supported ground; there is no fallback path for older systems.

**USB devices are not supported.** You cannot pass a Zigbee, Z-Wave or Matter USB stick through to the guest. `VZUSBDeviceConfiguration` requires a paid Apple Developer account to sign against, and it isn't wired up here regardless. Integrations that reach your devices over the network work fine — the bridged setup is specifically built for that — but anything needing a physical dongle will not. Use a network-attached coordinator (a Zigbee/Z-Wave-to-Ethernet bridge, or SkyConnect over a USB-to-IP server) instead.

**Bridged mode only.** There is no NAT/shared-networking fallback. If no physical interface is available for bridging, the VM won't start.

**One VM, one image.** No snapshots, no multiple instances, no UTM import, and the image is never updated in place — Home Assistant updates itself from inside the guest, as usual.

**Apple Silicon only.** Intel Macs are not supported.

## Prior art

[IngmarStein/havm](https://github.com/IngmarStein/havm) is a more featureful CLI-driven take on the same idea, with USB passthrough, NAT networking, UTM import and a Homebrew formula. HAOS is deliberately smaller: a menu bar app with one job and no configuration file.

## License

MIT — see [LICENSE](LICENSE).

Home Assistant and Home Assistant OS are projects of the [Open Home Foundation](https://www.openhomefoundation.org/); this app only downloads and boots their published images and is not affiliated with them.
