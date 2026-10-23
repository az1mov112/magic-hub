import SwiftUI

/// Логика простого калькулятора: + − × ÷, %, ±, история.
private final class CalcEngine: ObservableObject {
    struct Entry: Identifiable {
        let id = UUID()
        let expression: String
        let result: String
    }

    /// Внутреннее представление числа на дисплее (точка как разделитель) или «Ошибка».
    @Published var display = "0"
    @Published var accumulator: Double?
    @Published var pendingOp: String?
    @Published var fresh = true
    @Published var history: [Entry] = []

    static let error = "Ошибка"
    private var isError: Bool { display == CalcEngine.error }

    var shownDisplay: String { CalcEngine.show(display) }

    var pendingLine: String {
        guard let op = pendingOp, let acc = accumulator else { return "" }
        return CalcEngine.show(CalcEngine.format(acc)) + " " + op
    }

    static func show(_ raw: String) -> String { raw.replacingOccurrences(of: ".", with: ",") }

    static func format(_ v: Double) -> String {
        guard v.isFinite else { return error }
        if v == 0 { return "0" }
        let s = String(format: "%.12g", v)
        return s
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
    }

    private func equals() {
        guard let op = pendingOp, let acc = accumulator, !isError else { return }
        let b = value
        let result = CalcEngine.format(CalcEngine.apply(acc, b, op))
        let expression = CalcEngine.show(CalcEngine.format(acc)) + " " + op + " " + CalcEngine.show(CalcEngine.format(b))
        history.insert(Entry(expression: expression, result: result), at: 0)
        if history.count > 30 { history.removeLast(history.count - 30) }
        display = result
        accumulator = nil
        pendingOp = nil
        fresh = true
    }
}

/// Вкладка «Калькулятор».
struct CalculatorTabView: View {
    @StateObject private var calc = CalcEngine()
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
        .onAppear { focused = true }
        .panelMeta("")
    }

    // MARK: История

    private var historyColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ИСТОРИЯ")
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(MH.t3)
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

    private func handle(_ press: KeyPress) -> Bool {
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
