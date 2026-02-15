import SwiftUI
import AppKit

/// NSPanel subclass that accepts key events and doesn't close on Escape.
class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        // Don't close on Escape — panel uses hotkey to toggle
    }

    override func keyDown(with event: NSEvent) {
        super.keyDown(with: event)
    }
}

/// Manages the slide-out panel lifecycle: creation, show/hide animation, resize, and key monitoring.
class PanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var isVisible = false
    private var notesDirectory: URL
    private var hostingView: NSHostingView<PanelContentView>?
    private var previousApp: NSRunningApplication?
    private var keyMonitor: Any?
    private let panelState = PanelState()
    private var lastGPressTime: TimeInterval = 0

    override init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.notesDirectory = home.appendingPathComponent("obsidian")
        super.init()
        setupPanel()
    }

    private func setupPanel() {
        guard let screen = NSScreen.main else { return }

        let screenFrame = screen.visibleFrame
        let panelWidth = screenFrame.width * 0.4
        let panelHeight = screenFrame.height

        let offscreenFrame = NSRect(
            x: screenFrame.maxX,
            y: screenFrame.minY,
            width: panelWidth,
            height: panelHeight
        )

        let keyablePanel = KeyablePanel(
            contentRect: offscreenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel = keyablePanel

        guard let panel = panel else { return }

        panel.delegate = self
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let contentView = PanelContentView(
            notesDirectory: notesDirectory,
            panelState: panelState,
            onFocusPanel: { [weak self] in self?.focusPanel() },
            onClose: { [weak self] in self?.hide() },
            onResize: { [weak self] width in self?.resize(toWidth: width) },
            getScreenMaxX: { NSScreen.main?.visibleFrame.maxX ?? 0 }
        )
        let hosting = NSHostingView(rootView: contentView)
        hostingView = hosting
        panel.contentView = hostingView
    }

    /// @param width Desired panel width, clamped to [300, 80% of screen width].
    private func resize(toWidth width: CGFloat) {
        guard let panel = panel, let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let minWidth: CGFloat = 300
        let maxWidth = screenFrame.width * 0.8

        let newWidth = max(minWidth, min(maxWidth, width))
        let newFrame = NSRect(
            x: screenFrame.maxX - newWidth,
            y: screenFrame.minY,
            width: newWidth,
            height: screenFrame.height
        )
        panel.setFrame(newFrame, display: true)
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    /// Slides the panel in from the right edge with a deceleration curve.
    func show() {
        guard let panel = panel, let screen = NSScreen.main else { return }

        previousApp = NSWorkspace.shared.frontmostApplication

        let screenFrame = screen.visibleFrame
        let panelWidth = panel.frame.width

        let offscreenFrame = NSRect(
            x: screenFrame.maxX,
            y: screenFrame.minY,
            width: panelWidth,
            height: screenFrame.height
        )
        panel.setFrame(offscreenFrame, display: false)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let visibleFrame = NSRect(
            x: screenFrame.maxX - panelWidth,
            y: screenFrame.minY,
            width: panelWidth,
            height: screenFrame.height
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().setFrame(visibleFrame, display: true)
        }

        installKeyMonitor()
        isVisible = true
    }

    /// Slides the panel off-screen and restores focus to the previous app.
    func hide() {
        guard let panel = panel, let screen = NSScreen.main else { return }

        let screenFrame = screen.visibleFrame
        let panelWidth = panel.frame.width

        let offscreenFrame = NSRect(
            x: screenFrame.maxX,
            y: screenFrame.minY,
            width: panelWidth,
            height: screenFrame.height
        )

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().setFrame(offscreenFrame, display: true)
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            self?.isVisible = false
            self?.removeKeyMonitor()
            self?.previousApp?.activate()
            self?.previousApp = nil
        })
    }

    /// Installs a local key monitor for Cmd+P (search toggle), Escape (close search),
    /// and arrow/vim keys for search result navigation.
    private func installKeyMonitor() {
        if keyMonitor != nil { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isVisible else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "p" {
                self.panelState.toggleSearch()
                return nil
            }
            if event.keyCode == 53, self.panelState.isSearchVisible {
                self.panelState.closeSearch()
                return nil
            }
            if self.panelState.isSearchVisible {
                if event.keyCode == 126 { // up arrow
                    self.panelState.moveSelection(delta: -1)
                    return nil
                }
                if event.keyCode == 125 { // down arrow
                    self.panelState.moveSelection(delta: 1)
                    return nil
                }
                // Vim-style navigation in search results (only when search field isn't focused)
                if !self.panelState.isSearchFieldFocused {
                    if event.keyCode == 5, modifiers.contains(.shift) { // G
                        self.panelState.selectLast()
                        return nil
                    }
                    if event.keyCode == 5, modifiers.isDisjoint(with: [.command, .control, .option, .shift]) { // g
                        let now = Date().timeIntervalSinceReferenceDate
                        if now - self.lastGPressTime < 0.4 {
                            self.panelState.selectFirst()
                            self.lastGPressTime = 0
                            return nil
                        } else {
                            self.lastGPressTime = now
                        }
                    }
                }
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func focusPanel() {
        guard let panel = panel else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        panel.makeKey()
        panel.makeMain()
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        vimLog("[windowDidBecomeKey]")
    }

    /// Only re-grabs focus if the panel is visible AND the app losing focus is
    /// a transient system UI (e.g. Spotlight). Does NOT fight other apps for focus.
    func windowDidResignKey(_ notification: Notification) {
        guard isVisible else { return }
        // Allow other apps to take focus — don't fight for it.
        // The panel is floating and will remain visible; the user can
        // re-focus via the hotkey or by clicking the panel.
        vimLog("[windowDidResignKey] panel lost focus, not re-grabbing")
    }

    func windowDidBecomeMain(_ notification: Notification) {}
    func windowDidResignMain(_ notification: Notification) {}
}
