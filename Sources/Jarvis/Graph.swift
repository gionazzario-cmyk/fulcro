import Foundation

/// Mail dell'utente via Microsoft Graph, con il login a codice.
///
/// Perche' cosi': le password "app" di Microsoft non esistono piu' e Outlook sul Mac
/// non ha nessuna casella, quindi l'unico modo per leggere e spedire senza toccare
/// la sua password e il device code: Jarvis mostra un codice corto, l'utente lo
/// digita su microsoft.com/link da telefono, e il token resta su questo Mac.
/// La password non passa mai di qui.
///
/// Il token viene rinfrescato da solo: una volta che ha fatto il login, funziona
/// anche nei giorni dopo.
enum Graph {
    /// Client pubblico di Microsoft (quello usato dagli strumenti a riga di comando):
    /// non e' una credenziale, e' un identificatore. Se il tenant della scuola lo
    /// blocca, la risposta di `accedi` lo dice chiaro e si passa alla lettura dal browser.
    static let clientId = "d3590ed6-52b1-4ae8-9f46-76f4dbd60c47"
    static let scope = "Mail.Read Mail.Send offline_access User.Read"
    static var tokenFile: URL { AppPaths.jarvisRoot.appendingPathComponent("graph.token") }

    struct Token {
        var accesso: String
        var rinfresco: String
        var scadenza: Date
    }

    private static func salva(_ token: Token) {
        let dizionario: [String: Any] = [
            "accesso": token.accesso, "rinfresco": token.rinfresco,
            "scadenza": token.scadenza.timeIntervalSince1970
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dizionario) else { return }
        do {
            try data.write(to: tokenFile, options: .atomic)
            // il token vale quanto la sua casella di posta: leggibile solo da lui
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
        } catch { }
    }

    static func letto() -> Token? {
        guard let data = try? Data(contentsOf: tokenFile),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let a = d["accesso"] as? String, let r = d["rinfresco"] as? String,
              let s = d["scadenza"] as? Double else { return nil }
        return Token(accesso: a, rinfresco: r, scadenza: Date(timeIntervalSince1970: s))
    }

    static func disconnetti() -> String {
        try? FileManager.default.removeItem(at: tokenFile)
        return "Login Microsoft tolto: il token non e' piu' su questo Mac."
    }

    // MARK: - accesso a codice

