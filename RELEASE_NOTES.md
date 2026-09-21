FjärrConnect 0.2.15 — hardened verified SFTP directory downloads.

- Directory downloads now reconcile their staging tree against each current server listing, so a remote change during a resumed transfer cannot leave a stale local child in the completed folder.
- Uploads and downloads of files and directories retain a private staging item after cancellation, timeout or a disconnected SFTP channel. Before reuse, FjärrConnect verifies every transferred file prefix and validates safe directory structure.
- The change is verified against OpenSSH’s real `sftp-server`, plus the ARM/Intel regression, package, downloaded-app RDP and Gitleaks checks.

Existing favorites, saved profiles, Keychain credentials and encrypted opt-in SSH command-name logs are retained. Saved profiles still use double-click to connect.

Known limitations: clipboard sharing supports text, not images or files. Multi-monitor RDP, RemoteApp, USB/printer redirection, and VNC VeNCrypt/TLS or RSA-AES authentication are not implemented. See the README for protocol details.

Download `FjarrConnect-0.2.15-macOS-arm64.zip` for Apple Silicon or `FjarrConnect-0.2.15-macOS-x86_64.zip` for Intel. Each app contains only its target architecture and requires macOS 14 or later. Unzip and move FjärrConnect to Applications. `SHA256SUMS.txt` contains both download checksums.

The apps are ad-hoc signed, not Developer ID signed or notarized. macOS may require approval in System Settings → Privacy & Security on first launch.
