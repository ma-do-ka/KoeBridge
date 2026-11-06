import KoeBridgeCore

struct TranscriptRecoveryTests {
    func laterAppleRecoveryIsNotHiddenByStaleCloudPrefix() {
        check(TranscriptRecovery.text(preferred: .local, cloud: "会議について", local: "会議については明日確認します",
                                        preview: "会議について") == "会議については明日確認します")
        // A newer hypothesis is selected by ownership, never by length alone.
        check(TranscriptRecovery.text(preferred: .local, cloud: "古い誤認識で長くなった文章", local: "最新の途中結果",
                                        preview: "古い表示") == "最新の途中結果")
        check(TranscriptRecovery.text(preferred: .cloud, cloud: "クラウドの途中結果", local: "別の途中結果",
                                        preview: "表示") == "クラウドの途中結果")
    }

    func emptyFallbackKeepsEarlierRecoverableSpeech() {
        check(TranscriptRecovery.text(preferred: .local, cloud: "残っている音声", local: " \n ",
                                        preview: "表示") == "残っている音声")
        check(TranscriptRecovery.text(preferred: .local, cloud: nil, local: nil,
                                        preview: "最終表示") == "最終表示")
        check(TranscriptRecovery.text(preferred: .cloud, cloud: "", local: nil,
                                        preview: " \n ").isEmpty)
    }
}
