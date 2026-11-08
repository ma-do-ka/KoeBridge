import Foundation

/// The feed and public verification key are part of the signed app bundle,
/// never learned from a downloaded JSON file or a user-writable preference.
public enum SignedUpdateConfiguration {
    public static let feedURL = "https://raw.githubusercontent.com/ma-do-ka/KoeBridge/main/docs/updates/appcast.xml"
    public static func isReady(publicKey: String?, feed: String?, verifiesArchive: Bool,
                               requiresSignedFeed: Bool, signatureExpiry: Double?) -> Bool {
        guard let publicKey, let bytes = Data(base64Encoded: publicKey),
              bytes.count == 32, bytes.contains(where: { $0 != 0 }),
              publicKey == bytes.base64EncodedString(), feed == feedURL,
              verifiesArchive, requiresSignedFeed, signatureExpiry == 0 else { return false }
        return true
    }
}
