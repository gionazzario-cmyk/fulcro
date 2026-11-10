import Foundation
import IOKit

/// Sensori veri del Mac, letti da utente normale: niente `sudo`, niente `powermetrics`
/// (che pretende root e la sua regola dice che root non lo tocca nessuno).
///
/// Come si legge: l'SMC (`AppleSMC`) espone chiavi a 4 caratteri — `TC0D` die del CPU,
/// `TC0E`/`TC0F` potenza, `TG0D` GPU, `Tp0K`/`STRM` SSD, `TB0T` batteria, `TA0P` aria.
/// I nomi NON sono uguali tra i modelli: per questo ogni sensore qui prova una lista di
/// chiavi e, se nessuna risponde, dice onestamente "non leggibile" invece di mettere un
/// numero a caso. `--sensori` stampa cosa si riesce a leggere su QUESTO Mac.
enum Sensori {
    // ------------------------------------------------------- struttura SMC
    // `reserved` sono TRE byte, non uno: con uno solo la struct veniva 78 byte e il
    // kernel rispondeva kIOReturnBadArgument (0xE00002C2) a ogni chiave.
    private struct Versione { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0
                           var reserved: (UInt8, UInt8, UInt8) = (0, 0, 0); var release: UInt16 = 0 }
    private struct PLimit { var version: UInt16 = 0; var vType: UInt16 = 0; var attributes: UInt16 = 0; var size: UInt16 = 0; var cpuLimit: UInt32 = 0; var ioLimit: UInt32 = 0 }  // 16 byte, contati
    private struct InfoChiave { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }

    private struct Chiave {
        var key: UInt32 = 0
        var vers = Versione()
        var pLimit = PLimit()
        var info = InfoChiave()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        // `spareBytes[3]` del C: senza questi tre byte la struct veniva 76 e il kernel
        // rispondeva kIOReturnBadArgument a tutto (0xE00002C2)
        var spare: (UInt8, UInt8, UInt8) = (0, 0, 0)
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
             0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    // L'interfaccia utente dell'SMC ha UN solo indice di funzione (2): il comando vero
    // sta nel campo `data8` della struct. Avere messo gli indizi al posto dei comandi e'
    // il perche' del primo tentativo fallito (tutti "non leggibile" sull'M1 Max).
    private static let indice = 2
    private static let cmdVersione = 0
    private static let cmdChiave = 9
    private static let cmdLettura = 5

    private static func quattro(_ s: String) -> UInt32 {
        var v: UInt32 = 0
        for c in s.utf8.prefix(4) { v = (v << 8) + UInt32(c) }
        return v << ((4 - min(s.utf8.count, 4)) * 8)
    }

    private static func nome(_ raw: UInt32) -> String {
        String(bytes: [UInt8((raw >> 24) & 0xFF), UInt8((raw >> 16) & 0xFF),
                       UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF)].filter { $0 != 0 },
               encoding: .ascii) ?? "?"
    }

    private static let conn: io_connect_t? = {
        let servizio = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard servizio != 0 else { return nil }
        defer { IOObjectRelease(servizio) }
        var c = io_connect_t(0)
        return IOServiceOpen(servizio, mach_task_self_, 0, &c) == KERN_SUCCESS ? c : nil
    }()

    /// Chiave -> byte grezzi. Ritorna nil se la chiave non esiste su questo Mac.
    private static func grezzi(_ chiave: String) -> (Data, UInt32, UInt32)? {
        guard let conn else { return nil }
        var input = Chiave()
        var output = Chiave()
        var dimensioneIn = MemoryLayout<Chiave>.stride
        var dimensioneOut = MemoryLayout<Chiave>.stride
        // 1) info della chiave: quanto e' grande e che tipo ha
        input.key = quattro(chiave)
        input.data8 = UInt8(cmdChiave)
        dimensioneIn = MemoryLayout<Chiave>.stride
        dimensioneOut = MemoryLayout<Chiave>.stride
        if IOConnectCallStructMethod(conn, UInt32(indice), &input, dimensioneIn, &output, &dimensioneOut) != KERN_SUCCESS { return nil }
        let info = output.info
        guard info.dataSize > 0 else { return nil }
        // 2) i byte veri
        input = output
        input.key = quattro(chiave)
        input.data8 = UInt8(cmdLettura)
        dimensioneIn = MemoryLayout<Chiave>.stride
        dimensioneOut = MemoryLayout<Chiave>.stride
        if IOConnectCallStructMethod(conn, UInt32(indice), &input, dimensioneIn, &output, &dimensioneOut) != KERN_SUCCESS { return nil }
        guard output.result == 0 else { return nil }
        var byte = Data(capacity: Int(info.dataSize))
        withUnsafeBytes(of: output.bytes) { grezzo in
            byte.append(contentsOf: grezzo.prefix(Int(info.dataSize)))
        }
        return (byte, info.dataType, info.dataSize)
    }

