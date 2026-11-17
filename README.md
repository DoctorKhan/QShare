# QShare

Menu-bar app for Mac that **receives** files, links, and text from Android phones over [Quick Share](https://share.google/) (formerly Nearby Share).

Leave it running. On your phone: Share → Quick Share → pick this Mac. Both devices need to be on the same Wi‑Fi network.

> **Status:** early beta. Receive-only. Built and tested on Apple Silicon (macOS 14+). No notarized installer yet — build from source.

## Features

- Appears as a Quick Share target on the local network (Bonjour)
- Accept / decline requests from the menu, a floating panel, or notifications
- Auto-accept from everyone, trusted devices, or ask every time
- Resume interrupted file transfers when the phone supports it
- Saves into Downloads (or a folder you choose); text and links go to the clipboard
- Optional Bluetooth scan so the Mac shows up faster when a phone opens Quick Share
- Launch at login

## Requirements

- macOS 14 or later
- [Xcode](https://developer.apple.com/xcode/) (command-line tools alone are not enough to build the app)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build & install

```bash
git clone https://github.com/DoctorKhan/QShare.git
cd QShare
./run.sh build --install --run
```

That generates the Xcode project, builds a Release `QShare.app`, copies it to `/Applications`, and launches it. On first run, allow **Local Network** (and **Bluetooth** if you want faster discovery) when macOS asks.

Useful commands:

| Command | What it does |
|---------|----------------|
| `./run.sh build` | Build `build/QShare.app` |
| `./run.sh build --install` | Build and install to `/Applications` |
| `./run.sh build --run` | Build and launch (from `build/` or `/Applications` if you also passed `--install`) |
| `./run.sh test` | Run the QuickShareKit unit tests |
| `./run.sh protos` | Regenerate Swift from `Protos/` (needs `protoc`) |

## Usage

1. Look for the QShare icon in the menu bar.
2. Open settings (gear) to set the name phones see, the save folder, and auto-accept.
3. From Android, share something with Quick Share and choose your Mac. Confirm the PIN if prompted.
4. Accept the request on the Mac (unless auto-accept is on).

## Limits

- **Receive only** — this Mac cannot send to phones or other Macs yet
- **Same Wi‑Fi** — not a substitute for Quick Share over the internet or phone hotspot edge cases
- **Unsigned for Gatekeeper** — a local build is fine for you; strangers downloading a zip will hit macOS quarantine until there is a notarized release
- Protocol compatibility depends on the Android Quick Share implementation; treat this as best-effort

## Layout

| Path | Role |
|------|------|
| `App/` | SwiftUI menu-bar app |
| `Sources/QuickShareKit/` | Receiver, crypto, framing, file store |
| `Protos/` | Google Nearby Share `.proto` definitions (Apache-2.0) |
| `Scripts/` | Build and proto generation |
| `Tests/` | Protocol and receiver tests |

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

Quick Share / Nearby Share protocol buffers are Copyright Google LLC, also under Apache-2.0. QShare is not affiliated with Google.
