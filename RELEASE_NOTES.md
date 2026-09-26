Unreleased

- Check GitHub Releases for a newer stable version at app launch. Automatic checks
  can be disabled in Settings; manual checks remain available and open the release
  page without downloading or installing the update.
- Send Backspace, Return and Tab correctly to VNC servers when macOS resolves their
  characters as non-printable controls.
- Route dropped files to an advertised VNC Tight upload channel when available; keep
  SFTP as the drop fallback for servers without that channel and for RDP.
- Add a session-toolbar action that sends Ctrl+Alt+End to an active Windows RDP session.
- Mark RemoteApp tabs and accessibility names so application sessions are distinct
  from full RDP desktops.
- Accept certificate-verified VeNCrypt `X509Plain` servers. Username and password
  are sent only after macOS validates the server certificate and hostname.
- Keep VeNCrypt `TLSVnc` unavailable because macOS CFNetwork rejects its anonymous
  Diffie–Hellman TLS handshake.
- Add per-profile FreeRDP security selection for automatic, NLA, TLS, and legacy
  Standard RDP security. Automatic negotiation remains the default.
- Make the documented “Change saved password” action remove the stored password
  when saved with an empty field; leaving the action off still preserves it.

---

FjärrConnect 0.2.29

- If a saved VNC password is rejected, open the credential prompt so it can be
  corrected. Automatic reconnect stops after an authentication failure.
- Verify the password field and Advanced options for existing Mac VNC profiles.

Download `FjarrConnect-0.2.29-macOS-arm64.zip` for Apple Silicon or
`FjarrConnect-0.2.29-macOS-x86_64.zip` for Intel. Each app contains only its target
architecture and requires macOS 14 or later. `SHA256SUMS.txt` contains both download
checksums.

The apps are ad-hoc signed, not Developer ID signed or notarized. macOS may require
approval in System Settings → Privacy & Security on first launch.

---

FjärrConnect 0.2.28

- Keep the VNC password field available when editing a saved profile, so credentials
  can be added or replaced without reopening the sign-in dialog.
- Fix expanding Advanced connection options in the profile editor.

Download `FjarrConnect-0.2.28-macOS-arm64.zip` for Apple Silicon or
`FjarrConnect-0.2.28-macOS-x86_64.zip` for Intel. Each app contains only its target
architecture and requires macOS 14 or later. `SHA256SUMS.txt` contains both download
checksums.

The apps are ad-hoc signed, not Developer ID signed or notarized. macOS may require
approval in System Settings → Privacy & Security on first launch.

---

FjärrConnect 0.2.27

- Report an error when saving a connection diagnostics report fails, instead of
  silently leaving the user without an exported file.

Download `FjarrConnect-0.2.27-macOS-arm64.zip` for Apple Silicon or
`FjarrConnect-0.2.27-macOS-x86_64.zip` for Intel. Each app contains only its target
architecture and requires macOS 14 or later. `SHA256SUMS.txt` contains both download
checksums.

The apps are ad-hoc signed, not Developer ID signed or notarized. macOS may require
approval in System Settings → Privacy & Security on first launch.

---

FjärrConnect 0.2.26

- Add VNC image clipboard, bounded legacy Tight file transfer, and per-session
  clipboard isolation. The Tight channel is server-dependent; SFTP remains the
  recommended file workflow.
- Add connection-health details, bounded automatic reconnect, profile tags and
  recent connections, Wake-on-LAN, RDP network presets and dropped-file SFTP flows.
- Add encrypted profile import/export, `.rdp` and `.vnc` import, Touch ID profile
  locking, a searchable recording library and retention controls, and richer
  anonymized diagnostics.
- Add RDP keyboard-layout selection and input-source mapping, keyboard navigation,
  VoiceOver labels and larger interface controls.
- Require a username for Mac Screen Sharing authentication and improve VNC
  authentication-mode selection.
- Bundle FreeRDP 3.32.0 for Apple Silicon and Intel with the RDP desktop embedded in
  the app window. Keep RemoteApp as a separate tabbed session type without dynamic
  desktop resizing.
- Keep printer and smart-card redirection unavailable because the bundled macOS
  FreeRDP build lacks CUPS and PC/SC support. RDP audio and microphone redirection
  remain unavailable until verified in a real macOS session.

Known limitations: RDP clipboard file transfer and multi-monitor output are not
enabled. RDP audio, microphone, printer and smart-card redirection are unavailable.
RemoteApp still needs a real Windows Server with a published alias for end-to-end
verification. VNC clipboard supports text and standard DIB V5 images; clipboard
file copying is not implemented. The VNC Tight file-transfer channel is optional,
uploads have no server acknowledgement, and uploads have not been verified against
a real server; refresh the listing to check the result. SFTP remains recommended.
Certificate-authenticated VeNCrypt/TLS is supported on macOS; RSA-AES and unsupported
VeNCrypt subtypes remain unavailable. See the README for details.

Download `FjarrConnect-0.2.26-macOS-arm64.zip` for Apple Silicon or
`FjarrConnect-0.2.26-macOS-x86_64.zip` for Intel. Each app contains only its target
architecture and requires macOS 14 or later. `SHA256SUMS.txt` contains both download
checksums.

The apps are ad-hoc signed, not Developer ID signed or notarized. macOS may require
approval in System Settings → Privacy & Security on first launch.

---

FjärrConnect 0.2.23

- Add H.264 recording for embedded RDP and VNC tabs, with a red recording indicator.
- Bundle the FreeRDP runtime, RD Gateway over HTTPS and RemoteApp support.

Known limitations at that release: VNC clipboard supported text only. Multi-monitor
RDP, USB, printer and smart-card redirection were unavailable. Audio and microphone
redirection were opt-in but had not been verified with an RDS server. RemoteApp
launch still required a server-published alias. RSA-AES and unsupported VeNCrypt
subtypes were unavailable.

Download `FjarrConnect-0.2.23-macOS-arm64.zip` for Apple Silicon or
`FjarrConnect-0.2.23-macOS-x86_64.zip` for Intel. Each app contains only its target
architecture and requires macOS 14 or later. `SHA256SUMS.txt` contains both download
checksums.

The apps are ad-hoc signed, not Developer ID signed or notarized. macOS may require
approval in System Settings → Privacy & Security on first launch.