    /// Le chiavi di temperatura usano il tipo `sp78` (int a 8.8 con segno) o `flt `.
    private static func numero(_ chiave: String) -> Double? {
        guard let (byte, tipo, _) = grezzi(chiave) else { return nil }
        switch nome(tipo) {
        case "sp78":
            guard byte.count >= 2 else { return nil }
            let unitario = UInt16(bigEndian: UInt16(byte[0]) << 8 | UInt16(byte[1]))
            return Double(Int16(bitPattern: unitario)) / 256.0
        case "flt ":
            guard byte.count >= 4 else { return nil }
            return Double(Float(bitPattern: UInt32(byte[0]) | UInt32(byte[1]) << 8 | UInt32(byte[2]) << 16 | UInt32(byte[3]) << 24))
        case "ui8 ", "ui16", "ui32", "ioft", "ui64":
            var v: UInt64 = 0
            for b in byte { v = (v << 8) | UInt64(b) }
            return Double(v)
        default:
            return nil
        }
    }

    // ------------------------------------------------------- cosa chiede lui
    struct Lettura {
        var nome: String
        var uso: String?
        var temperatura: String
        var disponibile: Bool
    }

    /// Le chiavi provate per ciascun pezzo, in ordine: il primo che risponde vince.
    static let chiaviCalore: [String: [String]] = [
        "CPU": ["TC0D", "TC0E", "TC0F", "TC0H", "TC09", "TC0P", "TCAD"],
        "GPU": ["TG0D", "TG0E", "TG0F", "TG0P", "TG05", "TG0A"],
        "SSD": ["Tp0K", "Tp04", "TPD0", "STRM", "Ts0P"],
        "Batteria": ["TB0T", "TB1T", "TB2T"],
        "Aria": ["TA0P", "TA1P", "TH0P"]
    ]

    /// L'ultima lettura di uso CPU fatta da qualcuno (il campione vive 2 secondi).
    static var ultimaCpu: Double?

    static var strideStruct: Int { MemoryLayout<Chiave>.stride }
    static func misure() -> String {
        "chiave \(MemoryLayout<UInt32>.stride) + vers \(MemoryLayout<Versione>.stride) + plimit \(MemoryLayout<PLimit>.stride) + info \(MemoryLayout<InfoChiave>.stride) = totale \(MemoryLayout<Chiave>.stride)"
    }

