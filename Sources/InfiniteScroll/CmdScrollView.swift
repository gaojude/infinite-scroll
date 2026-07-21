import AppKit
import SwiftUI
import SwiftTerm

// MARK: - CmdNSScrollView: intercepts Cmd+scroll for window scrolling

class CmdNSScrollView: NSScrollView {
    private var eventMonitor: Any?

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

                        // Keep scrolling local to SwiftTerm even for tmux-backed
                        // terminals. Entering tmux copy-mode here made the pane
                        // appear frozen and left its status line visible until Esc.
                        // Do not forward the NSEvent itself: SwiftTerm's
                        // scrollWheel implementation reads the legacy `deltaY`,
                        // which can be zero for precise trackpad events even when
                        // `scrollingDeltaY` is non-zero. That swallowed scrolling
                        // entirely after this outer monitor had consumed it.
                        let lines = max(1, Int(abs(delta) / 12))
                        if delta > 0 {
                            termView.scrollUp(lines: lines)
                        } else {
                            termView.scrollDown(lines: lines)
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
