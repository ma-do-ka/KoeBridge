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

    public var command: String { command(relaunchApp: nil) }

    public func command(relaunchApp: URL?) -> String {
        // Encode the local path as data; it must never become shell syntax.
        let encodedPath = Data((relaunchApp?.path ?? "").utf8).base64EncodedString()
        return """
        /bin/bash <<'KOEBRIDGE_SOURCE_UPDATE'
        set -euo pipefail
        export GIT_TERMINAL_PROMPT=0
        test "$(uname -s)" = Darwin || { echo 'macOSで実行してください。' >&2; exit 1; }
        ROOT="$HOME/KoeBridge"
        APP="$ROOT/dist/KoeBridge.app"
        ORIGINAL=""
        if [ -n '\(encodedPath)' ]; then ORIGINAL="$(printf '%s' '\(encodedPath)' | /usr/bin/base64 -D)"; fi
        WORK=""
        BACKUP=""
        LOCK=""
        finish_update() {
          status=$?
          if [ "$status" -ne 0 ]; then
            if [ -n "$BACKUP" ] && [ -d "$BACKUP/KoeBridge.app" ] &&
               codesign --verify --deep --strict "$BACKUP/KoeBridge.app"; then
              if [ -e "$APP" ]; then mv "$APP" "$BACKUP/failed.app"; fi
              mv "$BACKUP/KoeBridge.app" "$APP"
            fi
            if pgrep -x KoeBridge >/dev/null 2>&1; then :
            elif [ -n "$ORIGINAL" ]; then
              printf '更新を中止しました。以前のアプリをFinderから起動してください：%s\\n' "$ORIGINAL" >&2
            else
              printf '更新を中止しました。以前使用していたKoeBridgeをFinderから起動してください。\\n' >&2
            fi
          fi
          if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
          if [ -n "$LOCK" ]; then rmdir "$LOCK"; fi
          exit "$status"
        }
        trap finish_update EXIT
        for tool in git swift codesign; do
          command -v "$tool" >/dev/null || { echo "必要なツールがありません: $tool" >&2; exit 1; }
        done
        SHA='\(commit)'
        if [ ! -e "$ROOT" ] && [ ! -L "$ROOT" ]; then
          git init -q -b main "$ROOT"
          git -C "$ROOT" remote add origin https://github.com/ma-do-ka/KoeBridge.git
        fi
        test ! -L "$ROOT" && test -d "$ROOT/.git" || { echo '既存のKoeBridgeフォルダーを保護するため停止しました。' >&2; exit 1; }
        cd "$ROOT"
        if ! mkdir .git/koebridge-update.lock; then
          echo '別の更新が進行中です。中断後にロックが残った場合は、更新処理の終了を確認してください。' >&2
          exit 1
        fi
        LOCK="$ROOT/.git/koebridge-update.lock"
        case "$(git remote get-url origin)" in
          https://github.com/ma-do-ka/KoeBridge|https://github.com/ma-do-ka/KoeBridge.git|git@github.com:ma-do-ka/KoeBridge|git@github.com:ma-do-ka/KoeBridge.git) ;;
          *) echo '公式リポジトリ以外は更新しません。' >&2; exit 1 ;;
        esac
        test "$(git symbolic-ref --short HEAD)" = main || { echo 'main以外の作業ブランチを保護するため停止しました。' >&2; exit 1; }
        test -z "$(git status --porcelain --untracked-files=normal)" || { echo '未保存の変更・未追跡ファイルを保護するため停止しました。' >&2; exit 1; }
        git -c core.hooksPath=/dev/null fetch --no-tags https://github.com/ma-do-ka/KoeBridge.git "$SHA"
        test "$(git rev-parse 'FETCH_HEAD^{commit}')" = "$SHA"
        WORK="$(mktemp -d "$ROOT/.build-source-update.XXXXXX")"
        INFO="$WORK/Info.plist"
        git show "$SHA:scripts/Info.plist" > "$INFO"
        test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")" = dev.koebridge.app
        test "$(/usr/libexec/PlistBuddy -c 'Print :KoeBridgeReleaseLabel' "$INFO")" = '\(label)'
        test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")" = '\(build)'
        if git rev-parse --verify HEAD >/dev/null 2>&1; then
          git merge-base --is-ancestor HEAD "$SHA" || { echo '巻き戻し・履歴の上書きを避けるため停止しました。' >&2; exit 1; }
        fi
        if pgrep -x KoeBridge >/dev/null 2>&1; then
          echo '事前確認が完了しました。KoeBridgeを終了し、同じコマンドを再実行してください。' >&2
          exit 1
        fi
        if git rev-parse --verify HEAD >/dev/null 2>&1; then
          git -c core.hooksPath=/dev/null merge --ff-only --no-edit "$SHA"
        else
          git -c core.hooksPath=/dev/null checkout -q -B main "$SHA"
        fi
        test "$(git rev-parse HEAD)" = "$SHA"
        # Build the exact target in isolation. Even older target scripts may
        # replace their own dist bundle; the running installation stays intact.
        mkdir "$WORK/source"
        git archive "$SHA" | tar -x -C "$WORK/source"
        (cd "$WORK/source" && unset KOEBRIDGE_BUILD_OUTPUT && bash scripts/verify_and_build.sh)
        CANDIDATE="$WORK/source/dist/KoeBridge.app"
        codesign --verify --deep --strict "$CANDIDATE"
        test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$CANDIDATE/Contents/Info.plist")" = dev.koebridge.app
        if pgrep -x KoeBridge >/dev/null 2>&1; then
          echo 'KoeBridgeが起動したため置換を中止しました。' >&2
          exit 1
        fi
        test "$(/usr/libexec/PlistBuddy -c 'Print :KoeBridgeReleaseLabel' "$CANDIDATE/Contents/Info.plist")" = '\(label)'
        test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$CANDIDATE/Contents/Info.plist")" = '\(build)'
        mkdir -p "$ROOT/dist"
        if [ -e "$APP" ]; then
          codesign --verify --deep --strict "$APP"
          BACKUP="$(mktemp -d "$ROOT/dist/previous-$(date +%Y%m%d-%H%M%S).XXXXXX")"
          mv "$APP" "$BACKUP/KoeBridge.app"
        fi
        mv "$CANDIDATE" "$APP"
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
