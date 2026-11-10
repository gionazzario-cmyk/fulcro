import Foundation

/// Il cancello della shell: decide se un comando si puo fare subito,
/// se serve il clic dell'utente, o se non si fa proprio.
///
/// Livelli decisi dall'utente il 2026-10-17 ("accesso pieno, conferma solo per le
/// cose pericolose"): tutto cio' che si puo annullare o che non tocca il sistema
/// parte subito; rm, push, permessi di sistema e cartelle altrui chiedono un clic;
/// sudo, portachiavi, `.ssh`, i permessi TCC e l'archivio di Matteo non si fanno.
enum ShellGate {
    enum Verdict: Equatable {
        case allowed
        case confirm
        case blocked(String)
    }

    /// Comandi che leggono e basta. `nil` = sicuro in ogni forma,
    /// altrimenti solo con uno di quei primi argomenti.
    private static let readOnly: [String: [String]?] = [
        "ls": nil, "cat": nil, "head": nil, "tail": nil, "wc": nil, "du": nil, "df": nil,
        "pwd": nil, "whoami": nil, "stat": nil, "file": nil, "which": nil, "type": nil,
        "grep": nil, "rg": nil, "sort": nil, "uniq": nil, "cut": nil, "tr": nil,
        "ps": nil, "pgrep": nil, "lsof": nil, "uptime": nil, "sw_vers": nil, "uname": nil,
        "date": nil, "ioreg": nil, "system_profiler": nil, "arp": nil, "ping": nil,
        "traceroute": nil, "dig": nil, "nslookup": nil, "lpstat": nil, "diff": nil,
        "vm_stat": nil, "qlmanage": nil, "id": nil, "basename": nil, "dirname": nil,
        "find": nil, "mdfind": nil, "mdls": nil, "tree": nil, "realpath": nil,
        "top": ["-l", "-n", "-o", "-stats"], "htop": ["-n"],
        "sysctl": ["-a", "-n", "-d"],
        "pmset": ["-g"],
        "ifconfig": ["-a"],
        "route": ["-n", "get"],
        "plutil": ["-p"],
        "git": ["status", "log", "diff", "show", "branch", "blame", "remote", "config", "ls-files"],
        "brew": ["list", "info", "search", "config", "doctor"],
        "ollama": ["list", "ls", "ps", "show", "-v", "--version"],
        // "run" non e' in sola lettura: esegue il progetto (e i suoi script di build)
        "swift": ["--version", "-version"],
        "xcodebuild": ["-version"],
        "java": ["-version"],
        "node": ["-v", "--version"],
        "python3": ["--version"],
        "sips": ["-g"],
        "codesign": ["-dv", "--verify"],
        "sqlite3": nil
    ]

    /// Comandi che scrivono ma non fanno danni irreparabili: via libera.
    /// Sono tutti dentro le cartelle dell'utente o dentro un progetto suo.
    private static let writeOk: [String: [String]?] = [
        "touch": nil, "mkdir": nil, "cp": nil, "mv": nil, "ln": nil, "rsync": nil,
        "open": nil, "echo": nil, "printf": nil, "sed": ["-i"], "tar": ["-czf", "-xf", "-xzf"],
        "zip": nil, "unzip": nil,
        // "swift run", "make", "npx", "npm", "cargo", "pip", "brew install" NON sono
        // piu' via libera: ognuno esegue codice che non ha scritto Jarvis (un Makefile,
        // un pacchetto, uno script di build). Restavano senza clic, quindi bastava una
        // pagina web ostile letta con `leggi_pagina` per far eseguire codice.
        "swift": ["build", "test"],
        "git": ["add", "commit", "checkout", "switch", "restore", "stash", "pull", "fetch", "init", "clone"],
        "chmod": ["+x", "u+x", "755", "644", "700"],
        "defaults": ["read"]
    ]

