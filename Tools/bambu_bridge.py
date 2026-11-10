#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Ponte MQTT con la Bambu A1 mini, senza librerie esterne.

La stampante parla MQTT su TLS (porta 8883) con username "bblp" e il codice di
accesso come password. Qui c'e' un client MQTT minimo (CONNECT / SUBSCRIBE /
PUBLISH) scritto con il solo ssl+socket di Python: niente pip, niente brew,
niente da scaricare.

Il certificato della Bambu e' self-signed, quindi la verifica standard di TLS non
puo' funzionare. Per non spegnere la sicurezza si usa il "pinning": alla prima
connessione riuscita l'impronta SHA-256 del certificato della stampante viene
salvata in ~/.jarvis/bambu-cert.txt e da allora in poi si accetta SOLO quella.
Se qualcuno in rete si spaccia per la stampante, l'impronta non torna e la
connessione viene rifiutata. Per rifare il primo aggancio (stampante cambiata o
resetata) si cancella quel file.

Uso:
    bambu_bridge.py stato              -> temperatura, avanzamento, ETA, stato
    bambu_bridge.py cerca              -> come stato, ma prima batte la rete 192.168.1.x
                                          (l'ip della stampante cambia: questo lo rimette
                                          nel file da solo)
    bambu_bridge.py watch --minuti 30  -> esce quando la stampa finisce o da' errore
    bambu_bridge.py test               -> dice solo se la connessione e' ok

Configurazione in ~/.jarvis/bambu.conf (ip, codice, seriale), letta da questo
script e mai passata dalla riga di comando: la riga di comando su macOS la vede
qualsiasi processo.
"""

import concurrent.futures
import hashlib
import json
import os
import socket
import ssl
import struct
import sys
import time

PORT = 8883
IMPRONTA_FILE = os.path.expanduser("~/.jarvis/bambu-cert.txt")

# I token che la stampante manda davvero non hanno una regola fissa di maiuscole
# ("SUCCESS", "success", "FINISH" a seconda del firmware), e la stampante ora e'
# spenta: nessuno puo' dirlo per certo. Quindi il lookup e' senza maiuscole e le
# due famiglie di parole stanno tutte qui.
ETICHETTE = {
    "available": "pronta", "online": "pronta", "offline": "spenta",
    "printing": "sta stampando", "running": "sta stampando", "pub": "accettata",
    "ack": "accettata", "unack": "accettata", "prepare": "in preparazione",
    "slicing": "affettata", "sending": "in invio",
    "pause": "in pausa", "failed": "fallita", "success": "finita bene",
    "finish": "finita bene",
}


# ------------------------------------------------------------------ config

def leggi_config():
    # BAMBU_CONF serve solo per le prove: nella vita normale e' ~/.jarvis/bambu.conf
    path = os.path.expanduser(os.environ.get("BAMBU_CONF", "~/.jarvis/bambu.conf"))
    cfg = {"ip": "", "codice": "", "seriale": ""}
    try:
        with open(path, "r", encoding="utf-8") as f:
            for riga in f:
                riga = riga.strip()
                if not riga or riga.startswith("#") or "=" not in riga:
                    continue
                chiave, valore = riga.split("=", 1)
                cfg[chiave.strip().lower()] = valore.strip()
    except OSError:
        pass
    return cfg


def manca(cfg):
    mancanti = [k for k in ("ip", "codice") if not cfg.get(k)]
    if not cfg.get("seriale"):
        mancanti.append("seriale")
    return mancanti


AUTOISTRUZIONE = ("Il codice di accesso sono 8 caratteri, non la seriale: si trova su un'etichetta "
                  "grigia dietro la stampante (vicino al QR e alla password del WiFi), oppure in "
                  "Bambu Handy -> tocca la stampante -> ingranaggio -> 'Access code'. Bambu Studio "
                  "sul Mac lo salva in ~/Library/Application Support/BambuStudio/BambuStudio.conf "
                  "sotto 'access_code', se la stampante e' gia' stata aggiunta. Niente API key: "
                  "quella e' un'altra cosa.")


def controlla_codice(cfg):
    """La riga `codice = ...` deve essere il codice di accesso: 8 caratteri."""
    c = cfg.get("codice", "")
    if not c:
        return ["codice"]
    se = cfg.get("seriale", "")
    if se and c == se:
        return ["codice: hai ricopiato la SERIALE anche nella riga 'codice ='"]
    if len(c) > 20:
        return ["codice: sembra una chiave di Bambu Studio, non il codice di accesso"]
    if len(c) != 8 or not all(ch.isalnum() for ch in c):
        return ["codice: sono " + str(len(c)) + " caratteri, il codice di accesso ne ha 8"]
    return []


# --------------------------------------------------- ritrovare la stampante in rete
# Il router TIM di casa da' un indirizzo DHCP che cambia: se la A1 mini si sveglia
# con un IP nuovo non deve toccare all'utente accorgersene.

def ip_del_mac():
    """L'indirizzo del Mac sulla rete di casa (senza mandare nessun pacchetto)."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))
        return s.getsockname()[0]
    except OSError:
        return ""
    finally:
        s.close()


