import XCTest
@testable import FjarrConnect

final class ConnectionOptionsTests: XCTestCase {
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

    func testRDPDeviceRedirectionAndRemoteAppAreExplicitPerProfile() throws {
        var profile = ConnectionProfile(name: "App", transport: .rdp, host: "desktop.local")
        let defaults = String(decoding: try XCTUnwrap(RDPArguments.input(profile: profile, password: nil)), as: UTF8.self)
        for flag in ["/printer", "/smartcard", "/sound", "/microphone", "/app:"] {
            XCTAssertFalse(defaults.contains(flag), flag)
        }
        profile.rdp = RDPOptions(audioRedirection: true, microphoneRedirection: true)
        let arguments = String(decoding: try XCTUnwrap(RDPArguments.input(profile: profile, password: nil)), as: UTF8.self)
        for flag in ["/sound:sys:mac", "/microphone:sys:mac"] {
            XCTAssertTrue(arguments.contains(flag + "\n"), flag)
        }
        XCTAssertTrue(arguments.contains("/dynamic-resolution\n"))
        XCTAssertFalse(arguments.contains("/printer\n"))
        XCTAssertFalse(arguments.contains("/smartcard\n"))
        profile.transport = .remoteApp
        profile.rdp?.remoteApp = "||wordpad"
        let remoteApp = String(decoding: try XCTUnwrap(RDPArguments.input(profile: profile, password: nil)), as: UTF8.self)
        XCTAssertTrue(remoteApp.contains("/app:||wordpad\n"))
        XCTAssertFalse(remoteApp.contains("/dynamic-resolution\n"))
        profile.rdp?.remoteApp = "wordpad\n/cert:ignore"
        XCTAssertFalse(profile.isValid)
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
