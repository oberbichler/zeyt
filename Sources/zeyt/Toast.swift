import AppKit

/// Short message in the top-right corner that fades out by itself.
@MainActor
enum Toast {
    private static var current: NSPanel?

    static func show(_ message: String, seconds: TimeInterval = 5) {
        current?.orderOut(nil)

        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 13)
        label.preferredMaxLayoutWidth = 300
        let icon = NSImageView(image: NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)!)
        icon.contentTintColor = .controlAccentColor

        let stack = NSStackView(views: [icon, label])
        stack.alignment = .top
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.contentView = background
        panel.setContentSize(background.fittingSize)
        if let vf = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vf.maxX - panel.frame.width - 12, y: vf.maxY - panel.frame.height - 12))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.animator().alphaValue = 1
        current = panel

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            guard current === panel else { return }
            NSAnimationContext.runAnimationGroup({ _ in panel.animator().alphaValue = 0 }) {
                MainActor.assumeIsolated {
                    panel.orderOut(nil)
                    if current === panel { current = nil }
                }
            }
        }
    }
}
