import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Логика простого калькулятора: + − × ÷, %, ±, история.
/// Одна на всё приложение и сохраняется на диск: сворачивание хаба и перезапуск ничего не сбрасывают.
final class CalcEngine: ObservableObject {
    static let shared = CalcEngine()

    struct Entry: Identifiable, Codable {
        var id = UUID()
        let expression: String
        let result: String
    }

    /// Внутреннее представление числа на дисплее (точка как разделитель) или «Ошибка».
    @Published var display = "0" { didSet { save() } }
    @Published var accumulator: Double? { didSet { save() } }
    @Published var pendingOp: String? { didSet { save() } }
    @Published var fresh = true { didSet { save() } }
    @Published var history: [Entry] = [] { didSet { save() } }
    /// Последнее действие — повторное «=» повторяет его (5 + 2 = = = → 7, 9, 11).
    private var lastOp: String?
    private var lastOperand: Double?

    static let error = "Ошибка"
    private var isError: Bool { display == CalcEngine.error }

    // MARK: Сохранение

    private struct Saved: Codable {
        var display: String
        var accumulator: Double?
        var pendingOp: String?
        var fresh: Bool
        var history: [Entry]
        var lastOp: String?
        var lastOperand: Double?
    }

    private static let file = "calculator.json"
    private var loading = false
    private var saveWork: DispatchWorkItem?

    init() {
        guard let s = JSONStore.load(Saved.self, from: Self.file) else { return }
        loading = true
        display = s.display
        accumulator = s.accumulator
        pendingOp = s.pendingOp
        fresh = s.fresh
        history = s.history
        lastOp = s.lastOp
        lastOperand = s.lastOperand
        loading = false
    }

    private func save() {
        guard !loading else { return }
        saveWork?.cancel()
        let snapshot = Saved(display: display, accumulator: accumulator, pendingOp: pendingOp, fresh: fresh,
                             history: history, lastOp: lastOp, lastOperand: lastOperand)
        let work = DispatchWorkItem { JSONStore.save(snapshot, to: Self.file) }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: Отображение

    var shownDisplay: String { CalcEngine.show(display) }

    var pendingLine: String {
        guard let op = pendingOp, let acc = accumulator else { return "" }
        return CalcEngine.show(CalcEngine.format(acc)) + " " + op
    }

    static func show(_ raw: String) -> String { raw.replacingOccurrences(of: ".", with: ",") }

    static func format(_ v: Double) -> String {
        guard v.isFinite else { return error }
        if v == 0 { return "0" }
        return String(format: "%.12g", v)
    }

    private static func apply(_ a: Double, _ b: Double, _ op: String) -> Double {
        switch op {
        case "+": return a + b
        case "−": return a - b
        case "×": return a * b
        case "÷": return b == 0 ? .nan : a / b
        default: return b
        }
    }

    private var value: Double { Double(display) ?? 0 }

    // MARK: Ввод

    func press(_ key: String) {
        switch key {
        case "0"..."9" where key.count == 1:
            digit(key)
        case ",":
            comma()
        case "C":
            clear()
        case "±":
            if !isError && display != "0" {
                display = display.hasPrefix("-") ? String(display.dropFirst()) : "-" + display
            }
        case "%":
            if !isError { display = CalcEngine.format(value / 100) }
        case "=":
            equals()
        case "÷", "×", "−", "+":
            operation(key)
        default:
            break
        }
    }

    func backspace() {
        guard !isError, !fresh else { return }
        display.removeLast()
        if display.isEmpty || display == "-" { display = "0" }
    }

    func pick(_ entry: Entry) {
        display = entry.result
        fresh = true
    }

    func clearHistory() { history = [] }

    /// Число из буфера обмена: «1 234,5», «1,234.5», «−7» и т. п.
    @discardableResult
    func pasteFromClipboard() -> Bool {
        guard let raw = NSPasteboard.general.string(forType: .string) else { return false }
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{2212}", with: "-")
            .filter { !$0.isWhitespace && $0 != "'" }
        if s.contains(","), s.contains(".") {
            // Разделитель тысяч — тот, что стоит раньше.
            let thousands: Character = (s.firstIndex(of: ",")! < s.firstIndex(of: ".")!) ? "," : "."
            s.removeAll { $0 == thousands }
        }
        s = s.replacingOccurrences(of: ",", with: ".")
        guard let v = Double(s), v.isFinite else { return false }
        display = CalcEngine.format(v)
        fresh = false
        return true
    }

    /// Что копировать: число на дисплее с запятой.
    var copyText: String { isError ? "" : shownDisplay }

    private func digit(_ d: String) {
        if fresh || display == "0" || isError {
            display = d
            fresh = false
        } else {
            let digits = display.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ".", with: "")
            if digits.count < 12 { display += d }
        }
    }

