import Foundation

/// Parses a single natural-language line into a structured `ReminderDraft`
/// without external dependencies. Supports English and Chinese dates/times,
/// priority markers (`!`, `!!`, `!!!`, `!high`), `#List` / `@List` mentions,
/// `#tags`, and optional inline notes after `//`.
enum QuickAddParser {
    static func parse(
        _ input: String,
        lists: [ReminderList],
        defaultListName: String? = nil,
        preferredListID: String? = nil,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> ReminderDraft? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Split inline notes after `//` when separated by whitespace.
        var working: String
        var notes: String?
        if let separator = trimmed.range(of: " // ") ?? trimmed.range(of: "// ") {
            working = String(trimmed[..<separator.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let noteText = String(trimmed[separator.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !noteText.isEmpty { notes = noteText }
        } else {
            working = trimmed
        }
        let fallbackTitle = working.isEmpty ? trimmed : working

        // 1. Extract explicit list mention (`#List` or `@List`, longest name first).
        var matchedList: ReminderList?
        let sortedLists = lists.sorted { $0.title.count > $1.title.count }
        for list in sortedLists where !list.title.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: list.title)
            let pattern = #"(?:^|\s)[#@]"# + escaped + #"(?=$|\s|[,.;:!?，。；：！？])"#
            if let range = firstRegexRange(pattern, in: working, caseInsensitive: true) {
                matchedList = list
                working.replaceSubrange(range, with: " ")
                break
            }
        }

        // 2. Extract priority markers.
        var priority: ReminderPriority = .none
        let priorityRules: [(String, ReminderPriority)] = [
            (#"(?:^|\s)(?:!!!|!high)(?=$|\s)"#, .high),
            (#"(?:^|\s)(?:!!|!medium|!med)(?=$|\s)"#, .medium),
            (#"(?:^|\s)(?:!|!low)(?=$|\s)"#, .low),
        ]
        for (pattern, level) in priorityRules {
            if let range = firstRegexRange(pattern, in: working, caseInsensitive: true) {
                priority = level
                working.replaceSubrange(range, with: " ")
                break
            }
        }

        // 3. Extract remaining `#tags`.
        var tags = [String]()
        let tagPattern = #"(?:^|\s)#([^\s#,.;:!?()\[\]{}，。；：！？]+)"#
        if let regex = try? NSRegularExpression(pattern: tagPattern) {
            let matches = regex.matches(in: working, range: NSRange(working.startIndex..<working.endIndex, in: working))
            for match in matches.reversed() {
                guard match.numberOfRanges > 1,
                      let tagRange = Range(match.range(at: 1), in: working),
                      let fullRange = Range(match.range, in: working)
                else { continue }
                let tag = String(working[tagRange])
                if !tag.isEmpty, !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                    tags.insert(tag, at: 0)
                }
                working.replaceSubrange(fullRange, with: " ")
            }
        }

        // 4. Extract due date and time.
        let (dueDate, withoutDate) = extractDueDate(from: working, now: now, calendar: calendar)
        working = withoutDate

        // 5. Resolve fallback list when no explicit list was mentioned.
        if matchedList == nil, let preferredListID {
            matchedList = lists.first { $0.id == preferredListID }
        }
        if matchedList == nil, let defaultListName {
            let cleaned = defaultListName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                matchedList = lists.first { $0.title.caseInsensitiveCompare(cleaned) == .orderedSame }
            }
        }

        let cleanedTitle = collapseWhitespace(working)
        let title = cleanedTitle.isEmpty ? collapseWhitespace(fallbackTitle) : cleanedTitle
        guard !title.isEmpty else { return nil }

        return ReminderDraft(
            title: title,
            notes: notes,
            listID: matchedList?.id,
            listTitle: matchedList?.title,
            dueDate: dueDate,
            priority: priority,
            tags: tags
        )
    }

    // MARK: - Date & Time Parsing

    private static func extractDueDate(
        from text: String,
        now: Date,
        calendar: Calendar
    ) -> (ReminderDueDate?, String) {
        var working = text

        // A. Relative offsets: `in 30m`, `in 2 hours`, `in 3 days`, `30分钟后`, `2小时后`, `3天后`.
        if let result = matchRelativeOffset(in: working, now: now, calendar: calendar) {
            return result
        }

        // B. Calendar date phrase (optional).
        var dayComponents: (year: Int, month: Int, day: Int)?

        // Explicit ISO date: YYYY-MM-DD
        if let match = firstMatch(#"(?:^|\s)(\d{4})-(\d{1,2})-(\d{1,2})(?=$|\s)"#, in: working),
           let year = Int(match.groups[1]),
           let month = Int(match.groups[2]),
           let day = Int(match.groups[3]),
           isValidDate(year: year, month: month, day: day, calendar: calendar) {
            dayComponents = (year, month, day)
            working.replaceSubrange(match.fullRange, with: " ")
        }
        // Chinese date: M月D日 / M月D号
        else if let match = firstMatch(#"(?:^|\s)(\d{1,2})月(\d{1,2})[日号](?=$|\s|\d|上|下|晚|早|中)"#, in: working),
                let month = Int(match.groups[1]),
                let day = Int(match.groups[2]),
                let resolved = resolveMonthDay(month: month, day: day, now: now, calendar: calendar) {
            dayComponents = resolved
            working.replaceSubrange(match.fullRange, with: " ")
        }
        // Relative day words (Chinese and English).
        else if let (resolved, range) = matchRelativeDay(in: working, now: now, calendar: calendar) {
            dayComponents = resolved
            working.replaceSubrange(range, with: " ")
        }
        // Weekday names (`monday`, `next friday`, `周五`, `下周一`, `星期三`).
        else if let (resolved, range) = matchWeekday(in: working, now: now, calendar: calendar) {
            dayComponents = resolved
            working.replaceSubrange(range, with: " ")
        }

        // C. Clock time (optional).
        var clock: (hour: Int, minute: Int)?
        if let (parsedClock, range) = matchClockTime(in: working) {
            clock = parsedClock
            working.replaceSubrange(range, with: " ")
        }

        // Combine date + clock.
        if let day = dayComponents, let clock {
            var comps = DateComponents()
            comps.calendar = calendar
            comps.timeZone = calendar.timeZone
            comps.year = day.year
            comps.month = day.month
            comps.day = day.day
            comps.hour = clock.hour
            comps.minute = clock.minute
            comps.second = 0
            if let date = calendar.date(from: comps) {
                return (.timed(date), working)
            }
        } else if let day = dayComponents {
            return (.allDay(year: day.year, month: day.month, day: day.day), working)
        } else if let clock {
            let todayParts = calendar.dateComponents([.year, .month, .day], from: now)
            var comps = DateComponents()
            comps.calendar = calendar
            comps.timeZone = calendar.timeZone
            comps.year = todayParts.year
            comps.month = todayParts.month
            comps.day = todayParts.day
            comps.hour = clock.hour
            comps.minute = clock.minute
            comps.second = 0
            if var date = calendar.date(from: comps) {
                if date <= now, let nextDay = calendar.date(byAdding: .day, value: 1, to: date) {
                    date = nextDay
                }
                return (.timed(date), working)
            }
        }

        return (nil, text)
    }

    private static func matchRelativeOffset(
        in text: String,
        now: Date,
        calendar: Calendar
    ) -> (ReminderDueDate, String)? {
        // English: `in 30m`, `in 2 hours`, `in 3 days`
        let enPattern = #"(?:^|\s)in\s+(\d+)\s*(m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days)(?=$|\s)"#
        if let match = firstMatch(enPattern, in: text, caseInsensitive: true),
           let amount = Int(match.groups[1]), amount > 0 {
            let unit = match.groups[2].lowercased()
            var stripped = text
            stripped.replaceSubrange(match.fullRange, with: " ")
            if unit.hasPrefix("m") {
                return (.timed(now.addingTimeInterval(Double(amount) * 60)), stripped)
            }
            if unit.hasPrefix("h") {
                return (.timed(now.addingTimeInterval(Double(amount) * 3600)), stripped)
            }
            if unit.hasPrefix("d"),
               let date = calendar.date(byAdding: .day, value: amount, to: calendar.startOfDay(for: now)) {
                let parts = calendar.dateComponents([.year, .month, .day], from: date)
                if let y = parts.year, let m = parts.month, let d = parts.day {
                    return (.allDay(year: y, month: m, day: d), stripped)
                }
            }
        }

        // Chinese: `30分钟后`, `2小时后`, `3天后`
        let zhPattern = #"(?:^|\s)(\d+)\s*(分钟|小时|天)[之以]?后(?=$|\s)"#
        if let match = firstMatch(zhPattern, in: text),
           let amount = Int(match.groups[1]), amount > 0 {
            let unit = match.groups[2]
            var stripped = text
            stripped.replaceSubrange(match.fullRange, with: " ")
            switch unit {
            case "分钟":
                return (.timed(now.addingTimeInterval(Double(amount) * 60)), stripped)
            case "小时":
                return (.timed(now.addingTimeInterval(Double(amount) * 3600)), stripped)
            case "天":
                if let date = calendar.date(byAdding: .day, value: amount, to: calendar.startOfDay(for: now)) {
                    let parts = calendar.dateComponents([.year, .month, .day], from: date)
                    if let y = parts.year, let m = parts.month, let d = parts.day {
                        return (.allDay(year: y, month: m, day: d), stripped)
                    }
                }
            default:
                break
            }
        }
        return nil
    }

    private static func matchRelativeDay(
        in text: String,
        now: Date,
        calendar: Calendar
    ) -> ((Int, Int, Int), Range<String.Index>)? {
        let start = calendar.startOfDay(for: now)
        let patterns: [(String, Int)] = [
            (#"(?:^|\s)(?:大后天)(?=$|\s|\d|上|下|晚|早|中)"#, 3),
            (#"(?:^|\s)(?:后天)(?=$|\s|\d|上|下|晚|早|中)"#, 2),
            (#"(?:^|\s)(?:明天|明日|tomorrow|tmr|tom)(?=$|\s|\d|上|下|晚|早|中)"#, 1),
            (#"(?:^|\s)(?:今天|今日|today|tod)(?=$|\s|\d|上|下|晚|早|中)"#, 0),
            (#"(?:^|\s)(?:next\s+week|下周)(?=$|\s)"#, 7),
        ]
        for (pattern, offset) in patterns {
            if let range = firstRegexRange(pattern, in: text, caseInsensitive: true),
               let date = calendar.date(byAdding: .day, value: offset, to: start) {
                let parts = calendar.dateComponents([.year, .month, .day], from: date)
                if let y = parts.year, let m = parts.month, let d = parts.day {
                    return ((y, m, d), range)
                }
            }
        }
        return nil
    }

    private static func matchWeekday(
        in text: String,
        now: Date,
        calendar: Calendar
    ) -> ((Int, Int, Int), Range<String.Index>)? {
        let start = calendar.startOfDay(for: now)
        let currentWeekday = calendar.component(.weekday, from: start) // 1 = Sun ... 7 = Sat

        // Chinese: `[下](?:周|星期)[一二三四五六日天]`
        let zhPattern = #"(?:^|\s)(下)?(?:周|星期)([一二三四五六日天])(?=$|\s|\d|上|下|晚|早|中)"#
        if let match = firstMatch(zhPattern, in: text) {
            let isNext = !match.groups[1].isEmpty
            let targetWeekday: Int? = switch match.groups[2] {
            case "日", "天": 1
            case "一": 2
            case "二": 3
            case "三": 4
            case "四": 5
            case "五": 6
            case "六": 7
            default: nil
            }
            if let targetWeekday,
               let resolved = resolveWeekday(targetWeekday, from: start, currentWeekday: currentWeekday, forceNextWeek: isNext, calendar: calendar) {
                return (resolved, match.fullRange)
            }
        }

        // English: `[next] (monday|mon|...)`
        let enPattern = #"(?:^|\s)(next\s+)?(monday|mon|tuesday|tue|tues|wednesday|wed|thursday|thu|thur|thurs|friday|fri|saturday|sat|sunday|sun)(?=$|\s)"#
        if let match = firstMatch(enPattern, in: text, caseInsensitive: true) {
            let isNext = !match.groups[1].isEmpty
            let dayName = match.groups[2].lowercased()
            let targetWeekday: Int? = switch dayName {
            case "sunday", "sun": 1
            case "monday", "mon": 2
            case "tuesday", "tue", "tues": 3
            case "wednesday", "wed": 4
            case "thursday", "thu", "thur", "thurs": 5
            case "friday", "fri": 6
            case "saturday", "sat": 7
            default: nil
            }
            if let targetWeekday,
               let resolved = resolveWeekday(targetWeekday, from: start, currentWeekday: currentWeekday, forceNextWeek: isNext, calendar: calendar) {
                return (resolved, match.fullRange)
            }
        }
        return nil
    }

    private static func resolveWeekday(
        _ targetWeekday: Int,
        from startOfToday: Date,
        currentWeekday: Int,
        forceNextWeek: Bool,
        calendar: Calendar
    ) -> (Int, Int, Int)? {
        var delta = (targetWeekday - currentWeekday + 7) % 7
        if delta == 0 {
            delta = 7
        } else if forceNextWeek {
            // Move into the following calendar week if target is still later this week.
            let mondayBasedCurrent = (currentWeekday + 5) % 7 // Mon=0 ... Sun=6
            let mondayBasedTarget = (targetWeekday + 5) % 7
            if mondayBasedTarget > mondayBasedCurrent {
                delta += 7
            }
        }
        guard let date = calendar.date(byAdding: .day, value: delta, to: startOfToday) else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let y = parts.year, let m = parts.month, let d = parts.day else { return nil }
        return (y, m, d)
    }

    private static func matchClockTime(in text: String) -> ((hour: Int, minute: Int), Range<String.Index>)? {
        // 1. English 12-hour clock: `[at] 9am`, `[at] 3:30 pm`
        let ampmPattern = #"(?:^|\s)(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)(?=$|\s)"#
        if let match = firstMatch(ampmPattern, in: text, caseInsensitive: true),
           var hour = Int(match.groups[1]), (1...12).contains(hour) {
            let minute = match.groups[2].isEmpty ? 0 : (Int(match.groups[2]) ?? -1)
            guard (0...59).contains(minute) else { return nil }
            let period = match.groups[3].lowercased()
            if period == "pm", hour < 12 { hour += 12 }
            if period == "am", hour == 12 { hour = 0 }
            return ((hour, minute), match.fullRange)
        }

        // 2. Chinese clock time: `[上午|下午|晚上|早上|中午] 9点[半|30[分]]`
        let zhClockPattern = #"(?:^|\s)(上午|早上|凌晨|中午|下午|傍晚|晚上)?\s*(\d{1,2})[点點](半|(\d{1,2})分?)?(?=$|\s)"#
        if let match = firstMatch(zhClockPattern, in: text),
           var hour = Int(match.groups[2]), (0...23).contains(hour) {
            let period = match.groups[1]
            let tail = match.groups[3]
            let minute: Int
            if tail == "半" {
                minute = 30
            } else if !match.groups[4].isEmpty, let parsed = Int(match.groups[4]), (0...59).contains(parsed) {
                minute = parsed
            } else if tail.isEmpty {
                minute = 0
            } else {
                return nil
            }
            if ["下午", "傍晚", "晚上"].contains(period), hour >= 1, hour < 12 {
                hour += 12
            } else if period == "中午", hour >= 1, hour < 11 {
                hour += 12
            } else if period == "凌晨", hour == 12 {
                hour = 0
            }
            return ((hour, minute), match.fullRange)
        }

        // 3. 24-hour clock: `[at] 14:30`, `09:00`
        let clock24Pattern = #"(?:^|\s)(?:at\s+)?([01]?\d|2[0-3]):([0-5]\d)(?=$|\s)"#
        if let match = firstMatch(clock24Pattern, in: text, caseInsensitive: true),
           let hour = Int(match.groups[1]),
           let minute = Int(match.groups[2]) {
            return ((hour, minute), match.fullRange)
        }

        return nil
    }

    private static func resolveMonthDay(
        month: Int,
        day: Int,
        now: Date,
        calendar: Calendar
    ) -> (Int, Int, Int)? {
        let currentYear = calendar.component(.year, from: now)
        let startOfToday = calendar.startOfDay(for: now)
        if isValidDate(year: currentYear, month: month, day: day, calendar: calendar) {
            var comps = DateComponents()
            comps.calendar = calendar
            comps.timeZone = calendar.timeZone
            comps.year = currentYear
            comps.month = month
            comps.day = day
            if let date = calendar.date(from: comps), date >= startOfToday {
                return (currentYear, month, day)
            }
        }
        if isValidDate(year: currentYear + 1, month: month, day: day, calendar: calendar) {
            return (currentYear + 1, month, day)
        }
        return nil
    }

    private static func isValidDate(year: Int, month: Int, day: Int, calendar: Calendar) -> Bool {
        guard (1...12).contains(month), (1...31).contains(day) else { return false }
        var comps = DateComponents()
        comps.calendar = calendar
        comps.timeZone = calendar.timeZone
        comps.year = year
        comps.month = month
        comps.day = day
        guard let date = calendar.date(from: comps) else { return false }
        let check = calendar.dateComponents([.year, .month, .day], from: date)
        return check.year == year && check.month == month && check.day == day
    }

    // MARK: - Regex Helpers

    private struct RegexMatch {
        let fullRange: Range<String.Index>
        let groups: [String]
    }

    private static func firstRegexRange(
        _ pattern: String,
        in text: String,
        caseInsensitive: Bool = false
    ) -> Range<String.Index>? {
        firstMatch(pattern, in: text, caseInsensitive: caseInsensitive)?.fullRange
    }

    private static func firstMatch(
        _ pattern: String,
        in text: String,
        caseInsensitive: Bool = false
    ) -> RegexMatch? {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange),
              let fullRange = Range(match.range, in: text)
        else { return nil }
        var groups = [String]()
        for index in 0..<match.numberOfRanges {
            if let range = Range(match.range(at: index), in: text) {
                groups.append(String(text[range]))
            } else {
                groups.append("")
            }
        }
        return RegexMatch(fullRange: fullRange, groups: groups)
    }

    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
