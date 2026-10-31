import AppKit
import SwiftUI

// MARK: - Panneau ouvert depuis l'icône de la barre de menu

final class MenuModel: ObservableObject {
    enum Status: Equatable { case loading(String), ready, recording(handsFree: Bool), transcribing, error(String) }
    enum Page { case home, history, settings }
    struct Entry { let text: String; let date: Date? }
    struct Day { let date: Date; let words: Int }

    @Published var page: Page = .home
    @Published var status: Status = .loading("Démarrage…")
    @Published var hotkey: Hotkey = .option
    @Published var autoLanguage = false
    @Published var launchAtLogin = false
    @Published var axOK = true
    @Published var micOK = true
    @Published var history: [Entry] = []
    @Published var week: [Day] = []
    @Published var todayWords = 0
    @Published var totalWords = 0
    @Published var minutesSaved = 0
    @Published var version = ""
    /// Version disponible sur GitHub, nil si l'app est à jour
    @Published var updateVersion: String?
    @Published var checking = false
    @Published var checkFailed = false
    /// Vrai quelques secondes après une vérification manuelle réussie
    @Published var confirmedUpToDate = false
    /// Ligne d'historique survolée / tout juste copiée (index)
    @Published var hoveredRow: Int?
    @Published var copiedRow: Int?

    var chooseHotkey: (Hotkey) -> Void = { _ in }
    var toggleLanguage: () -> Void = {}
    var toggleLogin: () -> Void = {}
    var update: () -> Void = {}
    var openAccessibility: () -> Void = {}
    var openMicrophone: () -> Void = {}

    var isActive: Bool {
        switch status { case .recording, .transcribing: return true; default: return false }
    }
}

