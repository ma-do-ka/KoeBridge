import Foundation

public enum TransformMode: String, CaseIterable, Sendable {
    case spoken, preset
}

public struct TransformPreset: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var steps: [String]

    public init(id: UUID = UUID(), name: String, steps: [String] = []) {
        self.id = id
        self.name = name
        self.steps = steps
    }

    public static func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func validStep(_ step: String) -> Bool {
        !step.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var isValid: Bool {
        Self.validName(name) && !steps.isEmpty && steps.allSatisfy(Self.validStep)
    }
}
