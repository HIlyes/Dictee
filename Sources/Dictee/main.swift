import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI
import WhisperKit

// MARK: - Enregistrement micro (16 kHz mono, format attendu par Whisper)

final class Recorder {
    // Moteur recréé à chaque dictée : après une veille ou un changement de micro
    // (AirPods…), un moteur réutilisé démarre mais ne reçoit plus aucun son
    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var samples: [Float] = []
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    /// Volume (RMS) de chaque bloc audio, appelé sur le fil principal pour animer l'onde
    var onLevel: ((Float) -> Void)?

    func start() throws {
        lock.lock(); samples.removeAll(); lock.unlock()
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(domain: "Dictee", code: 1, userInfo: [NSLocalizedDescriptionKey: "Format micro non pris en charge"])
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let ratio = self.targetFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
            guard let out = AVAudioPCMBuffer(pcmFormat: self.targetFormat, frameCapacity: capacity) else { return }
            var consumed = false
            converter.convert(to: out, error: nil) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard let data = out.floatChannelData?[0] else { return }
            let chunk = Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
            self.lock.lock(); self.samples.append(contentsOf: chunk); self.lock.unlock()
            if let onLevel = self.onLevel, !chunk.isEmpty {
                let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count))
                DispatchQueue.main.async { onLevel(rms) }
            }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() -> [Float] {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        lock.lock(); defer { lock.unlock() }
        return samples
    }
}

// MARK: - Insertion du texte dans l'app active

enum Paster {
    /// Colle le texte dans l'app active. Renvoie false si macOS bloque la frappe simulée
    /// (accessibilité non autorisée) : le texte reste alors dans le presse-papiers.
    @discardableResult
    static func paste(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)

        guard AXIsProcessTrusted() else {
            log("Collage impossible : accessibilité non autorisée, texte laissé dans le presse-papiers")
            return false
        }
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        log("Collage envoyé (⌘V) vers \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")

        // On remet l'ancien contenu du presse-papiers une fois le collage fait
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let previous else { return }
            pb.clearContents()
            pb.setString(previous, forType: .string)
        }
        return true
    }
}

// MARK: - Contexte du curseur : début de phrase ou pas ?

enum CursorContext {
    /// Le texte juste avant le curseur dans le champ actif, si l'app le donne (nil sinon)
    static func textBeforeCursor() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        var value: CFTypeRef?
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String,
              AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
              let range, CFGetTypeID(range) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        guard AXValueGetValue(range as! AXValue, .cfRange, &r) else { return nil }
        let ns = text as NSString
        let end = max(0, min(r.location, ns.length))
        let start = max(0, end - 200)
        return ns.substring(with: NSRange(location: start, length: end - start))
    }

    /// Ajuste le début de la dictée à ce qui précède : minuscule en milieu de phrase, espace si collé à un mot
    static func adapt(_ text: String, after before: String?) -> String {
        guard let before, !before.isEmpty, let first = text.first else { return text }
        var t = text
        let trimmed = before.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{00A0}")))
        let sentenceStart = trimmed.isEmpty || before.last?.isNewline == true
            || ".!?…:".contains(trimmed.last!)
        if !sentenceStart, first.isUppercase {
            // Seulement un mot ordinaire (« Je », « Bonjour ») : on garde « API », « iPhone » ou « I »
            let word = t.prefix { $0.isLetter }
            if word.count > 1, word.dropFirst().allSatisfy(\.isLowercase) {
                t = first.lowercased() + t.dropFirst()
            }
        }
        if let last = before.last, !last.isWhitespace, !"(«[{'’\"-/".contains(last), t.first?.isLetter == true || t.first?.isNumber == true {
            t = " " + t
        }
        return t
    }
}

// MARK: - Typographie française (espace insécable avant ? ! ; :)

