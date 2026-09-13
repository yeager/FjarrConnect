FjärrConnect 0.1 — remote connections for macOS 14 and later, on Apple Silicon and Intel.

- VNC / Mac Screen Sharing with saved profiles and Keychain credentials.
- Integrated SSH terminal using macOS OpenSSH, including ssh-agent, SSH keys and interactive authentication.
- RDP through the native FreeRDP SDL client, in its own window. Install the optional RDP runtime with `brew install freerdp`.
- Session tabs, connection search, quick connect (⌘K), new profiles (⌘N), Bonjour discovery and reconnect controls.
- Improved validation, visible storage errors, safer credential updates, and a new app icon.
- English, Swedish, Danish and Norwegian interface.

Download `FjarrConnect-0.1.0-macOS-universal.zip`, unzip it, and move FjärrConnect to Applications. `SHA256SUMS.txt` contains the download checksum.

This initial build is ad-hoc signed, not Developer ID signed or notarized. macOS may require approval in System Settings → Privacy & Security on first launch. VNC encryption depends on the server/protocol; use a trusted network or VPN. SSH passwords are entered directly in the terminal and are not saved by FjärrConnect.
