import SwiftUI
import AppKit
import ApplicationServices

/// Il testo selezionato nell'app davanti, letto tramite Accessibilita'.
///
/// Serve per il gesto che rende Jarvis utile davvero: selezioni il messaggio che ti
/// hanno scritto, premi ⌥⌘J, e lui scrive la risposta. Senza il permesso di
/// Accessibilita' non si inventa niente: si apre la barra vuota e si dice perche'.
enum TestoSelezionato {
    static func leggi() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let sistema = AXUIElementCreateSystemWide()
        var elemento: AnyObject?
        guard AXUIElementCopyAttributeValue(sistema, kAXFocusedUIElementAttribute as CFString, &elemento) == .success,
              let el = elemento else { return nil }
        guard CFGetTypeID(el) == AXUIElementGetTypeID() else { return nil }
        var valore: AnyObject?
        guard AXUIElementCopyAttributeValue(el as! AXUIElement, kAXSelectedTextAttribute as CFString, &valore) == .success,
              let testo = valore as? String else { return nil }
        let pulito = testo.trimmingCharacters(in: .whitespacesAndNewlines)
        return pulito.isEmpty ? nil : pulito
    }

    /// Rimette un testo nell'app che c'era davanti, come se l'avessi incollato tu.
    static func incolla(_ testo: String, in app: NSRunningApplication?) {
        let tavola = NSPasteboard.general
        tavola.clearContents()
        tavola.setString(testo, forType: .string)
        app?.activate(options: [])
        // un attimo perche' il cambio di applicazione sia finito prima del ⌘V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard let sorgente = CGEventSource(stateID: .hidSystemState) else { return }
            let giu = CGEvent(keyboardEventSource: sorgente, virtualKey: 9, keyDown: true)   // V
            let su = CGEvent(keyboardEventSource: sorgente, virtualKey: 9, keyDown: false)
            giu?.flags = .maskCommand
            su?.flags = .maskCommand
            giu?.post(tap: .cghidEventTap)
            su?.post(tap: .cghidEventTap)
        }
    }
}

/// La barra che scende dal cielo con ⌥Spazio: un campo, Invio, e la risposta sotto.
///
/// E' il modo "da una riga" di usare Jarvis senza aprire la finestra: quello che
/// scrivi entra nella stessa chat, quindi lo ritrovi nella cronologia.
@MainActor
final class BarraRapida: ObservableObject {
    static let shared = BarraRapida()

    enum Modo { case chiedi, rispondi }

    @Published private(set) var modo: Modo = .chiedi
    @Published private(set) var selezione = ""
    @Published private(set) var indicePartenza = 0
    private var pannello: PannelloChiave?
    private var appPrima: NSRunningApplication?

    var visibile: Bool { pannello?.isVisible == true }

    func alterna() {
        if visibile { chiudi() } else { apri(selezione: nil) }
    }

    /// ⌥⌘J: se c'e' un testo selezionato, la barra parte gia' in modalita' risposta.
    func apriConSelezione() {
        let testo = TestoSelezionato.leggi()
        if testo == nil, !Capacita.accessibilita {
            Capacita.chiediAccessibilita()
        }
        apri(selezione: testo)
    }

    func apri(selezione: String?) {
        appPrima = NSWorkspace.shared.frontmostApplication
        let core = JarvisCore.shared
        indicePartenza = core.bubbles.count
        self.selezione = selezione ?? ""
        modo = selezione == nil ? .chiedi : .rispondi
        core.draft = ""

        if pannello == nil { costruisci() }
        guard let p = pannello else { return }
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        posiziona(p, larga: false)
    }

