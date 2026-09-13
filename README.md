<div align="center">
  <img src="icon.png" width="128" alt="FjärrConnect app icon"/>
  <h1>FjärrConnect</h1>
  <p><strong>Your remote machines, in one Mac app.</strong></p>
  <p>
    <a href="https://github.com/yeager/FjarrConnect/actions/workflows/ci.yml"><img src="https://github.com/yeager/FjarrConnect/actions/workflows/ci.yml/badge.svg" alt="Mac build and tests"/></a>
    <a href="https://github.com/yeager/FjarrConnect/actions/workflows/gitleaks.yml"><img src="https://github.com/yeager/FjarrConnect/actions/workflows/gitleaks.yml/badge.svg" alt="Gitleaks secret scan"/></a>
    <img src="https://img.shields.io/badge/macOS-14%2B-lightgrey" alt="macOS 14 or later"/>
    <img src="https://img.shields.io/badge/architectures-Apple%20Silicon%20%2B%20Intel-blue" alt="Apple Silicon and Intel"/>
    <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT license"/>
  </p>
</div>

FjärrConnect brings **VNC / Mac Screen Sharing, SSH and RDP** into one connection
manager for **macOS 14 or later**, on **Apple Silicon (arm64) and Intel (x86_64)**.
There are no Windows, Linux or mobile app targets.

## Version 0.2