def cerca_8883(prefix=None, tempo=0.3):
    """Batte la /24 e ritorna chi ha la porta MQTT della Bambu aperta."""
    if not prefix:
        mio = ip_del_mac()
        prefix = ".".join(mio.split(".")[:3]) if mio.count(".") == 3 else "192.168.1"

    def batti(ultimo):
        ip = prefix + "." + str(ultimo)
        try:
            s = socket.create_connection((ip, PORT), timeout=tempo)
            s.close()
            return ip
        except OSError:
            return None

    con = concurrent.futures.ThreadPoolExecutor(max_workers=80)
    try:
        return [x for x in con.map(batti, range(1, 255)) if x]
    finally:
        con.shutdown(wait=False)


def salva_ip(nuovo):
    """Scrive il nuovo ip nel file di configurazione, senza toccare il resto."""
    path = os.path.expanduser(os.environ.get("BAMBU_CONF", "~/.jarvis/bambu.conf"))
    try:
        righe = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        return False
    fuori, cambiato = [], False
    for r in righe:
        if r.strip().lower().startswith("ip"):
            r = "ip = " + nuovo
            cambiato = True
        fuori.append(r)
    if not cambiato:
        fuori.insert(0, "ip = " + nuovo)
    try:
        fd = os.open(path, os.O_WRONLY | os.O_TRUNC, 0o600)
        os.write(fd, ("\n".join(fuori) + "\n").encode())
        os.close(fd)
    except OSError:
        return False
    return True


# ------------------------------------------------------- MQTT minimo (3.1.1)

def _pacchetto(tipo, flags, corpo):
    testa = bytes([(tipo << 4) | flags])
    lungh = len(corpo)
    out = bytearray()
    while True:
        cifra = lungh % 128
        lungh //= 128
        if lungh:
            cifra |= 0x80
        out.append(cifra)
        if not lungh:
            break
    return testa + bytes(out) + corpo


def _stringa(s):
    dati = s.encode("utf-8")
    return struct.pack("!H", len(dati)) + dati


def impronta_salvata():
    try:
        with open(IMPRONTA_FILE, "r", encoding="utf-8") as f:
            return f.read().strip().lower()
    except OSError:
        return ""


def impronta_del_certificato(presa):
    der = presa.getpeercert(binary_form=True)
    return hashlib.sha256(der).hexdigest() if der else ""


