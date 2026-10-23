import SwiftUI

/// Вкладка «Не спать» в чёлке (как в макете и в Vorssaint).
struct AwakeTabView: View {
    @ObservedObject private var awake = AwakeController.shared
    @ObservedObject private var prefs = Prefs.shared
    @State private var helperInstalled = PrivilegedHelper.isInstalled
    @State private var helperError: String?

    private let chips: [(AwakeDuration, String)] = [
        (.minutes(15), "15 мин"), (.minutes(30), "30 мин"), (.minutes(60), "1 ч"), (.minutes(120), "2 ч"),
        (.minutes(240), "4 ч"), (.minutes(480), "8 ч"), (.indefinite, "∞"), (.until, "До…")
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            mainCard
            optionsCard
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .panelMeta(awake.isEnabled ? (awake.isActive ? "активно" : "на паузе") : "выключено")
    }

    // MARK: Левая карточка: включение и длительность

    private var mainCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Не давать Mac уснуть").font(.system(size: 15, weight: .semibold))
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(awake.statusText)
                            .font(.system(size: 12))
                            .foregroundStyle(awake.pause != nil ? MH.orange : MH.t2)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 4)
                MHToggle(isOn: Binding(
                    get: { awake.isEnabled },
                    set: { on in
                        if on { awake.activate(.fromDefault(prefs.awakeDefaultMinutes)) } else { awake.deactivate() }
                    }
                ))
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                    let on = awake.isEnabled && awake.selected == chip.0
                    Button {
                        awake.chipTapped(chip.0)
                    } label: {
                        Text(chip.0 == .until ? awake.untilLabel() : chip.1)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .foregroundStyle(on ? Color.white : MH.t1)
                            .background(Capsule().fill(on ? MH.accent : MH.card2))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                Text("Время для «До…»").font(.system(size: 12)).foregroundStyle(MH.t2)
                DatePicker("", selection: $awake.untilTime, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.stepperField)
                    .labelsHidden()
                    .fixedSize()
                Spacer(minLength: 0)
            }

            Text("Нажмите на время, чтобы начать. Повторное нажатие — остановить.")
                .font(.system(size: 11)).foregroundStyle(MH.t3)

            Spacer(minLength: 0)

            if awake.pause == .battery {
                Text("Заряд \(awake.batteryPercent ?? 0)% ниже порога \(prefs.batteryThreshold)%. Режим приостановлен: подключите питание или снизьте порог.")
                    .font(.system(size: 12)).foregroundStyle(MH.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let pct = awake.batteryPercent {
                Text("Батарея: \(pct)% · \(awake.onAC ? "от сети" : "от батареи")")
                    .font(.system(size: 12)).foregroundStyle(MH.t2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(MH.cardDeep))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(MH.line, lineWidth: 1))
    }

    // MARK: Правая карточка: крышка, дисплей, порог

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Работать с закрытой крышкой").font(.system(size: 13))
                    Text("Mac не спит, а экран под крышкой гаснет. Следите за питанием")
                        .font(.system(size: 11)).foregroundStyle(MH.t3)
                }
                Spacer(minLength: 4)
                MHToggle(isOn: $prefs.clamshell)
            }
            .padding(.vertical, 8)

            if prefs.clamshell && !helperInstalled {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Нужно разрешение администратора — пароль спросят один раз.")
                        .font(.system(size: 11)).foregroundStyle(MH.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Разрешить (один раз ввести пароль)") { installHelper() }
                        .buttonStyle(MHButtonStyle(kind: .prominent))
                    if let helperError {
                        Text(helperError).font(.system(size: 11)).foregroundStyle(MH.orange)
                    }
                }
                .padding(.bottom, 8)
            } else if let err = awake.clamshellError, prefs.clamshell {
                Text(err).font(.system(size: 11)).foregroundStyle(MH.orange).padding(.bottom, 6)
            }

            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)

            HStack(spacing: 12) {
                Text("Разрешить дисплею выключаться").font(.system(size: 13))
                Spacer(minLength: 4)
                MHToggle(isOn: $prefs.allowDisplaySleep)
            }
            .padding(.vertical, 8)

            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Выключать при заряде ниже").font(.system(size: 13))
                    Spacer()
                    Text("\(prefs.batteryThreshold)%").font(.system(size: 13, weight: .semibold))
                }
                Slider(value: Binding(
                    get: { Double(prefs.batteryThreshold) },
                    set: { prefs.batteryThreshold = Int($0.rounded()) }
                ), in: 5...50, step: 5)
                .tint(MH.accent)
            }
            .padding(.vertical, 8)

            Spacer(minLength: 0)

            Button {
                AppModel.shared.tab = .settings
            } label: {
                HStack(spacing: 4) {
                    Text("Автоматизация, значок и остальное — в настройках")
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 11)).foregroundStyle(MH.t3)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(MH.cardDeep))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(MH.line, lineWidth: 1))
    }

    private func installHelper() {
        let r = PrivilegedHelper.install()
        helperInstalled = PrivilegedHelper.isInstalled
        helperError = r.ok ? nil : r.error
        if helperInstalled { awake.helperChanged() }
    }
}
