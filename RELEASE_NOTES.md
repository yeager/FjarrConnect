FjärrConnect 0.2.19 — SSH keep-alive.

- SSH profiles now keep an idle, authenticated session alive with encrypted OpenSSH protocol messages every 30 seconds.
- Keep-alive is on by default, including for saved profiles from previous versions, and can be disabled per SSH profile in Advanced options.
- Keep-alives never write to the remote shell, terminal display or encrypted command-name log.
- The release is verified by ARM/Intel regression, package, downloaded-app RDP and Gitleaks checks.

Existing favorites, saved profiles, Keychain credentials and encrypted opt-in SSH command-name logs are retained. Saved profiles still use double-click to connect.

Known limitations: VNC clipboard supports text only; clipboard file copying is not implemented. Multi-monitor RDP, RemoteApp, USB/printer redirection, and VNC VeNCrypt/TLS or RSA-AES authentication are not implemented. See the README for protocol details.

Download `FjarrConnect-0.2.19-macOS-arm64.zip` for Apple Silicon or `FjarrConnect-0.2.19-macOS-x86_64.zip` for Intel. Each app contains only its target architecture and requires macOS 14 or later. Unzip and move FjärrConnect to Applications. `SHA256SUMS.txt` contains both download checksums.

The apps are ad-hoc signed, not Developer ID signed or notarized. macOS may require approval in System Settings → Privacy & Security on first launch.
