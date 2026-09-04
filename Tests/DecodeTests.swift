import XCTest
@testable import ClaudeMeter

final class DecodeTests: XCTestCase {

    private func fixture() throws -> Data {
        let bundle = Bundle(for: type(of: self))
        let url = try XCTUnwrap(
            bundle.url(forResource: "usage-2026-09-03", withExtension: "json"),
            "fixture usage-2026-09-03.json missing from the test bundle")
        return try Data(contentsOf: url)
    }

    func testDecodesThreeLimits() throws {
        let snapshot = try UsageClient.decode(try fixture(), fetchedAt: Date())
        XCTAssertEqual(snapshot.limits.map(\.kind), ["session", "weekly_all", "weekly_scoped"])
        XCTAssertEqual(snapshot.limits.map(\.group), ["session", "weekly", "weekly"])
    }

    func testPercents() throws {
        let snapshot = try UsageClient.decode(try fixture(), fetchedAt: Date())
        XCTAssertEqual(snapshot.limits.map(\.percent), [27, 27, 17])
    }

    func testScopedLimitCarriesModelDisplayName() throws {
        let snapshot = try UsageClient.decode(try fixture(), fetchedAt: Date())
        let scoped = try XCTUnwrap(snapshot.limits.first { $0.kind == "weekly_scoped" })
        XCTAssertEqual(scoped.scopeDisplayName, "Fable")
        XCTAssertNil(snapshot.limits[0].scopeDisplayName)
        XCTAssertEqual(snapshot.limits.map(\.isActive), [true, false, false])
        XCTAssertEqual(snapshot.limits.compactMap(\.severity), ["normal", "normal", "normal"])
    }

    func testResetDatesParseWithFractionalSeconds() throws {
        let snapshot = try UsageClient.decode(try fixture(), fetchedAt: Date())
        for limit in snapshot.limits {
            XCTAssertNotNil(limit.resetsAt, "resetsAt nil for \(limit.kind)")
        }
        let session = try XCTUnwrap(snapshot.limits.first { $0.kind == "session" }?.resetsAt)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = cal.dateComponents([.year, .month, .day, .hour, .minute], from: session)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 9)
        XCTAssertEqual(parts.day, 4)
        XCTAssertEqual(parts.hour, 2)
        XCTAssertEqual(parts.minute, 20)
    }

    func testExtraUsage() throws {
        let snapshot = try UsageClient.decode(try fixture(), fetchedAt: Date())
        let extra = try XCTUnwrap(snapshot.extraUsage)
        XCTAssertTrue(extra.isEnabled)
        XCTAssertEqual(extra.utilization, 18.3, accuracy: 0.0001)
        XCTAssertEqual(extra.usedCredits, 183)
        XCTAssertEqual(extra.monthlyLimit, 1000)
    }

    func testUnknownKindsAndKeysAreTolerated() throws {
        let json = """
        {"some_future_key": {"a": 1},
         "limits": [{"kind": "monthly_experiment", "group": null, "percent": 5,
                     "severity": null, "resets_at": "2026-09-09T01:00:00+00:00",
                     "scope": null, "is_active": null, "extra": 7}]}
        """.data(using: .utf8)!
        let snapshot = try UsageClient.decode(json, fetchedAt: Date())
        XCTAssertEqual(snapshot.limits.count, 1)
        XCTAssertEqual(snapshot.limits[0].kind, "monthly_experiment")
        XCTAssertNotNil(snapshot.limits[0].resetsAt)
        XCTAssertNil(snapshot.extraUsage)
    }

    func testCredentialDecodeMalformed() {
        XCTAssertThrowsError(try CredentialStore.decodeCredentials(Data("{}".utf8))) {
            XCTAssertEqual($0 as? CredentialError, .malformed)
        }
    }

    func testCredentialDecodeHappyPath() throws {
        let blob = Data(#"{"claudeAiOauth":{"accessToken":"tok","expiresAt":1788000000000}}"#.utf8)
        let (token, expiresAt) = try CredentialStore.decodeCredentials(blob)
        XCTAssertEqual(token, "tok")
        XCTAssertEqual(expiresAt.timeIntervalSince1970, 1_788_000_000, accuracy: 1)
    }
}
