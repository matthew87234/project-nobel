import SwiftUI
import AppKit

struct PointingHandModifier: ViewModifier {
    @State private var isHovering: Bool = false
    
    func body(content: Content) -> some View {
        content
            .onHover { hovered in
                if hovered && !isHovering {
                    isHovering = true
                    NSCursor.pointingHand.push()
                } else if !hovered && isHovering {
                    isHovering = false
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isHovering {
                    isHovering = false
                    NSCursor.pop()
                }
            }
    }
}

extension View {
    /// Changes the mouse cursor to a pointing hand when hovering over interactive elements.
    func pointingHandCursor() -> some View {
        self.modifier(PointingHandModifier())
    }
}
