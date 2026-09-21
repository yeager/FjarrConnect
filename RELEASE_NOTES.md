FjärrConnect 0.2.6 — Embedded RDP and connection tools.

- RDP desktops now stay inside the app’s session tabs. Certificate verification dialogs and connection errors are translated into all nine interface languages.
- Single-click a saved profile to select it; double-click to connect. This also applies to favorites.
- Added an SFTP panel for browsing, uploading and downloading files and folders, with progress and cancellation.
- Added SSH identity, jump-host and forwarding options, RDP gateways and explicitly shared folders, and links to SMB shares and HTTPS administration pages.
- Closing an active session, the main window or the app asks for confirmation. Cancelling keeps sessions running.
- Added Unicode VNC text clipboard support and per-profile clipboard controls that restrict synchronization to the active session. The SDK changes have been submitted upstream in royalapplications/royalvnc#37.
- Updated the README and all nine language tables. Existing favorites, saved profiles, Keychain credentials and encrypted opt-in SSH command-name logs are retained.

The release workflow runs full-history Gitleaks, regression and UI tests on both native Mac architectures, and startup/certificate checks of both downloadable apps before publication.

Known limitations: some Windows hosts can still time out while activating the RDP desktop; the app reports a localized error. Clipboard sharing supports text, not images or files. Multi-monitor RDP, RemoteApp, USB/printer redirection, and VNC VeNCrypt/TLS or RSA-AES authentication are not implemented. Interrupted SFTP uploads may leave a temporary `.fjarrconnect-…partial` item on the server. See the README for protocol details.

Download `FjarrConnect-0.2.6-macOS-arm64.zip` for Apple Silicon or `FjarrConnect-0.2.6-macOS-x86_64.zip` for Intel. Each app contains only its target architecture and requires macOS 14 or later. Unzip and move FjärrConnect to Applications. `SHA256SUMS.txt` contains both download checksums.

The apps are ad-hoc signed, not Developer ID signed or notarized. macOS may require approval in System Settings → Privacy & Security on first launch.
