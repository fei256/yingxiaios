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
        let field = UITextField()
        field.font = .systemFont(ofSize: 17)
        field.textColor = .label
        field.contentVerticalAlignment = .center
        field.placeholder = "搜索影片、中文或拼音"
        field.returnKeyType = .search
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
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
        if let request = focusRequest, request.id != coordinator.appliedFocusRequest {
            coordinator.appliedFocusRequest = request.id
            DispatchQueue.main.async { [weak field, weak coordinator] in
                guard let field, let coordinator, coordinator.appliedFocusRequest == request.id, field.window != nil else { return }
                if request.focused { field.becomeFirstResponder() }
                else { field.resignFirstResponder() }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
        CGSize(width: max(0, proposal.width ?? uiView.intrinsicContentSize.width), height: proposal.height ?? 44)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: GlobalSearchInput
        var publishedText: String?
        var updating = false
        var appliedFocusRequest: UUID?

        init(_ parent: GlobalSearchInput) { self.parent = parent }

        @objc func changed(_ field: UITextField) {
            guard !updating, parent.focused else { return }
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
#endif