private let coral = Color(Brand.coral)
private let violet = Color(Brand.violet)
/// Violet des textes cliquables : éclairci en mode sombre pour rester bien lisible
private let linkColor = Color(NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.72, green: 0.66, blue: 1.00, alpha: 1)
        : Brand.violet
})
private let gradient = LinearGradient(colors: [coral, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
/// Dictées montrées sur l'accueil ; les autres sont dans la page Historique
private let homeRows = 3

struct MenuView: View {
    @ObservedObject var model: MenuModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.page {
            case .home: home
            case .history: historyPage
            case .settings: settingsPage
            }
        }
        .padding(14)
        .frame(width: 330)
    }

    // MARK: - Accueil

    @ViewBuilder private var home: some View {
        hero
        if let version = model.updateVersion { updateBanner(version) }
        if !model.axOK { banner("Autorise l'accessibilité pour coller le texte", action: model.openAccessibility) }
        if !model.micOK { banner("Autorise le micro pour dicter", action: model.openMicrophone) }

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle("Récent")
                Spacer()
                if model.history.count > homeRows {
                    LinkButton("Tout voir (\(model.history.count))") { model.page = .history }
                }
            }
            historyList(Array(model.history.prefix(homeRows)))
        }
        statsCard
        shortcuts
        Divider().padding(.horizontal, 4)
        footer
    }

    /// En-tête : halo de la marque + onde qui s'anime pendant la dictée
    private var hero: some View {
        HStack(spacing: 12) {
            LiveWave(active: model.isActive)
            VStack(alignment: .leading, spacing: 3) {
                Text("Dictée").font(.system(size: 17, weight: .bold, design: .rounded))
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                        .shadow(color: statusColor.opacity(0.8), radius: 3)
                    Text(statusText).lineLimit(1)
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            IconButton(symbol: "gearshape.fill", help: "Réglages") { model.page = .settings }
        }
        .padding(12)
        .background(Aurora())
    }

    private var statusColor: Color {
        switch model.status {
        case .loading: return .secondary
        case .ready: return Color(Brand.green)
        case .recording: return coral
        case .transcribing: return violet
        case .error: return .orange
        }
    }

    private var statusText: String {
        switch model.status {
        case .loading(let msg), .error(let msg): return msg
        case .ready: return "Prêt à t'écouter"
        case .recording(let free): return free ? "J'écoute · mains libres" : "J'écoute…"
        case .transcribing: return "Transcription…"
        }
    }

    private func updateBanner(_ version: String) -> some View {
        Button(action: model.update) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                Text("Dictée \(version) est disponible").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("Télécharger").font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(.white.opacity(0.25)))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(gradient))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHand()
    }

    private func banner(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(text).font(.system(size: 12, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.14)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHand()
    }

    // MARK: Statistiques + semaine

    private var statsCard: some View {
        HStack(alignment: .bottom, spacing: 14) {
            Metric(value: model.todayWords.formatted(), label: "mots aujourd'hui")
            Metric(value: saved, label: "gagnées")
            Spacer(minLength: 0)
            WeekChart(days: model.week)
        }
        .padding(12)
        .background(Card())
        .help("\(model.totalWords.formatted()) mots dictés au total")
    }

    private var saved: String {
        let m = model.minutesSaved
        return m >= 60 ? "\(m / 60) h \(String(format: "%02d", m % 60))" : "\(m) min"
    }

    // MARK: Les trois gestes

    private var shortcuts: some View {
        HStack(spacing: 0) {
            gesture([model.hotkey.shortKeycap], "maintenir")
            Spacer(minLength: 6)
            gesture([model.hotkey.shortKeycap, model.hotkey.shortKeycap], "mains libres")
            Spacer(minLength: 6)
            gesture(["esc"], "annuler")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private func gesture(_ keys: [String], _ label: String) -> some View {
        HStack(spacing: 5) {
            HStack(spacing: 2) { ForEach(Array(keys.enumerated()), id: \.offset) { Keycap($0.element) } }
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
        }
    }

    private var footer: some View {
        HStack {
            Button(action: model.update) {
                if model.checking {
                    HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Vérification…") }
                } else if model.confirmedUpToDate {
                    Label("Tu as la dernière version (\(model.version))", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color(Brand.green))
                } else if model.checkFailed {
                    Label("Vérification impossible (internet ?)", systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.orange)
                } else {
                    Text(model.updateVersion != nil ? "Version \(model.version)"
                         : "Version \(model.version) · vérifier les mises à jour")
                }
            }
            .help("Cliquer pour vérifier les mises à jour")
            .pointingHand()
            Spacer()
            Button("Quitter") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
                .pointingHand()
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
    }

    // MARK: - Historique

    @ViewBuilder private var historyPage: some View {
        PageHeader(title: "Historique", subtitle: "\(model.history.count) dernières dictées · clic pour copier") {
            model.page = .home
        }
        // Au-delà de 6 dictées, la liste défile dans une hauteur fixe (sinon le panneau la réduirait à rien)
        if model.history.count > 6 {
            ScrollView { historyList(model.history) }.frame(height: 400)
        } else {
            historyList(model.history)
        }
    }

    private func historyList(_ entries: [MenuModel.Entry]) -> some View {
        VStack(spacing: 0) {
            if entries.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "waveform").foregroundStyle(gradient)
                    Text("Maintiens \(model.hotkey.shortKeycap) et parle : tes dictées apparaîtront ici.")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            } else {
                ForEach(Array(entries.enumerated()), id: \.offset) { i, entry in
                    if i > 0 { Divider().padding(.leading, 14).padding(.trailing, 10) }
                    HistoryRow(model: model, index: i, entry: entry)
                }
            }
        }
        .padding(4)
        .background(Card())
    }

    // MARK: - Réglages

    @ViewBuilder private var settingsPage: some View {
        PageHeader(title: "Réglages", subtitle: nil) { model.page = .home }
        VStack(spacing: 0) {
            row("Langue", "Ou détection auto") {
                Picker("", selection: Binding(get: { model.autoLanguage },
                                              set: { if $0 != model.autoLanguage { model.toggleLanguage() } })) {
                    Text("Français").tag(false)
                    Text("Auto").tag(true)
                }
                .pickerStyle(.segmented).frame(width: 116)
            }
            Divider().padding(.horizontal, 12)
            row("Raccourci", "Touche à maintenir") {
                Picker("", selection: Binding(get: { model.hotkey }, set: { model.chooseHotkey($0) })) {
                    ForEach(Hotkey.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .frame(width: 120)
            }
            Divider().padding(.horizontal, 12)
            row("Lancer au démarrage", "S'ouvre avec ton Mac") {
                Toggle("", isOn: Binding(get: { model.launchAtLogin }, set: { _ in model.toggleLogin() }))
                    .toggleStyle(.switch)
            }
        }
        .controlSize(.small)
        .labelsHidden()
        .background(Card())

        VStack(spacing: 0) {
            row("Version \(model.version)",
                model.checking ? "Vérification…"
                : model.confirmedUpToDate ? "✓ C'est bon, tu es à jour"
                : model.checkFailed ? "Vérification impossible (internet ?)"
                : model.updateVersion.map { "La version \($0) est disponible" } ?? "Tu as la dernière version") {
                Button(model.updateVersion != nil ? "Télécharger" : "Vérifier", action: model.update)
            }
        }
        .controlSize(.small)
        .background(Card())
    }

    private func row<Content: View>(_ title: String, _ detail: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .layoutPriority(1)
            Spacer(minLength: 8)
            content().fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}

// MARK: - Composants

extension View {
    /// Curseur en forme de main au survol, comme sur un lien
    func pointingHand() -> some View {
        onContinuousHover { phase in
            switch phase {
            case .active: NSCursor.pointingHand.set()
            case .ended: NSCursor.arrow.set()
            }
        }
    }
}

/// Fond de carte : blanc franc et ombre douce en clair, verre léger en sombre
private struct Card: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        if scheme == .dark {
            shape.fill(Color.white.opacity(0.06))
                .overlay(shape.strokeBorder(Color.white.opacity(0.08)))
        } else {
            shape.fill(Color.white)
                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                .overlay(shape.strokeBorder(Color.black.opacity(0.06)))
        }
    }
}

/// Fond de l'en-tête : la carte, traversée par deux halos corail et violet
private struct Aurora: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let strength = scheme == .dark ? 0.35 : 0.22
        ZStack {
            Card()
            RadialGradient(colors: [coral.opacity(strength), .clear], center: .topLeading, startRadius: 0, endRadius: 190)
            RadialGradient(colors: [violet.opacity(strength), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 220)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(gradient.opacity(0.35), lineWidth: 1))
    }
}

/// Icône de l'app : cinq barres d'onde, qui dansent quand on dicte
private struct LiveWave: View {
    let active: Bool
    private let rest: [CGFloat] = [0.35, 0.65, 1, 0.65, 0.35]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    let h = active ? 0.3 + 0.7 * abs(sin(t * 5 + Double(i) * 0.9)) : rest[i]
                    Capsule().fill(.white).frame(width: 3.5, height: 22 * h)
                }
            }
        }
        .frame(width: 44, height: 44)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(gradient))
        .shadow(color: violet.opacity(0.45), radius: 8, y: 3)
    }
}

