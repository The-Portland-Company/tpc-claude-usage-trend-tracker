import XCTest
@testable import ClaudeUsageTrendTracker

final class PaceMathTests: XCTestCase {
    let iso = ISO8601DateFormatter()

    func testWeeklyProjectionOnPace() {
        // Window: resets 2026-09-09T01:00Z, length 7d → start 2026-09-02T01:00Z.
        let reset = iso.date(from: "2026-09-09T01:00:00Z")!
        let now = iso.date(from: "2026-09-04T01:00:00Z")!   // 2 of 7 days elapsed
        let p = PaceMath.project(percent: 26, kind: "weekly_all", resetsAt: reset, now: now)!
        XCTAssertEqual(p.elapsedFraction, 2.0/7.0, accuracy: 0.001)
        XCTAssertEqual(p.projectedAtReset, 91, accuracy: 0.5)
        XCTAssertFalse(p.overPace)
        XCTAssertNil(p.hits100At)
    }

    func testWeeklyProjectionOverPaceGivesHits100Time() {
        let reset = iso.date(from: "2026-09-09T01:00:00Z")!
        let now = iso.date(from: "2026-09-04T01:00:00Z")!
        let p = PaceMath.project(percent: 40, kind: "weekly_all", resetsAt: reset, now: now)!
        XCTAssertTrue(p.overPace)                          // 40 / (2/7) = 140
        // rate = 40% per 48h → 60% more takes 72h → 2026-09-07T01:00Z
        XCTAssertEqual(p.hits100At!, iso.date(from: "2026-09-07T01:00:00Z")!)
    }

    func testSessionWindowIsFiveHours() {
        XCTAssertEqual(PaceMath.windowLength(forKind: "session"), 5 * 3600)
        XCTAssertEqual(PaceMath.windowLength(forKind: "weekly_scoped"), 7 * 86400)
        XCTAssertNil(PaceMath.windowLength(forKind: "mystery"))
        XCTAssertNil(PaceMath.project(percent: 10, kind: "mystery", resetsAt: Date(), now: Date()))
    }

    func testFreshWindowDoesNotProjectToInfinity() {
        let reset = iso.date(from: "2026-09-09T01:00:00Z")!
        let now = reset.addingTimeInterval(-7 * 86400 + 60)      // 1 minute into the window
        let p = PaceMath.project(percent: 1, kind: "weekly_all", resetsAt: reset, now: now)!
        XCTAssertEqual(p.elapsedFraction, 0.02, accuracy: 0.0001)
        XCTAssertEqual(p.projectedAtReset, 50, accuracy: 0.01)
    }

    func testSeverity() {
        let reset = iso.date(from: "2026-09-09T01:00:00Z")!
        let now = iso.date(from: "2026-09-04T01:00:00Z")!
        let calm = PaceMath.project(percent: 26, kind: "weekly_all", resetsAt: reset, now: now)
        XCTAssertEqual(PaceMath.severity(percent: 26, projection: calm), .normal)
        XCTAssertEqual(PaceMath.severity(percent: 76, projection: nil), .warning)
        XCTAssertEqual(PaceMath.severity(percent: 91, projection: nil), .critical)
        let hot = PaceMath.project(percent: 60, kind: "weekly_all", resetsAt: reset, now: now)
        XCTAssertEqual(PaceMath.severity(percent: 60, projection: hot), .critical)   // over pace and past half
        let earlyHot = PaceMath.project(percent: 35, kind: "weekly_all", resetsAt: reset, now: now)
        XCTAssertEqual(PaceMath.severity(percent: 35, projection: earlyHot), .warning)
    }

    func testTrend() {
        let now = iso.date(from: "2026-09-04T01:00:00Z")!
        // Sustainable weekly slope ≈ 0.595 %/h. 2%/h over the last hour is rising.
        let rising: [(Date, Double)] = [(now.addingTimeInterval(-3600), 24), (now, 26)]
        XCTAssertEqual(PaceMath.trend(samples: rising, kind: "weekly_all", now: now), .rising)
        let flat: [(Date, Double)] = [(now.addingTimeInterval(-3600), 26), (now, 26)]
        XCTAssertEqual(PaceMath.trend(samples: flat, kind: "weekly_all", now: now), .falling)   // 0 < 75% of sustainable
        let steady: [(Date, Double)] = [(now.addingTimeInterval(-3600), 25.4), (now, 26)]
        XCTAssertEqual(PaceMath.trend(samples: steady, kind: "weekly_all", now: now), .steady)
        XCTAssertEqual(PaceMath.trend(samples: [(now, 26)], kind: "weekly_all", now: now), .unknown)
    }

