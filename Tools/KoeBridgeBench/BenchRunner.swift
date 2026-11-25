import Foundation
import KoeBridgeCore
import KoeBridgeEngines

@MainActor
final class BenchRunner {
    private let options: BenchOptions
    private let chunkBytes = 1_600

    init(options: BenchOptions) {
        self.options = options
    }

    func run() async throws -> Int32 {
        let manifest = try CorpusManifest.load(from: options.manifestPath)
        let vocabulary = try BenchIO.loadVocabulary(path: options.vocabFile)
        var audioStates: [String: AudioLoadState] = [:]
        for clip in manifest.clips {
            audioStates[clip.id] = BenchIO.inspectAudio(clip: clip, audioDir: options.audioDir)
        }
        if options.live {
            return try await runLive(manifest: manifest, audioStates: audioStates, vocabulary: vocabulary)
        }
        return runDry(manifest: manifest, audioStates: audioStates)
    }

    private func runDry(manifest: CorpusManifest, audioStates: [String: AudioLoadState]) -> Int32 {
        var missing = 0
        var invalid = 0
        var mismatches = 0
        var present = 0
        var lockedVerified = 0
        var trackSeconds: [Int: Double] = [1: 0.0, 2: 0.0]
        var trackBytes: [Int: Int] = [1: 0, 2: 0]

        print("KoeBridgeBench dry-run")
        print("manifest: ok (schema=1 clips=\(manifest.clips.count) language=\(manifest.language))")

        for clip in manifest.clips {
            switch audioStates[clip.id] ?? .missing {
            case .missing:
                missing += 1
                print("clip \(clip.id): missing")
            case .invalid(let reason):
                invalid += 1
                print("clip \(clip.id): invalid_wav (\(reason))")
            case .hashMismatch(let actual):
                mismatches += 1
                print("clip \(clip.id): hash_mismatch actual_pcm_sha256=\(actual)")
            case .loaded(let audio):
                present += 1
                trackSeconds[clip.track, default: 0.0] += audio.seconds
                trackBytes[clip.track, default: 0] += audio.bytes
                if clip.sha256 != nil { lockedVerified += 1 }
                print(String(format: "clip %@: ok pcm_bytes=%d audio_seconds=%.3f pcm_sha256=%@",
                             clip.id, audio.bytes, audio.seconds, audio.sha256))
            }
        }

        print(String(format: "audio: present=%d missing=%d invalid=%d hash_mismatch=%d locked_verified=%d",
                     present, missing, invalid, mismatches, lockedVerified))
        for track in [1, 2] {
            print(String(format: "track%d_present_total: audio_seconds=%.3f pcm_bytes=%d",
                         track, trackSeconds[track] ?? 0.0, trackBytes[track] ?? 0))
        }

        let plannedAmiVoice = plannedAudioSeconds(manifest: manifest, audioStates: audioStates, includeEstimatedForMissing: true)
        let plannedGemini = plannedAmiVoice
        if options.engines.contains(.gemini) {
            print(String(format: "gemini projected audio_seconds=%.1f (no monthly cap is enforced by this tool)", plannedGemini))
        } else {
            print("gemini projected audio_seconds=0.0 (engine not requested)")
        }

        do {
            let ledger = try BenchIO.loadLedger()
            if options.engines.contains(.amivoice) {
                let month = BenchIO.jstMonthKey()
                let consumed = ledger.months[month]?[options.amivoiceEngine] ?? 0.0
                let projected = consumed + plannedAmiVoice
                let state = projected > options.monthlyCapSeconds ? "exceeds_cap" : "within_cap"
                print(String(format: "quota: month_jst=%@ amivoice_engine=%@ ledger_seconds=%.1f planned_seconds=%.1f projected_seconds=%.1f cap_seconds=%.1f status=%@",
                             month, options.amivoiceEngine, consumed, plannedAmiVoice, projected,
                             options.monthlyCapSeconds, state))
            } else {
                print("quota: amivoice not requested; projected_seconds=0.0")
            }
        } catch {
            print("quota: ledger_unreadable (\(BenchIO.errorMessage(error)))")
        }

        // The adjudicated dry-run contract reserves non-zero exits for manifest corruption
        // (already thrown) and locked-hash mismatches. Missing audio is a reported state.
        return mismatches == 0 ? 0 : 1
    }

