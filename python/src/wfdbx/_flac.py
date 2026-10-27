"""FLAC-compressed signal files (formats 508, 516, and 524).

This module implements, without external libraries, the FLAC support that
the C WFDB library obtains from libFLAC:

* a complete FLAC decoder (all subframe types, stereo decorrelation, wasted
  bits, variable block sizes, CRC verification, and optional MD5 checking
  when WFDB_FLAC_CHECK_MD5 is set), used to read signals; and
* a lossless FLAC encoder, used to write signals.  The encoder writes
  standard FLAC streams that libFLAC (and therefore the C WFDB library)
  reads back with identical sample values.  The compressed bytes are not
  identical to those written by libFLAC, whose output depends on its
  version and on the processor it runs on.

This file is part of WFDB-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.

It is a Python translation of the FLAC support of lib/signal.c (the code that
connects FLAC to the signal functions) from the WFDB Software Package 10.7.0,
by Benjamin Moody (2020). The translation follows the logic and behavior of the
original code, but it is new code, not the original C code. Its FLAC codec is
WFDB-x's own implementation of the FLAC format; it has no counterpart in the
original package, which uses libFLAC.

Changes from the original: FLAC streams are decoded and encoded by WFDB-x's own
codec instead of libFLAC; the files written decode to the same samples, but
their bytes differ from libFLAC's. Each change is marked "wfdb-x:" in the code;
docs/DIVERGENCES.md gives the reasons.

Original C code: lib/signal.c (FLAC support), WFDB Software Package 10.7.0.
  Copyright (C) 1989-2013 George B. Moody; revised 2011-2022 by Benjamin Moody,
  including FLAC support (2020).
Python translation and changes: Copyright (C) 2026 Reza Sameni.

This library is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import bisect
import os

from ._wfdbio import wfdb_error

FLAC__MAX_CHANNELS = 8      # as in libFLAC
_BLOCKSIZE = 4096           # samples per channel in each encoded frame
_STREAMINFO_LEN = 34        # length of the STREAMINFO metadata block
_SAMPLE_RATE = 96000        # nominal sample rate written (as in signal.c)
_VENDOR = b"wfdb-x"           # vendor string of the VORBIS_COMMENT block

# ---------------------------------------------------------------------------
# CRC tables

_CRC8 = []
for _i in range(256):
    _c = _i
    for _ in range(8):
        _c = ((_c << 1) ^ 0x07) & 0xFF if _c & 0x80 else (_c << 1) & 0xFF
    _CRC8.append(_c)
_CRC16 = []
for _i in range(256):
    _c = _i << 8
    for _ in range(8):
        _c = ((_c << 1) ^ 0x8005) & 0xFFFF if _c & 0x8000 else \
            (_c << 1) & 0xFFFF
    _CRC16.append(_c)


def _crc8(data):
    c = 0
    for b in data:
        c = _CRC8[c ^ b]
    return c


def _crc16(data):
    c = 0
    for b in data:
        c = ((c << 8) & 0xFFFF) ^ _CRC16[(c >> 8) ^ b]
    return c


# ---------------------------------------------------------------------------
# Decoder

class FlacError(Exception):
    """A FLAC stream could not be decoded (status: 'sync', 'header',
    'crc', or 'unparseable')."""

    def __init__(self, status):
        Exception.__init__(self, status)
        self.status = status


class _Bits:
    """MSB-first bit reader over a bytes object."""

    __slots__ = ("data", "pos", "end")

    def __init__(self, data, pos=0):
        self.data = data
        self.pos = pos * 8
        self.end = len(data) * 8

    def read(self, n):
        if n == 0:
            return 0
        p = self.pos
        e = p + n
        if e > self.end:
            raise FlacError("eof")
        b0 = p >> 3
        b1 = (e + 7) >> 3
        v = int.from_bytes(self.data[b0:b1], "big")
        v >>= (b1 << 3) - e
        self.pos = e
        return v & ((1 << n) - 1)

    def read_signed(self, n):
        v = self.read(n)
        if n and v & (1 << (n - 1)):
            v -= 1 << n
        return v

    def unary(self):
        """Count zero bits up to (and consume) the next one bit."""
        data = self.data
        p = self.pos
        n = 0
        bi = p >> 3
        off = p & 7
        if bi >= len(data):
            raise FlacError("eof")
        byte = (data[bi] << off) & 0xFF
        if byte:
            z = 8 - byte.bit_length()
            self.pos = p + z + 1
            return z
        n = 8 - off
        bi += 1
        while True:
            if bi >= len(data):
                raise FlacError("eof")
            byte = data[bi]
            if byte:
                z = 8 - byte.bit_length()
                self.pos = (bi << 3) + z + 1
                return n + z
            n += 8
            bi += 1

    def align(self):
        self.pos = (self.pos + 7) & ~7

    def byte_pos(self):
        return self.pos >> 3


def _read_utf8(bits):
    x = bits.read(8)
    if x < 0x80:
        return x
    if x & 0xE0 == 0xC0:
        v, n = x & 0x1F, 1
    elif x & 0xF0 == 0xE0:
        v, n = x & 0x0F, 2
    elif x & 0xF8 == 0xF0:
        v, n = x & 0x07, 3
    elif x & 0xFC == 0xF8:
        v, n = x & 0x03, 4
    elif x & 0xFE == 0xFC:
        v, n = x & 0x01, 5
    elif x == 0xFE:
        v, n = 0, 6
    else:
        raise FlacError("header")
    for _ in range(n):
        y = bits.read(8)
        if y & 0xC0 != 0x80:
            raise FlacError("header")
        v = (v << 6) | (y & 0x3F)
    return v


def _read_residual(bits, blocksize, order, out):
    method = bits.read(2)
    if method > 1:
        raise FlacError("unparseable")
    # Rice parameters have 4 bits (method 0) or 5 bits (method 1); the
    # all-ones parameter is an escape code for unencoded residuals.
    pbits, esc = (4, 15) if method == 0 else (5, 31)
    porder = bits.read(4)
    nparts = 1 << porder
    if blocksize % nparts:
        raise FlacError("unparseable")
    psize = blocksize >> porder
    if porder > 0 and psize < order:
        raise FlacError("unparseable")
    unary = bits.unary
    read = bits.read
    for part in range(nparts):
        n = psize - order if part == 0 else psize
        k = read(pbits)
        if k == esc:
            nb = read(5)        # bits per unencoded residual
            for _ in range(n):
                out.append(bits.read_signed(nb))
        elif k == 0:
            for _ in range(n):
                u = unary()
                out.append(-(u >> 1) - 1 if u & 1 else u >> 1)
        else:
            for _ in range(n):
                u = (unary() << k) | read(k)
                out.append(-(u >> 1) - 1 if u & 1 else u >> 1)


def _decode_subframe(bits, blocksize, bps):
    if bits.read(1):                # zero padding bit
        raise FlacError("unparseable")
    # Subframe type: 0 constant, 1 verbatim, 8-12 fixed predictor of order
    # t - 8, 32-63 LPC of order t - 31 (other values are reserved).
    t = bits.read(6)
    wasted = 0
    if bits.read(1):
        wasted = bits.unary() + 1
        bps -= wasted
    if t == 0:
        v = bits.read_signed(bps)
        samples = [v] * blocksize
    elif t == 1:
        rs = bits.read_signed
        samples = [rs(bps) for _ in range(blocksize)]
    elif 8 <= t <= 12:
        order = t - 8
        rs = bits.read_signed
        samples = [rs(bps) for _ in range(order)]
        res = []
        _read_residual(bits, blocksize, order, res)
        s = samples
        if order == 0:
            s.extend(res)
        elif order == 1:
            x = s[-1]
            for r in res:
                x += r
                s.append(x)
        elif order == 2:
            a, b = s[-2], s[-1]
            for r in res:
                a, b = b, 2 * b - a + r
                s.append(b)
        elif order == 3:
            a, b, c = s[-3], s[-2], s[-1]
            for r in res:
                a, b, c = b, c, 3 * c - 3 * b + a + r
                s.append(c)
        else:
            a, b, c, d = s[-4], s[-3], s[-2], s[-1]
            for r in res:
                a, b, c, d = b, c, d, 4 * d - 6 * c + 4 * b - a + r
                s.append(d)
    elif t >= 32:
        order = t - 31
        rs = bits.read_signed
        samples = [rs(bps) for _ in range(order)]
        prec = bits.read(4) + 1     # coefficient precision (all ones: invalid)
        if prec == 16:
            raise FlacError("unparseable")
        shift = bits.read_signed(5)     # quantization level
        coefs = [bits.read_signed(prec) for _ in range(order)]
        res = []
        _read_residual(bits, blocksize, order, res)
        s = samples
        rc = coefs[::-1]
        if shift < 0:
            raise FlacError("unparseable")
        for r in res:
            acc = 0
            hist = s[-order:]
            for cf, x in zip(rc, hist):
                acc += cf * x
            s.append(r + (acc >> shift))
    else:
        raise FlacError("unparseable")
    if wasted:
        samples = [x << wasted for x in samples]
    return samples


# Block sizes and sample sizes given by the codes of a frame header (block
# size codes 6 and 7, and sample size code 0, are handled separately).
_BS_TABLE = {1: 192, 2: 576, 3: 1152, 4: 2304, 5: 4608, 8: 256, 9: 512,
             10: 1024, 11: 2048, 12: 4096, 13: 8192, 14: 16384, 15: 32768}
_BPS_TABLE = {1: 8, 2: 12, 4: 16, 5: 20, 6: 24, 7: 32}


def _decode_frame(data, pos, si_bps, si_ch):
    """Decode one frame at byte offset pos; returns (channels, newpos)."""
    # Frame header: a 14-bit sync code (11111111 111110), a reserved bit,
    # the blocking strategy bit, and then the fields read below.
    if pos + 2 > len(data) or data[pos] != 0xFF or \
            (data[pos + 1] & 0xFE) != 0xF8:
        raise FlacError("sync")
    bits = _Bits(data, pos)
    bits.read(15)       # sync code and reserved bit
    bits.read(1)        # blocking strategy
    bsc = bits.read(4)  # block size code
    src = bits.read(4)  # sample rate code
    chc = bits.read(4)  # channel assignment
    ssc = bits.read(3)  # sample size code
    if bits.read(1):    # reserved
        raise FlacError("header")
    _read_utf8(bits)    # frame or sample number
    if bsc == 0:
        raise FlacError("header")
    elif bsc == 6:      # block size - 1 follows, in 8 bits
        blocksize = bits.read(8) + 1
    elif bsc == 7:      # ... or in 16 bits
        blocksize = bits.read(16) + 1
    else:
        blocksize = _BS_TABLE[bsc]
    if src == 12:       # sample rate in kHz (8 bits)
        bits.read(8)
    elif src in (13, 14):   # sample rate in Hz or tens of Hz (16 bits)
        bits.read(16)
    elif src == 15:
        raise FlacError("header")
    if ssc == 0:
        bps = si_bps
    elif ssc in _BPS_TABLE:
        bps = _BPS_TABLE[ssc]
    else:
        raise FlacError("header")
    hend = bits.byte_pos()
    crc = bits.read(8)
    if _crc8(data[pos:hend]) != crc:
        raise FlacError("header")
    if chc < 8:             # independent channels
        nch = chc + 1
        chans = [_decode_subframe(bits, blocksize, bps) for _ in range(nch)]
    elif chc <= 10:
        nch = 2
        if chc == 8:        # left/side
            a = _decode_subframe(bits, blocksize, bps)
            sd = _decode_subframe(bits, blocksize, bps + 1)
            chans = [a, [x - y for x, y in zip(a, sd)]]
        elif chc == 9:      # side/right
            sd = _decode_subframe(bits, blocksize, bps + 1)
            b = _decode_subframe(bits, blocksize, bps)
            chans = [[x + y for x, y in zip(sd, b)], b]
        else:               # mid/side
            m = _decode_subframe(bits, blocksize, bps)
            sd = _decode_subframe(bits, blocksize, bps + 1)
            le = []
            ri = []
            for x, y in zip(m, sd):
                x = (x << 1) | (y & 1)
                le.append((x + y) >> 1)
                ri.append((x - y) >> 1)
            chans = [le, ri]
    else:
        raise FlacError("header")
    bits.align()
    fend = bits.byte_pos()
    crc16 = bits.read(16)
    if _crc16(data[pos:fend]) != crc16:
        raise FlacError("crc")
    return chans, bps, bits.byte_pos()


class _FlacInput:
    """Decoded state of a FLAC signal file (one WFDB input group)."""

    def __init__(self, nsig, datb, spf):
        self.nsig = nsig
        self.datb = datb        # resolution of the group (8, 16, or 24)
        self.spf = spf
        self.samples = None     # frame-ordered sample stream
        self.total = 0          # samples per channel
        self.pos = 0            # index into self.samples
        self.error = None
        self.md5_check = bool(os.environ.get("WFDB_FLAC_CHECK_MD5"))
        self.md5 = None
        self.decoded_md5 = None
        self.seeked = False
        # State of the libFLAC decoder of the C library, which decodes one
        # FLAC block at a time: the end of each block (in samples per
        # channel), the end of the blocks decoded so far, the sample from
        # which 'samples' starts, whether the buffered samples were
        # discarded by a failed seek, and whether decoding was aborted
        # (after a failed seek, iflac_samples() aborts the decoding of the
        # next block, and libFLAC then refuses to seek).
        self.block_ends = []
        self.dec_end = 0
        self.base = 0
        self.discarded = False
        self.aborted = False


def decode_bytes(data):
    """Decode a complete FLAC stream (bytes).

    Returns ``(channels, bits_per_sample)``, where ``channels`` is a list of
    lists of samples (one per channel).  Raises FlacError on invalid input.
    """
    return _decode_data(data, None)


def _decode_stream(fp, fi):
    """Decode the whole FLAC stream of a signal group (once)."""
    return _decode_data(fp.readall(), fi)


def _decode_data(data, fi):
    # Errors in the stream header and metadata are reported by libFLAC
    # without invoking its error callback ('meta' status).
    if data[:4] != b"fLaC":
        raise FlacError("meta")
    pos = 4
    si_bps = si_ch = 0
    while True:
        if pos + 4 > len(data):
            raise FlacError("meta")
        hb = data[pos]
        ln = int.from_bytes(data[pos + 1:pos + 4], "big")
        if pos + 4 + ln > len(data):
            raise FlacError("meta")
        # Metadata block header: last-block flag (bit 7), block type (bits
        # 0-6), and block length (24 bits).
        if hb & 0x7F == 0:      # STREAMINFO
            if ln < _STREAMINFO_LEN:
                raise FlacError("meta")
            b = _Bits(data, pos + 4)
            b.read(16)          # minimum block size
            b.read(16)          # maximum block size
            b.read(24)          # minimum frame size
            b.read(24)          # maximum frame size
            b.read(20)          # sample rate
            si_ch = b.read(3) + 1
            si_bps = b.read(5) + 1
            b.read(36)          # total samples
            if fi is not None:  # MD5 signature: the last 16 bytes
                fi.md5 = bytes(data[pos + 22:pos + 38])
        pos += 4 + ln
        if hb & 0x80:
            break
    chans = [[] for _ in range(max(si_ch, 1))]
    while pos < len(data):
        try:
            fr, bps, pos = _decode_frame(data, pos, si_bps, si_ch)
        except FlacError as e:
            if e.status == "sync" and all(x == 0 for x in data[pos:]):
                break
            raise
        if fi is not None and len(fr) != fi.nsig:
            wfdb_error("getvec: wrong number of signals in FLAC signal file\n")
            raise FlacError("wfdb")
        if fi is not None and bps > fi.datb:
            wfdb_error("getvec: wrong sample resolution in FLAC signal file\n")
            raise FlacError("wfdb")
        for c, f in zip(chans, fr):
            c.extend(f)
        if fi is not None and fr:
            fi.block_ends.append(len(chans[0]))
    return chans, si_bps


def _ensure_decoded(ig):
    fi = ig.flac
    if fi.samples is not None or fi.error is not None:
        return
    try:
        import numpy as np
        chans, bps = _decode_stream(ig.fp, fi)
        n = len(chans[0]) if chans else 0
        arr = np.array(chans, dtype=np.int64).reshape(len(chans), n) \
            if n else np.zeros((fi.nsig, 0), np.int64)
        if fi.md5_check and n:
            import hashlib      # (imported only when needed: it is slow)
            nb = (bps + 7) // 8
            inter = arr.T.astype("<i4").view(np.uint8).reshape(n, -1, 4)
            fi.decoded_md5 = hashlib.md5(
                inter[:, :, :nb].tobytes()).digest()
        fi.arr = arr
        fi.total = n
        _pack(fi, 0)
    except FlacError as e:
        status = e.status
        if status == "sync":
            wfdb_error("getvec: unable to decode FLAC (lost sync)\n")
        elif status == "header":
            wfdb_error("getvec: unable to decode FLAC (invalid header)\n")
        elif status == "crc":
            wfdb_error("getvec: unable to decode FLAC (CRC mismatch)\n")
        elif status == "unparseable":
            wfdb_error("getvec: unable to decode FLAC (unsupported format)\n")
        elif status == "eof":
            wfdb_error("getvec: unable to decode FLAC\n")
        elif status == "meta":
            wfdb_error("getvec: unexpected FLAC decoding error\n")
        fi.error = status
        fi.samples = []


def _pack(fi, base):
    """Arrange the samples from sample number 'base' onward in frame order
    (as iflac_samples() does after a seek to that sample)."""
    spf = fi.spf
    nch = fi.arr.shape[0]
    nfr = (fi.total - base) // spf
    fi.leftover = (fi.total - base) - nfr * spf
    a = fi.arr[:, base:base + nfr * spf].reshape(nch, nfr, spf)
    fi.samples = a.transpose(1, 0, 2).reshape(-1).tolist()
    fi.pos = 0
    fi.base = base


def _block_end(fi, n):
    """The end of the FLAC block that contains sample n - 1 (n > 0): the
    number of samples (per channel) decoded once sample n - 1 is."""
    k = bisect.bisect_left(fi.block_ends, n)
    return fi.block_ends[k] if k < len(fi.block_ends) else fi.total


def isopen(ig, hs, ns):
    """Prepare to read a FLAC signal group (flac_isopen)."""
    if ns > FLAC__MAX_CHANNELS:
        wfdb_error("isigopen: cannot store %u signals in a single FLAC file\n",
                   ns)
        return -1
    for i in range(1, ns):
        if hs[i].info.spf != hs[0].info.spf:
            wfdb_error("isigopen: every signal in a FLAC file must have\n"
                       "  the same sampling frequency\n")
            return -1
    ig.flac = _FlacInput(ns, hs[0].info.fmt - 500, hs[0].info.spf)
    ig.count = 0
    return 0


def getsamp(ig):
    """Return the next sample from a FLAC signal group (flac_getsamp)."""
    fi = ig.flac
    if fi.samples is None:
        _ensure_decoded(ig)
    if fi.error is not None:
        ig.stat = -2
        return 0
    if fi.aborted:
        return 0        # (the decoder does nothing; ig.stat is negative)
    p = fi.pos
    if p < len(fi.samples):
        # The frame of sample p must have been decoded.
        need = fi.base + (p // (fi.nsig * fi.spf) + 1) * fi.spf
        if fi.discarded or need > fi.dec_end:
            if ig.stat < 0:
                return _abort(ig) if fi.dec_end < fi.total else 0
            fi.dec_end = _block_end(fi, need)
        fi.pos = p + 1
        return fi.samples[p]
    if fi.discarded and fi.dec_end < fi.total:
        return _abort(ig)
    if ig.stat < 0:
        return 0
    fi.dec_end = fi.total
    if fi.leftover:
        wfdb_error("getvec: warning: %d samples left over at end of file\n",
                   fi.leftover)
        fi.leftover = 0
    ig.stat = 0
    return 0


def _abort(ig):
    """Decoding a block after a failed seek (ig.stat < 0): iflac_samples()
    aborts the decoder, and flac_getsamp() reports the error."""
    fi = ig.flac
    fi.aborted = True
    if ig.stat != -2:
        wfdb_error("getvec: unexpected FLAC decoding error\n")
        ig.stat = -2
    return 0


def isseek(ig, t):
    """Seek to frame t of a FLAC signal group (flac_isseek)."""
    fi = ig.flac
    if fi.samples is None:
        _ensure_decoded(ig)
    ig.stat = 1
    ig.count = 0
    fi.seeked = True
    if fi.error is not None:
        ig.stat = -1
        return -1
    tt = t * fi.spf + ig.start
    if fi.aborted or tt > fi.total or tt < 0:
        # (libFLAC refuses to seek once decoding was aborted, or past the
        # end of the stream; the buffered samples are discarded anyway)
        fi.discarded = True
        ig.stat = -1
        return -1
    _pack(fi, tt)
    fi.discarded = False
    # The seek decodes the block that contains sample tt - 1 (sample 0 if
    # tt is 0): libFLAC seeks to it, and the first sample is skipped.
    fi.dec_end = _block_end(fi, max(tt, 1))
    return ig.stat


def isclose(ig):
    """Check the MD5 signature, if requested (flac_isclose)."""
    fi = ig.flac
    if fi is not None and fi.md5_check and fi.md5 is not None and \
            fi.decoded_md5 is not None and not fi.seeked and \
            any(fi.md5) and fi.md5 != fi.decoded_md5:
        wfdb_error("isigclose: warning: incorrect MD5 hash in FLAC input\n")
        return -1
    return 0


# ---------------------------------------------------------------------------
# Encoder

class _BitWriter:
    """MSB-first bit writer."""

    __slots__ = ("acc", "n", "out")

    def __init__(self):
        self.acc = 0
        self.n = 0
        self.out = bytearray()

    def write(self, v, n):
        self.acc = (self.acc << n) | (v & ((1 << n) - 1))
        self.n += n
        if self.n >= 4096:      # keep the accumulator small
            self._flush_whole()

    def _flush_whole(self):
        k = self.n >> 3
        r = self.n & 7
        self.out += (self.acc >> r).to_bytes(k, "big")
        self.acc &= (1 << r) - 1
        self.n = r

    def align(self):
        if self.n & 7:
            self.write(0, 8 - (self.n & 7))

    def getbytes(self):
        self._flush_whole()
        assert self.n == 0
        return bytes(self.out)


def _utf8(v):
    """Code a frame number as in UTF-8 (extended to 36 bits, as in FLAC)."""
    if v < 0x80:
        return bytes((v,))
    for n, lead, mx in ((1, 0xC0, 0x7FF), (2, 0xE0, 0xFFFF),
                        (3, 0xF0, 0x1FFFFF), (4, 0xF8, 0x3FFFFFF),
                        (5, 0xFC, 0x7FFFFFFF), (6, 0xFE, 0xFFFFFFFFF)):
        if v <= mx:
            out = []
            for _ in range(n):
                out.append(0x80 | (v & 0x3F))
                v >>= 6
            out.append(lead | v)
            return bytes(reversed(out))
    raise ValueError(v)


def _rice_cost(u, k):
    """Bits needed to code the folded residuals u with Rice parameter k."""
    return sum((x >> k) for x in u) + len(u) * (k + 1)


def _best_partition(u, order, blocksize, maxk):
    """Choose a partition order and Rice parameters for folded residuals."""
    best = None
    for porder in range(0, 7):      # partition orders 0-6, as libFLAC
        nparts = 1 << porder
        if blocksize % nparts:
            break
        psize = blocksize >> porder
        if porder > 0 and psize <= order:
            break
        cost = 6                    # coding method and partition order
        params = []
        start = 0
        for p in range(nparts):
            n = psize - order if p == 0 else psize
            part = u[start:start + n]
            start += n
            if n == 0:
                params.append(0)
                cost += 4
                continue
            mean = sum(part) // n
            k0 = max(mean.bit_length() - 1, 0) if mean > 0 else 0
            bk, bc = None, None
            lo = min(max(k0 - 1, 0), maxk)
            for k in range(lo, min(k0 + 2, maxk) + 1):
                c = _rice_cost(part, k)
                if bc is None or c < bc:
                    bk, bc = k, c
            params.append(bk)
            cost += 4 + bc
        if best is None or cost < best[0]:
            best = (cost, porder, params)
    return best


def _encode_subframe(bw, x, bps):
    """Encode one channel as a constant, fixed-predictor or verbatim
    subframe, whichever is smallest.  A subframe header is a zero bit, the
    6-bit type (0 constant, 1 verbatim, 8 + order fixed) and a zero
    wasted-bits flag."""
    n = len(x)
    if all(v == x[0] for v in x):
        bw.write(0, 1)
        bw.write(0, 6)
        bw.write(0, 1)
        bw.write(x[0], bps)
        return
    maxk = 30           # largest Rice parameter (5-bit parameters, escape 31)
    best = None
    for order in range(0, min(4, n - 1) + 1):
        if order == 0:
            r = x
        elif order == 1:
            r = [x[i] - x[i - 1] for i in range(1, n)]
        elif order == 2:
            r = [x[i] - 2 * x[i - 1] + x[i - 2] for i in range(2, n)]
        elif order == 3:
            r = [x[i] - 3 * x[i - 1] + 3 * x[i - 2] - x[i - 3]
                 for i in range(3, n)]
        else:
            r = [x[i] - 4 * x[i - 1] + 6 * x[i - 2] - 4 * x[i - 3] + x[i - 4]
                 for i in range(4, n)]
        u = [(v << 1) if v >= 0 else ((-v) << 1) - 1 for v in r]
        bp = _best_partition(u, order, n, maxk)
        if bp is None:
            continue
        cost = order * bps + 2 + bp[0]
        if best is None or cost < best[0]:
            best = (cost, order, u, bp)
    if best is None or best[0] >= n * bps:
        bw.write(0, 1)
        bw.write(1, 6)
        bw.write(0, 1)
        for v in x:
            bw.write(v, bps)
        return
    cost, order, u, (pc, porder, params) = best
    bw.write(0, 1)
    bw.write(8 + order, 6)
    bw.write(0, 1)
    for v in x[:order]:
        bw.write(v, bps)
    method = 0 if max(params) < 15 else 1   # 4-bit parameters if possible
    pbits = 4 if method == 0 else 5
    bw.write(method, 2)
    bw.write(porder, 4)
    psize = n >> porder
    start = 0
    for p, k in enumerate(params):
        cnt = psize - order if p == 0 else psize
        bw.write(k, pbits)
        for v in u[start:start + cnt]:
            q = v >> k
            # unary quotient (q zeros then a one), then k low bits
            bw.write(1, q + 1)
            if k:
                bw.write(v, k)
        start += cnt


class _FlacOutput:
    """Encoder state of a FLAC signal file (one WFDB output group)."""

    def __init__(self, nsig, bps, spf):
        self.nsig = nsig
        self.bps = bps
        self.spf = spf
        self.chans = [[] for _ in range(nsig)]
        self.frame_no = 0
        self.total = 0
        self.minfs = None
        self.maxfs = 0
        import hashlib
        self.md5 = hashlib.md5()
        self.header_pos = 0
        self.pending = []       # samples of the current (incomplete) frame


def osinit(og, si, ns):
    """Prepare to write a FLAC signal group (flac_osinit)."""
    if ns > FLAC__MAX_CHANNELS:
        wfdb_error("osigfopen: cannot store %u signals in a single FLAC "
                   "file\n", ns)
        return -1
    for i in range(1, ns):
        if si[i].spf != si[0].spf:
            wfdb_error("osigfopen: every signal in a FLAC file must have\n"
                       "  the same sampling frequency\n")
            return -1
    og.flac = _FlacOutput(ns, si[0].fmt - 500, si[0].spf)
    og.bsize = ns * si[0].spf * 4   # one frame of 32-bit samples, as in C
    return 0


def _streaminfo(fo, total, md5):
    """The contents of the STREAMINFO metadata block."""
    bw = _BitWriter()
    bw.write(_BLOCKSIZE, 16)    # minimum block size
    bw.write(_BLOCKSIZE, 16)    # maximum block size
    bw.write(fo.minfs or 0, 24)
    bw.write(fo.maxfs, 24)
    bw.write(_SAMPLE_RATE, 20)
    bw.write(fo.nsig - 1, 3)
    bw.write(fo.bps - 1, 5)
    bw.write(total, 36)
    return bw.getbytes() + md5


def osopen(og):
    """Write the stream header (flac_osopen)."""
    fo = og.flac
    # A STREAMINFO block (rewritten by osclose; until then the total number
    # of samples is the largest possible value, as in signal.c), and a
    # VORBIS_COMMENT block (type 4, the last one) with no comments.
    vc = len(_VENDOR).to_bytes(4, "little") + _VENDOR + b"\0\0\0\0"
    hdr = b"fLaC" + bytes((0,)) + _STREAMINFO_LEN.to_bytes(3, "big") + \
        _streaminfo(fo, (1 << 36) - 1, b"\0" * 16) + \
        bytes((0x80 | 4,)) + len(vc).to_bytes(3, "big") + vc
    fo.header_pos = og.fp.tell() if og.fp is not None else 0
    if og.fp is not None:
        og.fp.write(hdr)
    return 0


def putsamp(v, fmt, og):
    """Append a sample to a FLAC output group (flac_putsamp)."""
    fo = og.flac
    # Wrap the sample to the resolution of the format.
    if fmt == 508:
        v = ((v + 0x80) & 0xFF) - 0x80
    elif fmt == 516:
        v = ((v + 0x8000) & 0xFFFF) - 0x8000
    elif fmt == 524:
        v = ((v + 0x800000) & 0xFFFFFF) - 0x800000
    pend = fo.pending
    pend.append(v)
    if len(pend) == fo.nsig * fo.spf:
        spf = fo.spf
        for c in range(fo.nsig):
            fo.chans[c].extend(pend[c * spf:(c + 1) * spf])
        del pend[:]
        if len(fo.chans[0]) >= _BLOCKSIZE:
            _write_block(og, _BLOCKSIZE)
    return 0


def _write_block(og, n):
    fo = og.flac
    block = [c[:n] for c in fo.chans]
    for c in fo.chans:
        del c[:n]
    nb = (fo.bps + 7) // 8
    inter = bytearray()
    for i in range(n):
        for c in block:
            inter += (c[i] & ((1 << (8 * nb)) - 1)).to_bytes(nb, "little")
    fo.md5.update(bytes(inter))
    # Frame header (see _decode_frame).
    hb = _BitWriter()
    hb.write(0xFFF8 >> 1, 15)       # sync code and reserved bit
    hb.write(0, 1)                  # fixed block size
    if n == _BLOCKSIZE:
        bsc = 12                    # 4096
    elif n <= 256:
        bsc = 6                     # n - 1 in 8 bits
    else:
        bsc = 7                     # n - 1 in 16 bits
    hb.write(bsc, 4)
    hb.write(11, 4)                 # 96 kHz
    hb.write(fo.nsig - 1, 4)        # independent channels
    hb.write({8: 1, 16: 4, 24: 6}.get(fo.bps, 0), 3)
    hb.write(0, 1)
    head = hb.getbytes() + _utf8(fo.frame_no)
    if bsc == 6:
        head += bytes((n - 1,))
    elif bsc == 7:
        head += (n - 1).to_bytes(2, "big")
    head += bytes((_crc8(head),))
    bw = _BitWriter()
    for c in block:
        _encode_subframe(bw, c, fo.bps)
    bw.align()
    frame = head + bw.getbytes()
    frame += _crc16(frame).to_bytes(2, "big")
    if og.fp is not None:
        og.fp.write(frame)
    fo.frame_no += 1
    fo.total += n
    fs = len(frame)
    fo.minfs = fs if fo.minfs is None else min(fo.minfs, fs)
    fo.maxfs = max(fo.maxfs, fs)


def osclose(og):
    """Encode any remaining samples and finish the stream (flac_osclose)."""
    fo = og.flac
    while fo.chans and len(fo.chans[0]) > 0:
        _write_block(og, min(len(fo.chans[0]), _BLOCKSIZE))
    # Rewrite STREAMINFO, after "fLaC" and its 4-byte block header.
    if og.fp is not None and og.fp.seek(fo.header_pos + 8, 0) == 0:
        og.fp.write(_streaminfo(fo, fo.total, fo.md5.digest()))
        og.fp.seek(0, 2)
    og.flac = None
    og.buf = bytearray()
    return 0
