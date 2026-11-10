#if os(macOS)
import Foundation
import KoeBridgeCore

private final class RecheckSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // The API endpoint is fixed; never forward the API-key header elsewhere.
        completionHandler(nil)
    }
}

@MainActor enum GeminiAudioRechecker {
    struct Result {
        let text: String
        let usage: GeminiTokenUsage?
    }

    static func recognize(pcm16LE: Data, vocabulary: [String], style: TranscriptionStyle,
                          japaneseHint: Bool, apiKey: String, timeout: TimeInterval, context: String? = nil) async throws -> Result {
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegate = RecheckSessionDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: GeminiRecheckWire.endpoint)!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try GeminiRecheckWire.request(pcm16LE: pcm16LE, vocabulary: vocabulary,
                                                       style: style, japaneseHint: japaneseHint, context: context)
        let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw GeminiRecheckWire.RecheckError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw GeminiRecheckWire.RecheckError.http(http.statusCode) }
        let data = try await withTaskCancellationHandler {
            try await readResponse(bytes)
        } onCancel: {
            session.invalidateAndCancel()
        }
        try Task.checkCancellation()
        let text = try GeminiRecheckWire.response(data)
        let usage = String(data: data, encoding: .utf8).flatMap(GeminiWire.parseTokenUsage)
        return Result(text: text, usage: usage)
    }

    /// Enforce the existing response limit while receiving, before URLSession
    /// accumulates an arbitrarily large body. Any failure exits recognize's
    /// scope and invalidates the session, including the still-active transfer.
    /// Byte collection runs off the UI actor even when bytes are buffered.
    private nonisolated static func readResponse(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < GeminiRecheckWire.maximumResponseBytes else {
                throw GeminiRecheckWire.RecheckError.invalidResponse
            }
            data.append(byte)
        }
        return data
    }
}
#endif
