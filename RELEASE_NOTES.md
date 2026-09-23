Unreleased

- New VNC profiles and quick-connect addresses default to Mac Screen Sharing and require a username. Select Standard VNC in the sign-in dialog for password-only servers.
- Add bidirectional VNC clipboard support for text and standard DIB V5 images, with per-session isolation.
- Add per-profile Wake-on-LAN and RDP network presets.
- Let users select an RDP keyboard layout or map the current macOS input source automatically.
- Verify VNC key events for Swedish, QWERTZ/AZERTY-style and Unicode characters; VNC layout negotiation is unavailable.
- Add a VNC file browser for servers that advertise legacy Tight file transfer, with capability-gated uploads and downloads up to 256 MiB. Local RFB fixtures verify upload framing; real-server upload verification remains outstanding.
- Show connection latency, negotiated RDP codec and reconnection state in session health.
- Carry files dropped on an RDP or VNC desktop into the same host's SFTP upload queue.
- Expand saved diagnostic reports with app, macOS and architecture details while
  omitting the endpoint, credentials and server output.
- Keep RDP file clipboard transfer disabled pending a real Windows integration test; continue to recommend SFTP or shared folders.
- Keep RDP audio and microphone redirection unavailable until verified in a real macOS RDP session.

Known limitations: RDP file clipboard support is not enabled pending Windows integration
testing. VNC file transfer requires the server to advertise the legacy Tight channel.
VNC uploads have no server acknowledgement and have not been verified against a real
server; refresh the listing to check the result. SFTP remains the recommended file flow.
VNC clipboard supports text and standard DIB V5 images; clipboard file copying is not implemented.
Multi-monitor RDP, USB redirection, RDP printer redirection and RDP smart-card redirection
are not implemented. RDP audio and microphone redirection are unavailable pending
macOS RDS integration testing. RemoteApp is a separate tabbed session type
with dynamic desktop resizing disabled, but end-to-end launch verification awaits a
Windows Server with a published alias. Certificate-authenticated VeNCrypt/TLS is
supported on macOS; RSA-AES and unsupported VeNCrypt subtypes remain unavailable. See
the README for protocol details.

---

FjärrConnect 0.2.23

- Documents embedded RDP and VNC recording, including its local H.264 `.mov` output, red recording indicator and no-audio scope.
- Documents the bundled FreeRDP runtime, RD Gateway over HTTPS, RemoteApp aliases and protocol limitations.
- Simplifies README and repository metadata.

Known limitations: VNC clipboard supports text only; clipboard file copying is not implemented. Multi-monitor RDP, USB redirection, RDP printer redirection and RDP smart-card redirection are not implemented. RDP audio and microphone redirection are opt-in and require server support, but await RDS integration testing. RemoteApp is a separate tabbed session type with dynamic desktop resizing disabled, but end-to-end launch verification awaits a Windows Server with a published alias. Certificate-authenticated VeNCrypt/TLS is supported on macOS; RSA-AES and unsupported VeNCrypt subtypes remain unavailable. See the README for protocol details.

Download `FjarrConnect-0.2.23-macOS-arm64.zip` for Apple Silicon or `FjarrConnect-0.2.23-macOS-x86_64.zip` for Intel. Each app contains only its target architecture and requires macOS 14 or later. `SHA256SUMS.txt` contains both download checksums.

The apps are ad-hoc signed, not Developer ID signed or notarized. macOS may require approval in System Settings → Privacy & Security on first launch.
