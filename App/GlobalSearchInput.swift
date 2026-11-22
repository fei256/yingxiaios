#if os(iOS)
import SwiftUI
import UIKit

struct GlobalSearchFocusRequest: Equatable {
    let id = UUID()
    let focused: Bool
}

/// Keep the header's native text field mounted when the result content changes.
struct GlobalSearchSurface<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View { ZStack { content() }.frame(maxWidth: .infinity, maxHeight: .infinity) }
}

/// Publish IME letters for suggestions while preserving the keyboard's marked text.
struct GlobalSearchInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    var focusRequest: GlobalSearchFocusRequest? = nil
    let submit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        makeTextField(coordinator: context.coordinator, field: GlobalSearchTextField())
    }

    @MainActor func makeTextField(coordinator: Coordinator, field: GlobalSearchTextField) -> UITextField {
        field.font = .systemFont(ofSize: 17)
        field.textColor = .label
        field.contentVerticalAlignment = .center
        field.placeholder = "搜索影片、中文或拼音"
        field.returnKeyType = .search
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.delegate = coordinator
        field.addTarget(coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.focusAvailabilityChanged = { [weak coordinator] field in coordinator?.resumeFocus(in: field) }
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.accessibilityIdentifier = "search.input"
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if text != coordinator.publishedText {
            coordinator.updating = true
            field.unmarkText()
            field.text = text
            coordinator.publishedText = text
            coordinator.updating = false
        }
        coordinator.requestFocus(focusRequest, in: field)
    }

    static func dismantleUIView(_ field: UITextField, coordinator: Coordinator) {
        coordinator.cancelFocusRequests()
        if let field = field as? GlobalSearchTextField {
            field.focusAvailabilityChanged = nil
            field.stopObservingFocusAvailability()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
        CGSize(width: max(0, proposal.width ?? uiView.intrinsicContentSize.width), height: proposal.height ?? 44)
    }

    @MainActor final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: GlobalSearchInput
        var publishedText: String?
        var updating = false
        private var appliedFocusRequest: UUID?
        private var pendingFocusRequest: GlobalSearchFocusRequest?
        private var focusRevision: UInt64 = 0
        private var focusScheduled = false
        private var focusAttempts = 0

        init(_ parent: GlobalSearchInput) { self.parent = parent }

        func requestFocus(_ request: GlobalSearchFocusRequest?, in field: UITextField) {
            guard let request else { cancelFocusRequests(); return }
            guard request.id != appliedFocusRequest else { return }
            if pendingFocusRequest?.id != request.id {
                cancelFocusRequests()
                pendingFocusRequest = request
            }
            resumeFocus(in: field)
        }

        func cancelFocusRequests() {
            focusRevision &+= 1
            pendingFocusRequest = nil
            focusScheduled = false
            focusAttempts = 0
        }

        /// Acknowledge the command after the native responder state matches it.
        /// Window events resume pending commands; a ready window gets bounded retries.
        func resumeFocus(in field: UITextField, delay: TimeInterval = 0) {
            guard let request = pendingFocusRequest else { return }
            if field.isFirstResponder == request.focused {
                appliedFocusRequest = request.id
                cancelFocusRequests()
                return
            }
            guard !focusScheduled, focusAttempts < 4 else { return }
            focusScheduled = true
            let revision = focusRevision
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak field] in
                guard let self, self.focusRevision == revision else { return }
                self.focusScheduled = false
                guard let field, self.pendingFocusRequest?.id == request.id else { return }
                guard !request.focused || field.window?.isKeyWindow == true else { return }
                self.focusAttempts += 1
                if request.focused { field.becomeFirstResponder() }
                else { field.resignFirstResponder() }
                guard self.focusRevision == revision, self.pendingFocusRequest?.id == request.id else { return }
                if field.isFirstResponder == request.focused {
                    self.appliedFocusRequest = request.id
                    self.cancelFocusRequests()
                } else if self.focusAttempts < 4 {
                    self.resumeFocus(in: field, delay: [0.05, 0.15, 0.3][self.focusAttempts - 1])
                }
            }
        }

        @objc func changed(_ field: UITextField) {
            guard !updating, field.isFirstResponder else { return }
            parent.focused = true
            let value = field.text ?? ""
            publishedText = value
            parent.text = value
        }

        func textFieldDidBeginEditing(_ field: UITextField) { parent.focused = true }
        func textFieldDidEndEditing(_ field: UITextField) { parent.focused = false }
        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            if field.markedTextRange != nil {
                field.unmarkText()
                changed(field)
                return false
            }
            changed(field)
            parent.submit()
            return true
        }
    }
}

class GlobalSearchTextField: UITextField {
    var focusAvailabilityChanged: (@MainActor (UITextField) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        stopObservingFocusAvailability()
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey(_:)),
                name: UIWindow.didBecomeKeyNotification, object: window)
            focusAvailabilityChanged?(self)
        }
    }

    func stopObservingFocusAvailability() {
        NotificationCenter.default.removeObserver(self, name: UIWindow.didBecomeKeyNotification, object: nil)
    }

    @objc private func windowBecameKey(_ notification: Notification) {
        guard let target = notification.object as? UIWindow, target === window else { return }
        focusAvailabilityChanged?(self)
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
#endif
