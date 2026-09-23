import XCTest
@testable import FjarrConnect

final class ConnectionOptionsTests: XCTestCase {
    func testMacScreenSharingRequiresAUsernameWhileStandardVNCDoesNot() throws {
        var macProfile = ConnectionProfile(name: "Mac", host: "mac.local",
                                           usesMacScreenSharingAuthentication: true)
        XCTAssertFalse(macProfile.isValid)
        macProfile.username = "daniel"
        XCTAssertTrue(macProfile.isValid)
        let restored = try JSONDecoder().decode(ConnectionProfile.self,
            from: JSONEncoder().encode(macProfile))
        XCTAssertTrue(restored.usesMacScreenSharingAuthentication)

        let standardProfile = ConnectionProfile(name: "VNC", host: "vnc.local")
        XCTAssertTrue(standardProfile.isValid)
        XCTAssertFalse(standardProfile.usesMacScreenSharingAuthentication)
    }

    func testVNCAuthenticationModesRequireUsernameOnlyForMacScreenSharing() {
        var profile = ConnectionProfile(name: "Mac", host: "mac.local")
        profile.usesMacScreenSharingAuthentication = true
        XCTAssertFalse(profile.isValid)
        profile.username = "   "
        XCTAssertFalse(profile.isValid)
        profile.username = "account"
        XCTAssertTrue(profile.isValid)
        profile.usesMacScreenSharingAuthentication = false
        profile.username = nil
        XCTAssertTrue(profile.isValid)
    }

    func testMacVNCAuthenticationCannotBeChangedToUsernameOptionalAtSignIn() {
        let macProfile = ConnectionProfile(name: "Mac", host: "mac.local", username: "account",
                                           usesMacScreenSharingAuthentication: true)
        let macCredentials = CredentialsView(profile: macProfile, saved: false) { _, _, _, _ in }
        XCTAssertFalse(macCredentials.allowsVNCAuthenticationModeSelection)
        XCTAssertTrue(macCredentials.requiresVNCUsername)

        let standardProfile = ConnectionProfile(name: "VNC", host: "vnc.local")
        let standardCredentials = CredentialsView(profile: standardProfile, saved: false) { _, _, _, _ in }
        XCTAssertTrue(standardCredentials.allowsVNCAuthenticationModeSelection)
        XCTAssertFalse(standardCredentials.requiresVNCUsername)
    }

    func testGraphicalSessionDropsPreserveLocalFilesForSFTPQueue() throws {
        let first = URL(fileURLWithPath: "/tmp/first.txt")
        let second = URL(fileURLWithPath: "/tmp/second.txt")

        for transport in [RemoteTransport.vnc, .rdp, .remoteApp] {
            XCTAssertEqual(SessionFileDropPolicy.acceptedURLs([first, second], for: transport), [first, second])
        }
    }

    func testNonGraphicalOrNonLocalDropPayloadsAreRejectedAsAWhole() throws {
        let local = URL(fileURLWithPath: "/tmp/upload.txt")
        let remote = try XCTUnwrap(URL(string: "https://example.invalid/upload.txt"))

        for transport in [RemoteTransport.ssh, .sftp] {
            XCTAssertNil(SessionFileDropPolicy.acceptedURLs([local], for: transport))
        }
        XCTAssertNil(SessionFileDropPolicy.acceptedURLs([], for: .vnc))
        XCTAssertNil(SessionFileDropPolicy.acceptedURLs([remote], for: .rdp))
        XCTAssertNil(SessionFileDropPolicy.acceptedURLs([local, remote], for: .vnc))
    }

