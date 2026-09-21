FjärrConnect 0.2.10 — author and repository in About.

- The About FjärrConnect menu now identifies Daniel Nylander as the creator and includes a clickable link to the GitHub repository. The app metadata uses the same copyright name.
- Added a regression fixture matching macOS Screen Sharing’s RFB 3.889 announcement, standards-compatible 3.8 fallback, and Apple ARD security offer. This protects the connection path used by the tested Mac VNC host.
- Verified the About link, Apple-VNC negotiation, resource localization and packaging in the full macOS ARM and Intel test suites, plus Gitleaks.

Existing favorites, saved profiles, Keychain credentials and encrypted opt-in SSH command-name logs are retained. Saved profiles still use double-click to connect.

Known limitations: clipboard sharing supports text, not images or files. Multi-monitor RDP, RemoteApp, USB/printer redirection, and VNC VeNCrypt/TLS or RSA-AES authentication are not implemented. Interrupted SFTP uploads may leave a temporary `.fjarrconnect-…partial` item on the server. See the README for protocol details.

Download `FjarrConnect-0.2.10-macOS-arm64.zip` for Apple Silicon or `FjarrConnect-0.2.10-macOS-x86_64.zip` for Intel. Each app contains only its target architecture and requires macOS 14 or later. Unzip and move FjärrConnect to Applications. `SHA256SUMS.txt` contains both download checksums.

The apps are ad-hoc signed, not Developer ID signed or notarized. macOS may require approval in System Settings → Privacy & Security on first launch.
