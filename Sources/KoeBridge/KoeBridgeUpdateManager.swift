#if os(macOS)
import AppKit
import Combine
import Foundation
import KoeBridgeCore

/// UI-only update checking. The repository currently distributes SOURCE
/// archives, not signed, notarized installable applications. No executable
/// from the network is downloaded or launched by this class.
@MainActor final class KoeBridgeUpdateManager: ObservableObject {
    static let shared = KoeBridgeUpdateManager()

    enum CheckState: Equatable {
        case idle, checking, upToDate, available, failed
    }

    @Published private(set) var state: CheckState = .idle
    @Published private(set) var statusMessage = "更新情報を確認できます"
    @Published private(set) var latestRelease: KoeBridgeStableRelease?
    @Published private(set) var lastCheckedAt: Date?
    private var lastAutomaticAttemptAt: Date?
    @Published private(set) var requestedUpdatePage = 0
    @Published private(set) var copiedCommand = false
    @Published var automaticChecksEnabled: Bool {
        didSet {
            UserDefaults.standard.set(automaticChecksEnabled, forKey: "checkUpdatesAutomatically")
            if automaticChecksEnabled { checkIfDue() }
        }
    }

    /// Automatic installation is intentionally unavailable: no signed and
    /// notarized app archive / Sparkle appcast exists in the current release.
    let automaticInstallationAvailable = false
    let channelName = "Stable"

    var installedLabel: String {
        Bundle.main.object(forInfoDictionaryKey: "KoeBridgeReleaseLabel") as? String ??
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "不明"
    }

    private init() {
        let defaults = UserDefaults.standard
        automaticChecksEnabled = (defaults.object(forKey: "checkUpdatesAutomatically") as? Bool) ?? true
        lastCheckedAt = defaults.object(forKey: "lastSuccessfulUpdateCheckAt") as? Date
        lastAutomaticAttemptAt = defaults.object(forKey: "lastAutomaticUpdateCheckAttemptAt") as? Date
    }

    func requestUpdatePage() {
        requestedUpdatePage += 1
    }

    func consumedUpdatePageRequest() {
        requestedUpdatePage = 0
    }

    func checkIfDue() {
        let now = Date()
        // A failed request must not hammer the public unauthenticated API:
        // throttle automatic attempts (including failures) to once per day.
        guard KoeBridgeUpdatePolicy.shouldCheck(
            automatic: automaticChecksEnabled, lastCheck: lastAutomaticAttemptAt, now: now
        ) else { return }
        lastAutomaticAttemptAt = now
        UserDefaults.standard.set(now, forKey: "lastAutomaticUpdateCheckAttemptAt")
        Task { await checkNow() }
    }

    func checkNow() async {
        guard state != .checking else { return }
        state = .checking
        copiedCommand = false
        statusMessage = "GitHub Releasesを確認中…"
        do {
            let url = URL(string: "https://api.github.com/repos/ma-do-ka/KoeBridge/releases/latest")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("KoeBridge-Updater", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw UpdateCheckError.invalidResponse
            }
            guard http.statusCode == 200 else {
                if http.statusCode == 403 || http.statusCode == 429 {
                    throw UpdateCheckError.rateLimited
                }
                throw UpdateCheckError.http(http.statusCode)
            }
            let release = try KoeBridgeUpdatePolicy.decodeLatest(data)
            latestRelease = release
            lastCheckedAt = Date()
            UserDefaults.standard.set(lastCheckedAt, forKey: "lastSuccessfulUpdateCheckAt")
            if KoeBridgeUpdatePolicy.newer(release, than: installedLabel) {
                state = .available
                statusMessage = "\(release.tag) が利用できます"
            } else {
                state = .upToDate
                statusMessage = "最新の正式版です（\(installedLabel)）"
            }
        } catch {
            // Never advertise "up to date" after a network or parsing error.
            state = .failed
            statusMessage = "更新確認に失敗しました：\(error.localizedDescription)"
        }
    }

    func openLatestRelease() {
        guard let release = latestRelease else { return }
        NSWorkspace.shared.open(release.page)
    }

    /// The user must quit KoeBridge before running this command. Source
    /// updates are compiled and signed with their own local signing identity.
    @discardableResult func copyUpdateCommand() -> Bool {
        guard state == .available, let release = latestRelease else { return false }
        let script = """
        cd "$HOME/KoeBridge" &&
        bash scripts/update_from_release.sh \(release.tag)
        """
        NSPasteboard.general.clearContents()
        let copied = NSPasteboard.general.setString(script, forType: .string)
        copiedCommand = copied
        if copied {
            statusMessage = "更新コマンドをコピーしました。KoeBridgeを終了してターミナルで実行してください。"
        }
        return copied
    }

    private enum UpdateCheckError: LocalizedError {
        case invalidResponse
        case rateLimited
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "応答を読み取れませんでした"
            case .rateLimited: return "GitHubのアクセス制限です。後でもう一度確認してください"
            case .http(let status): return "GitHubの応答コード \(status)"
            }
        }
    }
}
#endif
