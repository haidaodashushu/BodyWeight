import Foundation
import SwiftData

@Model
final class WeightEntry {
    enum Source: String, Codable, CaseIterable {
        case manual
        case photo
        case voice

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
    var sourceRawValue: String = Source.manual.rawValue
    var originalText: String = ""

    var source: Source {
        get { Source(rawValue: sourceRawValue) ?? .manual }
        set { sourceRawValue = newValue.rawValue }
    }

    init(
        weightKG: Double,
        recordedAt: Date,
        source: Source,
        originalText: String = ""
    ) {
        self.weightKG = weightKG
        self.recordedAt = recordedAt
        self.sourceRawValue = source.rawValue
        self.originalText = originalText
    }
}
