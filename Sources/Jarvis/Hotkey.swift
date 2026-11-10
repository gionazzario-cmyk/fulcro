import Carbon.HIToolbox
import AppKit

/// Scorciatoia globale per aprire/chiudere il microfono senza toccare il Terminale.
/// Usa le Carbon Hot Key: non chiedono permessi di Accessibilita.
final class Hotkey {
    static let shared = Hotkey()

    /// ⌥Spazio: la barra rapida.
    var onPress: (() -> Void)?
    /// ⌥⌘J: rispondi al testo selezionato.
    var onSelezione: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var refSelezione: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static let hotKeyID: UInt32 = 1
    private static let hotKeySelezione: UInt32 = 2
    private static let signature: OSType = 0x4A415253 // "JARS"

    /// Le scorciatoie si registrano (o falliscono) in silenzio: senza questa riga
    /// nel log non si distingue "non funziona" da "non e' mai stata registrata" —
    /// esattamente l'equivoco che e' durato dal 16 ottobre al 2 novembre.
    private static func annota(_ riga: String) {
        let url = AppPaths.jarvisRoot.appendingPathComponent("logs/hotkey.log")
        let testo = "[\(ISO8601DateFormatter().string(from: Date()))] \(riga)\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(testo.data(using: .utf8)!); try? h.close()
        } else {
            try? testo.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func register(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(optionKey)) {
        unregister()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let owner = Unmanaged<Hotkey>.fromOpaque(userData).takeUnretainedValue()
            switch id.id {
            case Hotkey.hotKeyID:      DispatchQueue.main.async { owner.onPress?() }
            case Hotkey.hotKeySelezione: DispatchQueue.main.async { owner.onSelezione?() }
            default: break
            }
            return noErr
        }, 1, &spec, me, &handler)

        let hk = EventHotKeyID(signature: Hotkey.signature, id: Hotkey.hotKeyID)
        let esitoUno = RegisterEventHotKey(keyCode, modifiers, hk, GetEventDispatcherTarget(), 0, &ref)
        Hotkey.annota("⌥Spazio: " + (esitoUno == noErr ? "registrata" : "FALLITA (\(esitoUno))"))

        // ⌥⌘J: leggere il testo selezionato e proporre la risposta
        let hk2 = EventHotKeyID(signature: Hotkey.signature, id: Hotkey.hotKeySelezione)
        let esitoDue = RegisterEventHotKey(UInt32(kVK_ANSI_J), UInt32(optionKey | cmdKey), hk2,
                                           GetEventDispatcherTarget(), 0, &refSelezione)
        Hotkey.annota("⌥⌘J: " + (esitoDue == noErr ? "registrata" : "FALLITA (\(esitoDue))"))
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        if let refSelezione { UnregisterEventHotKey(refSelezione); self.refSelezione = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }
}