    private func comma() {
        if fresh || isError {
            display = "0."
            fresh = false
        } else if !display.contains(".") {
            display += "."
        }
    }

    private func clear() {
        display = "0"
        accumulator = nil
        pendingOp = nil
        fresh = true
        lastOp = nil
        lastOperand = nil
    }

    private func operation(_ op: String) {
        guard !isError else { return }
        if let pending = pendingOp, let acc = accumulator, !fresh {
            display = CalcEngine.format(CalcEngine.apply(acc, value, pending))
            if isError {
                accumulator = nil
                pendingOp = nil
                fresh = true
                return
            }
        }
        accumulator = value
        pendingOp = op
        fresh = true
        lastOp = nil
        lastOperand = nil
    }

    private func equals() {
        guard !isError else { return }
        let a: Double, b: Double, op: String
        if let pending = pendingOp, let acc = accumulator {
            a = acc
            b = value
            op = pending
        } else if let repeatOp = lastOp, let operand = lastOperand {
            a = value
            b = operand
            op = repeatOp
        } else {
            return
        }
        let result = CalcEngine.format(CalcEngine.apply(a, b, op))
        let expression = CalcEngine.show(CalcEngine.format(a)) + " " + op + " " + CalcEngine.show(CalcEngine.format(b))
        var h = history
        h.insert(Entry(expression: expression, result: result), at: 0)
        if h.count > 50 { h.removeLast(h.count - 50) }
        history = h
        lastOp = op
        lastOperand = b
        display = result
        accumulator = nil
        pendingOp = nil
        fresh = true
    }
}

/// Вкладка «Калькулятор».
struct CalculatorTabView: View {
    @ObservedObject private var calc = CalcEngine.shared
    @FocusState private var focused: Bool

    private struct CalcKey: Identifiable {
        enum Kind { case digit, function, operation, equals }
        let label: String
        let kind: Kind
        let aria: String
        var wide = false
        var id: String { label }
    }

    private let keys: [CalcKey] = [
        CalcKey(label: "C", kind: .function, aria: "Сбросить"),
        CalcKey(label: "±", kind: .function, aria: "Сменить знак"),
        CalcKey(label: "%", kind: .function, aria: "Процент"),
        CalcKey(label: "÷", kind: .operation, aria: "Разделить"),
        CalcKey(label: "7", kind: .digit, aria: "7"),
        CalcKey(label: "8", kind: .digit, aria: "8"),
        CalcKey(label: "9", kind: .digit, aria: "9"),
        CalcKey(label: "×", kind: .operation, aria: "Умножить"),
        CalcKey(label: "4", kind: .digit, aria: "4"),
        CalcKey(label: "5", kind: .digit, aria: "5"),
        CalcKey(label: "6", kind: .digit, aria: "6"),
        CalcKey(label: "−", kind: .operation, aria: "Вычесть"),
        CalcKey(label: "1", kind: .digit, aria: "1"),
        CalcKey(label: "2", kind: .digit, aria: "2"),
        CalcKey(label: "3", kind: .digit, aria: "3"),
        CalcKey(label: "+", kind: .operation, aria: "Сложить"),
        CalcKey(label: "0", kind: .digit, aria: "0", wide: true),
        CalcKey(label: ",", kind: .digit, aria: "Запятая"),
        CalcKey(label: "=", kind: .equals, aria: "Равно")
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            historyColumn
                .frame(width: 210)
            VStack(spacing: 8) {
                display
                keypad
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down) { press in
            handle(press) ? .handled : .ignored
        }
        .onCopyCommand { copyResult() }
        .onPasteCommand(of: [UTType.plainText, UTType.utf8PlainText]) { _ in paste() }
        .onAppear { focused = true }
        .panelMeta("")
    }

    // MARK: История

