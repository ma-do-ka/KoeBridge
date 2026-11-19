import Foundation
import KoeBridgeCore

struct JapaneseDictationSpacingTests {
    private func adopt(_ text: String, terms: [String] = []) -> String {
        JapaneseDictationSpacing.adopt(text, enabled: true, protectedTerms: terms)
    }

    func boundaries() {
        // Synthetic prose with eight gaps; the private recordings stay outside the repository.
        let plain = "窓の外では静かな雨が降っています。"
        let spaced = "窓の 外では 静かな 雨が 降って い ま す 。"
        for input in [plain, spaced] {
            let once = adopt(input)
            check(once.utf8.elementsEqual(plain.utf8))
            check(adopt(once).utf8.elementsEqual(once.utf8))
        }
        check(adopt("㐀   鿿 々 ゝ ゞ ヽ ヾ ー 〆 、後 。") == "㐀鿿々ゝゞヽヾー〆、後。")
        check(adopt("  語　文\t次\n段\u{00a0}落  \n") == "  語　文\t次\n段\u{00a0}落  \n")
        check(adopt("和文、 次。 文") == "和文、 次。 文")
    }

    func bytePreservation() {
        let protected = [
            "  English prose with  two spaces  ", "和文 API client を利用", "漢 A B 字",
            "2 34 kg・１２ ３４ キロ・二百 万 円・約 三 千 円", "〇 個", "零 円", "第 三 章",
            "https://example.test/資料 次", "宛先 東京@例.日本 添付",
            "/tmp/資料 次", #"C:\資料\名前 次"#, "tool --name=東京 大阪", "cp 東京 大阪",
            "```swift\n和 文   次\n```", "前`和 文`後", "「和 文」『保 存』“保 存”",
            "前``和 ` 文 字``後", "~~~sh\n和 文\n~~~", "custom-tool 入力 出力",
            #""保 存" '和 文'"#, #""前\"中 間\"後""#,
            "  👩🏽‍💻 e\u{301} 和\t文\n"
        ]
        for example in protected {
            check(adopt(example).utf8.elementsEqual(example.utf8))
        }
        for example in protected + ["  和  文 。\t\n"] {
            check(JapaneseDictationSpacing.adopt(example, enabled: false, protectedTerms: [])
                .utf8.elementsEqual(example.utf8))
        }
        let mixed = "前 文「引用 内」後 文と 登録 語です"
        check(adopt(mixed, terms: ["登録 語"]) == "前文「引用 内」後文と登録 語です")
        check(adopt("語 語 語 後", terms: ["語 語"]) == "語 語 語後")
    }

    func adoptedStageOutputAndSnippets() throws {
        let rules = [SnippetRule(trigger: "定型 名前", template: "署 名{{CLIPBOARD}} ")]
        let terms = rules.map(\.trigger)
        let primary = adopt("元 の文", terms: terms)
        let processed = " 修 正 文 定型 名前"
        check(PostProcessingPolicy.accepts(original: primary, processed: processed))
        let adopted = adopt(processed, terms: terms)
        check(adopted == " 修正文定型 名前")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("history.json")
        var history = TranscriptHistoryStore(fileURL: file)
        var queue = OrderedResultBuffer<String>()
        for expand in [true, false] {
            let final = expand ? SnippetExpander.expand(adopted, rules: rules,
                context: SnippetContext(date: Date(), clipboardText: "貼 付")) : adopted
            let expected = expand ? " 修正文署 名貼 付 " : " 修正文定型 名前"
            let id = UUID()
            check(queue.begin(id))
            check(queue.finish(id, result: final))
            let recordID = try require(history.remember(final, isPartial: false, delivery: .pending,
                engine: "test", preserveWhitespace: true))
            let saved = try require(TranscriptHistoryStore(fileURL: file).entries.first { $0.id == recordID })
            let queued = try require(queue.drain().first?.1)
            check(queued.utf8.elementsEqual(expected.utf8))
            check(saved.text.utf8.elementsEqual(queued.utf8))
        }
    }
}
