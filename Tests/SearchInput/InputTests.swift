import XCTest
import SwiftUI
@testable import SearchInputChecks

final class SearchInputTests: XCTestCase {
    @MainActor private func host(_ state: SearchInputState) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = UIScreen.main.bounds
        window.rootViewController = UIHostingController(rootView: SearchInputHarness(state: state))
        window.makeKeyAndVisible()
        return window
    }
    @MainActor private func field(in view: UIView) -> UITextField? {
        if let field = view as? UITextField, field.accessibilityIdentifier == "search.input" { return field }
        return view.subviews.compactMap { self.field(in: $0) }.first
    }
    @MainActor private func settle() async throws { try await Task.sleep(for: .milliseconds(250)) }

    @MainActor func testFirstTypingKeepsFieldAndKeyboardFocus() async throws {
        let state = SearchInputState()
        let window = try host(state)
        defer { window.endEditing(true); window.isHidden = true; window.rootViewController = nil }
        try await settle()
        let original = try XCTUnwrap(field(in: window))
        XCTAssertTrue(original.becomeFirstResponder())
        try await settle()
        original.insertText("f"); original.sendActions(for: .editingChanged)
        try await settle()
        XCTAssertTrue(field(in: window) === original, "The first suggestion must not replace the native input")
        XCTAssertTrue(original.isFirstResponder, "The first character must not close the keyboard")
        XCTAssertEqual(state.text, "f")
        original.insertText("an"); original.sendActions(for: .editingChanged)
        try await settle()
        XCTAssertEqual(state.text, "fan")
        XCTAssertTrue(original.isFirstResponder)
        // A stale focus observation during rendering is not a request to dismiss.
        state.focused = false; state.revision += 1
        try await settle()
        XCTAssertTrue(original.isFirstResponder)
        state.request = GlobalSearchFocusRequest(focused: false)
        try await settle()
        XCTAssertFalse(original.isFirstResponder)
        state.request = GlobalSearchFocusRequest(focused: true)
        try await settle()
        XCTAssertTrue(original.isFirstResponder)
    }

    @MainActor func testIMECompositionSurvivesSuggestionUpdates() async throws {
        let state = SearchInputState()
        let window = try host(state)
        defer { window.endEditing(true); window.isHidden = true; window.rootViewController = nil }
        try await settle()
        let original = try XCTUnwrap(field(in: window))
        original.becomeFirstResponder()
        try await settle()
        original.setMarkedText("qing", selectedRange: NSRange(location: 4, length: 0))
        original.sendActions(for: .editingChanged)
        try await settle()
        XCTAssertEqual(state.text, "qing")
        state.revision += 1
        try await settle()
        XCTAssertNotNil(original.markedTextRange, "Publishing suggestions must preserve IME composition")
        XCTAssertTrue(original.isFirstResponder)
        state.text = "庆余年"
        try await settle()
        XCTAssertEqual(original.text, "庆余年")
        XCTAssertNil(original.markedTextRange)
        XCTAssertTrue(original.isFirstResponder)
    }

    @MainActor func testTextAndCaretAreVerticallyCentered() async throws {
        let state = SearchInputState()
        let window = try host(state)
        defer { window.endEditing(true); window.isHidden = true; window.rootViewController = nil }
        try await settle()
        let original = try XCTUnwrap(field(in: window))
        original.becomeFirstResponder()
        original.insertText("凡人"); original.sendActions(for: .editingChanged)
        try await settle()
        XCTAssertEqual(original.bounds.height, 44, accuracy: 1)
        let caret = original.caretRect(for: original.beginningOfDocument)
        XCTAssertEqual(caret.midY, original.bounds.midY, accuracy: 2, "The caret and text must be centered in the visible input bounds")
    }
}
