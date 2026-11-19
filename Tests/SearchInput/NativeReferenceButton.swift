import SwiftUI
import UIKit

/// An ordinary UIKit control checks the native gesture layer against a fixed rectangular target.
struct NativeReferenceButton: UIViewRepresentable {
    let action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
        button.setTitle("N", for: .normal)
        button.accessibilityIdentifier = "native.reference"
        button.addTarget(context.coordinator, action: #selector(Coordinator.tapped), for: .touchUpInside)
        return button
    }
    func updateUIView(_ button: UIButton, context: Context) { context.coordinator.parent = self }
    @MainActor final class Coordinator: NSObject {
        var parent: NativeReferenceButton
        init(_ parent: NativeReferenceButton) { self.parent = parent }
        @objc func tapped() { parent.action() }
    }
}
