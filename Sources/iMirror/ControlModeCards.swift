import AppKit

/// Native radio controls with a description for each input mode.
final class ControlModeCards: NSStackView {
    enum Mode: Int { case directUSB, webDriverAgent }

    var onSelection: ((Mode) -> Void)?
    private var radios: [Mode: NSButton] = [:]
    private var cards: [Mode: NSBox] = [:]
    private var badges: [Mode: NSTextField] = [:]

    init(width: CGFloat) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        addCard(.directUSB, width: width, title: "Direct USB", symbol: "cable.connector",
                description: "Live USB preview. Add Wired Control for taps, swipes, and typing through Apple’s CoreDevice.")
        addCard(.webDriverAgent, width: width, title: "WebDriverAgent", symbol: "point.3.connected.trianglepath.dotted",
                description: "Control the iPhone with XCTest and give agents access to the accessibility tree.")
        showSelection(.directUSB)
    }

    required init?(coder: NSCoder) { nil }

    func showSelection(_ selection: Mode) {
        for (mode, radio) in radios {
            let selected = mode == selection
            radio.state = selected ? .on : .off
            let badge = badges[mode]
            badge?.stringValue = mode == .directUSB
                ? (selected ? "Default · Selected" : "Default") : (selected ? "Selected" : "")
            badge?.textColor = selected ? .controlAccentColor : .secondaryLabelColor
            cards[mode]?.borderColor = selected
                ? .controlAccentColor.withAlphaComponent(0.65) : .separatorColor
            cards[mode]?.fillColor = selected
                ? .controlAccentColor.withAlphaComponent(0.12) : .controlBackgroundColor.withAlphaComponent(0.45)
        }
    }

    private func addCard(_ mode: Mode, width: CGFloat, title: String, symbol: String, description: String) {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        icon.widthAnchor.constraint(equalToConstant: 21).isActive = true
        icon.setAccessibilityElement(false)

        let radio = NSButton(radioButtonWithTitle: title, target: self, action: #selector(selected(_:)))
        radio.tag = mode.rawValue
        radio.font = .systemFont(ofSize: 13, weight: .semibold)
        radio.setAccessibilityHelp(description)
        radios[mode] = radio

        let badge = NSTextField(labelWithString: "")
        badge.font = .systemFont(ofSize: 11, weight: .medium)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        badges[mode] = badge

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let radioSlot = NSView()
        radioSlot.widthAnchor.constraint(equalToConstant: radio.fittingSize.width).isActive = true
        radioSlot.heightAnchor.constraint(equalToConstant: max(18, radio.fittingSize.height)).isActive = true
        let header = NSStackView(views: [icon, radioSlot, spacer, badge])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 7

        let detail = NSTextField(wrappingLabelWithString: description)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = width - 24
        let body = NSStackView(views: [header, detail])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 5
        body.translatesAutoresizingMaskIntoConstraints = false

        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 1
        box.cornerRadius = 14
        let content = NSView()
        box.contentView = content
        content.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            body.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            body.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            header.widthAnchor.constraint(equalTo: body.widthAnchor),
            detail.widthAnchor.constraint(equalTo: body.widthAnchor),
            box.widthAnchor.constraint(equalToConstant: width),
        ])
        cards[mode] = box
        addArrangedSubview(box)

        // AppKit groups radio buttons only when they share a parent and an action.
        // Anchor each radio over its card's reserved slot to keep that native group.
        radio.translatesAutoresizingMaskIntoConstraints = false
        addSubview(radio, positioned: .above, relativeTo: box)
        NSLayoutConstraint.activate([
            radio.leadingAnchor.constraint(equalTo: radioSlot.leadingAnchor),
            radio.centerYAnchor.constraint(equalTo: radioSlot.centerYAnchor),
        ])
    }

    @objc private func selected(_ sender: NSButton) {
        guard let mode = Mode(rawValue: sender.tag) else { return }
        showSelection(mode)
        onSelection?(mode)
    }
}

final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}
