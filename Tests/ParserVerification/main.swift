import Foundation
import WeightParsing

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 12))!
let parser = WeightTextParser()

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("验证失败：\(message)\n".utf8))
        exit(1)
    }
}

let chinese = parser.parse("今天的体重是100KG", now: now, calendar: calendar)
require(chinese != nil, "应识别中文语音句子")
require(abs(chinese!.weightKG - 100) < 0.001, "应识别 100 kg")
require(chinese!.date == calendar.startOfDay(for: now), "应识别今天")

let jin = parser.parse("昨天 160斤", now: now, calendar: calendar)
require(abs(jin!.weightKG - 80) < 0.001, "160 斤应换算为 80 kg")
require(
    jin!.date == calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)),
    "应识别昨天"
)

let explicit = parser.parse("2026年8月30日 82.6公斤", now: now, calendar: calendar)
require(abs(explicit!.weightKG - 82.6) < 0.001, "应识别小数体重")
require(
    explicit!.date == calendar.date(from: DateComponents(year: 2026, month: 8, day: 30)),
    "应识别完整日期"
)

let pounds = parser.parse("180 lb", now: now, calendar: calendar)
require(abs(pounds!.weightKG - 81.6466) < 0.001, "应将磅换算为 kg")
require(parser.parse("2026年8月30日", now: now, calendar: calendar) == nil, "不应把日期误识别为体重")

print("文本、单位和日期解析验证通过（5/5）")
