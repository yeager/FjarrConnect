FjärrConnect 0.2.8 — reliable session tabs and SFTP recovery.

- Fixed session-tab selection and close buttons on macOS 15. Tabs now use native AppKit controls, retain the selected accessibility state, scroll into view when needed, and keep their underlying connection alive while switching.
- Cancelling an SFTP upload or download now recreates only the SFTP subsystem over the existing authenticated SSH master. The file browser refreshes and is ready for another transfer without another password or key prompt.
- Added native SFTP file-table actions for folder navigation, download, rename and delete. Standard macOS upload and download panels are covered by end-to-end UI checks.
- Kept the Windows RDP desktop-start correction, verified VNC/RDP/SSH discovery, favorites, SSH command-name logging and nine-language localization from the preceding release.

Existing favorites, saved profiles, Keychain credentials and encrypted opt-in SSH command-name logs are retained. Saved profiles still use double-click to connect.

Known limitations: clipboard sharing supports text, not images or files. Multi-monitor RDP, RemoteApp, USB/printer redirection, and VNC VeNCrypt/TLS or RSA-AES authentication are not implemented. Interrupted SFTP uploads may leave a temporary `.fjarrconnect-…partial` item on the server. See the README for protocol details.

Download `FjarrConnect-0.2.8-macOS-arm64.zip` for Apple Silicon or `FjarrConnect-0.2.8-macOS-x86_64.zip` for Intel. Each app contains only its target architecture and requires macOS 14 or later. Unzip and move FjärrConnect to Applications. `SHA256SUMS.txt` contains both download checksums.

The apps are ad-hoc signed, not Developer ID signed or notarized. macOS may require approval in System Settings → Privacy & Security on first launch.
