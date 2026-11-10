#!/usr/bin/env python3
"""Toglie le righe dei test dalla cronologia VERA di Jarvis.

Le suite da terminale (`--prova-frasi`, `--ask`, `--test`) scrivevano in
~/.jarvis/logs/storico.jsonl con source "debug"/"selftest"/"test-batteria": non sono
conversazioni sue, e finivano nella lista chat. `Store.daElencare` le scarta gia' per la
vista, ma restano nel file.

Uso:   python3 pulisci-log-test.py            (guarda cosa farebbe)
       python3 pulisci-log-test.py --scrivi   (lo fa, con backup)
"""
import json
import os
import shutil
import sys
import time

PERCORSO = os.path.expanduser("~/.jarvis/logs/storico.jsonl")
TEST = {"debug", "selftest", "test-batteria", "test"}

def main():
    scrivi = "--scrivi" in sys.argv
    if not os.path.exists(PERCORSO):
        print("non c'e'", PERCORSO)
        return 1
    tenute, tolte, rotte = [], 0, 0
    for riga in open(PERCORSO, encoding="utf-8").read().split("\n"):
        r = riga.strip()
        if not r:
            continue
        try:
            e = json.loads(r)
        except Exception:
            rotte += 1
            tenute.append(riga)          # una riga che non si legge non la si butta via
            continue
        if e.get("source", "") in TEST:
            tolte += 1
        else:
            tenute.append(riga)
    print(f"righe nel file: {len(tenute) + tolte} · da tenere: {len(tenute)} · "
          f"test da togliere: {tolte} · righe non leggibili (lasciate): {rotte}")
    if not scrivi:
        print("solo guarda: per scrivere davvero aggiungi --scrivi")
        return 0
    backup = PERCORSO.replace("storico.jsonl", f"storico-backup-test-{time.strftime('%Y%m%d-%H%M%S')}.jsonl")
    shutil.copy2(PERCORSO, backup)
    with open(PERCORSO, "w", encoding="utf-8") as f:
        f.write("\n".join(tenute) + "\n")
    print("backup scritto in", backup)
    return 0

if __name__ == "__main__":
    sys.exit(main())
