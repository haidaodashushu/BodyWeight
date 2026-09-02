import Foundation
import SwiftData

@Model
final class WeightEntry {
    enum Source: String, Codable, CaseIterable {
        case manual
        case photo
        case voice

        static let availableInputCases: [Source] = [.manual, .voice]

        var title: String {
            switch self {
            case .manual: "手动"
            case .photo: "拍照"
            case .voice: "语音"
            }
        }

        var symbol: String {
            switch self {
            case .manual: "keyboard"
            case .photo: "camera.fill"
            case .voice: "waveform"
            }
        }
    }

    var id: UUID = UUID()
    var weightKG: Double = 0
    var recordedAt: Date = Date()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var sourceRawValue: String = Source.manual.rawValue
    var originalText: String = ""
    var isDeleted: Bool = false
    var photoLocalFilename: String?
    var photoUpdatedAt: Date?

    var source: Source {
        get { Source(rawValue: sourceRawValue) ?? .manual }
        set { sourceRawValue = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        weightKG: Double,
        recordedAt: Date,
        source: Source,
        originalText: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isDeleted: Bool = false,
        photoLocalFilename: String? = nil,
        photoUpdatedAt: Date? = nil
    ) {
        self.id = id
        self.weightKG = weightKG
        self.recordedAt = recordedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceRawValue = source.rawValue
        self.originalText = originalText
        self.isDeleted = isDeleted
        self.photoLocalFilename = photoLocalFilename
        self.photoUpdatedAt = photoUpdatedAt
    }
}
