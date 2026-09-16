FjärrConnect 0.2.3 — VNC desktop resizing fix.

- Fixed a frozen VNC display after the server changes its desktop resolution. The displayed AppKit framebuffer is now replaced when the remote framebuffer changes.
- Preserved keyboard focus and the remote cursor through a resolution change.
- Added an integration test that changes the RFB desktop size and pixel content, then verifies the displayed image, focus and cursor. The test reproduced the old failures before the fix.
- Includes the black-screen guidance and detailed RDP failure messages introduced in 0.2.2.

Download `FjarrConnect-0.2.3-macOS-arm64.zip` for Apple Silicon or `FjarrConnect-0.2.3-macOS-x86_64.zip` for Intel. Unzip and move FjärrConnect to Applications. Saved profiles and Keychain entries are retained. `SHA256SUMS.txt` contains the download checksums.

macOS must authorize screen capture and input on the remote Mac. If its sharing agent is denied those permissions, enable Remote Management locally in System Settings → General → Sharing and approve the OS prompt. A client update cannot grant those remote permissions.

The apps are ad-hoc signed, not Developer ID signed or notarized. macOS may require approval in System Settings → Privacy & Security on first launch.
