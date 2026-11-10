import SwiftUI
import AppKit

@main
struct JarvisApp: App {
    @ObservedObject private var core = JarvisCore.shared

    init() {
        SelfTest.runIfRequested()
    }

    var body: some Scene {
        Window("\(Marca.nome)", id: "finestra") {
            JarvisFinestra(core: core)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1080, height: 660)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Pulisci la chat") { JarvisCore.shared.clear() }
                    .keyboardShortcut("k", modifiers: .command)
            }
        }

        MenuBarExtra {
            JarvisPanel(core: core)
                .environmentObject(core)
                .preferredColorScheme(.dark)
        } label: {
            Image(systemName: core.listening ? "mic.fill" : (core.thinking ? "hourglass" : "atom"))
                .symbolEffect(.variableColor, isActive: core.thinking || core.listening)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Il gradiente firma: dal 2026-10-21 e' ciano olografico (#00f0ff), il colore del
/// design che ha portato l'utente. Il rosso resta solo dove vuol dire pericolo
/// (Olografico.allarme), perche' un bottone rosso che non e' un allarme e' rumore.
let jarvisGrad = LinearGradient(
    colors: [Color(red: 0.42, green: 0.96, blue: 1.0), Color(red: 0.0, green: 0.62, blue: 0.72)],
    startPoint: .topLeading, endPoint: .bottomTrailing)

/// Sfondo proprio: Jarvis resta scuro anche se il Mac e' in modalita' chiara.
/// Dal redesign olografico e' blu notte, non piu' il marrone del concept vecchio.
let pannelloScuro = LinearGradient(
    colors: [Olografico.notte, Olografico.notteProfonda],
    startPoint: .top, endPoint: .bottom)

struct JarvisPanel: View {
    @ObservedObject var core: JarvisCore
    @Environment(\.openWindow) private var openWindow
    @FocusState private var typing: Bool
    @State private var pulse = false
    /// Il pannello della barra dei menu esiste anche quando non lo apri: viene creato
    /// all'avvio e continua a rendersi. Parte `false`, e lo dice la finestra stessa.
    @State private var visibile = false

    /// I chip del pop-up: corti perche' a 400 px tre per fila ci stanno solo cosi'.
    /// L'icona nel tema olografico non serve: parla la scritta monospazio.
    private let chips: [(String, String)] = [
        ("GIORNATA", "la giornata"),
        ("COMPITI", "che compiti ho"),
        ("CLASSIFICA F1", "classifica piloti F1"),
        ("METEO", "Che tempo fa?")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            barraDiStato

            ZStack(alignment: .bottom) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(core.bubbles) { b in
                                BubbleView(bubble: b).id(b.id)
                            }
                        }
                        .padding(11)
                    }
                    .onChange(of: core.bubbles.count) { _, _ in
                        if let last = core.bubbles.last { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
                if core.bubbles.isEmpty { benvenuto }
            }
            .frame(height: core.bubbles.isEmpty ? 374 : 292)
            .caixa()

            if let cmd = core.pendingCommand {
                CardConferma(comando: cmd, motivo: "AVVISO DI SICUREZZA", pieno: true,
                             ok: { core.answer(true) }, no: { core.answer(false) })
            }

            input
            grigliaStato
            footer
        }
        .padding(13)
        .frame(width: 400)
        .background { Olografico.sfondo.clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)) }
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Olografico.bordo))
        .environment(\.colorScheme, .dark)
        .background(RilevatoreVisibilita { v in
            visibile = v
            core.pannelloInSchermo = v
            core.schermoCambiato()
        })
        .onAppear { typing = true }
        // Niente `repeatForever`: quella catena di animazione tiene su il ciclo di
        // Core Animation anche quando il microfono e' chiuso, ed e' stata la prima
        // causa del CPU a riposo. Qui il tasto si allarga quando si accende e torna
        // quando si spegne: il "respiro" lo fanno gia' gli anelli.
        .onChange(of: core.listening) { _, attivo in
            withAnimation(.easeOut(duration: 0.25)) { pulse = attivo }
        }
    }

    // MARK: - pezzi

    private var header: some View {
        HStack(spacing: 11) {
            SferaJarvis(diametro: 32, core: core, pausa: !visibile)
            VStack(alignment: .leading, spacing: 2) {
                Text(Marca.marchio).font(.system(size: 14, weight: .heavy, design: .monospaced)).tracking(3)
                    .foregroundStyle(Olografico.ciano)
                Text(core.headline).font(Olografico.corpo(9.5)).foregroundStyle(Olografico.testo.opacity(0.5)).lineLimit(1)
            }
            Spacer()
            Button { openWindow(id: "finestra") } label: {
                Image(systemName: "macwindow").font(.system(size: 12))
            }
            .buttonStyle(.plain).foregroundStyle(Olografico.ciano.opacity(0.75))
                .padding(6).overlay(Rectangle().stroke(Olografico.bordoTenue))
                .help("Apri la finestra grande")
        }
    }

    /// La riga STATUS / LINK / TEMPO del suo file, ma con i dati veri del Mac.
    private var barraDiStato: some View {
        HStack(spacing: 0) {
            VoceBarra(nome: "STATUS", valore: core.piano.sorveglianza
                      ? (core.headline.contains("spento") ? "PARZIALE" : "ONLINE")
                      : "SONNO",
                      umore: core.headline.contains("spento") ? .attenzione : .buono)
            VoceBarra(nome: "MOTORE", valore: pieno(core.diagnostica.motore), umore: letto(core.diagnostica.motore))
            Spacer(minLength: 6)
            VoceBarra(nome: "TEMPO", valore: orologio, umore: .buono).fixedSize()
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Olografico.notte.opacity(0.75))
        .overlay(Rectangle().stroke(Olografico.bordoTenue))
    }

    /// Taglia una scritta lunga senza spezzare le parole a meta'.
    static func corta(_ t: String, massimo: Int = 16) -> String {
        t.count <= massimo ? t : String(t.prefix(massimo - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Se la diagnostica non ha ancora letto il motore, la riga lo dice: niente trattini
    /// che sembrano un guasto quando e' solo il primo mezzo secondo.
    private func pieno(_ v: String) -> String {
        let t = v.trimmingCharacters(in: CharacterSet(charactersIn: " —–"))
        return t.isEmpty ? "LETTURA" : v.uppercased()
    }

    /// Finche' non ha letto niente la pill e' ambra: il verde deve voler dire
    /// "misurato", non "non lo so ancora".
    private func letto(_ v: String) -> Umore {
        v.trimmingCharacters(in: CharacterSet(charactersIn: " —–")).isEmpty ? .attenzione : .buono
    }

    private var orologio: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    /// La card di benvenuto: il reattore del suo file alla sua misura (160 px),
    /// il saluto, e i chip delle azioni che in questo momento hanno un perche' vero.
    private var benvenuto: some View {
        VStack(spacing: 12) {
            NucleoReattore(diametro: 160, attivo: core.thinking || core.listening,
                           pausa: !visibile || core.reattoreFermo)
            Text("Come posso aiutarti oggi, \(Identita.nome)?")
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(Olografico.testo).multilineTextAlignment(.center)
            Text("Scrivi un comando o tieni premuto ⌥ Spazio")
                .font(Olografico.corpo(11)).foregroundStyle(Olografico.testo.opacity(0.5))
                .multilineTextAlignment(.center).fixedSize()
            VStack(alignment: .center, spacing: 7) {
                HStack(spacing: 7) {
                    if core.suggerimenti.isEmpty {
                        ForEach(chips.prefix(3), id: \.0) { chip, testo in
                            ChipAzione(testo: chip) { core.draft = testo; core.sendTyped() }
                        }
                    } else {
                        ForEach(core.suggerimenti.prefix(3), id: \.chip) { s in
                            ChipAzione(testo: JarvisPanel.corta(s.chip)) { core.draft = s.frase; core.sendTyped() }
                                .help(s.perche)
                        }
                    }
                }
                HStack(spacing: 7) {
                    if core.suggerimenti.isEmpty {
                        ForEach(chips.dropFirst(3), id: \.0) { chip, testo in
                            ChipAzione(testo: chip) { core.draft = testo; core.sendTyped() }
                        }
                    } else {
                        ForEach(core.suggerimenti.dropFirst(3).prefix(3), id: \.chip) { s in
                            ChipAzione(testo: JarvisPanel.corta(s.chip)) { core.draft = s.frase; core.sendTyped() }
                                .help(s.perche)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .pannelloOlo()
    }

    /// La `.input-area` del suo file: campo con il bordo proprio e il pulsante INVIA
    /// accanto, entrambi quadri, entrambi che si accendono quando serve.
    private var input: some View {
        HStack(spacing: 9) {
            Button { core.toggleTalk() } label: {
                Image(systemName: core.listening ? "stop.fill" : "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(core.listening ? .white : Olografico.ciano)
                    .frame(width: 34, height: 34)
                    .background(core.listening ? AnyShapeStyle(Olografico.allarme.opacity(0.9)) : AnyShapeStyle(Olografico.riempimento))
                    .overlay(Rectangle().stroke(core.listening ? Olografico.allarme : Olografico.bordo))
                    .scaleEffect(core.listening && pulse ? 1.05 : 1)
            }
            .buttonStyle(.plain).help("⌥ Spazio per parlare")

            VStack(spacing: 3) {
                TextField("Immetti comando per JARVIS…", text: $core.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Olografico.corpo(12.5)).foregroundStyle(.white)
                    .focused($typing).lineLimit(1...3).onSubmit { core.sendTyped() }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Olografico.ciano.opacity(typing ? 0.07 : 0.05))
                    .overlay(Rectangle().stroke(typing ? Olografico.ciano : Olografico.bordo))
                    .shadow(color: Olografico.alone.opacity(typing ? 0.9 : 0), radius: 5)
                if core.listening {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Olografico.ciano.opacity(0.10))
                            Rectangle().fill(Olografico.ciano)
                                .frame(width: max(3, g.size.width * min(1, core.micLevel * 4)))
                                .shadow(color: Olografico.ciano.opacity(0.9), radius: 4)
                        }
                    }.frame(height: 3)
                    .overlay(Rectangle().stroke(Olografico.bordoTenue))
                }
            }

            Button { core.sendTyped() } label: {
                Text("INVIA")
                    .font(Olografico.micro(11)).tracking(1.4)
                    .foregroundStyle(puoInviare ? Olografico.notte : Olografico.ciano.opacity(0.35))
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(puoInviare ? AnyShapeStyle(Olografico.ciano) : AnyShapeStyle(Olografico.bordoSfumato))
                    .overlay(Rectangle().stroke(Olografico.ciano.opacity(puoInviare ? 1 : 0.35)))
            }
            .buttonStyle(.plain)
            .disabled(core.busy || !puoInviare)
            .shadow(color: Olografico.alone.opacity(puoInviare ? 1 : 0), radius: 8)
        }
    }

    private var puoInviare: Bool {
        !core.draft.trimmingCharacters(in: .whitespaces).isEmpty || core.listening
    }

    /// Le pill 2x2 di stato, prese dal suo concept.
    private var grigliaStato: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            PillStato(etichetta: "Schermo", valore: Capacita.schermo ? "Attivo" : "Negato", acceso: Capacita.schermo)
            PillStato(etichetta: "Microfono", valore: Capacita.microfono ? "Pronto" : "Negato", acceso: Capacita.microfono)
            PillStato(etichetta: "Voce neurale", valore: Speaker.piperPronto ? "Online" : "Assente", acceso: Speaker.piperPronto)
            PillStato(etichetta: "Ollama", valore: core.headline.contains("Ollama spento") ? "Spento" : "Attivo",
                      acceso: !core.headline.contains("Ollama spento"))
            PillStato(etichetta: "Alimentazione", valore: Alimentazione.inCarica ? "Corrente" : "Batteria",
                      acceso: Alimentazione.inCarica)
            PillStato(etichetta: "Cervello", valore: CervelloPortatile.daUsare() ? "Gemini" : "Locale",
                      acceso: CervelloPortatile.daUsare() || !core.headline.contains("Ollama spento"))
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $core.voiceOn) { Text("VOCE").font(Olografico.micro(9)).tracking(1).foregroundStyle(Olografico.testo.opacity(0.72)) }
                .toggleStyle(.switch).controlSize(.mini).tint(Olografico.ciano)
            Toggle(isOn: Binding(get: { core.webOn }, set: { core.setWeb($0) })) {
                Text("IPAD").font(Olografico.micro(9)).tracking(1).foregroundStyle(Olografico.testo.opacity(0.72))
            }
            .toggleStyle(.switch).controlSize(.mini).tint(Olografico.ciano)

            if core.webOn {
                Text(core.webLine.components(separatedBy: " · ").last ?? "")
                    .font(Olografico.corpo(9)).foregroundStyle(Olografico.cianoTenue.opacity(0.55)).textSelection(.enabled)
            }
            Spacer()
            Button { core.nuovaChat() } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Olografico.ciano.opacity(0.7)).help("Nuova chat")
            Button { core.userQuit() } label: { Image(systemName: "power") }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Olografico.allarme.opacity(0.75)).help("Esci")
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .overlay(Rectangle().stroke(Olografico.bordoTenue))
    }
}

