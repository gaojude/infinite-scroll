import AppKit
import SwiftUI
import SwiftTerm

// MARK: - CmdNSScrollView: intercepts Cmd+scroll for window scrolling

class CmdNSScrollView: NSScrollView {
    private var eventMonitor: Any?
    /// Debounce timer to auto-exit tmux copy-mode after scrolling stops
    private var copyModeExitTimer: DispatchWorkItem?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && eventMonitor == nil {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self = self,
                      let window = self.window,
                      window == event.window else {
                    return event
                }

                if event.modifierFlags.contains(.command) {
                    // Cmd+scroll: scroll the outer window
                    let clipView = self.contentView
                    var newOrigin = clipView.bounds.origin
                    newOrigin.y -= event.scrollingDeltaY
                    let maxY = max(0, (clipView.documentView?.frame.height ?? 0) - clipView.bounds.height)
                    newOrigin.y = min(max(0, newOrigin.y), maxY)
                    clipView.setBoundsOrigin(newOrigin)
                    self.reflectScrolledClipView(clipView)
                    return nil
                }

                // Non-Cmd scroll: find terminal view under cursor and forward to it.
                guard let docView = self.contentView.documentView else { return event }
                let loc = docView.convert(event.locationInWindow, from: nil)
                guard let hitView = docView.hitTest(loc) else { return event }
                var current: NSView? = hitView
                while let view = current {
                    if let termView = view as? LocalProcessTerminalView {
                        let delta = event.scrollingDeltaY
                        if delta == 0 { return nil }

                        if let session = TerminalViewRegistry.shared.tmuxSession(for: termView) {
                            // tmux-backed: use tmux copy-mode scrolling.
                            let lineHeight: CGFloat = 16
                            let lines = max(1, Int(abs(delta) / lineHeight))
                            let cmd = delta > 0 ? "scroll-up" : "scroll-down"

                            // Cancel any pending copy-mode exit
                            self.copyModeExitTimer?.cancel()

                            DispatchQueue.global(qos: .userInteractive).async {
                                TmuxManager.run(["copy-mode", "-t", session])
                                for _ in 0..<lines {
                                    TmuxManager.run(["send-keys", "-t", session, "-X", cmd])
                                }
                            }

                            // Auto-exit copy-mode after 1s of no scrolling
                            let exitWork = DispatchWorkItem {
                                TmuxManager.run(["send-keys", "-t", session, "-X", "cancel"])
                            }
                            self.copyModeExitTimer = exitWork
                            DispatchQueue.global(qos: .utility).asyncAfter(
                                deadline: .now() + 1.0, execute: exitWork)
                        } else {
                            // No tmux — use SwiftTerm's own scrollback buffer
                            termView.scrollWheel(with: event)
                        }
                        return nil
                    }
                    current = view.superview
                }
                return event
            }
        }
    }

    override func removeFromSuperview() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        super.removeFromSuperview()
    }

    // All scroll handling is done via the event monitor above.
    // This override prevents NSScrollView from scrolling its content on any stray events.
    override func scrollWheel(with event: NSEvent) {
        // no-op — monitor handles everything
    }
}

// MARK: - CmdScrollView: SwiftUI wrapper

struct CmdScrollView<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> CmdNSScrollView {
        let scrollView = CmdNSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false

        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let clipView = NSClipView()
        clipView.drawsBackground = false
        clipView.documentView = hostingView
        scrollView.contentView = clipView

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: clipView.topAnchor),
        ])

        return scrollView
    }

    func updateNSView(_ nsView: CmdNSScrollView, context: Context) {
        guard let hostingView = nsView.contentView.documentView as? NSHostingView<Content> else { return }
        hostingView.rootView = content
    }
}
