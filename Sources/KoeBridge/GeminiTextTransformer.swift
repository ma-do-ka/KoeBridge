#if os(macOS)
import Foundation
import KoeBridgeCore

private final class GeminiTransferDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // The API endpoint is fixed; never forward the API-key header elsewhere.
        completionHandler(nil)
    }
}

@MainActor enum GeminiTextTransformer {
    struct Result {
        let text: String
        let usage: GeminiTokenUsage?
    }

    static func transform(selectedText: String, instruction: String, apiKey: String,
                          timeout: TimeInterval = 30, preserveFullSelection: Bool = false) async throws -> Result {
        try await send(body: GeminiTransformWire.request(selectedText: selectedText, instruction: instruction, preserveFullSelection: preserveFullSelection),
                       apiKey: apiKey, timeout: timeout)
    }

    static func postProcess(text: String, mode: PostProcessingMode, apiKey: String,
                            timeout: TimeInterval) async throws -> Result {
        try await send(body: GeminiPostProcessWire.request(text: text, mode: mode),
                       apiKey: apiKey, timeout: timeout, parse: GeminiPostProcessWire.response)
    }

    private static func send(body: Data, apiKey: String, timeout: TimeInterval,
                             parse: (Data) throws -> String? = GeminiTransformWire.response) async throws -> Result {
        let data = try await GeminiTransfer.send(body: body, endpoint: GeminiTransformWire.endpoint,
                                                apiKey: apiKey, timeout: timeout)
        guard let text = try parse(data) else { throw GeminiRecheckWire.RecheckError.incompleteResponse }
        let usage = String(data: data, encoding: .utf8).flatMap(GeminiWire.parseTokenUsage)
        return Result(text: text, usage: usage)
    }
}

enum GeminiTransfer {
    static func send(body: Data, endpoint: String, apiKey: String, timeout: TimeInterval) async throws -> Data {
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegate = GeminiTransferDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
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
        return data
    }

    /// Enforce the existing response limit while receiving, before URLSession
    /// accumulates an arbitrarily large body. Any failure exits transform's
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