def connetti(ip, codice):
    """TLS con pinning del certificato: si accetta solo l'impronta conosciuta."""
    attesa = impronta_salvata()
    contesto = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    contesto.check_hostname = False        # il CN del certificato non e' l'IP
    contesto.verify_mode = ssl.CERT_NONE   # la verifica la facciamo noi sull'impronta
    presa = socket.create_connection((ip, PORT), timeout=8)
    tls = contesto.wrap_socket(presa, server_hostname=ip)
    visto = impronta_del_certificato(tls)
    if not visto:
        raise RuntimeError("la stampante non ha mandato nessun certificato")
    if attesa and visto != attesa:
        tls.close()
        raise RuntimeError("il certificato della stampante non coincide con quello salvato "
                           "(" + ip + " potrebbe non essere la stampante). "
                           "Se hai cambiato o resettato la stampante, cancella "
                           "~/.jarvis/bambu-cert.txt e riprova.")
    # payload MQTT 3.1.1: client-id (sempre obbligatorio), username, password.
    # flags 0xC2 = username + password + clean session.
    corpo = (_stringa("MQTT") + bytes([0x04, 0xC2, 0, 30])
             + _stringa("JarvisMac") + _stringa("bblp") + _stringa(codice))
    tls.sendall(_pacchetto(1, 0, corpo))
    risposta = tls.recv(4096)
    if len(risposta) < 4:
        raise RuntimeError("risposta troppo corta dal server")
    esito = risposta[3]
    if esito != 0:
        motivi = {1: "versione MQTT non accettata", 2: "id del client rifiutato",
                  3: "il broker della stampante non accetta la sessione (codice sbagliato?)",
                  4: "credenziali sbagliate: codice di accesso errato",
                  5: "non autorizzato: codice di accesso errato",
                  6: "password cattiva"}
        raise RuntimeError("CONNECT rifiutata: " + motivi.get(esito, "codice " + str(esito))
                           + ". " + AUTOISTRUZIONE)
    if not attesa:
        try:
            with open(IMPRONTA_FILE, "w", encoding="utf-8") as f:
                f.write(visto + "\n")
            os.chmod(IMPRONTA_FILE, 0o600)
        except OSError:
            pass
    return tls


def iscriviti(tls, topic, qid=1):
    tls.sendall(_pacchetto(8, 0, struct.pack("!H", qid) + _stringa(topic) + bytes([0])))
    tls.recv(4096)  # SUBACK


def pubblica(tls, topic, testo, qid=2):
    corpo = _stringa(topic) + struct.pack("!H", qid) + testo.encode("utf-8")
    tls.sendall(_pacchetto(3, 2, corpo))


def leggi_publish(tls, scadenza):
    """Raccoglie i PUBLISH finche' scade il tempo; ritorna i messaggi gia' parsed."""
    buffer = b""
    fuori = []
    tls.settimeout(2.0)
    while time.time() < scadenza:
        try:
            buffer += tls.recv(8192)
        except socket.timeout:
            continue
        except OSError:
            break
        while buffer:
            primo_byte = buffer[0]
            tipo = primo_byte >> 4
            i = 1
            mult = 1
            lungh = 0
            while i < len(buffer):
                cifra = buffer[i]
                lungh += (cifra & 0x7F) * mult
                mult *= 128
                i += 1
                if not (cifra & 0x80):
                    break
            else:
                break
            fine = i + lungh
            if fine > len(buffer):
                break
            corpo = buffer[i:fine]
            buffer = buffer[fine:]
            if tipo == 3 and len(corpo) > 2:
                tl = struct.unpack("!H", corpo[:2])[0]
                resto = corpo[2 + tl:]
                # Il packet-id di QoS 1 c'e' SOLO se il DUBB flag del fixed header lo
                # dice: toglierlo a caso su un messaggio QoS 0 mangiava i primi due
                # byte del JSON, che poi non si decodificava e la stampante sembrava
                # muta (2026-10-20, con la A1 mini accesa e il codice giusto).
                if (primo_byte >> 1) & 3:
                    resto = resto[2:]
                try:
                    fuori.append(json.loads(resto.decode("utf-8", "replace")))
                except ValueError:
                    pass
            elif tipo == 13:
                tls.sendall(bytes([0xD0, 0x00]))   # PINGRESP
    return fuori


# ------------------------------------------------------------ stato stampante

