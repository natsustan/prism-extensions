import Foundation
import PrismExtensionKit

/// Display formatting for usage values. Pure functions, so the exact strings
/// the launcher shows stay covered by tests.
enum AgentUsageFormat {
    /// "18% remaining" / "82% used" — the global Used/Left preference flips it.
    /// Shorter than the single-value form because it labels a meter.
    static func meterText(
        used: Double,
        limit: Double,
        showsRemaining: Bool
    ) -> String {
        let value = limit > 0 ? min(max(used, 0), limit) / limit * 100 : max(used, 0)
        if showsRemaining {
            let remaining = percentText(min(max(100 - value, 0), 100))
            return localized("\(remaining) remaining")
        }
        let used = percentText(value)
        return localized("\(used) used")
    }

    /// Just the number, for the list row's trailing badge.
    static func meterPercent(used: Double, limit: Double, showsRemaining: Bool) -> String {
        let value = limit > 0 ? min(max(used, 0), limit) / limit * 100 : max(used, 0)
        return percentText(showsRemaining ? min(max(100 - value, 0), 100) : value)
    }

    /// Countdown to a window reset. A window whose reset time has already
    /// passed (a stale refresh, a clock skew) reads "Due" rather than a
    /// one-minute remainder.
    static func resetCountdownText(resetsAt: Date, now: Date) -> String {
        let interval = resetsAt.timeIntervalSince(now)
        guard interval > 60 else { return localized("Due") }
        return durationText(interval)
    }

    /// "Oct 4 10:01 AM (18d 9h)" — an absolute date with its countdown, the way
    /// the detail pane lists expiring reset credits.
    static func dateText(_ date: Date, now: Date) -> String {
        let absolute = date.formatted(dayAndTime)
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return absolute }
        return "\(absolute) (\(durationText(interval)))"
    }
    /// "98% used" or "2% left" — the global Used/Left preference flips this.
    static func progressText(
        used: Double,
        limit: Double,
        format: AgentUsageMetric.Format,
        showsRemaining: Bool
    ) -> String {
        let clampedUsed = limit > 0 ? min(max(used, 0), limit) : max(used, 0)
        switch format {
        case .percent:
            let value = limit > 0 ? clampedUsed / limit * 100 : clampedUsed
            if showsRemaining {
                let remaining = percentText(min(max(100 - value, 0), 100))
                return localized("\(remaining) left")
            }
            let used = percentText(value)
            return localized("\(used) used")
        case .count:
            if showsRemaining {
                let remaining = countText(max(limit - clampedUsed, 0))
                return localized("\(remaining) left")
            }
            let used = countText(clampedUsed)
            return localized("\(used) used")
        case .currency:
            let amount = String(format: "$%.2f", showsRemaining ? max(limit - clampedUsed, 0) : clampedUsed)
            return showsRemaining ? localized("\(amount) left") : localized("\(amount) used")
        }
    }

    /// Whole percents; a value that rounds to 0 but is not 0 reads as "<1%"
    /// rather than "0%", so a barely-touched quota is not mistaken for an
    /// exhausted one.
    static func percentText(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let rounded = value.rounded()
        if rounded == 0, value > 0 { return "<1%" }
        guard let whole = Int(exactly: rounded) else { return "—" }
        return "\(whole)%"
    }

    static func countText(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let rounded = value.rounded()
        if rounded == 0, value > 0 { return "<1" }
        return rounded.formatted(
            .number.precision(.fractionLength(0)).grouping(.automatic).locale(PrismLocalization.locale)
        )
    }

    /// Fraction 0...1 for the row's meter.
    static func progressFraction(used: Double, limit: Double) -> Double {
        guard limit > 0, used.isFinite else { return 0 }
        return min(max(used / limit, 0), 1)
    }

    /// Share of the window still available. The warning tint reads this rather
    /// than the displayed value, so "about to run dry" means the same thing
    /// whichever way the preference shows the number.
    static func remainingFraction(used: Double, limit: Double) -> Double {
        1 - progressFraction(used: used, limit: limit)
    }

    /// What the meter beside a value fills: the same quantity the adjacent text
    /// reports, so a bar never contradicts its own number.
    static func displayedFraction(used: Double, limit: Double, showsRemaining: Bool) -> Double {
        let remaining = remainingFraction(used: used, limit: limit)
        return showsRemaining ? remaining : 1 - remaining
    }

    /// "Wed 12:54 PM · 2h 20m": the reset anchored to a clock reading, with the
    /// countdown beside it. The absolute half is what a plan is made against;
    /// the countdown is what stays readable while the pane sits open. Inside a
    /// week the weekday is the shorter anchor, further out the date is.
    static func resetDetailText(resetsAt: Date, now: Date) -> String {
        let interval = resetsAt.timeIntervalSince(now)
        guard interval > 60 else { return localized("Due") }
        let absolute = interval < 7 * 86_400
            ? resetsAt.formatted(Date.FormatStyle.dateTime.weekday(.abbreviated).hour().minute()
                .locale(PrismLocalization.locale))
            : resetsAt.formatted(dayAndTime)
        return "\(absolute) · \(durationText(interval))"
    }

    /// "Resets in 3d 4h", "Resets soon", "Resets today at 6:38 PM".
    /// Relative while the window is still days out, absolute once it is close
    /// enough that a weekday-and-time reading is more useful than a countdown.
    static func resetText(resetsAt: Date, now: Date) -> String {
        let interval = resetsAt.timeIntervalSince(now)
        if interval <= 60 { return localized("Resets soon") }
        if interval < 12 * 3600 {
            let calendar = Calendar.current
            let time = resetsAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: PrismLocalization.locale))
            if calendar.isDate(resetsAt, inSameDayAs: now) { return localized("Resets today at \(time)") }
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
               calendar.isDate(resetsAt, inSameDayAs: tomorrow) {
                return localized("Resets tomorrow at \(time)")
            }
            let date = resetsAt.formatted(dayAndTime)
            return localized("Resets \(date)")
        }
        let duration = durationText(interval)
        return localized("Resets in \(duration)")
    }

    /// "Oct 4 10:01 AM" in Prism's language.
    private static var dayAndTime: Date.FormatStyle {
        Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute().locale(PrismLocalization.locale)
    }

    /// Compact countdown: "3d 4h", "1h", "12m".
    static func durationText(_ interval: TimeInterval) -> String {
        guard let wholeMinutes = Int(exactly: (interval / 60).rounded()) else { return "—" }
        let totalMinutes = max(wholeMinutes, 1)
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        // Whole units drop their empty tail, so a one-hour window reads "1h"
        // rather than "1h 0m".
        var parts = [String]()
        if days > 0 { parts.append(localized("\(days)d")) }
        if hours > 0 || (days > 0 && minutes > 0) { parts.append(localized("\(hours)h")) }
        if minutes > 0 || parts.isEmpty { parts.append(localized("\(minutes)m")) }
        return parts.joined(separator: " ")
    }

    /// Footer freshness line: "Updated just now", "Updated 3m ago".
    static func updatedText(fetchedAt: Date, now: Date) -> String {
        let interval = now.timeIntervalSince(fetchedAt)
        guard interval > 45 else { return localized("Updated just now") }
        let duration = durationText(interval)
        return localized("Updated \(duration) ago")
    }
}
