#if os(macOS)
import Foundation
import Testing
import KoeBridgeCore
@testable import KoeBridge

@MainActor struct GeminiLiveConnectionTests {
    @Test func providerMessageIsDiscardedBeforeLoggingAndPresentation() throws {
        let marker = "B79-private-request-491bc7"
        let frame = try GeminiWire.decode("""
            {"error":{"message":"\(marker)","status":"\(marker)","code":429}}
            """)
        guard case .providerError(let failure) = frame.events.first else {
            Issue.record("Missing classified provider failure")
            return
        }
        #expect(failure.kind == .rateLimited)
        let diagnostic = GeminiLiveConnection.diagnosticFailure(failure)
        #expect(DiagnosticLogPolicy.sanitizedEvent(diagnostic) == "kind=rateLimited code=429")
        let presentation = GeminiLiveConnection.connectionFailureReason(for: failure)
        #expect(presentation.contains("利用上限"))
        for representation in [String(reflecting: frame), frame.diagnosticKind, diagnostic,
                               presentation, GeminiLiveConnection.ConnectionError.setup(presentation).localizedDescription] {
            #expect(!representation.contains(marker))
        }
    }

    @Test func setupReplyIsMappedOnceBeforeAddingTheAPIPrefix() {
        let raw = "Gemini API: The setup request was rejected."
        let error = GeminiLiveConnection.ConnectionError.setup(raw)
        let reason = GeminiLiveConnection.connectionFailureReason(for: error)
        let presented = GeminiLiveConnection.ConnectionError.setup(reason).errorDescription ?? ""
        #expect(reason == UserFacingErrorMessage.message(for: error, operation: "Geminiへの接続"))
        #expect(presented == "Gemini API: \(reason)")
        #expect(presented.components(separatedBy: "Gemini API: ").count == 2)
        #expect(!presented.contains("Gemini API: Gemini API:"))
        #expect(!presented.contains(raw))
    }

    @Test func connectionFailuresPreserveCuratedDetailAndMapTransportErrors() {
        let disconnected = GeminiLiveConnection.ConnectionError.disconnected
        #expect(GeminiLiveConnection.connectionFailureReason(for: disconnected) == disconnected.errorDescription)
        let transport = NSError(domain: NSURLErrorDomain, code: -1009,
                                userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."])
        let reason = GeminiLiveConnection.connectionFailureReason(for: transport)
        #expect(reason == UserFacingErrorMessage.message(for: transport, operation: "Geminiへの接続"))
        #expect(!reason.contains(transport.localizedDescription))
    }
}
#endif
