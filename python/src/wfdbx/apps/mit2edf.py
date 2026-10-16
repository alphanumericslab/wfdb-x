"""mit2edf: convert MIT format to EDF.

Copyright (C) 2002-2014 George B. Moody (original C program, convert/mit2edf.c;
revised 2020 by Benjamin Moody).
Python implementation part of wfdb-x, Reza Sameni, Oct 2026.
Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency, gain,
ADC resolution or units. Values that the record or the user does not give are
never assumed (the original package assumed 250 Hz, 200 adu/mV, 12 bits and
millivolts), because a silently assumed value corrupts every result derived
from it. See docs/DIVERGENCES.md.
This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.
"""

import sys

import wfdbx as w
from wfdbx._cstd import sscanf, int32, int8, cdiv, cmod
from ._common import (Output, Exit, eprintf, freq_not_specified, legacy,
                      run)

EDFMAXBLOCK = 61440     # maximum data block length, in bytes
MONTHS = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP",
          "OCT", "NOV", "DEC"]
HELP = [
    "usage: %s -r RECORD [OPTIONS ...]\n",
    "where RECORD is the name of the input record, and OPTIONS may include:",
    " -h          print this usage summary",
    " -o EDFILE   write the specified European Data Format file (default:",
    "              RECORD.edf)",
    " -p          write the output as an EDF+ file",
    " -v          select verbose mode",
    "This program reads MIT-format signal and header files and writes an EDF",
    "file containing the same data.",
]


def help(pname):
    eprintf(HELP[0], pname)
    for s in HELP[1:]:
        eprintf("%s\n", s)


def _legacy_adcres(f):
    """wfdb-x: legacy mode (original behavior): the ADC resolution guessed
    from the storage format f."""
    if f in (524, 24):
        return 24
    if f == 32:
        return 32
    if f in (508, 80):
        return 8
    if f == 212:
        return 12
    if f in (310, 311):
        return 10
    if f in (516, 16, 61, 160):
        return 16
    if f >= 100 and f % 100 > 0 and f % 100 <= 32:     # future formats
        return f % 100
    return 16


