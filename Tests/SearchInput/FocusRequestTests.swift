import XCTest
import UIKit
@testable import SearchInputChecks

final class FocusRequestTests: XCTestCase {
    @MainActor private func coordinator(for field: GlobalSearchTextField) -> GlobalSearchInput.Coordinator {
        let input = GlobalSearchInput(text: .constant(""), focused: .constant(false)) {}
        let coordinator = input.makeCoordinator()
        _ = input.makeTextField(coordinator: coordinator, field: field)
        return coordinator
    }

    @MainActor private func window(containing field: UITextField, visible: Bool = true) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = UIScreen.main.bounds
        let controller = UIViewController()
        controller.view.frame = window.bounds
        field.frame = CGRect(x: 16, y: 32, width: 260, height: 44)
        controller.view.addSubview(field)
        window.rootViewController = controller
        window.addSubview(controller.view)
        if visible { window.makeKeyAndVisible() }
        return window
    }

    @MainActor private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor func testPendingFocusWaitsForWindowAttachmentAndActivation() async throws {
        let field = GlobalSearchTextField()
        let coordinator = self.coordinator(for: field)
        coordinator.requestFocus(GlobalSearchFocusRequest(focused: true), in: field)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(field.isFirstResponder)
        let window = try self.window(containing: field, visible: false)
        defer {
            GlobalSearchInput.dismantleUIView(field, coordinator: coordinator)
            window.endEditing(true); window.isHidden = true; window.rootViewController = nil
        }
        XCTAssertTrue(field.window === window)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(field.isFirstResponder)
        window.makeKeyAndVisible()
        try await waitUntil { field.isFirstResponder }
        XCTAssertTrue(field.isFirstResponder, "An unfulfilled focus command must survive window readiness changes")
    }

    @MainActor func testTransientNativeFocusFailureIsRetried() async throws {
        let field = RefusingSearchTextField()
        field.failuresRemaining = 1
        let coordinator = self.coordinator(for: field)
        let window = try self.window(containing: field)
        defer {
            GlobalSearchInput.dismantleUIView(field, coordinator: coordinator)
            window.endEditing(true); window.isHidden = true; window.rootViewController = nil
        }
        coordinator.requestFocus(GlobalSearchFocusRequest(focused: true), in: field)
        try await waitUntil { field.isFirstResponder }
        XCTAssertTrue(field.isFirstResponder)
        XCTAssertEqual(field.attempts, 2)
    }

    @MainActor func testNewDismissRequestCancelsAnOlderFailedAttempt() async throws {
        let field = RefusingSearchTextField()
        field.failuresRemaining = 1
        let coordinator = self.coordinator(for: field)
        let window = try self.window(containing: field)
        defer {
            GlobalSearchInput.dismantleUIView(field, coordinator: coordinator)
            window.endEditing(true); window.isHidden = true; window.rootViewController = nil
        }
        field.onFailure = { [weak coordinator, weak field] in
            guard let coordinator, let field else { return }
            coordinator.requestFocus(GlobalSearchFocusRequest(focused: false), in: field)
        }
        coordinator.requestFocus(GlobalSearchFocusRequest(focused: true), in: field)
        try await waitUntil { field.attempts > 0 }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(field.isFirstResponder, "A failed older command must not revive the keyboard after dismissal")
        XCTAssertEqual(field.attempts, 1)
    }

    @MainActor func testPersistentNativeFailureStopsAtTheRetryLimit() async throws {
        let field = RefusingSearchTextField()
        field.failuresRemaining = .max
        let coordinator = self.coordinator(for: field)
        let window = try self.window(containing: field)
        defer {
            GlobalSearchInput.dismantleUIView(field, coordinator: coordinator)
            window.endEditing(true); window.isHidden = true; window.rootViewController = nil
        }
        coordinator.requestFocus(GlobalSearchFocusRequest(focused: true), in: field)
        try await waitUntil { field.attempts >= 4 }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(field.isFirstResponder)
        XCTAssertEqual(field.attempts, 4, "Repeated failures must stop scheduling native focus attempts")
    }
}

@MainActor private final class RefusingSearchTextField: GlobalSearchTextField {
    var failuresRemaining = 0
    var attempts = 0
    var onFailure: (@MainActor () -> Void)?
    override func becomeFirstResponder() -> Bool {
        attempts += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            onFailure?()
            return false
        }
        return super.becomeFirstResponder()
    }
}
