import SwiftUI
import AppKit

/// I mattoni visivi di Jarvis: colori, raggi, distanze e materiali stanno tutti qui,
/// cosi' la finestra, il pannello della barra e la pagina dell'iPad hanno la stessa faccia.
enum Design {
    // MARK: - colori

    // Il nome resta "rosso" per non riscrivere meta' del programma, ma dal
    // 2026-10-21 il colore firma di Jarvis e' il ciano del design olografico.
    // L'unica cosa che continua a essere rossa e' Olografico.allarme.
    static let rossoChiaro = Color(red: 0.44, green: 0.94, blue: 1.00)
    static let rosso = Color(red: 0.00, green: 0.86, blue: 0.95)
    static let rossoScuro = Color(red: 0.00, green: 0.42, blue: 0.52)
    static let inchiostro = Color(red: 0.012, green: 0.039, blue: 0.078)
    static let superficie = Color(red: 0.020, green: 0.075, blue: 0.130)
    static let superficieAlta = Color(red: 0.035, green: 0.110, blue: 0.175)

    /// Il gradiente "firma" di Jarvis.
    static let fiamma = LinearGradient(
        colors: [rossoChiaro, rosso, rossoScuro],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let fiammaOrizzontale = LinearGradient(
        colors: [rossoScuro, rosso, rossoChiaro, rosso, rossoScuro],
        startPoint: .leading, endPoint: .trailing)

    /// Sfondo della finestra: identico a `Olografico.sfondo`, cosi' il pop-up della
    /// barra e la finestra grande hanno la stessa faccia con una sola definizione.
    static var sfondo: some View { Olografico.sfondo }

    // MARK: - misure

    static let raggioCARTA: CGFloat = 16
    static let raggioBolla: CGFloat = 18
    static let raggioPillola: CGFloat = 999
    static let spazio: CGFloat = 12

    // MARK: - testi

    static func titolo(_ size: CGFloat = 15) -> Font { .system(size: size, weight: .bold, design: .rounded) }
    static func corpo(_ size: CGFloat = 13.5) -> Font { .system(size: size, weight: .regular) }
    static func micro(_ size: CGFloat = 9.5) -> Font { .system(size: size, weight: .semibold) }
    static func codice(_ size: CGFloat = 11) -> Font { .system(size: size, design: .monospaced) }

    static func sezione(_ testo: String) -> some View {
        Text(testo.uppercased())
            .font(micro(9)).tracking(1.3)
            .foregroundStyle(.white.opacity(0.36))
    }
}

// MARK: - materiali riutilizzabili

/// La card standard: ora e' il `.panel` del suo file — sfondo rgba(3,20,38,.7),
/// bordo ciano 1 px, alone interno, squadrette negli angoli e nessun angolo tondo.
/// Con `squadrette: false` diventa la `.chat-box` (fondo piu' scuro, 4 px, senza segni).
struct Carta: ViewModifier {
    var inRilievo = false
    var squadrette = true
    var scura = false

    private var raggio: CGFloat { squadrette ? 0 : 4 }
    private var sfondo: Color { scura ? Olografico.caixa : Olografico.pannello }

    func body(content: Content) -> some View {
        let forma = RoundedRectangle(cornerRadius: raggio, style: .continuous)
        content
            .background(.ultraThinMaterial.opacity(squadrette ? 0.22 : 0.12), in: forma)
            .background(sfondo, in: forma)
            .overlay(forma.stroke(inRilievo ? Olografico.ciano.opacity(0.55) : Olografico.bordo, lineWidth: 1))
            .overlay(                                   // l'alone interno del CSS
                forma.stroke(Olografico.ciano.opacity(0.10), lineWidth: 7).blur(radius: 7).clipShape(forma)
            )
            .overlay(squadrette ? AnyView(AngoliCiano(lato: 10, spessore: 2)) : AnyView(Color.clear))
            .shadow(color: Olografico.ciano.opacity(inRilievo ? 0.20 : 0.10), radius: inRilievo ? 16 : 9, y: 2)
    }
}

extension View {
    func carta(inRilievo: Bool = false) -> some View { modifier(Carta(inRilievo: inRilievo)) }