def stato_da_msg(msg, ultimo):
    """Traduce un messaggio di report in una riga leggibile.

    Qui dentro prima c'era un doppio sbussolamento: chi chiamava passava gia' il
    dizionario `print`, e la funzione lo cercava un'altra volta - trovando vuoto e
    scartando temperature vere. Ora prende IL MESSAGGIO completo e scende lui.
    """
    t = msg.get("print") or msg.get("tunnel") or msg
    if not isinstance(t, dict):
        return ultimo
    annidato = t.get("msg")
    if isinstance(annidato, dict):        # alcuni firmware mettono tutto sotto print.msg
        t = dict(t, **annidato)
    if "gcode_state" in t:
        grezzo = str(t.get("gcode_state", ""))
        ultimo["stato"] = ETICHETTE.get(grezzo.lower(), grezzo)
    for chiave, nome in (("mc_percent", "percentuale"), ("mc_remaining_time", "minuti_restanti"),
                         ("nozzle_temper", "ugello"), ("bed_temper", "letto"),
                         ("nozzle_target_temper", "ugello_obiettivo")):
        if chiave in t:
            ultimo[nome] = t.get(chiave)
    if "queue_homepage" in t:
        ultimo["coda"] = t.get("queue_homepage")
    for chiave, nome in (("wifi_signal", "wifi"), ("stage", "fase"),
                         ("subtask_name", "pezzo"), ("total_layer_count", "layer_totali"),
                         ("cur_layer", "layer")):
        if chiave in t:
            ultimo[nome] = t.get(chiave)
    if "heat_gtemperature" in t:
        ultimo["letto_obiettivo"] = t.get("heat_gtemperature")
    return ultimo


def riassume(u):
    parti = []
    if "stato" in u:
        parti.append("stato: " + str(u["stato"]))
    if "percentuale" in u:
        try:
            parti.append("avanzamento: " + str(int(float(u["percentuale"]))) + "%")
        except (TypeError, ValueError):
            pass
    if "minuti_restanti" in u:
        try:
            m = int(float(u["minuti_restanti"]))
            parti.append("mancano ~" + str(m) + " min" if m > 0 else "in conclusione")
        except (TypeError, ValueError):
            pass
    def grado(v):
        try:
            return format(float(v), ".1f")
        except (TypeError, ValueError):
            return str(v)
    if "ugello" in u:
        bersaglio = u.get("ugello_obiettivo")
        parti.append("ugello " + grado(u["ugello"]) + "°C" + (" (obiettivo " + grado(bersaglio) + ")" if bersaglio else ""))
    if "letto" in u:
        parti.append("letto " + grado(u["letto"]) + "°C")
    # dire "finita bene" a una stampante fredda e' mezzo bug: e' lo stato DELL'ULTIMA
    # stampa, non di una in corso. Il caldo lo distingue.
    try:
        freddo = float(u.get("ugello", 0)) < 45 and float(u.get("letto", 0)) < 40
    except (TypeError, ValueError):
        freddo = False
    if freddo:
        parti.append("in riposo: non c'e' niente di caldo, quindi non sta stampando adesso")
    if "layer" in u and u.get("layer_totali"):
        parti.append("layer " + str(u["layer"]) + "/" + str(u["layer_totali"]))
    if "pezzo" in u:
        parti.append("pezzo: " + str(u["pezzo"]))
    if "wifi" in u:
        parti.append("wifi " + str(u["wifi"]))
    return " | ".join(parti) if parti else ""


def apri_connessione(cfg, forza_scansione=False):
    """Prova l'ip salvato; se non risponde batte la rete e riprova su chi ha 8883 aperta.

    Ritorna (tls, ip, nota). I problemi di credenziali NON fanno partire la scansione:
    sarebbe solo rumore, e ricontattare la stampante 40 volte con il codice sbagliato
    e' un comportamento che non ci serve. Con `forza_scansione` (azione `cerca`) la rete
    viene battuta anche se l'ip salvato sembra funzionare.
    """
    if not forza_scansione:
        try:
            return connetti(cfg["ip"], cfg["codice"]), cfg["ip"], ""
        except RuntimeError as e:
            # CONNECT arrivata => la macchina c'e', il problema e' il codice
            raise RuntimeError(str(e))
        except OSError as e:
            prima = str(e)
    else:
        prima = ""
    candidati = cerca_8883()
    if forza_scansione:
        candidati.sort(key=lambda x: x != cfg["ip"])
    else:
        candidati = [x for x in candidati if x != cfg["ip"]]
    if not candidati:
        raise RuntimeError((prima + " — " if prima else "")
                           + "nessuna macchina in rete ha la porta della Bambu aperta (8883): "
                             "la A1 mini e' spenta o agganciata a un'altra rete")
    ultima = prima
    for ip in candidati:
        try:
            tls = connetti(ip, cfg["codice"])
            if ip == cfg["ip"]:
                nota = "l'ip in ~/.jarvis/bambu.conf e' ancora buono"
            else:
                nota = "l'ip era cambiato, ora e' " + ip + " (l'ho rimesso nel file)"
                salva_ip(ip)
            return tls, ip, nota
        except RuntimeError as e:
            ultima = str(e)   # credenziali: fermo qui, non ha senso provarne altri
            break
        except OSError as e:
            ultima = str(e)
    raise RuntimeError(ultima)