private struct WeekChart: View {
    let days: [MenuModel.Day]
    private let initials = ["D", "L", "M", "M", "J", "V", "S"]

    var body: some View {
        let top = max(days.map(\.words).max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                let isToday = i == days.count - 1
                VStack(spacing: 4) {
                    Capsule()
                        .fill(isToday ? AnyShapeStyle(gradient) : AnyShapeStyle(Color.primary.opacity(0.15)))
                        .frame(width: 7, height: max(3, 30 * CGFloat(day.words) / CGFloat(top)))
                    Text(initials[Calendar.current.component(.weekday, from: day.date) - 1])
                        .font(.system(size: 8.5, weight: isToday ? .bold : .medium))
                        .foregroundStyle(isToday ? .primary : .secondary)
                }
            }
        }
        .help("Mots dictés ces 7 derniers jours")
    }
}

private struct Metric: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(gradient)
                .lineLimit(1).fixedSize()
            Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary).fixedSize()
        }
    }
}

private struct PageHeader: View {
    let title: String
    let subtitle: String?
    let back: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            IconButton(symbol: "chevron.left", help: "Retour", action: back)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 15, weight: .bold, design: .rounded))
                if let subtitle { Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary) }
            }
            Spacer()
        }
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 6)
    }
}

private struct LinkButton: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Text(title)
                Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold))
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(linkColor)
        }
        .buttonStyle(.plain)
        .pointingHand()
        .padding(.trailing, 6)
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pointingHand()
        .help(help)
    }
}

private struct Keycap: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary.opacity(0.75))
            .fixedSize()
            .padding(.horizontal, 5).frame(minWidth: 19, minHeight: 19)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.18)))
    }
}

private struct HistoryRow: View {
    @ObservedObject var model: MenuModel
    let index: Int
    let entry: MenuModel.Entry

    var body: some View {
        let hover = model.hoveredRow == index
        let copied = model.copiedRow == index
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.text, forType: .string)
            model.copiedRow = index
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if model.copiedRow == index { model.copiedRow = nil }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(entry.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ZStack(alignment: .trailing) {
                    Text(entry.date.map(relative) ?? "").opacity(hover || copied ? 0 : 1)
                    Label(copied ? "Copié" : "Copier", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(copied ? Color(Brand.green) : linkColor)
                        .opacity(hover || copied ? 1 : 0)
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(minWidth: 58, alignment: .trailing)
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(violet.opacity(hover ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { model.hoveredRow = index } else if model.hoveredRow == index { model.hoveredRow = nil }
        }
        .pointingHand()
    }

    private func relative(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "à l'instant" }
        if s < 3600 { return "il y a \(s / 60) min" }
        if s < 86_400 { return "il y a \(s / 3600) h" }
        return s < 172_800 ? "hier" : "il y a \(s / 86_400) j"
    }
}

extension Hotkey {
    /// Libellé court affiché comme une touche de clavier
    var shortKeycap: String {
        switch self {
        case .option, .rightOption, .leftOption: return "⌥"
        case .rightCommand: return "⌘"
        case .control: return "⌃"
        case .fn: return "fn"
        }
    }
}
