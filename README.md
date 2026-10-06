<div align="center">

<img src="assets/logo.png" width="128" alt="Brickell Bridge logo" />

# Brickell Bridge

**Know if the Brickell Avenue Bridge is up before you get there.**

A tiny macOS menu bar app that shows the live status of Miami's Brickell Avenue drawbridge, with the live traffic cam one click away.

[![Build](https://github.com/antondkg/brickell-bridge/actions/workflows/build.yml/badge.svg)](https://github.com/antondkg/brickell-bridge/actions/workflows/build.yml)
[![Release](https://img.shields.io/github/v/release/antondkg/brickell-bridge?color=2563eb)](https://github.com/antondkg/brickell-bridge/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)](#install)
[![Swift](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](main.swift)
[![Dependencies](https://img.shields.io/badge/dependencies-none-22c55e)](#how-it-works)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/screenshot-dark.png">
  <img src="assets/screenshot-light.png" width="480" alt="Brickell Bridge popover showing bridge status and the live camera">
</picture>

</div>

## Why

If you live or work around Brickell, you know the bridge goes up at the worst possible time. FL511 sends email alerts, but they're easy to miss and they don't tell you how long it's been up. This puts the answer in your menu bar.

## Features

- **Live status in the menu bar.** Checks FL511 every 15 seconds.
- **Animated icon.** The bridge leaves raise and lower when the status changes, and the icon turns red while the bridge is up.
- **Live camera.** Click the icon to watch the Brickell Bridge CCTV stream right in the popover.
- **"Since" timer.** See when the bridge last changed and how long ago.
- **Notifications.** Get a macOS notification when the bridge goes up or comes down.
- **Launch at login.** One checkbox.
- **Tiny.** One Swift file, no dependencies, no accounts, no email setup.

## Menu bar states

<table>
  <tr>
    <td align="center">
      <picture><source media="(prefers-color-scheme: dark)" srcset="assets/icon-down-dark.png"><img src="assets/icon-down-light.png" width="120" alt="Bridge down icon"></picture>
      <br><b>Down</b><br><sub>Open to traffic</sub>
    </td>
    <td align="center">
      <picture><source media="(prefers-color-scheme: dark)" srcset="assets/icon-mid-dark.png"><img src="assets/icon-mid-light.png" width="120" alt="Bridge raising icon"></picture>
      <br><b>Raising</b><br><sub>Animates on change</sub>
    </td>
    <td align="center">
      <picture><source media="(prefers-color-scheme: dark)" srcset="assets/icon-up-dark.png"><img src="assets/icon-up-light.png" width="120" alt="Bridge up icon"></picture>
      <br><b>Up</b><br><sub>Closed to traffic</sub>
    </td>
  </tr>
</table>

When the bridge is down, the icon is a template image, so it follows your menu bar's light or dark appearance. If FL511 can't be reached, a `?` appears over the deck.

## Install

### Download

1. Grab `BrickellBridge.zip` from the [latest release](https://github.com/antondkg/brickell-bridge/releases/latest).
2. Unzip it and move **BrickellBridge.app** to `/Applications`.
3. The app is ad-hoc signed, not notarized, so macOS will block it the first time. Clear the quarantine flag once:

   ```bash
   xattr -dr com.apple.quarantine /Applications/BrickellBridge.app
   ```

4. Open it. The bridge icon shows up in your menu bar.

### Build from source

You need Xcode or the Xcode Command Line Tools.

```bash
git clone https://github.com/antondkg/brickell-bridge.git
cd brickell-bridge
INSTALL=1 ./build.sh
```

`./build.sh` alone builds `BrickellBridge.app` in the repo folder. With `INSTALL=1`, it also copies the app to `/Applications` and launches it.

## How it works

Everything comes from [FL511](https://fl511.com), Florida's official traveler information service. The app only talks to `fl511.com` and FL511's video host, `divas.cloud`.

| What | Source |
| --- | --- |
| Bridge status | `GET fl511.com/List/GetData/Bridge`, the same public list that powers FL511's drawbridge page. Brickell Avenue Bridge is item `253`. |
| Live video | `GET fl511.com/Camera/GetVideoUrl?imageId=5359` returns a token request, which `divas.cloud/VDS-API/SecureTokenUri/GetSecureTokenUriBySourceId` turns into a short-lived `?token=` for the HLS stream. Stream requests need a `Referer: https://fl511.com/` header. |
| Snapshot fallback | `GET fl511.com/map/Cctv/5359`, shown while the stream warms up or if it fails. |

A few notes:

- FL511 starts a fresh transcode for each viewer, so the stream takes about 10 to 15 seconds to start. The app keeps a small buffer and resumes on its own if playback catches up to the live edge.
- The stream only runs while the popover is open. Closing it stops all video traffic.
- Status polling is one small JSON request every 15 seconds.

## Use it for a different bridge

FL511 tracks about 20 drawbridges. To point the app at another one, change the IDs at the top of [`main.swift`](main.swift):

```swift
static let bridgeId = "253"        // drawbridge item ID
static let cameraImageId = "5359"  // CCTV image ID
static let streamBase = "https://dis-se1.divas.cloud:8200/chan-12074_h/index.m3u8"
```

Find the bridge ID by searching the drawbridge list:

```bash
curl -s 'https://fl511.com/List/GetData/Bridge?query=%7B%22columns%22%3A%5B%7B%22data%22%3Anull%2C%22name%22%3A%22%22%7D%5D%2C%22start%22%3A0%2C%22length%22%3A100%2C%22search%22%3A%7B%22value%22%3A%22%22%7D%7D' \
  | python3 -c 'import json,sys; [print(r["DT_RowId"], r["status"], r["name"]) for r in json.load(sys.stdin)["data"]]'
```

To find a camera, search the camera list for the bridge name. Use the image `id` and `videoUrl`:

```bash
curl -s 'https://fl511.com/List/GetData/Cameras?query=%7B%22columns%22%3A%5B%7B%22data%22%3Anull%2C%22name%22%3A%22%22%7D%5D%2C%22start%22%3A0%2C%22length%22%3A10%2C%22search%22%3A%7B%22value%22%3A%22brickell%22%7D%7D' \
  | python3 -m json.tool | grep -E '"id"|videoUrl|description'
```

## Privacy

No accounts, analytics or tracking, and no email access. The app makes anonymous requests to FL511's public endpoints, and that's it.

## Disclaimer

This is an unofficial hobby project. It is not affiliated with or endorsed by FL511, the Florida Department of Transportation or the City of Miami. Status data comes from FL511 and may lag the real world. Don't use it while driving.

## License

[MIT](LICENSE) © Antonio Goncalves