def _main(argv, out):
    pname = argv[0]
    argc = len(argv)
    ofname = record = None
    edfplusflag = vflag = 0
    i = 1
    while i < argc:
        a = argv[i]
        if a.startswith("-"):
            c = a[1:2]
            if c == "h":
                help(pname)
                raise Exit(0)
            elif c == "o":
                i += 1
                if i < argc:
                    ofname = argv[i]
                else:
                    eprintf("%s: output file name must follow -o\n", pname)
                    raise Exit(1)
            elif c == "p":
                edfplusflag = 1
            elif c == "r":
                i += 1
                if i < argc:
                    record = argv[i]
                else:
                    eprintf("%s: record name must follow -r\n", pname)
                    raise Exit(1)
            elif c == "v":
                vflag = 1
        i += 1
    if record is None:
        help(pname)
        raise Exit(1)
    if ofname is None:
        k = record.rfind("/")
        ofname = record[k + 1:][:w.WFDB_MAXRNL] + ".edf"
    elif edfplusflag:
        if ofname[-4:] not in (".edf", ".EDF"):
            eprintf("%s: '%s' is not a valid EDF+ file name\n", pname, ofname)
            eprintf(" EDF+ file names must end with '.edf' or '.EDF')\n")
            raise Exit(1)
    nsig = w.isigopen(record, None, 0)
    if nsig <= 0:
        raise Exit(2)
    si = []
    nsig = w.isigopen(record, si, nsig)
    if nsig <= 0:
        raise Exit(3)
    # wfdb-x: an EDF file needs the sampling frequency, and the gain and ADC
    # resolution of each signal (C assumed 250 Hz and 200 adu/mV if the
    # header did not specify them, and guessed the resolution from the
    # format), as legacy mode does.
    if not legacy():
        if w.sampfreq(None) <= 0.0:
            freq_not_specified(pname, record)
            raise Exit(3)
        for k in range(nsig):
            if si[k].gain == 0.0:
                eprintf("%s: signal %d of record %s is uncalibrated\n",
                        pname, k, record)
                raise Exit(3)
            if si[k].adcres < 1:    # the EDF digital range needs it
                eprintf("%s: ADC resolution of signal %d of record %s is "
                        "not specified\n", pname, k, record)
                raise Exit(3)
    try:
        ofile = open(ofname, "wb")
    except OSError:
        eprintf("%s: can't create %s\n", pname, ofname)
        raise Exit(4)
    p = w.timstr(0)
    start_date_recorded = 1
    if not p.startswith("["):
        w.setbasetime(None)
        p = w.timstr(0)
        start_date_recorded = 0
    n, v = sscanf(p, "[%d:%d:%d %d/%d/%d")
    v = [int32(x) for x in v] + [0] * (6 - len(v))
    hour, minute, second, day, month, year = v
    if n != 6:
        start_date_recorded = 0
        day = month = 1
        year = 1985             # beginning of EDF epoch
    # Block duration (EDF calls blocks "data records"): ten seconds, or
    # less if the blocks would be too long.  EDF has 2 bytes per sample.
    samples_per_frame = sum(s.spf for s in si)
    frames_per_second = w.strtim("1:0") / 60.0
    frames_per_block = int(10 * frames_per_second + 0.5)
    bytes_per_block = 2 * samples_per_frame * frames_per_block
    while bytes_per_block > EDFMAXBLOCK:
        frames_per_block = cdiv(frames_per_block, 10)
        bytes_per_block = samples_per_frame * 2 * frames_per_block
    seconds_per_block = frames_per_block / frames_per_second
    if frames_per_block < 1 and bytes_per_block < EDFMAXBLOCK // 60:
        frames_per_block = w.strtim("1:0")      # frames per minute
        bytes_per_block = 2 * samples_per_frame * frames_per_block
        seconds_per_block = 60.0
    if bytes_per_block > EDFMAXBLOCK:
        eprintf("%s: can't convert record %s to EDF\n", pname, record)
        eprintf(" EDF blocks cannot be larger than %d bytes, but each input "
                "frame requires\n", EDFMAXBLOCK)
        eprintf(" %d bytes.  Use 'snip' to select a subset of the input "
                "signals, or use\n 'xform' to reduce the sampling frequency."
                "\n", samples_per_frame * 2)
        raise Exit(5)
    nblocks = cdiv(w.strtim("e"), frames_per_block) + 1
    hlen = (nsig + 1) * 256     # 256 header bytes, plus 256 per signal
    header = bytearray(b" " * hlen)
    if vflag:
        out.write("Converting record %s to %s (%s mode)\n" % (
            record, ofname, "EDF+" if edfplusflag == 1 else "EDF"))
    dmax = []
    dmin = []
    pmax = []
    pmin = []
    for k in range(nsig):
        s = si[k]
        # (wfdb-x: the ADC resolution was checked above; the C program
        # guessed it from the storage format if the header did not give it,
        # as legacy mode does.)
        if legacy() and s.adcres < 1:
            s.adcres = _legacy_adcres(s.fmt)
        dmax.append(int32(s.adczero + (1 << (s.adcres - 1)) - 1))
        dmin.append(int32(s.adczero - (1 << (s.adcres - 1))))
        pmax.append(w.aduphys(k, dmax[k]))
        pmin.append(w.aduphys(k, dmin[k]))
    pos = [0]

    def put(text, advance=None):
        b = text.encode("latin-1")
        p0 = pos[0]
        end = min(p0 + len(b), hlen)
        header[p0:end] = b[:end - p0]
        if advance is not None:
            pos[0] += advance

    # The header fields, with the widths given by the EDF specification.
    put("0", 8)                 # version of this data format
    if len(record) > 80:
        record = record[:79]
    put(record, 80)             # local patient identification
    if start_date_recorded:
        buf = "Startdate %02d-%s-%d" % (day, MONTHS[month - 1], year)
    else:
        buf = "Startdate not recorded"
        if edfplusflag:
            eprintf("WARNING (%s): EDF+ requires start date (not "
                    "specified)\n", pname)
    put(buf, 80)                # local recording identification
    # Start date and time; strncpy(p, buf, 8) pads with NULs if buf is
    # shorter than 8 bytes.
    put(("%02d.%02d.%02d" % (day, month, cmod(year, 100)))[:8]
        .ljust(8, "\0"), 8)
    put(("%02d.%02d.%02d" % (hour, minute, second))[:8].ljust(8, "\0"), 8)
    put("%d" % hlen, 8)         # number of bytes in header
    if edfplusflag:
        put("EDF+C")
    pos[0] += 44                # reserved
    put("%d" % nblocks, 8)      # number of blocks
    buf = "%g" % seconds_per_block
    put(buf[:8], 8)             # duration of a block, in seconds
    put("%d" % nsig, 4)         # number of signals
    for k in range(nsig):
        if len(si[k].desc) > 16:
            si[k].desc = si[k].desc[:16]
        put(si[k].desc, 16)     # label
    for k in range(nsig):
        put("transducer type not recorded", 80)
    for k in range(nsig):
        if si[k].units is None:     # wfdb-x: "nd" (C, legacy mode: mV)
            si[k].units = "mV" if legacy() else "nd"
        elif len(si[k].units) > 8:
            si[k].units = si[k].units[:8]
        put(si[k].units, 8)     # physical dimension
    for k in range(nsig):
        put("%g" % pmin[k], 8)
    for k in range(nsig):
        put("%g" % pmax[k], 8)
    for k in range(nsig):
        put("%d" % dmin[k], 8)
    for k in range(nsig):
        put("%d" % dmax[k], 8)
    for k in range(nsig):
        put("prefiltering not recorded", 80)
    for k in range(nsig):
        put("%d" % (frames_per_block * si[k].spf), 8)   # samples per block
    # (The last 32 * nsig bytes of the header are unused.)
    ofile.write(bytes(header))
    for k in range(hlen):
        c = int8(header[k])
        if c < 32 or c > 126:   # not printable ASCII
            eprintf("WARNING (%s): output contains an invalid character, %d,"
                    " at byte %d\n", pname, c, k)
    blocks_per_minute = blocks_per_hour = 0
    if vflag:
        out.write(" Header block size: %d bytes\n" % hlen)
        out.write(" Data block size: %g second%s (%d frame%s or %d bytes)\n"
                  % (seconds_per_block, "" if seconds_per_block == 1.0
                     else "s", frames_per_block,
                     "" if frames_per_block == 1 else "s", bytes_per_block))
        p = w.timstr(w.strtim("e")).lstrip(" ")
        out.write(" Recording length: %s (%d data blocks, %d frames, %d "
                  "bytes)\n" % (p, nblocks, nblocks * frames_per_block,
                                nblocks * bytes_per_block))
        out.write(" Total length of file to be written: %d bytes\n" %
                  (hlen + nblocks * bytes_per_block))
        blocks_per_minute = int(60 / seconds_per_block)
        blocks_per_hour = 60 * blocks_per_minute
    v = [0] * samples_per_frame
    spfs = [s.spf for s in si]
    for nb in range(1, nblocks + 1):
        block = bytearray(bytes_per_block)
        bp = []
        o = 0
        for k in range(nsig):
            bp.append(o)
            o += 2 * frames_per_block * spfs[k]
        for f in range(frames_per_block):
            if w.getframe(v) != nsig:
                for k in range(samples_per_frame):
                    v[k] = w.WFDB_INVALID_SAMPLE
            vp = 0
            for k in range(nsig):
                for kk in range(spfs[k]):
                    x = v[vp]
                    vp += 1
                    q = bp[k]
                    block[q] = x & 0xFF
                    block[q + 1] = (x >> 8) & 0xFF
                    bp[k] = q + 2
        ofile.write(bytes(block))
        if vflag:
            if nb % blocks_per_minute == 0:
                out.write(".")
                out.flush()
            if nb % blocks_per_hour == 0:
                out.write("\n")
    ofile.close()
    out.write("\n")
    if edfplusflag:
        out.flush()
        eprintf("\nWARNING (%s): EDF+ requires the subject's gender, "
                "birthdate, and name, as\n"
                " well as additional information about the recording that is "
                "not usually\n"
                " available.  This information is not saved in the output "
                "file even if\n"
                " available.  EDF+ also requires the use of standard names "
                "for signals and\n"
                " for physical units;  these requirements are not enforced by "
                "this program.\n"
                " To make the output file fully EDF+ compliant, its header "
                "must be edited\n"
                " manually.\n", pname)
        if not any(s.desc == "EDF-Annotations" for s in si):
            eprintf("\nWARNING:  The output file does not include EDF "
                    "annotations, which are\n required for EDF+.\n")
    w.wfdbquit()
    return 0


def main(argv=None):
    """Run mit2edf as a command and return its exit status.

    ``argv`` is the complete argument list, program name first, as in C
    (default: ``["mit2edf"] + sys.argv[1:]``).  Output and error messages
    are those of the C program.
    """
    if argv is None:
        argv = ["mit2edf"] + sys.argv[1:]
    out = Output()
    return run(lambda a: _main(a, out), argv, out)


if __name__ == "__main__":
    sys.exit(main())
