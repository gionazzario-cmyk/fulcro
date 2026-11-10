import Foundation
import Network

/// Piccolo server HTTP per la chat dall'iPad. Gira solo sulla rete di casa
/// e chiede il PIN che il pannello di Jarvis mostra.
final class JarvisWeb {
    static let shared = JarvisWeb()

    let port: UInt16 = 8732
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "jarvis.web", attributes: .concurrent)
    private let agent = Agent()
    private let busyLock = NSLock()
    private var busy = false
    private(set) var running = false

    private init() {}

    // MARK: - PIN

    private let pinLock = NSLock()
    private var tentativiSbagliati = 0
    private var bloccatoFino = Date.distantPast

    /// Confronto a tempo costante: `==` esce al primo carattere diverso e il tempo
    /// racconta quanti caratteri erano giusti. Su una rete di casa conta poco, ma
    /// costa due righe e toglie il canale.
    private func pinCorretto(_ dato: String) -> Bool {
        let atteso = Array(pin.utf8), ricevuto = Array(dato.utf8)
        guard atteso.count == ricevuto.count, !atteso.isEmpty else { return false }
        var diverso: UInt8 = 0
        for i in 0..<atteso.count { diverso |= atteso[i] ^ ricevuto[i] }
        return diverso == 0
    }

    /// Sei caratteri si provano tutti in un pomeriggio con un ciclo di curl: dopo
    /// cinque errori il PIN si blocca per un minuto.
    private func pinAccettato(_ dato: String) -> Bool {
        pinLock.lock()
        defer { pinLock.unlock() }
        if Date() < bloccatoFino { return false }
        guard pinCorretto(dato) else {
            tentativiSbagliati += 1
            if tentativiSbagliati >= 5 {
                tentativiSbagliati = 0
                bloccatoFino = Date().addingTimeInterval(60)
                NSLog("\(Marca.nome) web: troppi PIN sbagliati, bloccato per un minuto")
            }
            return false
        }
        tentativiSbagliati = 0
        return true
    }

    var pin: String {
        let f = AppPaths.jarvisRoot.appendingPathComponent("webpin")
        if let saved = try? String(contentsOf: f, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           saved.count >= 4 { return saved }
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let made = String((0..<6).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
        try? made.write(to: f, atomically: true, encoding: .utf8)
        return made
    }

    var address: String { "http://\(Self.lanIP()):\(port)/" }

    func start() {
        guard listener == nil else { return }
        do {
            let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            l.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.running = true
                case .failed, .cancelled: self?.running = false
                default: break
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            NSLog("\(Marca.nome) web: %@", error.localizedDescription)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
    }

    // MARK: - HTTP

    private func serve(_ conn: NWConnection) {
        conn.start(queue: queue)
        read(conn, buffer: Data())
    }

    private func read(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if error != nil || (isComplete && buf.isEmpty) { conn.cancel(); return }

            guard let text = String(data: buf, encoding: .utf8),
                  let headerEnd = text.range(of: "\r\n\r\n") else {
                if buf.count < 200_000 { self.read(conn, buffer: buf) } else { conn.cancel() }
                return
            }
            let head = String(text[..<headerEnd.lowerBound])
            let body = String(text[headerEnd.upperBound...])
            let lines = head.split(separator: "\r\n").map(String.init)
            guard let requestLine = lines.first else { conn.cancel(); return }
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2 else { conn.cancel(); return }
            let method = String(parts[0])
            let target = String(parts[1])
            // `uniqueKeysWithValues` e' un trap: due header con lo stesso nome (basta
            // un curl sulla LAN) facevano schiantare l'app. Con `uniquingKeysWith`
            // vince il primo e la richiesta prosegue.
            let headers = Dictionary(lines.dropFirst().compactMap { line -> (String, String)? in
                guard let i = line.firstIndex(of: ":") else { return nil }
                return (String(line[..<i]).lowercased(), String(line[line.index(after: i)...]).trimmingCharacters(in: .whitespaces))
            }, uniquingKeysWith: { primo, _ in primo })
            let needBody = (Int(headers["content-length"] ?? "") ?? 0) > body.count
            if needBody { self.read(conn, buffer: buf); return }

            self.route(conn, method: method, target: target, headers: headers, body: body)
        }
    }

    private func route(_ conn: NWConnection, method: String, target: String,
                       headers: [String: String], body: String) {
        let path = target.split(separator: "?").first.map(String.init) ?? target
        let sentPin = headers["x-jarvis-pin"] ?? ""

        switch (method, path) {
        case ("GET", "/"):
            send(conn, status: "200 OK", type: "text/html; charset=utf-8", body: WebPage.html)
        case ("GET", "/health"):
            // senza PIN non si conta il tentativo (la pagina lo interroga mentre si
            // apre); con un PIN sbagliato si conta, cosi' non diventa un oracolo.
            let ok = sentPin.isEmpty ? false : pinAccettato(sentPin)
            send(conn, status: "200 OK", type: "application/json",
                 body: "{\"ok\":true,\"nome\":\"\(Marca.nome)\",\"pin_ok\":\(ok)}")
        case ("POST", "/chat"):
            guard pinAccettato(sentPin) else {
                send(conn, status: "401 Unauthorized", type: "application/json",
                     body: "{\"errore\":\"pin sbagliato\"}")
                return
            }
            guard let data = body.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let testo = obj["testo"] as? String, !testo.trimmingCharacters(in: .whitespaces).isEmpty else {
                send(conn, status: "400 Bad Request", type: "application/json", body: "{\"errore\":\"manca testo\"}")
                return
            }
            ask(testo) { answer in
                let json = try? JSONSerialization.data(withJSONObject: ["risposta": answer])
                let payload = String(data: json ?? Data(), encoding: .utf8) ?? "{\"risposta\":\"\"}"
                self.send(conn, status: "200 OK", type: "application/json", body: payload)
            }
        default:
            send(conn, status: "404 Not Found", type: "text/plain; charset=utf-8", body: "non esiste")
        }
    }

    private func ask(_ testo: String, done: @escaping (String) -> Void) {
        busyLock.lock()
        if busy {
            busyLock.unlock()
            done("Sto gia' rispondendo a qualcos'altro: aspetta qualche secondo.")
            return
        }
        busy = true
        busyLock.unlock()

        Task {
            var final = ""
            await self.agent.ask(testo, source: "ipad",
                                 onDelta: { _ in },
                                 onNote: { line in NSLog("\(Marca.nome) web: %@", line) },
                                 onFinal: { answer in final = answer })
            NSLog("\(Marca.nome) web: risposta %@", String(final.prefix(120)))
            self.busyLock.lock()
            self.busy = false
            self.busyLock.unlock()
            done(final.isEmpty ? "Non sono riuscito a rispondere." : final)
        }
    }

    private func send(_ conn: NWConnection, status: String, type: String, body: String) {
        let data = Data(body.utf8)
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\n"
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(data)
        conn.send(content: payload, completion: .contentProcessed { _ in conn.cancel() })
    }

    static func lanIP() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
        p.arguments = ["getifaddr", "en0"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "127.0.0.1" }
        p.waitUntilExit()
        let ip = (String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ip.isEmpty ? "127.0.0.1" : ip
    }
}
