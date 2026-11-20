import XCTest
@testable import SearchInputChecks

final class JournalDateTests: XCTestCase {
    func testWeekCrossesYearWithoutDuplicatingDays() throws {
        let date = try XCTUnwrap(JournalCalendarDates.date("2027-01-01"))
        let days = JournalCalendarDates.week(containing: date)
        XCTAssertEqual(days.map(JournalCalendarDates.key), [
            "2026-12-27", "2026-12-28", "2026-12-29", "2026-12-30", "2026-12-31", "2027-01-01", "2027-01-02"
        ])
        XCTAssertEqual(Set(days).count, 7)
        XCTAssertEqual(JournalCalendarDates.weekday(days[0]), "周日")
    }
    func testInvalidAirDatesAreNotNormalizedIntoAnotherMonth() {
        XCTAssertNil(JournalCalendarDates.date("2026-02-30"))
        XCTAssertNil(JournalCalendarDates.date("2026-13-01"))
        XCTAssertNil(JournalCalendarDates.date("2026-11-20T01:00:00Z"))
        XCTAssertNotNil(JournalCalendarDates.date("2028-02-29"))
    }
    func testTodayAndMonthStatisticsUseExclusiveEndDates() throws {
        let date = try XCTUnwrap(JournalCalendarDates.date("2026-11-20"))
        let today = try XCTUnwrap(JournalStatisticsPeriod.today.interval(containing: date))
        XCTAssertEqual(JournalCalendarDates.key(today.start), "2026-11-20")
        XCTAssertEqual(JournalCalendarDates.key(today.end), "2026-11-21")
        let month = try XCTUnwrap(JournalStatisticsPeriod.month.interval(containing: date))
        XCTAssertEqual(JournalCalendarDates.key(month.start), "2026-11-01")
        XCTAssertEqual(JournalCalendarDates.key(month.end), "2026-12-01")
    }
}
