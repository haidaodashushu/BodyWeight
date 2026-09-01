import Foundation

public struct ParsedWeightInput: Equatable, Sendable {
    public let weightKG: Double
    public let date: Date
    public let dateWasExplicit: Bool

    public init(weightKG: Double, date: Date, dateWasExplicit: Bool) {
        self.weightKG = weightKG
        self.date = date
        self.dateWasExplicit = dateWasExplicit
    }
}

public struct WeightTextParser: Sendable {
    public init() {}

    public func parse(
        _ text: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ParsedWeightInput? {
        guard let weight = parseWeight(from: text), (20...500).contains(weight) else {
            return nil
        }

        let parsedDate = parseDate(from: text, now: now, calendar: calendar)
        return ParsedWeightInput(
            weightKG: weight,
            date: parsedDate?.date ?? now,
            dateWasExplicit: parsedDate != nil
        )
    }

    private func parseWeight(from text: String) -> Double? {
        let normalized = text
            .replacingOccurrences(of: "，", with: ".")
            .replacingOccurrences(of: ",", with: ".")
            .lowercased()

        let unitPattern = #"(\d{1,3}(?:\.\d{1,2})?)\s*(kg|公斤|千克|斤|lb|lbs|磅)"#
        if let groups = firstMatch(in: normalized, pattern: unitPattern),
           let value = Double(groups[1]) {
            switch groups[2] {
            case "斤": return value / 2
            case "lb", "lbs", "磅": return value * 0.453_592_37
            default: return value
            }
        }

        let labelledPattern = #"(?:体重|weight)\s*(?:是|为|:|：)?\s*(\d{1,3}(?:\.\d{1,2})?)"#
        if let groups = firstMatch(in: normalized, pattern: labelledPattern),
           let value = Double(groups[1]) {
            return value
        }

        // 纯数字输入用于手动录入；含有日期等其他文本时不猜测，避免把日期当体重。
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(trimmed)
    }

    private func parseDate(
        from text: String,
        now: Date,
        calendar: Calendar
    ) -> (date: Date, explicit: Bool)? {
        let startOfToday = calendar.startOfDay(for: now)
        let lowered = text.lowercased()

        let relativeDays: [(tokens: [String], offset: Int)] = [
            (["前天"], -2),
            (["昨天", "yesterday"], -1),
            (["今天", "今日", "today"], 0)
        ]
        for item in relativeDays where item.tokens.contains(where: lowered.contains) {
            if let date = calendar.date(byAdding: .day, value: item.offset, to: startOfToday) {
                return (date, true)
            }
        }

        let fullDatePatterns = [
            #"(\d{4})\s*[年\-/\.]\s*(\d{1,2})\s*[月\-/\.]\s*(\d{1,2})\s*[日号]?"#,
            #"(\d{4})(\d{2})(\d{2})"#
        ]
        for pattern in fullDatePatterns {
            if let groups = firstMatch(in: lowered, pattern: pattern),
               let year = Int(groups[1]),
               let month = Int(groups[2]),
               let day = Int(groups[3]),
               let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) {
                return (date, true)
            }
        }

        let monthDayPattern = #"(\d{1,2})\s*月\s*(\d{1,2})\s*[日号]?"#
        if let groups = firstMatch(in: lowered, pattern: monthDayPattern),
           let month = Int(groups[1]),
           let day = Int(groups[2]) {
            let year = calendar.component(.year, from: now)
            if let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) {
                return (date, true)
            }
        }

        return nil
    }

    private func firstMatch(in text: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ) else {
            return nil
        }

        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound,
                  let swiftRange = Range(range, in: text) else { return "" }
            return String(text[swiftRange])
        }
    }
}
