FjärrConnect 0.2.1 — remote connections for macOS 14 and later, on Apple Silicon and Intel.

- Fixed the startup crash caused by a missing RoyalVNCKit framework in 0.2.0.
- Separate Apple Silicon (arm64) and Intel (x86_64) apps, each with one architecture.
- The downloadable apps are now launched on native Mac runners without Xcode library paths; a missing-framework negative control guards against this regression.
- VNC / Mac Screen Sharing with saved profiles and Keychain credentials.
- Integrated SSH terminal using macOS OpenSSH, including ssh-agent, SSH keys and interactive authentication.
- RDP through the bundled native FreeRDP SDL client, in its own window. No separate Homebrew installation is needed.
- Persistent favorites with one-click stars, session tabs, connection search, quick connect (⌘K), new profiles (⌘N), Bonjour discovery and reconnect controls.
- Improved validation, visible storage errors, safer credential updates, and a new app icon.
- English, Swedish, Danish and Norwegian interface.

Download `FjarrConnect-0.2.1-macOS-arm64.zip` for Apple Silicon or `FjarrConnect-0.2.1-macOS-x86_64.zip` for Intel, unzip it, and move FjärrConnect to Applications. `SHA256SUMS.txt` contains the download checksum.

This initial build is ad-hoc signed, not Developer ID signed or notarized. macOS may require approval in System Settings → Privacy & Security on first launch. VNC encryption depends on the server/protocol; use a trusted network or VPN. SSH passwords are entered directly in the terminal and are not saved by FjärrConnect.