enum FrenchTypography {
    static func apply(_ text: String) -> String {
        var t = text
        // "?", "!" et ";" : on remplace l'éventuelle espace par une insécable
        t = t.replacingOccurrences(of: #"(?<=\S)\s?([?!;]+)"#, with: "\u{00A0}$1", options: .regularExpression)
        // ":" seulement entre des mots, pour ne pas casser 14:30 ou https://
        t = t.replacingOccurrences(of: #"(?<=[\p{L}\)»])\s?:(?=\s|$)"#, with: "\u{00A0}:", options: .regularExpression)
        // Guillemets droits -> « »
        t = t.replacingOccurrences(of: #""\s*([^"]+?)\s*""#, with: "«\u{00A0}$1\u{00A0}»", options: .regularExpression)
        return t
    }
}

// MARK: - Nettoyage des tics de langage (euh, hum, mots répétés)

enum TextCleanup {
    static func apply(_ text: String) -> String {
        var t = text
        // « euh », « heu », « hum », « hmm », « um », « uh », avec la virgule ou les points qui suivent
        t = t.replacingOccurrences(of: #"(?i),?\s*\b(e+u+h+|h+e+u+|h+u+m+|h+m+|u+m+|u+h+)\b[,.…]*"#, with: " ", options: .regularExpression)
        // Mot répété (« je je ») sauf « nous nous », « vous vous » et « très très », voulus
        t = t.replacingOccurrences(of: #"(?i)\b(?!nous\b|vous\b|très\b)(\p{L}+)(?:\s+\1\b)+"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+([,.])"#, with: "$1", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
        // Majuscule en tête si on a retiré le premier mot
        if let first = t.first, first.isLowercase, text.first?.isUppercase == true {
            t = first.uppercased() + t.dropFirst()
        }
        return t
    }
}

// MARK: - Historique et statistiques (UserDefaults)

enum Stats {
    private static let d = UserDefaults.standard

    static var history: [String] { d.stringArray(forKey: "history") ?? [] }
    /// Date de chaque dictée de l'historique (secondes depuis 1970), dans le même ordre
    static var historyDates: [Double] { d.array(forKey: "historyDates") as? [Double] ?? [] }
    static var totalWords: Int { d.integer(forKey: "totalWords") }
    static var todayWords: Int { d.string(forKey: "todayDate") == today ? d.integer(forKey: "todayWords") : 0 }
    /// Temps gagné par rapport à une frappe à 40 mots/min, en minutes
    static var minutesSaved: Int { max(0, Int(Double(totalWords) / 40 - d.double(forKey: "totalSeconds") / 60)) }

    private static func day(_ date: Date) -> String {
        ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: .withFullDate)
    }
    private static var today: String { day(Date()) }

    /// Mots dictés par jour (« 2026-10-31 » -> 412)
    private static var daily: [String: Int] { d.dictionary(forKey: "dailyWords") as? [String: Int] ?? [:] }

    /// Les 7 derniers jours, du plus ancien à aujourd'hui
    static var lastWeek: [(date: Date, words: Int)] {
        var days = daily
        // Les mots d'aujourd'hui comptés avant l'arrivée du suivi par jour
        if days[today] == nil, todayWords > 0 { days[today] = todayWords }
        return (0..<7).reversed().map { offset in
            let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date())!
            return (date, days[day(date)] ?? 0)
        }
    }

    static func record(_ text: String, seconds: Double) {
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        d.set(Array(([text] + history).prefix(50)), forKey: "history")
        d.set(Array(([Date().timeIntervalSince1970] + historyDates).prefix(50)), forKey: "historyDates")
        var days = daily
        days[today] = todayWords + words
        // On ne garde qu'un mois
        let cutoff = day(Date().addingTimeInterval(-31 * 86_400))
        d.set(days.filter { $0.key >= cutoff }, forKey: "dailyWords")
        d.set(totalWords + words, forKey: "totalWords")
        d.set(todayWords + words, forKey: "todayWords")
        d.set(today, forKey: "todayDate")
        d.set(d.double(forKey: "totalSeconds") + seconds, forKey: "totalSeconds")
    }
}

// MARK: - Journal de diagnostic (~/Library/Logs/Dictee.log)

private let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Dictee.log")
private let logDate = ISO8601DateFormatter()

func log(_ message: String) {
    let url = logURL
    let line = "\(logDate.string(from: Date())) \(message)\n"
    // Au-delà de 1 Mo, l'ancien journal devient Dictee.old.log : il ne grossit jamais sans fin
    if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 1_000_000 {
        let old = url.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Modèle Whisper (téléchargé une fois dans ~/Library/Application Support/Dictee)

func loadWhisper() async throws -> WhisperKit {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Dictee", isDirectory: true)
    let config = WhisperKitConfig(model: "large-v3-v20240930_turbo_632MB", downloadBase: base,
                                  verbose: false, prewarm: true, load: true, download: true)
    return try await WhisperKit(config)
}

// MARK: - Raccourcis possibles (touches modificatrices maintenues seules)

enum Hotkey: String, CaseIterable {
    case option, rightOption, leftOption, rightCommand, control, fn

    var label: String {
        switch self {
        case .option: return "⌥ Option (gauche ou droite)"
        case .rightOption: return "⌥ Option droite"
        case .leftOption: return "⌥ Option gauche"
        case .rightCommand: return "⌘ Commande droite"
        case .control: return "⌃ Contrôle"
        case .fn: return "🌐 Fn / Globe"
        }
    }

    var keyCodes: Set<UInt16> {
        switch self {
        case .option: return [58, 61]
        case .rightOption: return [61]
        case .leftOption: return [58]
        case .rightCommand: return [54]
        case .control: return [59, 62]
        case .fn: return [63]
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .option, .rightOption, .leftOption: return .option
        case .rightCommand: return .command
        case .control: return .control
        case .fn: return .function
        }
    }
}

// MARK: - App barre de menu

final class AppDelegate: NSObject, NSApplicationDelegate {
    enum State { case loading(String), ready, recording, transcribing, error(String) }

    /// La touche modificatrice à maintenir pour parler (choisie dans les réglages)
    private var hotkey = Hotkey(rawValue: UserDefaults.standard.string(forKey: "hotkey") ?? "") ?? .option

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let menuModel = MenuModel()
    private var monitors: [Any] = []
    private var axTrusted = false
    private var otherKeyDuringHold = false
    private let recorder = Recorder()
    private let updater = Updater()
    private var availableUpdate: Updater.Release?
    /// Vrai quand l'utilisateur a cliqué : le panneau affiche alors le résultat
    private var manualUpdateCheck = false
    private var recordStart = Date()
    private let overlay = OverlayPanel()
    private var whisper: WhisperKit?
    private var state: State = .loading("Démarrage…") { didSet { refresh(); updateOverlay() } }
    private var hotkeyDown = false
    /// Mains libres : activé par un double appui, arrêté par l'appui suivant
    private var handsFree = false
    private var pressStart = Date()
    private var lastQuickRelease: Date?
    private var ignoreNextRelease = false
    /// Incrémenté par Échap : la transcription en cours n'est plus collée
    private var transcriptionID = 0
    private var autoLanguage = UserDefaults.standard.bool(forKey: "autoLanguage")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        recorder.onLevel = { [weak self] rms in self?.overlay.model.push(rms) }
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        let host = NSHostingController(rootView: MenuView(model: menuModel))
        // Le panneau suit la taille de la page affichée (accueil, historique, réglages)
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        menuModel.version = updater.currentVersion
        menuModel.chooseHotkey = { [weak self] in self?.setHotkey($0) }
        menuModel.toggleLanguage = { [weak self] in self?.toggleLanguage() }
        menuModel.toggleLogin = { [weak self] in self?.toggleLogin() }
        menuModel.update = { [weak self] in self?.updateClicked() }
        menuModel.openAccessibility = { [weak self] in self?.openAccessibility() }
        menuModel.openMicrophone = { [weak self] in self?.openMicrophone() }
        refresh()

        log("Lancement \(Bundle.main.bundlePath)")
        requestPermissions()
        installHotkey()
        // L'autorisation peut être accordée pendant que l'app tourne : on surveille
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.checkTrust() }
        updater.onResult = { [weak self] release in
            guard let self else { return }
            self.availableUpdate = release
            self.refresh()
            self.menuModel.updateVersion = release?.version
            let manual = self.manualUpdateCheck
            self.manualUpdateCheck = false
            // On laisse « Vérification… » visible un instant, sinon le clic semble sans effet
            DispatchQueue.main.asyncAfter(deadline: .now() + (manual ? 0.7 : 0)) {
                self.menuModel.checking = false
                self.menuModel.checkFailed = false
                guard manual else { return }
                if let release {
                    NSWorkspace.shared.open(release.page)
                } else {
                    self.menuModel.confirmedUpToDate = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.menuModel.confirmedUpToDate = false }
                }
            }
        }
        updater.onError = { [weak self] in
            guard let self else { return }
            self.menuModel.checking = false
            self.menuModel.checkFailed = self.manualUpdateCheck
            self.manualUpdateCheck = false
        }
        updater.start()
        // Au réveil : on repose le raccourci et on remet l'app dans un état propre
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            log("Réveil de l'ordinateur : remise à zéro")
            if case .recording = self.state { _ = self.recorder.stop(); self.state = .ready }
            self.hotkeyDown = false
            self.installHotkey()
        }
        Task { await loadModel() }
    }

    private func checkTrust() {
        let trusted = AXIsProcessTrusted()
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        guard trusted != axTrusted || mic != menuModel.micOK else { return }
        if trusted != axTrusted {
            axTrusted = trusted
            log("Accessibilité : \(trusted ? "autorisée" : "NON autorisée")")
            // Les moniteurs globaux posés avant l'autorisation ne reçoivent rien : on les repose
            installHotkey()
        }
        refresh()
    }

    // MARK: Permissions

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            log("Micro : \(granted ? "autorisé" : "REFUSÉ")")
            DispatchQueue.main.async { self.refresh() }
        }
        axTrusted = AXIsProcessTrusted()
        log("Accessibilité au lancement : \(axTrusted ? "autorisée" : "NON autorisée")")
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openMicrophone() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    // MARK: Modèle

