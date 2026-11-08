import AppKit

/// "Details" under an alert's text: collapsed at first, a disclosure triangle
/// shows technical text (monospaced, selectable for copying) and grows the
/// alert to fit.
@MainActor
final class AlertDetails: NSView {
    private weak var alert: NSAlert?
    private let toggle = NSButton(title: "", target: nil, action: nil)
    private let label = NSTextField(labelWithString: "Details")
    private let scroll = NSTextView.scrollableTextView()
    private static let width: CGFloat = 260
    private static let row: CGFloat = 18
    private static let textHeight: CGFloat = 110

    init(_ details: String, in alert: NSAlert) {
        self.alert = alert
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.row))
        toggle.bezelStyle = .disclosure
        toggle.setButtonType(.onOff)
        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.setAccessibilityLabel("Details")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(labelClicked)))
        if let text = scroll.documentView as? NSTextView {
            text.string = details
            text.isEditable = false
            text.isSelectable = true
            text.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            text.textContainerInset = NSSize(width: 2, height: 4)
            text.drawsBackground = false
        }
        scroll.drawsBackground = false
        scroll.borderType = .lineBorder
        scroll.isHidden = true
        for v in [toggle, label, scroll] { addSubview(v) }
        place()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func place() {
        let h = frame.height
        toggle.frame = NSRect(x: -2, y: h - Self.row, width: 18, height: Self.row)
        label.frame = NSRect(x: 16, y: h - Self.row + 1, width: frame.width - 16, height: Self.row - 2)
        scroll.frame = NSRect(x: 0, y: 0, width: frame.width, height: max(0, h - Self.row - 4))
    }

    @objc private func labelClicked() {
        toggle.state = toggle.state == .on ? .off : .on
        toggled()
    }

    @objc private func toggled() {
        let open = toggle.state == .on
        scroll.isHidden = !open
        setFrameSize(NSSize(width: frame.width, height: open ? Self.row + 4 + Self.textHeight : Self.row))
        place()
        alert?.layout()
    }
}
