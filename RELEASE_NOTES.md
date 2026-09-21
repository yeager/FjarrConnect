FjärrConnect 0.2.9 — recover from incompatible RDP display resizing.

- Added a per-profile RDP setting to keep a fixed remote-desktop size for legacy servers and RDP-to-VNC gateways that reject a dynamic display resize or disconnect during one.
- Existing profiles retain dynamic resizing by default. The new setting is localized in English, Swedish, Danish, Norwegian, German, Finnish, French, Spanish and Japanese.
- Verified legacy-profile compatibility and FreeRDP argument handling, then ran the macOS ARM and Intel regression suites and Gitleaks.

Existing favorites, saved profiles, Keychain credentials and encrypted opt-in SSH command-name logs are retained. Saved profiles still use double-click to connect.

Known limitations: clipboard sharing supports text, not images or files. Multi-monitor RDP, RemoteApp, USB/printer redirection, and VNC VeNCrypt/TLS or RSA-AES authentication are not implemented. Interrupted SFTP uploads may leave a temporary `.fjarrconnect-…partial` item on the server. See the README for protocol details.

Download `FjarrConnect-0.2.9-macOS-arm64.zip` for Apple Silicon or `FjarrConnect-0.2.9-macOS-x86_64.zip` for Intel. Each app contains only its target architecture and requires macOS 14 or later. Unzip and move FjärrConnect to Applications. `SHA256SUMS.txt` contains both download checksums.

The apps are ad-hoc signed, not Developer ID signed or notarized. macOS may require approval in System Settings → Privacy & Security on first launch.
