import SwiftUI
import AppKit

extension Color {
    /// Цвет из шестнадцатеричной строки: "0A84FF" или "#0A84FF".
    init(hex: String, alpha: Double = 1) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

/// Палитра Magic Hub (тёмная тема, как в макете).
enum MH {
    static let accent = Color(hex: "0A84FF")
    static let t1 = Color(hex: "F5F5F7")
    static let t2 = Color(hex: "A1A1A6")
    static let t3 = Color(hex: "8E8E93")
    static let card = Color(hex: "161618")
    static let card2 = Color(hex: "1C1C1E")
    static let card3 = Color(hex: "2C2C2E")
    static let cardDeep = Color(hex: "121214")
    static let control = Color(hex: "3A3A3C")
    static let line = Color.white.opacity(0.06)
    static let green = Color(hex: "30D158")
    static let yellow = Color(hex: "FFD60A")
    static let orange = Color(hex: "FF9F0A")
    static let red = Color(hex: "FF453A")
    static let purple = Color(hex: "BF5AF2")
    static let pink = Color(hex: "FF6482")
    static let lightBlue = Color(hex: "64A8FF")

    /// Цвет по имени из настроек (orange, green, blue, purple, pink, none).
    static func named(_ name: String) -> Color? {
        switch name {
        case "orange": return orange
        case "green": return green
        case "blue": return accent
        case "purple": return purple
        case "pink": return pink
        default: return nil
        }
    }
}

// MARK: - Сегментированный переключатель

struct MHSegmented<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                Button {
                    selection = opt.0
                } label: {
                    Text(opt.1)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .foregroundStyle(selection == opt.0 ? MH.t1 : MH.t2)
                        .background(RoundedRectangle(cornerRadius: 6).fill(selection == opt.0 ? MH.control : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(MH.card2))
    }
}

// MARK: - Карточки и строки настроек

struct MHCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(MH.cardDeep))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(MH.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder _ content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(MH.t3)
                .padding(.leading, 4)
            MHCard { content }
        }
    }
}

struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var subtitleColor: Color = MH.t3
    let trailing: Trailing

    init(_ title: String, subtitle: String? = nil, subtitleColor: Color = MH.t3, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.subtitleColor = subtitleColor
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).foregroundStyle(MH.t1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(subtitleColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
        }
    }
}

struct SettingsToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    init(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self._isOn = isOn
    }

    var body: some View {
        SettingsRow(title, subtitle: subtitle) {
            MHToggle(isOn: $isOn)
        }
    }
}

struct SettingsSegmentRow<T: Hashable>: View {
    let title: String
    var subtitle: String? = nil
    let options: [(T, String)]
    @Binding var selection: T

    init(_ title: String, subtitle: String? = nil, options: [(T, String)], selection: Binding<T>) {
        self.title = title
        self.subtitle = subtitle
        self.options = options
        self._selection = selection
    }

    var body: some View {
        SettingsRow(title, subtitle: subtitle) {
            MHSegmented(options: options, selection: $selection)
        }
    }
}

struct SettingsButtonRow: View {
    let title: String
    var subtitle: String? = nil
    let buttonTitle: String
    var destructive = false
    let action: () -> Void

    init(_ title: String, subtitle: String? = nil, buttonTitle: String, destructive: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.buttonTitle = buttonTitle
        self.destructive = destructive
        self.action = action
    }

    var body: some View {
        SettingsRow(title, subtitle: subtitle) {
            Button(buttonTitle, action: action)
                .buttonStyle(MHButtonStyle(kind: destructive ? .destructive : .normal))
        }
    }
}

// MARK: - Переключатель (как в макете)

struct MHToggle: View {
    @Binding var isOn: Bool
    var tint: Color = MH.accent

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? tint : MH.control).frame(width: 38, height: 22)
                Circle().fill(Color.white).frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                    .padding(2)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Кнопки

struct MHButtonStyle: ButtonStyle {
    enum Kind { case normal, prominent, destructive }
    var kind: Kind = .normal

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(kind == .destructive ? Color(hex: "FF6961") : (kind == .prominent ? Color.white : MH.t1))
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(kind == .destructive ? MH.red.opacity(0.16) : (kind == .prominent ? MH.accent : MH.card3))
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

struct MHIconButton: View {
    let systemName: String
    var help: String = ""
    var size: CGFloat = 30
    var active = false
    let action: () -> Void

    init(_ systemName: String, help: String = "", size: CGFloat = 30, active: Bool = false, action: @escaping () -> Void) {
        self.systemName = systemName
        self.help = help
        self.size = size
        self.active = active
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.43, weight: .medium))
                .frame(width: size, height: size)
                .foregroundStyle(active ? MH.accent : MH.t1)
                .background(RoundedRectangle(cornerRadius: 8).fill(MH.card2))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Поиск, пустое состояние

struct MHSearchField: View {
    @Binding var text: String
    var placeholder: String = "Поиск"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(MH.t3)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(MH.t1)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(MH.t3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9).fill(MH.card))
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    var subtitle: String = ""

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 26, weight: .light)).foregroundStyle(MH.t3)
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(MH.t1)
            if !subtitle.isEmpty {
                Text(subtitle).font(.system(size: 12)).foregroundStyle(MH.t3).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Цветная «плашка» статуса: ● Занят.
struct StatusPill: View {
    let text: String
    let color: Color
    var pulse = false
    @State private var dim = false

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6).opacity(pulse && dim ? 0.35 : 1)
            Text(text).font(.system(size: 11))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(Capsule().fill(color.opacity(0.14)))
        .onAppear {
            guard pulse else { return }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { dim = true }
        }
    }
}

/// Полоска прогресса (0…1).
struct MHBar: View {
    let value: Double
    var color: Color = MH.accent
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(MH.card3)
                Capsule().fill(color).frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: height)
    }
}

// MARK: - Подпись в шапке панели

/// Вкладка может показать короткий текст справа в шапке панели: `.panelMeta("56 снимков")`.
struct PanelMetaKey: PreferenceKey {
    static var defaultValue: String = ""
    static func reduce(value: inout String, nextValue: () -> String) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}

extension View {
    func panelMeta(_ text: String) -> some View { preference(key: PanelMetaKey.self, value: text) }
}