    /// La `.chat-box` del suo file: rettangolo scuro, bordo ciano tenue, 4 px.
    func caixa() -> some View { modifier(Carta(squadrette: false, scura: true)) }

    /// Il `.panel` del suo file: squadrette incluse.
    func pannelloOlo(inRilievo: Bool = false) -> some View { modifier(Carta(inRilievo: inRilievo)) }

    /// Angoli continui + alone rosso per gli elementi attivi.
    func alone(_ attivo: Bool = true, raggio: CGFloat = 12) -> some View {
        shadow(color: Olografico.alone.opacity(attivo ? 1 : 0), radius: raggio, y: 3)
    }
}

// MARK: - animazioni

/// L'alone che si muove sopra l'intestazione mentre Jarvis sta pensando.
/// Si ferma quando non sta pensando: un `TimelineView` a 24 fotogrammi che disegna
/// una cosa trasparente e' esattamente il CPU che lui non vuole pagare.
struct PensieroAurora: View {
    @ObservedObject var core: JarvisCore
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !core.thinking)) { tempo in
            let t = tempo.date.timeIntervalSinceReferenceDate
            let f = CGFloat(sin(t.truncatingRemainder(dividingBy: 5) / 5 * 2 * .pi))
            LinearGradient(colors: [.clear, Design.rosso.opacity(0.55), Design.rossoChiaro.opacity(0.35), .clear],
                           startPoint: UnitPoint(x: 0.5 + f * 0.7, y: 0),
                           endPoint: UnitPoint(x: 0.5 - f * 0.7, y: 1))
                .opacity(core.thinking ? 0.34 : 0)
                .animation(.easeInOut(duration: 0.4), value: core.thinking)
        }
    }
}

/// Onda del microfono: prende il livello vero della registrazione.
/// Ferma quando il microfono non e' aperto: 30 fotogrammi al secondo per disegnare
/// una linea piatta non sono una grafica, sono corrente.
struct OndaMicrofono: View {
    let livello: Double
    var attivo: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !attivo)) { tempo in
            Canvas { contesto, dimensione in
                let barre = 22
                let passo = dimensione.width / CGFloat(barre)
                let t = tempo.date.timeIntervalSinceReferenceDate
                for i in 0..<barre {
                    let x = CGFloat(i) * passo
                    let distanza = abs((CGFloat(i) - CGFloat(barre) / 2) / CGFloat(barre))
                    let inviluppo = max(0, 1 - distanza * 1.6)
                    let oscillazione = sin(t * 7 + Double(i) * 0.55) * 0.5 + 0.5
                    let ampiezza = attivo
                        ? dimensione.height * (0.16 + inviluppo * CGFloat(livello) * 2.6 * (0.35 + oscillazione))
                        : dimensione.height * 0.10
                    let rettangolo = CGRect(x: x + passo * 0.22,
                                            y: (dimensione.height - ampiezza) / 2,
                                            width: passo * 0.56,
                                            height: max(2, ampiezza))
                    contesto.fill(Path(roundedRect: rettangolo, cornerRadius: passo * 0.28),
                                  with: .color(Design.rossoChiaro.opacity(0.55 + 0.45 * inviluppo)))
                }
            }
        }
    }
}

/// La faccia di Jarvis in alto a sinistra: da qui in poi e' sempre lo stesso
/// reattore che gira, nella finestra grande e nel pop-up della barra.
/// Il ritmo viene dallo stato vero del programma: pensa o ascolta = gira veloce.
@MainActor @ViewBuilder
func SferaJarvis(diametro: CGFloat, core: JarvisCore, pausa: Bool = false) -> some View {
    NucleoReattore(diametro: diametro, attivo: core.thinking || core.listening,
                   pausa: pausa || core.reattoreFermo)
}

// MARK: - pezzi del concept dell'utente

/// La pill di stato: etichetta monospazio tenue sopra, valore con la vocina accanto.
/// Quadro, bordo ciano, come i pannelli del suo file.
struct PillStato: View {
    let etichetta: String
    let valore: String
    var acceso = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(etichetta.uppercased())
                .font(Olografico.micro(8)).tracking(1.2).foregroundStyle(Olografico.testo.opacity(0.45))
                .lineLimit(1)
            HStack(spacing: 6) {
                Circle()
                    .fill(acceso ? Color(red: 0.06, green: 0.73, blue: 0.42) : Olografico.allarme)
                    .frame(width: 6, height: 6)
                    .shadow(color: (acceso ? Color.green : Olografico.allarme).opacity(0.9), radius: 5)
                Text(valore)
                    .font(Olografico.valore(11))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Olografico.ciano.opacity(0.05))
        .overlay(Rectangle().stroke(Olografico.bordoTenue))
    }
}