    private func loadModel() async {
        await MainActor.run { state = .loading("Chargement du modèle (1er lancement : téléchargement ~600 Mo)…") }
        do {
            let kit = try await loadWhisper()
            await MainActor.run { whisper = kit; state = .ready }
            log("Modèle chargé")
        } catch {
            log("Erreur modèle : \(error)")
            await MainActor.run { state = .error("Modèle : \(error.localizedDescription)") }
        }
    }

    // MARK: Raccourci

    private func installHotkey() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            if event.type == .keyDown {
                // Échap : on annule la dictée ou la transcription en cours
                if event.keyCode == 53 { self.cancelDictation(); return }
                // Raccourci + une touche (ex. ⌥( pour « { » ou ⌘C) : ce n'est pas une dictée
                if self.hotkeyDown && !self.handsFree { self.otherKeyDuringHold = true }
                return
            }
            guard self.hotkey.keyCodes.contains(event.keyCode) else { return }
            let pressed = event.modifierFlags.contains(self.hotkey.flag)
            if pressed && !self.hotkeyDown {
                self.hotkeyDown = true
                self.keyPressed()
            } else if !pressed && self.hotkeyDown {
                self.hotkeyDown = false
                self.keyReleased()
            }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: handler) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { handler($0); return $0 }) { monitors.append(m) }
        log("Raccourci installé (accessibilité : \(AXIsProcessTrusted()))")
    }

    private func keyPressed() {
        pressStart = Date()
        if handsFree {
            // Mains libres : l'appui suivant termine la dictée
            handsFree = false
            ignoreNextRelease = true
            stopRecording()
        } else if case .recording = state, let last = lastQuickRelease, Date().timeIntervalSince(last) < 0.4 {
            // Double appui : on passe en mains libres, l'enregistrement continue
            lastQuickRelease = nil
            handsFree = true
            ignoreNextRelease = true
            overlay.model.locked = true
            refresh()
            log("Mains libres activé")
        } else {
            otherKeyDuringHold = false
            startRecording()
        }
    }

    private func keyReleased() {
        if ignoreNextRelease { ignoreNextRelease = false; return }
        guard case .recording = state else { return }
        if Date().timeIntervalSince(pressStart) < 0.3 && !otherKeyDuringHold {
            // Appui bref : peut-être le début d'un double appui, on attend un peu avant d'abandonner
            let release = Date()
            lastQuickRelease = release
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard self.lastQuickRelease == release, !self.handsFree, !self.hotkeyDown else { return }
                self.lastQuickRelease = nil
                self.stopRecording()
            }
            return
        }
        stopRecording()
    }

    private func cancelDictation() {
        switch state {
        case .recording:
            _ = recorder.stop()
            handsFree = false
            lastQuickRelease = nil
            if hotkeyDown { ignoreNextRelease = true }
        case .transcribing:
            transcriptionID += 1
        default:
            return
        }
        log("Annulé avec Échap")
        state = .ready
        overlay.flash(.cancelled)
    }

    private func startRecording() {
        guard case .ready = state else { log("Appui ignoré : modèle pas prêt"); return }
        do {
            try recorder.start()
            recordStart = Date()
            NSSound(named: "Tink")?.play()
            state = .recording
            log("Enregistrement démarré")
        } catch {
            log("Erreur micro : \(error)")
            state = .error("Micro : \(error.localizedDescription)")
        }
    }

    private func stopRecording() {
        guard case .recording = state else { return }
        let samples = recorder.stop()
        let peak = samples.map(abs).max() ?? 0
        log("Enregistrement arrêté : \(samples.count) échantillons, pic \(peak)")
        if samples.isEmpty && Date().timeIntervalSince(recordStart) > 0.6 {
            log("Micro muet : aucun son reçu")
            state = .error("Micro muet : réessaie (ou vérifie l'entrée son)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if case .error = self.state { self.state = .ready }
            }
            return
        }
        if otherKeyDuringHold { log("Annulé : raccourci utilisé avec une autre touche"); state = .ready; return }
        handsFree = false
        NSSound(named: "Pop")?.play()
        // Moins de 0,3 s : appui accidentel
        guard samples.count > 16_000 * 3 / 10, let whisper else { state = .ready; return }
        state = .transcribing
        let options = DecodingOptions(
            task: .transcribe,
            language: autoLanguage ? nil : "fr",
            temperatureFallbackCount: 3,
            usePrefillPrompt: !autoLanguage,
            detectLanguage: autoLanguage,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            chunkingStrategy: .vad
        )
        let french = !autoLanguage
        let seconds = Double(samples.count) / 16_000
        transcriptionID += 1
        let id = transcriptionID
        Task {
            do {
                let results: [TranscriptionResult] = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
                let raw = results.map(\.text).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let cleaned = TextCleanup.apply(raw)
                let text = french ? FrenchTypography.apply(cleaned) : cleaned
                log("Transcription : \(text.count) caractères")
                await MainActor.run {
                    guard id == transcriptionID else { log("Transcription ignorée (annulée)"); return }
                    let before = CursorContext.textBeforeCursor()
                    let text = CursorContext.adapt(text, after: before)
                    log("Contexte du curseur : \(before.map { "« …\(String($0.suffix(20)))»" } ?? "illisible")")
                    if !text.isEmpty { Stats.record(text, seconds: seconds); refreshPanel() }
                    if !text.isEmpty && !Paster.paste(text) {
                        state = .error("Texte copié : fais ⌘V (accessibilité à autoriser)")
                        NSSound(named: "Funk")?.play()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                            if case .error = self.state { self.state = .ready }
                        }
                        return
                    }
                    state = .ready
                    if !text.isEmpty { overlay.flash(.done) }
                }
            } catch {
                await MainActor.run { state = .error("Transcription : \(error.localizedDescription)") }
            }
        }
    }

    // MARK: Menu

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            state = .error("Démarrage auto : \(error.localizedDescription)")
        }
        refreshPanel()
    }

    @objc private func toggleLanguage() {
        autoLanguage.toggle()
        UserDefaults.standard.set(autoLanguage, forKey: "autoLanguage")
        refresh()
    }

    @objc private func updateClicked() {
        if let release = availableUpdate {
            NSWorkspace.shared.open(release.page)
        } else {
            menuModel.checking = true
            manualUpdateCheck = true
            updater.check()
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            menuModel.page = .home
            refresh()
            refreshPanel()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func setHotkey(_ key: Hotkey) {
        hotkey = key
        hotkeyDown = false
        UserDefaults.standard.set(key.rawValue, forKey: "hotkey")
        log("Raccourci choisi : \(key.rawValue)")
        refresh()
    }

    /// Données du panneau (historique, stats, démarrage auto) : à l'ouverture et après chaque dictée
    private func refreshPanel() {
        let m = menuModel
        m.launchAtLogin = SMAppService.mainApp.status == .enabled
        let dates = Stats.historyDates
        m.history = Stats.history.enumerated().map { i, text in
            MenuModel.Entry(text: text, date: i < dates.count ? Date(timeIntervalSince1970: dates[i]) : nil)
        }
        m.todayWords = Stats.todayWords
        m.totalWords = Stats.totalWords
        m.minutesSaved = Stats.minutesSaved
        m.week = Stats.lastWeek.map { MenuModel.Day(date: $0.date, words: $0.words) }
    }

    /// État courant : icône de la barre de menu et en-tête du panneau
    private func refresh() {
        let m = menuModel
        m.hotkey = hotkey
        m.autoLanguage = autoLanguage
        m.axOK = axTrusted
        m.micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        m.status = {
            switch state {
            case .loading(let msg): return .loading(msg)
            case .ready: return .ready
            case .recording: return .recording(handsFree: handsFree)
            case .transcribing: return .transcribing
            case .error(let msg): return .error(msg)
            }
        }()
        // Couleur nil = icône monochrome qui suit le thème de la barre de menu
        let (symbol, color, text): (String, NSColor?, String) = {
            switch state {
            case .loading(let msg): return ("hourglass", nil, msg)
            case .ready: return ("mic", nil, "Prêt")
            case .recording: return ("mic.fill", Brand.coral, handsFree ? "J'écoute (mains libres, Échap pour annuler)…" : "J'écoute…")
            case .transcribing: return ("waveform", Brand.violet, "Transcription…")
            case .error(let msg): return ("exclamationmark.triangle.fill", .systemOrange, msg)
            }
        }()
        statusItem?.button?.toolTip = availableUpdate.map { "Dictée : mise à jour \($0.version) disponible" } ?? "Dictée : \(text)"
        var image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Dictée")
        if let color {
            image = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))
            image?.isTemplate = false
        } else {
            image?.isTemplate = true
        }
        // Pastille corail sur l'icône quand une mise à jour attend
        if availableUpdate != nil, case .ready = state, let base = image {
            image = withBadge(base)
        }
        statusItem?.button?.image = image
    }

    private func withBadge(_ base: NSImage) -> NSImage {
        let size = NSSize(width: base.size.width + 3, height: base.size.height)
        // Dessiné au moment de l'affichage : la couleur suit le thème clair/sombre de la barre de menu
        return NSImage(size: size, flipped: false) { rect in
            let icon = NSRect(origin: .zero, size: base.size)
            base.draw(in: icon)
            NSColor.labelColor.set()
            icon.fill(using: .sourceAtop)
            let dot = NSRect(x: rect.maxX - 7, y: rect.maxY - 7, width: 7, height: 7)
            // Liseré transparent autour de la pastille, pour la détacher du micro
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            Brand.coral.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
    }

    private func updateOverlay() {
        switch state {
        case .recording: overlay.show(.listening)
        case .transcribing: overlay.show(.transcribing)
        default: overlay.hide()
        }
    }
}

