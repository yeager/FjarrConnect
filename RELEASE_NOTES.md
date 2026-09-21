FjärrConnect 0.2.11 — verified SFTP upload resume.

- Regular-file uploads interrupted by cancellation, timeout or a disconnected SFTP channel now retain a private staging file and resume when you upload the same local file again.
- Before continuing, the app compares the entire completed remote prefix with the local source. A stale or mismatched staging file is removed and the upload restarts, preventing content from being mixed.
- Regular-file downloads use the same verified resume behavior, while preserving an existing local destination until the complete download is ready. Directory uploads and downloads still restart after interruption. The change is verified against OpenSSH’s real `sftp-server`, plus the ARM/Intel regression, package, downloaded-app RDP and Gitleaks checks.

Existing favorites, saved profiles, Keychain credentials and encrypted opt-in SSH command-name logs are retained. Saved profiles still use double-click to connect.

Known limitations: clipboard sharing supports text, not images or files. Multi-monitor RDP, RemoteApp, USB/printer redirection, and VNC VeNCrypt/TLS or RSA-AES authentication are not implemented. Directory uploads and downloads restart after interruption. See the README for protocol details.

Download `FjarrConnect-0.2.11-macOS-arm64.zip` for Apple Silicon or `FjarrConnect-0.2.11-macOS-x86_64.zip` for Intel. Each app contains only its target architecture and requires macOS 14 or later. Unzip and move FjärrConnect to Applications. `SHA256SUMS.txt` contains both download checksums.

The apps are ad-hoc signed, not Developer ID signed or notarized. macOS may require approval in System Settings → Privacy & Security on first launch.