    /// Cosa risponde l'SMC passo per passo: serve per non tirare a indovinare perche'
    /// una temperatura non arriva.
    static func diagnosticaSmc(_ chiave: String) -> String {
        guard IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC")) != 0 else {
            return "servizio AppleSMC non trovato"
        }
        let servizio = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        var c = io_connect_t(0)
        let aperto = IOServiceOpen(servizio, mach_task_self_, 0, &c)
        IOObjectRelease(servizio)
        guard aperto == KERN_SUCCESS else { return "IOServiceOpen -> " + String(aperto) }
        var input = Chiave()
        var output = Chiave()
        var din = MemoryLayout<Chiave>.stride
        var dout = MemoryLayout<Chiave>.stride
        input.key = quattro(chiave)
        input.data8 = UInt8(cmdChiave)
        let k = IOConnectCallStructMethod(c, UInt32(indice), &input, din, &output, &dout)
        if k != KERN_SUCCESS { return "chiave \(chiave): keyInfo -> kern \(k), result \(output.result), dataType \(nome(output.info.dataType)), size \(output.info.dataSize)" }
        input = output
        input.key = quattro(chiave)
        input.data8 = UInt8(cmdLettura)
        din = MemoryLayout<Chiave>.stride
        dout = MemoryLayout<Chiave>.stride
        let r = IOConnectCallStructMethod(c, UInt32(indice), &input, din, &output, &dout)
        IOServiceClose(c)
        return "chiave \(chiave): keyInfo ok (tipo \(nome(output.info.dataType)) size \(output.info.dataSize)), read -> kern \(r) result \(output.result)"
    }

    /// La temperatura di un pezzo, o nil se questo Mac non la vuole dare.
    static func temperatura(_ pezzo: String) -> String? {
        guard let chiavi = chiaviCalore[pezzo] else { return nil }
        for k in chiavi {
            if let v = numero(k), v > 0, v < 120 { return String(format: "%.1f °C", v) }
        }
        return nil
    }

    /// Spazio vero sul disco di avvio.
    static func spazioDisco() -> String {
        let url = URL(fileURLWithPath: "/")
        guard let d = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) else { return "—" }
        let totale = Double(d.volumeTotalCapacity ?? 0) / 1_000_000_000
        let liberi = Double(d.volumeAvailableCapacityForImportantUsage ?? 0) / 1_000_000_000
        guard totale > 0 else { return "—" }
        return String(format: "%.0f / %.0f GB liberi", liberi, totale)
    }

    static func percentualePieno() -> Double {
        let url = URL(fileURLWithPath: "/")
        guard let d = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let totale = d.volumeTotalCapacity, totale > 0 else { return 0 }
        let liberi = Double(d.volumeAvailableCapacityForImportantUsage ?? 0)
        return max(0, min(100, 100 - liberi / Double(totale) * 100))
    }

    /// Una riga per componente, con quello che si puo' misurare davvero.
    static func tutte() -> [Lettura] {
        let cpu = ultimaCpu
        let ram = usoRam()
        var fuori: [Lettura] = []
        for (pezzo, chiavi) in chiaviCalore where pezzo != "Aria" {
            let t = chiavi.lazy.compactMap { numero($0) }.first
            var uso: String? = nil
            if pezzo == "CPU" { uso = cpu.map { String(format: "%.0f%%", $0) } }
            if pezzo == "RAM" { uso = ram?.percentuali }
            fuori.append(Lettura(nome: pezzo, uso: uso,
                                 temperatura: t.map { String(format: "%.1f °C", $0) } ?? "non leggibile",
                                 disponibile: t != nil))
        }
        fuori.sort { ordine($0.nome) < ordine($1.nome) }
        return fuori
    }

    private static func ordine(_ n: String) -> Int {
        ["CPU": 0, "GPU": 1, "SSD": 2, "Batteria": 3].first(where: { $0.key == n })?.value ?? 9
    }

    /// RAM attiva+wired, con la stessa matematica della finestra: il compresso non si
    /// legge da questa struct, e chiamarla "RAM usata" sarebbe un numero a meta'.
    static func usoRam() -> (giga: String, percentuali: String)? {
        let fisica = ProcessInfo.processInfo.physicalMemory
        var stat = vm_statistics64()
        var numero = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let esito = withUnsafeMutablePointer(to: &stat) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(numero)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &numero)
            }
        }
        guard esito == KERN_SUCCESS, fisica > 0 else { return nil }
        let pagina = UInt64(vm_kernel_page_size)
        let usata = (UInt64(stat.active_count) + UInt64(stat.wire_count) + UInt64(stat.speculative_count)) * pagina
        let percentuale = Double(usata) / Double(fisica) * 100
        return (String(format: "%.0f / %.0f GB", Double(usata) / 1_073_741_824, Double(fisica) / 1_073_741_824),
                String(format: "%.0f%%", percentuale))
    }

    /// Uso CPU reale: delta dei tick tra due chiamate (host_cpu_load_info).
    /// Serve chiamare `cpuPerCento()` due volte a distanza di un secondo: la prima
    /// misura il passato e ritorna nil, la seconda dà il numero buono.
    /// I quattro stati sono USER, SYSTEM, IDLE, NICE in quest'ordine: il primo
    /// tentativo prendeva `cpu_ticks.0` per "inattivo" (che e' USER) e il Mac, che
    /// con `top` stava al 39%, in finestra segnava 75% — ecco perche' la lettura dei
    /// tick e il calcolo sono separati, e il calcolo ha un test suo.
    private static var ultimoCampione: (utente: UInt64, sistema: UInt64, inattivo: UInt64, nice: UInt64, quando: Date)?

    /// Quanto CPU e' stata davvero occupata in un blocco di tick.
    static func percentualeDaTick(utente: UInt64, sistema: UInt64, inattivo: UInt64, nice: UInt64) -> Double {
        let totale = utente + sistema + inattivo + nice
        guard totale > 0 else { return 0 }
        return max(0, min(100, (1 - Double(inattivo) / Double(totale)) * 100))
    }

    static func cpuPerCento() -> Double? {
        var info = host_cpu_load_info()
        var numero = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let esito = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(numero)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &numero)
            }
        }
        guard esito == KERN_SUCCESS else { return nil }
        let utente = UInt64(info.cpu_ticks.0)      // CPU_STATE_USER
        let sistema = UInt64(info.cpu_ticks.1)     // CPU_STATE_SYSTEM
        let inattivo = UInt64(info.cpu_ticks.2)    // CPU_STATE_IDLE  <- questo, non .0
        let nice = UInt64(info.cpu_ticks.3)        // CPU_STATE_NICE
        defer { ultimoCampione = (utente, sistema, inattivo, nice, Date()) }
        guard let vecchio = ultimoCampione else { return nil }
        let dU = utente - vecchio.utente
        let dS = sistema - vecchio.sistema
        let dI = inattivo - vecchio.inattivo
        let dN = nice - vecchio.nice
        let v = percentualeDaTick(utente: dU, sistema: dS, inattivo: dI, nice: dN)
        ultimaCpu = v
        return v
    }
}
