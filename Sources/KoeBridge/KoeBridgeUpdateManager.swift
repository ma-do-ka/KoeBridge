#if os(macOS)
import AppKit
import Combine
import Foundation
import KoeBridgeCore

/// Read-only update discovery. Source commands run ONLY when a user pastes
/// them in Terminal. Signed binary installation remains owned by Sparkle.
@MainActor final class KoeBridgeUpdateManager: ObservableObject {
    static let shared = KoeBridgeUpdateManager()

    enum CheckState: Equatable {
        case idle, checking, upToDate, available, failed
    }

    @Published private(set) var state: CheckState = .idle
    @Published private(set) var statusMessage = "更新情報を確認できます"
    @Published private(set) var latestRelease: KoeBridgeStableRelease?
    @Published private(set) var sourceTarget: SourceUpdateTarget?
    @Published private(set) var sourceStatusMessage = "更新確認後に、公式ソースの更新コマンドをコピーできます"
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

    let automaticInstallationAvailable = false
    let channelName = "Stable / Source"

    var installedLabel: String {
        Bundle.main.object(forInfoDictionaryKey: "KoeBridgeReleaseLabel") as? String ??
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "不明"
    }
    var installedBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }
    var hasNewStableRelease: Bool {
        latestRelease.map { KoeBridgeUpdatePolicy.newer($0, than: installedLabel) } ?? false
    }
    var canCopyUpdateCommand: Bool {
        state != .checking && sourceTarget?.canBuild(over: installedLabel, build: installedBuild) == true
    }

    private init() {
        let defaults = UserDefaults.standard
        automaticChecksEnabled = (defaults.object(forKey: "checkUpdatesAutomatically") as? Bool) ?? true
        lastCheckedAt = defaults.object(forKey: "lastSuccessfulUpdateCheckAt") as? Date
        lastAutomaticAttemptAt = defaults.object(forKey: "lastAutomaticUpdateCheckAttemptAt") as? Date
    }

    func requestUpdatePage() { requestedUpdatePage += 1 }
    func consumedUpdatePageRequest() { requestedUpdatePage = 0 }

    func checkIfDue() {
        let now = Date()
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
        latestRelease = nil
        sourceTarget = nil // No stale command after a failed or cancelled refresh.
        statusMessage = "GitHub Releasesを確認中…"
        sourceStatusMessage = "公式mainのコミットと版番号を確認中…"
        var releaseChecked = false
        do {
            let data = try await readOfficial(URL(string: "https://api.github.com/repos/ma-do-ka/KoeBridge/releases/latest")!)
            let release = try KoeBridgeUpdatePolicy.decodeLatest(data)
            guard let installed = KoeBridgeReleaseVersion(installedLabel) else {
                throw UpdateCheckError.unknownInstalledVersion
            }
            latestRelease = release
            releaseChecked = true
            lastCheckedAt = Date()
            UserDefaults.standard.set(lastCheckedAt, forKey: "lastSuccessfulUpdateCheckAt")
            if release.version > installed {
                statusMessage = "正式リリース \(release.tag) が利用できます"
            } else if release.version == installed {
                statusMessage = "公開済み正式版と同じバージョンです（\(installedLabel)）"
            } else {
                statusMessage = "公開済み正式版は\(release.tag)です。現在の\(installedLabel)はそれより新しいソース版です"
            }
        } catch {
            statusMessage = "正式リリースの確認に失敗しました：\(error.localizedDescription)"
        }
        do {
            let head = try SourceUpdateTarget.decodeHead(await readOfficial(
                URL(string: "https://api.github.com/repos/ma-do-ka/KoeBridge/branches/main")!))
            let infoURL = URL(string: "https://raw.githubusercontent.com/ma-do-ka/KoeBridge/\(head)/scripts/Info.plist")!
            let candidate = try SourceUpdateTarget.decodeInfoPlist(await readOfficial(infoURL), commit: head)
            guard candidate.canBuild(over: installedLabel, build: installedBuild) else {
                throw UpdateCheckError.sourceDowngrade
            }
            sourceTarget = candidate
            let action = candidate.isNewer(than: installedLabel, build: installedBuild) ? "更新できます" : "再ビルドできます"
            sourceStatusMessage = "公式ソース：\(candidate.label) / Build \(candidate.build)。手動コマンドで\(action)（配布アプリとは別）"
        } catch {
            sourceTarget = nil
            sourceStatusMessage = "ソース更新は利用できません：\(error.localizedDescription)"
        }
        if hasNewStableRelease || sourceTarget?.isNewer(than: installedLabel, build: installedBuild) == true {
            state = .available
        } else {
            state = releaseChecked ? .upToDate : .failed
        }
    }

    private func readOfficial(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 12
        request.setValue("KoeBridge-Updater", forHTTPHeaderField: "User-Agent")
        if url.host == "api.github.com" { request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.url == url else {
            throw UpdateCheckError.invalidResponse
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 403 || http.statusCode == 429 { throw UpdateCheckError.rateLimited }
            throw UpdateCheckError.http(http.statusCode)
        }
        guard data.count <= 262_144 else { throw UpdateCheckError.invalidResponse }
        return data
    }

    func openLatestRelease() {
        guard let release = latestRelease else { return }
        NSWorkspace.shared.open(release.page)
    }

    @discardableResult func copyUpdateCommand() -> Bool {
        guard canCopyUpdateCommand, let candidate = sourceTarget else { return false }
        NSPasteboard.general.clearContents()
        let copied = NSPasteboard.general.setString(candidate.command, forType: .string)
        copiedCommand = copied
        sourceStatusMessage = copied
            ? "\(candidate.label) / Build \(candidate.build) のコマンドをコピーしました。KoeBridgeを終了してターミナルで実行してください。"
            : "コピーに失敗しました。もう一度ボタンを押してください。"
        return copied
    }

    private enum UpdateCheckError: LocalizedError {
        case invalidResponse, rateLimited, unknownInstalledVersion, sourceDowngrade
        case http(Int)
        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "公式サーバーの応答を確認できませんでした"
            case .rateLimited: return "GitHubのアクセス制限です。後でもう一度確認してください"
            case .unknownInstalledVersion: return "現在のアプリバージョンを確認できません"
            case .sourceDowngrade: return "現在より古い版・ビルドへの更新、または現在の版情報が不明な更新は行いません"
            case .http(let status): return "GitHubの応答コード \(status)"
            }
        }
    }
}
#endif
