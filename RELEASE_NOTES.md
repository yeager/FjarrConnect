FjärrConnect 0.2.22

- Documents embedded RDP and VNC recording, including its local H.264 `.mov` output, red recording indicator and no-audio scope.
- Documents the bundled FreeRDP runtime, RD Gateway over HTTPS, RemoteApp aliases and protocol limitations.
- Simplifies README and repository metadata.

Known limitations: VNC clipboard supports text only; clipboard file copying is not implemented. Multi-monitor RDP, USB redirection, RDP printer redirection and RDP smart-card redirection are not implemented. RDP audio and microphone redirection are opt-in and require server support, but await RDS integration testing. RemoteApp is a separate tabbed session type with dynamic desktop resizing disabled, but end-to-end launch verification awaits a Windows Server with a published alias. VNC VeNCrypt/TLS and RSA-AES authentication are not implemented. See the README for protocol details.

Download `FjarrConnect-0.2.22-macOS-arm64.zip` for Apple Silicon or `FjarrConnect-0.2.22-macOS-x86_64.zip` for Intel. Each app contains only its target architecture and requires macOS 14 or later. `SHA256SUMS.txt` contains both download checksums.

The apps are ad-hoc signed, not Developer ID signed or notarized. macOS may require approval in System Settings → Privacy & Security on first launch.
