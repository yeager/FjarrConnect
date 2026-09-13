<div align="center">
  <img src="icon.png" width="128" alt="FjärrConnect app icon"/>
  <h1>FjärrConnect</h1>
  <p><strong>Native macOS remote-desktop client for VNC, RDP and SSH.</strong></p>
  <p>
    <img src="https://img.shields.io/badge/protected%20by-gitleaks-blue" alt="protected by gitleaks"/>
    <img src="https://github.com/yeager/FjarrConnect/actions/workflows/ci.yml/badge.svg" alt="CI"/>
    <img src="https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey" alt="platform"/>
    <img src="https://img.shields.io/badge/license-MIT-green" alt="license"/>
  </p>
</div>

A native macOS remote-desktop client for reaching the machines on your network —
**VNC** (including Mac Screen Sharing), **RDP**, and **SSH** — from one place.
Saved connection profiles, credentials in the Keychain, Bonjour auto-discovery,
and a fully Scandinavian-localized interface.

> **Naming.** `FjärrConnect` is the display name; `FjarrConnect` / `fjarrconnect`
> is the internal name used everywhere tooling requires ASCII (bundle id, target,
> module). *Fjärr* is Swedish for "remote" — as in *fjärrskrivbord*, remote desktop.

---

## Features

- **Three protocols, one app** — VNC, RDP, and SSH behind a single connection list.
- **Auto-discovery** — Macs sharing their screen appear automatically on your LAN
  via Bonjour (`_rfb._tcp`), the same mechanism Apple Remote Desktop uses.
- **Saved profiles** — name, host, port, protocol, username, and optional grouping,
  persisted locally and reusable with one click.
- **Credentials in the Keychain** — passwords are never written to the profile file
  or to disk in plain text.
- **Quick connect** — type `vnc://user@host:port` (or just a hostname) to connect
  without saving anything.
- **Localized** — English, Swedish, Danish, and Norwegian Bokmål.

## Protocol status

| Protocol | Status | Engine |
|---|---|---|
| VNC / Screen Sharing | ✅ Implemented | [RoyalVNCKit](https://github.com/royalapplications/royalvnc) (MIT) |
| RDP | 🚧 Stubbed behind the seam | [FreeRDP 3](https://github.com/FreeRDP/FreeRDP) (Apache-2.0) |
| SSH | 🚧 Stubbed behind the seam | [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) + [Citadel](https://github.com/orlandos-nl/Citadel) |

RoyalVNCKit speaks both classic VNC auth and Apple Remote Desktop auth, so a macOS
account username/password connects to any Mac with Screen Sharing enabled.

## Requirements

- **macOS 14 or later** (uses `ContentUnavailableView` and the two-parameter `onChange`).
- Apple Silicon or Intel — the release build is a **universal binary**.
- To build: **Xcode 16.4+** and **[XcodeGen](https://github.com/yonaskolb/XcodeGen)**.

## Building

The Xcode project is generated from `project.yml`, so no `.xcodeproj` is committed —
`project.yml` is the single source of truth for the bundle id, Info.plist keys,
localizations, app icon, and the RoyalVNCKit dependency.

```bash
git clone https://github.com/yeager/FjarrConnect.git
cd FjarrConnect
brew install xcodegen
xcodegen generate          # writes FjarrConnect.xcodeproj + Generated/Info.plist
open FjarrConnect.xcodeproj # then press ⌘R
```

Command-line build (identical to CI), producing a universal binary:

```bash
xcodebuild -project FjarrConnect.xcodeproj -scheme FjarrConnect \
  -configuration Release -destination 'generic/platform=macOS' \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
```

## Usage

1. On the **target** Mac: System Settings ▸ General ▸ Sharing ▸ **Screen Sharing** → on.
2. Launch FjärrConnect and allow the Local Network permission prompt (macOS 15+).
3. The Mac appears under **On Your Network** — click to connect. Or type an address
   in the quick-connect field (`vnc://studio.local`), or save a reusable profile with
   the **+** button.

Saved profiles can be edited or deleted from the sidebar's context menu; passwords
are stored in the Keychain, keyed by the profile's id.

## Localization

Every user-facing string is a key in `Resources/<lang>.lproj/Localizable.strings`,
translated for:

- 🇬🇧 English (base) · 🇸🇪 Swedish · 🇩🇰 Danish · 🇳🇴 Norwegian Bokmål

All four tables are kept in key-for-key parity. Add a language by copying an `.lproj`
folder and adding the locale under the target's localizations in `project.yml`.

## Architecture

The design borrows Remmina's protocol-plugin model: a single seam, `RemoteSession`,
hides every transport library so the UI never talks to a concrete backend.

```
ContentView ─ ConnectionManager ─ (any RemoteSession)
                                    ├── VNCRemoteSession  (RoyalVNCKit)
                                    ├── RDPRemoteSession  (FreeRDP — stub)
                                    └── SSHRemoteSession  (SwiftTerm — stub)
```

`ProtocolRegistry.makeSession(for:)` is the only place that knows which libraries
exist — adding a real RDP or SSH backend means implementing one file, with no UI
changes. Supporting types:

- `ConnectionProfile` / `ProfileStore` — the saved-machine model and its JSON store.
- `KeychainStore` — per-profile passwords via Keychain Services.
- `BonjourBrowser` — `_rfb._tcp` discovery and endpoint resolution.
- `ConnectionURI` — `vnc://user@host:port` quick-connect parsing.

## Security

Secrets are kept out of the repository by [gitleaks](https://github.com/gitleaks/gitleaks) (MIT):

- **CI** (`.github/workflows/gitleaks.yml`) scans full history on every push/PR using
  the gitleaks CLI — no license key required, unlike the official action for orgs.
- **Pre-commit** (`.pre-commit-config.yaml`) runs the same scan locally:
  `pipx install pre-commit && pre-commit install`.
- App credentials live only in the macOS Keychain, never in source or profile files.

## Continuous integration

`.github/workflows/ci.yml` runs on every push and PR:

- Runner **macos-15**, Xcode pinned to **16.4**.
- `xcodegen generate` → `xcodebuild` a **universal** (`arm64` + `x86_64`) build.
- `lipo -info` verifies both slices, and the `.app` is uploaded as an artifact.

## App icon

`icon.svg` is the editable master — a Bifröst-style aurora arc bridging two nodes,
evoking both the Nordic name and the app's job of connecting two machines. It's
rasterized into `Resources/Assets.xcassets/AppIcon.appiconset` (16–1024px), and
`icon.png` / `icon.icns` are provided for use outside the app bundle.

## Roadmap

- Implement the SSH backend (SwiftTerm PTY + Citadel) and RDP backend (FreeRDP xcframework).
- SSH key-based auth, with keys in the Keychain.
- Session tabs and per-profile colour tags.
- Localize the remaining `SessionStatus` labels.
- Unit tests (`ConnectionURI`, `ProfileStore`) wired into CI.
- Signed and notarized release builds.

## Licensing

FjärrConnect is released under the [MIT License](LICENSE).

Dependencies keep their own permissive licenses: RoyalVNCKit (MIT), and — once
integrated — FreeRDP (Apache-2.0), SwiftTerm (BSD), Citadel (MIT). The design draws
architectural inspiration from [Remmina](https://gitlab.com/Remmina/Remmina)
(GPLv2+); ideas and UX only — no Remmina code is included.