    func testLegacyProfilesRetainDefaultsAndAdvancedSettingsRoundTrip() throws {
        let old = Data(#"{"id":"11111111-1111-1111-1111-111111111111","name":"Old","transport":"rdp","host":"desktop.local","port":3389,"rdp":{"gatewayHost":"gateway.local"}}"#.utf8)
        var profile = try JSONDecoder().decode(ConnectionProfile.self, from: old)
        XCTAssertTrue(profile.sharesClipboard)
        XCTAssertNil(profile.ssh)
        XCTAssertTrue(profile.rdp?.resizesRemoteDesktop ?? false)
        profile.ssh = SSHOptions(host: "files.local", port: 2222, username: "files", identityFile: "/tmp/test key",
                                 jumpHost: "jump.local", jumpUsername: "jump", startDirectory: "/srv/data")
        profile.rdp = RDPOptions(gatewayHost: "gateway.local", gatewayPort: 4443, gatewayUsername: "gateway-user", sharedFolders: ["/tmp/shared folder"])
        profile.links = HostLinks(smb: "smb://files.local/share", web: "https://desktop.local/admin")
        profile.clipboardEnabled = false
        XCTAssertTrue(profile.isValid)
        let data = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(ConnectionProfile.self, from: data), profile)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("password"))
        XCTAssertEqual(profile.fileProfile.host, "files.local")
        XCTAssertEqual(profile.fileProfile.port, 2222)
        XCTAssertEqual(profile.fileProfile.username, "files")
        XCTAssertEqual(profile.fileProfile.transport, .sftp)
    }

    func testSSHIdentityFileIsStoredAndAppliedPerProfile() throws {
        var first = ConnectionProfile(name: "Build host", transport: .ssh, host: "build.local", username: "builder")
        first.ssh = SSHOptions(identityFile: "/Users/test/.ssh/build_ed25519")
        var second = ConnectionProfile(name: "Git host", transport: .ssh, host: "git.local", username: "git")
        second.ssh = SSHOptions(identityFile: "/Users/test/.ssh/git_ed25519")

        let firstArguments = SSHArguments.connection(first)
        let secondArguments = SSHArguments.connection(second)
        XCTAssertEqual(firstArguments.suffix(2).first, "-i")
        XCTAssertEqual(firstArguments.suffix(1).first, "/Users/test/.ssh/build_ed25519")
        XCTAssertEqual(secondArguments.suffix(2).first, "-i")
        XCTAssertEqual(secondArguments.suffix(1).first, "/Users/test/.ssh/git_ed25519")

        let data = try JSONEncoder().encode([first, second])
        let restored = try JSONDecoder().decode([ConnectionProfile].self, from: data)
        XCTAssertEqual(restored.map { $0.ssh?.identityFile }, [first.ssh?.identityFile, second.ssh?.identityFile])
    }

    func testJumpHostsAndForwardingCannotInjectShellSyntax() {
        for host in ["jump;id", "jump$(id)", "jump`id`", "jump host", "-oProxyCommand=id", "jump%0a"] {
            XCTAssertFalse(SSHOptions(jumpHost: host).isValid, host)
        }
        XCTAssertFalse(SSHOptions(jumpHost: "jump.local", jumpUsername: "user;id").isValid)
        var profile = ConnectionProfile(name: "IPv6", transport: .ssh, host: "::1")
        profile.ssh = SSHOptions(jumpHost: "2001:db8::1", jumpPort: 2222, jumpUsername: "user",
            forwards: [SSHForward(direction: .local, listenPort: 8080, destinationHost: "::1", destinationPort: 80),
                       SSHForward(direction: .dynamic, listenPort: 1080)])
        let args = SSHArguments.make(profile)
        XCTAssertTrue(args.contains("user@[2001:db8::1]:2222"))
        XCTAssertTrue(args.contains("127.0.0.1:8080:[::1]:80"))
        XCTAssertTrue(args.contains("127.0.0.1:1080"))
        XCTAssertTrue(args.contains("ExitOnForwardFailure=yes"))
    }

    func testSSHKeepAliveDefaultsOnAndCanBeDisabledPerProfile() throws {
        let legacy = try JSONDecoder().decode(SSHOptions.self, from: Data("{}".utf8))
        XCTAssertTrue(legacy.usesKeepAlive)
        var profile = ConnectionProfile(name: "SSH", transport: .ssh, host: "host")
        XCTAssertTrue(SSHArguments.make(profile).contains("ServerAliveInterval=30"))
        XCTAssertTrue(SSHArguments.make(profile).contains("ServerAliveCountMax=3"))
        profile.ssh = SSHOptions(keepAlive: false)
        let arguments = SSHArguments.make(profile)
        XCTAssertFalse(arguments.contains("ServerAliveInterval=30"))
        XCTAssertFalse(arguments.contains("ServerAliveCountMax=3"))
    }

    func testServiceLinksRejectCredentialsAndUnexpectedSchemes() {
        for value in ["http://host", "https://user:secret@host", "https://host:0", "https://host:65536", "javascript:alert(1)"] {
            XCTAssertNil(HostLinks.url(value, scheme: "https"), value)
        }
        XCTAssertNil(HostLinks.url("smb://user@host/share", scheme: "smb"))
        XCTAssertNil(HostLinks.url("smb://host/share?password=sample", scheme: "smb"))
        XCTAssertEqual(ConnectionURI.profile(from: "sftp://user@host:2222")?.transport, .sftp)
    }

    func testGatewayArgumentsEscapeValuesAndRespectClipboardAndFolderChoices() throws {
        var profile = ConnectionProfile(name: "Desktop", transport: .rdp, host: "desktop.local")
        profile.rdp = RDPOptions(gatewayHost: "::1", gatewayUsername: "EXAMPLE\\user,name", sharedFolders: ["/tmp/shared folder"])
        profile.clipboardEnabled = false
        let input = try XCTUnwrap(RDPArguments.input(profile: profile, password: nil, gatewayPassword: "example,with\\punctuation"))
        let text = String(decoding: input, as: UTF8.self)
        XCTAssertTrue(text.contains("/gateway:g:[::1]:443,u:EXAMPLE\\\\user\\,name,p:example\\,with\\\\punctuation\n"))
        XCTAssertTrue(text.contains("-clipboard\n"))
        XCTAssertTrue(text.contains("/drive:Shared1,/tmp/shared folder\n"))
        XCTAssertNil(RDPArguments.input(profile: profile, password: nil, gatewayPassword: "sample\n/cert:ignore"))
        profile.rdp?.sharedFolders = ["/tmp/ambiguous,path"]
        XCTAssertFalse(profile.isValid)
    }

    func testRDPDynamicResolutionDefaultsToEnabledAndCanBeDisabled() throws {
        var profile = ConnectionProfile(name: "Desktop", transport: .rdp, host: "desktop.local")
        profile.rdp = RDPOptions()
        XCTAssertTrue(profile.rdp?.resizesRemoteDesktop ?? false)
        XCTAssertTrue(String(decoding: try XCTUnwrap(RDPArguments.input(profile: profile, password: nil)), as: UTF8.self).contains("/dynamic-resolution\n"))
        profile.rdp?.dynamicResolution = false
        XCTAssertFalse(profile.rdp?.resizesRemoteDesktop ?? true)
        XCTAssertFalse(String(decoding: try XCTUnwrap(RDPArguments.input(profile: profile, password: nil)), as: UTF8.self).contains("/dynamic-resolution\n"))
    }

    func testRDPKeyboardLayoutCanBeSelectedOrDetectedFromMacInputSource() throws {
        let automaticMappings: [(String, UInt32)] = [
            ("com.apple.keylayout.Swedish-Pro", 0x0000041D),
            ("com.apple.keylayout.USInternational-PC", 0x00000409),
            ("com.apple.keylayout.German", 0x00000407),
            ("com.apple.keylayout.French", 0x0000040C),
            ("com.apple.keylayout.Danish", 0x00000406),
            ("com.apple.keylayout.Norwegian", 0x00000414),
            ("com.apple.keylayout.Finnish", 0x0000040B),
            ("com.apple.keylayout.Spanish-ISO", 0x0000040A),
            ("com.apple.keylayout.Italian", 0x00000410)
        ]
        for (source, windowsID) in automaticMappings {
            XCTAssertEqual(RDPKeyboardLayout.resolvedWindowsLayoutID(
                selection: RDPKeyboardLayout.automatic.rawValue,
                inputSourceID: source), windowsID, source)
        }
        XCTAssertNil(RDPKeyboardLayout.resolvedWindowsLayoutID(
            selection: RDPKeyboardLayout.automatic.rawValue,
            inputSourceID: "com.apple.keylayout.Unsupported"))
        for layout in RDPKeyboardLayout.allCases where layout != .automatic {
            XCTAssertEqual(RDPKeyboardLayout.resolvedWindowsLayoutID(
                selection: layout.rawValue, inputSourceID: "com.apple.keylayout.Unsupported"), layout.windowsLayoutID)
        }

        var profile = ConnectionProfile(name: "Desktop", transport: .rdp, host: "desktop.local")
        let swedish = String(decoding: try XCTUnwrap(RDPArguments.input(
            profile: profile, password: nil, keyboardLayoutIdentifier: 0x0000041D)), as: UTF8.self)
        XCTAssertTrue(swedish.contains("/kbd:layout:0x0000041D\n"))
        let automaticFallback = String(decoding: try XCTUnwrap(RDPArguments.input(
            profile: profile, password: nil, keyboardLayoutIdentifier: nil)), as: UTF8.self)
        XCTAssertFalse(automaticFallback.contains("/kbd:layout:"))

        profile.transport = .remoteApp
        profile.rdp = RDPOptions(remoteApp: "||notepad")
        let remoteApp = String(decoding: try XCTUnwrap(RDPArguments.input(
            profile: profile, password: nil, keyboardLayoutIdentifier: 0x00000409)), as: UTF8.self)
        XCTAssertTrue(remoteApp.contains("/kbd:layout:0x00000409\n"))
    }

    func testRDPDeviceRedirectionAndRemoteAppAreExplicitPerProfile() throws {
        var profile = ConnectionProfile(name: "App", transport: .rdp, host: "desktop.local")
        let defaults = String(decoding: try XCTUnwrap(RDPArguments.input(profile: profile, password: nil)), as: UTF8.self)
        for flag in ["/printer", "/smartcard", "/sound", "/microphone", "/app:"] {
            XCTAssertFalse(defaults.contains(flag), flag)
        }
        let arguments = String(decoding: try XCTUnwrap(RDPArguments.input(profile: profile, password: nil)), as: UTF8.self)
        for flag in ["/sound", "/microphone"] {
            XCTAssertFalse(arguments.contains(flag), flag)
        }
        XCTAssertTrue(arguments.contains("/dynamic-resolution\n"))
        XCTAssertFalse(arguments.contains("/printer\n"))
        XCTAssertFalse(arguments.contains("/smartcard\n"))
        profile.transport = .remoteApp
        profile.rdp = RDPOptions(remoteApp: "||wordpad")
        let remoteApp = String(decoding: try XCTUnwrap(RDPArguments.input(profile: profile, password: nil)), as: UTF8.self)
        XCTAssertTrue(remoteApp.contains("/app:||wordpad\n"))
        XCTAssertFalse(remoteApp.contains("/dynamic-resolution\n"))
        profile.rdp?.remoteApp = "wordpad\n/cert:ignore"
        XCTAssertFalse(profile.isValid)
    }

    func testLegacyAudioPreferencesAreIgnoredUntilTheyCanBeVerifiedOnMacOS() throws {
        let legacy = Data(#"{"id":"11111111-1111-1111-1111-111111111111","name":"Old RDP","transport":"rdp","host":"desktop.local","port":3389,"rdp":{"audioRedirection":true,"microphoneRedirection":true}}"#.utf8)
        let profile = try JSONDecoder().decode(ConnectionProfile.self, from: legacy)
        let arguments = String(decoding: try XCTUnwrap(RDPArguments.input(profile: profile, password: nil)), as: UTF8.self)
        XCTAssertFalse(arguments.contains("/sound"))
        XCTAssertFalse(arguments.contains("/microphone"))
    }

    func testRDPNetworkProfileIsOptInAndEscapesNoUserValues() throws {
        var profile = ConnectionProfile(name: "Office", transport: .rdp, host: "desktop.local")
        profile.rdp = RDPOptions()
        var arguments = String(decoding: try XCTUnwrap(RDPArguments.input(profile: profile, password: nil)), as: UTF8.self)
        XCTAssertFalse(arguments.contains("/network:"))
        profile.rdp?.networkProfile = .slow
        arguments = String(decoding: try XCTUnwrap(RDPArguments.input(profile: profile, password: nil)), as: UTF8.self)
        XCTAssertTrue(arguments.contains("/network:modem\n"))
        profile.rdp?.networkProfile = .balanced
        arguments = String(decoding: try XCTUnwrap(RDPArguments.input(profile: profile, password: nil)), as: UTF8.self)
        XCTAssertTrue(arguments.contains("/network:broadband-high\n"))
    }

    func testLoginAndGatewayCredentialsRemainSeparateAndAreRemovedTogether() throws {
        let id = UUID()
        defer {
            try? KeychainStore.deletePassword(for: id)
            try? KeychainStore.deletePassword(for: id, purpose: .gateway)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(fileURL: directory.appendingPathComponent("profiles.json"))
        let profile = ConnectionProfile(id: id, name: "Test", transport: .rdp, host: "desktop.local")
        try store.save(profile, password: "test-login-value", gatewayPassword: "test-gateway-value")
        XCTAssertEqual(try KeychainStore.password(for: id), "test-login-value")
        XCTAssertEqual(try KeychainStore.password(for: id, purpose: .gateway), "test-gateway-value")
        try store.save(profile, password: nil, gatewayPassword: "updated-test-gateway")
        XCTAssertEqual(try KeychainStore.password(for: id), "test-login-value")
        XCTAssertEqual(try KeychainStore.password(for: id, purpose: .gateway), "updated-test-gateway")
        try store.remove(profile)
        XCTAssertNil(try KeychainStore.password(for: id))
        XCTAssertNil(try KeychainStore.password(for: id, purpose: .gateway))
    }
}
