FjärrConnect 0.2.18 — RDP image clipboard.

- RDP now shares copied images and screenshots in both directions with Windows peers that advertise the standard DIB clipboard format. Text clipboard behavior is unchanged.
- The RDP clipboard option now states that it covers text and images; the VNC option remains explicitly text-only.
- Package verification runs an AppKit image → RDP DIB → AppKit clipboard round trip on both Apple Silicon and Intel before publishing.
- The release is verified by ARM/Intel regression, package, downloaded-app RDP and Gitleaks checks.

Existing favorites, saved profiles, Keychain credentials and encrypted opt-in SSH command-name logs are retained. Saved profiles still use double-click to connect.

Known limitations: VNC clipboard supports text only; clipboard file copying is not implemented. Multi-monitor RDP, RemoteApp, USB/printer redirection, and VNC VeNCrypt/TLS or RSA-AES authentication are not implemented. See the README for protocol details.

Download `FjarrConnect-0.2.18-macOS-arm64.zip` for Apple Silicon or `FjarrConnect-0.2.18-macOS-x86_64.zip` for Intel. Each app contains only its target architecture and requires macOS 14 or later. Unzip and move FjärrConnect to Applications. `SHA256SUMS.txt` contains both download checksums.

The apps are ad-hoc signed, not Developer ID signed or notarized. macOS may require approval in System Settings → Privacy & Security on first launch.
