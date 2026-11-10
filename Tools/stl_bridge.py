#!/usr/bin/env python3
"""Genera STL binari parametrici per una Bambu A1 mini.

Nessuna libreria esterna: scrive direttamente il formato STL binario.
Ogni faccia e' un quad con vertici in ordine antiorario visto da fuori,
cosi le normali puntano tutte verso l'esterno e lo slicer non impazzisce.

  stl_bridge.py --forma scatola --larghezza 80 --profondita 60 --altezza 30 --spessore 2
  stl_bridge.py --forma cilindro --diametro 40 --altezza 25 --tubo
"""
import argparse
import math
import os
import struct
import sys

TRIANGLE = struct.Struct("<12fH")   # 12 float (normale + 3 vertici) + 2 byte di attributo = 50


class Mesh:
    def __init__(self):
        self.tris = []

    def quad(self, a, b, c, d):
        """Due triangoli dal quad a-b-c-d (antiorario visto da fuori)."""
        self.tri(a, b, c)
        self.tri(a, c, d)

    def tri(self, a, b, c):
        ux, uy, uz = b[0] - a[0], b[1] - a[1], b[2] - a[2]
        vx, vy, vz = c[0] - a[0], c[1] - a[1], c[2] - a[2]
        nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
        n = math.sqrt(nx * nx + ny * ny + nz * nz) or 1.0
        self.tris.append(((nx / n, ny / n, nz / n), a, b, c))

    def fan(self, center, ring, up):
        n = len(ring)
        for i in range(n):
            if up:
                self.tri(center, ring[i], ring[(i + 1) % n])
            else:
                self.tri(center, ring[(i + 1) % n], ring[i])

    def write(self, path):
        with open(path, "wb") as f:
            f.write(b"Jarvis STL - " + os.path.basename(path).encode()[:60].ljust(67, b" "))
            f.write(struct.pack("<I", len(self.tris)))
            for (nx, ny, nz), a, b, c in self.tris:
                f.write(TRIANGLE.pack(nx, ny, nz,
                                      a[0], a[1], a[2], b[0], b[1], b[2], c[0], c[1], c[2], 0))
        return len(self.tris)


def scatola(m, W, D, H, t, cava):
    if not cava:
        m.quad((0, D, 0), (W, D, 0), (W, 0, 0), (0, 0, 0))          # sotto
        m.quad((0, 0, H), (W, 0, H), (W, D, H), (0, D, H))          # sopra
        m.quad((0, 0, 0), (W, 0, 0), (W, 0, H), (0, 0, H))          # davanti
        m.quad((W, D, 0), (0, D, 0), (0, D, H), (W, D, H))          # dietro
        m.quad((0, D, 0), (0, 0, 0), (0, 0, H), (0, D, H))          # sinistra
        m.quad((W, 0, 0), (W, D, 0), (W, D, H), (W, 0, H))          # destra
        return

    m.quad((0, 0, 0), (W, 0, 0), (W, 0, H), (0, 0, H))
    m.quad((W, D, 0), (0, D, 0), (0, D, H), (W, D, H))
    m.quad((0, D, 0), (0, 0, 0), (0, 0, H), (0, D, H))
    m.quad((W, 0, 0), (W, D, 0), (W, D, H), (W, 0, H))
    m.quad((W - t, t, t), (t, t, t), (t, t, H), (W - t, t, H))
    m.quad((t, D - t, t), (W - t, D - t, t), (W - t, D - t, H), (t, D - t, H))
    m.quad((t, t, t), (t, D - t, t), (t, D - t, H), (t, t, H))
    m.quad((W - t, D - t, t), (W - t, t, t), (W - t, t, H), (W - t, D - t, H))
    m.quad((0, D, 0), (W, D, 0), (W, 0, 0), (0, 0, 0))
    m.quad((t, t, t), (W - t, t, t), (W - t, D - t, t), (t, D - t, t))
    m.quad((0, 0, H), (W, 0, H), (W - t, t, H), (t, t, H))
    m.quad((W, D, H), (0, D, H), (t, D - t, H), (W - t, D - t, H))
    m.quad((0, D, H), (0, 0, H), (t, t, H), (t, D - t, H))
    m.quad((W, 0, H), (W, D, H), (W - t, D - t, H), (W - t, t, H))


