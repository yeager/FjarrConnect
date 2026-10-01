Unreleased

- Release ordinary VNC keys immediately and send autorepeat as balanced press/release
  pairs, so a dropped physical key-up cannot leave a key repeating on a remote Mac.
- Import RDP gateway and RemoteApp settings from `.rdp` files while continuing to ignore
  desktop and gateway password fields.
- Pin FreeRDP 3.32.1 and verify it against a GNOME Remote Desktop server: NLA Extended
  (`0x08`) authenticated, delivered a desktop frame and rendered the native view in a
  macOS window. The full SwiftUI app flow and live RDP
  file transfer remain unverified; x86_64 was not tested on physical Intel hardware.
- Show FreeRDP's measured RDP round-trip time when the server provides a sample;
  keep packet loss unavailable instead of estimating it from TCP.
- Show the negotiated VNC security type and verified VeNCrypt TLS certificate name
  and SHA-256 fingerprint in the session health menu.

FjärrConnect 0.2.33

- Explain when the embedded RDP component is missing, built for the wrong Mac
  architecture, incompatible with the app, or rejected by macOS.
- Forward Swedish right Option+2 as `@` in a focused VNC session, including when
  AppKit routes the key equivalent through the window instead of the framebuffer.
- Add regression coverage for rapid VNC input, repeated characters, and key release
  after focus changes.
- Keep Apple Silicon and Intel downloads as separate architecture-specific archives.

Known limitation: live testing against the Mac Screen Sharing host was unavailable
for this release because the server stopped responding after authentication. Local
VNC protocol and keyboard tests pass.

At the time of the 0.2.33 release, an authenticated desktop session and RDP file
clipboard had not been verified in that build. The current checkout's FreeRDP 3.32.1
native-view test authenticated to GNOME Remote Desktop, selected NLA Extended and
displayed a desktop frame. The x86_64 runtime has not been tested on an Intel Mac, and
live RDP file transfer remains unverified.

Download `FjarrConnect-0.2.33-macOS-arm64.zip` for Apple Silicon or
`FjarrConnect-0.2.33-macOS-x86_64.zip` for Intel. Each app contains only its target
architecture and requires macOS 14 or later. `SHA256SUMS.txt` contains both download
checksums.

The apps are ad-hoc signed, not Developer ID signed or notarized. macOS may require
approval in System Settings → Privacy & Security on first launch.

---

FjärrConnect 0.2.31

- Forward Command+2 in a focused VNC session before macOS handles it as an
  application keyboard shortcut.
- Show the FreeRDP connection phase after an RDP failure and include only recognized
  phase names in an optional diagnostic report. Distinguish failed RDP security negotiation
  from an unreachable host. Credentials and backend logs remain excluded.
- Add bidirectional per-profile RDP file clipboard transfer. It is off by default and can
  be enabled in Advanced options. File transfer requires a Windows RDP server that advertises
  clipboard file support; text and image clipboard continue to work independently. Local
  protocol tests pass, but live Windows integration remains unverified. Received files are
  staged in a private temporary folder; while the owning session is active, replaced
  clipboard files are removed when the clipboard changes. Stale copies older than
  24 hours are removed on app launch.
  Shared folders and SFTP remain the recommended file flows.
- Retry one initial Mac Screen Sharing connection error or silent timeout when a password
  is provided. Authentication failures are not retried. Keep session tabs at the top of the
  window when a connection fails.
- Decode RFB, XCursor and Apple's cached alpha cursor shapes. Some Mac Screen Sharing servers
  do not send cursor-shape updates; the local arrow stays visible until a server shape arrives.
- Release held RDP keys and mouse buttons when the app or its window loses focus, even when
  clipboard synchronization is disabled.
- Bound queued RDP key repeats during a delayed input loop and reserve queue space for
  key-up and mouse-up events, preventing a lost release from leaving remote input stuck.
- End an RDP connection attempt after 15 seconds without a response, show a localized
  timeout message, and keep the session controls available for retry.
- Release held VNC keys when the app or its window loses focus, including after autorepeat,
  so a missed key-up does not leave a key repeating on the remote computer.

---

FjärrConnect 0.2.30

- Check GitHub Releases for a newer stable version at app launch. Automatic checks
  can be disabled completely in Settings; when enabled, checks open the release
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

Download `FjarrConnect-0.2.30-macOS-arm64.zip` for Apple Silicon or
`FjarrConnect-0.2.30-macOS-x86_64.zip` for Intel. Each app contains only its target
architecture and requires macOS 14 or later. `SHA256SUMS.txt` contains both download
checksums.

The apps are ad-hoc signed, not Developer ID signed or notarized. macOS may require
approval in System Settings → Privacy & Security on first launch.

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

Known limitations: RDP file clipboard is available in both directions as a per-profile
opt-in but has not been verified against a real Windows server; multi-monitor output is not enabled. RDP
audio, microphone, printer and smart-card redirection are unavailable.
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
