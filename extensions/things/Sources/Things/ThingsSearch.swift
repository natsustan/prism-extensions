import Foundation

/// Filters, scores, and sorts Things to-dos for a query and active filter.
struct ThingsSearch {
    let words: [String]

    init(query: String) {
        self.words = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    func results(
        in todos: [ThingsTodo],
        filter: ThingsFilter,
        now: Date,
        calendar: Calendar,
        limit: Int
    ) -> [ThingsTodo] {
        let filtered = todos.filter { matchesFilter($0, filter: filter) }

        if words.isEmpty {
            let sorted = filtered.sorted { lhs, rhs in
                defaultOrder(lhs, rhs, filter: filter, now: now, calendar: calendar)
            }
            return Array(sorted.prefix(limit))
        }

        var scored: [(todo: ThingsTodo, score: Int)] = []
        scored.reserveCapacity(filtered.count)
        for todo in filtered {
            guard let score = matchScore(for: todo) else { continue }
            scored.append((todo, score))
        }

        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return defaultOrder(lhs.todo, rhs.todo, filter: filter, now: now, calendar: calendar)
        }
        return Array(scored.prefix(limit).map(\.todo))
    }

    private func matchesFilter(_ todo: ThingsTodo, filter: ThingsFilter) -> Bool {
        switch filter {
        case .all:
            return todo.isOpen && todo.bucket != .logbook
        case .today:
            return todo.isOpen && todo.bucket == .today
        case .inbox:
            return todo.isOpen && todo.bucket == .inbox
        case .upcoming:
            return todo.isOpen && todo.bucket == .upcoming
        case .anytime:
            return todo.isOpen && todo.bucket == .anytime
        case .someday:
            return todo.isOpen && todo.bucket == .someday
        case .logbook:
            return todo.bucket == .logbook || !todo.isOpen
        case let .project(id):
            return todo.isOpen && todo.projectID == id
        case let .area(id):
            return todo.isOpen && todo.areaID == id
        }
    }

    private func matchScore(for todo: ThingsTodo) -> Int? {
        let title = todo.title.lowercased()
        let notes = todo.notes.lowercased()
        let project = (todo.projectTitle ?? "").lowercased()
        let area = (todo.areaTitle ?? "").lowercased()
        let tags = todo.tags.map { $0.lowercased() }
        let pinyin = todo.pinyinKeywords

        var total = 0
        for word in words {
            if title == word {
                total += 120
            } else if title.hasPrefix(word) {
                total += 90
            } else if title.contains(word) {
                total += 70
            } else if pinyin.contains(where: { $0.hasPrefix(word) }) {
                total += 65
            } else if pinyin.contains(where: { $0.contains(word) }) {
                total += 50
            } else if tags.contains(where: { $0 == word || $0.hasPrefix(word) || "#\($0)" == word }) {
                total += 45
            } else if project.contains(word) || area.contains(word) {
                total += 40
            } else if notes.contains(word) {
                total += 25
            } else {
                return nil
            }
        }
        return total
    }

    private func defaultOrder(
        _ lhs: ThingsTodo,
        _ rhs: ThingsTodo,
        filter: ThingsFilter,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        if filter == .logbook {
            let lDate = lhs.completionDate ?? lhs.cancellationDate ?? .distantPast
            let rDate = rhs.completionDate ?? rhs.cancellationDate ?? .distantPast
            if lDate != rDate { return lDate > rDate }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

        if lhs.bucket.sortRank != rhs.bucket.sortRank {
            return lhs.bucket.sortRank < rhs.bucket.sortRank
        }

        let lOverdue = lhs.isOverdue(now: now, calendar: calendar)
        let rOverdue = rhs.isOverdue(now: now, calendar: calendar)
        if lOverdue != rOverdue { return lOverdue }

        if lhs.bucket == .upcoming, let lAct = lhs.activationDate, let rAct = rhs.activationDate, lAct != rAct {
            return lAct < rAct
        }

        switch (lhs.dueDate, rhs.dueDate) {
        case let (lDue?, rDue?) where lDue != rDue:
            return lDue < rDue
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }
}