def cilindro(m, r, H, seg, tubo, t):
    ri = max(0.4, r - t) if tubo else r
    ring_o = [(r * math.cos(2 * math.pi * i / seg), r * math.sin(2 * math.pi * i / seg)) for i in range(seg)]
    ring_i = [(ri * math.cos(2 * math.pi * i / seg), ri * math.sin(2 * math.pi * i / seg)) for i in range(seg)]

    for i in range(seg):
        j = (i + 1) % seg
        a, b = ring_o[i], ring_o[j]
        m.quad((a[0], a[1], 0), (b[0], b[1], 0), (b[0], b[1], H), (a[0], a[1], H))

    if not tubo:
        m.fan((0, 0, 0), [(x, y, 0) for x, y in ring_o], up=False)
        m.fan((0, 0, H), [(x, y, H) for x, y in ring_o], up=True)
        return

    # banda interna del foro, con normali verso il centro
    for i in range(seg):
        j = (i + 1) % seg
        a, b = ring_i[i], ring_i[j]
        m.quad((b[0], b[1], t), (a[0], a[1], t), (a[0], a[1], H), (b[0], b[1], H))
    # fondo del foro (la base piena resta sotto, a quota 0)
    m.fan((0, 0, t), [(x, y, t) for x, y in ring_i], up=True)
    # anello di sopra, tra parete esterna e foro
    for i in range(seg):
        j = (i + 1) % seg
        ao, bo = ring_o[i], ring_o[j]
        ai, bi = ring_i[i], ring_i[j]
        m.quad((ao[0], ao[1], H), (bo[0], bo[1], H), (bi[0], bi[1], H), (ai[0], ai[1], H))
    # sotto pieno
    m.fan((0, 0, 0), [(x, y, 0) for x, y in ring_o], up=False)


def anello(r, seg, z):
    """Un anello di `seg` punti sul cerchio di raggio r, a quota z."""
    return [(r * math.cos(2 * math.pi * i / seg), r * math.sin(2 * math.pi * i / seg), z)
            for i in range(seg)]


def cono(m, r0, r1, H, seg):
    """Cono o tronco di cono. r1 = 0 e' la punta."""
    seg = max(16, min(seg, 240))
    base = anello(r0, seg, 0)
    if r1 <= 1e-6:
        apice = (0.0, 0.0, H)
        for i in range(seg):
            m.tri(base[i], base[(i + 1) % seg], apice)
    else:
        cima = anello(r1, seg, H)
        for i in range(seg):
            j = (i + 1) % seg
            m.quad(base[i], base[j], cima[j], cima[i])
        m.fan((0, 0, H), cima, up=True)
    m.fan((0, 0, 0), base, up=False)


def sfera(m, r, seg, anelli):
    """Sfera UV: anelli di latitudine, ventagli ai due poli."""
    seg = max(16, min(seg, 240))
    anelli = max(6, min(anelli, 120))
    sud, nord = (0.0, 0.0, -r), (0.0, 0.0, r)
    ringhe = []
    for k in range(anelli + 1):
        phi = -math.pi / 2 + math.pi * k / anelli
        ringhe.append(anello(r * math.cos(phi), seg, r * math.sin(phi)))
    for i in range(seg):
        m.tri(sud, ringhe[1][(i + 1) % seg], ringhe[1][i])
    for k in range(1, anelli - 1):
        A, B = ringhe[k], ringhe[k + 1]
        for i in range(seg):
            j = (i + 1) % seg
            m.quad(A[i], A[j], B[j], B[i])
    for i in range(seg):
        m.tri(nord, ringhe[anelli - 1][i], ringhe[anelli - 1][(i + 1) % seg])


def prisma(m, r, H, lati):
    """Prisma a base poligonale regolare (esagono, ottagono...)."""
    lati = max(3, min(lati, 24))
    base, cima = anello(r, lati, 0), anello(r, lati, H)
    for i in range(lati):
        j = (i + 1) % lati
        m.quad(base[i], base[j], cima[j], cima[i])
    m.fan((0, 0, 0), base, up=False)
    m.fan((0, 0, H), cima, up=True)


def controlla(m):
    """Ogni spigolo deve comparire esattamente due volte: se no la mesh ha buchi.

    Uno STL aperto e' il motivo numero uno per cui lo slicer fa cose strane
    (pareti a zero, riempimenti che entrano nel vuoto). Meglio dirlo qui che
    scoprirlo dopo tre ore di stampa.
    """
    spigoli = {}
    for _, a, b, c in m.tris:
        for p, q in ((a, b), (b, c), (c, a)):
            k = tuple(sorted((tuple(round(v, 5) for v in p), tuple(round(v, 5) for v in q))))
            spigoli[k] = spigoli.get(k, 0) + 1
    return sum(1 for n in spigoli.values() if n != 2)


