import SwiftUI
import RoyalVNCKit

/// VNC/RFB backend built on RoyalVNCKit (MIT). RoyalVNCKit implements the standard
/// VNC auth and Apple Remote Desktop auth. The remote Mac must grant the account
/// screen access and authorize its sharing agent to capture the screen.
///
/// RoyalVNCKit's `VNCCAFramebufferView` both renders the framebuffer and forwards
/// local mouse/keyboard events to the server, so we don't inject input by hand.
final class VNCRemoteSession: NSObject, RemoteSession, VNCConnectionDelegate, VNCClipboardDelegate, SessionRecordingSource, SessionHealthProviding {
    let profile: ConnectionProfile
    private var password: String?
    private var connectionDeadline: DispatchWorkItem?
    private var credentialFailure: String?
    private var requestedAuthentication: VNCAuthenticationType?
    private var frameCheck: DispatchWorkItem?
    private var active = false
    private var clipboardForeground = false
    private var clipboardBaseline = 0

    @Published private(set) var status: SessionStatus = .idle
    @Published private(set) var notice: String?
    @Published private(set) var fileTransferAvailable = false
    @Published private(set) var fileUploadAvailable = false
    @Published private(set) var isUploadingFile = false
    @Published private(set) var remoteFiles: [VNCRemoteFile] = []
    @Published private(set) var fileListRevision = 0
    @Published private(set) var isLoadingRemoteFiles = false
    @Published private(set) var remoteDirectory = "/"
    @Published private(set) var fileTransferNotice: String?

    private var connection: VNCConnection?
    private let logger = VNCPrintLogger()
    private var downloadDestination: URL?
    private var downloadSize: UInt64 = 0
    private var downloadHandle: FileHandle?
    private var downloadTemporaryURL: URL?
    private static let maximumFileTransferBytes: UInt64 = 256 * 1024 * 1024

    /// Cached per remote framebuffer; a server resize replaces both buffer and view.
    private var framebufferView: VNCCAFramebufferView?

    var recordingView: NSView? { framebufferView }

    init(profile: ConnectionProfile, password: String?) {
        self.profile = profile
        self.password = password
        super.init()
    }

    // MARK: RemoteSession

