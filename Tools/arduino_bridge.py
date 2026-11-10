#!/usr/bin/env python3
"""Ponte seriale per Jarvis: parla con Arduino su USB.

Uso:
  arduino_bridge.py --list
  arduino_bridge.py --send "led on" [--port /dev/cu.usbmodem14101] [--baud 9600] [--wait 0.8]
"""
import argparse
import glob
import sys

try:
    import serial
except ImportError:
    print("Manca pyserial: installa con  python3 -m pip install pyserial", file=sys.stderr)
    sys.exit(2)


def ports():
    return sorted(glob.glob("/dev/cu.usbmodem*") + glob.glob("/dev/cu.usbserial*")
                  + glob.glob("/dev/cu.wchusbserial*") + glob.glob("/dev/cu.SLAB*"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--send")
    ap.add_argument("--port", default="")
    ap.add_argument("--baud", default="9600")
    ap.add_argument("--wait", default="0.8")
    a = ap.parse_args()

    found = ports()
    if a.list or not a.send:
        print("\n".join(found) if found else "Nessun Arduino collegato via USB adesso.")
        return 0

    port = a.port or (found[0] if found else "")
    if not port:
        print("Non c'e nessuna porta seriale USB aperta: collega l'Arduino e riprova.")
        return 0

    try:
        with serial.Serial(port, int(a.baud), timeout=float(a.wait)) as ser:
            ser.reset_input_buffer()
            ser.write((a.send.strip() + "\n").encode())
            ser.flush()
            chunks = []
            deadline = float(a.wait)
            while deadline > 0:
                line = ser.readline()
                if not line:
                    break
                chunks.append(line.decode("utf-8", "replace").rstrip())
                deadline = max(0.0, deadline - 0.05)
            out = "\n".join(chunks).strip()
            print(out if out else f"Ho inviato «{a.send}» a {port} ma Arduino non risponde.")
    except serial.SerialException as e:
        print(f"Non riesco ad aprire {port}: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
