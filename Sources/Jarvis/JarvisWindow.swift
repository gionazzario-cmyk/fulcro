import SwiftUI
import AppKit

/// "hh:mm" per le righe che devono dire QUANDO sono state lette. E' una funzione e non
/// un `let` dentro la View: un `let DateFormatter()` in un ViewBuilder non e' una View
/// e il compilatore lo dice nel modo piu' confuso possibile.
private func oraLeggibile(_ momento: Date) -> String {
    if momento == .distantPast { return "mai" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "it_IT")
    f.dateFormat = "HH:mm"
    return f.string(from: momento)
}

/// La finestra vera e propria: barra laterale con stato e azioni rapide, chat grande.
struct JarvisFinestra: View {
    @ObservedObject var core: JarvisCore
    @ObservedObject private var orecchio = Orecchio.shared
    @FocusState private var typing: Bool
    /// Falso quando la finestra non si vede: i reattori si fermano (vedi `RilevatoreVisibilita`).
    @State private var inSchermo = false
    @State private var pulse = false
    /// Chat prima di tutto: la barra laterale e la lista chat si chiudono, e resta
    /// solo il filo. Su un 14 pollici tre colonne non stanno, e la chat e' la cosa
    /// che guardi.
    @State private var barraAperta = JarvisFinestra.barraDiProva

    /// Solo per le immagini (`--scatto-finestra --barra`): la barra laterale parte
    /// aperta cosi' si possono vedere i suoi interruttori senza cliccare sul suo desktop.
    static var barraDiProva = false

    enum VistaSelezionata {
        case chat
        case cronologia
    }

    @State private var vista: VistaSelezionata = .chat
    /// L'accensione: lunga la prima volta che apri il giorno, lampo dopo.
    @State private var splash = VistaSplash.lunga()

    private let rapide: [(String, String, String)] = [
        ("sun.max.fill", "la giornata", "Briefing scuola, compiti, meteo, F1 e stato Mac/Pi"),
        ("checklist", "Che compiti ho?", "Legge ~/.jarvis/compiti.md in ordine di scadenza"),
        ("book.closed.fill", "Inizia i compiti", "Accende il controllo e lo riporta sui libri se si sconcentra"),
        ("sparkles", "Che tempo fa?", "Chiedigli il meteo"),
        ("flag.checkered.2", "Classifica piloti F1", "Dati veri dalla stagione"),
        ("play.tv", "Metti un video su YouTube", "Lo cerca e lo apre"),
        ("display", "C'è sullo schermo?", "Guarda il tuo desktop"),
        ("memorychip", "Prestazioni del Raspberry", "Carico, RAM, temperatura"),
        ("cube", "Fammi una scatola 70x50x25", "Genera uno STL per la Bambu")
    ]

    var body: some View {
        VStack(spacing: 0) {
            BarraStato(core: core, pausa: !inSchermo)
            corpoFinestra
        }
        .frame(minWidth: 980, minHeight: 560)
        .background(RilevatoreVisibilita { v in
            inSchermo = v
            core.finestraInSchermo = v
            core.schermoCambiato()
        })
        .overlay {
            if splash {
                VistaSplash(core: core, visibile: $splash)
                    .transition(.opacity.combined(with: .scale(scale: 1.04)))
            }
        }
        .background(Olografico.sfondo)
        .onAppear {
            JarvisCore.shared.portaFinestraAvanti()
            core.aggiornaListaChat()
        }
        .environment(\.colorScheme, .dark)
        .onChange(of: core.listening) { _, attivo in
            // una sola animazione, non `repeatForever`: quella catena resta accesa
            // anche a microfono spento ed e' corrente bruciata
            withAnimation(.easeOut(duration: 0.25)) { pulse = attivo }
        }
    }

