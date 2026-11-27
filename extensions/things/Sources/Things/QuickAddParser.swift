import Foundation

/// Parses a single-line Quick Add query into a `ThingsDraft`.
///
/// Supported syntax (English & Chinese):
/// - Inline notes: `// notes`
/// - Tags: `#tag`
/// - Project or Area: `@Project`
/// - Deadline: `due:friday`, `ddl:2026-12-01`, `截止:周五`, `截止:明天`
/// - When: `today`, `evening`, `tonight`, `tomorrow`, `anytime`, `someday`,
///   `monday`..`sunday`, `next week`, `in 3 days`, `YYYY-MM-DD`,
///   `今天`, `今晚`, `明天`, `后天`, `随时`, `某天`, `下周`, `周三`, `3天后`,
///   plus optional times (`9am`, `14:30`, `下午3点半`).
enum QuickAddParser {
    static func parse(
        _ input: String,
        containers: [ThingsContainer],
        preferredContainerID: String? = nil,
        defaultWhen: ThingsWhen? = nil,
        now: Date,
        calendar: Calendar
    ) -> ThingsDraft? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1. Split inline notes after `//` (only when preceded by whitespace or at start,
        //    so URLs like `https://example.com` are preserved in the title).
        let mainPart: String
        let notes: String
        if let range = Self.noteSeparatorRange(in: trimmed) {
            mainPart = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            notes = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            mainPart = trimmed
            notes = ""
        }

        let tokens = mainPart.split(whereSeparator: \.isWhitespace).map(String.init)
        var titleTokens: [String] = []
        var tags: [String] = []
        var explicitListName: String?
        var when: ThingsWhen?
        var whenDateOnly: ThingsDate?
        var explicitTime: (hour: Int, minute: Int)?
        var deadline: ThingsDate?

        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let lower = token.lowercased()

            // Tags: #tag
            if token.hasPrefix("#"), token.count > 1 {
                let tag = String(token.dropFirst())
                if !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                    tags.append(tag)
                }
                index += 1
                continue
            }

            // Project or Area: @Name
            if token.hasPrefix("@"), token.count > 1 {
                explicitListName = String(token.dropFirst())
                index += 1
                continue
            }

            // Deadline: due:<expr>, ddl:<expr>, 截止:<expr>
            if let deadlineExpr = extractDeadlinePrefix(token) {
                if let parsed = parseDateWord(deadlineExpr, now: now, calendar: calendar) {
                    deadline = parsed
                    index += 1
                    continue
                }
            }

            // Multi-word English expressions: "next week", "this evening", "in N days"
            if lower == "next", index + 1 < tokens.count, tokens[index + 1].lowercased() == "week" {
                whenDateOnly = nextMonday(now: now, calendar: calendar)
                when = .date(whenDateOnly!)
                index += 2
                continue
            }
            if lower == "this", index + 1 < tokens.count, tokens[index + 1].lowercased() == "evening" {
                when = .evening
                index += 2
                continue
            }
            if lower == "in", index + 2 < tokens.count,
               let days = Int(tokens[index + 1]), days > 0,
               ["d", "day", "days"].contains(tokens[index + 2].lowercased()) {
                let target = addDays(days, to: now, calendar: calendar)
                whenDateOnly = target
                when = .date(target)
                index += 3
                continue
            }

            // Single-token schedule keywords
            if let parsedWhen = parseWhenToken(token, now: now, calendar: calendar) {
                when = parsedWhen.when
                whenDateOnly = parsedWhen.date
                index += 1
                continue
            }

            // Standalone time token (e.g. "9am", "14:30", "下午3点半")
            if let parsedTime = parseTimeToken(token) {
                explicitTime = parsedTime
                index += 1
                continue
            }

