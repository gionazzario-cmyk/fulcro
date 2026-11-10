import AVFoundation
import Foundation

/// Registra dal microfono e scrive un WAV mono: sono i dati che guarda whisper.cpp.
final class Mic {
    static let shared = Mic()

    private let engine = AVAudioEngine()
    private var samples: [Int16] = []
    private let lock = NSLock()
    private var rate: Double = 48_000
    private var installed = false
    private(set) var isRunning = false
    var level: Double = 0

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start() -> String? {
        let input = engine.inputNode
        let fmt = input.inputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { return "Nessun microfono trovato." }
        rate = fmt.sampleRate
        lock.withLock { samples = [] }
        level = 0
        if !installed {
            input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
                self?.ingest(buf)
            }
            installed = true
        }
        engine.prepare()
        do { try engine.start() } catch { return "Microfono non disponibile: \(error.localizedDescription)" }
        isRunning = true
        return nil
    }

    private func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let ch = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let mixCount = min(ch, 2)
        var chunk = [Int16]()
        chunk.reserveCapacity(frames)
        var peak: Float = 0
        for i in 0..<frames {
            var sum: Float = 0
            for c in 0..<mixCount { sum += data[c][i] }
            let mono = sum / Float(mixCount)
            peak = max(peak, abs(mono))
            chunk.append(Int16(max(-32_768, min(32_767, mono * 32_767))))
        }
        lock.withLock { samples.append(contentsOf: chunk) }
        level = Double(peak)
    }

    /// Ferma la registrazione e restituisce il file WAV (o nil se non hai detto niente).
    func finish() -> URL? {
        guard isRunning else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        installed = false
        engine.stop()
        isRunning = false
        level = 0
        let captured = lock.withLock { () -> [Int16] in
            let copy = samples
            samples = []
            return copy
        }
        guard captured.count > Int(rate * 0.25) else { return nil }
        let url = AppPaths.tmp.appendingPathComponent("presa-\(Int(Date().timeIntervalSince1970)).wav")
        return Mic.writeWav(captured, sampleRate: rate, to: url) ? url : nil
    }

    private static func writeWav(_ samples: [Int16], sampleRate: Double, to url: URL) -> Bool {
        let channels = 1
        let bits = 16
        let hz = UInt32(sampleRate)
        let sampleBytes = UInt32(samples.count * 2)
        var data = Data(capacity: Int(sampleBytes) + 44)

        func ascii(_ s: String) { data.append(contentsOf: s.utf8) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        ascii("RIFF"); u32(36 + sampleBytes); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(UInt16(channels))
        u32(hz); u32(hz * UInt32(channels * bits / 8)); u16(UInt16(channels * bits / 8)); u16(UInt16(bits))
        ascii("data"); u32(sampleBytes)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return FileManager.default.createFile(atPath: url.path, contents: data)
    }
}

/// whisper.cpp in locale: la tua voce diventa testo senza mandarla da nessuna parte.
enum STT {
    static var isReady: Bool {
        AppPaths.whisperBinary != nil && FileManager.default.fileExists(atPath: AppPaths.whisperModel.path)
    }

    /// Un errore dell'ascolto non e' una frase da attribuire all'utente: prima
    /// `transcribe` restituiva stringhe ("whisper-cli non installato…", "Fallito: …")
    /// e il chiamante le trattava come trascrizione, mandandole al modello come se
    /// le avesse dette lui. Ora l'errore e' un errore.
    struct ErroreAscolto: Error { let messaggio: String }

    static func transcribe(_ wav: URL) async -> Result<String, ErroreAscolto> {
        guard let bin = AppPaths.whisperBinary else {
            return .failure(ErroreAscolto(messaggio: "whisper-cli non installato: run brew install whisper-cpp"))
        }
        guard FileManager.default.fileExists(atPath: AppPaths.whisperModel.path) else {
            return .failure(ErroreAscolto(messaggio: "Manca il modello di ascolto in \(AppPaths.whisperModel.path)"))
        }
        let args = ["-m", AppPaths.whisperModel.path, "-f", wav.path, "-l", "it", "-nt", "-np", "-t", "6"]
        let out = await Shell.run(bin, args)
        let text = out.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("whisper_") && !$0.hasPrefix("load_model") }
            .joined(separator: " ")
            .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
            .replacingOccurrences(of: "(capita)", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(text)
    }
}