    func testCountdown() {
        let now = Date()
        XCTAssertEqual(PaceMath.countdown(to: now.addingTimeInterval(2 * 86400 + 4 * 3600), from: now), "in 2d 4h")
        XCTAssertEqual(PaceMath.countdown(to: now.addingTimeInterval(3 * 3600 + 12 * 60), from: now), "in 3h 12m")
        XCTAssertEqual(PaceMath.countdown(to: now.addingTimeInterval(40 * 60), from: now), "in 40m")
        XCTAssertEqual(PaceMath.countdown(to: now.addingTimeInterval(-5), from: now), "now")
    }
}

final class NotificationPlannerTests: XCTestCase {
    let iso = ISO8601DateFormatter()
    lazy var reset = iso.date(from: "2026-09-09T01:00:00Z")!
    lazy var now = iso.date(from: "2026-09-04T01:00:00Z")!
    func bucket(_ pct: Double, kind: String = "weekly_all", resets: Date? = nil) -> NotificationPlanner.Bucket {
        .init(kind: kind, title: "Week", percent: pct, resetsAt: resets ?? reset)
    }

    func testPaceFiresOnceThenReArmsWhenBackUnder() {
        var r = NotificationPlanner.plan(now: now, buckets: [bucket(40)], previous: [], armed: [])
        XCTAssertEqual(r.send.count, 1)
        XCTAssertTrue(r.send[0].title.contains("over pace"))
        r = NotificationPlanner.plan(now: now, buckets: [bucket(41)], previous: [bucket(40)], armed: r.armed)
        XCTAssertEqual(r.send.count, 0, "must not repeat while still over pace")
        r = NotificationPlanner.plan(now: now.addingTimeInterval(3 * 86400), buckets: [bucket(41)], previous: [bucket(41)], armed: r.armed)
        XCTAssertEqual(r.send.count, 0)                     // 41 / (5/7) = 57, under pace → re-armed silently
        r = NotificationPlanner.plan(now: now.addingTimeInterval(3 * 86400), buckets: [bucket(80)], previous: [bucket(41)], armed: r.armed)
        XCTAssertEqual(r.send.filter { $0.key.hasSuffix("|pace") }.count, 1, "fires again after re-arm")
    }

    func testThresholdsFireOncePerWindow() {
        var r = NotificationPlanner.plan(now: now.addingTimeInterval(4 * 86400), buckets: [bucket(76)], previous: [], armed: [])
        XCTAssertEqual(r.send.filter { $0.key.hasSuffix("|75") }.count, 1)
        r = NotificationPlanner.plan(now: now.addingTimeInterval(4 * 86400), buckets: [bucket(78)], previous: [bucket(76)], armed: r.armed)
        XCTAssertEqual(r.send.filter { $0.key.hasSuffix("|75") }.count, 0)
        r = NotificationPlanner.plan(now: now.addingTimeInterval(5 * 86400), buckets: [bucket(91)], previous: [bucket(78)], armed: r.armed)
        XCTAssertEqual(r.send.filter { $0.key.hasSuffix("|90") }.count, 1)
    }

    func testResetNotificationAndArmingPrune() {
        let nextReset = reset.addingTimeInterval(7 * 86400)
        let r = NotificationPlanner.plan(now: reset.addingTimeInterval(120),
                                         buckets: [bucket(0, resets: nextReset)],
                                         previous: [bucket(95)],
                                         armed: ["weekly_all|\(Int(reset.timeIntervalSince1970))|90"])
        XCTAssertEqual(r.send.count, 1)
        XCTAssertTrue(r.send[0].title.contains("reset"))
        XCTAssertFalse(r.armed.contains { $0.hasSuffix("|90") }, "old window's keys pruned")
    }

    func testSessionResetOffByDefault() {
        let sessionReset = iso.date(from: "2026-09-04T02:20:00Z")!
        let r = NotificationPlanner.plan(now: sessionReset.addingTimeInterval(120),
                                         buckets: [bucket(0, kind: "session", resets: sessionReset.addingTimeInterval(5 * 3600))],
                                         previous: [bucket(60, kind: "session", resets: sessionReset)],
                                         armed: [])
        XCTAssertEqual(r.send.count, 0)
    }
}