    func start() {
        guard connection == nil else { return }
        credentialFailure = nil
        requestedAuthentication = nil
        notice = nil
        let settings = VNCConnection.Settings(
            isDebugLoggingEnabled: false,
            hostname: profile.host,
            port: profile.port,
            isShared: true,
            isScalingEnabled: true,
            useDisplayLink: true,
            inputMode: .forwardKeyboardShortcutsIfNotInUseLocally,
            isClipboardRedirectionEnabled: profile.sharesClipboard,
            colorDepth: .depth24Bit,
            frameEncodings: .default
        )

        let connection = VNCConnection(settings: settings, logger: logger)
        // VeNCrypt and ARD authentication remain preferred by RoyalVNCKit. Tight
        // is selected only when neither stronger mode is offered, so its
        // advertised file-transfer extension can be discovered when available.
        connection.prefersTightSecurityForFileTransfer = true
        connection.fileTransferHandler = { [weak self, weak connection] event in
            guard let self, let connection, self.connection === connection else { return }
            self.handleFileTransfer(event)
        }
        connection.delegate = self
        connection.clipboardDelegate = self
        self.connection = connection
        clipboardBaseline = NSPasteboard.general.changeCount

        setStatus(.connecting)
        connection.connect()
        let deadline = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection, self.connection === connection,
                  self.status == .connecting else { return }
            self.stop()
            self.status = .disconnected(reason: Self.connectionTimeoutMessage(authentication: self.requestedAuthentication))
        }
        connectionDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: deadline)
    }

    func stop() {
        frameCheck?.cancel()
        frameCheck = nil
        notice = nil
        fileTransferAvailable = false
        fileUploadAvailable = false
        isUploadingFile = false
        remoteFiles = []
        isLoadingRemoteFiles = false
        fileTransferNotice = nil
        downloadDestination = nil
        try? downloadHandle?.close()
        downloadHandle = nil
        if let downloadTemporaryURL { try? FileManager.default.removeItem(at: downloadTemporaryURL) }
        downloadTemporaryURL = nil
        connectionDeadline?.cancel()
        connectionDeadline = nil
        password = nil
        let old = connection
        connection = nil
        old?.delegate = nil
        old?.clipboardDelegate = nil
        old?.disconnect()
        framebufferView = nil
        status = .disconnected(reason: nil)
    }

    func setActive(_ active: Bool) {
        self.active = active
        clipboardBaseline = NSPasteboard.general.changeCount
        connection?.resetClipboardSynchronization()
    }

    private func acceptsClipboard(_ source: VNCConnection) -> Bool {
        let foreground = active && NSApp.isActive && framebufferView?.window?.isKeyWindow == true
        if foreground != clipboardForeground {
            clipboardForeground = foreground
            clipboardBaseline = NSPasteboard.general.changeCount
            source.resetClipboardSynchronization()
        }
        return connection === source && profile.sharesClipboard && foreground
    }

    func connectionShouldSendClipboard(_ connection: VNCConnection) -> Bool {
        acceptsClipboard(connection) && NSPasteboard.general.changeCount != clipboardBaseline
    }

    func connectionShouldReceiveClipboard(_ connection: VNCConnection) -> Bool {
        acceptsClipboard(connection)
    }

    func connection(_ connection: VNCConnection, didReceiveClipboardText text: String) {
        guard acceptsClipboard(connection) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        clipboardBaseline = NSPasteboard.general.changeCount
    }

    func connection(_ connection: VNCConnection, didReceiveClipboardImageData imageData: Data) {
        guard acceptsClipboard(connection),
              let image = VNCClipboardImageCodec.decode(imageData),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
        clipboardBaseline = NSPasteboard.general.changeCount
    }

    func makeScreenView() -> AnyView {
        if let view = framebufferView {
            return AnyView(FramebufferViewWrapper(nsView: view, shouldFocus: status == .connected))
        } else {
            return AnyView(
                VStack(spacing: 12) {
                    ProgressView()
                    Text(status.label).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
        }
    }

    // MARK: VNCConnectionDelegate

    func connection(_ connection: VNCConnection,
                    stateDidChange connectionState: VNCConnection.ConnectionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connection === connection else { return }
            switch connectionState.status {
            case .connecting: self.status = .connecting
            case .connected:
                self.connectionDeadline?.cancel()
                self.password = nil
                self.status = .connected
                self.fileTransferAvailable = connection.canDownloadFiles
                self.fileUploadAvailable = connection.canUploadFiles
                self.checkInitialImage(connection, after: 8)
            case .disconnecting: self.status = .disconnecting
            case .disconnected:
                self.fileTransferAvailable = false
                self.fileUploadAvailable = false
                if self.isUploadingFile {
                    self.isUploadingFile = false
                    self.fileTransferNotice = NSLocalizedString("vnc.files.uploadFailed", comment: "")
                }
                self.remoteFiles = []
                self.frameCheck?.cancel()
                self.notice = nil
                self.connectionDeadline?.cancel()
                self.password = nil
                // SDK error strings are diagnostic implementation details and may
                // be English or expose server-specific text. Keep the endpoint
                // visible while giving every locale a safe, useful next step.
                let reason = self.credentialFailure ?? connectionState.error.map { error in
                    Self.connectionFailureMessage(host: self.profile.host, port: self.profile.port, error: error)
                }
                self.status = .disconnected(reason: reason)
            }
        }
    }

    func browseRemoteFiles(_ directory: String) {
        guard fileTransferAvailable, status == .connected,
              directory.hasPrefix("/"), !directory.split(separator: "/").contains("..") else { return }
        do {
            remoteDirectory = directory
            remoteFiles = []
            isLoadingRemoteFiles = true
            try connection?.requestFileList(directory: directory)
            fileTransferNotice = nil
        } catch {
            isLoadingRemoteFiles = false
            fileTransferNotice = NSLocalizedString("vnc.files.failed", comment: "")
        }
    }

    func downloadRemoteFile(_ file: VNCRemoteFile, to destination: URL) {
        guard fileTransferAvailable, status == .connected, !file.isDirectory,
              file.size <= Self.maximumFileTransferBytes else {
            fileTransferNotice = NSLocalizedString("vnc.files.downloadFailed", comment: "")
            return
        }
        let path = remoteDirectory == "/" ? "/\(file.name)" : "\(remoteDirectory)/\(file.name)"
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).fjarr-partial")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: temporary) else {
            fileTransferNotice = NSLocalizedString("vnc.files.downloadFailed", comment: "")
            return
        }
        downloadDestination = destination
        downloadTemporaryURL = temporary
        downloadSize = file.size
        downloadHandle = handle
        do {
            try connection?.requestFileDownload(path: path)
            fileTransferNotice = NSLocalizedString("vnc.files.downloading", comment: "")
        } catch {
            failFileTransfer()
            fileTransferNotice = NSLocalizedString("vnc.files.downloadFailed", comment: "")
        }
    }

    func uploadLocalFile(_ source: URL, overwrite: Bool = false) {
        guard fileUploadAvailable, !isUploadingFile, status == .connected,
              source.isFileURL,
              let connection,
              (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else {
            fileTransferNotice = NSLocalizedString("vnc.files.uploadFailed", comment: "")
            return
        }
        let name = source.lastPathComponent
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            fileTransferNotice = NSLocalizedString("vnc.files.uploadFailed", comment: "")
            return
        }
        if !overwrite, remoteFiles.contains(where: { $0.name == name }) {
            fileTransferNotice = NSLocalizedString("vnc.files.uploadExists", comment: "")
            return
        }
        let path = remoteDirectory == "/" ? "/\(name)" : "\(remoteDirectory)/\(name)"
        let accessGranted = source.startAccessingSecurityScopedResource()
        isUploadingFile = true
        fileTransferNotice = NSLocalizedString("vnc.files.uploading", comment: "")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { if accessGranted { source.stopAccessingSecurityScopedResource() } }
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let size = (attributes[.size] as? NSNumber)?.uint64Value,
                      size <= Self.maximumFileTransferBytes else {
                    throw VNCFileUploadError.invalidFile
                }
                let modificationDate = attributes[.modificationDate] as? Date ?? Date()
                let modificationTime = UInt32(max(0, min(Double(UInt32.max), modificationDate.timeIntervalSince1970)))
                let handle = try FileHandle(forReadingFrom: source)
                defer { try? handle.close() }
                try connection.requestFileUpload(path: path)
                var transferred: UInt64 = 0
                while let chunk = try handle.read(upToCount: 65_535), !chunk.isEmpty {
                    guard UInt64(chunk.count) <= size - min(transferred, size) else {
                        throw VNCFileUploadError.invalidFile
                    }
                    try connection.sendFileUploadData(chunk)
                    transferred += UInt64(chunk.count)
                }
                guard transferred == size else { throw VNCFileUploadError.invalidFile }
                try connection.finishFileUpload(modificationTime: modificationTime)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.connection === connection else { return }
                    self.isUploadingFile = false
                    self.fileTransferNotice = NSLocalizedString("vnc.files.uploadSent", comment: "")
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.connection === connection else { return }
                    self.isUploadingFile = false
                    self.fileTransferNotice = NSLocalizedString("vnc.files.uploadFailed", comment: "")
                }
            }
        }
    }

    private func handleFileTransfer(_ event: VNCFileTransferEvent) {
        switch event {
        case .fileList(let files):
            remoteFiles = files
            isLoadingRemoteFiles = false
            fileListRevision &+= 1
            fileTransferNotice = nil
        case .downloadData(let data):
            guard downloadDestination != nil,
                  let handle = downloadHandle,
                  let currentOffset = try? handle.offset(),
                  currentOffset <= Self.maximumFileTransferBytes,
                  UInt64(data.count) <= Self.maximumFileTransferBytes - currentOffset,
                  UInt64(data.count) <= downloadSize - min(currentOffset, downloadSize) else {
                failFileTransfer()
                return
            }
            do {
                try handle.write(contentsOf: data)
            } catch {
                failFileTransfer()
            }
        case .downloadFinished:
            guard let destination = downloadDestination, let temporary = downloadTemporaryURL,
                  let handle = downloadHandle, let currentOffset = try? handle.offset(),
                  currentOffset == downloadSize else {
                failFileTransfer()
                return
            }
            do {
                try handle.synchronize()
                try handle.close()
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                }
                fileTransferNotice = NSLocalizedString("vnc.files.downloadComplete", comment: "")
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                fileTransferNotice = NSLocalizedString("vnc.files.downloadFailed", comment: "")
            }
            clearDownloadState()
        case .failed:
            isLoadingRemoteFiles = false
            isUploadingFile = false
            failFileTransfer()
            fileTransferNotice = NSLocalizedString("vnc.files.failed", comment: "")
        @unknown default:
            isLoadingRemoteFiles = false
            isUploadingFile = false
            failFileTransfer()
            fileTransferNotice = NSLocalizedString("vnc.files.failed", comment: "")
        }
    }

    private func clearDownloadState() {
        downloadDestination = nil
        downloadTemporaryURL = nil
        downloadSize = 0
        try? downloadHandle?.close()
        downloadHandle = nil
    }

    private func failFileTransfer() {
        if let downloadTemporaryURL { try? FileManager.default.removeItem(at: downloadTemporaryURL) }
        clearDownloadState()
    }

    func connection(_ connection: VNCConnection,
                    credentialFor authenticationType: VNCAuthenticationType,
                    completion: @escaping ((any VNCCredential)?) -> Void) {
        // Credential checks run on the main queue with the session state.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connection === connection else { completion(nil); return }
            self.requestedAuthentication = authenticationType
            if authenticationType.requiresUsername,
               self.profile.username?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                self.credentialFailure = NSLocalizedString("vnc.usernameRequired", comment: "")
                completion(nil)
                return
            }
            self.provideCredential(for: authenticationType, completion: completion)
        }
    }

    private func provideCredential(for authenticationType: VNCAuthenticationType,
                                   completion: @escaping ((any VNCCredential)?) -> Void) {
        if authenticationType.requiresUsername, authenticationType.requiresPassword {
            completion(VNCUsernamePasswordCredential(username: profile.username ?? "",
                                                     password: password ?? ""))
        } else if authenticationType.requiresPassword {
            completion(VNCPasswordCredential(password: password ?? ""))
        } else {
            completion(nil)
        }
    }

    func connection(_ connection: VNCConnection,
                    didCreateFramebuffer framebuffer: VNCFramebuffer) {
        // Keep callbacks on this session so updates queued during a desktop resize
        // reach the replacement view instead of the detached framebuffer view.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connection === connection else { return }
            let size = CGSize(width: CGFloat(framebuffer.size.width),
                              height: CGFloat(framebuffer.size.height))
            let view = VNCCAFramebufferView(
                frame: CGRect(origin: .zero, size: size),
                framebuffer: framebuffer,
                connection: connection,
                connectionDelegate: self
            )
            if let cursor = self.framebufferView?.currentCursor {
                view.currentCursor = cursor
            }
            self.framebufferView = view
            connection.delegate = self
            self.objectWillChange.send()   // let the UI swap the placeholder for the screen
        }
    }

    func connection(_ connection: VNCConnection,
                    didResizeFramebuffer framebuffer: VNCFramebuffer) {
        self.connection(connection, didCreateFramebuffer: framebuffer)
    }

    func connection(_ connection: VNCConnection,
                    didUpdateFramebuffer framebuffer: VNCFramebuffer,
                    x: UInt16, y: UInt16, width: UInt16, height: UInt16) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connection === connection else { return }
            self.framebufferView?.connection(connection, didUpdateFramebuffer: framebuffer,
                                            x: x, y: y, width: width, height: height)
        }
    }

    func connection(_ connection: VNCConnection,
                    didUpdateCursor cursor: VNCCursor) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connection === connection else { return }
            self.framebufferView?.connection(connection, didUpdateCursor: cursor)
        }
    }

    // MARK: Helpers

    private func checkInitialImage(_ connection: VNCConnection, after delay: TimeInterval) {
        frameCheck?.cancel()
        let check = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection, self.connection === connection,
                  self.status == .connected else { return }
            if let image = connection.framebuffer?.cgImage {
                guard VNCFrameDiagnostics.isBlack(image) else { self.notice = nil; return }
                self.notice = NSLocalizedString("vnc.blackScreen", comment: "")
            } else {
                self.notice = NSLocalizedString("vnc.waitingForImage", comment: "")
            }
            // Clear the hint automatically if the server starts sending content.
            self.checkInitialImage(connection, after: 3)
        }
        frameCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: check)
    }

    private func setStatus(_ new: SessionStatus) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connection != nil else { return }
            self.status = new
        }
    }

    static func connectionFailureMessage(host: String, port: UInt16, error: Error? = nil) -> String {
        let explanation: String
        if let error,
           case VNCError.authentication(.clientCouldNotDecideOnSecurityType) = error {
            explanation = NSLocalizedString("vnc.unsupportedSecurity", comment: "")
        } else {
            explanation = NSLocalizedString("vnc.connectionFailed", comment: "")
        }

        return "VNC \(host):\(port)\n" + explanation
    }

    static func connectionTimeoutMessage(authentication: VNCAuthenticationType?) -> String {
        authentication == .appleRemoteDesktop
            ? NSLocalizedString("vnc.ardAuthenticationTimeout", comment: "")
            : NSLocalizedString("session.timeout", comment: "")
    }
}

