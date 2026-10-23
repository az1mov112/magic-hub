import SwiftUI
import ApplicationServices

/// Настройки → «Звук и яркость»: свои индикаторы в чёлке и регуляторы в одном месте.
struct HUDSettingsSection: View {
    @ObservedObject private var prefs = Prefs.shared
    @State private var volume: Double = Double(SystemVolume.get() ?? 0)
    @State private var screen: Double = Double(DisplayBrightness.get() ?? 0)
    @State private var keyboard: Double = Double(KeyboardBacklight.get() ?? 0)
    @State private var trusted = AXIsProcessTrusted()
    private let hasScreen = DisplayBrightness.get() != nil
    private let hasKeyboard = KeyboardBacklight.isAvailable

    var body: some View {
        SettingsSection("Звук и яркость") {
            SettingsToggleRow("Индикаторы громкости и яркости в чёлке",
                              subtitle: "Вместо стандартного окошка macOS — анимированная плашка с процентами",
                              isOn: $prefs.customHUD)
            if prefs.customHUD && !trusted {
                SettingsRow("Нужен «Универсальный доступ»",
                            subtitle: "Без него Magic Hub не может перехватить клавиши громкости и яркости",
                            subtitleColor: MH.orange) {
                    Button("Разрешить") {
                        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
                    }
                    .buttonStyle(MHButtonStyle(kind: .prominent))
                }
            }
            sliderRow("Громкость", icon: "speaker.wave.2.fill", value: $volume) { SystemVolume.set(Float($0)) }
            if hasScreen {
                sliderRow("Яркость экрана", icon: "sun.max.fill", value: $screen) { DisplayBrightness.set(Float($0)) }
            }
            if hasKeyboard {
                sliderRow("Подсветка клавиатуры", icon: "light.max", value: $keyboard) { KeyboardBacklight.set(Float($0)) }
            } else {
                SettingsRow("Подсветка клавиатуры", subtitle: "На этом Mac недоступна") { EmptyView() }
            }
        }
        .onAppear(perform: reload)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            trusted = AXIsProcessTrusted()
        }
    }

    private func reload() {
        volume = Double(SystemVolume.get() ?? 0)
        screen = Double(DisplayBrightness.get() ?? 0)
        keyboard = Double(KeyboardBacklight.get() ?? 0)
        trusted = AXIsProcessTrusted()
    }

    private func sliderRow(_ title: String, icon: String, value: Binding<Double>, apply: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(MH.t3).frame(width: 18)
            Text(title).font(.system(size: 13)).foregroundStyle(MH.t1).frame(width: 150, alignment: .leading)
            Slider(value: Binding(get: { value.wrappedValue }, set: { v in
                value.wrappedValue = v
                apply(v)
            }), in: 0...1)
            .tint(MH.accent)
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(MH.t2)
                .frame(width: 38, alignment: .trailing)
                .contentTransition(.numericText(value: value.wrappedValue))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1) }
    }
}