/// La bolla del dialogo, presa di peso dal suo CSS:
/// `.chat-message.jarvis` = fondo ciano 10% + bordo sinistro 3 px ciano + testo #c0e8ff,
/// `.chat-message.user` = fondo bianco 5% + bordo destro 3 px bianco + testo bianco.
/// Tre px di raggio, massimo 85% della larghezza, niente coda e niente gradiente.
struct BubbleView: View {
    let bubble: Bubble

    var body: some View {
        switch bubble.role {
        case "user":
            HStack(alignment: .bottom, spacing: 0) {
                Spacer(minLength: 60)
                Text(bubble.text)
                    .font(Olografico.corpo(12.5))
                    .lineSpacing(2.5)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .frame(maxWidth: 340, alignment: .trailing)
                    .background(Color.white.opacity(0.06))
                    .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.85)).frame(width: 3) }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case "note":
            HStack(spacing: 7) {
                Rectangle().fill(Olografico.bordo).frame(width: 2, height: 12)
                Text(bubble.text)
                    .font(Olografico.corpo(10.5))
                    .foregroundStyle(Olografico.cianoTenue.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.leading, 2)
        default:
            HStack(alignment: .top, spacing: 0) {
                Text(bubble.text.isEmpty ? "…" : bubble.text)
                    .font(Olografico.corpo(12.5))
                    .lineSpacing(2.5)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .frame(maxWidth: 360, alignment: .leading)
                    .background(Olografico.ciano.opacity(0.08))
                    .overlay(alignment: .leading) { Rectangle().fill(Olografico.ciano.opacity(0.85)).frame(width: 3) }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(Olografico.testoCorpo)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 40)
            }
        }
    }
}