/// Chip delle azioni rapide: la `.modal-btn` del suo file — fondo ciano 10%,
/// bordo ciano, testo ciano; al passaggio diventa ciano pieno con testo scuro e alone.
struct ChipAzione: View {
    let testo: String
    var icona: String?
    let azione: () -> Void
    @State private var sopra = false

    var body: some View {
        Button(action: azione) {
            HStack(spacing: 5) {
                if let icona { Image(systemName: icona).font(.system(size: 9.5)) }
                Text(testo).font(Olografico.corpo(11))
            }
            .foregroundStyle(sopra ? Olografico.notte : Olografico.ciano)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(sopra ? Olografico.ciano : Olografico.riempimento)
            .overlay(Rectangle().stroke(sopra ? Olografico.ciano : Olografico.bordo))
        }
        .buttonStyle(.plain)
        .onHover { sopra = $0 }
        .animation(.easeOut(duration: 0.15), value: sopra)
        .shadow(color: Olografico.alone.opacity(sopra ? 1 : 0), radius: 6)
    }
}

/// La card di conferma dei comandi: e' la `.modal-window` del suo file — 420 px,
/// sfondo quasi opaco, bordo ciano pieno, alone da 30 px, squadrette da 12 px,
/// titolo ciano con la linea tratteggiata sotto, pulsanti allineati a destra.
struct CardConferma: View {
    let comando: String
    let motivo: String
    let pieno: Bool
    let ok: () -> Void
    let no: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(Olografico.allarme)
                Text(motivo.uppercased())
                    .font(Olografico.micro(11)).tracking(2).foregroundStyle(Olografico.ciano)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 6)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Olografico.bordo).frame(height: 1)
                    .overlay(TratteggioCiano(altezza: 1).opacity(0.9))
            }
            Text(comando)
                .font(Olografico.corpo(12))
                .foregroundStyle(Olografico.testo)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Olografico.notteProfonda.opacity(0.85))
                .overlay(Rectangle().stroke(Olografico.bordoTenue))
                .textSelection(.enabled)
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                BottonePotente(titolo: "Esegui", pieno: true, azione: ok)
                BottonePotente(titolo: "Lascia stare", pieno: false, azione: no)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Olografico.pannelloForte)
        .overlay(Rectangle().stroke(Olografico.ciano.opacity(0.75)))
        .overlay(AngoliCiano(lato: 12, spessore: 2))
        .shadow(color: Olografico.alone, radius: 15, y: 2)
    }
}

/// Dice al SwiftUI se la finestra che lo contiene si vede DAVVERO. Serve perche' il
/// pannello della barra dei menu viene creato all'avvio e resta vivo anche quando non
/// lo apri: `.onAppear` scatta lo stesso, e un anello che gira in una finestra nascosta
/// costa un quarto di core (misurato con `sample`: `NSHostingView.layout ->
/// ViewGraph.updateOutputs`, 25% di CPU con la finestra chiusa).
struct RilevatoreVisibilita: NSViewRepresentable {
    let cambio: (Bool) -> Void

    func makeNSView(context: Context) -> NSView { Vista(cambio: cambio) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Vista: NSView {
        let cambio: (Bool) -> Void
        var osservatore: Any?

        init(cambio: @escaping (Bool) -> Void) {
            self.cambio = cambio
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("non si costruisce da un nib") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let vecchio = osservatore { NotificationCenter.default.removeObserver(vecchio) }
            // la finestra si chiude: il detached della vista NON manda la notifica di
            // occlusione, e senza questa riga Jarvis crederebbe che qualcuno guarda
            // ancora e continuerebbe a ricalcolare i chip per nessuno
            guard let finestra = self.window else { cambio(false); return }
            osservatore = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: finestra, queue: .main
            ) { _ in
                self.cambio(self.window?.occlusionState.contains(.visible) ?? false)
            }
            cambio(finestra.occlusionState.contains(.visible))
        }

        deinit {
            if let osservatore { NotificationCenter.default.removeObserver(osservatore) }
        }
    }
}

