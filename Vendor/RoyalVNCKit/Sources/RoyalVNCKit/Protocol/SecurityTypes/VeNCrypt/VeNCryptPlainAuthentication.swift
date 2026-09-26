#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension VNCProtocol {
	/// Username/password authentication sent only after the VeNCrypt TLS stream
	/// has been established and its X.509 server certificate has been validated.
	struct VeNCryptPlainAuthentication {
		static let authenticationType = VNCAuthenticationType.veNCryptPlain
	}
}

extension VNCProtocol.VeNCryptPlainAuthentication {
	static func send(connection: NetworkConnectionWriting,
				 credential: VNCUsernamePasswordCredential) async throws {
		let username = Data(credential.username.utf8)
		let password = Data(credential.password.utf8)
		guard let usernameLength = UInt32(exactly: username.count),
			  let passwordLength = UInt32(exactly: password.count) else {
			throw VNCError.protocol(.invalidData)
		}

		var packet = Data(capacity: 8 + username.count + password.count)
		packet.append(usernameLength, bigEndian: true)
		packet.append(passwordLength, bigEndian: true)
		packet.append(username)
		packet.append(password)
		try await connection.write(data: packet)
	}
}
