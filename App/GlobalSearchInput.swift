#if os(iOS)
import SwiftUI
import UIKit

/// Publish IME letters for suggestions while preserving the keyboard's marked text.
struct GlobalSearchInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let submit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.font = .systemFont(ofSize: 17)
        field.textColor = .label
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
        if !focused && field.isFirstResponder {
            field.resignFirstResponder()
        } else if focused && !field.isFirstResponder {
            DispatchQueue.main.async { [weak field, weak coordinator] in
                guard let field, let coordinator, coordinator.parent.focused, field.window != nil else { return }
                field.becomeFirstResponder()
            }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: GlobalSearchInput
        var publishedText: String?
        var updating = false

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
