import SwiftUI
import AppKit

/// Drag handle on the left edge of the panel for resizing.
struct ResizeHandle: View {
    let onResize: (CGFloat) -> Void
    let getScreenMaxX: () -> CGFloat

    var body: some View {
        ZStack {
            ResizeHandleView(onResize: onResize, getScreenMaxX: getScreenMaxX)
                .frame(maxHeight: .infinity)

            VStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: 4, height: 1)
                }
            }
            .allowsHitTesting(false)
        }
        .frame(width: 12)
        .frame(maxHeight: .infinity)
    }
}

/// NSViewRepresentable bridge for the resize drag view.
struct ResizeHandleView: NSViewRepresentable {
    let onResize: (CGFloat) -> Void
    let getScreenMaxX: () -> CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = ResizeDragView()
        view.onResize = onResize
        view.getScreenMaxX = getScreenMaxX
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// NSView that handles mouse drag events for panel resizing.
class ResizeDragView: NSView {
    var onResize: ((CGFloat) -> Void)?
    var getScreenMaxX: (() -> CGFloat)?
    private var cursorToEdgeOffset: CGFloat = 0
    private var trackingArea: NSTrackingArea?
    private var isDragging = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.resizeLeftRight.push()
    }

    override func mouseExited(with event: NSEvent) {
        if !isDragging {
            NSCursor.pop()
        }
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        let cursorX = NSEvent.mouseLocation.x
        let panelLeftEdge = window?.frame.minX ?? 0
        cursorToEdgeOffset = cursorX - panelLeftEdge
    }

    override func mouseDragged(with event: NSEvent) {
        let cursorX = NSEvent.mouseLocation.x
        let targetLeftEdge = cursorX - cursorToEdgeOffset
        let screenMaxX = getScreenMaxX?() ?? 0
        let newWidth = screenMaxX - targetLeftEdge
        onResize?(newWidth)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        NSCursor.pop()
    }
}
