FjärrConnect 0.2.2 — connection diagnostics and VNC rendering checks.

- RDP failures now show the destination, a useful network, sign-in, account or TLS explanation, and the client exit code. Raw backend logs and credentials are never displayed or persisted.
- VNC shows the server’s detailed failure reason and explains when Apple authentication requires a username.
- Password-authenticated VNC regression tests now verify actual pixels rendered by the app’s framebuffer view, not only a completed handshake.
- Documented the separate Observe/Control permissions required when a Mac uses Remote Management.
- Verified password-authenticated x11vnc rendering on a real Apple Silicon Mac.
- Added a hint when the server only sends a black screen or no initial image, including macOS sharing-permission guidance; it clears automatically when content arrives.
- Separate Apple Silicon and Intel apps remain fully bundled, including RoyalVNCKit and FreeRDP.
- The bundled ARM64 RDP client was exercised on a real Mac against a temporary xrdp/VNC desktop over TLS with certificate pinning. Windows NLA login remains dependent on an available Windows test server.

Download `FjarrConnect-0.2.2-macOS-arm64.zip` for Apple Silicon or `FjarrConnect-0.2.2-macOS-x86_64.zip` for Intel. Unzip and move FjärrConnect to Applications. Saved profiles and Keychain entries are retained. `SHA256SUMS.txt` contains the download checksums.

The apps are ad-hoc signed, not Developer ID signed or notarized. macOS may require approval in System Settings → Privacy & Security on first launch.
