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

// MARK: - Journal de diagnostic (~/Library/Logs/Dictee.log)

func log(_ message: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Dictee.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
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

    // Une touche Option (gauche 58 ou droite 61) maintenue seule = on parle
    private var hotkey = Hotkey(rawValue: UserDefaults.standard.string(forKey: "hotkey") ?? "") ?? .option
    private let hintLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let hotkeyMenu = NSMenu()

    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let langItem = NSMenuItem(title: "Langue : français", action: #selector(toggleLanguage), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Lancer au démarrage", action: #selector(toggleLogin), keyEquivalent: "")
    private let axLine = NSMenuItem(title: "", action: #selector(openAccessibility), keyEquivalent: "")
    private let micLine = NSMenuItem(title: "", action: #selector(openMicrophone), keyEquivalent: "")
    private var monitors: [Any] = []
    private var axTrusted = false
    private var otherKeyDuringHold = false
    private let recorder = Recorder()
    private var recordStart = Date()
    private let overlay = OverlayPanel()
    private var whisper: WhisperKit?
    private var state: State = .loading("Démarrage…") { didSet { refresh(); updateOverlay() } }
    private var hotkeyDown = false
    private var autoLanguage = UserDefaults.standard.bool(forKey: "autoLanguage")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        recorder.onLevel = { [weak self] rms in self?.overlay.model.push(rms) }
        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        hintLine.isEnabled = false
        menu.addItem(hintLine)
        menu.addItem(.separator())
        axLine.target = self
        menu.addItem(axLine)
        micLine.target = self
        menu.addItem(micLine)
        menu.addItem(.separator())
        langItem.target = self
        menu.addItem(langItem)
        for key in Hotkey.allCases {
            let item = NSMenuItem(title: key.label, action: #selector(chooseHotkey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key.rawValue
            hotkeyMenu.addItem(item)
        }
        let hotkeyItem = NSMenuItem(title: "Raccourci", action: nil, keyEquivalent: "")
        hotkeyItem.submenu = hotkeyMenu
        menu.addItem(hotkeyItem)
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quitter Dictée", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        refresh()

        log("Lancement \(Bundle.main.bundlePath)")
        requestPermissions()
        installHotkey()
        // L'autorisation peut être accordée pendant que l'app tourne : on surveille
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.checkTrust() }
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
                // Raccourci + une touche (ex. ⌥( pour « { » ou ⌘C) : ce n'est pas une dictée
                if self.hotkeyDown { self.otherKeyDuringHold = true }
                return
            }
            log("Touche modificatrice keyCode=\(event.keyCode)")
            guard self.hotkey.keyCodes.contains(event.keyCode) else { return }
            let pressed = event.modifierFlags.contains(self.hotkey.flag)
            if pressed && !self.hotkeyDown {
                self.hotkeyDown = true
                self.otherKeyDuringHold = false
                self.startRecording()
            } else if !pressed && self.hotkeyDown {
                self.hotkeyDown = false
                self.stopRecording()
            }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: handler) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { handler($0); return $0 }) { monitors.append(m) }
        log("Raccourci installé (accessibilité : \(AXIsProcessTrusted()))")
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
        Task {
            do {
                let results: [TranscriptionResult] = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
                let raw = results.map(\.text).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let text = french ? FrenchTypography.apply(raw) : raw
                log("Transcription : \(text.count) caractères")
                await MainActor.run {
                    if !text.isEmpty && !Paster.paste(text) {
                        state = .error("Texte copié : fais ⌘V (accessibilité à autoriser)")
                        NSSound(named: "Funk")?.play()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                            if case .error = self.state { self.state = .ready }
                        }
                        return
                    }
                    state = .ready
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
        refresh()
    }

    @objc private func toggleLanguage() {
        autoLanguage.toggle()
        UserDefaults.standard.set(autoLanguage, forKey: "autoLanguage")
        refresh()
    }

    @objc private func chooseHotkey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = Hotkey(rawValue: raw) else { return }
        hotkey = key
        hotkeyDown = false
        UserDefaults.standard.set(raw, forKey: "hotkey")
        log("Raccourci choisi : \(raw)")
        refresh()
    }

    private func refresh() {
        hintLine.title = "Maintenir \(hotkey.label) pour dicter"
        for item in hotkeyMenu.items {
            item.state = item.representedObject as? String == hotkey.rawValue ? .on : .off
        }
        langItem.title = autoLanguage ? "Langue : détection auto" : "Langue : français"
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        axLine.title = axTrusted ? "✅ Accessibilité autorisée" : "⚠️ Accessibilité à autoriser (clic)"
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        micLine.title = mic == .authorized ? "✅ Micro autorisé" : "⚠️ Micro à autoriser (clic)"
        // Couleur nil = icône monochrome qui suit le thème de la barre de menu
        let (symbol, color, text): (String, NSColor?, String) = {
            switch state {
            case .loading(let msg): return ("hourglass", nil, msg)
            case .ready: return ("mic", nil, "Prêt")
            case .recording: return ("mic.fill", Brand.coral, "J'écoute…")
            case .transcribing: return ("waveform", Brand.violet, "Transcription…")
            case .error(let msg): return ("exclamationmark.triangle.fill", .systemOrange, msg)
            }
        }()
        statusLine.title = text
        var image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Dictée")
        if let color {
            image = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))
            image?.isTemplate = false
        } else {
            image?.isTemplate = true
        }
        statusItem?.button?.image = image
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
