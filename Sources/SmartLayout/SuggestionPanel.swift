import AppKit

/// Плавающее окно с подсказкой. Не забирает фокус у приложения, в котором вы печатаете.
/// Показывает исправленный текст и, если есть, альтернативную формулировку.
final class SuggestionPanel: NSObject {
    private let panel: NSPanel
    private let titleLabel = NSTextField(labelWithString: "")
    private let textLabel = NSTextField(wrappingLabelWithString: "")
    private let altTitleLabel = NSTextField(labelWithString: "Вариант формулировки")
    private let altLabel = NSTextField(wrappingLabelWithString: "")
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private let nextTitleLabel = NSTextField(labelWithString: "Дальше можно написать")
    private let nextLabel = NSTextField(wrappingLabelWithString: "")
    private var nextButton: NSButton!
    private var acceptButton: NSButton!
    private var onAcceptNext: (() -> Void)?
    private var altButton: NSButton!
    private var onAccept: (() -> Void)?
    private var onAcceptAlternative: (() -> Void)?
    private var onReject: (() -> Void)?
    private var hideWork: DispatchWorkItem?

    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 180),
                        styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .utilityWindow],
                        backing: .buffered, defer: true)
        super.init()
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        for l in [titleLabel, altTitleLabel, nextTitleLabel] {
            l.font = .systemFont(ofSize: 11, weight: .semibold)
            l.textColor = .secondaryLabelColor
        }
        nextLabel.textColor = .secondaryLabelColor
        for l in [textLabel, altLabel, nextLabel] {
            l.font = .systemFont(ofSize: 13)
            l.isSelectable = true
            l.preferredMaxLayoutWidth = 430
        }
        noteLabel.font = .systemFont(ofSize: 11)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.preferredMaxLayoutWidth = 430

        let accept = NSButton(title: "Исправить  ⌥↩", target: self, action: #selector(acceptTapped))
        accept.bezelColor = .controlAccentColor
        acceptButton = accept
        nextButton = NSButton(title: "Дописать  ⌥⇥", target: self, action: #selector(nextTapped))
        altButton = NSButton(title: "Вариант  ⌥⇧↩", target: self, action: #selector(altTapped))
        let cancel = NSButton(title: "Отмена  Esc", target: self, action: #selector(cancelTapped))
        let buttons = NSStackView(views: [cancel, nextButton, altButton, accept])
        buttons.spacing = 8

        let stack = NSStackView(views: [titleLabel, textLabel, altTitleLabel, altLabel,
                                        nextTitleLabel, nextLabel, noteLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(14, after: textLabel)
        stack.edgeInsets = NSEdgeInsets(top: 26, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 460)
        ])
        panel.contentView = content
    }

    func show(title: String, suggestion: String, alternative: String? = nil, note: String?, near rect: NSRect?,
              onReject: (() -> Void)? = nil, onAcceptAlternative: (() -> Void)? = nil,
              next: String? = nil, onAcceptNext: (() -> Void)? = nil,
              primaryTitle: String = "Исправить  ⌥↩",
              onAccept: @escaping () -> Void) {
        if isVisible { hide() }
        self.onAccept = onAccept
        self.onAcceptAlternative = onAcceptAlternative
        self.onAcceptNext = onAcceptNext
        self.onReject = onReject
        acceptButton.title = primaryTitle
        let hasNext = next != nil && onAcceptNext != nil
        nextTitleLabel.isHidden = !hasNext
        nextLabel.isHidden = !hasNext
        nextButton.isHidden = !hasNext
        nextLabel.stringValue = next ?? ""
        // Если вся подсказка — это продолжение, основная кнопка вставляет его по ⌥⇥.
        let primaryIsNext = primaryTitle.contains("⌥⇥")

        titleLabel.stringValue = title
        textLabel.stringValue = suggestion
        let hasAlt = alternative != nil && onAcceptAlternative != nil
        altTitleLabel.isHidden = !hasAlt
        altLabel.isHidden = !hasAlt
        altButton.isHidden = !hasAlt
        altLabel.stringValue = alternative ?? ""
        noteLabel.stringValue = note ?? ""
        noteLabel.isHidden = (note ?? "").isEmpty

        panel.layoutIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 460, height: 180)
        panel.setContentSize(size)

        // Под курсором ввода, а если его не узнать — рядом с мышью.
        let anchor = rect ?? NSRect(origin: NSEvent.mouseLocation, size: .zero)
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - size.height - 8)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor.origin) }) ?? NSScreen.main {
            let f = screen.visibleFrame
            origin.x = min(max(origin.x, f.minX + 8), f.maxX - size.width - 8)
            if origin.y < f.minY { origin.y = min(anchor.maxY + 8, f.maxY - size.height) }
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()

        if primaryIsNext {
            HotKeyCenter.shared.register(id: HotKeyID.acceptNext, keyCode: 48, modifiers: optionMask) { [weak self] in
                self?.acceptTapped()
            }
        } else {
            HotKeyCenter.shared.register(id: HotKeyID.accept, keyCode: 36, modifiers: optionMask) { [weak self] in
                self?.acceptTapped()
            }
        }
        if hasNext {
            HotKeyCenter.shared.register(id: HotKeyID.acceptNext, keyCode: 48, modifiers: optionMask) { [weak self] in
                self?.nextTapped()
            }
        }
        if hasAlt {
            HotKeyCenter.shared.register(id: HotKeyID.acceptAlternative, keyCode: 36,
                                         modifiers: optionMask | shiftMask) { [weak self] in self?.altTapped() }
        }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    /// Закрыть без принятия. Отказом (`rejected: true`) считаются только Esc и кнопка «Отмена»:
    /// продолжение набора, таймаут или новая подсказка ничего не говорят о том, согласны ли вы
    /// с правкой, и не должны учить ИИ «не трогать» слово.
    func hide(rejected: Bool = false) {
        let reject = onReject
        close()
        if rejected { reject?() }
    }

    private func close() {
        hideWork?.cancel()
        HotKeyCenter.shared.unregister(id: HotKeyID.accept)
        HotKeyCenter.shared.unregister(id: HotKeyID.acceptAlternative)
        HotKeyCenter.shared.unregister(id: HotKeyID.acceptNext)
        onAcceptNext = nil
        panel.orderOut(nil)
        onAccept = nil
        onAcceptAlternative = nil
        onReject = nil
    }

    @objc private func acceptTapped() {
        let action = onAccept
        close()
        action?()
    }

    @objc private func altTapped() {
        let action = onAcceptAlternative
        close()
        action?()
    }

    @objc private func nextTapped() {
        let action = onAcceptNext
        close()
        action?()
    }

    @objc private func cancelTapped() { hide(rejected: true) }
}

// Модификаторы Carbon: optionKey = 1 << 11, shiftKey = 1 << 9.
private let optionMask: UInt32 = 1 << 11
private let shiftMask: UInt32 = 1 << 9