/// Il trattino tratteggiato sotto i titoli, come `border-bottom: 1px dashed`.
struct TratteggioCiano: View {
    var altezza: CGFloat = 1
    var passo: CGFloat = 5
    var body: some View {
        Canvas { zona, dimensione in
            var tratteggio = Path()
            var x: CGFloat = 0
            while x < dimensione.width {
                tratteggio.move(to: CGPoint(x: x, y: dimensione.height / 2))
                tratteggio.addLine(to: CGPoint(x: x + passo * 0.55, y: dimensione.height / 2))
                x += passo
            }
            zona.stroke(tratteggio, with: .color(Olografico.bordo), lineWidth: altezza)
        }
        .frame(height: altezza)
        .allowsHitTesting(false)
    }
}

/// Il bottone del suo file (`.modal-btn`): contorno ciano su fondo tenue,
/// pieno = ciano con la scritta scura e l'alone; `pericoloso` usa il rosso #ff3366.
struct BottonePotente: View {
    let titolo: String
    let pieno: Bool
    var pericoloso = false
    let azione: () -> Void
    @State private var sopra = false

    private var firma: Color { pericoloso ? Olografico.allarme : Olografico.ciano }

    var body: some View {
        Button(action: azione) {
            Text(pieno ? titolo.uppercased() : titolo)
                .font(Olografico.micro(pieno ? 11 : 10.5)).tracking(pieno ? 1.4 : 0.4)
                .foregroundStyle((pieno || sopra) ? Olografico.notte : firma)
                .padding(.horizontal, 16).padding(.vertical, 7)
                .frame(maxWidth: pieno ? .infinity : nil)
                .background((pieno || sopra) ? AnyShapeStyle(firma) : AnyShapeStyle(Olografico.riempimento))
                .overlay(Rectangle().stroke(firma.opacity(pieno || sopra ? 1 : 0.7)))
        }
        .buttonStyle(.plain)
        .onHover { sopra = $0 }
        .animation(.easeOut(duration: 0.14), value: sopra)
        .shadow(color: Olografico.alone.opacity(pieno || sopra ? 1 : 0), radius: 8)
    }
}

/// L'ingresso del suo concept: sfocato e piccolo che si materializza.
struct Materializza: ViewModifier {
    @State private var dentro = false
    let ritardo: Double

    func body(content: Content) -> some View {
        content
            .blur(radius: dentro ? 0 : 15)
            .scaleEffect(dentro ? 1 : 0.6)
            .offset(y: dentro ? 0 : 20)
            .opacity(dentro ? 1 : 0)
            .onAppear {
                withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 1.4).delay(ritardo)) { dentro = true }
            }
    }
}

extension View {
    /// Si materializza con la curva di temporizzazione dell'utente.
    func materializza(ritardo: Double = 0) -> some View { modifier(Materializza(ritardo: ritardo)) }
}


/// Come sta una cosa: verde a posto, ambra "guarda che", rosso rotto.
enum Umore {
    case buono, attenzione, no
    var colore: Color {
        switch self {
        case .buono: return Color(red: 0.06, green: 0.73, blue: 0.42)
        case .attenzione: return Color(red: 1, green: 0.71, blue: 0.33)
        case .no: return Color(red: 1, green: 0.29, blue: 0.29)
        }
    }
}

/// Le quattro verita' della barra in alto: una pill piccola per ciascuna.
/// Sono compatte perche' stanno sopra la chat, non in una card a lato: devono
/// potersi leggere con la coda dell'occhio mentre si scrive.
struct PillCompatta: View {
    let etichetta: String
    let valore: String
    var umore: Umore = .buono

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(umore.colore).frame(width: 5, height: 5)
                .shadow(color: umore.colore.opacity(0.9), radius: 4)
            Text(etichetta).font(.system(size: 8.5)).tracking(0.6)
                .foregroundStyle(.white.opacity(0.4)).textCase(.uppercase)
            Text(valore).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88)).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.white.opacity(0.05), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.08)))
        .help("\(etichetta): \(valore)")
    }
}

