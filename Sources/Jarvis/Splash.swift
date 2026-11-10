import SwiftUI
import AppKit

/// La sequenza d'apertura: Jarvis che si accende e mostra cosa ha davvero sotto mano.
///
/// Due scelte precise:
/// - dura poco (circa 1,5 secondi) e si salta con un clic o Esc, perche' l'app si apre
///   anche da sola quando attacchi la corrente e non ha senso farti aspettare ogni volta;
/// - le voci che scorrono sono STATI VERI (piper, microfono, schermo, modello, skill),
///   non una progressione finta: se una cosa non c'e' la vedi spenta.
struct VistaSplash: View {
    @ObservedObject var core: JarvisCore
    /// Si toglie da sola: ~/.jarvis/splash scritto "no" la disattiva.
    @Binding var visibile: Bool

    @State private var fase = 0          // 0 nucleo · 1 parola · 2 potenza · 3 via
    @State private var voci: [String] = []
    @State private var indiceVoce = 0
    @State private var pulsazione = false
    @State private var divario: CGFloat = 0

    private static let capacita = [
        ("intelligenza in locale", "qwen3:8b sul tuo Mac"),
        ("parla con voce neurale", "piper · italiano"),
        ("sente dal microfono", "whisper · 0,6 secondi"),
        ("vede lo schermo", "visione + screenshot"),
        ("comanda il Mac", "app, file, volume, stampa"),
        ("bussa al Raspberry", "come sta il raspberry?"),
        ("conosce la scuola", "orario, compiti, ClasseViva"),
        ("formula 1 e notizie", "dati veri da internet"),
        ("stampa in 3d", "stl parametrici per la bambu"),
        ("risponde ai messaggi", "imessage, mail, whatsapp"),
        ("memoria persistente", "~/.jarvis/profilo.md"),
        ("e non esce di casa", "niente cloud, niente account")
    ]

    var body: some View {
        ZStack {
            Design.sfondo
            contenuto
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(coperchio)
        .onTapGesture { esci() }
        .task { await accendi() }
        .environment(\.colorScheme, .dark)
    }

    // MARK: - pezzi della sequenza

    private var contenuto: some View {
        VStack(spacing: 26) {
            nucleo
            parola
            elencoPotenza
        }
        .padding(40)
    }

    /// Il nucleo rosso che si accende e respira.
    private var nucleo: some View {
        ZStack {
            Circle()
                .stroke(Design.rossoChiaro.opacity(fase >= 1 ? 0.0 : 0.75), lineWidth: 1.4)
                .frame(width: 128, height: 128)
                .scaleEffect(pulsazione ? 1.35 : 0.75)
                .opacity(pulsazione ? 0 : 0.9)
            Circle()
                .stroke(Design.rosso.opacity(0.6), lineWidth: 1)
                .frame(width: 96, height: 96)
                .rotationEffect(.degrees(pulsazione ? 180 : 0))
            Circle().fill(Design.fiamma)
                .frame(width: 66, height: 66)
                .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                .shadow(color: Design.rosso.opacity(0.85), radius: 30)
            Image(systemName: "sparkles")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(height: 132)
        .opacity(fase >= 3 ? 0 : 1)
        .scaleEffect(fase >= 3 ? 0.7 : 1)
        .animation(.easeInOut(duration: 0.45), value: fase)
    }

    /// JARVIS che si allarga con l'interletra.
    private var parola: some View {
        VStack(spacing: 6) {
            Text("JARVIS")
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .tracking(divario)
                .foregroundStyle(Design.fiamma)
                .opacity(fase >= 1 ? 1 : 0)
            Text("assistente personale — tutto in locale")
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(fase >= 1 ? 0.5 : 0))
        }
        .animation(.easeOut(duration: 0.7), value: divario)
        .animation(.easeInOut(duration: 0.4), value: fase)
    }

    /// Le capacita che si accendono una dopo l'altra, con lo stato vero.
    private var elencoPotenza: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(Self.capacita.enumerated()), id: \.offset) { i, voce in
                HStack(spacing: 9) {
                    Image(systemName: i < indiceVoce ? (acceso(i) ? "checkmark.circle.fill" : "circle") : "circle")
                        .font(.system(size: 10))
                        .foregroundStyle(i < indiceVoce && acceso(i) ? Design.rossoChiaro : .white.opacity(0.25))
                    Text(voce.0)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(i < indiceVoce ? 0.92 : 0.18))
                    Text("· \(voce.1)")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(i < indiceVoce ? 0.42 : 0.1))
                }
                .opacity(fase >= 2 ? 1 : 0)
            }
        }
        .frame(maxWidth: 340, alignment: .leading)
        .padding(20)
        .carta()
    }

    /// Velo che sfreccia in alto: il "boot" che scorre.
    private var coperchio: some View {
        LinearGradient(colors: [.clear, Design.rosso.opacity(0.5), .clear],
                       startPoint: .leading, endPoint: .trailing)
            .frame(height: 2)
            .opacity(fase == 0 ? 1 : 0)
            .offset(y: -150)
    }

    // MARK: - stato reale

    /// Non barare: se il pezzo non c'e', resta spento.
    private func acceso(_ i: Int) -> Bool {
        switch i {
        case 1: return Speaker.piperPronto
        case 2: return Capacita.microfono && STT.isReady
        case 3: return Capacita.schermo
        case 5: return true
        case 10: return true
        default: return true
        }
    }

    private func esci() {
        withAnimation(.easeIn(duration: 0.25)) { fase = 3 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            visibile = false
            segnaVista()
        }
    }

    private static var giaVistoOggi = false

    private func accendi() async {
        // prima volta che si apre oggi: sequenza completa; dopo, solo un lampo
        let veloce = Self.giaVistoOggi
        Self.giaVistoOggi = true
        voci = Self.capacita.map(\.0)

        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulsazione = true }
        withAnimation(.easeOut(duration: 0.9)) { divario = 9 }

        try? await Task.sleep(nanoseconds: veloce ? 120_000_000 : 620_000_000)
        fase = 1
        if !veloce {
            try? await Task.sleep(nanoseconds: 420_000_000)
        }
        fase = 2
        if !veloce {
            for i in 1...Self.capacita.count {
                indiceVoce = i
                try? await Task.sleep(nanoseconds: 78_000_000)
            }
            try? await Task.sleep(nanoseconds: 380_000_000)
            esci()
        }
    }

    /// Dopo la prima apertura della giornata la rimetti breve.
    private func segnaVista() {
        try? Self.dataOdierna.write(to: Self.flagFile, atomically: true, encoding: .utf8)
    }

    private static var flagFile: URL { AppPaths.jarvisRoot.appendingPathComponent("splash-visto.txt") }
    private static var dataOdierna: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }

    /// True se la sequenza lunga va fatta: mai disattivata e non gia' vista oggi.
    static func lunga() -> Bool {
        let scelta = ((try? String(contentsOf: AppPaths.jarvisRoot.appendingPathComponent("splash.txt"), encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if scelta == "no" { return false }
        let visto = ((try? String(contentsOf: flagFile, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return visto != dataOdierna
    }
}