    /// Chiede il codice. l'utente lo digita su microsoft.com/link: qui non arriva mai la password.
    static func richiediCodice() async -> String {
        guard let url = URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/devicecode") else {
            return "Indirizzo di login non valido."
        }
        let corpo = "client_id=\(clientId)&scope=\(scope.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = corpo.data(using: .utf8)
        req.timeoutInterval = 25
        guard let (dati, risposta) = try? await URLSession.shared.data(for: req),
              (risposta as? HTTPURLResponse)?.statusCode == 200,
              let d = try? JSONSerialization.jsonObject(with: dati) as? [String: Any],
              let codice = d["user_code"] as? String,
              let verifica = d["verification_uri"] as? String,
              let device = d["device_code"] as? String else {
            return "Microsoft non mi da un codice di login adesso. Puo' essere il filtro della scuola: in quel caso la mail la leggo dal browser."
        }
        // il device_code serve dopo per il polling: lo teniamo in memoria
        inCorso = (device, Int(d["interval"] as? String ?? "5") ?? 5, Date())
        inCorsoScadenza = Date().addingTimeInterval(Double(d["expires_in"] as? Int ?? 900))
        return "VAI SU \(verifica) E DIGITA \(codice) — il codice scade tra 15 minuti. Quando l'hai messo, dimmi «ho fatto il login» che finisco da solo."
    }

    private static var inCorso: (device: String, ogniSecondi: Int, iniziato: Date)?
    private static var inCorsoScadenza = Date.distantPast

    /// Controlla se l'utente ha completato il login: chiama questa dopo che ha digitato il codice.
    static func completaAccesso() async -> String {
        guard let (device, _, _) = inCorso, Date() < inCorsoScadenza else {
            if letto() != nil { return "Sei gia' collegato a Microsoft: la mail funziona." }
            return "Non c'e' nessuna richiesta di login aperta: dimmi «accedi alla mail» e ti do il codice."
        }
        let corpo = "client_id=\(clientId)&grant_type=device_code&code=\(device)"
        guard let url = URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token") else {
            return "Indirizzo di login non valido."
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = corpo.data(using: .utf8)
        req.timeoutInterval = 25
        guard let (dati, _) = try? await URLSession.shared.data(for: req),
              let d = try? JSONSerialization.jsonObject(with: dati) as? [String: Any] else {
            return "Non riesco a parlare con Microsoft adesso: riprova tra un minuto."
        }
        if let errore = d["error"] as? String {
            if errore == "authorization_pending" {
                return "Aspetto ancora: devi digitare il codice su microsoft.com/link. Poi dimmi «ho fatto il login»."
            }
            if errore == "expired_token" {
                inCorso = nil
                return "Il codice e' scaduto: te ne do uno nuovo, dimmi «accedi alla mail»."
            }
            inCorso = nil
            return "Microsoft ha detto di no (\(errore)): probabilmente il tenant della scuola non lascia passare questo accesso. Posso leggere la mail dallo schermo, come faccio con ClasseViva."
        }
        guard let accesso = d["access_token"] as? String,
              let rinfresco = d["refresh_token"] as? String else {
            inCorso = nil
            return "Login finito ma Microsoft non mi ha dato il token: riprova."
        }
        salva(Token(accesso: accesso, rinfresco: rinfresco,
                    scadenza: Date().addingTimeInterval(Double(d["expires_in"] as? Int ?? 3600))))
        inCorso = nil
        return "Collegato. Ora leggo e spedisco la tua mail."
    }

    // MARK: - token ancora valido

    /// Token valido (lo rinfresca da solo se sta per scadere).
    static func tokenUsabile() async -> String? {
        guard let t = letto() else { return nil }
        if t.scadenza.timeIntervalSinceNow > 120 { return t.accesso }
        guard let nuovo = await rinnewa(t.rinfresco) else {
            try? FileManager.default.removeItem(at: tokenFile)
            return nil
        }
        salva(nuovo)
        return nuovo.accesso
    }

    private static func rinnewa(_ rinfresco: String) async -> Token? {
        let corpo = "client_id=\(clientId)&grant_type=refresh_token&refresh_token=\(rinfresco)"
        guard let url = URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = corpo.data(using: .utf8)
        req.timeoutInterval = 25
        guard let (dati, risposta) = try? await URLSession.shared.data(for: req),
              (risposta as? HTTPURLResponse)?.statusCode == 200,
              let d = try? JSONSerialization.jsonObject(with: dati) as? [String: Any],
              let accesso = d["access_token"] as? String,
              let r = d["refresh_token"] as? String else { return nil }
        return Token(accesso: accesso, rinfresco: r,
                     scadenza: Date().addingTimeInterval(Double(d["expires_in"] as? Int ?? 3600)))
    }

    // MARK: - leggere e scrivere

    static func nonLette(limit: Int = 10) async -> String {
        guard let token = await tokenUsabile() else {
            return "Non sei ancora collegato a Microsoft: dimmi «accedi alla mail» e ti do il codice da digitare."
        }
        let url = "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages?$filter=isRead%20eq%20false&$top=\(max(1, min(limit, 25)))&$select=from,subject,receivedBodyPreview,isRead,receivedDateTime"
        guard let dati = await chiGet(url, token) else {
            return "Microsoft non risponde: riprova tra un momento."
        }
        guard let d = try? JSONSerialization.jsonObject(with: dati) as? [String: Any],
              let valori = d["value"] as? [[String: Any]], !valori.isEmpty else {
            return "Nessuna mail non letta."
        }
        var righe: [String] = []
        for (n, m) in valori.enumerated() {
            let oggetto = (m["subject"] as? String) ?? "senza oggetto"
            let mittente = ((m["from"] as? [String: Any])?["emailAddress"] as? [String: Any])?["address"] as? String ?? "?"
            let quando = (m["receivedDateTime"] as? String) ?? ""
            let stralcio = ((m["receivedBodyPreview"] as? String) ?? "").prefix(160)
            righe.append("\(n + 1). \(quando) · \(mittente) · \(oggetto)\n   \(stralcio)")
        }
        return "\(valori.count) mail non lette:\n" + righe.joined(separator: "\n")
    }

    static func corpo(_ id: Int) async -> String {
        guard let token = await tokenUsabile() else { return "Non sei collegato a Microsoft." }
        let elenco = await chiGet("https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages?$filter=isRead%20eq%20false&$top=25&$select=id,subject,bodyPreview,from", token)
        guard let dati = elenco,
              let d = try? JSONSerialization.jsonObject(with: dati) as? [String: Any],
              let valori = d["value"] as? [[String: Any]],
              id >= 1, id <= valori.count else { return "Non ho quella mail li'." }
        let m = valori[id - 1]
        let oggetto = (m["subject"] as? String) ?? ""
        let corpo = (m["bodyPreview"] as? String) ?? ""
        return "\(oggetto)\n\n\(corpo)"
    }

    static func scrivi(a: String, oggetto: String, testo: String, invio: Bool) async -> String {
        guard invio else { return "Posso solo spedire davvero: se vuoi solo leggerla te la mostro e mi dici «manda»." }
        guard !a.isEmpty, !testo.isEmpty else { return "Dimmi a chi e cosa." }
        guard let token = await tokenUsabile() else {
            return "Non sei collegato a Microsoft: dimmi «accedi alla mail» e ti do il codice."
        }
        let corpo: [String: Any] = [
            "message": [
                "subject": oggetto,
                "body": ["contentType": "Text", "content": testo],
                "toRecipients": [["emailAddress": ["address": a]]]
            ],
            "saveToSentItems": true
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: corpo) else { return "Non riesco a preparare la mail." }
        let (codice, risposta) = await chiPost("https://graph.microsoft.com/v1.0/me/sendMail", token, data)
        if codice == 202 || codice == 200 { return "Mail a \(a) spedita." }
        return "Microsoft non l'ha mandata (\(codice)): \(String(risposta.prefix(220)))"
    }

    // MARK: - HTTP

    private static func chiGet(_ stringa: String, _ token: String) async -> Data? {
        guard let url = URL(string: stringa) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 25
        guard let (dati, risposta) = try? await URLSession.shared.data(for: req),
              (risposta as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return dati
    }

    private static func chiPost(_ stringa: String, _ token: String, _ corpo: Data) async -> (Int, String) {
        guard let url = URL(string: stringa) else { return (-1, "indirizzo invalido") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = corpo
        req.timeoutInterval = 25
        guard let (dati, risposta) = try? await URLSession.shared.data(for: req) else { return (-1, "nessuna risposta") }
        let codice = (risposta as? HTTPURLResponse)?.statusCode ?? -1
        return (codice, String(decoding: dati, as: UTF8.self))
    }

    static func stato() -> String {
        guard let t = letto() else { return "Non collegato a Microsoft: dimmi «accedi alla mail»." }
        let valido = t.scadenza.timeIntervalSinceNow > 0
        return "Collegato a Microsoft (\(valido ? "token valido" : "token da rinnovare, lo faccio da solo"))."
    }
}
