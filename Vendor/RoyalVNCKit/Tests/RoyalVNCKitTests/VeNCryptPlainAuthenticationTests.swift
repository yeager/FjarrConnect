import Foundation
import XCTest

@testable import RoyalVNCKit

final class VeNCryptPlainAuthenticationTests: XCTestCase {
	func testWritesUTF8UsernameAndPasswordWithinTheVerifiedTLSStream() async throws {
		let connection = VeNCryptPlainWritingConnection()
		let credential = VNCUsernamePasswordCredential(username: "användare", password: "lösenord🔐")

		try await VNCProtocol.VeNCryptPlainAuthentication.send(connection: connection,
													 credential: credential)

		let username = Data("användare".utf8)
		let password = Data("lösenord🔐".utf8)
		var expected = Data()
		expected.append(UInt32(username.count), bigEndian: true)
		expected.append(UInt32(password.count), bigEndian: true)
		expected.append(username)
		expected.append(password)
		XCTAssertEqual(connection.data, expected)
	}

	func testAuthenticationTypeRequiresUsernameAndPassword() {
		XCTAssertTrue(VNCAuthenticationType.veNCryptPlain.requiresUsername)
		XCTAssertTrue(VNCAuthenticationType.veNCryptPlain.requiresPassword)
	}
}

private final class VeNCryptPlainWritingConnection: NetworkConnectionWriting {
	private(set) var data = Data()

	func write(data: Data) async throws {
		self.data.append(data)
	}
}
