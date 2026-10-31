import AppKit
import SwiftUI

// Couleurs de la marque, partagées avec l'icône de l'app
enum Brand {
    static let coral = NSColor(srgbRed: 1.00, green: 0.42, blue: 0.42, alpha: 1)
    static let violet = NSColor(srgbRed: 0.46, green: 0.33, blue: 1.00, alpha: 1)
    static let green = NSColor(srgbRed: 0.30, green: 0.85, blue: 0.55, alpha: 1)
}

// MARK: - Bulle flottante en bas de l'écran pendant la dictée

final class OverlayModel: ObservableObject {
    enum Mode { case listening, transcribing, done, cancelled }
    @Published var mode: Mode = .listening
    @Published var levels: [CGFloat] = Array(repeating: 0, count: 22)
    /// Mains libres : la dictée continue sans tenir la touche
    @Published var locked = false
    @Published var start = Date()
    /// Durée de transcription estimée (s) et début de la transcription
    var estimate: Double = 1
    var transcribeStart = Date()

    /// Avance de 0 à 1 : linéaire jusqu'à 90 %, puis ralentit sans jamais finir avant le vrai résultat
    func progress(at date: Date) -> Double {
        let p = date.timeIntervalSince(transcribeStart) / estimate
        return p < 0.9 ? p : 0.9 + 0.09 * (1 - exp(-(p - 0.9) * 3))
    }

    func push(_ rms: Float) {
        // La voix tourne autour de 0,01-0,1 en RMS : on étale pour que l'onde bouge bien
        let level = CGFloat(min(1, sqrt(rms) * 3.2))
        levels.removeFirst()
        levels.append(level)
    }

    /// Niveau récent, pour faire pulser le contour
    var recentLevel: CGFloat { levels.suffix(4).max() ?? 0 }
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    private var accent: Color {
        switch model.mode {
        case .listening: return Color(Brand.coral)
        case .transcribing: return Color(Brand.violet)
        case .done: return Color(Brand.green)
        case .cancelled: return .gray
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            switch model.mode {
            case .listening:
                Circle().fill(accent).frame(width: 8, height: 8).shadow(color: accent, radius: 4)
                HStack(spacing: 3) {
                    ForEach(model.levels.indices, id: \.self) { i in
                        Capsule()
                            .fill(LinearGradient(colors: [Color(Brand.coral), Color(Brand.violet)],
                                                 startPoint: .top, endPoint: .bottom))
                            .frame(width: 3, height: 4 + model.levels[i] * 20)
                    }
                }
                .frame(height: 24)
                .animation(.easeOut(duration: 0.1), value: model.levels)
                TimelineView(.periodic(from: model.start, by: 1)) { context in
                    let s = max(0, Int(context.date.timeIntervalSince(model.start)))
                    Text(String(format: "%d:%02d", s / 60, s % 60))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                }
                if model.locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
            case .transcribing:
                Circle().fill(accent).frame(width: 8, height: 8).shadow(color: accent, radius: 4)
                Text("Transcription")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                TimelineView(.animation(minimumInterval: 1 / 20)) { context in
                    let p = model.progress(at: context.date)
                    HStack(spacing: 8) {
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.15))
                            Capsule()
                                .fill(LinearGradient(colors: [Color(Brand.coral), Color(Brand.violet)],
                                                     startPoint: .leading, endPoint: .trailing))
                                .frame(width: 110 * p)
                        }
                        .frame(width: 110, height: 5)
                        Text("\(Int(p * 100)) %")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 32, alignment: .trailing)
                    }
                }
            case .done, .cancelled:
                Image(systemName: model.mode == .done ? "checkmark" : "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(accent)
                Text(model.mode == .done ? "Collé" : "Annulé")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(Capsule().fill(.black.opacity(0.85)))
        // Contour coloré qui pulse avec la voix : la bulle reste repérable même sur un fond sombre
        .overlay(Capsule().strokeBorder(accent.opacity(model.mode == .listening ? 0.35 + model.recentLevel * 0.6 : 0.5),
                                        lineWidth: 1.5))
        .animation(.easeOut(duration: 0.15), value: model.recentLevel)
        .fixedSize()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

final class OverlayPanel {
    let model = OverlayModel()
    private var panel: NSPanel?
    private let size = NSSize(width: 320, height: 56)
    private var hideToken = 0

    /// Une fenêtre neuve à chaque dictée : une fenêtre gardée longtemps peut rester accrochée
    /// à un ancien bureau et ne plus apparaître sur une app en plein écran
    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Niveau des menus déroulants : au-dessus des fenêtres « toujours devant » de certaines apps
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        // Dictée n'est jamais l'app active : sans ça, la bulle peut être masquée d'office
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: OverlayView(model: model))
        return panel
    }

    func show(_ mode: OverlayModel.Mode) {
        hideToken += 1
        if mode == .transcribing { model.transcribeStart = Date() }
        if mode == .listening {
            model.levels = model.levels.map { _ in 0 }
            model.locked = false
            model.start = Date()
        }
        model.mode = mode
        if mode == .listening || panel == nil {
            panel?.orderOut(nil)
            panel = makePanel()
        }
        guard let panel else { return }
        // Sur l'écran où se trouve la souris
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let f = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + 20))
        panel.orderFrontRegardless()
        if mode == .listening { log("Bulle affichée sur \(screen.localizedName), visible : \(panel.isVisible)") }
    }

    /// Affiche brièvement ✓ ou ✕, puis cache la bulle
    func flash(_ mode: OverlayModel.Mode) {
        show(mode)
        let token = hideToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            if self?.hideToken == token { self?.hide() }
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }
}
