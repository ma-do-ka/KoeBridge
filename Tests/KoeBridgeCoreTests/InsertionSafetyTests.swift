import Testing
@testable import KoeBridgeCore

struct InsertionSafetyTests {
    @Test(arguments: [false, true]) func neverPasteToWindowOnlyTarget(_ sameProcess: Bool) {
        #expect(!InsertionFocusPolicy.mayPaste(sameProcess: sameProcess, sameWindow: true,
                                               sameElement: nil, selectionMatches: nil))
    }

    @Test func movingTheCaretInTheSameEditorBlocksPasteWhenObservable() {
        #expect(!InsertionFocusPolicy.mayPaste(sameProcess: true, sameWindow: true,
                                               sameElement: true, selectionMatches: false))
    }

    @Test func validCaptureAndCurrentFocusPermitPaste() {
        #expect(InsertionFocusPolicy.mayPaste(sameProcess: true, sameWindow: true,
                                              sameElement: true, selectionMatches: true))
    }

    @Test func unknownCaretMayPasteOnlyWhenTheSameTextFieldIsVerified() {
        #expect(InsertionFocusPolicy.mayPaste(sameProcess: true, sameWindow: true,
                                              sameElement: true, selectionMatches: nil))
    }

    @Test func focusedElementOwnedByDifferentProcessMustBlockPaste() {
        #expect(!InsertionFocusPolicy.mayPaste(sameProcess: true, sameWindow: true,
                                               sameElement: true, selectionMatches: true,
                                               sameElementOwner: false))
    }

    @Test func anotherWindowOrAppMustBlockPaste() {
        for sameProcess in [false, true] {
            for sameWindow in [false, true] {
                if sameProcess && sameWindow { continue }
                #expect(!InsertionFocusPolicy.mayPaste(sameProcess: sameProcess, sameWindow: sameWindow,
                                                       sameElement: true, selectionMatches: true))
            }
        }
    }
}