            titleTokens.append(token)
            index += 1
        }

        // Combine date + explicit time if present
        if let time = explicitTime {
            let targetDate = whenDateOnly ?? ThingsDate.today(now: now, calendar: calendar)
            when = .dateTime(targetDate, hour: time.hour, minute: time.minute)
        } else if when == nil {
            when = defaultWhen
        }

        let title = titleTokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        // Resolve Project / Area
        var resolvedListID: String?
        var resolvedListTitle: String?
        if let name = explicitListName {
            if let match = matchContainer(named: name, in: containers) {
                resolvedListID = match.id
                resolvedListTitle = match.title
            } else {
                resolvedListTitle = name
            }
        } else if let preferredContainerID,
                  let match = containers.first(where: { $0.id == preferredContainerID }) {
            resolvedListID = match.id
            resolvedListTitle = match.title
        }

        return ThingsDraft(
            title: title,
            notes: notes,
            when: when,
            deadline: deadline,
            listID: resolvedListID,
            listTitle: resolvedListTitle,
            tags: tags
        )
    }

    // MARK: - Helpers

    private static func matchContainer(named name: String, in containers: [ThingsContainer]) -> ThingsContainer? {
        if let exact = containers.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) {
            return exact
        }
        return containers.first(where: { $0.title.localizedCaseInsensitiveContains(name) })
    }

    private static func extractDeadlinePrefix(_ token: String) -> String? {
        let lower = token.lowercased()
        for prefix in ["due:", "ddl:", "deadline:", "截止:", "截止："] {
            if lower.hasPrefix(prefix) {
                let value = String(token.dropFirst(prefix.count))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    private static func parseWhenToken(
        _ token: String,
        now: Date,
        calendar: Calendar
    ) -> (when: ThingsWhen, date: ThingsDate?)? {
        let lower = token.lowercased()
        switch lower {
        case "today", "tod", "今天", "今日":
            return (.today, ThingsDate.today(now: now, calendar: calendar))
        case "evening", "tonight", "今晚", "今天晚上":
            return (.evening, ThingsDate.today(now: now, calendar: calendar))
        case "tomorrow", "tmr", "tom", "明天", "明日":
            return (.tomorrow, addDays(1, to: now, calendar: calendar))
        case "anytime", "随时", "隨時":
            return (.anytime, nil)
        case "someday", "某天", "将来", "將來":
            return (.someday, nil)
        case "后天", "後天":
            let d = addDays(2, to: now, calendar: calendar)
            return (.date(d), d)
        case "下周", "下週", "下周一", "下週一":
            let d = nextMonday(now: now, calendar: calendar)
            return (.date(d), d)
        default:
            if let d = parseDateWord(token, now: now, calendar: calendar) {
                return (.date(d), d)
            }
            return nil
        }
    }

    private static func parseDateWord(_ word: String, now: Date, calendar: Calendar) -> ThingsDate? {
        let lower = word.lowercased()
        switch lower {
        case "today", "tod", "今天", "今日":
            return ThingsDate.today(now: now, calendar: calendar)
        case "tomorrow", "tmr", "tom", "明天", "明日":
            return addDays(1, to: now, calendar: calendar)
        case "后天", "後天":
            return addDays(2, to: now, calendar: calendar)
        case "下周", "下週", "nextweek":
            return nextMonday(now: now, calendar: calendar)
        default:
            break
        }

        // Relative Chinese: "3天后" / "3天後"
        if lower.hasSuffix("天后") || lower.hasSuffix("天後") {
            let numStr = String(lower.dropLast(2))
            if let days = Int(numStr), days > 0 {
                return addDays(days, to: now, calendar: calendar)
            }
        }

        // ISO date: YYYY-MM-DD
        if let iso = parseISODate(lower) {
            return iso
        }

        // Weekday names (English & Chinese)
        if let weekday = parseWeekday(lower) {
            return nextWeekday(weekday, now: now, calendar: calendar)
        }

        return nil
    }

    private static func noteSeparatorRange(in text: String) -> Range<String.Index>? {
        var searchStart = text.startIndex
        while let range = text.range(of: "//", range: searchStart..<text.endIndex) {
            if range.lowerBound == text.startIndex {
                return range
            }
            let before = text[text.index(before: range.lowerBound)]
            if before.isWhitespace {
                return range
            }
            searchStart = range.upperBound
        }
        return nil
    }

    private static func parseISODate(_ text: String) -> ThingsDate? {
        let parts = text.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), parts[0].count == 4,
              let month = Int(parts[1]), (1...12).contains(month),
              let day = Int(parts[2]), (1...31).contains(day) else {
            return nil
        }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = gregorian.date(from: DateComponents(year: year, month: month, day: day)) else {
            return nil
        }
        let roundTrip = gregorian.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else {
            return nil
        }
        return ThingsDate(year: year, month: month, day: day)
    }

    private static func parseWeekday(_ lower: String) -> Int? {
        switch lower {
        case "sun", "sunday", "周日", "週日", "星期日", "星期天": 1
        case "mon", "monday", "周一", "週一", "星期一": 2
        case "tue", "tues", "tuesday", "周二", "週二", "星期二": 3
        case "wed", "wednesday", "周三", "週三", "星期三": 4
        case "thu", "thur", "thurs", "thursday", "周四", "週四", "星期四": 5
        case "fri", "friday", "周五", "週五", "星期五": 6
        case "sat", "saturday", "周六", "週六", "星期六": 7
        default: nil
        }
    }

    private static func parseTimeToken(_ token: String) -> (hour: Int, minute: Int)? {
        let lower = token.lowercased()

        // 12-hour: 9am, 9:30pm, 12pm
        if lower.hasSuffix("am") || lower.hasSuffix("pm") {
            let isPM = lower.hasSuffix("pm")
            let body = String(lower.dropLast(2))
            guard !body.isEmpty else { return nil }
            let parts = body.split(separator: ":", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count),
                  let rawHour = Int(parts[0]), (1...12).contains(rawHour) else { return nil }
            let minute = parts.count == 2 ? (Int(parts[1]) ?? -1) : 0
            guard (0...59).contains(minute) else { return nil }
            var hour = rawHour % 12
            if isPM { hour += 12 }
            return (hour, minute)
        }

        // 24-hour: 14:30, 9:05
        if lower.contains(":") {
            let parts = lower.split(separator: ":")
            if parts.count == 2,
               let hour = Int(parts[0]), (0...23).contains(hour),
               let minute = Int(parts[1]), (0...59).contains(minute) {
                return (hour, minute)
            }
        }

        // Chinese time: 上午9点, 下午3点半, 晚上8点, 9点30
        var rest = lower
        var pmOffset = false
        if rest.hasPrefix("下午") || rest.hasPrefix("晚上") {
            pmOffset = true
            rest = String(rest.dropFirst(2))
        } else if rest.hasPrefix("上午") || rest.hasPrefix("早上") {
            rest = String(rest.dropFirst(2))
        }
        if let dotIndex = rest.firstIndex(where: { $0 == "点" || $0 == "點" }) {
            let hourStr = String(rest[..<dotIndex])
            let after = String(rest[rest.index(after: dotIndex)...])
            guard var hour = Int(hourStr), (0...23).contains(hour) else { return nil }
            let minute: Int
            if after.isEmpty {
                minute = 0
            } else if after == "半" {
                minute = 30
            } else {
                let digits = after.replacingOccurrences(of: "分", with: "")
                guard let m = Int(digits), (0...59).contains(m) else { return nil }
                minute = m
            }
            if pmOffset, hour < 12 { hour += 12 }
            return (hour, minute)
        }

        return nil
    }

    private static func addDays(_ days: Int, to now: Date, calendar: Calendar) -> ThingsDate {
        let start = calendar.startOfDay(for: now)
        let target = calendar.date(byAdding: .day, value: days, to: start) ?? start
        return ThingsDate.today(now: target, calendar: calendar)
    }

    private static func nextMonday(now: Date, calendar: Calendar) -> ThingsDate {
        let start = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: start)
        let offset = (9 - weekday) % 7
        let days = offset == 0 ? 7 : offset
        return addDays(days, to: now, calendar: calendar)
    }

    private static func nextWeekday(_ targetWeekday: Int, now: Date, calendar: Calendar) -> ThingsDate {
        let start = calendar.startOfDay(for: now)
        let current = calendar.component(.weekday, from: start)
        var delta = (targetWeekday - current + 7) % 7
        if delta == 0 { delta = 7 }
        return addDays(delta, to: now, calendar: calendar)
    }
}