def volume(m):
    """Volume firmato: se esce negativo le facce guardano dentro."""
    tot = 0.0
    for _, a, b, c in m.tris:
        tot += (a[0] * (b[1] * c[2] - b[2] * c[1])
                - a[1] * (b[0] * c[2] - b[2] * c[0])
                + a[2] * (b[0] * c[1] - b[1] * c[0])) / 6.0
    return tot


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--forma", required=True,
                    choices=["scatola", "cilindro", "cono", "sfera", "prisma"])
    ap.add_argument("--larghezza", type=float, default=80)
    ap.add_argument("--profondita", type=float, default=60)
    ap.add_argument("--altezza", type=float, default=30)
    ap.add_argument("--diametro", type=float, default=40)
    ap.add_argument("--diametro2", type=float, default=0, help="diametro in cima al cono")
    ap.add_argument("--lati", type=int, default=6, help="lati del prisma")
    ap.add_argument("--spessore", type=float, default=2.0)
    ap.add_argument("--cava", action="store_true")
    ap.add_argument("--tubo", action="store_true")
    ap.add_argument("--out", default=os.path.expanduser("~/.jarvis/stl"))
    a = ap.parse_args()

    if min(a.larghezza, a.profondita, a.altezza, a.diametro) < 2:
        print("Misure troppo piccole: il minimo e' 2 mm.", file=sys.stderr)
        return 2
    if a.spessore < 0.8:
        print("Lo spessore minimo sensato e' 0.8 mm.", file=sys.stderr)
        return 2

    os.makedirs(a.out, exist_ok=True)
    m = Mesh()
    if a.forma == "scatola":
        if a.spessore * 2 >= min(a.larghezza, a.profondita):
            print("Pareti troppo spesse: con %g mm di parete la scatola non ha piu' interno "                  "(servono almeno %g mm per lato)." % (a.spessore, a.spessore * 2 + 1), file=sys.stderr)
            return 2
        if a.cava and a.altezza <= a.spessore * 1.5:
            print("La scatola e' alta %g mm con pareti da %g: resta un vassoio, non un contenitore."                  % (a.altezza, a.spessore), file=sys.stderr)
            return 2
        scatola(m, a.larghezza, a.profondita, a.altezza, a.spessore, a.cava)
        nome = "scatola_%gx%gx%g%s.stl" % (a.larghezza, a.profondita, a.altezza, "_cava" if a.cava else "")
    elif a.forma == "cono":
        r0, r1 = a.diametro / 2, a.diametro2 / 2
        if r1 > r0 + 1e-9:
            print("Il diametro in cima (%g) e' piu' grande di quello in base (%g): "                  "un cono non si allarga verso l'alto." % (a.diametro2, a.diametro), file=sys.stderr)
            return 2
        cono(m, r0, r1, a.altezza, max(24, int(2 * math.pi * max(r0, 0.1) / 1.5)))
        nome = "cono_d%gx%gx%g.stl" % (a.diametro, a.diametro2, a.altezza)
    elif a.forma == "sfera":
        r = a.diametro / 2
        sfera(m, r, max(24, int(2 * math.pi * r / 1.5)), int(max(24, 2 * math.pi * r / 1.5) // 2) or 12)
        nome = "sfera_d%g.stl" % a.diametro
    elif a.forma == "prisma":
        r = a.diametro / 2
        if a.lati < 3 or a.lati > 24:
            print("Un prisma ha da 3 a 24 lati (hai chiesto %d)." % a.lati, file=sys.stderr)
            return 2
        prisma(m, r, a.altezza, a.lati)
        nome = "prisma%d_d%gx%g.stl" % (a.lati, a.diametro, a.altezza)
    else:
        r = a.diametro / 2
        if a.tubo and a.spessore >= r:
            print("Il tubo ha pareti piu spesse del raggio (raggio %g, parete %g)." % (r, a.spessore), file=sys.stderr)
            return 2
        cilindro(m, r, a.altezza, max(24, int(2 * math.pi * r / 1.5)), a.tubo, a.spessore)
        nome = "cilindro_d%gx%g%s.stl" % (a.diametro, a.altezza, "_tubo" if a.tubo else "")

    # le facce devono guardare fuori (se il volume e' negativo si girano tutte)
    if volume(m) < 0:
        m.tris = [(tuple(-c for c in nrm), a, c, b) for nrm, a, b, c in m.tris]
    aperti = controlla(m)
    if aperti:
        print("Mesh non chiusa: %d spigoli aperti. Non la scrivo: lo slicer farebbe danni." % aperti,
              file=sys.stderr)
        return 3

    path = os.path.join(a.out, nome)
    n = m.write(path)
    print("%s\n%d triangoli" % (path, n))
    return 0


if __name__ == "__main__":
    sys.exit(main())
