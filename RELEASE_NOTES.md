FjärrConnect 0.2.7 — Windows desktop fix and network discovery.

- Fixed Windows RDP sessions closing immediately when the desktop starts. The embedded client now responds to the server's network-latency measurements. Verified with NLA authentication, an actual Windows desktop, resizing and a sustained connection.
- Added Find servers: search an IPv4 network for VNC, RDP and SSH, including hosts that do not advertise through Bonjour. The scanner verifies each protocol before listing a result. Save results as profiles or connect directly.
- Expanded Bonjour discovery to RDP and SSH, added progress and cancellation for manual searches, and translated the new controls into all nine languages.
- Fixed the network discovery UI-test fixture for Xcode's sandboxed runner. CI tests both native Mac architectures and checks the packaged apps before publication.

Existing favorites, saved profiles, Keychain credentials and encrypted opt-in SSH command-name logs are retained. Saved profiles still use double-click to connect.

Known limitations: clipboard sharing supports text, not images or files. Multi-monitor RDP, RemoteApp, USB/printer redirection, and VNC VeNCrypt/TLS or RSA-AES authentication are not implemented. Interrupted SFTP uploads may leave a temporary `.fjarrconnect-…partial` item on the server. See the README for protocol details.

Download `FjarrConnect-0.2.7-macOS-arm64.zip` for Apple Silicon or `FjarrConnect-0.2.7-macOS-x86_64.zip` for Intel. Each app contains only its target architecture and requires macOS 14 or later. Unzip and move FjärrConnect to Applications. `SHA256SUMS.txt` contains both download checksums.

The apps are ad-hoc signed, not Developer ID signed or notarized. macOS may require approval in System Settings → Privacy & Security on first launch.
