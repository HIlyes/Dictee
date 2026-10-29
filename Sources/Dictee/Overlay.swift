import AppKit
import SwiftUI

// Couleurs de la marque, partagées avec l'icône de l'app
enum Brand {
    static let coral = NSColor(srgbRed: 1.00, green: 0.42, blue: 0.42, alpha: 1)
    static let violet = NSColor(srgbRed: 0.46, green: 0.33, blue: 1.00, alpha: 1)
}

// MARK: - Bulle flottante en bas de l'écran pendant la dictée

final class OverlayModel: ObservableObject {
    enum Mode { case listening, transcribing }
    @Published var mode: Mode = .listening
    @Published var levels: [CGFloat] = Array(repeating: 0, count: 22)

    func push(_ rms: Float) {
        // La voix tourne autour de 0,01-0,1 en RMS : on étale pour que l'onde bouge bien
        let level = CGFloat(min(1, sqrt(rms) * 3.2))
        levels.removeFirst()
        levels.append(level)
    }
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(model.mode == .listening ? Brand.coral : Brand.violet))
                .frame(width: 8, height: 8)
                .shadow(color: Color(model.mode == .listening ? Brand.coral : Brand.violet), radius: 4)

            if model.mode == .listening {
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
            } else {
                Text("Transcription…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                ProgressView().controlSize(.small).tint(.white)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(Capsule().fill(.black.opacity(0.82)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .fixedSize()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

final class OverlayPanel {
    let model = OverlayModel()
    private let panel: NSPanel
    private let size = NSSize(width: 260, height: 56)

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: OverlayView(model: model))
    }

    func show(_ mode: OverlayModel.Mode) {
        if mode == .listening { model.levels = model.levels.map { _ in 0 } }
        model.mode = mode
        // Sur l'écran où se trouve la souris
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let f = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + 20))
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}