// Mode test : Dictee --transcribe fichier.wav
if let i = CommandLine.arguments.firstIndex(of: "--transcribe"), i + 1 < CommandLine.arguments.count {
    let path = CommandLine.arguments[i + 1]
    let done = DispatchSemaphore(value: 0)
    Task {
        do {
            let kit = try await loadWhisper()
            let start = Date()
            let results: [TranscriptionResult] = try await kit.transcribe(
                audioPath: path, decodeOptions: DecodingOptions(language: "fr", skipSpecialTokens: true, withoutTimestamps: true))
            print(FrenchTypography.apply(results.map(\.text).joined(separator: " ")))
            print(String(format: "(%.2f s)", Date().timeIntervalSince(start)))
        } catch {
            print("Erreur : \(error)")
        }
        done.signal()
    }
    done.wait()
    exit(0)
}

// Mode aperçu : Dictee --preview (montre la bulle quelques secondes, pour ajuster le design)
if CommandLine.arguments.contains("--preview") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let overlay = OverlayPanel()
    // Avec un chemin : on enregistre aussi les deux états en PNG
    if let i = CommandLine.arguments.firstIndex(of: "--preview"), i + 1 < CommandLine.arguments.count {
        let model = OverlayModel()
        model.levels = (0..<model.levels.count).map { CGFloat(abs(sin(Double($0) * 0.6))) * 0.9 }
        MainActor.assumeIsolated {
        for mode in [OverlayModel.Mode.listening, .transcribing] {
            model.mode = mode
            let renderer = ImageRenderer(content: OverlayView(model: model).frame(width: 260, height: 56))
            renderer.scale = 2
            if let cg = renderer.cgImage {
                let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
                try? png?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1] + "-\(mode).png"))
            }
        }
        // Le panneau du menu, avec des données d'exemple
        let menu = MenuModel()
        menu.status = .ready
        menu.hotkey = .fn
        menu.version = "0.7"
        menu.todayWords = 412
        menu.totalWords = 5_280
        menu.minutesSaved = 96
        menu.history = [
            .init(text: "Tu peux me dire pourquoi la bulle n'apparaît pas en plein écran ?", date: Date().addingTimeInterval(-40)),
            .init(text: "Ok, je regarde ça demain matin et je te redis.", date: Date().addingTimeInterval(-60 * 14)),
            .init(text: "Merci pour le retour !", date: Date().addingTimeInterval(-3600 * 3)),
        ]
        menu.week = [120, 340, 0, 280, 510, 190, 412].enumerated().map {
            MenuModel.Day(date: Date().addingTimeInterval(Double($0.offset - 6) * 86_400), words: $0.element)
        }
        for (page, dark, suffix) in [(MenuModel.Page.home, false, "light"), (.home, true, "dark"),
                                     (.settings, false, "settings"), (.history, true, "history")] {
            menu.page = page
            let host = NSHostingView(rootView: MenuView(model: menu))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.sizingOptions = [.intrinsicContentSize]
            host.frame.size = host.fittingSize
            let bg = NSView(frame: host.frame)
            bg.wantsLayer = true
            bg.layer?.backgroundColor = (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).cgColor
            bg.addSubview(host)
            if let rep = bg.bitmapImageRepForCachingDisplay(in: bg.bounds) {
                bg.cacheDisplay(in: bg.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1] + "-menu-\(suffix).png"))
            }
        }
        }
    }
    overlay.show(.listening)
    var t: Float = 0
    Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
        t += 0.3
        overlay.model.push(abs(sin(t)) * Float.random(in: 0.01...0.08))
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { overlay.show(.transcribing) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { exit(0) }
    app.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