/// Voce italiana del Mac, con interruzione quando ricominci a parlare.
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()
    private let synth = AVSpeechSynthesizer()
    private var chosen: AVSpeechSynthesisVoice?

    override init() {
        super.init()
        synth.delegate = self
        let all = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("it") }
        chosen = all.first { $0.name.contains("Alice") && $0.quality != .default }
            ?? all.first { $0.name.contains("Alice") }
            ?? all.first { $0.quality == .enhanced }
            ?? all.first
    }

    var voiceName: String {
        Speaker.piperPronto
            ? AppPaths.capitalizza(AppPaths.voceCorrente) + " (neurale)"
            : (chosen?.name ?? "nessuna voce italiana")
    }
    var isSpeaking: Bool { synth.isSpeaking || audioProc != nil || !coda.isEmpty || parlo }

    // MARK: - la coda (parlare sulla prima frase, non sull'ultima)

    /// Le frasi che `JarvisCore` butta dentro man mano che il modello le scrive.
    /// Si dicono una dopo l'altra: la seconda parte mentre la terza ancora non esiste.
    private var coda: [String] = []
    /// Vero dalla prima sillaba detta all'ultima: senza questo, `scarica()` ne
    /// avvrebbe due insieme e si taglierebbero a vicenda.
    private var parlo = false

    /// Aggiungi frasi senza interrompere quello che sta già uscendo.
    func incoda(_ frasi: [String]) {
        let pulite = frasi.map { Self.pronunciabile($0) }.filter { !$0.isEmpty }
        guard !pulite.isEmpty else { return }
        coda.append(contentsOf: pulite)
        scarica()
    }

    private func scarica() {
        guard !parlo, !coda.isEmpty else { return }
        parlo = true
        diFrase(coda.removeFirst())
    }

    /// Una frase sola, senza passare dalla coda: la usa `say()` e la coda stessa.
    private func diFrase(_ testo: String) {
        if Speaker.piperPronto { diConPiper(testo); return }
        guard let chosen else { coda.removeAll(); parlo = false; return }
        let u = AVSpeechUtterance(string: testo)
        u.voice = chosen
        u.rate = 0.5
        u.volume = 1
        synth.speak(u)
    }

    /// Quanto ci mette la voce neurale a preparare una frase (secondi, senza
    /// riprodurla): il numero che serve per dire "quanto aspetti prima di sentire
    /// la prima parola", e che nessuno dei Jarvis in giro pubblica.
    static func tempoDiSintesi(_ frase: String) async -> Double? {
        guard piperPronto, let py = Tools.python else { return nil }
        let base = AppPaths.tmp.appendingPathComponent("cronometro-voce-\(Int(Date().timeIntervalSince1970 * 1000))")
        let txt = base.appendingPathExtension("txt")
        let wav = base.appendingPathExtension("wav")
        do { try frase.write(to: txt, atomically: true, encoding: .utf8) } catch { return nil }
        defer { try? FileManager.default.removeItem(at: txt); try? FileManager.default.removeItem(at: wav) }
        let t0 = Date()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", """
        '\(py)' -m piper -m '\(AppPaths.piperVoce.path)' -i '\(txt.path)' -f '\(wav.path)' \
        --length-scale 1.02 --noise-scale 0.5 --noise-w 0.6 --sentence-silence 0.32 >/dev/null 2>&1
        """]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { p.waitUntilExit(); c.resume() }
        }
        guard p.terminationStatus == 0 else { return nil }
        return Date().timeIntervalSince(t0)
    }

    /// Voce neurale piper: molto meno metallica di quella di sistema.
    /// Il controllo vero si fa in background all'avvio: provarlo sul main thread
    /// bloccava l'app (deadlock di libdispatch).
    static private(set) var piperPronto = false

    static func verificaPiper() {
        guard let py = Tools.python,
              FileManager.default.fileExists(atPath: AppPaths.piperVoce.path) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: py)
        p.arguments = ["-c", "import piper"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return }
        p.waitUntilExit()
        if p.terminationStatus == 0 { piperPronto = true }
    }

    private var audioProc: Process?

    func say(_ raw: String) {
        let text = Self.speakable(raw)
        guard !text.isEmpty else { return }
        stop()                       // una cosa detta a metà non deve restare in coda
        coda = [text]
        scarica()
    }

    private func diConPiper(_ testo: String) {
        guard let py = Tools.python else { return }
        let base = AppPaths.tmp.appendingPathComponent("voce-\(Int(Date().timeIntervalSince1970))")
        let txt = base.appendingPathExtension("txt")
        let wav = base.appendingPathExtension("wav")
        do { try testo.write(to: txt, atomically: true, encoding: .utf8) } catch { return }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // i percorsi sono nostri e fra apici: il testo passa da un file, non dalla riga di comando
        p.arguments = ["-c", """
        '\(py)' -m piper -m '\(AppPaths.piperVoce.path)' -i '\(txt.path)' -f '\(wav.path)' \
        --length-scale 1.02 --noise-scale 0.5 --noise-w 0.6 --sentence-silence 0.32 >/dev/null 2>&1 && afplay '\(wav.path)'
        """]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return }
        audioProc = p
        DispatchQueue.global().async {
            p.waitUntilExit()
            DispatchQueue.main.async {
                if self.audioProc === p { self.audioProc = nil }
                self.parlo = false
                self.scarica()               // la frase dopo, se il modello l'ha gia' scritta
            }
            try? FileManager.default.removeItem(at: txt)
            try? FileManager.default.removeItem(at: wav)
        }
    }

    /// Fine (o interruzione) della voce di sistema: la coda prosegue da qui.
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        parlo = false
        scarica()
    }

    /// `stop()` manda `didCancel`: se non si ripulisce anche qui, la coda resta ferma
    /// per sempre con `parlo` vero e Jarvis non parla piu' per tutto il resto
    /// della sessione (errore che si paga con un "non si sente niente" alle 2 di notte).
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        parlo = false
    }

    func stop() {
        coda.removeAll()
        parlo = false
        synth.stopSpeaking(at: .immediate)
        audioProc?.terminate()
        audioProc = nil
    }

    /// Togli codice, markdown e URL: non ha senso leggerli ad alta voce.
    private static func speakable(_ raw: String) -> String {
        let t = pulitoPerLaVoce(raw)
        let sentences = t.split(whereSeparator: { ".!?".contains($0) })
        return String(sentences.prefix(6).joined(separator: ". "))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Una frase della coda: pulita come sopra, ma **senza** il tetto delle sei frasi
    /// (che ha senso su una risposta intera, non su un pezzo: sei pezzi non sono sei
    /// frasi). E con il punto finale, perche' piper chiude male una frase monca.
    static func pronunciabile(_ raw: String) -> String {
        var t = pulitoPerLaVoce(raw)
        if let last = t.last, !".!?".contains(last) { t += "." }
        return t
    }

    private static func pulitoPerLaVoce(_ raw: String) -> String {
        var t = stripCode(raw)
        t = t.replacingOccurrences(of: "[*_#`>|]", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "https?://\\S+", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "[\\u{1F300}-\\u{1FAFF}\\u{2600}-\\u{27BF}\\u{FE0F}\\u{200D}]",
                                   with: "", options: .regularExpression)
        t = normalizzaItaliano(t)
        t = t.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Simboli e numeri che piper legge male, riscritti come li direbbe una persona.
    static func normalizzaItaliano(_ t: String) -> String {
        var s = t
        let sostituzioni: [(String, String)] = [
            ("°C", " gradi"), ("°F", " gradi fahrenheit"), ("°", " gradi"),
            ("%", " per cento"), ("€", " euro"), ("$", " dollari"),
            ("km/h", " chilometri all'ora"), ("GHz", " giga hertz"), ("MHz", " mega hertz"),
            ("GB", " giga"), ("MB", " mega"), ("RAM", " mem"),
            ("⌥", " option "), ("⌘", " command "), ("→", " , "), ("·", " , "),
            ("•", " , "), ("—", " , "), ("–", " "), ("~", " circa "), ("&", " e ")
        ]
        for (da, a) in sostituzioni { s = s.replacingOccurrences(of: da, with: a) }
        s = dateItaliane(in: s)
        // "esercizi 14-18": senza questa sostituzione il trattino diventa "meno"
        s = s.replacingOccurrences(of: #"\b(\d{1,3})-(\d{1,3})\b"#, with: "dal $1 al $2",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: "\n", with: ". ")
        s = s.replacingOccurrences(of: #"(?m)^\s*\d+[).\]]\s*"#, with: "", options: .regularExpression)
        return s
    }

    /// "2026-10-20" -> "20 ottobre 2026": cosi' piper non la spara cifra per cifra.
    private static let mesiItaliani = ["gennaio", "febbraio", "marzo", "aprile", "maggio", "giugno",
                                       "luglio", "agosto", "settembre", "ottobre", "novembre", "dicembre"]

    private static func dateItaliane(in testo: String) -> String {
        var out = testo
        guard let re = try? NSRegularExpression(pattern: #"(\d{4})-(\d{1,2})-(\d{1,2})"#) else { return out }
        let r = NSRange(out.startIndex..., in: out)
        var sostituzioni: [(NSRange, String)] = []
        for m in re.matches(in: out, range: r) {
            guard let a = Range(m.range(at: 1), in: out),
                  let mm = Int(out[Range(m.range(at: 2), in: out)!]),
                  let gg = Int(out[Range(m.range(at: 3), in: out)!]) else { continue }
            let nome = (1...12).contains(mm) ? mesiItaliani[mm - 1] : ""
            sostituzioni.append((m.range, "\(gg) \(nome) \(out[a])"))
        }
        for (range, testo) in sostituzioni.reversed() {
            if let r = Range(range, in: out) { out.replaceSubrange(r, with: testo) }
        }
        return out
    }

    private static func stripCode(_ t: String) -> String {
        var keep: [String] = []
        var inside = false
        for line in t.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") { inside.toggle(); continue }
            if !inside { keep.append(String(line)) }
        }
        return keep.joined(separator: " ")
    }
}

// Jarvis la usa sempre dal main thread: il marker toglie l'alert su AVSpeechSynthesizer.
extension Speaker: @unchecked Sendable {}

enum Shell {
    /// Esegue un programma e dice COSA HA DETTO, sempre. Due regole imparate il
    /// 2026-10-20: (1) un'uscita diversa da zero non e' un errore di whisper, e' il
    /// programma che ha spiegato il perche' sullo stdout — il ponte della Bambu fa
    /// proprio cosi' (esce 1 e scrive il motivo), e con la vecchia versione l'utente
    /// si sentiva "whisper e' uscito con codice 1" al posto della diagnosi;
    /// (2) gli_pipe vanno svuotati mentre il processo gira, perche' un output piu'
    /// grande del buffer (64 KB) lo blocca li' per sempre.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 40) async -> String {
        await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do { try p.run() } catch { c.resume(returning: "Errore: \(error.localizedDescription)"); return }
                let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

                let gruppo = DispatchGroup()
                let lucchetto = NSLock()
                var datoUscita = Data(), datoErrore = Data()
                gruppo.enter()
                DispatchQueue.global().async {
                    let d = out.fileHandleForReading.readDataToEndOfFile()
                    lucchetto.lock(); datoUscita = d; lucchetto.unlock()
                    gruppo.leave()
                }
                gruppo.enter()
                DispatchQueue.global().async {
                    let d = err.fileHandleForReading.readDataToEndOfFile()
                    lucchetto.lock(); datoErrore = d; lucchetto.unlock()
                    gruppo.leave()
                }
                p.waitUntilExit()
                timer.cancel()
                gruppo.wait()

                let o = String(data: datoUscita, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let e = String(data: datoErrore, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if p.terminationStatus != 0 {
                    let spiegato = [o, e].filter { !$0.isEmpty }.joined(separator: "\n")
                    c.resume(returning: spiegato.isEmpty
                        ? "Il comando e' finito male (codice \(p.terminationStatus)) e non ha detto perche'."
                        : spiegato)
                } else {
                    c.resume(returning: o)
                }
            }
        }
    }
}
