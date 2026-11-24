import Foundation
import KoeBridgeCore

struct AmiVoiceWireTests {
    func nologEndpointPreservesMandatoryTrailingSlash() throws {
        check(AmiVoiceWire.nologWebSocketEndpoint == "wss://acp-api.amivoice.com/v1/nolog/")
        check(AmiVoiceWire.nologWebSocketEndpoint.hasSuffix("/nolog/"))
        let url = try require(URL(string: AmiVoiceWire.nologWebSocketEndpoint))
        check(url.absoluteString == "wss://acp-api.amivoice.com/v1/nolog/")
        check(url.scheme == "wss")
        check(url.host == "acp-api.amivoice.com")
    }

    func engineMetadataAndCodableRoundTrip() throws {
        check(AmiVoiceEngine.allCases == [
            .e2eJapaneseGeneral,
            .e2eJapaneseGeneralBatch,
            .hybridJapaneseInput,
            .hybridJapaneseConversation
        ])
        check(AmiVoiceEngine.e2eJapaneseGeneral.rawValue == "-a2-ja-general")
        check(AmiVoiceEngine.e2eJapaneseGeneral.isE2E)
        check(AmiVoiceEngine.e2eJapaneseGeneral.supportsInterimPreview)
        check(AmiVoiceEngine.e2eJapaneseGeneral.supportsWrittenOnlyBoost)
        check(AmiVoiceEngine.e2eJapaneseGeneral.label == "日本語E2E_汎用")

        check(AmiVoiceEngine.e2eJapaneseGeneralBatch.rawValue == "-a2b-ja-general")
        check(AmiVoiceEngine.e2eJapaneseGeneralBatch.isE2E)
        check(!AmiVoiceEngine.e2eJapaneseGeneralBatch.supportsInterimPreview)
        check(AmiVoiceEngine.e2eJapaneseGeneralBatch.supportsWrittenOnlyBoost)
        check(AmiVoiceEngine.e2eJapaneseGeneralBatch.label == "日本語E2E_汎用バッチ")

        check(AmiVoiceEngine.hybridJapaneseInput.rawValue == "-a-general-input")
        check(!AmiVoiceEngine.hybridJapaneseInput.isE2E)
        check(AmiVoiceEngine.hybridJapaneseInput.supportsInterimPreview)
        check(!AmiVoiceEngine.hybridJapaneseInput.supportsWrittenOnlyBoost)
        check(AmiVoiceEngine.hybridJapaneseInput.label == "音声入力_汎用")

        check(AmiVoiceEngine.hybridJapaneseConversation.rawValue == "-a-general")
        check(!AmiVoiceEngine.hybridJapaneseConversation.isE2E)
        check(AmiVoiceEngine.hybridJapaneseConversation.supportsInterimPreview)
        check(!AmiVoiceEngine.hybridJapaneseConversation.supportsWrittenOnlyBoost)
        check(AmiVoiceEngine.hybridJapaneseConversation.label == "会話_汎用")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for engine in AmiVoiceEngine.allCases {
            check(engine.id == engine.rawValue)
            check(engine.nologPriceJPYPerSecond == 0.04125)
            let encoded = try encoder.encode(engine)
            let decoded = try decoder.decode(AmiVoiceEngine.self, from: encoded)
            check(decoded == engine)
        }
    }

