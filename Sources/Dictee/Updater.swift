import AppKit

// MARK: - Mises à jour : vérification sur GitHub, puis installation sur demande

final class Updater {
    struct Release { let version: String; let page: URL; let zip: URL? }
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    // DICTEE_UPDATE_API permet de tester l'installation avec une fausse release locale
    private let api = URL(string: ProcessInfo.processInfo.environment["DICTEE_UPDATE_API"]
                          ?? "https://api.github.com/repos/HIlyes/Dictee/releases/latest")!
    private var progressObservation: NSKeyValueObservation?
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    /// Appelé sur le fil principal : la release si elle est plus récente, nil si l'app est à jour
    var onResult: ((Release?) -> Void)?
    /// Appelé sur le fil principal quand GitHub ne répond pas
    var onError: (() -> Void)?

    /// Vérifie maintenant, puis une fois par jour
    func start() {
        check()
        Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in self?.check() }
    }

    func check() {
        var request = URLRequest(url: api)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
                log("Mise à jour : vérification impossible (\(error?.localizedDescription ?? "réponse inattendue"))")
                DispatchQueue.main.async { self.onError?() }
                return
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let zip = (json["assets"] as? [[String: Any]])?
                .first { ($0["name"] as? String) == "Dictee.zip" }?["browser_download_url"]
                .flatMap { ($0 as? String).flatMap(URL.init(string:)) }
            let newer = latest.compare(self.currentVersion, options: .numeric) == .orderedDescending
            log("Mise à jour : installée \(self.currentVersion), dernière \(latest)")
            DispatchQueue.main.async { self.onResult?(newer ? Release(version: latest, page: page, zip: zip) : nil) }
        }.resume()
    }

    /// Télécharge la release, vérifie qu'elle est signée comme l'app actuelle, puis remplace l'app.
    /// Sur le fil principal : progress (0 à 1), puis completion(nil) si c'est prêt, ou la raison de l'échec
    func install(_ release: Release, progress: @escaping (Double) -> Void, completion: @escaping (String?) -> Void) {
        guard let zip = release.zip else { return completion("archive introuvable") }
        // Une app lancée depuis Téléchargements ou un dossier protégé ne peut pas être remplacée
        guard FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path) else {
            return completion("dossier de l'app protégé")
        }
        let task = URLSession.shared.downloadTask(with: zip) { [weak self] file, response, error in
            var failure: String?
            do {
                guard let file, (response as? HTTPURLResponse)?.statusCode ?? 200 == 200 else {
                    throw Failure(error?.localizedDescription ?? "téléchargement impossible")
                }
                try self?.replaceApp(with: file, version: release.version)
            } catch {
                failure = error.localizedDescription
            }
            log("Mise à jour \(release.version) : \(failure ?? "installée")")
            DispatchQueue.main.async {
                self?.progressObservation = nil
                completion(failure)
            }
        }
        progressObservation = task.progress.observe(\.fractionCompleted) { p, _ in
            DispatchQueue.main.async { progress(p.fractionCompleted) }
        }
        task.resume()
    }

    private func replaceApp(with zip: URL, version: String) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("DicteeUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, work.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0,
              let app = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) else { throw Failure("archive illisible") }
        try verify(app, version: version)
        // Échange atomique : l'ancienne app part dans le dossier temporaire, effacé ensuite
        _ = try fm.replaceItemAt(Bundle.main.bundleURL, withItemAt: app)
    }

    /// La nouvelle app doit remplir la même exigence de signature que l'app installée
    /// (même identifiant, même certificat) : c'est aussi ce qui garde l'autorisation d'accessibilité
    private func verify(_ app: URL, version: String) throws {
        var current: SecStaticCode?, candidate: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &current) == errSecSuccess, let current,
              SecCodeCopyDesignatedRequirement(current, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess, let candidate else {
            throw Failure("signature illisible")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(candidate, flags, requirement) == errSecSuccess else {
            throw Failure("signature différente de l'app installée")
        }
        guard Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version else {
            throw Failure("version inattendue dans l'archive")
        }
    }

    /// Relance l'app une fois ce processus terminé
    func relaunch() {
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"",
                              Bundle.main.bundlePath]
        try? relaunch.run()
        NSApp.terminate(nil)
    }
}