/// Il chip del suggerimento del momento: cosa premere, e perche' te lo sta dicendo.
struct ChipSuggerimento: View {
    let s: Suggerimento
    let azione: () -> Void
    @State private var sopra = false

    var body: some View {
        Button(action: azione) {
            HStack(spacing: 6) {
                Image(systemName: s.icona).font(.system(size: 9.5))
                    .foregroundStyle(sopra ? Olografico.notte : Olografico.cianoTenue)
                Text(s.chip).font(.system(size: 11.5))
            }
            .foregroundStyle(sopra ? Olografico.notte : Olografico.ciano)
            .font(Olografico.corpo(11))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(sopra ? Olografico.ciano : Olografico.riempimento)
            .overlay(Rectangle().stroke(sopra ? Olografico.ciano : Olografico.bordo))
        }
        .buttonStyle(.plain)
        .onHover { sopra = $0 }
        .animation(.easeOut(duration: 0.14), value: sopra)
        .help(s.perche)
    }
}


// MARK: - tema olografico (il design che l'utente ha portato il 2026-10-21)
//
// Ciano su blu notte, bordi luminosi, angoli quasi quadri, etichette monospazio
// maiuscole, rosso #ff3366 solo dove c'e' un allarme. Sono i suoi valori, ripresi
// dal file che ha mandato (#00f0ff, #030a14, rgba(3,20,38,.7), #c0e8ff, #ff3366,
// #ffbb00). La differenza con quel file sta nei NUMERI: qui dentro non c'e' niente
// che recita "sistemi operativi" — ogni riga legge un dato vero del Mac.
enum Olografico {
    static let ciano = Color(red: 0.00, green: 0.94, blue: 1.00)
    static let cianoTenue = Color(red: 0.44, green: 0.85, blue: 1.00)
    static let notte = Color(red: 0.012, green: 0.039, blue: 0.078)
    static let notteProfonda = Color(red: 0.004, green: 0.020, blue: 0.039)
    static let pannello = Color(red: 0.012, green: 0.078, blue: 0.149).opacity(0.72)
    static let bordo = Color(red: 0.00, green: 0.94, blue: 1.00).opacity(0.30)
    static let testo = Color(red: 0.75, green: 0.91, blue: 1.00)
    /// Testo secondario davvero leggibile: con `.opacity(0.4)` sotto i 10 px, su questo
    /// blu, le etichette sparivano. Questi due valori tengono la gerarchia senza
    /// spegnere niente (li ho guardati a schermo, non scelti a occhio sul codice).
    static let testoTenue = Color(red: 0.60, green: 0.77, blue: 0.90)
    static let testoCorpo = Color(red: 0.82, green: 0.93, blue: 1.00)
    static let allarme = Color(red: 1.00, green: 0.20, blue: 0.40)
    static let avviso = Color(red: 1.00, green: 0.73, blue: 0.00)

    // I valori esatti del suo file, uno a uno.
    static let alone = Color(red: 0.00, green: 0.94, blue: 1.00).opacity(0.40)   // --primary-glow
    static let pannelloForte = Color(red: 0.012, green: 0.078, blue: 0.149).opacity(0.95)
    static let caixa = Color(red: 0.004, green: 0.039, blue: 0.078).opacity(0.80) // chat-box
    static let riempimento = Color(red: 0.00, green: 0.94, blue: 1.00).opacity(0.10)
    static let bordoTenue = Color(red: 0.00, green: 0.94, blue: 1.00).opacity(0.10)
    static let bordoSfumato = Color(red: 0.00, green: 0.94, blue: 1.00).opacity(0.03)

    static let etichetta = Font.system(size: 9, weight: .bold, design: .monospaced)
    static func micro(_ s: CGFloat = 9) -> Font { .system(size: s, weight: .bold, design: .monospaced) }
    static func valore(_ s: CGFloat = 13) -> Font { .system(size: s, weight: .semibold, design: .monospaced) }
    /// Il suo file e' tutto in Courier: qui il corpo della chat e' monospazio.
    static func corpo(_ s: CGFloat = 12) -> Font { .system(size: s, weight: .regular, design: .monospaced) }