def main():
    modalita = sys.argv[1] if len(sys.argv) > 1 else "stato"
    cfg = leggi_config()

    topic = "device/" + cfg["seriale"] + "/report"
    guai = manca(cfg) + controlla_codice(cfg)
    if guai:
        for g in guai:
            print("Problema in ~/.jarvis/bambu.conf -> " + g)
        print(AUTOISTRUZIONE)
        return 2
    try:
        tls, _, nota = apri_connessione(cfg, forza_scansione=(modalita == "cerca"))
    except Exception as e:
        print("Non riesco a parlare con la stampante: " + str(e))
        return 1
    if nota:
        print("(nota: " + nota + ")")

    iscriviti(tls, topic)
    pubblica(tls, topic, json.dumps({"print": {"command": "get_version"}, "version": 1}))
    pubblica(tls, topic, json.dumps({"print": {"command": "statuslist"}, "version": 1}))

    minuti = 1
    if "--minuti" in sys.argv:
        try:
            minuti = max(1, int(sys.argv[sys.argv.index("--minuti") + 1]))
        except (IndexError, ValueError):
            pass
    # la stampante risponde in pochi secondi (push_status): 25 s di ascolto erano solo
    # un lusso che sfondava il tempo limite della suite di prova
    durata = 12 if modalita in ("stato", "cerca") else (12 if modalita == "test" else minuti * 60)
    scadenza = time.time() + durata

    ultimo = {}
    visti = 0
    finito = False
    visto_stampare = False
    non_e_il_primo_giro = False
    while time.time() < scadenza and not finito:
        for msg in leggi_publish(tls, min(time.time() + 6, scadenza)):
            visti += 1
            stato_da_msg(msg, ultimo)
        non_e_il_primo_giro = True
        if modalita == "test":
            break
        if modalita == "watch":
            s = str(ultimo.get("stato", "")).lower()
            try:
                caldo = float(ultimo.get("ugello", 0)) >= 45 or float(ultimo.get("letto", 0)) >= 40
            except (TypeError, ValueError):
                caldo = False
            if "stamp" in s or str(ultimo.get("percentuale", "")) not in ("", "0"):
                visto_stampare = True
            fine_vera = any(k in s for k in ("finish", "failed", "pause", "finita", "fallita", "in pausa"))
            # il primo giro vede lo stato DELL'ULTIMA stampa: senza averla vista calda
            # non e' un finale, e' la stampante che aspetta
            if (fine_vera and (visto_stampare or caldo)) or (fine_vera and non_e_il_primo_giro):
                finito = True
                break
            if non_e_il_primo_giro and not visto_stampare and not caldo:
                print("NON C'E' NESSUNA STAMPA IN CORSO (ugello freddo): "
                      "te lo dico adesso invece di aspettare due ore")
                finito = True
                break

    try:
        tls.close()
    except OSError:
        pass

    if modalita == "test":
        print("Connessione MQTT alla Bambu: ok (codice giusto)")
        if visti:
            print("La stampante risponde sul topic (seriale giusta): "
                  + str(visti) + " messaggi")
        else:
            print("Però la stampante non ha mandato niente su device/<seriale>/report: "
                  "controlla che la riga 'seriale =' sia quella stampata sull'etichetta.")
        return 0

    riepilogo = riassume(ultimo)
    if not riepilogo:
        print("La stampante non ha risposto niente di leggibile: controlla che la seriale "
              "in ~/.jarvis/bambu.conf sia quella giusta.")
        return 1
    print(riepilogo)
    if modalita == "watch":
        print("FINE:" + str(ultimo.get("stato", "")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