    private func runLive(
        manifest: CorpusManifest,
        audioStates: [String: AudioLoadState],
        vocabulary: [String]
    ) async throws -> Int32 {
        var ledger = try BenchIO.loadLedger()
        let month = BenchIO.jstMonthKey()
        let plannedSeconds = plannedAudioSeconds(manifest: manifest, audioStates: audioStates, includeEstimatedForMissing: false)
        if options.engines.contains(.amivoice) {
            // AmiVoice bills VAD speech time, but that measurement does not exist before
            // the run. The planned value therefore uses canonical wall-audio seconds as
            // the conservative estimate required by the brief; missing/unreadable clips
            // are not planned because no network call will be made for them.
            let consumed = ledger.months[month]?[options.amivoiceEngine] ?? 0.0
            let projected = consumed + plannedSeconds
            guard projected <= options.monthlyCapSeconds else {
                throw BenchFailure.quota(String(
                    format: "AmiVoice月次上限を超えるためネットワーク呼び出し前に中止します: ledger=%.1fs planned=%.1fs cap=%.1fs",
                    consumed, plannedSeconds, options.monthlyCapSeconds
                ))
            }
        }

        try validateOutputLocation()
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: options.outDir, isDirectory: true),
            withIntermediateDirectories: true
        )

        var apiKeys: [BenchEngine: String] = [:]
        if options.engines.contains(.gemini), let key = BenchIO.geminiAPIKey() { apiKeys[.gemini] = key }
        if options.engines.contains(.amivoice), let key = BenchIO.amiVoiceAPIKey() { apiKeys[.amivoice] = key }

        let runID = BenchIO.runID()
        let gitCommit = BenchIO.gitCommit(manifestPath: options.manifestPath)
        var results: [BenchResultRecord] = []
        var needsEngineCooldown = false

        for (clipIndex, clip) in manifest.clips.enumerated() {
            let orderedEngines = executionOrder(forClipAt: clipIndex)
            let state = audioStates[clip.id] ?? .missing
            guard case .loaded(let audio) = state else {
                let outcome = audioFailureOutcome(state)
                for engine in orderedEngines {
                    results.append(makeRecord(
                        clip: clip,
                        engine: engine,
                        audio: nil,
                        outcome: outcome,
                        vocabulary: vocabulary,
                        gitCommit: gitCommit
                    ))
                }
                continue
            }

            for engine in orderedEngines {
                if needsEngineCooldown {
                    try await Task.sleep(for: .seconds(1))
                }
                needsEngineCooldown = true
                let outcome = await execute(
                    engine: engine,
                    pcm: audio.pcm,
                    audioSeconds: audio.seconds,
                    vocabulary: vocabulary,
                    apiKeys: apiKeys
                )
                results.append(makeRecord(
                    clip: clip,
                    engine: engine,
                    audio: audio,
                    outcome: outcome,
                    vocabulary: vocabulary,
                    gitCommit: gitCommit
                ))

                if engine == .amivoice, outcome.status != "missing_key" {
                    let consumed = outcome.speechSeconds ?? outcome.sentAudioSeconds ?? 0.0
                    if consumed > 0 {
                        var monthEntries = ledger.months[month] ?? [:]
                        monthEntries[options.amivoiceEngine] = (monthEntries[options.amivoiceEngine] ?? 0.0) + consumed
                        ledger.months[month] = monthEntries
                        try BenchIO.saveLedger(ledger)
                    }
                }
            }
        }

        try assertIdenticalHashes(results)
        let jsonlURL = URL(fileURLWithPath: options.outDir, isDirectory: true)
            .appendingPathComponent(runID + ".jsonl")
        let reportURL = URL(fileURLWithPath: options.outDir, isDirectory: true)
            .appendingPathComponent(runID + "-report.md")
        try writeJSONL(results, to: jsonlURL)
        let report = BenchReportBuilder.make(
            runID: runID,
            manifest: manifest,
            results: results,
            options: options,
            gitCommit: gitCommit
        )
        try Data(report.utf8).write(to: reportURL, options: .atomic)
        print("run_id: \(runID)")
        print("results: \(jsonlURL.path)")
        print("report: \(reportURL.path)")
        return 0
    }

    private func plannedAudioSeconds(
        manifest: CorpusManifest,
        audioStates: [String: AudioLoadState],
        includeEstimatedForMissing: Bool
    ) -> Double {
        var total = 0.0
        for clip in manifest.clips {
            switch audioStates[clip.id] ?? .missing {
            case .loaded(let audio):
                total += audio.seconds
            case .missing, .invalid, .hashMismatch:
                if includeEstimatedForMissing { total += clip.estimated_seconds }
            }
        }
        return total
    }

    private func executionOrder(forClipAt index: Int) -> [BenchEngine] {
        switch options.order {
        case .fixed:
            return options.engines
        case .roundRobin:
            let base = [BenchEngine.gemini, .amivoice, .apple].filter { options.engines.contains($0) }
            guard base.count > 1 else { return base }
            let shift = index % base.count
            return Array(base[shift...]) + Array(base[..<shift])
        }
    }

    private func execute(
        engine: BenchEngine,
        pcm: Data,
        audioSeconds: Double,
        vocabulary: [String],
        apiKeys: [BenchEngine: String]
    ) async -> EngineOutcome {
        switch engine {
        case .gemini:
            guard let key = apiKeys[.gemini], !key.isEmpty else {
                return missingKeyOutcome("GEMINI_API_KEY または Keychain dev.koebridge.gemini-api/personal-key")
            }
            return await runGemini(pcm: pcm, audioSeconds: audioSeconds, apiKey: key, vocabulary: vocabulary)
        case .amivoice:
            guard let key = apiKeys[.amivoice], !key.isEmpty else {
                return missingKeyOutcome("AMIVOICE_API_KEY または Keychain dev.koebridge.amivoice-api/api-key")
            }
            return await runAmiVoice(pcm: pcm, audioSeconds: audioSeconds, apiKey: key, vocabulary: vocabulary)
        case .apple:
            return await runApple(pcm: pcm, audioSeconds: audioSeconds)
        }
    }

    private func missingKeyOutcome(_ source: String) -> EngineOutcome {
        var outcome = EngineOutcome()
        outcome.status = "missing_key"
        outcome.error = "APIキーがありません: \(source)"
        return outcome
    }

    private func audioFailureOutcome(_ state: AudioLoadState) -> EngineOutcome {
        var outcome = EngineOutcome()
        switch state {
        case .missing:
            outcome.status = "missing_audio"
            outcome.error = "音声ファイルがありません"
        case .invalid(let reason):
            outcome.status = "invalid_audio"
            outcome.error = reason
        case .hashMismatch:
            outcome.status = "hash_mismatch"
            outcome.error = "ロック済み PCM SHA-256 と一致しません"
        case .loaded:
            outcome.status = "failed"
            outcome.error = "音声状態の解決に失敗しました"
        }
        return outcome
    }

    private func streamPCM(
        _ pcm: Data,
        pacing: BenchPacing,
        send: (Data) async throws -> Void
    ) async throws {
        let startedAt = ContinuousClock.now
        var offset = pcm.startIndex
        var chunkIndex = 0
        while offset < pcm.endIndex {
            if pacing == .realtime {
                let target = startedAt.advanced(by: .milliseconds(50 * chunkIndex))
                let now = ContinuousClock.now
                if target > now {
                    try await Task.sleep(until: target, clock: .continuous)
                }
            }
            let end = min(offset + chunkBytes, pcm.endIndex)
            try await send(Data(pcm[offset..<end]))
            offset = end
            chunkIndex += 1
        }
    }

    private func runGemini(
        pcm: Data,
        audioSeconds: Double,
        apiKey: String,
        vocabulary: [String]
    ) async -> EngineOutcome {
        var outcome = EngineOutcome()
        let connection = GeminiLiveConnection()
        let probe = BenchProbe()
        connection.onEvent = { event in
            switch event {
            case .interim(let text):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    probe.markFirstTranscript()
                }
            case .final(let text):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    probe.markFirstTranscript()
                }
            case .setupComplete, .turnComplete, .activityEnd, .providerError, .error:
                break
            }
        }
        var firstAudioAt: ContinuousClock.Instant?
        let connectStartedAt = ContinuousClock.now
        do {
            try await connection.connect(
                apiKey: apiKey,
                vocabulary: vocabulary,
                style: .verbatim,
                japaneseHint: true
            )
            outcome.connectMS = BenchClock.milliseconds(from: connectStartedAt, to: .now)
            try await streamPCM(pcm, pacing: options.pacing) { chunk in
                if firstAudioAt == nil { firstAudioAt = .now }
                try await connection.sendAudio(chunk)
            }
            let stopStartedAt = ContinuousClock.now
            try await connection.endAudio()
            let text = try await connection.awaitFinal()
            outcome.stopToFinalMS = BenchClock.milliseconds(from: stopStartedAt, to: .now)
            outcome.rawText = text
            outcome.status = "success"
        } catch {
            connection.cancel()
            outcome.status = "failed"
            outcome.error = BenchIO.errorMessage(error)
        }

        let sentSeconds = Double(connection.sentAudioBytes) / 32_000.0
        outcome.sentAudioSeconds = sentSeconds
        outcome.speechSeconds = sentSeconds
        if let firstAudioAt, let firstTranscriptAt = probe.firstTranscript() {
            outcome.ttfiMS = BenchClock.milliseconds(from: firstAudioAt, to: firstTranscriptAt)
        }
        if let sample = connection.tokenSamples.last {
            outcome.geminiTokens = GeminiTokenCounts(
                prompt_tokens: sample.promptTokens,
                candidate_tokens: sample.responseTokens,
                total_tokens: sample.totalTokens
            )
        }
        let promptTokens = connection.tokenSamples.last.flatMap { $0.promptTokens }
        let candidateTokens = connection.tokenSamples.last.flatMap { $0.responseTokens }
        let estimate = BenchmarkCost.geminiEstimate(
            audioSeconds: sentSeconds,
            promptTokens: promptTokens,
            candidateTokens: candidateTokens,
            usdToJPY: options.usdJPY
        )
        outcome.estimatedCostJPY = estimate.tokenJPY ?? estimate.blendedJPY
        return outcome
    }

    private func runAmiVoice(
        pcm: Data,
        audioSeconds: Double,
        apiKey: String,
        vocabulary: [String]
    ) async -> EngineOutcome {
        var outcome = EngineOutcome()
        guard let engine = AmiVoiceEngine(rawValue: options.amivoiceEngine) else {
            outcome.error = "未知のAmiVoiceエンジンです: \(options.amivoiceEngine)"
            return outcome
        }
        let connection = AmiVoiceWebSocketConnection(
            apiKey: apiKey,
            engine: engine,
            vocabulary: vocabulary,
            profileId: nil,
            resultUpdatedIntervalMS: nil
        )
        let probe = BenchProbe()
        connection.onUpdate = { preview in
            if !preview.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                probe.markFirstTranscript()
            }
        }
        var firstAudioAt: ContinuousClock.Instant?
        var firstSend = true
        do {
            try await streamPCM(pcm, pacing: options.pacing) { chunk in
                if firstAudioAt == nil { firstAudioAt = .now }
                let sendStartedAt = ContinuousClock.now
                try await connection.sendAudio(chunk)
                if firstSend {
                    // AmiVoice opens lazily inside the first admitted PCM write. The first
                    // send elapsed time is therefore the closest caller-side connect measure
                    // available without modifying the shared engine implementation.
                    outcome.connectMS = BenchClock.milliseconds(from: sendStartedAt, to: .now)
                    firstSend = false
                }
            }
            let stopStartedAt = ContinuousClock.now
            let text = try await connection.endAudioAndAwaitFinal()
            outcome.stopToFinalMS = BenchClock.milliseconds(from: stopStartedAt, to: .now)
            outcome.rawText = text
            outcome.status = "success"
        } catch {
            connection.cancel()
            outcome.status = "failed"
            outcome.error = BenchIO.errorMessage(error)
        }

        let sentSeconds = Double(connection.sentAudioBytes) / 32_000.0
        outcome.sentAudioSeconds = sentSeconds
        let measuredSpeech = connection.speechDurationSeconds
        outcome.speechSeconds = measuredSpeech > 0 ? measuredSpeech : sentSeconds
        if engine != .e2eJapaneseGeneralBatch,
           let firstAudioAt,
           let firstTranscriptAt = probe.firstTranscript() {
            outcome.ttfiMS = BenchClock.milliseconds(from: firstAudioAt, to: firstTranscriptAt)
        }
        let billableSpeech = outcome.speechSeconds ?? sentSeconds
        outcome.estimatedCostJPY = billableSpeech * engine.nologPriceJPYPerSecond
        return outcome
    }

    private func runApple(pcm: Data, audioSeconds: Double) async -> EngineOutcome {
        var outcome = EngineOutcome()
        let transcriber = LocalTranscriberFactory.make()
        let probe = BenchProbe()
        transcriber.onUpdate = { preview in
            if !preview.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                probe.markFirstTranscript()
            }
        }
        var firstAudioAt: ContinuousClock.Instant?
        var sentBytes = 0
        let connectStartedAt = ContinuousClock.now
        do {
            try await transcriber.start()
            outcome.connectMS = BenchClock.milliseconds(from: connectStartedAt, to: .now)
            try await streamPCM(pcm, pacing: options.pacing) { chunk in
                if firstAudioAt == nil { firstAudioAt = .now }
                try transcriber.appendPCM16(chunk)
                sentBytes += chunk.count
            }
            let stopStartedAt = ContinuousClock.now
            let text = try await transcriber.endAudioAndAwaitFinal()
            outcome.stopToFinalMS = BenchClock.milliseconds(from: stopStartedAt, to: .now)
            outcome.rawText = text
            outcome.status = "success"
        } catch {
            transcriber.cancel()
            outcome.status = "failed"
            outcome.error = BenchIO.errorMessage(error)
        }

        let sentSeconds = Double(sentBytes) / 32_000.0
        outcome.sentAudioSeconds = sentSeconds
        outcome.speechSeconds = sentSeconds
        if let firstAudioAt, let firstTranscriptAt = probe.firstTranscript() {
            outcome.ttfiMS = BenchClock.milliseconds(from: firstAudioAt, to: firstTranscriptAt)
        }
        outcome.estimatedCostJPY = BenchmarkCost.appleCostJPY(audioSeconds: sentSeconds)
        return outcome
    }

    private func makeRecord(
        clip: CorpusClip,
        engine: BenchEngine,
        audio: ClipAudio?,
        outcome: EngineOutcome,
        vocabulary: [String],
        gitCommit: String
    ) -> BenchResultRecord {
        let spacingTransform: @Sendable (String) -> String = {
            JapaneseDictationSpacing.adopt($0, enabled: true, protectedTerms: [])
        }
        var adopted: String?
        var cerNorm: Double?
        var cerStrict: Double?
        var cerStrictSpacing: Double?
        if outcome.status == "success", let raw = outcome.rawText {
            adopted = spacingTransform(raw)
            cerNorm = BenchmarkCER.clipNorm(ref: clip.reference, hyp: raw)
            cerStrict = BenchmarkCER.clipStrict(ref: clip.reference, hyp: raw)
            cerStrictSpacing = BenchmarkCER.clipStrict(ref: clip.reference, hyp: raw, transform: spacingTransform)
        }
        return BenchResultRecord(
            clip_id: clip.id,
            track: clip.track,
            category: clip.category,
            engine: engine.rawValue,
            variant: variant(for: engine, vocabulary: vocabulary),
            pcm_sha256: audio?.sha256,
            pcm_bytes: audio?.bytes,
            audio_seconds: audio?.seconds,
            speech_seconds: outcome.speechSeconds,
            status: outcome.status,
            raw_text: outcome.rawText,
            adopted_text: adopted,
            cer_norm: cerNorm,
            cer_strict: cerStrict,
            cer_strict_spacing: cerStrictSpacing,
            connect_ms: outcome.connectMS,
            ttfi_ms: outcome.ttfiMS,
            stop_to_final_ms: outcome.stopToFinalMS,
            gemini_tokens: outcome.geminiTokens,
            estimated_cost_jpy: outcome.estimatedCostJPY,
            os_version: BenchIO.osVersion(),
            apple_backend: engine == .apple ? BenchIO.appleBackend() : nil,
            git_commit: gitCommit,
            error: outcome.error
        )
    }

    private func variant(for engine: BenchEngine, vocabulary: [String]) -> String {
        let ablation = !vocabulary.isEmpty
        switch engine {
        case .apple:
            return ablation ? "vocab-unsupported" : "baseline"
        case .gemini:
            return ablation ? "vocab-ablation" : "baseline"
        case .amivoice:
            return options.amivoiceEngine + (ablation ? "+vocab" : "")
        }
    }

    private func assertIdenticalHashes(_ results: [BenchResultRecord]) throws {
        let grouped = Dictionary(grouping: results, by: \.clip_id)
        for (clipID, rows) in grouped {
            let hashes = Set(rows.compactMap(\.pcm_sha256))
            guard hashes.count <= 1 else {
                throw BenchFailure.output("同一クリップの pcm_sha256 がエンジン間で一致しません: \(clipID)")
            }
        }
    }

    private func writeJSONL(_ results: [BenchResultRecord], to url: URL) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var data = Data()
            for result in results {
                data.append(try encoder.encode(result))
                data.append(Data([0x0a]))
            }
            try data.write(to: url, options: .atomic)
        } catch {
            throw BenchFailure.output("JSONL結果を書けません: \(url.path)")
        }
    }

    private func validateOutputLocation() throws {
        let outPath = resolvedPath(options.outDir, isDirectory: true)
        for candidate in repositoryRootCandidates() {
            let rootPath = resolvedPath(candidate, isDirectory: true)
            let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            guard outPath != rootPath, !outPath.hasPrefix(rootPrefix) else {
                throw BenchFailure.output("結果出力先はリポジトリ外にしてください: \(options.outDir)")
            }
        }
    }

    private func repositoryRootCandidates() -> [String] {
        var roots: [String] = []
        if let manifestRoot = BenchIO.repoRoot(manifestPath: options.manifestPath) {
            roots.append(manifestRoot)
        }

        var cursor = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        while true {
            let packagePath = cursor.appendingPathComponent("Package.swift").path
            let benchPath = cursor
                .appendingPathComponent("Tools", isDirectory: true)
                .appendingPathComponent("KoeBridgeBench", isDirectory: true)
                .path
            if FileManager.default.fileExists(atPath: packagePath),
               FileManager.default.fileExists(atPath: benchPath) {
                roots.append(cursor.path)
                break
            }
            if cursor.path == "/" { break }
            cursor.deleteLastPathComponent()
        }

        var unique: [String] = []
        for root in roots {
            let resolved = resolvedPath(root, isDirectory: true)
            if !unique.contains(resolved) { unique.append(resolved) }
        }
        return unique
    }

    private func resolvedPath(_ path: String, isDirectory: Bool) -> String {
        URL(fileURLWithPath: path, isDirectory: isDirectory)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}