    private func costruisci() {
        let p = PannelloChiave(contentRect: NSRect(x: 0, y: 0, width: 640, height: 96),
                               styleMask: [.borderless],
                               backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = true
        p.contentView = NSHostingView(rootView: VistaBarra(core: JarvisCore.shared, barra: self))
        pannello = p
    }

    private func posiziona(_ p: NSPanel, larga: Bool) {
        let schermo = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let larghezza: CGFloat = 640
        let altezza: CGFloat = larga ? 340 : (selezione.isEmpty ? 96 : 136)
        let x = schermo.midX - larghezza / 2
        let y = schermo.maxY - altezza - 90
        p.setFrame(NSRect(x: x, y: y, width: larghezza, height: altezza), display: true, animate: false)
    }

    /// La barra si allunga quando c'e' una risposta da leggere.
    func allarga(_ si: Bool) {
        guard let p = pannello else { return }
        posiziona(p, larga: si)
    }

    func chiudi() {
        pannello?.orderOut(nil)
    }

    /// Quello che e' stato detto DOPO l'apertura: cosi' non si vede la chat vecchia.
    func risposta(core: JarvisCore) -> String {
        core.bubbles.dropFirst(indicePartenza).last(where: { $0.role == "jarvis" })?.text ?? ""
    }

    func invia(_ testo: String) {
        let pulito = testo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pulito.isEmpty, !JarvisCore.shared.thinking else { return }
        let daMandare: String
        if modo == .rispondi, !selezione.isEmpty {
            daMandare = "Rispondi a questo messaggio, nel mio tono, senza spiegazioni e senza virgolette: «\(selezione)»"
        } else {
            daMandare = pulito
        }
        JarvisCore.shared.draft = ""
        allarga(true)
        Task { await JarvisCore.shared.handle(userText: daMandare, source: "rapida") }
    }

    /// Mette la risposta nell'app da cui sei partito, come se l'avessi incollata.
    func incollaNellAppPrima(_ testo: String) {
        let app = appPrima
        chiudi()
        TestoSelezionato.incolla(testo, in: app)
    }
}

final class PannelloChiave: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct VistaBarra: View {
    @ObservedObject var core: JarvisCore
    @ObservedObject private var barra: BarraRapida
    @FocusState private var fuoco: Bool
    @State private var lampeggia = false

    init(core: JarvisCore, barra: BarraRapida) {
        self.core = core
        self.barra = barra
    }

    private var risposta: String { barra.risposta(core: core) }
    private var haRisposta: Bool { !risposta.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().stroke(Olografico.ciano.opacity(core.thinking ? 0.9 : 0.45), lineWidth: 1.2)
                    Circle()
                        .fill(RadialGradient(colors: [Olografico.ciano.opacity(0.95), Olografico.ciano.opacity(0.15)],
                                             center: .center, startRadius: 1, endRadius: 9))
                        .padding(4)
                        .scaleEffect(core.thinking && lampeggia ? 1.15 : 1.0)
                }
                .frame(width: 20, height: 20)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: lampeggia)

                TextField(barra.modo == .rispondi ? "Come rispondo?" : "Chiedi qualcosa…", text: $core.draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))
                    .focused($fuoco)
                    .onSubmit { barra.invia(core.draft) }

                if core.thinking {
                    ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14)
                } else {
                    Button {
                        barra.chiudi()
                        JarvisCore.shared.toggleTalk()
                    } label: {
                        Image(systemName: "mic").font(.system(size: 12))
                            .foregroundStyle(Olografico.ciano.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help("Parla invece di scrivere")
                    Text("↵").font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.3))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 13)

            if !barra.selezione.isEmpty {
                HStack(spacing: 6) {
                    Rectangle().fill(Olografico.ciano.opacity(0.35)).frame(width: 2, height: 26)
                    Text(barra.selezione)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.bottom, 10)
            }

            if haRisposta {
                Rectangle().fill(Olografico.bordoTenue).frame(height: 1)
                ScrollView {
                    Text(risposta)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                }
                .frame(maxHeight: 190)

                HStack(spacing: 8) {
                    if barra.modo == .rispondi {
                        BottoneBarra(titolo: "Incolla in \(nomeAppPrima)", icona: "arrow.down.doc") {
                            barra.incollaNellAppPrima(risposta)
                        }
                    }
                    BottoneBarra(titolo: "Copia", icona: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(risposta, forType: .string)
                    }
                    BottoneBarra(titolo: "Apri la chat", icona: "macwindow") {
                        barra.chiudi()
                        JarvisCore.shared.portaFinestraAvanti()
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.bottom, 10)
            }
        }
        .background(
            ZStack {
                pannelloScuro
                LinearGradient(colors: [Olografico.ciano.opacity(0.08), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        )
        .overlay(Rectangle().stroke(Olografico.ciano.opacity(0.35), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 22, y: 10)
        .onAppear { fuoco = true; lampeggia.toggle() }
        .onExitCommand { barra.chiudi() }
    }

    private var nomeAppPrima: String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "app"
    }
}

struct BottoneBarra: View {
    let titolo: String
    let icona: String
    let azione: () -> Void

    var body: some View {
        Button(action: azione) {
            HStack(spacing: 5) {
                Image(systemName: icona).font(.system(size: 9))
                Text(titolo).font(.system(size: 10, weight: .medium, design: .rounded))
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Olografico.ciano.opacity(0.14))
            .overlay(Rectangle().stroke(Olografico.ciano.opacity(0.4), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Olografico.ciano)
    }
}
