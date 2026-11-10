#if os(macOS)
import Foundation
import KoeBridgeCore

@MainActor struct LastDeliveryAnchor {
    let target: InsertionTarget
    let before: InsertionReceiptPolicy.Snapshot
    let after: InsertionReceiptPolicy.Snapshot
    let submittedText: String
    let sourceRecordID: UUID?
    let deliveredAt: Date

    init(receipt: TextInsertion.Receipt, sourceRecordID: UUID?) {
        target = receipt.target
        before = receipt.proof.before
        after = receipt.proof.after
        submittedText = receipt.proof.inserted
        self.sourceRecordID = sourceRecordID
        deliveredAt = Date()
    }
}
#endif
