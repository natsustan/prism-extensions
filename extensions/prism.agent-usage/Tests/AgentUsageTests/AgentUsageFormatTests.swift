import Foundation
import PrismExtensionKit
import Testing
@testable import AgentUsage

@Suite("Agent usage formatting")
struct AgentUsageFormatTests {
    @Test("exported summaries use absolute timestamps for resets and expiry")
    func summaryTimestamps() {
        let fetched = Date(timeIntervalSince1970: 1_700_000_000)
        let report = AgentUsageReport(providerID: .codex, providerName: "Codex", plan: nil, accountLabel: nil,
            metrics: [
                AgentUsageMetric(id: "weekly", title: "Weekly", section: .limits,
                    value: .progress(used: 42, limit: 100, format: .percent,
                                     resetsAt: fetched.addingTimeInterval(86_400), windowSeconds: 604_800)),
                AgentUsageMetric(id: "expiry", title: "Credit Expires", section: .creditsAndResets,
                    value: .date(fetched.addingTimeInterval(120)))
            ], fetchedAt: fetched)
        #expect(report.summaryText == """
        Codex
        Fetched at: 2023-11-14T22:13:20Z
        Weekly: 42% used, resets at 2023-11-15T22:13:20Z
        Credit Expires: 2023-11-14T22:15:20Z
        """)
    }

    @Test("unrepresentable percentages and durations never trap")
    func numericBounds() {
        for value in [Double.infinity, -.infinity, .nan, Double.greatestFiniteMagnitude] {
            #expect(AgentUsageFormat.percentText(value) == "—")
            #expect(AgentUsageFormat.durationText(value) == "—")
        }
    }

    @Test("time-dependent labels advance with timeline dates")
    func relativeLabelsAdvance() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = start.addingTimeInterval(120)
        #expect(AgentUsageFormat.updatedText(fetchedAt: start, now: start) == "Updated just now")
        #expect(AgentUsageFormat.updatedText(fetchedAt: start, now: reset) == "Updated 2m ago")
        #expect(AgentUsageFormat.resetDetailText(resetsAt: reset, now: reset) == "Due")
        #expect(AgentUsageFormat.dateText(reset, now: start).contains("(2m)"))
        #expect(!AgentUsageFormat.dateText(reset, now: reset).contains("(2m)"))
    }

    @Test("a percent meter reads as used or left")
    func percentProgress() {
        #expect(AgentUsageFormat.progressText(
            used: 98, limit: 100, format: .percent, showsRemaining: false) == "98% used")
        #expect(AgentUsageFormat.progressText(
            used: 98, limit: 100, format: .percent, showsRemaining: true) == "2% left")
    }

    @Test("a dollar quota keeps its balance in the detail while the list uses percent")
    func currencyProgress() {
        #expect(AgentUsageFormat.progressText(
            used: 2, limit: 5, format: .currency, showsRemaining: false) == "$2.00 used")
        #expect(AgentUsageFormat.progressText(
            used: 2, limit: 5, format: .currency, showsRemaining: true) == "$3.00 left")
        #expect(AgentUsageFormat.meterPercent(used: 2, limit: 5, showsRemaining: false) == "40%")
    }

    @Test("a barely touched quota does not read as an exhausted one")
    func subOnePercent() {
        #expect(AgentUsageFormat.percentText(0.4) == "<1%")
        #expect(AgentUsageFormat.percentText(0) == "0%")
        #expect(AgentUsageFormat.countText(0.4) == "<1")
    }

    @Test("used is clamped into the window, so a stale-over report cannot overflow the meter")
    func clamping() {
        #expect(AgentUsageFormat.progressFraction(used: 140, limit: 100) == 1)
        #expect(AgentUsageFormat.progressFraction(used: -3, limit: 100) == 0)
        #expect(AgentUsageFormat.progressText(
            used: 140, limit: 100, format: .percent, showsRemaining: true) == "0% left")
    }

    @Test("the meter fills the same quantity its digits report")
    func displayedFraction() {
        // The bar beside "58%" is 58% full whichever way the preference reads,
        // and the tint reads that same 58% either way.
        #expect(abs(AgentUsageFormat.displayedFraction(used: 42, limit: 100, showsRemaining: true) - 0.58) < 0.0001)
        #expect(abs(AgentUsageFormat.displayedFraction(used: 42, limit: 100, showsRemaining: false) - 0.42) < 0.0001)
        #expect(abs(AgentUsageFormat.remainingFraction(used: 42, limit: 100) - 0.58) < 0.0001)
        #expect(AgentUsageFormat.displayedFraction(used: 140, limit: 100, showsRemaining: true) == 0)
        #expect(AgentUsageFormat.displayedFraction(used: 140, limit: 100, showsRemaining: false) == 1)
        // A missing ceiling stays inside the track rather than leaving it.
        #expect(AgentUsageFormat.displayedFraction(used: 10, limit: 0, showsRemaining: true) == 1)
        #expect(AgentUsageFormat.displayedFraction(used: 10, limit: 0, showsRemaining: false) == 0)
    }

    @Test("the reset line anchors its countdown to a clock reading")
    func resetDetail() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let soon = AgentUsageFormat.resetDetailText(
            resetsAt: now.addingTimeInterval(2 * 3_600 + 20 * 60), now: now)
        #expect(soon.hasSuffix(" · 2h 20m"))

        // Inside the week the weekday is the shorter anchor; past it the anchor
        // has to carry the date. Asserted against the same format styles, so the
        // test pins which style is chosen rather than the locale's spelling.
        let withinWeek = now.addingTimeInterval(6 * 86_400)
        #expect(AgentUsageFormat.resetDetailText(resetsAt: withinWeek, now: now).hasPrefix(
            withinWeek.formatted(.dateTime.weekday(.abbreviated).hour().minute())))
        let beyondWeek = now.addingTimeInterval(8 * 86_400)
        #expect(AgentUsageFormat.resetDetailText(resetsAt: beyondWeek, now: now).hasPrefix(
            beyondWeek.formatted(.dateTime.month(.abbreviated).day().hour().minute())))

        #expect(AgentUsageFormat.resetDetailText(resetsAt: now.addingTimeInterval(-600), now: now) == "Due")
        #expect(AgentUsageFormat.resetDetailText(resetsAt: now.addingTimeInterval(20), now: now) == "Due")
    }

    @Test("reset time is relative while far out, absolute once close")
    func resetText() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(AgentUsageFormat.resetText(
            resetsAt: now.addingTimeInterval(3 * 86_400 + 4 * 3_600), now: now) == "Resets in 3d 4h")
        #expect(AgentUsageFormat.resetText(resetsAt: now.addingTimeInterval(30), now: now) == "Resets soon")
        #expect(AgentUsageFormat.resetText(
            resetsAt: now.addingTimeInterval(5 * 3_600), now: now).hasPrefix("Resets today at "))
    }

    @Test("durations stay compact")
    func durations() {
        #expect(AgentUsageFormat.durationText(3 * 86_400 + 4 * 3_600) == "3d 4h")
        #expect(AgentUsageFormat.durationText(5 * 3_600 + 20 * 60) == "5h 20m")
        #expect(AgentUsageFormat.durationText(12 * 60) == "12m")
    }

    @Test("freshness line stays quiet right after a fetch")
    func updatedText() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(AgentUsageFormat.updatedText(fetchedAt: now.addingTimeInterval(-10), now: now)
            == "Updated just now")
        #expect(AgentUsageFormat.updatedText(fetchedAt: now.addingTimeInterval(-180), now: now)
            == "Updated 3m ago")
    }

    @Test("meter copy names what is left of the window")
    func meterText() {
        #expect(AgentUsageFormat.meterText(used: 82, limit: 100, showsRemaining: true) == "18% remaining")
        #expect(AgentUsageFormat.meterText(used: 82, limit: 100, showsRemaining: false) == "82% used")
        #expect(AgentUsageFormat.meterPercent(used: 82, limit: 100, showsRemaining: true) == "18%")
        #expect(AgentUsageFormat.meterPercent(used: 82, limit: 100, showsRemaining: false) == "82%")
    }

    @Test("a dated row pairs the absolute time with its countdown")
    func dateText() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let expiry = now.addingTimeInterval(18 * 86_400 + 9 * 3_600)
        let text = AgentUsageFormat.dateText(expiry, now: now)
        #expect(text.hasSuffix("(18d 9h)"))
        // A date already in the past drops the countdown rather than showing a
        // negative one.
        #expect(!AgentUsageFormat.dateText(now.addingTimeInterval(-3_600), now: now).contains("("))
    }

    @Test("a window whose reset already passed reads as due, not as one minute")
    func resetCountdown() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(AgentUsageFormat.resetCountdownText(resetsAt: now.addingTimeInterval(3 * 86_400), now: now)
            == "3d")
        #expect(AgentUsageFormat.resetCountdownText(resetsAt: now.addingTimeInterval(-600), now: now)
            == "Due")
        #expect(AgentUsageFormat.resetCountdownText(resetsAt: now.addingTimeInterval(20), now: now)
            == "Due")
    }

    @Test("meter tone warms up as the window empties")
    func meterTone() {
        #expect(AgentUsagePresentation.tone(remaining: 0.9) == .normal)
        #expect(AgentUsagePresentation.tone(remaining: 0.2) == .warning)
        #expect(AgentUsagePresentation.tone(remaining: 0.05) == .critical)
    }
}