    /// Come nel suo file: blu notte, alone al centro e **griglia ciano da 30 px**.
    static let sfondo = ZStack {
        LinearGradient(colors: [notte, notteProfonda], startPoint: .top, endPoint: .bottom)
        RadialGradient(colors: [Color(red: 0.0, green: 0.16, blue: 0.31).opacity(0.55), .clear],
                       center: .center, startRadius: 20, endRadius: 900)
        GrigliaCiano(passi: 30)
        RadialGradient(colors: [ciano.opacity(0.07), .clear],
                       center: UnitPoint(x: 0.5, y: -0.15), startRadius: 10, endRadius: 620)
    }
}

/// Pannello del tema olografico: bordo ciano sottile, fondo blu trasparente, glow.
struct PannelloOlografico<Contenuto: View>: View {
    let titolo: String
    var dritta: AnyView? = nil
    @ViewBuilder var contenuto: () -> Contenuto

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text(titolo.uppercased()).font(Olografico.etichetta).tracking(1.7)
                    .foregroundStyle(Olografico.ciano.opacity(0.78))
                Spacer(minLength: 4)
                if let dritta { dritta }
            }
            contenuto()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Olografico.pannello)
        .overlay(Rectangle().stroke(Olografico.bordo))
        .overlay(AngoliCiano(lato: 10, spessore: 2))          // le squadrette del suo CSS
        .background(AngoliCiano(lato: 10, spessore: 2).opacity(0.0))
        .overlay(GeometryReader { _ in Color.clear }
            .background(Olografico.ciano.opacity(0.05)))      // glow interno
        .shadow(color: Olografico.ciano.opacity(0.12), radius: 14, y: 2)
    }
}

/// Le squadrette agli angoli in alto a sinistra e in basso a destra: sono la firma
/// del design che ha portato (`.panel::before` e `::after` nel suo file).
struct AngoliCiano: View {
    var lato: CGFloat = 10
    var spessore: CGFloat = 2
    var colore: Color = Olografico.ciano

