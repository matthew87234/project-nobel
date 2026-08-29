import SwiftUI
import AppKit

struct PointingHandModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onHover { isHovered in
                if isHovered {
                    NSCursor.pointingHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
    }
}

extension View {
    /// Changes the mouse cursor to a pointing hand (clicky cursor) when hovering over clickable/interactive elements
    func pointingHandCursor() -> some View {
        self.modifier(PointingHandModifier())
    }
}