**[Download version 0.2.0](https://github.com/yeager/FjarrConnect/releases/tag/v0.2.0)**
for Apple Silicon and Intel. Download `FjarrConnect-0.2.0-macOS-universal.zip` and
`SHA256SUMS.txt`, unzip the archive and move FjärrConnect to Applications.

Every release passes gitleaks, Mac regression tests, universal packaging and
checks of the downloaded app on both native Mac architectures before publication.

The initial release uses **ad-hoc signing**, not Developer ID signing or Apple
notarization. macOS may require approval under **System Settings → Privacy & Security**
on first launch. Never disable Gatekeeper globally to install the app.

## Features

- **Favorites:** click the star beside a saved connection to pin it to the Favorites
  section. Click again to remove it. Favorites persist between launches, work with
  search, and preserve compatibility with existing saved profiles.
- **Saved connections:** create, edit and delete profiles with a name, host, port,
  protocol, username and optional group. Right-click a connection for available actions.
- **Session tabs:** keep multiple connections open and switch between them. Closing
  a tab disconnects its session; closing the app disconnects all sessions.
- **Search:** find saved connections by name, host, group or protocol, and filter
  discovered Macs by name.
- **Quick connect:** press **⌘K**, enter an address, then press Return.
- **New connection:** press **⌘N**. Leave the name blank to use the hostname.
- **Bonjour discovery:** find Macs advertising Screen Sharing on the local network,
  with refresh and visible connection errors. Discovery uses `_rfb._tcp` (VNC);
  SSH and RDP hosts are added manually, and hosts on other networks need an address.
- **Keychain credentials:** save VNC and RDP passwords in the macOS Keychain. Quick
  connections can use a password without saving it.
- **Localized interface:** English, Swedish, Danish and Norwegian Bokmål.
- **Refreshed icon:** an editable SVG master with all required Mac icon sizes.

## Protocols

| Protocol | How it works | Authentication |
|---|---|---|
| VNC / Mac Screen Sharing | Embedded desktop through [RoyalVNCKit](https://github.com/royalapplications/royalvnc), with keyboard, mouse and clipboard support | VNC password or remote Mac username/password; optional Keychain storage |
| SSH | Embedded [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) terminal running macOS `/usr/bin/ssh` | Your SSH configuration, keys and ssh-agent; passwords and new host-key confirmation in the terminal |
| RDP | Native [FreeRDP](https://github.com/FreeRDP/FreeRDP) SDL client in a separate desktop window, managed by FjärrConnect | Username/password; FreeRDP handles certificate prompts |

**RDP is bundled:** no Homebrew installation is needed for the downloaded app.
The CI/release pipeline builds a self-contained FreeRDP runtime for both Mac
architectures. Developer builds also detect a locally installed SDL client from
`brew install freerdp`.

SSH passwords are entered directly in the terminal and are **not** saved by
FjärrConnect. SSH private keys remain managed by OpenSSH and your ssh-agent.
The status “Client running” for SSH/RDP means the client process started; it does
not claim that authentication succeeded.

## Connect to a Mac

1. On the remote Mac, enable **System Settings → General → Sharing → Screen Sharing**.
2. Open FjärrConnect. Allow Local Network access if macOS asks.
3. Select the Mac under **On Your Network**, or enter `vnc://studio.local` in Quick Connect.
4. Enter the remote Mac account's username and password. For a saved profile, you can
   remember the password in Keychain.
5. Save frequently used machines with **⌘N**, then click their star to make them favorites.

Quick-connect examples:

```text
studio.local
vnc://admin@studio.local:5901
ssh://deploy@server.local:2222
rdp://user@workstation.local
vnc://[::1]:5900
```

Ports must be between **1 and 65535**. Passwords, query parameters and arbitrary
paths are rejected in connection URLs; use the sign-in dialog for credentials.
In the profile editor, enter only the hostname/IP in the Host field and the port in
its own field. IPv6 addresses in URLs use brackets.

## Credentials and local data

Profiles are stored in:

```text
~/Library/Application Support/FjarrConnect/profiles.json
```

The JSON contains connection details and favorite state, **not passwords**. VNC/RDP
passwords are stored as per-profile Keychain items. When editing a profile, enable
**Change saved password** to replace it; an empty replacement removes the saved password.

Saving reports errors instead of silently losing changes. An unreadable or corrupt
profile file is preserved and blocks further saves so it cannot be overwritten by
an empty connection list. Back up the file before repairing or removing it.

VNC encryption depends on the server and authentication protocol; use a trusted
network or VPN. SSH retains OpenSSH host-key checks, and RDP retains certificate
verification. RDP credentials are passed through an anonymous pipe, not command-line
arguments or temporary profile files.

## Build from source

You need **Xcode 16.4+** and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
The Xcode project is generated from `project.yml`.

```bash
git clone https://github.com/yeager/FjarrConnect.git
cd FjarrConnect
brew install xcodegen
xcodegen generate
open FjarrConnect.xcodeproj
```

Build the universal app:

```bash
xcodebuild -project FjarrConnect.xcodeproj -scheme FjarrConnect \
  -configuration Release -destination 'generic/platform=macOS' \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
```

Run Mac tests for the host architecture:

```bash
xcodebuild -project FjarrConnect.xcodeproj -scheme FjarrConnect \
  -configuration Debug -destination 'platform=macOS' \
  ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO test
```

`scripts/build-rdp.sh arm64` and `scripts/build-rdp.sh x86_64` build the bundled RDP
runtime from pinned FreeRDP, OpenSSL and SDL sources on a Mac with CMake available.
CI combines both outputs and `scripts/build-release.sh` packages the app. A normal
Xcode build does not automatically compile or bundle the RDP runtime.

## GitHub Actions and releases

Development is on **`main`**.

- **CI:** checks localizations and icons, runs macOS regression tests, builds both RDP
  runtime slices and packages the universal app. Packaging verifies architecture
  slices in the app and embedded native code, checks ad-hoc signatures, and creates
  a ZIP archive with a SHA-256 checksum. Separate Apple Silicon and Intel jobs
  download the ZIP, verify it and exercise the bundled RDP client against a local
  negotiation fixture in authentication-only mode.
- **gitleaks:** scans the complete repository history on pushes to `main` and pull
  requests. The release workflow also requires a clean full-history scan.
- **Release:** a tag matching `MARKETING_VERSION`, such as **`v0.2.0`**, triggers a
  fresh scan, test and build. GitHub publishes the release assets only when these pass.

For maintainers, after the current `main` revision passes verification:

```bash
git pull --ff-only
git tag v0.2.0
git push origin v0.2.0
```

Do not reuse or move an already published release tag. Use a new version for fixes.
Release notes are maintained in `RELEASE_NOTES.md`.

Local checks:

```bash
python3 scripts/check-resources.py
gitleaks detect --source . --redact
gitleaks detect --source . --no-git --redact
git diff --check
```

An optional pre-commit hook is configured in `.pre-commit-config.yaml`.

## Project layout

| Directory | Purpose |
|---|---|
| `App` | App lifecycle and session ownership |
| `Model` | Profiles, favorites, validation, persistence and Keychain access |
| `Protocols` | VNC, SSH and RDP session implementations |
| `Views` | Connection list, tabs, profile editor and sign-in UI |
| `Discovery` | Bonjour browsing and endpoint resolution |
| `Resources` | Mac app icon and four localization tables |
| `Tests` | Regression tests for profiles, favorites, sessions, VNC and SSH |
| `UITests` | Native Mac UI tests for saving and persisting favorites |
| `scripts` | Resource validation, icon generation and release/runtime builds |

`RemoteSession` is the common backend interface. `ConnectionManager` owns session
tabs; UI code does not need to know each backend's transport implementation.

## Icon and localization

`icon.svg` is the editable icon master. Regenerate `icon.png`, `icon.icns` and all
Mac asset-catalog sizes with:

```bash
python3 -m pip install cairosvg pillow
python3 scripts/generate-icon.py
python3 scripts/check-resources.py
```

User-facing strings live in `Resources/{en,sv,da,nb}.lproj/Localizable.strings`.
Keep the four tables in key-for-key parity; the resource check enforces this.

## License

FjärrConnect is [MIT licensed](LICENSE). Dependencies retain their own licenses:
RoyalVNCKit (MIT), SwiftTerm (MIT), FreeRDP and OpenSSL (Apache-2.0), SDL and SDL_ttf
(zlib), and FreeType (FreeType License). Bundled RDP dependency notices are copied
into the app's `Contents/Resources/Licenses` directory by the packaging workflow.
No Remmina source code is included.
