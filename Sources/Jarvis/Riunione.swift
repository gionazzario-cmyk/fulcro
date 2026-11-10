import Foundation
import AppKit

/// L'assistente per le riunioni: mentre l'utente e' in Meet/Zoom/Teams, Jarvis guarda
/// lo schermo, tiene gli appunti in un file e li scrive in chat. MAI a voce: la regola
/// che si e' dato e' "durante una call non parlare".
///
/// Costa: ogni passaggio e' uno screenshot + il modello visivo (~30 s, 6,9 GB di RAM),
/// quindi gira al massimo ogni 75 secondi e solo con la corrente attaccata.
@MainActor
final class Riunione: ObservableObject {
    static let shared = Riunione()

    @Published var attivo = false
    @Published var ultimoPassaggio = Date.distantPast
    private var timer: Timer?
    private var giroInCorso = false

    static var cartella: URL {
        let c = AppPaths.jarvisRoot.appendingPathComponent("riunioni")
        try? FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)
        return c
    }

    static var fileDiOggi: URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HH-mm"
        return cartella.appendingPathComponent("riunione-\(f.string(from: Date())).md")
    }

    private init() {}

    var stato: String {
        guard attivo else { return "Riunioni: non sto ascoltando." }
        let d = Int(Date().timeIntervalSince(ultimoPassaggio))
        return "Riunioni: acceso, ultimo sguardo allo schermo \(d) secondi fa. Appunti in \(Riunione.fileDiOggi.path)"
    }

    func accendi() -> String {
        guard !attivo else { return "Sto gia' prendendo appunti." }
        guard Alimentazione.inCarica else {
            return "A batteria non posso guardare lo schermo ogni minuto (il modello visivo pesa): attacca la corrente e riprova."
        }
        attivo = true
        let file = Riunione.fileDiOggi
        if !FileManager.default.fileExists(atPath: file.path) {
            try? "# Riunione del \(Date())\n\n".write(to: file, atomically: true, encoding: .utf8)
        }
        timer?.invalidate()
        avviaTimer()
        Task { @MainActor in await self.passaggio() }
        return "Riunioni: acceso. Guardo lo schermo ogni 75 secondi e scrivo gli appunti in chat e nel file, sempre senza parlare."
    }

    /// Uno screenshot + il modello visivo ogni 75 secondi non e' roba da fare a
    /// batteria: il piano lo sospende, e quando torna la corrente riparte da solo.
    private func avviaTimer() {
        let t = Timer(timeInterval: 75, repeats: true) { _ in
            Task { @MainActor in await Riunione.shared.passaggio() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @MainActor func sospendi() {
        timer?.invalidate()
        timer = nil
    }

    @MainActor func riprendi() {
        guard attivo, timer == nil else { return }
        avviaTimer()
    }

    func spegni() -> String {
        attivo = false
        timer?.invalidate()
        timer = nil
        return "Riunioni: spento. Gli appunti restano in \(Riunione.fileDiOggi.path)."
    }

    /// Appunto manuale (sua richiesta): "nota che Marco deve mandarmi il preventivo".
    func punta(_ testo: String) -> String {
        let riga = "- \(ora()) \u{2014} \(testo)\n"
        if let maniglia = try? FileHandle(forWritingTo: Riunione.fileDiOggi) {
            maniglia.seekToEndOfFile()
            maniglia.write(riga.data(using: .utf8)!)
            try? maniglia.close()
        } else {
            try? riga.write(to: Riunione.fileDiOggi, atomically: true, encoding: .utf8)
        }
        JarvisCore.shared.notaSenzaVoce("Appunto preso: \(testo)")
        return "Segnato negli appunti della riunione."
    }

    private func ora() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "HH:mm"
        return f.string(from: Date())
    }

    /// Uno sguardo allo schermo: legge sottotitoli e finestre della call e scrive cosa capisce.
    @MainActor
    func passaggio() async {
        guard attivo, !giroInCorso else { return }
        guard await Brain.shared.visionModel() != nil else {
            JarvisCore.shared.notaSenzaVoce("Riunioni: il modello visivo non e' pronto, non posso guardare lo schermo.")
            attivo = false
            return
        }
        giroInCorso = true
        defer { giroInCorso = false }
        ultimoPassaggio = Date()
        let immagine = AppPaths.tmp.appendingPathComponent("riunione-\(Int(Date().timeIntervalSince1970)).png")
        _ = await Shell.run("/usr/sbin/screencapture", ["-x", immagine.path])
        guard FileManager.default.fileExists(atPath: immagine.path) else { return }
        let visto = await Brain.shared.askVision(image: immagine, prompt: "Questa e' lo schermo di un Mac durante una videochiamata. Se vedi una riunione (Meet, Zoom, Teams), "
                + "scrivi in italiano massimo 3 righe: chi sta parlando, cosa sta dicendo di importante, ed eventuali "
                + "azioni o scadenze citate. Se non c'e' nessuna riunione visibile, rispondi solo NOTHING.")
        try? FileManager.default.removeItem(at: immagine)
        let pulito = visto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pulito.isEmpty, pulito.uppercased().contains("NOTHING") == false else { return }

        let riga = "- \(ora()) \(pulito.replacingOccurrences(of: "\n", with: " · "))\n"
        if let maniglia = try? FileHandle(forWritingTo: Riunione.fileDiOggi) {
            maniglia.seekToEndOfFile()
            maniglia.write(riga.data(using: .utf8)!)
            try? maniglia.close()
        }
        JarvisCore.shared.notaSenzaVoce("Riunione: \(pulito.prefix(300))")
    }
}

extension Tools {
    /// Dal filo degli strumenti (non isolato) si passa al main actor con una
    /// continuazione: il semaforo blocca tutto in modalita' terminale, questa no.
    static func riunioneSkill(_ args: [String: Any]) async -> String {
        await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            Task { @MainActor in c.resume(returning: Tools.riunioneSuMain(args)) }
        }
    }

    @MainActor private static func riunioneSuMain(_ args: [String: Any]) -> String {
        let a = { (k: String) -> String in (args[k] as? String) ?? "" }
        switch a("azione") {
        case "accendi": return Riunione.shared.accendi()
        case "spegni": return Riunione.shared.spegni()
        case "stato": return Riunione.shared.stato
        case "nota":
            guard a("testo").count > 3 else { return "Dimmi cosa devo annotare." }
            return Riunione.shared.punta(a("testo"))
        case "riepilogo":
            let testo = ((try? String(contentsOf: Riunione.fileDiOggi, encoding: .utf8)) ?? "")
            guard !testo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "Non ho ancora appunti di questa riunione."
            }
            return testo
        default:
            return "Azioni: accendi, spegni, stato, nota (con testo), riepilogo."
        }
    }
}
