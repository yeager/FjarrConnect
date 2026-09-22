FjärrConnect 0.2.21 — embedded session recording and verified packages.

- Mac CI now validates the xcresult summary if Xcode returns its known spurious exit 65 after all tests have passed.
- The fallback requires one or more passing tests and zero failed tests; every other nonzero xcodebuild exit remains a build failure.
- The same verification is used by CI and the release workflow on both Apple Silicon and Intel.
- The release is verified by ARM/Intel regression, package, downloaded-app RDP and Gitleaks checks.
- RDP and VNC session headers now include a Record control and active recording indicator. Recordings contain only the embedded remote desktop and are saved as local H.264 `.mov` files in `~/Movies/FjarrConnect`.

Existing favorites, saved profiles, Keychain credentials and encrypted opt-in SSH command-name logs are retained. Saved profiles still use double-click to connect.

Known limitations: VNC clipboard supports text only; clipboard file copying is not implemented. Multi-monitor RDP, USB redirection, RDP printer redirection and RDP smart-card redirection are not implemented. RDP audio and microphone redirection are opt-in and require server support, but await RDS integration testing. RemoteApp is a separate tabbed session type with dynamic desktop resizing disabled, but end-to-end launch verification awaits a Windows Server with a published alias. VNC VeNCrypt/TLS and RSA-AES authentication are not implemented. See the README for protocol details.

Download `FjarrConnect-0.2.21-macOS-arm64.zip` for Apple Silicon or `FjarrConnect-0.2.21-macOS-x86_64.zip` for Intel. Each app contains only its target architecture and requires macOS 14 or later. Unzip and move FjärrConnect to Applications. `SHA256SUMS.txt` contains both download checksums.

The apps are ad-hoc signed, not Developer ID signed or notarized. macOS may require approval in System Settings → Privacy & Security on first launch.
