import SwiftUI
import AppKit

/// Вкладка «Музыка»: то, что сейчас играет на Mac, из любого источника.
struct MusicTabView: View {
    @ObservedObject private var np = NowPlayingModel.shared

    var body: some View {
        Group {
            if np.hasContent {
                content
            } else {
                EmptyStateView(
                    systemImage: "music.note",
                    title: "Сейчас ничего не играет",
                    subtitle: np.available
                        ? "Включите музыку, видео или голосовое — здесь появится то, что играет на Mac"
                        : "Не удалось подключиться к системному «Сейчас играет»"
                )
            }
        }
        .panelMeta(np.sourceName)
    }

    private var content: some View {
        HStack(alignment: .center, spacing: 24) {
            // Кадр видео (YouTube, сериалы в браузере) — широкая рамка 16:9, обложка трека — квадрат.
            MusicCover(image: np.artwork)
                .frame(width: isWideArtwork ? 256 : 170, height: isWideArtwork ? 144 : 170)
                .animation(.easeInOut(duration: 0.25), value: isWideArtwork)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    if let icon = np.sourceIcon {
                        Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                    } else {
                        Circle().fill(np.isPlaying ? MH.green : MH.t3).frame(width: 6, height: 6)
                    }
                    Text(stateLine)
                        .lineLimit(1)
                }
                .font(.system(size: 12))
                .foregroundStyle(MH.t2)

                Text(np.title)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(MH.t1)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.top, 8)

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(MH.t2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.top, 4)
                }

                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let position = np.currentElapsed(at: context.date)
                    VStack(spacing: 6) {
                        MusicProgressBar(
                            fraction: np.duration > 0 ? position / np.duration : 0,
                            enabled: np.duration > 0
                        ) { fraction in
                            np.seek(to: fraction * np.duration)
                        }
                        HStack {
                            Text(Fmt.clock(position))
                            Spacer()
                            Text(np.duration > 0 ? Fmt.clock(np.duration) : "—")
                        }
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(MH.t3)
                    }
                }
                .padding(.top, 20)

                HStack(spacing: 22) {
                    MusicControlButton(systemName: "backward.fill", size: 40, filled: false, label: "Предыдущий") { np.previous() }
                    MusicControlButton(systemName: np.isPlaying ? "pause.fill" : "play.fill", size: 48, filled: true, label: np.isPlaying ? "Пауза" : "Воспроизвести") { np.togglePlayPause() }
                    MusicControlButton(systemName: "forward.fill", size: 40, filled: false, label: "Следующий") { np.next() }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.25), value: np.title)
    }

    private var isWideArtwork: Bool {
        guard let a = np.artwork, a.size.height > 0 else { return false }
        return a.size.width / a.size.height > 1.25
    }

    private var stateLine: String {
        let state = np.isPlaying ? "Сейчас играет" : "На паузе"
        return np.sourceName.isEmpty ? state : "\(state) · \(np.sourceName)"
    }

    private var subtitle: String {
        if !np.artist.isEmpty && !np.album.isEmpty { return "\(np.artist) — \(np.album)" }
        return np.artist.isEmpty ? np.album : np.artist
    }
}

private struct MusicCover: View {
    let image: NSImage?

    // Размер задаёт подложка, картинка лежит поверх и обрезается по ней:
    // иначе кадр видео 16:9 растягивал бы рамку и вылезал на соседние элементы.
    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color(hex: "3B2F5C"))
            .overlay {
                ZStack {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .id(ObjectIdentifier(image))
                            .transition(.opacity)
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: 52, weight: .light))
                            .foregroundStyle(Color.white.opacity(0.85))
                            .transition(.opacity)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(MH.line, lineWidth: 1))
            .animation(.easeInOut(duration: 0.3), value: image.map { ObjectIdentifier($0) })
    }
}

/// Полоса прогресса: клик или перетаскивание — перемотка.
private struct MusicProgressBar: View {
    let fraction: Double
    let enabled: Bool
    let onSeek: (Double) -> Void
    @State private var dragFraction: Double?

    var body: some View {
        GeometryReader { geo in
            let shown = max(0, min(1, dragFraction ?? fraction))
            ZStack(alignment: .leading) {
                Capsule().fill(MH.card3).frame(height: 4)
                Capsule().fill(MH.t1).frame(width: shown * geo.size.width, height: 4)
            }
            .frame(height: 14)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard enabled, geo.size.width > 0 else { return }
                        dragFraction = max(0, min(1, value.location.x / geo.size.width))
                    }
                    .onEnded { value in
                        guard enabled, geo.size.width > 0 else { return }
                        let f = max(0, min(1, value.location.x / geo.size.width))
                        dragFraction = nil
                        onSeek(f)
                    }
            )
        }
        .frame(height: 14)
    }
}

private struct MusicControlButton: View {
    let systemName: String
    let size: CGFloat
    let filled: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: filled ? 20 : 18, weight: .semibold))
                .foregroundStyle(filled ? Color.black : MH.t1)
                .frame(width: size, height: size)
                .background(Circle().fill(filled ? MH.t1 : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
