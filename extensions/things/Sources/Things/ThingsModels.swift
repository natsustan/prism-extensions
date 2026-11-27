import Foundation

/// A calendar date without a time of day, used for Things start dates and deadlines.
struct ThingsDate: Sendable, Hashable, Comparable, Codable {
    var year: Int
    var month: Int
    var day: Int

    var isoString: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func < (lhs: ThingsDate, rhs: ThingsDate) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        if lhs.month != rhs.month { return lhs.month < rhs.month }
        return lhs.day < rhs.day
    }

    func date(in calendar: Calendar) -> Date {
        let gregorian = Self.gregorianCalendar(for: calendar)
        let components = DateComponents(year: year, month: month, day: day)
        return gregorian.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    func isBeforeToday(now: Date, calendar: Calendar) -> Bool {
        self < Self.today(now: now, calendar: calendar)
    }

    func isToday(now: Date, calendar: Calendar) -> Bool {
        self == Self.today(now: now, calendar: calendar)
    }

    static func today(now: Date, calendar: Calendar) -> ThingsDate {
        let gregorian = gregorianCalendar(for: calendar)
        let parts = gregorian.dateComponents([.year, .month, .day], from: now)
        return ThingsDate(
            year: parts.year ?? 2001,
            month: parts.month ?? 1,
            day: parts.day ?? 1
        )
    }

    static func gregorianCalendar(for calendar: Calendar) -> Calendar {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian
    }
}

enum ThingsBucket: String, Sendable, Hashable, CaseIterable {
    case today
    case inbox
    case upcoming
    case anytime
    case someday
    case logbook

    var sortRank: Int {
        switch self {
        case .today: 0
        case .inbox: 1
        case .upcoming: 2
        case .anytime: 3
        case .someday: 4
        case .logbook: 5
        }
    }

    /// Canonical Things AppleScript list IDs (independent of Things UI language).
    var appleScriptListID: String {
        switch self {
        case .today: "TMTodayListSource"
        case .inbox: "TMInboxListSource"
        case .upcoming: "TMCalendarListSource"
        case .anytime: "TMNextListSource"
        case .someday: "TMSomedayListSource"
        case .logbook: "TMLogbookListSource"
        }
    }
}

enum ThingsStatus: String, Sendable, Hashable {
    case open
    case completed
    case canceled
}

struct ThingsContainer: Sendable, Hashable, Identifiable {
    enum Kind: String, Sendable, Hashable {
        case project
        case area
    }

    let id: String
    let title: String
    let kind: Kind
    let areaID: String?
    let areaTitle: String?
}

struct ThingsTodo: Sendable, Hashable, Identifiable {
    let id: String
    let title: String
    let notes: String
    let status: ThingsStatus
    let bucket: ThingsBucket
    let dueDate: ThingsDate?
    let activationDate: ThingsDate?
    let completionDate: Date?
    let cancellationDate: Date?
    let projectID: String?
    let projectTitle: String?
    let areaID: String?
    let areaTitle: String?
    let tags: [String]
    var pinyinKeywords: [String] = []

    var isOpen: Bool { status == .open }

    /// The most specific parent title (project if present, otherwise area).
    var parentTitle: String? {
        if let projectTitle, !projectTitle.isEmpty { return projectTitle }
        if let areaTitle, !areaTitle.isEmpty { return areaTitle }
        return nil
    }

    func isOverdue(now: Date, calendar: Calendar) -> Bool {
        guard isOpen, let dueDate else { return false }
        return dueDate.isBeforeToday(now: now, calendar: calendar)
    }

    var primaryURL: URL? {
        if let match = notes.firstHTTPURL { return match }
        return nil
    }
}

enum ThingsFilter: Sendable, Equatable {
    case all
    case today
    case inbox
    case upcoming
    case anytime
    case someday
    case logbook
    case project(id: String)
    case area(id: String)

    static let allID = "all"
    static let todayID = "today"
    static let inboxID = "inbox"
    static let upcomingID = "upcoming"
    static let anytimeID = "anytime"
    static let somedayID = "someday"
    static let logbookID = "logbook"
    static let projectPrefix = "project:"
    static let areaPrefix = "area:"

    init(filterID: String?) {
        switch filterID {
        case nil, "", Self.allID: self = .all
        case Self.todayID: self = .today
        case Self.inboxID: self = .inbox
        case Self.upcomingID: self = .upcoming
        case Self.anytimeID: self = .anytime
        case Self.somedayID: self = .someday
        case Self.logbookID: self = .logbook
        case let id? where id.hasPrefix(Self.projectPrefix):
            self = .project(id: String(id.dropFirst(Self.projectPrefix.count)))
        case let id? where id.hasPrefix(Self.areaPrefix):
            self = .area(id: String(id.dropFirst(Self.areaPrefix.count)))
        default:
            self = .all
        }
    }

    var loadsLogbook: Bool {
        self == .logbook
    }

    var preferredContainerID: String? {
        switch self {
        case let .project(id), let .area(id): id
        default: nil
        }
    }
}

/// Schedule specification for Things Quick Add (`when` parameter).
enum ThingsWhen: Sendable, Hashable {
    case today
    case evening
    case tomorrow
    case anytime
    case someday
    case date(ThingsDate)
    case dateTime(ThingsDate, hour: Int, minute: Int)

    var urlParameterValue: String {
        switch self {
        case .today: "today"
        case .evening: "evening"
        case .tomorrow: "tomorrow"
        case .anytime: "anytime"
        case .someday: "someday"
        case let .date(date): date.isoString
        case let .dateTime(date, hour, minute):
            String(format: "%@@%02d:%02d", date.isoString, hour, minute)
        }
    }

    init?(presetCode: String) {
        switch presetCode {
        case "today": self = .today
        case "evening": self = .evening
        case "tomorrow": self = .tomorrow
        case "anytime": self = .anytime
        case "someday": self = .someday
        default: return nil
        }
    }
}

enum ThingsMoveTarget: Sendable, Equatable {
    case list(String)
    case project(String)
    case area(String)

    var scriptKind: String {
        switch self {
        case .list: "list"
        case .project: "project"
        case .area: "area"
        }
    }

    var targetID: String {
        switch self {
        case let .list(id), let .project(id), let .area(id): id
        }
    }
}

struct ThingsDraft: Sendable, Hashable {
    var title: String
    var notes: String
    var when: ThingsWhen?
    var deadline: ThingsDate?
    var listID: String?
    var listTitle: String?
    var tags: [String]
}

enum ThingsAuthorizationStatus: Sendable, Equatable {
    case authorized
    case notDetermined
    case denied
    case notRunning
}

enum ThingsRepositoryError: Error, Sendable, Equatable {
    case appNotInstalled
    case appNotRunning
    case automationDenied
    case notFound
    case scriptFailed(String)

    var userMessage: String {
        switch self {
        case .appNotInstalled:
            localized("Things 3 is not installed on this Mac.")
        case .appNotRunning:
            localized("Things 3 is not running. Open Things and try again.")
        case .automationDenied:
            localized("Prism isn’t allowed to control Things. Enable it in System Settings → Privacy & Security → Automation.")
        case .notFound:
            localized("That to-do no longer exists in Things.")
        case let .scriptFailed(detail):
            detail.isEmpty ? localized("Things didn’t respond as expected.") : detail
        }
    }
}

extension String {
    var firstHTTPURL: URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(startIndex..., in: self)
        for match in detector.matches(in: self, options: [], range: range) {
            if let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                return url
            }
        }
        return nil
    }
}
