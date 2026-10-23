import SwiftUI

/// Корневой вид окна чёлки: чёрная форма, которая растёт из выреза.
struct NotchRootView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject private var app = AppModel.shared
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var music = NowPlayingModel.shared
    @ObservedObject private var awake = AwakeController.shared
    @ObservedObject private var jarvis = JarvisMonitor.shared
    @ObservedObject private var hud = HUDModel.shared

    var body: some View {
        let mode = model.mode
        let g = model.geometry
        let size = g.size(for: mode)
        let radius = g.cornerRadius(for: mode)
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous)

        ZStack(alignment: .top) {
            shape
                .fill(Color.black)
                .frame(width: size.width, height: size.height)
                .shadow(color: .black.opacity(mode == .open ? 0.55 : (mode == .notif ? 0.35 : 0)), radius: 22, y: 10)

            ZStack(alignment: .top) {
                switch mode {
                case .open:
                    PanelView(model: model)
                        .frame(width: g.openSize.width, height: g.openSize.height, alignment: .top)
                        .transition(.opacity.animation(.easeOut(duration: 0.12).delay(0.03)))
                case .notif:
                    if let n = app.notification {
                        NotificationContent(notification: n)
                            .frame(width: g.notifSize.width, height: g.notifSize.height, alignment: .bottom)
                            .transition(.opacity)
                    }
                case .live:
                    LiveContent()
                        .frame(width: g.liveSize.width, height: g.liveSize.height)
                        .transition(.opacity)
                case .hud:
                    HUDContent(cutout: g.isCutout, notchWidth: g.notchSize.width)
                        .frame(width: g.hudSize.width, height: g.hudSize.height, alignment: g.isCutout ? .center : .bottom)
                        .transition(.opacity)
                case .idle:
                    Color.clear.frame(width: 1, height: 1)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipShape(shape)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.22, dampingFraction: 0.86), value: mode)
        .animation(.spring(response: 0.22, dampingFraction: 0.86), value: g)
        .environment(\.colorScheme, .dark)
    }
}

/// Свёрнутая чёлка с «живыми» значками: музыка, Джарвис, «Не спать».
private struct LiveContent: View {
    @ObservedObject private var music = NowPlayingModel.shared
    @ObservedObject private var awake = AwakeController.shared
    @ObservedObject private var jarvis = JarvisMonitor.shared

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                if music.isPlaying {
                    Group {
                        if let art = music.artwork {
                            Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "music.note").font(.system(size: 9)).foregroundStyle(MH.t1)
                                .frame(maxWidth: .infinity, maxHeight: .infinity).background(MH.purple.opacity(0.6))
                        }
                    }
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                if jarvis.isBusy {
                    PulsingDot(color: MH.yellow)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if awake.isActive {
                    Image(systemName: "moon.zzz.fill").font(.system(size: 10)).foregroundStyle(MH.t2)
                }
                if music.isPlaying {
                    EqualizerBars()
                }
            }
        }
        .padding(.horizontal, 12)
    }
}

struct PulsingDot: View {
    let color: Color
    @State private var dim = false

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

/// Три полоски эквалайзера, пока играет музыка.
struct EqualizerBars: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.18)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    let h = 3 + 9 * abs(sin(t * 3.1 + Double(i) * 1.3))
                    Capsule().fill(MH.t1).frame(width: 3, height: h)
                        .animation(.easeInOut(duration: 0.18), value: h)
                }
            }
            .frame(height: 12, alignment: .bottom)
        }
    }
}

/// Плашка уведомления, выехавшая из чёлки.
private struct NotificationContent: View {
    let notification: NotchNotification

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: notification.icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(notification.color)
                .frame(width: 38, height: 38)
                .background(Circle().fill(MH.card2))
            VStack(alignment: .leading, spacing: 2) {
                Text(notification.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(MH.t1).lineLimit(1)
                if !notification.subtitle.isEmpty {
                    Text(notification.subtitle).font(.system(size: 12)).foregroundStyle(MH.t2).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Group {
                switch notification.kind {
                case .progress:
                    ProgressView().controlSize(.small).tint(notification.color)
                case .success:
                    Image(systemName: "checkmark").font(.system(size: 18, weight: .semibold))
                case .warning, .error:
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 18))
                case .info:
                    Image(systemName: "arrow.clockwise").font(.system(size: 18))
                }
            }
            .foregroundStyle(notification.color)
        }
        .padding(.horizontal, 18)
        .frame(height: 62)
        .contentShape(Rectangle())
        .onTapGesture {
            if let tap = notification.onTap { tap() } else { AppModel.shared.open(.ai) }
        }
    }
}

