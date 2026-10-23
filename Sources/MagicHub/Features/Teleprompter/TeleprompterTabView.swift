import SwiftUI
import Combine

/// Движок прокрутки телесуфлёра: отсчёт 3-2-1 и плавное движение текста вверх.
private final class TeleprompterEngine: ObservableObject {
    @Published var offset: CGFloat = 0
    @Published var countdown: Int?
    @Published var playing = false
    @Published var ended = false

    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0

    /// Идёт отсчёт или прокрутка — панель не должна сворачиваться.
    var running: Bool { playing || countdown != nil }

    private var scrollTimer: Timer?
    private var countdownTimer: Timer?
    private var lastTick: Date?

    deinit {
        scrollTimer?.invalidate()
        countdownTimer?.invalidate()
    }

    /// Пуск: с начала — с отсчётом, с середины — сразу.
    func play() {
        if ended { restart(); return }
        if offset <= 0.5 {
            startCountdown()
        } else {
            startScrolling()
        }
    }

    func pause() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdown = nil
        scrollTimer?.invalidate()
        scrollTimer = nil
        lastTick = nil
        playing = false
    }

    func toggle() {
        if running { pause() } else { play() }
    }

    func restart() {
        pause()
        offset = 0
        ended = false
        startCountdown()
    }

    func reset() {
        pause()
        offset = 0
        ended = false
    }

    private func startCountdown() {
        countdownTimer?.invalidate()
        countdown = 3
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let next = (self.countdown ?? 1) - 1
            if next <= 0 {
                timer.invalidate()
                self.countdownTimer = nil
                self.countdown = nil
                self.startScrolling()
            } else {
                self.countdown = next
            }
        }
        RunLoop.main.add(t, forMode: .common)
        countdownTimer = t
    }

    private func startScrolling() {
        scrollTimer?.invalidate()
        playing = true
        ended = false
        lastTick = Date()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        scrollTimer = t
    }

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick ?? now)
        lastTick = now
        let speed = 30.0 * max(0.5, min(3.0, Prefs.shared.tpSpeed))
        offset += CGFloat(speed * dt)
        // Текст начинается на 35% высоты окна; закончился — когда целиком ушёл вверх.
        let limit = contentHeight + viewportHeight * 0.35
        if contentHeight > 0 && offset >= limit {
            offset = limit
            pause()
            ended = true
        }
    }
}

private struct TeleprompterHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Вкладка «Телесуфлёр»: текст плывёт прямо под камерой.
struct TeleprompterTabView: View {
    @ObservedObject private var prefs = Prefs.shared
    @StateObject private var engine = TeleprompterEngine()
    @State private var editing = false

    var body: some View {
        Group {
            if editing {
                editor
            } else {
                player
            }
        }
        .panelMeta("текст под камерой")
        .onChange(of: engine.running) { _, running in
            AppModel.shared.pinnedOpen = running
        }
        .onDisappear {
            engine.pause()
            AppModel.shared.pinnedOpen = false
        }
    }

    // MARK: Правка

    private var editor: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $prefs.tpText)
                    .font(.system(size: 14))
                    .foregroundStyle(MH.t1)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                if prefs.tpText.isEmpty {
                    Text("Вставьте сюда сценарий")
                        .font(.system(size: 14))
                        .foregroundStyle(MH.t3)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(MH.card))

            HStack {
                Text("\(prefs.tpText.count) знаков")
                    .font(.system(size: 11))
                    .foregroundStyle(MH.t3)
                Spacer()
                Button("Готово") {
                    engine.reset()
                    editing = false
                }
                .buttonStyle(MHButtonStyle(kind: .prominent))
            }
        }
    }

    // MARK: Показ

    private var player: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .top) {
                    Text(prefs.tpText.isEmpty ? "Нажмите карандаш и вставьте сценарий" : prefs.tpText)
                        .font(.system(size: CGFloat(prefs.tpFontSize), weight: .semibold))
                        .foregroundStyle(prefs.tpText.isEmpty ? MH.t3 : MH.t1)
                        .lineSpacing(CGFloat(prefs.tpFontSize) * 0.25)
                        .multilineTextAlignment(.leading)
                        .frame(width: max(0, geo.size.width - 56), alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(
                            GeometryReader { g in
                                Color.clear.preference(key: TeleprompterHeightKey.self, value: g.size.height)
                            }
                        )
                        .offset(y: geo.size.height * 0.35 - engine.offset)

                    if let c = engine.countdown {
                        Text("\(c)")
                            .font(.system(size: 76, weight: .bold))
                            .foregroundStyle(MH.t1)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.black.opacity(0.55))
                            .transition(.opacity)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .clipped()
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.16),
                            .init(color: .black, location: 0.84),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .onPreferenceChange(TeleprompterHeightKey.self) { h in
                    engine.contentHeight = h
                }
                .onAppear { engine.viewportHeight = geo.size.height }
                .onChange(of: geo.size.height) { _, h in engine.viewportHeight = h }
            }

            controls
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            TeleprompterRoundButton(systemName: "arrow.counterclockwise", filled: false, label: "Сначала") {
                engine.restart()
            }
            TeleprompterRoundButton(systemName: engine.running ? "pause.fill" : "play.fill", filled: true, label: engine.running ? "Пауза" : "Пуск") {
                engine.toggle()
            }
            Slider(value: $prefs.tpSpeed, in: 0.5...3.0, step: 0.1)
                .frame(width: 140)
                .tint(MH.accent)
                .controlSize(.small)
            Text(String(format: "%.1f×", prefs.tpSpeed))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(MH.t2)
                .frame(width: 36, alignment: .leading)
            Spacer(minLength: 0)
            TeleprompterSquareButton(title: "A−", fontSize: 11, label: "Шрифт меньше") {
                prefs.tpFontSize = max(18, prefs.tpFontSize - 4)
            }
            TeleprompterSquareButton(title: "A+", fontSize: 15, label: "Шрифт больше") {
                prefs.tpFontSize = min(56, prefs.tpFontSize + 4)
            }
            MHIconButton("pencil", help: "Изменить сценарий") {
                engine.pause()
                editing = true
            }
        }
        .frame(height: 34)
        .padding(.horizontal, 6)
    }
}

private struct TeleprompterRoundButton: View {
    let systemName: String
    let filled: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(filled ? Color.black : MH.t1)
                .frame(width: 32, height: 32)
                .background(Circle().fill(filled ? MH.t1 : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct TeleprompterSquareButton: View {
    let title: String
    let fontSize: CGFloat
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(MH.t1)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(MH.card2))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
