#!/usr/bin/env python3
"""Generate synthetic input files for the converter conformance tests.

These files are inputs only; all expected outputs are produced by the original
C programs. Run from tests/data.
Part of WFDB-x, Reza Sameni, Oct 2026.
This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 3 of the License, or (at your option) any later
version.
"""

import math
import struct


def wav(name, nsig, bits, n, rate):
    fr = nsig * bits // 8
    data = bytearray()
    for i in range(n):
        for s in range(nsig):
            x = int(1000 * math.sin(2 * math.pi * (s + 1) * i / 50.0))
            if bits == 16:
                data += struct.pack("<h", x * 20)
            else:
                data += struct.pack("<B", 128 + x // 10)
    hdr = b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt " + \
        struct.pack("<IHHIIHH", 16, 1, nsig, rate, rate * fr, fr, bits) + \
        b"data" + struct.pack("<I", len(data))
    open(name, "wb").write(hdr + data)


def edfplus(name):
    # 2 data records of 1 s; signal 0: 100 samples/record; signal 1:
    # "EDF Annotations" with 30 samples (60 bytes) per record.
    nsig = 2
    nrec = 2

    def f(s, n):
        return s.ljust(n)[:n].encode("ascii")

    h = f("0", 8) + f("X X X X", 80) + \
        f("Startdate 02-MAR-2002 X X X", 80) + f("02.03.02", 8) + \
        f("13.24.35", 8) + f(str((nsig + 1) * 256), 8) + f("EDF+C", 44) + \
        f(str(nrec), 8) + f("1", 8) + f(str(nsig), 4)
    h += f("EEG Fpz-Cz", 16) + f("EDF Annotations", 16)
    h += f("AgAgCl electrode", 80) + f("", 80)
    h += f("uV", 8) + f("", 8)
    h += f("-500", 8) + f("-1", 8)
    h += f("500", 8) + f("1", 8)
    h += f("-2048", 8) + f("-32768", 8)
    h += f("2047", 8) + f("32767", 8)
    h += f("HP:0.1Hz", 80) + f("", 80)
    h += f("100", 8) + f("30", 8)
    h += f("", 32) * nsig
    assert len(h) == (nsig + 1) * 256
    tals = [b"+0\x14\x14\x00+0.5\x15" b"1.5\x14Sleep stage W\x14\x00",
            b"+1\x14\x14\x00+1.25\x14Arousal\x14Spindle onset\x14\x00"]
    body = b""
    for r in range(nrec):
        for i in range(100):
            body += struct.pack("<h", int(1500 * math.sin(i / 7.0 + r)))
        t = tals[r].ljust(60, b"\x00")
        body += t
    open(name, "wb").write(h + body)


def ano(name):
    # compressed AHA annotation file: 6 bytes per annotation
    out = bytearray()
    labels = "NNVNNFNRENPQ[]UNN"
    for k, c in enumerate(labels):
        t = 1000 + 812 * k + (k * k) % 17
        out += bytes((ord(c), (t >> 16) & 255, (t >> 8) & 255, t & 255,
                      0, k + 1))
    out += bytes((0, 0xFF, 0, 0, 0, 0))
    open(name, "wb").write(out)


def cmp(name):
    # compressed AHA signal file
    out = bytearray()
    v0 = v1 = 0
    for i in range(800):
        d0 = int(30 * math.sin(i / 9.0))
        d1 = int(90 * math.cos(i / 13.0))
        if i % 97 == 50:
            d0 += 3000
            d1 -= 2000
        if -64 <= d0 < 64 and -128 <= d1 < 128:
            out += bytes((d0 & 0x7F, d1 & 0xFF))
        else:
            out += bytes((0x80 | ((d0 >> 8) & 0x7F), d0 & 0xFF,
                          (d1 >> 8) & 0xFF, d1 & 0xFF))
    open(name, "wb").write(out)


def aha_dvd(nameb, namet):
    b = bytearray()
    t = []
    for i in range(700):
        x0 = int(400 * math.sin(i / 11.0)) & 0xFFFF
        x1 = int(300 * math.cos(i / 7.0)) & 0xFFFF
        lab = "." if i % 113 else "NVFNQU"[(i // 113) % 6]
        b += bytes((x0 & 255, x0 >> 8, x1 & 255, x1 >> 8, ord(lab)))
        s0 = x0 - 65536 if x0 > 32767 else x0
        s1 = x1 - 65536 if x1 > 32767 else x1
        t.append('%d,%d,"%s"\r\n' % (s0, s1, "" if lab == "." else lab))
    open(nameb, "wb").write(b)
    open(namet, "wb").write("".join(t).encode("ascii"))


def oldheader():
    open("old.header", "w").write(
        "old\n1\n100s.dat\n200\n360\n212 2 11 1024\n995 21600 0\n")


wav("t16.wav", 2, 16, 400, 8000)
wav("t8.wav", 1, 8, 300, 4000)
edfplus("edfp.edf")
ano("1201.ANO")
cmp("1201.CMP")
aha_dvd("1001.ecg", "1002.txt")
oldheader()