    var body: some View {
        ZStack {
            VStack {
                HStack {
                    Rectangle().fill(colore).frame(width: lato, height: spessore)
                    Spacer(minLength: 0)
                }
                .padding(.top, 0).padding(.leading, 0)
                Spacer(minLength: 0)
            }
            VStack {
                Spacer(minLength: 0)
                HStack {
                    Spacer(minLength: 0)
                    Rectangle().fill(colore).frame(width: lato, height: spessore)
                }
                .overlay(alignment: .bottomTrailing) {
                    Rectangle().fill(colore).frame(width: spessore, height: lato)
                        .offset(x: 0, y: 0)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            Rectangle().fill(colore).frame(width: spessore, height: lato)
        }
        .allowsHitTesting(false)
    }
}

/// La griglia ciano di fondo (linee da 1 px ogni 30 px, come `background-image` suo).
struct GrigliaCiano: View {
    var passi: CGFloat = 30
    var body: some View {
        Canvas { zona, dimensione in
            var tratteggio = Path()
            var x: CGFloat = 0
            while x <= dimensione.width {
                tratteggio.move(to: CGPoint(x: x, y: 0))
                tratteggio.addLine(to: CGPoint(x: x, y: dimensione.height))
                x += passi
            }
            var y: CGFloat = 0
            while y <= dimensione.height {
                tratteggio.move(to: CGPoint(x: 0, y: y))
                tratteggio.addLine(to: CGPoint(x: dimensione.width, y: y))
                y += passi
            }
            zona.stroke(tratteggio, with: .color(Olografico.ciano.opacity(0.035)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

/// Una metrica vera con la barretta: il numero arriva dal Mac, non dall'immaginazione.
struct MetricaReale: View {
    let etichetta: String
    let valore: String
    var percentuale: Double? = nil
    var umore: Umore = .buono

    private var colore: Color {
        switch umore { case .buono: return Olografico.ciano; case .attenzione: return Olografico.avviso; case .no: return Olografico.allarme }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(etichetta.uppercased()).font(Olografico.micro(9)).tracking(0.7)
                    .foregroundStyle(Olografico.testoTenue.opacity(0.92))
                Spacer(minLength: 6)
                Text(valore).font(Olografico.valore(11.5)).foregroundStyle(colore)
                    .monospacedDigit().lineLimit(1)
            }
            if let p = percentuale {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Olografico.ciano.opacity(0.13))
                        Capsule().fill(colore)
                            .frame(width: max(3, g.size.width * min(max(p / 100, 0), 1)))
                    }
                }
                .frame(height: 5)
                .clipped()                    // `overflow: hidden` del suo CSS: l'alone resta DENTRO
                // Un alone da 8 px il CSS ce l'ha, ma ritagliato: qui una sfumatura
                // leggera attorno alla barra, non sopra le scritte (era il "sbavato").
                .shadow(color: colore.opacity(0.22), radius: 2)
            }
        }
    }
}

/// Righe del registro: ora vera + cosa e' successa davvero.
struct RigaEvento: View {
    let evento: JarvisCore.Evento
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("[\(evento.ora)]").font(Olografico.micro(8.5)).foregroundStyle(Olografico.ciano.opacity(0.55))
            Text(evento.testo).font(.system(size: 10.5)).foregroundStyle(Olografico.testo.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// La barra in alto: stato, link e orologio — tutti letti, nessuno scritto a mano.
struct BarraStato: View {
    @ObservedObject var core: JarvisCore
    var pausa = false

    var body: some View {
        HStack(spacing: 10) {
            NucleoReattore(diametro: 30, attivo: core.thinking || core.listening,
                           pausa: pausa || core.reattoreFermo)
            Text(Marca.marchio).font(.system(size: 13, weight: .heavy, design: .monospaced)).tracking(3)
                .foregroundStyle(Olografico.ciano)
            Spacer(minLength: 8)
            VoceBarra(nome: "STATUS", valore: stato, umore: core.headline.contains("spento") ? .attenzione : .buono)
            VoceBarra(nome: "MOTORE", valore: pieno(core.diagnostica.motore), umore: .buono)
            VoceBarra(nome: "RETE", valore: pieno(core.diagnostica.rete), umore: .buono)
            VoceBarra(nome: "TEMPO", valore: orologio, umore: .buono)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Olografico.notte.opacity(0.85))
        .overlay(alignment: .bottom) { Rectangle().fill(Olografico.bordo).frame(height: 1) }
    }

    /// "SONNO" deve comparire: se la riga dice ONLINE mentre il piano ha spento tutto
    /// e' una bugia, e lui le bugie a schermo le ha sempre notate.
    private var stato: String {
        if !core.piano.sorveglianza { return "SONNO" }
        return core.headline.contains("spento") ? "PARZIALE" : "ONLINE"
    }

    /// "—" secco fa pensare a un guasto: qui dice che sta ancora leggendo.
    private func pieno(_ v: String) -> String {
        let t = v.trimmingCharacters(in: CharacterSet(charactersIn: " —–"))
        return t.isEmpty ? "IN LETTURA" : v.uppercased()
    }

    private var orologio: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}

/// La vocina "NOME: VALORE" della barra in alto: identica nel pop-up e nella finestra.
struct VoceBarra: View {
    let nome: String
    let valore: String
    var umore: Umore = .buono
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(umore.colore).frame(width: 5, height: 5)
                .shadow(color: umore.colore.opacity(0.9), radius: 4)
            Text(nome).font(Olografico.micro(8)).tracking(1).foregroundStyle(Olografico.testo.opacity(0.45))
                .fixedSize()                                  // "STATUS" non deve andare a capo
            Text(valore).font(Olografico.valore(10)).foregroundStyle(umore.colore)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Olografico.ciano.opacity(0.06))
        .overlay(Rectangle().stroke(Olografico.bordo.opacity(0.6)))
    }
}

/// Il "coso che gira", copiato dal suo file alla misura del suo file: 160 px di
/// contenitore, anello esterno tratteggiato che gira in 20 s, anello di mezzo pieno
/// con lo spigo in alto che gira al contrario in 10 s, anello punteggiato in 15 s e
/// nucleo bianco->ciano da 45 px che pulsa ogni 2 s. Qui le misure sono proporzionali
/// a `diametro` (serve anche da 30 px nella barra), ma il rapporto tra gli anelli e'
/// quello del CSS: 100% / 75% / 50% / 45 px.
/// Il ritmo dice la verita': quando Jarvis pensa o ascolta tutto va piu' veloce.
struct NucleoReattore: View {
    var diametro: CGFloat = 160
    var attivo = false
    var azione: (() -> Void)? = nil
    /// `true` = fermo. Serve per il pop-up della barra: la sua finestra resta viva anche
    /// quando non la guardi, e un anello che gira costa ~25% di CPU (misurato con
    /// `sample`: tutto in `NSHostingView.layout -> ViewGraph...render`).
    var pausa = false

    /// Con `withAnimation(...repeatForever)` SwiftUI tiene accesa la catena di
    /// Core Animation a 120 Hz per ogni reattore: misurato con `sample` sul processo
    /// vivo, il 22% di CPU a riposo era tutto lì. Il tempo di un orologio e un
    /// `TimelineView` che si ferma: 12 fotogrammi al secondo quando è fermo (l'anello
    /// più lento fa un giro in 20 s, quindi si muove di 1,5° per scatto) e 24 quando
    /// pensa. Il movimento è identico, la macchina no.
    private var passo: Double { attivo ? 1.0 / 24.0 : 1.0 / 8.0 }
    private var velocita: Double { attivo ? 0.45 : 1 }

    /// 1 px del file = questo, nel disegno piccolo.
    private var k: CGFloat { diametro / 160 }
    /// Sotto il mezzo millimetro le linee spariscono: il tratto minimo e' 1 px vero.
    private func tratto(_ px: CGFloat) -> CGFloat { max(1, px * k) }

    @ViewBuilder private func reattore(_ t: Double, _ v: Double) -> some View {
        ZStack {
            Circle()
                .stroke(Olografico.ciano.opacity(0.40),
                        style: StrokeStyle(lineWidth: tratto(2), dash: [max(2.5, 4 * k), max(2.5, 4 * k)]))
                .frame(width: diametro, height: diametro)
                .rotationEffect(.degrees(t / (20 * v) * 360))

            Circle()
                .trim(from: 0.25, to: 1.0)
                .stroke(Olografico.ciano, style: StrokeStyle(lineWidth: tratto(2), lineCap: .round))
                .frame(width: diametro * 0.75, height: diametro * 0.75)
                .rotationEffect(.degrees(-t / (10 * v) * 360))
                .shadow(color: Olografico.ciano.opacity(0.75), radius: max(2, 7.5 * k))

            Circle()
                .stroke(Olografico.cianoTenue.opacity(0.55),
                        style: StrokeStyle(lineWidth: max(1, 1 * k), dash: [1, max(2.5, 3 * k)]))
                .frame(width: diametro * 0.50, height: diametro * 0.50)
                .rotationEffect(.degrees(t / (15 * v) * 360))

            Circle()
                .fill(RadialGradient(colors: [.white, Olografico.ciano, .clear],
                                     center: .center, startRadius: 0, endRadius: max(4, 22.5 * k)))
                .frame(width: max(6, 45 * k), height: max(6, 45 * k))
                .scaleEffect(0.92 + 0.23 * (0.5 + 0.5 * sin(t / (2 * v) * 2 * .pi)))
                .opacity(0.82 + 0.18 * (0.5 + 0.5 * sin(t / (2 * v) * 2 * .pi)))
                .shadow(color: Olografico.ciano.opacity(0.9), radius: max(3, 12.5 * k))
                .shadow(color: Olografico.ciano.opacity(0.45), radius: max(6, 25 * k))
        }
        .frame(width: diametro, height: diametro)
        .contentShape(Circle())
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: passo, paused: pausa)) { tempo in
            quadro(tempo.date.timeIntervalSinceReferenceDate)
        }
        .frame(width: diametro, height: diametro)
    }

    /// Il corpo scelto dall'orologio: una funzione, perche' il `content` di
    /// `TimelineView` non e' un ViewBuilder e non puo' avere un `let` in mezzo.
    @ViewBuilder private func quadro(_ orologio: Double) -> some View {
            Group {
                if let azione {
                    Button(action: azione) { reattore(orologio, velocita) }
                        .buttonStyle(.plain)
                        .help("Rilegge le misure vere del Mac")
                } else {
                    reattore(orologio, velocita)
                }
            }
            .frame(width: diametro, height: diametro)
    }
}