    /// Tre colonne come nel design che ha portato: sessioni, chat, diagnostica.
    /// La barra delle azioni rapide e' un di piu' a scomparsa (⌘-like), non una colonna fissa.
    private var corpoFinestra: some View {
        HStack(spacing: 0) {
            if barraAperta {
                sidebar
                Divider().overlay(Olografico.bordo.opacity(0.6))
            }
            if vista == .cronologia {
                CronologiaView(core: core, riapriChat: { id in
                    core.apriChat(id)
                    vista = .chat
                })
            } else {
                elencoChat
                Divider().overlay(Olografico.bordo.opacity(0.6))
                main
                Divider().overlay(Olografico.bordo.opacity(0.6))
                colonnaDestra
            }
        }
        .animation(.easeOut(duration: 0.22), value: barraAperta)
    }

    // MARK: - colonna destra: numeri veri, moduli, registro

    /// Tutto quello che c'e' qui dentro si legge: carico, RAM, termico, compiti,
    /// stampante, permessi e le ultime cose successe. Se un numero non c'e', compare
    /// "—", non un valore inventato.
    private var colonnaDestra: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 11) {
                PannelloOlografico(titolo: "Diagnostica") {
                    VStack(alignment: .leading, spacing: 9) {
                        MetricaReale(etichetta: "CPU · uso", valore: core.diagnostica.cpuUso,
                                     percentuale: Double(core.diagnostica.cpuUso.replacingOccurrences(of: "%", with: "")),
                                     umore: Int(core.diagnostica.cpuUso.replacingOccurrences(of: "%", with: "")) ?? 0 > 85 ? .attenzione : .buono)
                        MetricaReale(etichetta: "Carico (1' / 15')", valore: core.diagnostica.carico)
                        MetricaReale(etichetta: core.diagnostica.ramEtichetta,
                                     valore: core.diagnostica.ramUsata,
                                     percentuale: Double(core.diagnostica.ramPercentuale),
                                     umore: core.diagnostica.ramPercentuale > 82 ? .attenzione : .buono)
                        MetricaReale(etichetta: "Termico", valore: core.diagnostica.termico,
                                     umore: core.diagnostica.termico.contains("CRITICAL") ? .no
                                          : (core.diagnostica.termico.contains("SERIOUS") || core.diagnostica.termico.contains("caldo") ? .attenzione : .buono))
                        MetricaReale(etichetta: "SSD · spazio", valore: Sensori.spazioDisco(),
                                     percentuale: Sensori.percentualePieno())
                        MetricaReale(etichetta: "Batteria",
                                     valore: Alimentazione.percentuale().map { "\($0)% · \(Alimentazione.inCarica ? "corrente" : "staccato")" } ?? "senza batteria",
                                     percentuale: Double(Alimentazione.percentuale() ?? 0),
                                     umore: Alimentazione.inCarica ? .buono : .attenzione)

                        // Se il piano ha congelato le letture deve dirlo: una riga che
                        // sembra fresca ma non lo e' peggio di un "—".
                        if !core.piano.diagnostica {
                            HStack(spacing: 6) {
                                Image(systemName: "pause.circle").font(.system(size: 9))
                                Text("letture ferme · ultima \(oraLeggibile(core.ultimaLettura))")
                                    .font(Olografico.micro(8.5)).tracking(0.6)
                            }
                            .foregroundStyle(Olografico.cianoTenue.opacity(0.6))
                        }
                        Text(core.piano.perche.isEmpty ? "passo: tutto attivo" : "passo: \(core.piano.perche)")
                            .font(.system(size: 9.5)).foregroundStyle(Olografico.testo.opacity(0.4))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                PannelloOlografico(titolo: "Moduli") {
                    VStack(alignment: .leading, spacing: 7) {
                        MetricaReale(etichetta: "Motore", valore: core.diagnostica.motore)
                        MetricaReale(etichetta: "Scuola",
                                     valore: core.verita.first { $0.nome == "scuola" }?.valore ?? "—",
                                     umore: (core.verita.first { $0.nome == "scuola" }?.umore) ?? .buono)
                        MetricaReale(etichetta: "A1 mini",
                                     valore: core.verita.first { $0.nome == "stampa" }?.valore ?? "—",
                                     umore: (core.verita.first { $0.nome == "stampa" }?.umore) ?? .attenzione)
                        MetricaReale(etichetta: "Ascolto", valore: Capacita.microfono ? "pronto" : "permesso negato",
                                     umore: Capacita.microfono ? .buono : .no)
                        MetricaReale(etichetta: "Voce neurale", valore: Speaker.piperPronto ? "online" : "assente",
                                     umore: Speaker.piperPronto ? .buono : .attenzione)
                    }
                }

                PannelloOlografico(titolo: "Registro eventi") {
                    VStack(alignment: .leading, spacing: 6) {
                        if core.eventi.isEmpty {
                            Text("ancora niente da registrare").font(.system(size: 10))
                                .foregroundStyle(Olografico.testo.opacity(0.4))
                        }
                        ForEach(core.eventi.suffix(14)) { e in
                            RigaEvento(evento: e)
                        }
                    }
                }
                .frame(maxHeight: 230)
            }
            .padding(12)
        }
        .frame(width: 268, alignment: .top)
        .background(Olografico.notte.opacity(0.45))
    }

    // MARK: - lista delle chat

    /// La colonna con le conversazioni già fatte: si riapre una chat con un clic.
    private var elencoChat: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("SESSIONI").font(Olografico.micro(9)).tracking(1.7)
                    .foregroundStyle(Olografico.ciano.opacity(0.7))
                Spacer()
                Button { core.nuovaChat() } label: {
                    Text("+ NUOVA")
                        .font(Olografico.micro(8.5)).tracking(1.2)
                        .foregroundStyle(core.busy ? Olografico.ciano.opacity(0.3) : Olografico.ciano)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Olografico.riempimento)
                        .overlay(Rectangle().stroke(Olografico.ciano.opacity(0.8)))
                }
                .buttonStyle(.plain)
                .help("Nuova chat")
                .disabled(core.busy)
            }
            .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 10)

            if core.chat.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "bubble.left").font(.system(size: 20)).foregroundStyle(.white.opacity(0.18))
                    Text("Nessuna chat ancora").font(.system(size: 11)).foregroundStyle(.white.opacity(0.3))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(core.chat) { sessione in
                            RigChat(sessione: sessione,
                                    attiva: sessione.id == core.chatAttuale)
                                .onTapGesture { core.apriChat(sessione.id) }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(width: 214, alignment: .topLeading)
        .background(.ultraThinMaterial.opacity(0.22))
    }

    // MARK: - barra laterale

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                NucleoReattore(diametro: 34, attivo: core.thinking || core.listening,
                               pausa: !inSchermo || core.reattoreFermo)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Marca.marchio).font(.system(size: 13, weight: .heavy, design: .monospaced)).tracking(2.4)
                        .foregroundStyle(Olografico.ciano)
                    Text(core.headline).font(Olografico.corpo(9)).foregroundStyle(Olografico.testo.opacity(0.5)).lineLimit(2)
                }
            }

            // Schede principali (Chat / Cronologia)
            HStack(spacing: 4) {
                scheda(vista == .chat, "bubble.left.and.bubble.right.fill", "Chat") { vista = .chat }
                scheda(vista == .cronologia, "clock.arrow.circlepath", "Cronologia") { vista = .cronologia }
            }
            .padding(3)
            .background(Olografico.bordoSfumato)
            .overlay(Rectangle().stroke(Olografico.bordoTenue))

            // Le schede scorrono: con la riga "A batteria" in piu' il contenuto e' piu'
            // alto della finestra, e l'interruttore in fondo restava tagliato fuori
            // (visto nello scatto di prova: si vedeva meta' "dormi").
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
            // i suggerimenti del momento, con la ragione scritta sotto: se ne esce uno
            // scemo si vede perche' c'e', e quella riga si puo' correggere
            carta(core.suggerimenti.isEmpty ? "Chiedi pure" : "In questo momento") {
                if core.suggerimenti.isEmpty {
                    Text("Nessun suggerimento: adesso non c'e' niente che ti convenga chiedere.")
                        .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                }
                ForEach(core.suggerimenti, id: \.chip) { s in
                    Button { core.draft = s.frase; core.sendTyped() } label: {
                        HStack(spacing: 9) {
                            Image(systemName: s.icona).font(.system(size: 11)).frame(width: 14)
                                .foregroundStyle(Design.rossoChiaro)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.chip).font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                                Text(s.perche).font(.system(size: 9.5))
                                    .foregroundStyle(.white.opacity(0.42)).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Olografico.ciano.opacity(core.busy ? 0.03 : 0.06))
                        .overlay(Rectangle().stroke(Olografico.bordoTenue))
                    }
                    .buttonStyle(.plain).help(s.perche).disabled(core.busy)
                }
            }

            carta("Azioni rapide") {
                ForEach(rapide, id: \.1) { icona, testo, aiuto in
                    Button { core.draft = testo; core.sendTyped() } label: {
                        HStack(spacing: 9) {
                            Image(systemName: icona).font(.system(size: 11)).frame(width: 14)
                                .foregroundStyle(Olografico.ciano)
                            Text(testo).font(.system(size: 12)).foregroundStyle(.white.opacity(0.88))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Olografico.ciano.opacity(core.busy ? 0.03 : 0.06))
                        .overlay(Rectangle().stroke(Olografico.bordoTenue))
                    }
                    .buttonStyle(.plain)
                    .help(aiuto)
                    .disabled(core.busy)
                }
            }

            // "Il tuo Mac" diceva quattro cose, due delle quali erano gia' nelle pill
            // in alto (Ollama e il motore): qui restano solo i permessi macOS, che
            // sono le uniche quattro che puoi sistemare tu con un clic
            carta("Permesso macOS") {
                permessoRapido("Registrazione schermo", Capacita.schermo) { _ = Capacita.apriPannello("schermo") }
                permessoRapido("Microfono", Capacita.microfono) { _ = Capacita.apriPannello("microfono") }
                permessoRapido("Accessibilita", Capacita.accessibilita) { _ = Capacita.apriPannello("accessibilita") }
                permessoRapido("Accesso al disco", Capacita.discoCompleto) { _ = Capacita.apriPannello("disco") }
                stato("Voce neurale", Speaker.piperPronto)
            }

            carta("Collegamenti") {
                // Il codice dell'installazione: serve a scrivere nei commenti del sito.
                // Non è un account e non dice chi sei: dice che Fulcro gira su questo Mac.
                HStack(spacing: 7) {
                    Image(systemName: "textformat.abc.dottedunderline").font(.system(size: 10)).frame(width: 14)
                        .foregroundStyle(Olografico.ciano)
                    Text("Codice commenti").font(.system(size: 11)).foregroundStyle(.white.opacity(0.72))
                    Spacer()
                    Text(Marca.codiceApp).font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Olografico.ciano).textSelection(.enabled)
                        .help("Scrivilo nella casella dei commenti del sito: senza quello non si scrive")
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Marca.codiceApp, forType: .string)
                    } label: { Image(systemName: "doc.on.doc").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(Olografico.ciano.opacity(0.7)).help("Copia il codice")
                }
                HStack(spacing: 7) {
                    Image(systemName: "person.wave.2.fill").font(.system(size: 10)).frame(width: 14)
                        .foregroundStyle(Olografico.ciano)
                    Text("Voce di").font(.system(size: 11)).foregroundStyle(.white.opacity(0.72))
                    Spacer()
                    Picker("Voce", selection: Binding(
                        get: { AppPaths.voceCorrente },
                        set: { core.cambiaVoce($0) }
                    )) {
                        ForEach(AppPaths.disponibili(), id: \.nome) { v in
                            Text(AppPaths.capitalizza(v.nome)).tag(v.nome)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).controlSize(.mini)
                    .fixedSize()
                }
                HStack(spacing: 7) {
                    Image(systemName: core.voiceOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(size: 10)).frame(width: 14)
                        .foregroundStyle(Olografico.ciano)
                    Text("Voce").font(.system(size: 11)).foregroundStyle(.white.opacity(0.72))
                    Spacer()
                    Text(core.voiceOn ? "sì" : "no").font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                    Toggle("", isOn: $core.voiceOn).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
                HStack(spacing: 7) {
                    Image(systemName: "ipad.genome").font(.system(size: 10)).frame(width: 14)
                        .foregroundStyle(Olografico.ciano)
                    Text("iPad").font(.system(size: 11)).foregroundStyle(.white.opacity(0.72))
                    Spacer()
                    Toggle("", isOn: Binding(get: { core.webOn }, set: { core.setWeb($0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
                HStack(spacing: 7) {
                    Image(systemName: "envelope.badge").font(.system(size: 10)).frame(width: 14)
                        .foregroundStyle(Olografico.ciano)
                    Text("Avvisi messaggi").font(.system(size: 11)).foregroundStyle(.white.opacity(0.72))
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { orecchio.attivo },
                        set: { _ = $0 ? orecchio.accendi() : orecchio.spegni() }
                    )).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
                HStack(spacing: 7) {
                    Image(systemName: "battery.25").font(.system(size: 10)).frame(width: 14)
                        .foregroundStyle(Olografico.ciano)
                    Text("A batteria").font(.system(size: 11)).foregroundStyle(.white.opacity(0.72))
                    Spacer()
                    Picker("A batteria", selection: Binding(
                        get: { Risparmio.modalita },
                        set: { core.cambiaPasso($0) }
                    )) {
                        Text("dormi").tag(Risparmio.Modo.dormi)
                        Text("esci").tag(Risparmio.Modo.esci)
                        Text("lavora").tag(Risparmio.Modo.lavora)
                    }
                    .labelsHidden().pickerStyle(.menu).controlSize(.mini)
                    .fixedSize()
                }
                .help("Cosa fa \(Marca.nome) quando stacchi la corrente: dormi = zero sveglie (⌥ Spazio lo risveglia), esci = si chiude, lavora = continua a passo lento")
                HStack(spacing: 6) {
                    permessoRapido("disco", Capacita.discoCompleto) { Capacita.apriPannello("disco") }
                    permessoRapido("tasti", Capacita.accessibilita) { Capacita.apriPannello("accessibilita") }
                    Spacer(minLength: 0)
                }
                Text(core.webOn ? core.webLine : "chat iPad spenta")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                }
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 10) {
                Button { core.nuovaChat() } label: {
                    Label("Nuova chat", systemImage: "square.and.pencil").font(.system(size: 11))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(jarvisGrad, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(core.busy)

                Button { core.userQuit() } label: {
                    Image(systemName: "power").font(.system(size: 13))
                        .frame(width: 34, height: 31)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
                .help("Esci: \(Marca.nome) non riapre finché non stacchi e riattacchi la corrente")
            }
        }
        .padding(14)
        .frame(width: 236, alignment: .topLeading)
        .background(.ultraThinMaterial.opacity(0.35))
    }

    /// Un blocco dell'interfaccia: titolo piccolo sopra, contenuto dentro una card scura.
    private func carta<Contenuto: View>(_ titolo: String, @ViewBuilder _ contenuto: () -> Contenuto) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(titolo.uppercased())
                .font(Olografico.micro(9)).tracking(1.7)
                .foregroundStyle(Olografico.ciano.opacity(0.72))
            contenuto()
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .carta()
    }

    /// Un pulsante delle schede (Chat / Cronologia) dentro la sua cornice.
    private func scheda(_ attiva: Bool, _ icona: String, _ titolo: String, _ azione: @escaping () -> Void) -> some View {
        Button(action: azione) {
            HStack(spacing: 6) {
                Image(systemName: icona).font(.system(size: 10))
                Text(titolo).font(.system(size: 11.5, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(attiva ? AnyShapeStyle(Olografico.ciano.opacity(0.16)) : AnyShapeStyle(Color.clear))
            .foregroundStyle(attiva ? Olografico.ciano : .white.opacity(0.5))
        }
        .buttonStyle(.plain)
    }

    /// Un permesso macOS shown as a tiny pill: green when granted, tappable when not.
    private func permessoRapido(_ nome: String, _ concesso: Bool, _ apri: @escaping () -> Void) -> some View {
        Button(action: apri) {
            HStack(spacing: 4) {
                Circle().fill(concesso ? Color.green : Olografico.avviso).frame(width: 5, height: 5)
                Text(nome.uppercased()).font(Olografico.micro(8)).tracking(0.8)
                    .foregroundStyle(Olografico.testo.opacity(0.62))
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(concesso ? Olografico.ciano.opacity(0.05) : Olografico.avviso.opacity(0.08))
            .overlay(Rectangle().stroke(concesso ? Olografico.bordoTenue : Olografico.avviso.opacity(0.4)))
        }
        .buttonStyle(.plain)
        .help(concesso ? "\(nome): permesso gia' dato" : "\(nome): clic per aprire la schermata e attivarlo")
    }

    private func sezione(_ titolo: String) -> some View {
        Text(titolo.uppercased())
            .font(Olografico.micro(9)).tracking(1.7)
            .foregroundStyle(Olografico.ciano.opacity(0.6))
    }

    private func stato(_ cosa: String, _ ok: Bool) -> some View {
        HStack(spacing: 7) {
            Circle().fill(ok ? Color.green : Olografico.allarme).frame(width: 6, height: 6)
            Text(cosa.uppercased()).font(Olografico.micro(8.5)).tracking(0.9)
                .foregroundStyle(Olografico.testo.opacity(0.66))
            Spacer()
            Text(ok ? "SI'" : "NO").font(Olografico.valore(10))
                .foregroundStyle(ok ? Olografico.ciano : Olografico.allarme)
        }
    }

    // MARK: - chat

    private var main: some View {
        VStack(spacing: 0) {
            barraChat
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(core.bubbles) { b in
                            BubbleView(bubble: b).id(b.id).font(.system(size: 13.5))
                        }
                    }
                    .padding(.horizontal, 22).padding(.vertical, 18)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: core.bubbles.count) { _, _ in
                    if let last = core.bubbles.last { withAnimation(.easeOut) { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            .overlay {
                if core.bubbles.isEmpty {
                    VStack(spacing: 16) {
                        NucleoReattore(diametro: 160, attivo: core.thinking || core.listening,
                                       azione: {
                            core.raccogliDiagnostica()
                            core.raccogliSuggerimenti()
                        }, pausa: !inSchermo || core.reattoreFermo)
                        Text("Tutti i sistemi primari sono operativi")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Olografico.testo.opacity(0.7))
                        Text("Scrivi o premi ⌥ Spazio — il reattore in alto rilegge le misure del Mac")
                            .font(Olografico.corpo(10.5)).foregroundStyle(Olografico.testoTenue.opacity(0.75))
                    }
                }
            }

            if let cmd = core.pendingCommand { confermaGrande(cmd).padding(.bottom, 6) }

            pensiero(core.passi)

            // i suggerimenti stanno dove guardi quando scrivi, non in una card a lato;
            // e se non c'e' niente di utile da dire la riga non c'e'
            if !core.suggerimenti.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(core.suggerimenti, id: \.chip) { s in
                            ChipSuggerimento(s: s) { core.draft = s.frase; core.sendTyped() }
                        }
                    }
                    .padding(.horizontal, 18)
                }
                .padding(.bottom, 7)
            }

            barraInput
        }
    }

    /// I fumetti che mostrano cosa sta facendo davvero, uno per strumento chiamato.
    private func pensiero(_ passi: [Passo]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if !passi.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile").font(.system(size: 9))
                    Text("STO PENSANDO").font(Olografico.micro(8.5)).tracking(1.4)
                    Spacer()
                }
                .foregroundStyle(Olografico.ciano.opacity(0.8))
                .padding(.leading, 3)
            }
            ForEach(passi.suffix(5)) { passo in
                HStack(spacing: 8) {
                    ZStack {
                        if passo.fatto {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 11))
                                .foregroundStyle(.green.opacity(0.85))
                        } else {
                            // Un orologio, non `repeatForever`: quest'ultimo tiene su
                            // l'intero ciclo di Core Animation anche quando i fumetti
                            // sono vuoti (era il resto del CPU a riposo).
                            TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { tempo in
                                Circle().trim(from: 0, to: 0.7)
                                    .stroke(Olografico.ciano, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                    .frame(width: 11, height: 11)
                                    .rotationEffect(.degrees(tempo.date.timeIntervalSinceReferenceDate / 1.1 * 360))
                            }
                        }
                    }
                    Text(passo.etichetta)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(passo.fatto ? 0.5 : 0.9))
                        .strikethrough(passo.fatto, color: .white.opacity(0.3))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(passo.fatto ? Olografico.bordoSfumato : Olografico.ciano.opacity(0.06))
                .overlay(Rectangle().stroke(passo.fatto ? Olografico.bordoTenue : Olografico.bordo.opacity(0.7)))
                .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                        removal: .opacity))
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, passi.isEmpty ? 0 : 8)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: passi)
    }

    /// Intestazione della chat: titolo del filo aperto + stato del motore.
    private var barraChat: some View {
        HStack(spacing: 10) {
            Button { barraAperta.toggle() } label: {
                Image(systemName: "sidebar.left").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(barraAperta ? 0.9 : 0.5))
                    .frame(width: 26, height: 26)
                    .background(Olografico.riempimento)
                    .overlay(Rectangle().stroke(Olografico.bordoTenue))
            }
            .buttonStyle(.plain)
            .help(barraAperta ? "Chiudi la barra laterale: resta solo il filo" : "Apri la barra laterale")

            VStack(alignment: .leading, spacing: 2) {
                Text(titoloChat).font(Olografico.corpo(13.5)).foregroundStyle(Olografico.testo).lineLimit(1)
                Text(core.headline).font(Olografico.corpo(9.5)).foregroundStyle(Olografico.cianoTenue.opacity(0.45))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if core.thinking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("CI PENSO").font(Olografico.micro(8.5)).tracking(1.2).foregroundStyle(Olografico.ciano.opacity(0.8))
                }
            }
            Circle()
                .fill(core.thinking ? Color.orange : (core.busy ? Color.yellow : Color.green))
                .frame(width: 7, height: 7)
                .shadow(color: (core.thinking ? Color.orange : Color.green).opacity(0.8), radius: 5)
        }
        .padding(.horizontal, 20).padding(.vertical, 13)
        .background {
            // mentre pensa l'intestazione si muove: una luce ciano che scorre
            if core.thinking {
                TimelineView(.animation) { tempo in
                    let f = CGFloat(sin(tempo.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4) / 4 * 2 * .pi))
                    LinearGradient(colors: [Olografico.notteProfonda,
                                            Olografico.ciano.opacity(0.55),
                                            Olografico.notteProfonda],
                                   startPoint: UnitPoint(x: 0.5 + f * 0.5, y: 0),
                                   endPoint: UnitPoint(x: 0.5 - f * 0.5, y: 1))
                        .opacity(0.30)
                }
            }
        }
        .background(Olografico.notte.opacity(0.8))
        .overlay(alignment: .bottom) { Rectangle().fill(Olografico.bordo).frame(height: 1) }
    }

    private var titoloChat: String {
        if let aperta = core.chat.first(where: { $0.id == core.chatAttuale }) { return aperta.titolo }
        return core.bubbles.isEmpty ? "Chat nuova" : "Chat in corso"
    }

    private func confermaGrande(_ cmd: String) -> some View {
        CardConferma(comando: cmd, motivo: "AVVISO DI SICUREZZA", pieno: true,
                     ok: { core.answer(true) }, no: { core.answer(false) })
    }

    private func bottone(_ titolo: String, piena: Bool, _ azione: @escaping () -> Void) -> some View {
        Button(action: azione) {
            Text(titolo)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 9)
                .background(piena ? AnyShapeStyle(Color.red.opacity(0.85)) : AnyShapeStyle(.white.opacity(0.09)),
                            in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var barraInput: some View {
        HStack(spacing: 12) {
            Button { core.toggleTalk() } label: {
                Image(systemName: core.listening ? "stop.fill" : "mic.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(core.listening ? .white : Olografico.ciano)
                    .frame(width: 42, height: 42)
                    .background(core.listening ? AnyShapeStyle(Olografico.allarme.opacity(0.9)) : AnyShapeStyle(Olografico.riempimento))
                    .overlay(Rectangle().stroke(core.listening ? Olografico.allarme : Olografico.bordo))
                    .scaleEffect(core.listening && pulse ? 1.05 : 1)
                    .shadow(color: (core.listening ? Olografico.allarme : Olografico.alone).opacity(0.8), radius: 9)
            }
            .buttonStyle(.plain)
            .help("⌥ Spazio")

            VStack(spacing: 5) {
                TextField("Immetti comando per JARVIS…", text: $core.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Olografico.corpo(13)).foregroundStyle(.white)
                    .focused($typing).lineLimit(1...6).onSubmit { core.sendTyped() }
                    .padding(.horizontal, 13).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Olografico.ciano.opacity(typing ? 0.07 : 0.05))
                    .overlay(Rectangle().stroke(typing ? Olografico.ciano : Olografico.bordo))
                    .shadow(color: Olografico.alone.opacity(typing ? 0.8 : 0), radius: 5)
                if core.listening {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Olografico.ciano.opacity(0.1))
                            Rectangle().fill(Olografico.ciano)
                                .frame(width: max(4, g.size.width * min(1, core.micLevel * 4)))
                                .shadow(color: Olografico.ciano.opacity(0.9), radius: 4)
                        }
                    }.frame(height: 3)
                    .overlay(Rectangle().stroke(Olografico.bordoTenue))
                }
            }

            Button { core.sendTyped() } label: {
                Text("INVIA")
                    .font(Olografico.micro(12)).tracking(1.6)
                    .foregroundStyle(canSend ? Olografico.notte : Olografico.ciano.opacity(0.35))
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(canSend ? AnyShapeStyle(Olografico.ciano) : AnyShapeStyle(Olografico.bordoSfumato))
                    .overlay(Rectangle().stroke(Olografico.ciano.opacity(canSend ? 1 : 0.35)))
            }
            .buttonStyle(.plain)
            .disabled(core.busy || !canSend)
            .shadow(color: Olografico.alone.opacity(canSend ? 1 : 0), radius: 10)
        }
        .padding(16)
        .background(Olografico.notte.opacity(0.55))
        .overlay(alignment: .top) { Rectangle().fill(Olografico.bordoTenue).frame(height: 1) }
    }

    private var canSend: Bool {
        !core.draft.trimmingCharacters(in: .whitespaces).isEmpty || core.listening
    }
}

