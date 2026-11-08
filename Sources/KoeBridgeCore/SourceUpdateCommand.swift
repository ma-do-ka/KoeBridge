import Foundation

/// Read-only discovery of official main. This is a USER-RUN source build,
/// never a substitute for Sparkle's signature verification or a stable release.
public struct SourceUpdateTarget: Equatable, Sendable {
    public let commit: String
    public let label: String
    public let build: Int

    public init?(commit: String, label: String, build: Int) {
        guard Self.validCommit(commit), Self.validLabel(label), build > 0 else { return nil }
        self.commit = commit
        self.label = label
        self.build = build
    }

    public static func validCommit(_ value: String) -> Bool {
        value.count == 40 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func validLabel(_ value: String) -> Bool {
        guard value.range(of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)[a-z]?$"#,
                          options: .regularExpression) != nil,
              KoeBridgeReleaseVersion(value) != nil else { return false }
        return !value.contains(where: { $0.isWhitespace })
    }

    public static func decodeHead(_ data: Data) throws -> String {
        struct Branch: Decodable {
            struct Commit: Decodable { let sha: String }
            let name: String
            let commit: Commit
        }
        let branch = try JSONDecoder().decode(Branch.self, from: data)
        guard branch.name == "main", validCommit(branch.commit.sha) else { throw SourceError.invalidMetadata }
        return branch.commit.sha
    }

    public static func decodeInfoPlist(_ data: Data, commit: String) throws -> Self {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == "dev.koebridge.app",
              let label = plist["KoeBridgeReleaseLabel"] as? String,
              let rawBuild = plist["CFBundleVersion"] as? String,
              let build = Int(rawBuild), String(build) == rawBuild,
              let target = Self(commit: commit, label: label, build: build),
              let version = KoeBridgeReleaseVersion(label),
              plist["CFBundleShortVersionString"] as? String == "\(version.major).\(version.minor).\(version.patch)"
        else { throw SourceError.invalidMetadata }
        return target
    }

    /// Unknown installed metadata must not silently permit a downgrade.
    public func canBuild(over installedLabel: String, build installedBuild: Int) -> Bool {
        guard Self.validLabel(installedLabel), let installed = KoeBridgeReleaseVersion(installedLabel),
              let remote = KoeBridgeReleaseVersion(label), installedBuild > 0 else { return false }
        return remote >= installed && build >= installedBuild
    }

    public func isNewer(than installedLabel: String, build installedBuild: Int) -> Bool {
        canBuild(over: installedLabel, build: installedBuild) &&
            (label != installedLabel || build > installedBuild)
    }

    public var command: String {
        // Only validated hex / canonical version / positive integer values enter
        // the shell. No remote command, title, URL or user-controlled path does.
        """
        /bin/bash <<'KOEBRIDGE_SOURCE_UPDATE'
        set -euo pipefail
        export GIT_TERMINAL_PROMPT=0
        test "$(uname -s)" = Darwin || { echo 'macOSで実行してください。' >&2; exit 1; }
        for tool in git swift; do
          command -v "$tool" >/dev/null || { echo "必要なツールがありません: $tool" >&2; exit 1; }
        done
        if pgrep -x KoeBridge >/dev/null 2>&1; then
          echo 'KoeBridgeをメニューバーから終了して、同じコマンドを再実行してください。' >&2
          exit 1
        fi
        ROOT="$HOME/KoeBridge"
        SHA='\(commit)'
        if [ ! -e "$ROOT" ] && [ ! -L "$ROOT" ]; then
          git init -q -b main "$ROOT"
          git -C "$ROOT" remote add origin https://github.com/ma-do-ka/KoeBridge.git
        fi
        test ! -L "$ROOT" && test -d "$ROOT/.git" || { echo '既存のKoeBridgeフォルダーを保護するため停止しました。' >&2; exit 1; }
        cd "$ROOT"
        case "$(git remote get-url origin)" in
          https://github.com/ma-do-ka/KoeBridge|https://github.com/ma-do-ka/KoeBridge.git|git@github.com:ma-do-ka/KoeBridge|git@github.com:ma-do-ka/KoeBridge.git) ;;
          *) echo '公式リポジトリ以外は更新しません。' >&2; exit 1 ;;
        esac
        test "$(git symbolic-ref --short HEAD)" = main || { echo 'main以外の作業ブランチを保護するため停止しました。' >&2; exit 1; }
        test -z "$(git status --porcelain --untracked-files=normal)" || { echo '未保存の変更・未追跡ファイルを保護するため停止しました。' >&2; exit 1; }
        git -c core.hooksPath=/dev/null fetch --no-tags https://github.com/ma-do-ka/KoeBridge.git "$SHA"
        test "$(git rev-parse 'FETCH_HEAD^{commit}')" = "$SHA"
        INFO="$(mktemp)"
        trap 'rm -f "$INFO"' EXIT
        git show "$SHA:scripts/Info.plist" > "$INFO"
        test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")" = dev.koebridge.app
        test "$(/usr/libexec/PlistBuddy -c 'Print :KoeBridgeReleaseLabel' "$INFO")" = '\(label)'
        test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")" = '\(build)'
        if git rev-parse --verify HEAD >/dev/null 2>&1; then
          git merge-base --is-ancestor HEAD "$SHA" || { echo '巻き戻し・履歴の上書きを避けるため停止しました。' >&2; exit 1; }
          git -c core.hooksPath=/dev/null merge --ff-only --no-edit "$SHA"
        else
          git -c core.hooksPath=/dev/null checkout -q -B main "$SHA"
        fi
        test "$(git rev-parse HEAD)" = "$SHA"
        bash scripts/verify_and_build.sh
        APP="$ROOT/dist/KoeBridge.app"
        test "$(/usr/libexec/PlistBuddy -c 'Print :KoeBridgeReleaseLabel' "$APP/Contents/Info.plist")" = '\(label)'
        test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")" = '\(build)'
        open "$APP"
        printf '\\nKoeBridge \(label) / Build \(build) を起動しました: %s\\n' "$APP"
        KOEBRIDGE_SOURCE_UPDATE
        """
    }

    public enum SourceError: LocalizedError {
        case invalidMetadata
        public var errorDescription: String? { "公式ソースのコミット・版番号・ビルド番号を確認できませんでした" }
    }
}
