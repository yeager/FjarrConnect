FjärrConnect 0.2.5 — Improved release verification.

- Corrected the isolation of packaged-app startup checks on macOS. The verifier now uses Foundation’s temporary home override so startup checks do not read the account’s saved connection profiles.
- Built from the latest main with full-history Gitleaks, native ARM/Intel regression and UI tests, and verification of both downloadable apps.
- Includes all nine interface languages, encrypted opt-in SSH command-name logs, favorites and the VNC desktop-resizing fixes from previous releases.

Download `FjarrConnect-0.2.5-macOS-arm64.zip` for Apple Silicon or `FjarrConnect-0.2.5-macOS-x86_64.zip` for Intel. Each app contains only its target architecture. Unzip and move FjärrConnect to Applications. Saved profiles and Keychain entries are retained. `SHA256SUMS.txt` contains both download checksums.

The apps are ad-hoc signed, not Developer ID signed or notarized. macOS may require approval in System Settings → Privacy & Security on first launch.
