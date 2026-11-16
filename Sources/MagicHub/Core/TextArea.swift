import AppKit
import SwiftUI

/// ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z для полей ввода в чёлке.
/// У приложения без меню «Правка» (оно живёт в чёлке) эти сочетания сами до полей не доходят:
/// в обычных программах их доставляет именно меню. Поэтому отправляем команду вручную.
enum EditShortcuts {
    static func action(for event: NSEvent) -> Selector? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else { return nil }
        let shift = flags.contains(.shift)
        // Буква по раскладке, а для русской раскладки — по клавише (на «м» та же клавиша, что и V).
        var letter = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if letter.count != 1 || !(letter.first?.isASCII ?? false) {
            switch event.keyCode {
            case 0: letter = "a"
            case 6: letter = "z"
            case 7: letter = "x"
            case 8: letter = "c"
            case 9: letter = "v"
            default: return nil
            }
        }
        switch (letter, shift) {
        case ("v", false): return #selector(NSText.paste(_:))
        case ("v", true): return #selector(NSTextView.pasteAsPlainText(_:))
        case ("c", false): return #selector(NSText.copy(_:))
        case ("x", false): return #selector(NSText.cut(_:))
        case ("a", false): return #selector(NSText.selectAll(_:))
        case ("z", false): return Selector(("undo:"))
        case ("z", true): return Selector(("redo:"))
        default: return nil
        }
    }

    /// Выполнить сочетание в поле, где сейчас курсор. false — сочетание не наше или некому его выполнить.
    static func handle(_ event: NSEvent) -> Bool {
        guard let action = action(for: event) else { return false }
        return NSApp.sendAction(action, to: nil, from: nil)
    }
}

/// Многострочное поле ввода для чёлки вместо `TextEditor`.
/// Клик в любое место поля ставит туда курсор (в том числе первым же кликом), пустое место под текстом
/// ставит курсор в конец, работают ⌘V и остальные сочетания, вставляется только текст без оформления.
/// Отступ от края — внутри самого поля, чтобы и у краёв карточки клик попадал в поле.
struct MHTextArea: View {
    @Binding var text: String
    var fontSize: CGFloat = 14
    var placeholder: String = ""
    var inset: CGFloat = 10

    var body: some View {
        TextAreaRepresentable(text: $text, fontSize: fontSize, inset: inset)
            .overlay(alignment: .topLeading) {
                if text.isEmpty && !placeholder.isEmpty {
                    Text(placeholder)
                        .font(.system(size: fontSize))
                        .foregroundStyle(MH.t3)
                        .padding(.leading, inset)
                        .padding(.top, inset)
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct TextAreaRepresentable: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let inset: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> TextAreaScrollView {
        let scroll = TextAreaScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        let size = scroll.contentSize
        let tv = TextAreaView(frame: NSRect(origin: .zero, size: size))
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isEditable = true
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: fontSize)
        tv.textColor = NSColor(MH.t1)
        tv.insertionPointColor = NSColor(MH.accent)
        // 5 — внутренний отступ строки NSTextView: текст начинается ровно в `inset` от края.
        tv.textContainerInset = NSSize(width: max(0, inset - 5), height: inset)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: size.height)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: size.width, height: CGFloat.greatestFiniteMagnitude)
        tv.string = text

        scroll.documentView = tv
        scroll.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: TextAreaScrollView, context: Context) {
        context.coordinator.text = $text
        guard let tv = scroll.textView else { return }
        // Текст поменяли снаружи (очистили, выбрали другую заметку) — показать его.
        if tv.string != text, !tv.hasMarkedText() {
            tv.string = text
        }
        if tv.font?.pointSize != fontSize {
            tv.font = .systemFont(ofSize: fontSize)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            if text.wrappedValue != tv.string { text.wrappedValue = tv.string }
        }
    }
}

/// Прокрутка вокруг поля: поле всегда во всю её высоту, а клик мимо текста ставит курсор в конец.
final class TextAreaScrollView: NSScrollView {
    weak var textView: NSTextView?

    override func tile() {
        super.tile()
        guard let tv = textView else { return }
        let height = contentSize.height
        if tv.minSize.height != height {
            tv.minSize = NSSize(width: 0, height: height)
            tv.sizeToFit()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let tv = textView else { return super.mouseDown(with: event) }
        window?.makeKey()
        window?.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
    }
}

private final class TextAreaView: NSTextView {
    /// Первый же клик ставит курсор туда, куда нажали, а не только делает окно активным.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, EditShortcuts.handle(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
}