    func startAudioAndEndCommandsMatchProtocol() {
        check(AmiVoiceWire.audioFormat == "LSB16K")
        check(AmiVoiceWire.maximumAudioPacketBytes == 16_000_000)
        check(AmiVoiceWire.endCommand == "e")

        let defaultStart = AmiVoiceWire.startCommand()
        check(defaultStart == "s LSB16K -a2-ja-general resultUpdatedInterval=300")
        check(!defaultStart.contains("authorization="))

        let customInterval = AmiVoiceWire.startCommand(
            engine: .e2eJapaneseGeneral,
            resultUpdatedIntervalMS: 500
        )
        check(customInterval == "s LSB16K -a2-ja-general resultUpdatedInterval=500")

        let clampedInterval = AmiVoiceWire.startCommand(
            engine: .e2eJapaneseGeneral,
            resultUpdatedIntervalMS: -250
        )
        check(clampedInterval == "s LSB16K -a2-ja-general resultUpdatedInterval=0")

        let batchStart = AmiVoiceWire.startCommand(
            engine: .e2eJapaneseGeneralBatch,
            resultUpdatedIntervalMS: 300,
            profileWords: ["KoeBridge"]
        )
        check(batchStart == #"s LSB16K -a2b-ja-general resultUpdatedInterval=0 profileWords="KoeBridge""#)

        let hybridStart = AmiVoiceWire.startCommand(
            engine: .hybridJapaneseInput,
            profileWords: ["KoeBridge", "SwiftUI"]
        )
        check(hybridStart == "s LSB16K -a-general-input resultUpdatedInterval=300")

        let hybridWithProfile = AmiVoiceWire.startCommand(
            engine: .hybridJapaneseConversation,
            profileWords: ["KoeBridge"],
            profileId: "team_dict-1"
        )
        check(hybridWithProfile == "s LSB16K -a-general resultUpdatedInterval=300 profileId=:team_dict-1")

        let pcm = Data([0x01, 0x02, 0xfe, 0xff])
        let packet = AmiVoiceWire.audioPacket(pcm)
        check(packet == Data([0x70, 0x01, 0x02, 0xfe, 0xff]))
        check(AmiVoiceWire.audioPacket(Data()) == Data([0x70]))
    }

    func profileIdSanitizationRejectsReservedAndUnsafeValues() {
        check(AmiVoiceWire.sanitizeProfileId("team_01-prod") == "team_01-prod")
        check(AmiVoiceWire.sanitizeProfileId(" _single_leading ") == "_single_leading")
        for invalid in [nil, "", "   ", "__reserved", "__", "has space", "a:b", "a|b", "日本語", "bad\"quote", "line\nbreak"] {
            check(AmiVoiceWire.sanitizeProfileId(invalid) == nil)
        }

        let withId = AmiVoiceWire.startCommand(
            engine: .e2eJapaneseGeneral,
            profileWords: ["KoeBridge"],
            profileId: "user_profile"
        )
        check(withId == "s LSB16K -a2-ja-general resultUpdatedInterval=300 profileId=:user_profile")

        let reserved = AmiVoiceWire.startCommand(
            engine: .e2eJapaneseGeneral,
            profileWords: ["KoeBridge"],
            profileId: "__system"
        )
        check(reserved == "s LSB16K -a2-ja-general resultUpdatedInterval=300")
    }

    func profileWordsSanitizationDeduplicationAndCaps() throws {
        let encoded = try require(AmiVoiceWire.encodeProfileWords([
            "  GitHub   Actions  ",
            "GitHub\tActions",
            "Koe:Bridge",
            "Koe|Bridge",
            "say \"hi\"",
            "日本語　用語",
            "a\0b",
            "|||:::",
            "   ",
            "foo\nbar"
        ]))
        check(encoded == #"GitHub_Actions KoeBridge say_""hi"" 日本語_用語 ab foo_bar"#)
        check(!encoded.contains("|"))
        check(!encoded.contains(":"))
        check(!encoded.contains("\n"))

        let command = AmiVoiceWire.startCommand(
            engine: .e2eJapaneseGeneral,
            profileWords: ["GitHub Actions", #"say "hi""#]
        )
        check(command == #"s LSB16K -a2-ja-general resultUpdatedInterval=300 profileWords="GitHub_Actions say_""hi""""#)

        check(AmiVoiceWire.encodeProfileWords(["|||", ":::", "   "]) == nil)
        check(AmiVoiceWire.startCommand(profileWords: ["|||", ":::"]) == "s LSB16K -a2-ja-general resultUpdatedInterval=300")

        let manyShort = (0..<150).map { "term\($0)" }
        let cappedCount = try require(AmiVoiceWire.encodeProfileWords(manyShort))
        let terms = cappedCount.split(separator: " ").map(String.init)
        check(terms.count == AmiVoiceWire.maximumProfileWordCount)
        check(terms == (0..<100).map { "term\($0)" })

        let manyJapanese = (0..<100).map { "用語\(100 + $0)_" + String(repeating: "あ", count: 30) }
        let cappedBytes = try require(AmiVoiceWire.encodeProfileWords(manyJapanese))
        check(cappedBytes.utf8.count <= AmiVoiceWire.maximumProfileWordsBytes)
        check(cappedBytes.utf8.count > 3_900)
        check(cappedBytes.split(separator: " ").count < 100)

        let exact = String(repeating: "a", count: AmiVoiceWire.maximumProfileWordsBytes)
        check(AmiVoiceWire.encodeProfileWords([exact])?.utf8.count == AmiVoiceWire.maximumProfileWordsBytes)
        let overByOne = String(repeating: "a", count: AmiVoiceWire.maximumProfileWordsBytes + 1)
        check(AmiVoiceWire.encodeProfileWords([overByOne]) == nil)
        let quoteOverflow = String(repeating: "a", count: AmiVoiceWire.maximumProfileWordsBytes - 1) + "\""
        check(AmiVoiceWire.encodeProfileWords([quoteOverflow, "KoeBridge"]) == "KoeBridge")
    }

    func decodeServerFrameRoundTripsAndMalformedRejection() throws {
        try check(AmiVoiceWire.decode("s") == .startAck(nil))
        try check(AmiVoiceWire.decode("s invalid authorization") == .startAck(AmiVoiceProviderError(command: .start, message: "invalid authorization")))
        try check(AmiVoiceWire.decode("p can't feed audio data to recognizer server") == .provideError(AmiVoiceProviderError(command: .provide, message: "can't feed audio data to recognizer server")))
        try check(AmiVoiceWire.decode("e") == .endAck(nil))
        try check(AmiVoiceWire.decode("e timeout occurred while waiting for audio data") == .endAck(AmiVoiceProviderError(command: .end, message: "timeout occurred")))
        try check(AmiVoiceWire.decode("S 0") == .speechStart(ms: 0))
        try check(AmiVoiceWire.decode("S 1250") == .speechStart(ms: 1_250))
        try check(AmiVoiceWire.decode("E 3400") == .speechEnd(ms: 3_400))
        try check(AmiVoiceWire.decode("C") == .recognitionStarted)
        try check(AmiVoiceWire.decode("G recording started") == .serverInfo)
        try check(AmiVoiceWire.decode("G") == .serverInfo)

        let aFrame = try AmiVoiceWire.decode(#"""
        A {"results":[{"text":"今日は晴れです。","starttime":320,"endtime":1850}],"utteranceid":"20261124/12/abc","text":"今日は晴れです。","code":"","message":""}
        """#)
        check(aFrame == .utteranceFinal(AmiVoiceUtteranceResult(
            text: "今日は晴れです。",
            error: nil,
            utteranceID: "20261124/12/abc",
            startTimeMS: 320,
            endTimeMS: 1_850
        )))

        let rFrame = try AmiVoiceWire.decode(#"""
        R {"text":"確認します","code":"","utteranceid":"u2","starttime":100,"endtime":900}
        """#)
        check(rFrame == .utteranceFinal(AmiVoiceUtteranceResult(
            text: "確認します",
            error: nil,
            utteranceID: "u2",
            startTimeMS: 100,
            endTimeMS: 900
        )))

        checkThrows(AmiVoiceWireError.self) { _ = try AmiVoiceWire.decode("") }
        for malformed in ["start", "p", "end", "S", "S -1", "S abc", "E ", "C extra", "GARBAGE", "X 123", "U", "A", "R"] {
            checkThrows(AmiVoiceWireError.self) { _ = try AmiVoiceWire.decode(malformed) }
        }
        for badJSON in ["U not-json", "U []", "U null", "A {bad}", "A []", "A {\"code\":123}", "R null"] {
            checkThrows(AmiVoiceWireError.self) { _ = try AmiVoiceWire.decode(badJSON) }
        }
    }

    func interimEllipsisStrippingAndEmptyInterimHandling() throws {
        try check(AmiVoiceWire.decode(#"U {"text":"こんにちは..."}"#) == .interim("こんにちは"))
        try check(AmiVoiceWire.decode(#"U {"text":"こんにちは ..."}"#) == .interim("こんにちは"))
        try check(AmiVoiceWire.decode(#"U {"text":"..."}"#) == .interim(""))
        try check(AmiVoiceWire.decode(#"U {"text":"  ...  "}"#) == .interim(""))
        try check(AmiVoiceWire.decode(#"U {"text":""}"#) == .interim(""))
        try check(AmiVoiceWire.decode(#"U {}"#) == .interim(""))
        try check(AmiVoiceWire.decode(#"U {"text":"こんにちは"}"#) == .interim("こんにちは"))
        try check(AmiVoiceWire.decode(#"U {"text":"テスト......"}"#) == .interim("テスト..."))
        try check(AmiVoiceWire.decode(#"U {"text":"テスト…"}"#) == .interim("テスト…"))

        var assembler = AmiVoiceTranscriptAssembler()
        assembler.apply(.interim(""))
        check(assembler.interim.isEmpty)
        check(assembler.preview == RecognitionPreview())
        assembler.apply(.interim("入力中"))
        assembler.apply(.interim(""))
        check(assembler.interim == "入力中")
        check(assembler.preview == RecognitionPreview(finalizedPrefix: "", volatileTail: "入力中"))
    }

    func providerErrorClassificationAndZeroLeakBoundary() throws {
        let codeExpectations: [(String, AmiVoiceProviderError.Kind)] = [
            ("-", .authentication),
            ("+", .unsupportedAudio),
            ("%", .unsupportedAudio),
            ("b", .serverBusy),
            ("!", .serverUnavailable),
            (">", .serverUnavailable),
            ("<", .serverUnavailable),
            ("#", .serverUnavailable),
            ("x", .serverUnavailable),
            ("?", .serverUnavailable),
            ("$", .timeout),
            ("t", .timeout),
            ("s", .timeout),
            ("e", .timeout),
            ("o", .noSpeechRejected),
            ("c", .rejected),
            ("z", .rejected)
        ]
        for (code, expectedKind) in codeExpectations {
            let err = AmiVoiceProviderError(resultCode: code)
            check(err.kind == expectedKind)
            check(err.errorDescription?.isEmpty == false)
            check(DiagnosticLogPolicy.sanitizedEvent(err.diagnostic) == err.diagnostic)
        }

        check(AmiVoiceProviderError(command: .start, message: "invalid authorization").kind == .authentication)
        check(AmiVoiceProviderError(command: .start, message: "can't allocate recognizer").kind == .serverBusy)
        check(AmiVoiceProviderError(command: .start, message: "invalid audio format").kind == .unsupportedAudio)
        check(AmiVoiceProviderError(command: .provide, message: "can't feed audio data to recognizer server").kind == .serverUnavailable)
        check(AmiVoiceProviderError(command: .end, message: "timeout occurred while waiting for audio data").kind == .timeout)

        let sentinel = "SENTINEL-RAW-PROVIDER-9f2a4c"
        let rawFrames = [
            "s invalid authorization: \(sentinel)",
            "p can't feed audio data to recognizer server: \(sentinel)",
            "e timeout occurred: \(sentinel)",
            #"A {"code":"-","message":"\#(sentinel)","text":"\#(sentinel)"}"#,
            #"A {"code":"\#(sentinel)","message":"\#(sentinel)","text":"\#(sentinel)"}"#,
            "G \(sentinel)"
        ]
        for raw in rawFrames {
            let frame = try AmiVoiceWire.decode(raw)
            var representations = [
                String(reflecting: frame),
                String(describing: frame),
                frame.diagnosticKind
            ]
            switch frame {
            case .startAck(let err?), .provideError(let err), .endAck(let err?):
                representations += [
                    err.diagnostic,
                    err.diagnosticCode,
                    err.errorDescription ?? "",
                    err.localizedDescription
                ]
            case .utteranceFinal(let result):
                check(result.text.isEmpty)
                let err = try require(result.error)
                representations += [
                    result.text,
                    err.diagnostic,
                    err.diagnosticCode,
                    err.errorDescription ?? "",
                    err.localizedDescription
                ]
            case .serverInfo:
                break
            default:
                recordFailure("Unexpected frame for sentinel check: \(frame.diagnosticKind)")
            }
            for rep in representations {
                check(!rep.contains(sentinel))
            }
        }
    }

    func assemblerInterleavedSpeechDurationAndNoSpeechSegmentPolicy() throws {
        var assembler = AmiVoiceTranscriptAssembler()
        for raw in [
            "s",
            "S 100",
            "E 1600",
            "S 2000",
            #"U {"text":"Git..."}"#,
            #"A {"text":"GitHub","code":"","utteranceid":"u1"}"#,
            "E 3500",
            #"U {"text":"AP..."}"#,
            #"A {"text":"API","code":"","utteranceid":"u2"}"#,
            #"U {"text":"ノイズ..."}"#,
            #"A {"text":"","code":"o","message":"no speech detected","utteranceid":"u3"}"#,
            "e"
        ] {
            assembler.apply(try AmiVoiceWire.decode(raw))
        }
        check(assembler.openSpeechStartMS == nil)
        check(assembler.speechDurationMS == 3_000)
        check(assembler.speechDurationSeconds == 3.0)
        check(assembler.finalCount == 2)
        check(assembler.rejectedSegmentCount == 1)
        check(assembler.interim.isEmpty)
        check(assembler.fatalError == nil)
        check(assembler.endAcknowledged)
        check(assembler.committedText == "GitHub API")
        check(assembler.recoveryText == "GitHub API")
        check(assembler.completion == .text("GitHub API"))

        var onlyNoSpeech = AmiVoiceTranscriptAssembler()
        onlyNoSpeech.apply(try AmiVoiceWire.decode("S 200"))
        onlyNoSpeech.apply(try AmiVoiceWire.decode("E 900"))
        onlyNoSpeech.apply(try AmiVoiceWire.decode(#"A {"text":"","code":"o","message":"rejected"}"#))
        onlyNoSpeech.apply(try AmiVoiceWire.decode("e"))
        check(onlyNoSpeech.speechDurationMS == 700)
        check(onlyNoSpeech.rejectedSegmentCount == 1)
        check(onlyNoSpeech.fatalError == nil)
        check(onlyNoSpeech.committedText.isEmpty)
        check(onlyNoSpeech.completion == .noSpeech)

        var partialFailure = AmiVoiceTranscriptAssembler()
        partialFailure.apply(try AmiVoiceWire.decode(#"A {"text":"前半の認識。","code":""}"#))
        partialFailure.apply(try AmiVoiceWire.decode(#"U {"text":"後半..."}"#))
        partialFailure.apply(try AmiVoiceWire.decode(#"A {"text":"","code":"b","message":"server busy"}"#))
        partialFailure.apply(try AmiVoiceWire.decode(#"A {"text":"遅着","code":""}"#))
        partialFailure.apply(try AmiVoiceWire.decode("e"))
        check(partialFailure.fatalError == AmiVoiceProviderError(resultCode: "b"))
        check(partialFailure.committedText.isEmpty)
        check(partialFailure.recoveryText == "前半の認識。後半")
        check(partialFailure.completion == .failed(AmiVoiceProviderError(resultCode: "b")))

        var edgeTiming = AmiVoiceTranscriptAssembler()
        edgeTiming.apply(.speechEnd(ms: 500))
        edgeTiming.apply(.speechStart(ms: 1_000))
        edgeTiming.apply(.speechEnd(ms: 400))
        check(edgeTiming.speechDurationMS == 0)
        check(edgeTiming.openSpeechStartMS == nil)
    }

    func assemblerDictationBudgetFailClosedAndMeetingUnlimited() {
        var dictation = AmiVoiceTranscriptAssembler()
        for i in 0..<256 {
            dictation.apply(.interim(String(repeating: "仮", count: 100) + "\(i)"))
        }
        check(!dictation.exceededFinalBudget)
        let chunk = String(repeating: "a", count: 16_384)
        for _ in 0..<16 {
            dictation.apply(.utteranceFinal(AmiVoiceUtteranceResult(text: chunk)))
        }
        check(dictation.exceededFinalBudget)
        check(dictation.finalCount == 15)
        check(dictation.committedText.isEmpty)
        check(dictation.completion == .budgetExceeded)
        check(!dictation.recoveryText.isEmpty)
        let recoveredBeforeLate = dictation.recoveryText
        dictation.apply(.utteranceFinal(AmiVoiceUtteranceResult(text: "遅着")))
        check(dictation.recoveryText == recoveredBeforeLate)

        var countCapped = AmiVoiceTranscriptAssembler(budget: .init(bytes: 1_024, identities: 2))
        countCapped.apply(.utteranceFinal(AmiVoiceUtteranceResult(text: "あ")))
        countCapped.apply(.utteranceFinal(AmiVoiceUtteranceResult(text: "い")))
        check(!countCapped.exceededFinalBudget)
        check(countCapped.committedText == "あい")
        countCapped.apply(.utteranceFinal(AmiVoiceUtteranceResult(text: "う")))
        check(countCapped.exceededFinalBudget)
        check(countCapped.committedText.isEmpty)
        check(countCapped.recoveryText == "あい")
        check(countCapped.completion == .budgetExceeded)

        var oversizedFirst = AmiVoiceTranscriptAssembler(budget: .init(bytes: 8, identities: 4))
        oversizedFirst.apply(.utteranceFinal(AmiVoiceUtteranceResult(text: "日月火水")))
        oversizedFirst.apply(.interim("遅着"))
        check(oversizedFirst.exceededFinalBudget)
        check(oversizedFirst.committedText.isEmpty)
        check(oversizedFirst.recoveryText == "日月")
        check(oversizedFirst.completion == .budgetExceeded)

        var meeting = AmiVoiceTranscriptAssembler(budget: nil)
        let large = String(repeating: "a", count: 300_000)
        meeting.apply(.utteranceFinal(AmiVoiceUtteranceResult(text: large)))
        check(!meeting.exceededFinalBudget)
        check(meeting.committedText.utf8.count == 300_000)
    }
}