/// Раскрытая панель: шапка, колонки вкладок, содержимое.
struct PanelView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject private var app = AppModel.shared
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var prefs = Prefs.shared
    @State private var meta = ""

    var body: some View {
        let g = model.geometry
        let s = g.panelScale
        let innerW = g.baseOpenSize.width
        let innerH = g.baseOpenSize.height - g.headerTop
        // Панель всегда раскладывается в полном размере, а затем целиком уменьшается:
        // так при любом масштабе ничего не перестраивается и не наезжает друг на друга.
        VStack(spacing: 0) {
            Color.clear.frame(height: g.headerTop)
            VStack(spacing: 0) {
                header.frame(height: 18).padding(.horizontal, 20)
                Color.clear.frame(height: max(0, g.contentTop - g.headerTop - 18))
                HStack(alignment: .top, spacing: 14) {
                    rail(Tab.allCases.filter { $0.isLeft })
                    content
                        .id(app.tab)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    rail(Tab.allCases.filter { !$0.isLeft })
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
            .frame(width: innerW, height: innerH, alignment: .top)
            .scaleEffect(s, anchor: .topLeading)
            .frame(width: innerW * s, height: innerH * s, alignment: .topLeading)
        }
        .frame(width: g.openSize.width, height: g.openSize.height, alignment: .top)
        .foregroundStyle(MH.t1)
        .onPreferenceChange(PanelMetaKey.self) { meta = $0 }
        .onChange(of: app.tab) { meta = "" }
        .onAppear(perform: fixHiddenTab)
        .onChange(of: prefs.hiddenTabs) { fixHiddenTab() }
    }

    private func fixHiddenTab() {
        if !prefs.isVisible(app.tab) {
            app.tab = Tab.allCases.first(where: { prefs.isVisible($0) }) ?? .settings
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(app.tab.title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.9)
                .foregroundStyle(MH.t3)
            Spacer()
            if let toast = app.toast {
                Text(toast).font(.system(size: 11, weight: .medium)).foregroundStyle(MH.green)
                    .transition(.opacity)
            } else {
                Text(meta).font(.system(size: 11)).foregroundStyle(MH.t3).lineLimit(1)
            }
            if let update = updater.available {
                Button {
                    updater.install()
                } label: {
                    Label(updater.busy ? (updater.status ?? "Обновляю…") : "Обновить до \(update.version)",
                          systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(MH.accent)
                .disabled(updater.busy)
                .help("Скачать новую версию и перезапустить Magic Hub")
            }
            if app.pinnedOpen {
                Button {
                    app.pinnedOpen = false
                    NotchManager.shared.closeAll()
                } label: {
                    Image(systemName: "pin.slash").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(MH.t2)
                .help("Открепить и свернуть")
            }
        }
        .animation(.easeOut(duration: 0.15), value: app.toast)
    }

    private func rail(_ tabs: [Tab]) -> some View {
        VStack(spacing: 4) {
            ForEach(tabs.filter { prefs.isVisible($0) }) { t in
                Button {
                    app.tab = t
                } label: {
                    Image(systemName: t.icon)
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 36, height: 32)
                        .foregroundStyle(app.tab == t ? MH.t1 : MH.t3)
                        .background(RoundedRectangle(cornerRadius: 9).fill(app.tab == t ? Color.white.opacity(0.14) : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(t.title)
                .accessibilityLabel(t.title)
            }
        }
        .frame(width: 36)
    }

    @ViewBuilder private var content: some View {
        switch app.tab {
        case .music: MusicTabView()
        case .shelf: ShelfTabView()
        case .clipboard: ClipboardTabView()
        case .snippets: SnippetsTabView()
        case .calendar: CalendarTabView()
        case .translate: TranslateTabView()
        case .notes: NotesTabView()
        case .currency: CurrencyTabView()
        case .teleprompter: TeleprompterTabView()
        case .calculator: CalculatorTabView()
        case .ai: AITabView()
        case .awake: AwakeTabView()
        case .settings: SettingsTabView()
        }
    }
}

/// Индикатор громкости / яркости / подсветки: значок, полоска и проценты с анимацией.
private struct HUDContent: View {
    @ObservedObject private var hud = HUDModel.shared
    let cutout: Bool
    let notchWidth: CGFloat

    var body: some View {
        let e = hud.current ?? HUDEvent(kind: .volume, value: 0)
        let level = e.muted ? 0 : Double(e.value)
        let pct = Int((level * 100).rounded())
        HStack(spacing: 10) {
            Image(systemName: e.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MH.t1)
                .frame(width: 22)
                .contentTransition(.symbolEffect(.replace))
            if cutout {
                Spacer(minLength: notchWidth + 4)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.16))
                    Capsule().fill(MH.t1).frame(width: max(0, geo.size.width * level))
                }
            }
            .frame(height: 6)
            Text("\(pct)%")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(MH.t1)
                .contentTransition(.numericText(value: Double(pct)))
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, cutout ? 0 : 7)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: level)
        .animation(.easeOut(duration: 0.2), value: e.icon)
    }
}
