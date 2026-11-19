#if os(iOS)
import SwiftUI
import UIKit

/// A native rectangular touch surface, independent of the label's drawn pixels.
struct ControlTouchProxy: UIViewRepresentable {
    @Binding var pressed: Bool
    let enabled: Bool
    let action: () -> Void
    var accessibilityIdentifier: String? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIButton {
        let button = TouchButton(frame: .zero)
        button.addTarget(context.coordinator, action: #selector(Coordinator.tapped), for: .touchUpInside)
        button.highlightChanged = { [weak coordinator = context.coordinator] value in
            coordinator?.parent.pressed = value
        }
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.parent = self
        button.isEnabled = enabled
        button.isAccessibilityElement = accessibilityIdentifier != nil
        button.accessibilityIdentifier = accessibilityIdentifier
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 48, height: proposal.height ?? 48)
    }

    @MainActor final class Coordinator: NSObject {
        var parent: ControlTouchProxy
        init(_ parent: ControlTouchProxy) { self.parent = parent }
        @objc func tapped() { if parent.enabled { parent.action() } }
    }

    private final class TouchButton: UIButton {
        var highlightChanged: ((Bool) -> Void)?
        override var isHighlighted: Bool {
            didSet { if oldValue != isHighlighted { highlightChanged?(isHighlighted) } }
        }
    }
}
#endif
