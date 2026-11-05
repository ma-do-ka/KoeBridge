import Foundation

/// KoeBridge stable releases use numeric macOS bundle versions and a human
/// readable v1.0.1a / v1.0.1b / v1.0.1c label. The official release tag,
/// not the newest arbitrary main commit, controls available updates.
public struct KoeBridgeReleaseVersion: Comparable, Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let letterIndex: Int

    public init?(_ raw: String) {
        let value = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              let major = Int(components[0]), let minor = Int(components[1]),
              major >= 0, minor >= 0 else { return nil }
        let patchPart = String(components[2])
        let digits = String(patchPart.prefix(while: { $0.isASCII && $0.isNumber }))
        guard !digits.isEmpty, let patch = Int(digits), patch >= 0 else { return nil }
        let suffix = String(patchPart.dropFirst(digits.count))
        let index: Int
        if suffix.isEmpty { index = 0 }
        else {
            guard suffix.count == 1, let ascii = suffix.utf8.first,
                  ascii >= 97 && ascii <= 122 else { return nil }
            index = Int(ascii - 96)
        }
        self.major = major
        self.minor = minor
        self.patch = patch
        self.letterIndex = index
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        return lhs.letterIndex < rhs.letterIndex
    }
}

/// Only public stable releases at the exact project's URL are acceptable.
/// Never return a remote command, executable download URL, or arbitrary host.
public struct KoeBridgeStableRelease: Equatable, Sendable {
    public let tag: String
    public let page: URL
    public let version: KoeBridgeReleaseVersion

    public init?(tag: String, pageURL: String, isDraft: Bool, isPrerelease: Bool) {
        guard !isDraft, !isPrerelease,
              tag.hasPrefix("v"), let version = KoeBridgeReleaseVersion(tag),
              let url = URL(string: pageURL),
              url.scheme == "https", url.host == "github.com",
              pageURL == "https://github.com/ma-do-ka/KoeBridge/releases/tag/\(tag)"
        else { return nil }
        self.tag = tag
        self.page = url
        self.version = version
    }
}

public enum KoeBridgeUpdatePolicy {
    public static let checkInterval: TimeInterval = 24 * 60 * 60

    public static func shouldCheck(automatic: Bool, lastCheck: Date?, now: Date) -> Bool {
        guard automatic else { return false }
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed < 0 || elapsed >= checkInterval
    }

    public static func newer(_ release: KoeBridgeStableRelease, than installed: String) -> Bool {
        guard let current = KoeBridgeReleaseVersion(installed) else { return false }
        return release.version > current
    }

    public static func decodeLatest(_ data: Data) throws -> KoeBridgeStableRelease {
        struct Payload: Decodable {
            let tag_name: String
            let html_url: String
            let draft: Bool
            let prerelease: Bool
        }
        let raw = try JSONDecoder().decode(Payload.self, from: data)
        guard let valid = KoeBridgeStableRelease(tag: raw.tag_name, pageURL: raw.html_url,
                                                 isDraft: raw.draft, isPrerelease: raw.prerelease)
        else { throw UpdateError.invalidRelease }
        return valid
    }

    public enum UpdateError: LocalizedError {
        case invalidRelease
        public var errorDescription: String? {
            "GitHubの正式リリース情報を確認できません。安全のため更新操作を停止しました。"
        }
    }
}
