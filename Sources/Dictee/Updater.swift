import AppKit

// MARK: - Vérification des mises à jour (dernière release GitHub)

final class Updater {
    struct Release { let version: String; let page: URL }

    private let api = URL(string: "https://api.github.com/repos/HIlyes/Dictee/releases/latest")!
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    /// Appelé sur le fil principal : la release si elle est plus récente, nil si l'app est à jour
    var onResult: ((Release?) -> Void)?

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
                return
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let newer = latest.compare(self.currentVersion, options: .numeric) == .orderedDescending
            log("Mise à jour : installée \(self.currentVersion), dernière \(latest)")
            DispatchQueue.main.async { self.onResult?(newer ? Release(version: latest, page: page) : nil) }
        }.resume()
    }
}