    /// Robe che non si fanno: distruttive, di sicurezza, o fuori dai limiti dati dall'utente.
    private static let never: [(String, String)] = [
        ("sudo", "serve root: lo digiti tu nel Terminale, non io"),
        ("rm -rf /", "cancella il disco"),
        ("rm -rf \"\"", "cancella tutto il contenuto di una variabile vuota"),
        ("mkfs", "formatta il volume"),
        ("dd if=", "scrive crudo sul disco"),
        (":(){", "fork bomb"),
        ("csrutil", "disattiva la protezione di sistema"),
        ("security delete", "cancella cose dal portachiavi"),
        ("keychain", "il portachiavi non si tocca"),
        ("tcc.db", "i permessi di privacy del Mac non si leggono"),
        (".ssh", "chiavi SSH"),
        ("id_rsa", "chiavi SSH"),
        ("matteo", "cartella e codice di Matteo: fuori limite per tua scelta"),
        ("git push --force", "sovrascrive il lavoro altrui"),
        ("git reset --hard", "butta via modifiche non salvate"),
        ("git clean -f", "cancella file non tracciati"),
        ("dscl", "utenti di sistema"),
        ("chown -r /", "cambia il proprietario di tutto il disco"),
        ("chmod -r 777", "apre tutto a tutti"),
        ("pmset sleepnow", "addormenta il Mac"),
        ("shutdown", "spegne il Mac"),
        ("osascript -e 'tell application \"System Events\" to shut down", "spegne il Mac")
    ]

    /// Cartelle di sistema dove non si scrive mai senza un clic.
    private static let zoneDiSistema = ["/system", "/usr/", "/bin/", "/sbin/", "/etc/",
                                        "/library/", "/private/var/root", "/applications/",
                                        // i file che vengono eseguiti a ogni nuovo Terminale
                                        ".zshrc", ".zprofile", ".bash_profile", ".bashrc"]

    static func classify(_ command: String) -> Verdict {
        let lower = command.lowercased()
        for (needle, why) in never where lower.contains(needle) {
            return .blocked(why)
        }

        // Cancella tutto il disco o tutta la casa: non si fa, col clic o senza.
        if let re = try? NSRegularExpression(pattern: #"rm\s+-[rRf]{1,2}\s+(~|"~"|\$HOME|/)(\s|$)"#) {
            let r = NSRange(lower.startIndex..., in: lower)
            if re.firstMatch(in: lower, range: r) != nil {
                return .blocked("cancella la casa o il disco intero")
            }
        }
        // Cancellare chiede sempre il clic: e' l'unica cosa che non si annulla.
        for shape in ["rm ", "rm\t", "rmdir", "unlink", "shred", " trash"] where lower.contains(shape) {
            return .confirm
        }
        // Scrivere fuori dalla casa dell'utente, o cambiare permessi/proprietari pesanti.
        for zona in zoneDiSistema where lower.contains(zona) {
            return .confirm
        }
        // Un redirect, una sostituzione o un pipe che esegue codice: un clic, non di corsa.
        for shape in ["$(", "`", ">", ">>", "tee", "yes |", "| xargs", "eval", "source ",
                      "&& rm", ";rm", "| sh", "| bash", "curl -o /usr", "launchctl load",
                      "launchctl unload", "chmod -r", "chown"]
        where lower.contains(shape) {
            return .confirm
        }
        // git push: tocca gli altri, non solo il Mac di casa.
        if lower.contains("git push") { return .confirm }
        // find esegue e scrive da solo: questi primari non sono "solo lettura".
        for primary in ["-exec", "-execdir", "-ok", "-delete", "-fprint", "-fprintf", "-fls"]
        where lower.contains(primary) {
            return .confirm
        }

        var pieces = [Substring]()
        for chunk in command.split(whereSeparator: { $0 == "|" || $0 == ";" || $0 == "\n" || $0 == "&" }) {
            pieces.append(chunk)
        }
        if pieces.isEmpty { return .confirm }

        for piece in pieces {
            let words = piece.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let firstWord = words.first else { continue }
            let base = (String(firstWord).lowercased() as NSString).lastPathComponent
            let secondo = words.dropFirst().first.map { String($0).lowercased() }

            // prima i comandi che scrivono in modo reversibile, poi quelli che leggono:
            // se il sottocomando non e' in nessuna delle due liste, serve il clic
            var viaLibera: Bool
            if let subs = writeOk[base] {
                if let subs {
                    viaLibera = subs.contains(secondo ?? "")
                    if !viaLibera {
                        // magari lo stesso comando e' permesso in sola lettura (git add vs git status)
                        if let ro = readOnly[base] {
                            viaLibera = ro == nil || ro?.contains(secondo ?? "") == true
                        }
                    }
                } else { viaLibera = true }
            } else if let subs = readOnly[base] {
                if let subs {
                    viaLibera = subs.contains(secondo ?? "")
                } else { viaLibera = true }
            } else {
                viaLibera = false
            }
            if !viaLibera { return .confirm }
        }
        return .allowed
    }
}
