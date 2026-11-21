import XCTest
import UIKit
@testable import SearchInputChecks

final class SymbolAvailabilityTests: XCTestCase {
    @MainActor func testStaticAppIconsAndCompatibilityAliasesLoadOnTheRunningOS() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "system-symbols", withExtension: "json"))
        let report = try JSONDecoder().decode(SymbolList.self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(report.names.count, 150, "The audit must cover app icons outside the small UI fixture")
        let missing = report.names.filter { UIImage(systemName: AppSystemSymbols.name($0)) == nil }
        XCTAssertTrue(missing.isEmpty, "Unavailable icons: \(missing.map { $0 + ": " + (report.locations[$0] ?? []).joined(separator: ", ") })")
        let aliases = report.names.filter { AppSystemSymbols.name($0) != $0 }
        print("Verified \(report.names.count) static app icons on \(UIDevice.current.systemVersion); aliases: \(aliases)")
    }

    private struct SymbolList: Decodable {
        let names: [String]
        let locations: [String: [String]]
    }
}