/// Una riga della lista chat: titolo breve, quando, quanti messaggi.
private struct RigChat: View {
    let sessione: ChatSessione
    let attiva: Bool
    @State private var sopra = false

    private static func quando(_ d: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        if cal.isDateInToday(d) { f.dateFormat = "HH:mm"; return f.string(from: d) }
        if cal.isDateInYesterday(d) { return "ieri" }
        f.dateFormat = "d MMM"
        return f.string(from: d)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(sessione.titolo)
                .font(Olografico.corpo(11.5))
                .lineSpacing(1.5)
                .foregroundStyle(attiva || sopra ? .white : Olografico.testo.opacity(0.82))
                .lineLimit(2).multilineTextAlignment(.leading)
            HStack(spacing: 5) {
                Text(Self.quando(sessione.inizio))
                Text("·").opacity(0.6)
                Text("\(sessione.messaggi) msg")
            }
            .font(Olografico.corpo(9)).foregroundStyle(Olografico.testoTenue.opacity(0.62))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(RigChat.sfondo(attiva: attiva, sopra: sopra))
        .overlay(Rectangle().stroke((attiva || sopra) ? Olografico.ciano : Olografico.bordoTenue, lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { sopra = $0 }
        .animation(.easeOut(duration: 0.12), value: sopra)
    }

    private static func sfondo(attiva: Bool, sopra: Bool) -> AnyShapeStyle {
        if attiva || sopra { return AnyShapeStyle(Olografico.riempimento) }
        return AnyShapeStyle(Olografico.bordoSfumato)
    }
}
