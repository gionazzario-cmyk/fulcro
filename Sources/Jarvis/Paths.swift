import Foundation

enum AppPaths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static var jarvisRoot: URL { home.appendingPathComponent(".jarvis") }
    static var tmp: URL { jarvisRoot.appendingPathComponent("tmp") }
    static var whisperModel: URL { jarvisRoot.appendingPathComponent("models/ggml-small.bin") }
    static var stl: URL { jarvisRoot.appendingPathComponent("stl") }

    /// Voce neurale italiana (piper). Se non c'e', Jarvis ricade sulla voce di sistema.
    static var piperDir: URL { jarvisRoot.appendingPathComponent("piper") }

    /// Le voci piper scaricate davvero: ~/.jarvis/voce.txt dice quale usare.
    static var voceSceltaFile: URL { jarvisRoot.appendingPathComponent("voce.txt") }

    static let vociPiper: [(nome: String, file: String, desc: String)] = [
        ("serena", "it_IT-serena-high.onnx", "donna, alta qualita'"),
        ("riccardo", "it_IT-riccardo-x_low.onnx", "uomo, qualita' bassa")
    ]

    static func disponibili() -> [(nome: String, file: String, desc: String)] {
        let fm = FileManager.default
        return vociPiper.filter { fm.fileExists(atPath: piperDir.appendingPathComponent($0.file).path) }
    }

    static var voceCorrente: String {
        let scelta = ((try? String(contentsOf: voceSceltaFile, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pronte = disponibili().map(\.nome)
        if pronte.contains(scelta) { return scelta }
        return pronte.contains("serena") ? "serena" : (pronte.first ?? "serena")
    }

    static var piperVoce: URL {
        let file = vociPiper.first(where: { $0.nome == voceCorrente })?.file ?? "it_IT-serena-high.onnx"
        return piperDir.appendingPathComponent(file)
    }

    /// Cambia voce senza ricompilare: scrive il nome nel file e dice com'e' andata.
    static func scegliVoce(_ nome: String) -> String {
        let pulito = nome.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'."))
        guard let trovata = vociPiper.first(where: { $0.nome == pulito || pulito.contains($0.nome) }) else {
            let pronte = disponibili().map(\.nome).joined(separator: ", ")
            return "Non conosco la voce «\(nome)». Quelle pronte sono: \(pronte.isEmpty ? "nessuna" : pronte)."
        }
        guard disponibili().contains(where: { $0.nome == trovata.nome }) else {
            return "La voce \(trovata.nome) non e' scaricata in ~/.jarvis/piper/."
        }
        do { try trovata.nome.write(to: voceSceltaFile, atomically: true, encoding: .utf8) }
        catch { return "Non sono riuscito a salvare la scelta: \(error.localizedDescription)" }
        return "Voce cambiata: \(capitalizza(trovata.nome)) (\(trovata.desc)). Vale da subito, anche senza riavviarmi."
    }

    static func capitalizza(_ s: String) -> String {
        s.isEmpty ? s : s.prefix(1).uppercased() + s.dropFirst()
    }

    static var whisperBinary: String? {
        ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli", "/opt/homebrew/bin/whisper"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func prepare() {
        let fm = FileManager.default
        for sub in ["models", "logs", "tmp", "stl"] {
            try? fm.createDirectory(at: jarvisRoot.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        // gli screenshot si accumulano: via quelli di piu' di un giorno
        let cutoff = Date().addingTimeInterval(-86_400)
        let files = (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for f in files where ["schermo-", "voce-", "stampa-", "presa-"].contains(where: { f.lastPathComponent.hasPrefix($0) }) {
            let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            if date < cutoff { try? fm.removeItem(at: f) }
        }
    }
}