private enum VNCFileUploadError: Error { case invalidFile }

/// Bridges the cached AppKit framebuffer view into SwiftUI.
private struct FramebufferViewWrapper: NSViewRepresentable {
    let nsView: VNCCAFramebufferView
    let shouldFocus: Bool
    func makeNSView(context: Context) -> FramebufferContainer {
        let container = FramebufferContainer(frame: nsView.frame)
        container.show(nsView)
        if shouldFocus { container.requestInitialFocus() }
        return container
    }
    func updateNSView(_ container: FramebufferContainer, context: Context) {
        container.show(nsView)
        if shouldFocus { container.requestInitialFocus() }
    }
}

/// SwiftUI retains the host while a server resize replaces its AppKit child.
private final class FramebufferContainer: NSView {
    private var framebufferView: VNCCAFramebufferView?
    private var requestedInitialFocus = false

    func show(_ view: VNCCAFramebufferView) {
        guard framebufferView !== view else { return }
        let restoreFocus = framebufferView != nil && window?.firstResponder === framebufferView
        framebufferView?.removeFromSuperview()
        framebufferView = view
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        if restoreFocus { window?.makeFirstResponder(view) }
    }

    func requestInitialFocus() {
        guard !requestedInitialFocus else { return }
        func focus(_ attempt: Int) {
            guard !self.requestedInitialFocus, let framebufferView = self.framebufferView else { return }
            guard let window = self.window else {
                if attempt < 5 { DispatchQueue.main.async { focus(attempt + 1) } }
                return
            }
            self.requestedInitialFocus = window.makeFirstResponder(framebufferView)
        }
        DispatchQueue.main.async { focus(0) }
    }
}
