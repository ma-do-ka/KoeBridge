import Foundation
import Testing
@testable import KoeBridgeCore

struct AmiVoiceWireTests {
    @Test func nologEndpointPreservesMandatoryTrailingSlash() throws {
        #expect(AmiVoiceWire.nologWebSocketEndpoint == "wss://acp-api.amivoice.com/v1/nolog/")
        #expect(AmiVoiceWire.nologWebSocketEndpoint.hasSuffix("/nolog/"))
        let url = try #require(URL(string: AmiVoiceWire.nologWebSocketEndpoint))
        #expect(url.absoluteString == "wss://acp-api.amivoice.com/v1/nolog/")
        #expect(url.scheme == "wss")
        #expect(url.host == "acp-api.amivoice.com")
    }

    @Test func engineMetadataAndCodableRoundTrip() throws {
        #expect(AmiVoiceEngine.allCases == [
            .e2eJapaneseGeneral,
            .e2eJapaneseGeneralBatch,
            .hybridJapaneseInput,
            .hybridJapaneseConversation
        ])
        #expect(AmiVoiceEngine.e2eJapaneseGeneral.rawValue == "-a2-ja-general")
        #expect(AmiVoiceEngine.e2eJapaneseGeneral.isE2E)
        #expect(AmiVoiceEngine.e2eJapaneseGeneral.supportsInterimPreview)
        #expect(AmiVoiceEngine.e2eJapaneseGeneral.supportsWrittenOnlyBoost)
        #expect(AmiVoiceEngine.e2eJapaneseGeneral.label == "日本語E2E_汎用")

        #expect(AmiVoiceEngine.e2eJapaneseGeneralBatch.rawValue == "-a2b-ja-general")
        #expect(AmiVoiceEngine.e2eJapaneseGeneralBatch.isE2E)
        #expect(!AmiVoiceEngine.e2eJapaneseGeneralBatch.supportsInterimPreview)
        #expect(AmiVoiceEngine.e2eJapaneseGeneralBatch.supportsWrittenOnlyBoost)
        #expect(AmiVoiceEngine.e2eJapaneseGeneralBatch.label == "日本語E2E_汎用バッチ")

        #expect(AmiVoiceEngine.hybridJapaneseInput.rawValue == "-a-general-input")
        #expect(!AmiVoiceEngine.hybridJapaneseInput.isE2E)
        #expect(AmiVoiceEngine.hybridJapaneseInput.supportsInterimPreview)
        #expect(!AmiVoiceEngine.hybridJapaneseInput.supportsWrittenOnlyBoost)
        #expect(AmiVoiceEngine.hybridJapaneseInput.label == "音声入力_汎用")

        #expect(AmiVoiceEngine.hybridJapaneseConversation.rawValue == "-a-general")
        #expect(!AmiVoiceEngine.hybridJapaneseConversation.isE2E)
        #expect(AmiVoiceEngine.hybridJapaneseConversation.supportsInterimPreview)
        #expect(!AmiVoiceEngine.hybridJapaneseConversation.supportsWrittenOnlyBoost)
        #expect(AmiVoiceEngine.hybridJapaneseConversation.label == "会話_汎用")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for engine in AmiVoiceEngine.allCases {
            #expect(engine.id == engine.rawValue)
            #expect(engine.nologPriceJPYPerSecond == 0.04125)
            let encoded = try encoder.encode(engine)
            let decoded = try decoder.decode(AmiVoiceEngine.self, from: encoded)
            #expect(decoded == engine)
        }
    }

    @Test func startAudioAndEndCommandsMatchProtocol() {
        #expect(AmiVoiceWire.audioFormat == "LSB16K")
        #expect(AmiVoiceWire.maximumAudioPacketBytes == 16_000_000)
        #expect(AmiVoiceWire.endCommand == "e")

        let defaultStart = AmiVoiceWire.startCommand()
        #expect(defaultStart == "s LSB16K -a2-ja-general resultUpdatedInterval=300")
        #expect(!defaultStart.contains("authorization="))

        let customInterval = AmiVoiceWire.startCommand(
            engine: .e2eJapaneseGeneral,
            resultUpdatedIntervalMS: 500
        )
        #expect(customInterval == "s LSB16K -a2-ja-general resultUpdatedInterval=500")

        let clampedInterval = AmiVoiceWire.startCommand(
            engine: .e2eJapaneseGeneral,
            resultUpdatedIntervalMS: -250
        )
        #expect(clampedInterval == "s LSB16K -a2-ja-general resultUpdatedInterval=0")

        // Batch E2E never enables interim preview even if an interval is supplied.
        let batchStart = AmiVoiceWire.startCommand(
            engine: .e2eJapaneseGeneralBatch,
            resultUpdatedIntervalMS: 300,
            profileWords: ["KoeBridge"]
        )
        #expect(batchStart == #"s LSB16K -a2b-ja-general resultUpdatedInterval=0 profileWords="KoeBridge""#)

        // Hybrid engines require readings for word registration, so written-only profileWords are omitted.
        let hybridStart = AmiVoiceWire.startCommand(
            engine: .hybridJapaneseInput,
            profileWords: ["KoeBridge", "SwiftUI"]
        )
        #expect(hybridStart == "s LSB16K -a-general-input resultUpdatedInterval=300")

        let hybridWithProfile = AmiVoiceWire.startCommand(
            engine: .hybridJapaneseConversation,
            profileWords: ["KoeBridge"],
            profileId: "team_dict-1"
        )
        #expect(hybridWithProfile == "s LSB16K -a-general resultUpdatedInterval=300 profileId=:team_dict-1")

        // Audio packet prepends ASCII 'p' (0x70) to raw PCM16LE bytes.
        let pcm = Data([0x01, 0x02, 0xfe, 0xff])
        let packet = AmiVoiceWire.audioPacket(pcm)
        #expect(packet == Data([0x70, 0x01, 0x02, 0xfe, 0xff]))
        #expect(AmiVoiceWire.audioPacket(Data()) == Data([0x70]))
    }

    @Test func profileIdSanitizationRejectsReservedAndUnsafeValues() {
        #expect(AmiVoiceWire.sanitizeProfileId("team_01-prod") == "team_01-prod")
        #expect(AmiVoiceWire.sanitizeProfileId(" _single_leading ") == "_single_leading")
        for invalid in [nil, "", "   ", "__reserved", "__", "has space", "a:b", "a|b", "日本語", "bad\"quote", "line\nbreak"] {
            #expect(AmiVoiceWire.sanitizeProfileId(invalid) == nil)
        }

        // Valid profileId suppresses profileWords even on E2E.
        let withId = AmiVoiceWire.startCommand(
            engine: .e2eJapaneseGeneral,
            profileWords: ["KoeBridge"],
            profileId: "user_profile"
        )
        #expect(withId == "s LSB16K -a2-ja-general resultUpdatedInterval=300 profileId=:user_profile")

        // Reserved profileId is rejected and does not emit profileId=:... or profileWords.
        let reserved = AmiVoiceWire.startCommand(
            engine: .e2eJapaneseGeneral,
            profileWords: ["KoeBridge"],
            profileId: "__system"
        )
        #expect(reserved == "s LSB16K -a2-ja-general resultUpdatedInterval=300")
    }

    @Test func profileWordsSanitizationDeduplicationAndCaps() throws {
        let encoded = try #require(AmiVoiceWire.encodeProfileWords([
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
        #expect(encoded == #"GitHub_Actions KoeBridge say_""hi"" 日本語_用語 ab foo_bar"#)
        #expect(!encoded.contains("|"))
        #expect(!encoded.contains(":"))
        #expect(!encoded.contains("\n"))

        let command = AmiVoiceWire.startCommand(
            engine: .e2eJapaneseGeneral,
            profileWords: ["GitHub Actions", #"say "hi""#]
        )
        #expect(command == #"s LSB16K -a2-ja-general resultUpdatedInterval=300 profileWords="GitHub_Actions say_""hi""""#)

        // Empty-after-sanitization list omits profileWords entirely.
        #expect(AmiVoiceWire.encodeProfileWords(["|||", ":::", "   "]) == nil)
        #expect(AmiVoiceWire.startCommand(profileWords: ["|||", ":::"]) == "s LSB16K -a2-ja-general resultUpdatedInterval=300")

        // 100-term cap preserves priority order.
        let manyShort = (0..<150).map { "term\($0)" }
        let cappedCount = try #require(AmiVoiceWire.encodeProfileWords(manyShort))
        let terms = cappedCount.split(separator: " ").map(String.init)
        #expect(terms.count == AmiVoiceWire.maximumProfileWordCount)
        #expect(terms == (0..<100).map { "term\($0)" })

        // 4,096 UTF-8 byte cap with multi-byte Japanese words.
        let manyJapanese = (0..<100).map { "用語\(100 + $0)_" + String(repeating: "あ", count: 30) }
        let cappedBytes = try #require(AmiVoiceWire.encodeProfileWords(manyJapanese))
        #expect(cappedBytes.utf8.count <= AmiVoiceWire.maximumProfileWordsBytes)
        #expect(cappedBytes.utf8.count > 3_900)
        #expect(cappedBytes.split(separator: " ").count < 100)

        // Exact 4,096-byte boundary and quote-expansion accounting.
        let exact = String(repeating: "a", count: AmiVoiceWire.maximumProfileWordsBytes)
        #expect(AmiVoiceWire.encodeProfileWords([exact])?.utf8.count == AmiVoiceWire.maximumProfileWordsBytes)
        let overByOne = String(repeating: "a", count: AmiVoiceWire.maximumProfileWordsBytes + 1)
        #expect(AmiVoiceWire.encodeProfileWords([overByOne]) == nil)
        // Escaping `"` to `""` pushes 4,095 + 2 = 4,097 bytes over budget, while subsequent short term still fits.
        let quoteOverflow = String(repeating: "a", count: AmiVoiceWire.maximumProfileWordsBytes - 1) + "\""
        #expect(AmiVoiceWire.encodeProfileWords([quoteOverflow, "KoeBridge"]) == "KoeBridge")
    }

    @Test func decodeServerFrameRoundTripsAndMalformedRejection() throws {
        #expect(try AmiVoiceWire.decode("s") == .startAck(nil))
        #expect(try AmiVoiceWire.decode("s invalid authorization") == .startAck(AmiVoiceProviderError(command: .start, message: "invalid authorization")))
        #expect(try AmiVoiceWire.decode("p can't feed audio data to recognizer server") == .provideError(AmiVoiceProviderError(command: .provide, message: "can't feed audio data to recognizer server")))
        #expect(try AmiVoiceWire.decode("e") == .endAck(nil))
        #expect(try AmiVoiceWire.decode("e timeout occurred while waiting for audio data") == .endAck(AmiVoiceProviderError(command: .end, message: "timeout occurred")))
        #expect(try AmiVoiceWire.decode("S 0") == .speechStart(ms: 0))
        #expect(try AmiVoiceWire.decode("S 1250") == .speechStart(ms: 1_250))
        #expect(try AmiVoiceWire.decode("E 3400") == .speechEnd(ms: 3_400))
        #expect(try AmiVoiceWire.decode("C") == .recognitionStarted)
        #expect(try AmiVoiceWire.decode("G recording started") == .serverInfo)
        #expect(try AmiVoiceWire.decode("G") == .serverInfo)

        let aFrame = try AmiVoiceWire.decode(#"""
        A {"results":[{"text":"今日は晴れです。","starttime":320,"endtime":1850}],"utteranceid":"20261124/12/abc","text":"今日は晴れです。","code":"","message":""}
        """#)
        #expect(aFrame == .utteranceFinal(AmiVoiceUtteranceResult(
            text: "今日は晴れです。",
            error: nil,
            utteranceID: "20261124/12/abc",
            startTimeMS: 320,
            endTimeMS: 1_850
        )))

        // Top-level starttime/endtime fallback and R event packet.
        let rFrame = try AmiVoiceWire.decode(#"""
        R {"text":"確認します","code":"","utteranceid":"u2","starttime":100,"endtime":900}
        """#)
        #expect(rFrame == .utteranceFinal(AmiVoiceUtteranceResult(
            text: "確認します",
            error: nil,
            utteranceID: "u2",
            startTimeMS: 100,
            endTimeMS: 900
        )))

        // Malformed frames must fail closed rather than silently succeeding.
        #expect(throws: AmiVoiceWireError.emptyFrame) { _ = try AmiVoiceWire.decode("") }
        for malformed in ["start", "p", "end", "S", "S -1", "S abc", "E ", "C extra", "GARBAGE", "X 123", "U", "A", "R"] {
            #expect(throws: AmiVoiceWireError.malformedFrame) { _ = try AmiVoiceWire.decode(malformed) }
        }
        for badJSON in ["U not-json", "U []", "U null", "A {bad}", "A []", "A {\"code\":123}", "R null"] {
            #expect(throws: AmiVoiceWireError.invalidJSON) { _ = try AmiVoiceWire.decode(badJSON) }
        }
    }

    @Test func interimEllipsisStrippingAndEmptyInterimHandling() throws {
        #expect(try AmiVoiceWire.decode(#"U {"text":"こんにちは..."}"#) == .interim("こんにちは"))
        #expect(try AmiVoiceWire.decode(#"U {"text":"こんにちは ..."}"#) == .interim("こんにちは"))
        #expect(try AmiVoiceWire.decode(#"U {"text":"..."}"#) == .interim(""))
        #expect(try AmiVoiceWire.decode(#"U {"text":"  ...  "}"#) == .interim(""))
        #expect(try AmiVoiceWire.decode(#"U {"text":""}"#) == .interim(""))
        #expect(try AmiVoiceWire.decode(#"U {}"#) == .interim(""))
        #expect(try AmiVoiceWire.decode(#"U {"text":"こんにちは"}"#) == .interim("こんにちは"))
        // Only one trailing ASCII "..." dummy token is stripped; Unicode ellipsis is preserved.
        #expect(try AmiVoiceWire.decode(#"U {"text":"テスト......"}"#) == .interim("テスト..."))
        #expect(try AmiVoiceWire.decode(#"U {"text":"テスト…"}"#) == .interim("テスト…"))

        // Empty U frames (such as -a2b-ja-general) are ignored by the assembler.
        var assembler = AmiVoiceTranscriptAssembler()
        assembler.apply(.interim(""))
        #expect(assembler.interim.isEmpty)
        #expect(assembler.preview == RecognitionPreview())
        assembler.apply(.interim("入力中"))
        assembler.apply(.interim(""))
        #expect(assembler.interim == "入力中")
        #expect(assembler.preview == RecognitionPreview(finalizedPrefix: "", volatileTail: "入力中"))
    }

    @Test func providerErrorClassificationAndZeroLeakBoundary() throws {
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
            #expect(err.kind == expectedKind)
            #expect(err.errorDescription?.isEmpty == false)
            #expect(DiagnosticLogPolicy.sanitizedEvent(err.diagnostic) == err.diagnostic)
        }

        // Documented WebSocket command error strings classify accurately.
        #expect(AmiVoiceProviderError(command: .start, message: "invalid authorization").kind == .authentication)
        #expect(AmiVoiceProviderError(command: .start, message: "can't allocate recognizer").kind == .serverBusy)
        #expect(AmiVoiceProviderError(command: .start, message: "invalid audio format").kind == .unsupportedAudio)
        #expect(AmiVoiceProviderError(command: .provide, message: "can't feed audio data to recognizer server").kind == .serverUnavailable)
        #expect(AmiVoiceProviderError(command: .end, message: "timeout occurred while waiting for audio data").kind == .timeout)

        // Raw provider error strings must never cross the decode boundary.
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
                #expect(result.text.isEmpty)
                let err = try #require(result.error)
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
                Issue.record("Unexpected frame for sentinel check: \(frame.diagnosticKind)")
            }
            for rep in representations {
                #expect(!rep.contains(sentinel))
            }
        }
    }

    @Test func assemblerInterleavedSpeechDurationAndNoSpeechSegmentPolicy() throws {
        // Interleaved E(k), S(k+1), A(k), E(k+1), A(k+1) sequence + ASCII boundary spacing.
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
        #expect(assembler.openSpeechStartMS == nil)
        #expect(assembler.speechDurationMS == 3_000)
        #expect(assembler.speechDurationSeconds == 3.0)
        #expect(assembler.finalCount == 2)
        #expect(assembler.rejectedSegmentCount == 1)
        #expect(assembler.interim.isEmpty)
        #expect(assembler.fatalError == nil)
        #expect(assembler.endAcknowledged)
        #expect(assembler.committedText == "GitHub API")
        #expect(assembler.recoveryText == "GitHub API")
        #expect(assembler.completion == .text("GitHub API"))

        // Whole-result code=="o" with zero committed segments yields .noSpeech on e ack.
        var onlyNoSpeech = AmiVoiceTranscriptAssembler()
        onlyNoSpeech.apply(try AmiVoiceWire.decode("S 200"))
        onlyNoSpeech.apply(try AmiVoiceWire.decode("E 900"))
        onlyNoSpeech.apply(try AmiVoiceWire.decode(#"A {"text":"","code":"o","message":"rejected"}"#))
        onlyNoSpeech.apply(try AmiVoiceWire.decode("e"))
        #expect(onlyNoSpeech.speechDurationMS == 700)
        #expect(onlyNoSpeech.rejectedSegmentCount == 1)
        #expect(onlyNoSpeech.fatalError == nil)
        #expect(onlyNoSpeech.committedText.isEmpty)
        #expect(onlyNoSpeech.completion == .noSpeech)

        // Non-"o" error in a later A segment fails closed (no auto-paste), retaining recovery prefix.
        var partialFailure = AmiVoiceTranscriptAssembler()
        partialFailure.apply(try AmiVoiceWire.decode(#"A {"text":"前半の認識。","code":""}"#))
        partialFailure.apply(try AmiVoiceWire.decode(#"U {"text":"後半..."}"#))
        partialFailure.apply(try AmiVoiceWire.decode(#"A {"text":"","code":"b","message":"server busy"}"#))
        // Late frames after a fatal error cannot overwrite or clear the failure.
        partialFailure.apply(try AmiVoiceWire.decode(#"A {"text":"遅着","code":""}"#))
        partialFailure.apply(try AmiVoiceWire.decode("e"))
        #expect(partialFailure.fatalError == AmiVoiceProviderError(resultCode: "b"))
        #expect(partialFailure.committedText.isEmpty)
        #expect(partialFailure.recoveryText == "前半の認識。後半")
        #expect(partialFailure.completion == .failed(AmiVoiceProviderError(resultCode: "b")))

        // Unpaired or reversed S/E timestamps never produce negative duration.
        var edgeTiming = AmiVoiceTranscriptAssembler()
        edgeTiming.apply(.speechEnd(ms: 500))
        edgeTiming.apply(.speechStart(ms: 1_000))
        edgeTiming.apply(.speechEnd(ms: 400))
        #expect(edgeTiming.speechDurationMS == 0)
        #expect(edgeTiming.openSpeechStartMS == nil)
    }

    @Test func assemblerDictationBudgetFailClosedAndMeetingUnlimited() {
        // Default dictation budget (256 KiB UTF-8): crossing 256 KiB fails closed.
        var dictation = AmiVoiceTranscriptAssembler()
        // Repeated interims do not consume the final budget.
        for i in 0..<256 {
            dictation.apply(.interim(String(repeating: "仮", count: 100) + "\(i)"))
        }
        #expect(!dictation.exceededFinalBudget)
        let chunk = String(repeating: "a", count: 16_384)
        for _ in 0..<16 {
            dictation.apply(.utteranceFinal(AmiVoiceUtteranceResult(text: chunk)))
        }
        // 16 * 16,384 + 15 ASCII spaces = 262,159 > 262,144 (256 KiB) -> 16th segment triggers budget!
        #expect(dictation.exceededFinalBudget)
        #expect(dictation.finalCount == 15)
        #expect(dictation.committedText.isEmpty)
        #expect(dictation.completion == .budgetExceeded)
        #expect(!dictation.recoveryText.isEmpty)
        let recoveredBeforeLate = dictation.recoveryText
        dictation.apply(.utteranceFinal(AmiVoiceUtteranceResult(text: "遅着")))
        #expect(dictation.recoveryText == recoveredBeforeLate)

        // Utterance-count (identities) cap fails closed.
        var countCapped = AmiVoiceTranscriptAssembler(budget: .init(bytes: 1_024, identities: 2))
        countCapped.apply(.utteranceFinal(AmiVoiceUtteranceResult(text: "あ")))
        countCapped.apply(.utteranceFinal(AmiVoiceUtteranceResult(text: "い")))
        #expect(!countCapped.exceededFinalBudget)
        #expect(countCapped.committedText == "あい")
        countCapped.apply(.utteranceFinal(AmiVoiceUtteranceResult(text: "う")))
        #expect(countCapped.exceededFinalBudget)
        #expect(countCapped.committedText.isEmpty)
        #expect(countCapped.recoveryText == "あい")
        #expect(countCapped.completion == .budgetExceeded)

        // Oversized first final preserves only whole Unicode scalars for manual recovery.
        var oversizedFirst = AmiVoiceTranscriptAssembler(budget: .init(bytes: 8, identities: 4))
        oversizedFirst.apply(.utteranceFinal(AmiVoiceUtteranceResult(text: "日月火水")))
        oversizedFirst.apply(.interim("遅着"))
        #expect(oversizedFirst.exceededFinalBudget)
        #expect(oversizedFirst.committedText.isEmpty)
        #expect(oversizedFirst.recoveryText == "日月")
        #expect(oversizedFirst.completion == .budgetExceeded)

        // Unlimited budget (nil, for MeetingSession) accepts >2,048 segments and >256 KiB.
        var meeting = AmiVoiceTranscriptAssembler(budget: nil)
        let large = String(repeating: "a", count: 300_000)
        meeting.apply(.utteranceFinal(AmiVoiceUtteranceResult(text: large)))
        #expect(!meeting.exceededFinalBudget)
        #expect(meeting.committedText.utf8.count == 300_000)
    }
}
