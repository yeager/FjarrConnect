import SwiftUI

/// Shown by backends whose native library isn't wired in yet (SSH, RDP).
/// Replace with the real terminal/framebuffer view when integrating.
struct BackendPlaceholderView: View {
    let transport: RemoteTransport
    let host: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: transport == .ssh ? "terminal" : "display")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(LocalizedStringKey(transport.displayNameKey))
                .font(.headline)
            Text(host)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("backend.pending.hint")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