    private var historyColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("ИСТОРИЯ")
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.8)
                    .foregroundStyle(MH.t3)
                Spacer()
                if !calc.history.isEmpty {
                    Button("Очистить") { calc.clearHistory() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(MH.t3)
                }
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    if calc.history.isEmpty {
                        Text("Пока пусто. Нажмите «=», и пример появится здесь.")
                            .font(.system(size: 12))
                            .foregroundStyle(MH.t3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    }
                    ForEach(calc.history) { entry in
                        Button {
                            calc.pick(entry)
                        } label: {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(entry.expression)
                                    .font(.system(size: 11))
                                    .foregroundStyle(MH.t3)
                                    .lineLimit(1)
                                Text(CalcEngine.show(entry.result))
                                    .font(.system(size: 15))
                                    .foregroundStyle(MH.t1)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(MH.card))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Подставить результат")
                        .contextMenu {
                            Button("Скопировать результат") { copy(CalcEngine.show(entry.result)) }
                            Button("Скопировать пример") { copy(entry.expression + " = " + CalcEngine.show(entry.result)) }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Дисплей

    private var display: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(calc.pendingLine)
                .font(.system(size: 11))
                .foregroundStyle(MH.t3)
                .frame(height: 14)
            Text(calc.shownDisplay)
                .font(.system(size: 30, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(MH.t1)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .frame(height: 58)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(MH.card))
        .contentShape(Rectangle())
        .onTapGesture {
            takeKeyboard()
            copy(calc.copyText)
        }
        .help("Нажмите, чтобы скопировать")
        .contextMenu {
            Button("Скопировать") { copy(calc.copyText) }
            Button("Вставить число") { paste() }
        }
    }

    // MARK: Клавиши

    private var keypad: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(0..<5, id: \.self) { row in
                GridRow {
                    ForEach(keysInRow(row)) { key in
                        keyButton(key)
                            .gridCellColumns(key.wide ? 2 : 1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func keysInRow(_ row: Int) -> [CalcKey] {
        switch row {
        case 0: return Array(keys[0..<4])
        case 1: return Array(keys[4..<8])
        case 2: return Array(keys[8..<12])
        case 3: return Array(keys[12..<16])
        default: return Array(keys[16..<19])
        }
    }

    private func keyButton(_ key: CalcKey) -> some View {
        let activeOp = key.kind == .operation && calc.pendingOp == key.label && calc.fresh
        let background: Color
        let foreground: Color
        switch key.kind {
        case .digit:
            background = Color(hex: "232325")
            foreground = MH.t1
        case .function:
            background = MH.control
            foreground = MH.t1
        case .operation, .equals:
            background = activeOp ? MH.t1 : MH.accent
            foreground = activeOp ? MH.accent : Color.white
        }
        return Button {
            takeKeyboard()
            calc.press(key.label)
        } label: {
            Text(key.label)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 10).fill(background))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(key.aria)
    }

    // MARK: Клавиатура

    /// После клика по калькулятору набирать можно с клавиатуры: чёлка забирает ввод только по клику,
    /// чтобы не перехватывать набор в других программах при случайном наведении.
    private func takeKeyboard() {
        NSApp.currentEvent?.window?.makeKey()
        focused = true
    }

    private func copy(_ text: String) {
        guard !text.isEmpty else { return }
        Clipboard.copy(text)
        AppModel.shared.flash("Скопировано")
    }

    private func copyResult() -> [NSItemProvider] {
        let text = calc.copyText
        guard !text.isEmpty else { return [] }
        AppModel.shared.flash("Скопировано")
        return [NSItemProvider(object: text as NSString)]
    }

    private func paste() {
        if !calc.pasteFromClipboard() { AppModel.shared.flash("В буфере нет числа") }
    }

    private func handle(_ press: KeyPress) -> Bool {
        if press.modifiers.contains(.command) {
            // Запасной путь для ⌘C / ⌘V (в том числе в русской раскладке).
            switch press.characters.lowercased() {
            case "c", "с": copy(calc.copyText); return true
            case "v", "м": paste(); return true
            default: return false
            }
        }
        if press.key == .escape { return false }
        if press.key == .return {
            calc.press("=")
            return true
        }
        if press.key == .delete || press.key == .deleteForward {
            calc.backspace()
            return true
        }
        let chars = press.characters
        guard chars.count == 1, let ch = chars.first else { return false }
        switch ch {
        case "0"..."9": calc.press(String(ch))
        case ",", ".": calc.press(",")
        case "+": calc.press("+")
        case "-": calc.press("−")
        case "*", "x", "х": calc.press("×")
        case "/", ":": calc.press("÷")
        case "=": calc.press("=")
        case "%": calc.press("%")
        case "c", "C", "с", "С": calc.press("C")
        default: return false
        }
        return true
    }
}
