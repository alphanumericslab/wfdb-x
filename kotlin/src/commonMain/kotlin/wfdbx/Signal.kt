// Signal I/O (port of lib/signal.c, through rust/src/signal.rs): headers
// (including EDF headers), signal files in every storage format (0, 8, 16,
// 61, 80, 160, 212, 310, 311, 24, 32, and the FLAC formats 508, 516 and
// 524), multi-segment and multi-frequency records, header and info files.
// The time, date and amplitude conversions of signal.c are in
// SignalTime.kt.
//
// The functions are extension functions of Wfdb (with top-level versions
// that use the default instance); they behave as those of the C library,
// with the same integer types and status codes. Their state is held in
// SigState, part of Wfdb.
//
// Functions that fill a caller's array take an IntArray: getvec writes one
// sample per signal (getframe one frame, that is the sum of the samples per
// frame of all signals). If the array is shorter than that, only its length
// is filled (the other values are discarded).
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of lib/signal.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original code, but it is new code, not the original C code.
//
// Changes from the original: no built-in sampling frequency, gain, ADC
// resolution or units (the original assumed 250 Hz, 200 adu/mV, 12 bits or a
// resolution based on the format, and millivolts): a value that the header
// does not give stays unspecified, and the time and amplitude conversions that
// need it, and setifreq, report an error; the signal files and segments named
// in a header are read only from the header's directory (on disk or at its
// URL), never searched for, and a name that leaves that directory is refused;
// an output signal file is never one of the input files of the open record; a
// header written under a path names the record, its signal files and its
// segments relative to its own directory; FLAC signal files are read and
// written with WFDB-x's FLAC codec (Flac.kt) instead of libFLAC; additions:
// getvecs, getvecs_status, wfdbx_bulk_read and putframes; legacy mode
// (wfdbx_set_legacy) restores the original behavior. Each change is marked
// "WFDB-x:" in the code; docs/DIVERGENCES.md gives the reasons.
//
// Original C code: lib/signal.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1989-2013 George B. Moody; revised 2011-2022 by
//   Benjamin Moody, including FLAC support (2020).
// Kotlin translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx

import wfdbx.cstd.ByteVec
import wfdbx.cstd.CDouble
import wfdbx.cstd.CInt
import wfdbx.cstd.CLong
import wfdbx.cstd.FileId
import wfdbx.cstd.INT_MAX
import wfdbx.cstd.SEEK_CUR
import wfdbx.cstd.SEEK_END
import wfdbx.cstd.SEEK_SET
import wfdbx.cstd.Strtok
import wfdbx.cstd.at
import wfdbx.cstd.beq
import wfdbx.cstd.cformat
import wfdbx.cstd.cstr
import wfdbx.cstd.d2i
import wfdbx.cstd.d2l
import wfdbx.cstd.getenv
import wfdbx.cstd.isdigit
import wfdbx.cstd.latin1
import wfdbx.cstd.sscanf
import wfdbx.cstd.startsWith
import wfdbx.cstd.strtod
import wfdbx.cstd.strtol

/** BUFSIZ of the reference platform (default buffer sizes). */
private const val WFDB_BUFSIZ = 8192

/**
 * WFDB-x: the largest input buffer of a signal file whose size is not
 * known (a larger block is read in several parts, with the same results).
 */
private const val BUF_MAX = 1 shl 26

/** Frames per tile of the bulk path (see bulkFrames). */
private const val BULK_TILE = 1024

/** Size of the sample() buffer (a power of 2). */
private const val BUFLN = 4096L

private const val SEP = " \t\n\r"

/** FLAC formats are numbered from FLAC_FMT_BASE to FLAC_FMT_MAX; the bits per sample are fmt - FLAC_FMT_BASE. */
private const val FLAC_FMT_BASE = 500
private const val FLAC_FMT_MAX = 532

/** Longest file name plus description accepted for an output signal (as in C's osigfopen). */
private const val MAXFDLEN = 200

/** Length of the longest EDF header field. */
private const val EDF_MAXFIELD = 80

/** Size of the fixed part of an EDF header, and of each signal's part. */
private const val EDF_HDRBLOCK = 256L

// ---------------------------------------------------------------------------
// Data structures

/** Signal information from a header. */
internal class HsData {
    var info = Siginfo()

    /** Signal file byte offset to sample 0. */
    var start = 0L

    /** Intersignal skew (in frames). */
    var skew = 0
}

/** An open input signal. */
internal class IsData {
    var info = Siginfo()

    /** Most recent sample read. */
    var samp = 0

    /** Intersignal skew (in frames). */
    var skew = 0

    /** Current high-resolution sample number. */
    var gvindex = 0

    /** Counter for updating gvindex. */
    var gvcount = 0
}

/** FLAC input (one signal group): the FLAC fields of the C `igdata`. */
internal class FlacIn(val pack: FlacPack) {
    /** The decoder (made from the signal file when the group is first read or sought). */
    var dec: FlacStreamDecoder? = null
    var md5Check = false
}

/**
 * The decoded samples of a FLAC signal group not yet read, in frame order,
 * and what the decoder reports (C `iflac_samples` and `iflac_error`, which
 * receive the results of the libFLAC decoder).
 */
internal class FlacPack(
    /** Signals in the group (C `data`), and their resolution (`datb`). */
    val nsig: Int,
    val datb: Int,
    /** Samples per frame of each signal (C `packspf`). */
    val spf: Int,
) : FlacClient {
    /**
     * `buf[bp until packptr]`: complete frames not yet read; then the frame
     * being filled (up to `size`), of which `packcount` samples per signal
     * are decoded.
     */
    var buf = IntArray(0)
    var size = 0
    var bp = 0
    var packptr = 0
    var packcount = 0

    /** Samples (per signal) to skip after a seek (C `count`). */
    var count = 0L

    /** The group's `stat` while the decoder runs. */
    var stat = 0

    /** The messages to report. */
    val msgs = ArrayList<String>()

    /** Sets the number of values in buf to n (new values are 0). */
    private fun resize(n: Int) {
        if (n > buf.size) buf = buf.copyOf(maxOf(n, 2 * buf.size))
        if (n > size) buf.fill(0, size, n)
        size = n
    }

    /** Drops the values read and the frame being filled (after a seek). */
    fun clear() {
        size = 0
        bp = 0
        packptr = 0
        packcount = 0
        count = 0
    }

    override fun error(e: FlacDecodeError) {
        msgs.add(
            when (e) {
                FlacDecodeError.LOST_SYNC -> "getvec: unable to decode FLAC (lost sync)\n"
                FlacDecodeError.BAD_HEADER -> "getvec: unable to decode FLAC (invalid header)\n"
                FlacDecodeError.CRC_MISMATCH -> "getvec: unable to decode FLAC (CRC mismatch)\n"
                FlacDecodeError.UNPARSEABLE -> "getvec: unable to decode FLAC (unsupported format)\n"
            },
        )
        // (decoding stops at the next frame)
        stat = -2
    }

    override fun write(h: FlacFrameHeader, chans: Array<IntArray>, off: Int): Boolean {
        if (h.channels != nsig) {
            msgs.add("getvec: wrong number of signals in FLAC signal file\n")
            stat = -2
        }
        if (h.bitsPerSample > datb) {
            msgs.add("getvec: wrong sample resolution in FLAC signal file\n")
            stat = -2
        }
        if (stat < 0) return false
        val frmsize = chans.size * spf
        // Shift out the samples already read.
        if (bp > 0) {
            buf.copyInto(buf, 0, bp, size)
            size -= bp
            packptr -= bp
            bp = 0
        }
        var nsamp = h.blocksize.toLong()
        if (count > nsamp) {
            count -= nsamp
            return true
        }
        var ipos = off + count.toInt()
        nsamp -= count
        count = 0
        // Store the samples in frame order.
        var orem = spf - packcount
        var p = packptr + packcount
        resize(packptr + frmsize)
        while (nsamp != 0L) {
            val n = minOf(nsamp, orem.toLong()).toInt()
            for (s in chans.indices) chans[s].copyInto(buf, p + s * spf, ipos, ipos + n)
            nsamp -= n
            orem -= n
            if (orem == 0) {
                packptr += frmsize
                resize(packptr + frmsize)
                p = packptr
                orem = spf
                ipos += n
            }
        }
        packcount = spf - orem
        return true
    }
}

/** Shared by all signals in an input group (file). */
internal class IgData {
    var data = 0
    var datb = 0
    var fp: WfdbFile? = null
    var start = 0L

    /** Block size (WFDB-x: a Long, since that of a header can be 2^31: see isigopen). */
    var bsize = 0L
    var buf = ByteArray(0)
    var bp = 0
    var be = 0
    var flac: FlacIn? = null
    var count = 0
    var seek = 0
    var initialSkip = 0
    var stat = 0

    private fun r8Fill(): Int {
        val n = if (bsize > 0) minOf(bsize, buf.size.toLong()).toInt() else buf.size
        val got = fp?.read(buf, 0, n) ?: 0
        stat = got
        bp = 0
        be = got
        val c = if (buf.isNotEmpty()) buf[0].toInt() else 0
        bp = 1
        return c
    }

    fun r8(): Int {
        if (bp < be) return buf[bp++].toInt()
        return r8Fill()
    }

    fun r16(): Int {
        if (bp + 2 <= be) {
            val v = (buf[bp].toInt() and 0xff) or (buf[bp + 1].toInt() shl 8)
            bp += 2
            return v.toShort().toInt()
        }
        val l = r8()
        val h = r8()
        return ((h shl 8) or (l and 0xff)).toShort().toInt()
    }

    fun r61(): Int {
        if (bp + 2 <= be) {
            val v = (buf[bp + 1].toInt() and 0xff) or (buf[bp].toInt() shl 8)
            bp += 2
            return v.toShort().toInt()
        }
        val h = r8()
        val l = r8()
        return ((l and 0xff) or (h shl 8)).toShort().toInt()
    }

    fun r24(): Int {
        if (bp + 3 <= be) {
            val v = (buf[bp].toInt() and 0xff) or ((buf[bp + 1].toInt() and 0xff) shl 8) or (buf[bp + 2].toInt() shl 16)
            bp += 3
            return v
        }
        val lw = r16()
        val h = r8()
        return (h shl 16) or (lw and 0xffff)
    }

    fun r32(): Int {
        if (bp + 4 <= be) {
            val v = (buf[bp].toInt() and 0xff) or ((buf[bp + 1].toInt() and 0xff) shl 8) or
                ((buf[bp + 2].toInt() and 0xff) shl 16) or (buf[bp + 3].toInt() shl 24)
            bp += 4
            return v
        }
        val lw = r16()
        val h = r16()
        return (h shl 16) or (lw and 0xffff)
    }

    fun r80(): Int = (r8() and 0xff) - (1 shl 7)

    fun r160(): Int = (r16() and 0xffff) - (1 shl 15)

    /** Format 212: 2 12-bit samples bit-packed in 3 bytes. */
    fun r212(): Int {
        var v: Int
        val c = count++
        if (c == 0) {
            data = r16()
            v = data
        } else {
            count = 0
            v = ((data shr 4) and 0xf00) or (r8() and 0xff)
        }
        v = if (v and 0x800 != 0) v or 0xfff.inv() else v and 0xfff
        return v
    }

    /** Format 310: 3 10-bit samples bit-packed in 4 bytes. */
    fun r310(): Int {
        val c = count++
        var v = when (c) {
            0 -> {
                data = r16()
                data shr 1
            }
            1 -> {
                datb = r16()
                datb shr 1
            }
            else -> {
                count = 0
                ((data and 0xf800) shr 11) or ((datb and 0xf800) shr 6)
            }
        }
        v = if (v and 0x200 != 0) v or 0x3ff.inv() else v and 0x3ff
        return v
    }

    /** Format 311: 3 10-bit samples bit-packed in 4 bytes. */
    fun r311(): Int {
        val c = count++
        var v = when (c) {
            0 -> {
                data = r16()
                data
            }
            1 -> {
                datb = r8() and 0xff
                ((data and 0xfc00) shr 10) or ((datb and 0xf) shl 6)
            }
            else -> {
                count = 0
                datb = datb or (r8() shl 8)
                datb shr 4
            }
        }
        v = if (v and 0x200 != 0) v or 0x3ff.inv() else v and 0x3ff
        return v
    }
}

/** An open output signal. */
internal class OsData {
    var info = Siginfo()
    var samp = 0
    var skew = 0
}

/** FLAC output (one signal group). */
internal class FlacOut(val enc: FlacEncoder) {
    var headerPos = 0L
    val pending = ByteVec(4096)
}

/** Shared by all signals in an output group (file). */
internal class OgData {
    var data = 0
    var datb = 0
    var fp: WfdbFile? = null
    var start = 0L
    var bsize = 0
    var buf = ByteArray(0)
    var bp = 0
    var be = 0
    var flac: FlacOut? = null
    var count = 0
    var seek = 0
    var forceFlush = 0
    var nrewind = 0

    private fun w8Flush(obsize: Int) {
        var n = if (bsize > 0) bsize else obsize
        bp = 0
        if (n > buf.size) n = buf.size
        fp?.write(buf, 0, n)
    }

    fun w8(v: Int, ob: Int) {
        buf[bp++] = v.toByte()
        if (bp == be) w8Flush(ob)
    }

    fun w16(v: Int, ob: Int) {
        w8(v, ob)
        w8(v shr 8, ob)
    }

    fun w61(v: Int, ob: Int) {
        w8(v shr 8, ob)
        w8(v, ob)
    }

    fun w24(v: Int, ob: Int) {
        w16(v, ob)
        w8(v shr 16, ob)
    }

    fun w32(v: Int, ob: Int) {
        w16(v, ob)
        w16(v shr 16, ob)
    }

    fun w80(v: Int, ob: Int) = w8((v and 0xff) + (1 shl 7), ob)

    fun w160(v: Int, ob: Int) = w16((v and 0xffff) + (1 shl 15), ob)

    fun w212(v: Int, ob: Int) {
        val c = count++
        if (c == 0) {
            data = v and 0xfff
        } else {
            count = 0
            data = data or ((v shl 4) and 0xf000)
            w16(data, ob)
            w8(v, ob)
        }
    }

    fun f212(ob: Int) {
        if (count == 1) {
            w16(data, ob)
            nrewind = 2
        }
    }

    fun w310(v: Int, ob: Int) {
        when (count++) {
            0 -> data = (v shl 1) and 0x7fe
            1 -> datb = (v shl 1) and 0x7fe
            else -> {
                count = 0
                data = data or (v shl 11)
                w16(data, ob)
                datb = datb or ((v shl 6) and 0x7fe.inv())
                w16(datb, ob)
            }
        }
    }

    fun f310(ob: Int) {
        when (count) {
            0 -> {}
            1 -> {
                w16(data, ob)
                nrewind = 2
            }
            else -> {
                w16(data, ob)
                w16(datb, ob)
                nrewind = 4
            }
        }
    }

    fun w311(v: Int, ob: Int) {
        when (count++) {
            0 -> data = v and 0x3ff
            1 -> {
                data = data or (v shl 10)
                w16(data, ob)
                datb = (v shr 6) and 0xf
            }
            else -> {
                count = 0
                datb = datb or (v shl 4)
                datb = datb and 0x3fff
                w16(datb, ob)
            }
        }
    }

    fun f311(ob: Int) {
        when (count) {
            0 -> {}
            1 -> {
                w16(data, ob)
                nrewind = 2
            }
            else -> {
                w16(datb, ob)
                nrewind = 2
            }
        }
    }

    /** Write a sample to a FLAC signal group, wrapped (as C does) to the 8, 16 or 24 bits of the format. */
    fun flacPutsamp(v0: Int, fmt: Int): Int {
        val v = when (fmt) {
            508 -> v0.toByte().toInt()
            516 -> v0.toShort().toInt()
            524 -> (v0 shl 8) shr 8
            else -> v0
        }
        val fo = flac ?: return -1
        fo.pending.clear()
        fo.enc.put(v, fo.pending)
        if (!fo.pending.isEmpty()) fp?.write(fo.pending.bytes, 0, fo.pending.size)
        return 0
    }

    fun flacOsopen(): Int {
        val fo = flac ?: return 0
        val hdr = fo.enc.header()
        fo.headerPos = fp?.tell() ?: 0
        fp?.write(hdr)
        return 0
    }

    fun flacOsclose() {
        val fo = flac
        if (fo != null) {
            flac = null
            fo.pending.clear()
            fo.enc.finish(fo.pending)
            val f = fp
            if (f != null) {
                if (!fo.pending.isEmpty()) f.write(fo.pending.bytes, 0, fo.pending.size)
                if (f.seek(fo.headerPos + FLAC_STREAMINFO_POS, SEEK_SET) == 0) {
                    f.write(fo.enc.streaminfo())
                    f.seek(0, SEEK_END)
                }
            }
        }
        bp = 0
        be = 0
    }
}

/** Signal mapping of a variable-layout record (one output sample). */
internal class SigMapInfo {
    var desc = ByteArray(0)
    var gain = 0.0
    var scale = 0.0
    var offset = 0.0
    var sampleOffset = 0
    var baseline = 0
    var index = 0
    var spf = 0

    fun copy(): SigMapInfo {
        val r = SigMapInfo()
        r.desc = desc; r.gain = gain; r.scale = scale; r.offset = offset
        r.sampleOffset = sampleOffset; r.baseline = baseline; r.index = index; r.spf = spf
        return r
    }
}

/** Where putinfo writes. */
private const val OUTINFO_NONE = 0
private const val OUTINFO_HEADER = 1
private const val OUTINFO_FILE = 2

/**
 * The state of signal.c (part of [Wfdb]): the open record, input and
 * output signals, header data, time base, info strings, ...
 */
internal class SigState {
    // Set by readheader
    val hsd = ArrayList<HsData>()
    var hheader: WfdbFile? = null

    /** Frame frequency (Hz). */
    var ffreq = 0.0

    /** getvec sampling frequency (setifreq; 0: not set). */
    var ifreq = 0.0

    /** Sampling frequency (Hz). */
    var sfreq = 0.0

    /** Counter frequency (Hz). */
    var cfreq = 0.0

    /** Maximum samples per signal per frame. */
    var spfmax = 0
    var btime = 0L
    var bdate = 0L
    var nsamples = 0L
    var bcount = 0.0
    var prologBytes = 0L

    // WFDB-x: files named in a header (see openHeader)
    /** Directory of the header read last by readheader (null if unknown: the standard input). */
    var hdrDir: ByteArray? = null

    /** Directory and name of the header of the current multi-segment record (msrecName null if there is none). */
    var msrecDir: ByteArray? = null
    var msrecName: ByteArray? = null

    /** True while setmsheader reads the headers of the segments it was given. */
    var userSegments = false

    /** WFDB-x: true during a high-level read: getvec's checksum message is recorded but not printed. */
    var cksumQuiet = false

    /** WFDB-x: true if getvecs must not use its bulk path (see wfdbx_bulk_read; for tests). */
    var bulkOff = false

    /** WFDB-x: the number of vectors read by the bulk path (for tests). */
    var bulkVectors = 0L

    /** WFDB-x: storage of the bulk path: the frames as read, the frames as getframe gives them, and a tile of decoded samples. */
    var bulkIn = IntArray(0)
    var bulkFr = IntArray(0)
    var bulkRaw = IntArray(0)

    // Multi-segment records
    var segments = 0
    var inMsrec = 0
    var msbtime = 0L
    var msbdate = 0L
    var msnsamples = 0L
    val segarray = ArrayList<Seginfo>()
    var haveSegarray = false
    var segp = -1
    var segend = -1

    // Open input signals
    val isd = ArrayList<IsData>()
    val igd = ArrayList<IgData>()
    var nisig = 0
    var nigroup = 0
    var ispfmax = 0
    var tvector = IntArray(0)
    var uvector = IntArray(0)
    var vvector = IntArray(0)
    var tuvlen = 0
    var istime = 0L
    var ibsize = 0
    var skewmax = 0
    var dsbuf = IntArray(0)
    var haveDsbuf = false
    var dsbi = 0
    var dsblen = 0
    var framelen = 0

    /**
     * WFDB-x: is there a signal group whose frames hold no samples (an EDF
     * file can give 0 samples per data record)? It is at the end of its
     * data at once.
     */
    var emptyGroup = false

    /** getvec mode. */
    var gvmode = DEFWFDBGVMODE
    var gvc = 0
    var isedf = 0
    var sbuf = IntArray(0)
    var haveSbuf = false
    var sampleVflag = 0

    // Output signals
    val osd = ArrayList<OsData>()
    val ogd = ArrayList<OgData>()
    var nosig = 0
    var nogroup = 0
    var oheader: WfdbFile? = null
    var outinfoFile: WfdbFile? = null
    var outinfo = OUTINFO_NONE
    var ostime = 0L
    var obsize = 0

    // Info strings
    val pinfo = ArrayList<ByteArray>()
    var havePinfo = false
    var ninfo = 0
    var infoI = 0

    // Variable-layout multi-segment records
    var needSigmap = 0
    var nvsig = 0
    var tspf = 0
    var vspfmax = 0
    val vsd = ArrayList<IsData>()
    var ovec = IntArray(0)
    var smi: Array<SigMapInfo> = emptyArray()

    // getvec resampling (setifreq)
    var mticks = 0L
    var nticks = 0L
    var mnticks = 0L
    var rgvstat = 0
    var rgvtime = 0L
    var gvtime = 0L
    var gv0 = IntArray(0)
    var gv1 = IntArray(0)
    var rgetvecStat = 0

    // Time and date strings
    var dateString = ByteArray(0)
    var pdays = -1L

    // sample()
    var sampleTt = 0L
}

// ---------------------------------------------------------------------------
// Helpers

private fun isfmt(f: Int): Boolean = WFDB_FMT_LIST.contains(f)

private fun isflacfmt(f: Int): Boolean = f in FLAC_FMT_BASE..FLAC_FMT_MAX

/** Unsigned comparison a < b (C's unsigned signal numbers). */
private fun uless(a: Int, b: Int): Boolean = (a xor Int.MIN_VALUE) < (b xor Int.MIN_VALUE)

/** The C string of an optional string (empty if NULL). */
private fun ostr(s: ByteArray?): ByteArray = if (s == null) ByteArray(0) else cstr(s)

/** `strtol(s + pos, NULL, 10)`. */
private fun strtol10(s: ByteArray, pos: Int = 0): Long = strtol(s, 10, pos).value

/** `strtod(s + pos, NULL)`. */
private fun strtod0(s: ByteArray, pos: Int = 0): Double = strtod(s, pos).value

/** `strchr(s + from, c)` on a C string: the index (in s) of c, or -1. */
internal fun strchrAt(s: ByteArray, c: Char, from: Int = 0): Int {
    var i = from
    while (i < s.size) {
        val b = s[i].toInt() and 0xff
        if (b == 0) return -1
        if (b == c.code) return i
        i++
    }
    return -1
}

/** The first n bytes of the C string starting at from (strnlen). */
private fun strn(s: ByteArray, from: Int, n: Int): ByteArray {
    var e = from
    while (e < s.size && s[e] != 0.toByte() && e - from < n) e++
    return s.copyOfRange(from, e)
}

/**
 * strtok(s, delim) applied in place: the first token (null if there is
 * none), and the string as strtok leaves it (truncated after the token; s
 * itself if there is no token).
 */
private fun strtokInplace(s: ByteArray, delim: String): Pair<ByteArray?, ByteArray> {
    val c = cstr(s)
    val tk = Strtok(c)
    val t = tk.next(delim) ?: return Pair(null, s)
    return Pair(t, c.copyOf(tk.end))
}

/** meansamp: the mean of n sample values, rounded to the nearest integer (halfway cases rounded up). */
internal fun meansamp(s: IntArray, off: Int, n: Int): Int {
    var sum = (n / 2).toLong()
    for (i in 0 until maxOf(n, 0)) {
        val x = s[off + i]
        if (x == WFDB_INVALID_SAMPLE) return WFDB_INVALID_SAMPLE
        sum += x
    }
    val neg = if (sum < 0) 1L else 0L
    if (n and (n - 1) != 0) return ((sum + neg) / n - neg).toInt()
    // (each halving below is a floor division by 2: an arithmetic shift)
    if (n > 0) return (sum shr n.countTrailingZeroBits()).toInt()
    var m = n
    while (true) {
        m /= 2
        if (m == 0) break
        sum = (sum - (if (sum < 0) 1 else 0)) / 2
    }
    return sum.toInt()
}

/**
 * The lowest value (the code written for, and read back as, an invalid
 * sample, for formats other than 0 and 8) of a storage format.
 */
private fun fmtMin(fmt: Int): Int = when (fmt) {
    508, 80 -> -0x80
    310, 311 -> -0x200
    212 -> -0x800
    16, 61, 516, 160 -> -0x8000
    524, 24 -> -0x800000
    else -> WFDB_SAMPLE_MIN
}

/** The highest value of a storage format. */
private fun fmtMax(fmt: Int): Int = when (fmt) {
    508, 80 -> 0x7f
    310, 311 -> 0x1ff
    212 -> 0x7ff
    16, 61, 516, 160 -> 0x7fff
    524, 24 -> 0x7fffff
    else -> WFDB_SAMPLE_MAX
}

/** The (bytes, samples) per packed unit of a format handled by the bulk path, or null. */
private fun bulkUnit(fmt: Int): IntArray? = when (fmt) {
    8, 80 -> intArrayOf(1, 1)
    16, 61, 160 -> intArrayOf(2, 1)
    24 -> intArrayOf(3, 1)
    32 -> intArrayOf(4, 1)
    212 -> intArrayOf(3, 2)
    310, 311 -> intArrayOf(4, 3)
    else -> null
}

private fun sext(v: Int, bits: Int): Int = (v shl (32 - bits)) shr (32 - bits)

/**
 * Decodes cnt raw samples (as the rFMT functions return them; for format 8,
 * the first differences) in format fmt from b[from...] into dst[off...].
 */
private fun bulkDecodeFlat(fmt: Int, b: ByteArray, from: Int, cnt: Int, dst: IntArray, off: Int) {
    var p = from
    var o = off
    val end = off + cnt
    fun u(i: Int) = b[i].toInt() and 0xff
    when (fmt) {
        8 -> while (o < end) dst[o++] = b[p++].toInt()
        80 -> while (o < end) dst[o++] = u(p++) - (1 shl 7)
        16 -> while (o < end) {
            dst[o++] = (u(p) or (b[p + 1].toInt() shl 8)).toShort().toInt()
            p += 2
        }
        61 -> while (o < end) {
            dst[o++] = (u(p + 1) or (b[p].toInt() shl 8)).toShort().toInt()
            p += 2
        }
        160 -> while (o < end) {
            dst[o++] = (u(p) or (u(p + 1) shl 8)) - (1 shl 15)
            p += 2
        }
        24 -> while (o < end) {
            dst[o++] = u(p) or (u(p + 1) shl 8) or (b[p + 2].toInt() shl 16)
            p += 3
        }
        32 -> while (o < end) {
            dst[o++] = u(p) or (u(p + 1) shl 8) or (u(p + 2) shl 16) or (b[p + 3].toInt() shl 24)
            p += 4
        }
        212 -> while (o < end) {
            val b0 = u(p)
            val b1 = u(p + 1)
            val b2 = u(p + 2)
            p += 3
            dst[o++] = sext(b0 or ((b1 and 0x0f) shl 8), 12)
            if (o < end) dst[o++] = sext(b2 or ((b1 and 0xf0) shl 4), 12)
        }
        310 -> while (o < end) {
            val w0 = u(p) or (u(p + 1) shl 8)
            val w1 = u(p + 2) or (u(p + 3) shl 8)
            p += 4
            dst[o++] = sext((w0 shr 1) and 0x3ff, 10)
            if (o < end) dst[o++] = sext((w1 shr 1) and 0x3ff, 10)
            if (o < end) dst[o++] = sext(((w0 and 0xf800) shr 11) or ((w1 and 0xf800) shr 6), 10)
        }
        311 -> while (o < end) {
            val w0 = u(p) or (u(p + 1) shl 8)
            val w1 = u(p + 2) or (u(p + 3) shl 8)
            val c2 = u(p + 2)
            p += 4
            dst[o++] = sext(w0 and 0x3ff, 10)
            if (o < end) dst[o++] = sext(((w0 and 0xfc00) shr 10) or ((c2 and 0xf) shl 6), 10)
            if (o < end) dst[o++] = sext((w1 shr 4) and 0x3ff, 10)
        }
    }
}

private fun gcd(a: Int, b: Int): Int = if (b == 0) a else gcd(b, a % b)

/**
 * A group of input signals read by the bulk path (see bulkFrames): its
 * first signal and the signal after its last one, the format of its
 * signals (0: null signals, without a file), the number of its samples in
 * a frame, and the position of its first sample in a frame.
 */
private class BulkGroup(val s0: Int, val s1: Int, val fmt: Int, val gfl: Int, val pos: Int)

/** (year, month, day) of a Julian date, as datstr gives them (the calendar code of C's datstr). */
internal fun julianToYmd(date0: Long): IntArray {
    var date = date0
    if (date >= IGREG_JDN) {
        // Gregorian calendar correction
        val gcorr = d2i(((date - 1867216).toDouble() - 0.25) / 36524.25)
        date += 1 + gcorr.toLong() - d2l(0.25 * gcorr)
    }
    date += 1524
    val jy = d2i(6680.0 + ((date - 2439870).toDouble() - 122.1) / 365.25)
    val jd = d2l((365L * jy).toDouble() + 0.25 * jy)
    val jm = d2i((date - jd).toDouble() / 30.6001)
    val d = (date - jd - d2i(30.6001 * jm).toLong()).toInt()
    var m = jm - 1
    if (m > 12) m -= 12
    var y = jy - 4715
    if (m > 2) y -= 1
    if (y <= 0) y -= 1
    return intArrayOf(y, m, d)
}

/** The Julian day number of 15 October 1582 (the first day of the Gregorian calendar), and the same date as d + 31 * (m + 12 * y). */
internal const val IGREG_JDN = 2299161L
internal const val IGREG_DMY = 15L + 31L * (10L + 12L * 1582L)

/** EDF header reader: C reads every field into one buffer, so that stale bytes may follow a field. */
private class EdfBuf {
    val b = ByteArray(EDF_MAXFIELD + 1)

    /** Read a fixed-size field and remove trailing spaces. */
    fun readStr(size: Int, f: WfdbFile) {
        if (f.read(b, 0, size) != size) {
            b[0] = 0
        } else {
            var n = size
            while (n > 0 && b[n - 1] == ' '.code.toByte()) n--
            b[n] = 0
        }
    }

    fun s(): ByteArray = cstr(b)
}

// ---------------------------------------------------------------------------
// Internal functions

private fun Wfdb.closeHheader() {
    sig.hheader?.close()
    sig.hheader = null
}

private fun Wfdb.sigmapCleanup() {
    val st = sig
    st.needSigmap = 0
    st.nvsig = 0
    st.tspf = 0
    st.vspfmax = 0
    st.ovec = IntArray(0)
    st.smi = emptyArray()
    st.vsd.clear()
}

private fun Wfdb.makeVsd(): Int {
    val st = sig
    if (st.nvsig != st.nisig) {
        wfdb_error(cformat("make_vsd: oops! nvsig = %d, nisig = %d\n", st.nvsig, st.nisig))
        return -1
    }
    val n = st.nvsig
    while (st.vsd.size < n) st.vsd.add(IsData())
    for (i in 0 until n) {
        st.vsd[i].info = st.isd[i].info.copy()
        st.vsd[i].skew = st.isd[i].skew
    }
    return st.nvsig
}

private fun Wfdb.segname(): ByteArray {
    val st = sig
    return if (st.haveSegarray && st.segp >= 0 && st.segp < st.segarray.size) st.segarray[st.segp].recname else ByteArray(0)
}

private fun Wfdb.sigmapInit(firstSegment: Boolean): Int {
    val st = sig
    if (st.inMsrec != 0 && firstSegment && st.haveSegarray && st.segarray.isNotEmpty() && st.segarray[0].nsamp == 0L) {
        // This is the layout segment: set up the output side of the map.
        st.needSigmap = 1
        st.nvsig = st.nisig
        st.vspfmax = st.ispfmax
        st.tspf = 0
        for (s in 0 until st.nisig) st.tspf += st.isd[s].info.spf
        st.smi = Array(maxOf(st.tspf, 0)) { SigMapInfo() }
        var s = 0
        for (i in 0 until st.nisig) {
            val m = st.smi[s]
            m.desc = ostr(st.isd[i].info.desc)
            m.gain = st.isd[i].info.gain
            m.baseline = st.isd[i].info.baseline
            val k = st.isd[i].info.spf
            m.spf = k
            for (j in 1 until maxOf(k, 0)) st.smi[s + j] = st.smi[s].copy()
            s += maxOf(k, 0)
        }
        st.ovec = IntArray(maxOf(st.tspf, 0))
        return makeVsd()
    } else if (st.needSigmap != 0) {
        // Set up the input side of the map.
        for (m in st.smi) {
            m.index = 0
            m.scale = 0.0
            m.offset = 0.0
            m.sampleOffset = WFDB_INVALID_SAMPLE
        }
        st.ispfmax = st.vspfmax
        if (st.isd[0].info.fmt == 0 && st.nisig == 1) return 0 // the current segment is a null record
        val errs = ArrayList<ByteArray>()
        val segName = segname()
        val tspf = st.tspf
        var j = 0
        for (i in 0 until st.nisig) {
            val ii = st.isd[i].info
            val idesc = ostr(ii.desc)
            var s = 0
            while (s < tspf) {
                if (st.smi[s].desc.contentEquals(idesc)) {
                    var kmax = st.smi[s].spf
                    if (kmax != ii.spf) {
                        errs.add(cformat("sigmap_init: unexpected spf for signal %d in segment %s\n", i, segName))
                        if (kmax > ii.spf) kmax = ii.spf
                    }
                    for (k in 0 until kmax) {
                        val ps = st.smi[s + k]
                        ps.index = j + k
                        ps.scale = ps.gain / ii.gain
                        if (ps.scale < 1.0) {
                            errs.add(cformat("sigmap_init: loss of precision in signal %d in segment %s\n", i, segName))
                        }
                        ps.offset = ps.baseline - ps.scale * ii.baseline + 0.5
                        // If it is possible to add an additional offset such
                        // that all possible output values will fit into a
                        // positive signed integer, the "fast" case can be
                        // used in sigmap.
                        val ivmin = fmtMin(ii.fmt)
                        val ivmax = fmtMax(ii.fmt)
                        val ovmin = ivmin * ps.scale + ps.offset
                        val ovmax = ivmax * ps.scale + ps.offset
                        if (ovmin < ovmax && ovmin >= WFDB_SAMPLE_MIN + 1.0 && ovmax <= WFDB_SAMPLE_MAX.toDouble() &&
                            ovmax - ovmin + 1.0 < WFDB_SAMPLE_MAX.toDouble()
                        ) {
                            ps.sampleOffset = d2i(ovmin - 1.0)
                            ps.offset -= ps.sampleOffset
                        } else {
                            ps.sampleOffset = 0
                        }
                    }
                    break
                }
                s += st.smi[s].spf
            }
            j += ii.spf
        }
        val tooLarge = j > tspf
        for (e in errs) wfdb_error(e)
        if (tooLarge) {
            wfdb_error(cformat("sigmap_init: frame size too large in segment %s\n", segName))
            return -1
        }
    } else if (st.inMsrec != 0 && !firstSegment && st.framelen == 0) {
        // Opening a new segment of a fixed-layout multisegment record.
        st.ispfmax = st.vspfmax
        if (st.nisig > st.nvsig) {
            wfdb_error(cformat("sigmap_init: wrong number of signals in segment %s\n", segname()))
            return -1
        }
        for (i in 0 until st.nisig) {
            if (st.isd[i].info.spf != st.vsd[i].info.spf) {
                wfdb_error(cformat("sigmap_init: wrong spf for signal %d in segment %s\n", i, segname()))
                return -1
            }
        }
    } else {
        // Normal record, or multisegment record without a layout.
        st.nvsig = st.nisig
        st.vspfmax = st.ispfmax
        st.tspf = 0
        for (s in 0 until st.nisig) st.tspf += st.isd[s].info.spf
        return makeVsd()
    }
    return 0
}

// ---------------------------------------------------------------------------
// Header files

private fun Wfdb.hsdAt(s: Int): HsData {
    while (sig.hsd.size <= s) sig.hsd.add(HsData())
    return sig.hsd[s]
}

/** Get header information from an EDF file. */
private fun Wfdb.edfparse(): Int {
    val buf = EdfBuf()
    val format: Int
    val fnamebuf = wfdb_filename().copyOf()
    val ifile = sig.hheader ?: return -1

    // Read the first 8 bytes and check for the magic string.
    ifile.read(buf.b, 0, 8)
    if (buf.b.copyOf(8).contentEquals("0       ".latin1())) {
        format = 16 // EDF or EDF+
    } else if (buf.b.copyOfRange(1, 8).contentEquals("BIOSEMI".latin1())) {
        format = 24 // BDF
    } else {
        wfdb_error(cformat("init: '%s' is not EDF or EDF+\n", fnamebuf))
        return -2
    }

    val day = CInt()
    val month = CInt()
    val year = CInt()
    val hour = CInt()
    val minute = CInt()
    val second = CInt()
    val offset = CInt()
    val nframes = CLong()
    val nsigv = CInt()

    // Read the remainder of the fixed-size section of the header.
    buf.readStr(80, ifile) // patient ID (ignored)
    buf.readStr(80, ifile) // recording ID (ignored)
    buf.readStr(8, ifile) // recording date
    sscanf(buf.s(), "%d%*c%d%*c%d", day, month, year)
    // EDF has only two-digit years: 85-99 are 1985-1999 (EDF dates from
    // 1985), 00-84 are 2000-2084.
    var yr = year.v + 1900
    if (yr < 1985) yr += 100
    buf.readStr(8, ifile) // recording time
    sscanf(buf.s(), "%d%*c%d%*c%d", hour, minute, second)
    buf.readStr(8, ifile) // number of bytes in header
    sscanf(buf.s(), "%d", offset)
    buf.readStr(44, ifile) // free space (ignored)
    buf.readStr(8, ifile) // number of frames (EDF blocks)
    sscanf(buf.s(), "%ld", nframes)
    if (nframes.v < 0) nframes.v = 0
    sig.nsamples = nframes.v
    val sprv = CDouble(0.0)
    buf.readStr(8, ifile) // data record duration (seconds)
    sscanf(buf.s(), "%lf", sprv)
    var spr = sprv.v
    if (spr <= 0.0) spr = 1.0
    ifile.read(buf.b, 4, 4) // number of signals
    sscanf(cstr(buf.b.copyOfRange(4, buf.b.size)), "%d", nsigv)
    val nsig = nsigv.v

    if (nsig < 1 || (nsig.toLong() + 1) * EDF_HDRBLOCK != offset.v.toLong()) {
        wfdb_error(cformat("init: '%s' is not EDF or EDF+\n", fnamebuf))
        return -2
    }
    val ns = nsig

    // Allocate workspace.
    hsdAt(ns - 1)
    val dmax = LongArray(ns)
    val dmin = LongArray(ns)
    val pmax = DoubleArray(ns)
    val pmin = DoubleArray(ns)

    // Strip off any path info from the EDF file name (C starts the search
    // for '/' 5 bytes before the end of the name).
    val fname = cstr(fnamebuf)
    var edfFname = fname
    var p = fname.size - 5
    while (p > 0) {
        if (fname[p] == '/'.code.toByte()) {
            edfFname = fname.copyOfRange(p + 1, fname.size)
            break
        }
        p--
    }

    // Read the variable-size section of the header.
    var spfmax = sig.spfmax
    val hsd = sig.hsd
    for (s in 0 until ns) {
        val h = hsd[s]
        h.start = offset.v.toLong()
        h.skew = 0
        h.info.fname = edfFname
        h.info.group = 0
        h.info.bsize = 0
        h.info.cksum = 0
        h.info.fmt = format
        h.info.nsamp = nframes.v
        buf.readStr(16, ifile) // signal type
        h.info.desc = buf.s()
    }
    for (s in 0 until ns) buf.readStr(80, ifile) // transducer type (ignored)
    for (s in 0 until ns) {
        buf.readStr(8, ifile) // signal units
        hsd[s].info.units = buf.s()
    }
    for (s in 0 until ns) {
        buf.readStr(8, ifile) // physical minimum
        val v = CDouble(0.0)
        sscanf(buf.s(), "%lf", v)
        pmin[s] = v.v
    }
    for (s in 0 until ns) {
        buf.readStr(8, ifile) // physical maximum
        val v = CDouble(0.0)
        sscanf(buf.s(), "%lf", v)
        pmax[s] = v.v
    }
    for (s in 0 until ns) {
        buf.readStr(8, ifile) // digital minimum
        val v = CLong(0)
        sscanf(buf.s(), "%ld", v)
        dmin[s] = v.v
    }
    for (s in 0 until ns) {
        buf.readStr(8, ifile) // digital maximum
        val v = CLong(0)
        sscanf(buf.s(), "%ld", v)
        dmax[s] = v.v
        val h = hsd[s]
        val z = ((dmax[s] + 1 + dmin[s]) / 2).toInt()
        h.info.initval = z
        h.info.adczero = z
        var adcrange = dmax[s] - dmin[s]
        var i = 0
        while (adcrange > 0) {
            adcrange /= 2
            i++
        }
        h.info.adcres = i
        if (pmax[s] != pmin[s]) {
            h.info.gain = (dmax[s] - dmin[s]).toDouble() / (pmax[s] - pmin[s])
            val baseline = dmax[s] - pmax[s] * h.info.gain
            h.info.baseline = if (baseline >= 0.0) d2i(baseline + 0.5) else d2i(baseline - 0.5)
        } else {
            // gain is undefined
            h.info.gain = 0.0
            h.info.baseline = 0
        }
    }
    for (s in 0 until ns) buf.readStr(80, ifile) // filtering information (ignored)
    for (s in 0 until ns) {
        val n = CInt(0)
        buf.readStr(8, ifile) // samples per frame (EDF block)
        sscanf(buf.s(), "%d", n)
        hsd[s].info.spf = n.v
        if (n.v > spfmax) spfmax = n.v
    }
    sig.spfmax = spfmax

    // Close the file (don't bother reading nsig*32 bytes of free space);
    // getinfo must not try to read the EDF file.
    closeHheader()

    val st = sig
    st.ffreq = 1.0 / spr // frame frequency = 1/(seconds per EDF block)
    st.cfreq = st.ffreq // set sampling and counter frequencies to match
    st.sfreq = st.ffreq * st.spfmax
    if (getafreq() == 0.0) setafreq(st.sfreq)
    st.gvmode = st.gvmode or WFDB_HIGHRES
    var tb = cformat("%02d:%02d:%02d %02d/%02d/%04d", hour.v, minute.v, second.v, day.v, month.v, yr)
    if (tb.size > EDF_MAXFIELD) tb = tb.copyOf(EDF_MAXFIELD) // C formats it into an 81-byte buffer
    setbasetime(tb)

    sig.isedf = 1
    return nsig
}

/**
 * WFDB-x: opens the header (of type s: "hea", or null for a file name) of
 * a record, or of a segment named in the header of the current
 * multi-segment record (in the directory of that header), and notes its
 * directory (hdrDir). Legacy mode: wfdb_open (the WFDB path).
 */
private fun Wfdb.openHeader(s: ByteArray?, record: ByteArray): WfdbFile? {
    if (legacy) return wfdb_open(s, record, WFDB_READ)
    val st = sig
    if (st.inMsrec == 0) {
        st.msrecDir = null
        st.msrecName = null
    }
    val name = st.msrecName
    val f = if (name != null && st.inMsrec != 0 && !st.userSegments) {
        wfdbx_open_in(st.msrecDir, s, record, name)
    } else {
        wfdb_open(s, record, WFDB_READ)
    }
    st.hdrDir = if (f != null && !f.isStd()) wfdbx_dirname(wfdb_filename()) else null
    return f
}

/**
 * Read the header of record (or the EDF file it names). Returns the number
 * of signals, -1 if the header cannot be opened, or -2 if it is invalid.
 */
private fun Wfdb.readheader(record0: ByteArray): Int {
    val record = cstr(record0)

    // If another input header file was opened, close it.
    closeHheader()

    val st = sig
    st.spfmax = 1
    st.sfreq = st.ffreq
    st.isedf = 0
    if (beq(record, "~")) {
        if (st.inMsrec != 0 && st.vsd.isNotEmpty()) {
            st.hsd.clear()
            val h = HsData()
            st.hsd.add(h)
            h.info.desc = "~".latin1()
            h.info.spf = 1
            h.info.fmt = 0
            st.nsamples = st.segarray[st.segp].nsamp
            h.info.nsamp = st.nsamples
            return 1
        }
        return 0
    }

    // If the final component of the record name includes a '.', assume it
    // is a file name.
    var qq = maxOf(record.size - 1, 0)
    while (qq > 0) {
        val c = record.at(qq)
        if (c == '.'.code || c == '/'.code || c == ':'.code || c == '\\'.code) break
        qq--
    }
    if (record.isNotEmpty() && record[qq] == '.'.code.toByte()) {
        val f = openHeader(null, record)
        if (f == null) {
            wfdb_error(cformat("init: can't open %s\n", record))
            return -1
        }
        st.hheader = f
        if (!beq(record.copyOfRange(qq + 1, record.size), "hea")) {
            // assume EDF if not '.hea'
            return edfparse()
        }
    } else {
        // Otherwise, assume the file name is record.hea.
        val f = openHeader("hea".latin1(), record)
        if (f == null) {
            wfdb_error(cformat("init: can't open header for record %s\n", record))
            return -1
        }
        st.hheader = f
    }
    return readheaderBody(record)
}

/** The next line of the input header (0 bytes at the end of the file). */
private fun Wfdb.hgetline(line: ByteVec): Int = sig.hheader?.getline(line) ?: 0

private fun Wfdb.readheaderBody(record: ByteArray): Int {
    val line = ByteVec(256)
    // Read the first line and check for a magic string.
    if (hgetline(line) == 0) {
        wfdb_error(cformat("init: record %s header is empty\n", record))
        return -2
    }
    val magic = "#wfdb" // followed by the version required
    var lb = line.toByteArray()
    if (lb.startsWith(magic)) {
        val major = CInt()
        val minor = CInt()
        val release = CInt()
        val n = sscanf(cstr(lb.copyOfRange(magic.length, lb.size)), "%d.%d.%d", major, minor, release)
        if ((n > 0 && major.v > WFDB_MAJOR) || (n > 1 && major.v == WFDB_MAJOR && minor.v > WFDB_MINOR) ||
            (n > 2 && major.v == WFDB_MAJOR && minor.v == WFDB_MINOR && release.v > WFDB_RELEASE)
        ) {
            wfdb_error(
                cformat(
                    "init: reading record %s requires WFDB library version %d.%d.%d or later\n" +
                        "  (the most recent version is always available from http://physionet.org)\n",
                    record, major.v, minor.v, release.v,
                ),
            )
            return -1
        }
    }

    // Get the first token (the record name) from the first non-empty,
    // non-comment line.
    var tk: Strtok
    var p: ByteArray
    while (true) {
        tk = Strtok(lb)
        val t = tk.next(SEP)
        if (t != null && t[0] != '#'.code.toByte()) {
            p = t
            break
        }
        if (hgetline(line) == 0) {
            wfdb_error(cformat("init: can't find record name in record %s header\n", record))
            return -2
        }
        lb = line.toByteArray()
    }

    val q = strchrAt(p, '/', 1)
    if (q >= 0) {
        if (sig.inMsrec != 0) {
            wfdb_error(cformat("init: record %s cannot be nested in another multi-segment record\n", record))
            return -2
        }
        sig.segments = strtol10(p, q + 1).toInt()
        p = p.copyOf(q)
    }

    // For local files, be sure that the name (p) within the header file
    // matches the name (record) provided as an argument to this function.
    // (WFDB-x: a remote header, a fetched URL, is not checked, as the C
    // library did not check remote files.)
    val hh = sig.hheader
    val isStd = hh != null && (hh.isStd() || hh.isRemote())
    val plen = p.size
    if (!isStd && !(record.size >= plen && record.copyOf(plen).contentEquals(p))) {
        // If there is a mismatch, check to see if the record argument
        // includes a directory separator; if so, compare only the final
        // portion of the argument against the name in the header file.
        val q2 = record.size - 1
        var s2 = q2
        while (s2 > 0) {
            val c = record.at(s2)
            if (c == '/'.code || c == '\\'.code || c == ':'.code) break
            s2--
        }
        if (q2 > s2 && !p.contentEquals(record.copyOfRange(s2 + 1, record.size))) {
            wfdb_error(cformat("init: record name in record %s header is incorrect\n", record))
            return -2
        }
    }

    // Identify which type of header file is being read by trying to get
    // another token from the line which contains the record name.
    val p2 = tk.next(SEP)
    if (p2 == null) {
        wfdb_error(cformat("init: obsolete format in record %s header\n", record))
        return -2
    }

    // The second token specifies the number of signals (an unsigned int in
    // C: -1 is 4294967295; WFDB-x: the signal lines run out first).
    val nsig = strtol10(p2) and 0xffffffffL

    // Determine the frame rate, if present and not set already.
    val p3 = tk.next(SEP)
    if (p3 != null) {
        val f = strtod0(p3)
        if (f <= 0.0) {
            wfdb_error(cformat("init: sampling frequency in record %s header is incorrect\n", record))
            return -2
        }
        if (sig.ffreq > 0.0 && f != sig.ffreq) {
            wfdb_error("warning (init):\n")
            wfdb_error(cformat(" record %s sampling frequency differs", record))
            wfdb_error(" from that of previously opened record\n")
        } else {
            sig.ffreq = f
        }
    } else if (legacy && sig.ffreq == 0.0) {
        sig.ffreq = WFDB_DEFFREQ
    }
    // WFDB-x: if the header does not specify the sampling frequency (and the
    // caller has not set one with setsampfreq), it remains unspecified (0);
    // the C library assumed WFDB_DEFFREQ (250 Hz), as legacy mode does.

    val st = sig
    // Set the sampling rate to the frame rate for now.
    st.sfreq = st.ffreq

    // Determine the counter frequency and the base counter value.
    st.cfreq = 0.0
    st.bcount = 0.0
    if (p3 != null) {
        val k = strchrAt(p3, '/')
        if (k >= 0) {
            st.cfreq = strtod0(p3, k + 1)
            val m = strchrAt(p3, '(', k + 1)
            if (m >= 0) st.bcount = strtod0(p3, m + 1)
        }
    }
    if (st.cfreq <= 0.0) st.cfreq = st.ffreq

    // Determine the number of samples per signal, if present and not set
    // already.
    var ns: Long
    val p4 = tk.next(SEP)
    if (p4 != null) {
        ns = strtol(p4, 10).value
        if (ns < 0) {
            wfdb_error(cformat("init: number of samples in record %s header is incorrect\n", record))
            return -2
        }
        if (st.nsamples == 0L) {
            st.nsamples = ns
        } else if (ns > 0 && ns != st.nsamples && st.inMsrec == 0) {
            wfdb_error("warning (init):\n")
            wfdb_error(cformat(" record %s duration differs", record))
            wfdb_error(" from that of previously opened record\n")
            // nsamples must match the shortest record duration.
            if (st.nsamples > ns) st.nsamples = ns
        }
    } else {
        ns = 0
    }

    // Determine the base time and date, if present and not set already.
    val p5 = tk.next("\n\r")
    if (p5 != null) {
        if (st.btime == 0L && setbasetime(p5) < 0) return -2 // error message will come from setbasetime
    }

    // Special processing for master header of a multi-segment record.
    if (st.segments != 0 && st.inMsrec == 0) {
        // WFDB-x: the segments are in the directory of this header
        if (!legacy) {
            st.msrecDir = st.hdrDir
            st.msrecName = record.copyOf()
        }
        st.msbtime = st.btime
        st.msbdate = st.bdate
        st.msnsamples = st.nsamples
        // Read the names and lengths of the segment records.
        st.segarray.clear()
        st.haveSegarray = true
        ns = 0
        val nseg = st.segments
        for (i in 0 until maxOf(nseg, 0)) {
            // Get next segment spec, skip empty lines and comments.
            var name: ByteArray
            var lenp: ByteArray?
            while (true) {
                if (hgetline(line) == 0) {
                    return segfail(cformat("init: unexpected EOF in header file for record %s\n", record))
                }
                val t = Strtok(line.toByteArray())
                val x = t.next(SEP)
                if (x != null && x[0] != '#'.code.toByte()) {
                    name = x
                    lenp = t.next(SEP)
                    break
                }
            }
            if (name[0] == '+'.code.toByte()) {
                return segfail(cformat("init: `%s' is not a valid segment name in record %s\n", name, record))
            }
            if (name.size > WFDB_MAXRNL) {
                return segfail(cformat("init: `%s' is too long for a segment name in record %s\n", name, record))
            }
            val nsamp = if (lenp != null) strtol(lenp, 10).value else -1L
            if (lenp != null && nsamp >= 0) {
                st.segarray.add(Seginfo(name, nsamp, ns))
                ns += nsamp
            } else {
                return segfail(cformat("init: length must be specified for segment %s in record %s\n", name, record))
            }
        }
        st.segend = st.segarray.size - 1
        st.segp = 0
        if (st.msnsamples == 0L) {
            st.msnsamples = ns
        } else if (ns != st.msnsamples) {
            wfdb_error(cformat("warning (init): in record %s, stated record length (%lld)\n", record, st.msnsamples))
            wfdb_error(cformat(" does not match sum of segment lengths (%lld)\n", ns))
        }
        return 0
    }

    // Now get information for each signal.
    var s = 0
    while (s < nsig) {
        val hs = hsdAt(s)

        // Get the first token (the signal file name) from the next
        // non-empty, non-comment line.
        var stk: Strtok
        var fnameTok: ByteArray
        while (true) {
            if (hgetline(line) == 0) {
                wfdb_error(cformat("init: unexpected EOF in header file for record %s\n", record))
                return -2
            }
            stk = Strtok(line.toByteArray())
            val x = stk.next(SEP)
            if (x != null && x[0] != '#'.code.toByte()) {
                fnameTok = x
                break
            }
        }

        val hp = if (s > 0) st.hsd[s - 1] else null
        val hpGroup = hp?.info?.group ?: 0
        val hpFname = hp?.info?.fname
        val hpFmt = hp?.info?.fmt ?: 0
        val hpBsize = hp?.info?.bsize ?: 0

        // Determine the signal group number.
        if (s == 0 || !fnameTok.contentEquals(if (hpFname == null) "(null)".latin1() else cstr(hpFname))) {
            hs.info.group = if (s == 0) 0 else hpGroup + 1
            hs.info.fname = fnameTok
        } else {
            hs.info.group = hpGroup
            hs.info.fname = hpFname
        }

        // Determine the signal format.
        val pf = stk.next(SEP)
        var ok = false
        if (pf != null) {
            hs.info.fmt = strtol10(pf).toInt()
            ok = isfmt(hs.info.fmt)
        }
        if (!ok || pf == null) {
            wfdb_error(cformat("init: illegal format for signal %d, record %s\n", s, record))
            return -2
        }
        hs.info.spf = 1
        hs.skew = 0
        hs.start = 0
        // Parse the optional "xSPF", ":SKEW", and "+START" suffixes. (If the
        // token ends with one of the prefix characters, C reads past its
        // end; the suffix is ignored here.)
        var i = 0
        while (true) {
            i++
            if (pf.at(i) == 0) break
            if (pf.at(i) == 'x'.code) {
                i++
                if (pf.at(i) != 0) {
                    hs.info.spf = strtol10(pf, i).toInt()
                    if (hs.info.spf < 1) hs.info.spf = 1
                } else {
                    break
                }
            }
            if (pf.at(i) == ':'.code) {
                i++
                if (pf.at(i) != 0) {
                    hs.skew = strtol10(pf, i).toInt()
                    if (hs.skew < 0) hs.skew = 0
                } else {
                    break
                }
            }
            if (pf.at(i) == '+'.code) {
                i++
                if (pf.at(i) != 0) {
                    hs.start = strtol10(pf, i)
                    if (hs.start < 0) hs.start = 0
                } else {
                    break
                }
            }
        }
        if (hs.info.spf > st.spfmax) st.spfmax = hs.info.spf
        // The skew in samples (given in the header) is converted to skew in
        // frames here.
        hs.skew = d2i(hs.skew.toDouble() / hs.info.spf + 0.5)

        // Determine the gain in ADC units per physical unit.
        val pg = stk.next(SEP)
        hs.info.gain = if (pg != null) strtod0(pg) else 0.0

        // Determine the baseline if specified, and the physical units.
        var nobaseline = true
        var units: ByteArray? = null
        if (pg != null) {
            var k = 0
            while (k < pg.size && pg[k] != '('.code.toByte() && pg[k] != '/'.code.toByte()) k++
            if (k < pg.size && pg[k] == '('.code.toByte()) {
                k++
                hs.info.baseline = strtol10(pg, k).toInt()
                nobaseline = false
            }
            while (k < pg.size) {
                val c = pg[k]
                k++
                if (c == '/'.code.toByte() && k < pg.size) break
            }
            if (k < pg.size) units = strn(pg, k, WFDB_MAXUSL)
        }
        hs.info.units = units

        // Determine the ADC resolution in bits. WFDB-x: if this number is
        // missing, it is unspecified (0); the C library inferred it from the
        // format or assumed WFDB_DEFRES (12 bits), as legacy mode does.
        val pr = stk.next(SEP)
        hs.info.adcres = if (pr != null) {
            strtol10(pr).toInt()
        } else if (legacy) {
            when (hs.info.fmt) {
                80 -> 8
                160 -> 16
                212 -> 12
                310 -> 10
                311 -> 10
                else -> WFDB_DEFRES
            }
        } else {
            0
        }

        // Determine the ADC zero (assumed to be zero if missing).
        val pz = stk.next(SEP)
        hs.info.adczero = if (pz != null) strtol10(pz).toInt() else 0

        // Set the baseline to adczero if no baseline field was found.
        if (nobaseline) hs.info.baseline = hs.info.adczero

        // Determine the initial value.
        val pi = stk.next(SEP)
        hs.info.initval = if (pi != null) strtol10(pi).toInt() else hs.info.adczero

        // Determine the checksum (assumed to be zero if missing).
        val pc = stk.next(SEP)
        if (pc != null) {
            hs.info.cksum = strtol10(pc).toInt()
            hs.info.nsamp = ns
        } else {
            hs.info.cksum = 0
            hs.info.nsamp = 0
        }

        // Determine the block size (assumed to be zero if missing).
        val pb = stk.next(SEP)
        hs.info.bsize = if (pb != null) strtol10(pb).toInt() else 0

        // Check that formats and block sizes match for signals belonging to
        // the same group.
        if (s > 0 && hs.info.group == hpGroup && (hs.info.fmt != hpFmt || hs.info.bsize != hpBsize)) {
            wfdb_error(cformat("init: error in specification of signal %d or %d\n", s - 1, s))
            return -2
        }

        // Get the signal description.
        val pd = stk.next("\n\r")
        hs.info.desc = if (pd != null) strn(pd, 0, WFDB_MAXDSL) else cformat("record %s, signal %d", record, s)
        s++
    }
    setgvmode(sig.gvmode) // Reset sfreq if appropriate.
    return s
}

private fun Wfdb.segfail(msg: ByteArray): Int {
    wfdb_error(msg)
    val st = sig
    st.segarray.clear()
    st.haveSegarray = false
    st.segments = 0
    return -2
}

// ---------------------------------------------------------------------------
// FLAC input and output (glue to Flac.kt)

/**
 * flac_isclose: closes the decoder of a FLAC input (an error message if the
 * MD5 signature of its samples was checked and is wrong).
 */
private fun flacIsclose(ig: IgData): String? {
    val fi = ig.flac ?: return null
    val d = fi.dec
    // (a decoder that has read nothing has no STREAMINFO signature)
    val ok = if (d != null) d.finish() else !fi.md5Check
    return if (ok) null else "isigclose: warning: incorrect MD5 hash in FLAC input\n"
}

/**
 * The decoder of FLAC signal group g, made from its signal file when first
 * needed (C makes it when the group is opened; it reads nothing until then).
 */
private fun Wfdb.flacDecoder(g: Int) {
    val ig = sig.igd[g]
    val fi = ig.flac ?: return
    if (fi.dec == null) {
        val data = ig.fp?.readToEnd() ?: ByteArray(0)
        fi.dec = FlacStreamDecoder(data, ig.seek != 0, fi.md5Check)
    }
}

/** Reports the messages of the decoder of a FLAC input. */
private fun Wfdb.flacMessages(fi: FlacIn) {
    for (m in fi.pack.msgs) wfdb_error(m)
    fi.pack.msgs.clear()
}

/** flac_getsamp: the next sample of FLAC signal group g. */
private fun Wfdb.flacGetsamp(g: Int): Int {
    flacDecoder(g)
    val ig = sig.igd[g]
    val fi = ig.flac
    if (fi == null) {
        ig.stat = -2
        return 0
    }
    val p = fi.pack
    var stat = ig.stat
    var v = 0
    while (true) {
        if (p.bp != p.packptr) {
            // the next decoded sample
            v = p.buf[p.bp++]
            break
        }
        // Decode the next FLAC frame (or metadata block).
        val oldcount = p.packcount
        p.stat = stat
        val dec = fi.dec
        val ok = dec != null && dec.processSingle(p)
        stat = p.stat
        flacMessages(fi)
        if (!ok) {
            if (stat != -2) {
                wfdb_error("getvec: unexpected FLAC decoding error\n")
                stat = -2
            }
            break
        }
        if (stat <= 0) break
        if (p.bp == p.packptr && p.packcount == oldcount) {
            when (dec!!.state) {
                FlacState.END_OF_STREAM -> {
                    if (p.packcount != 0) {
                        wfdb_error(cformat("getvec: warning: %d samples left over at end of file\n", p.packcount))
                    }
                    p.packcount = 0
                    stat = 0
                    break
                }
                FlacState.SEARCH_FOR_METADATA, FlacState.READ_METADATA, FlacState.SEARCH_FOR_FRAME_SYNC -> {}
                else -> {
                    wfdb_error("getvec: unknown FLAC decoding state\n")
                    stat = -2
                    break
                }
            }
        }
    }
    ig.stat = stat
    return v
}

private fun Wfdb.flacIsopen(g: Int, si: Int, ns: Int): Int {
    if (ns > FLAC_MAX_CHANNELS) {
        wfdb_error(cformat("isigopen: cannot store %u signals in a single FLAC file\n", ns))
        return -1
    }
    val hs = sig.hsd
    for (k in si + 1 until si + ns) {
        if (hs[k].info.spf != hs[si].info.spf) {
            wfdb_error("isigopen: every signal in a FLAC file must have\n  the same sampling frequency\n")
            return -1
        }
    }
    val fi = FlacIn(FlacPack(ns, hs[si].info.fmt - FLAC_FMT_BASE, maxOf(hs[si].info.spf, 1)))
    val p = getenv("WFDB_FLAC_CHECK_MD5")
    fi.md5Check = p != null && p.isNotEmpty()
    val ig = sig.igd[g]
    ig.flac = fi
    ig.count = 0
    return 0
}

/** flac_isseek: seeks FLAC signal group g to frame t. */
private fun Wfdb.flacIsseek(g: Int, t: Long): Int {
    flacDecoder(g)
    val ig = sig.igd[g]
    val start = ig.start
    val fi = ig.flac
    val dec = fi?.dec
    if (fi == null || dec == null) {
        ig.stat = -1
        return -1
    }
    // After a failed seek, clear the decoder state to try again.
    if (dec.state == FlacState.SEEK_ERROR) dec.flush()
    // Nothing is left of the current block.
    val p = fi.pack
    p.clear()
    p.stat = 1
    // Seek to the sample before the one wanted (seeking to the end of the
    // stream fails), and skip it.
    var tt = t * p.spf + start
    if (tt != 0L) {
        tt -= 1
        p.count = 1
    }
    var stat = if (dec.seekAbsolute(tt, p)) p.stat else -1
    flacMessages(fi)
    if (stat > 0) stat = 1
    ig.stat = stat
    return stat
}

private fun Wfdb.flacOsinit(g: Int, si: Array<Siginfo>, s0: Int, ns: Int): Int {
    if (ns > FLAC_MAX_CHANNELS) {
        wfdb_error(cformat("osigfopen: cannot store %u signals in a single FLAC file\n", ns))
        return -1
    }
    for (s in s0 + 1 until s0 + ns) {
        if (si[s].spf != si[s0].spf) {
            wfdb_error("osigfopen: every signal in a FLAC file must have\n  the same sampling frequency\n")
            return -1
        }
    }
    val spf = if (si[s0].spf < 1) 1 else si[s0].spf
    val og = sig.ogd[g]
    og.flac = FlacOut(FlacEncoder(ns, si[s0].fmt - FLAC_FMT_BASE, spf))
    // Make the buffer exactly large enough to hold a single frame of 32-bit
    // samples, as C does (a non-zero bsize also prevents wfdb_osflush from
    // flushing it).
    og.bsize = ns * si[s0].spf * 4
    return 0
}

// ---------------------------------------------------------------------------
// Closing signals

private fun Wfdb.isigclose() {
    val st = sig
    if (st.haveSbuf && st.inMsrec == 0) {
        st.sbuf = IntArray(0)
        st.haveSbuf = false
        st.sampleVflag = 0
    }
    st.isd.clear()
    st.nisig = 0
    st.framelen = 0
    st.emptyGroup = false

    while (st.igd.isNotEmpty()) {
        val ig = st.igd.removeAt(st.igd.size - 1)
        flacIsclose(ig)?.let { wfdb_error(it) }
        ig.fp?.close()
        ig.fp = null
    }
    st.nigroup = 0

    st.istime = 0
    st.gvc = 1
    st.ispfmax = 1
    closeHheader()
    if (st.nosig == 0 && st.hsd.isNotEmpty()) st.hsd.clear()
}

private fun Wfdb.osigclose(): Int {
    var stat = 0
    val st = sig
    val n = minOf(st.nogroup, st.ogd.size)
    for (g in 0 until n) st.ogd[g].forceFlush = 1
    wfdb_osflush()

    st.osd.clear()
    st.nosig = 0

    while (st.ogd.isNotEmpty()) {
        val og = st.ogd.removeAt(st.ogd.size - 1)
        val maxogroup = st.ogd.size
        val fp = og.fp ?: continue
        if (og.flac != null) og.flacOsclose()
        // If a block size has been defined, null-pad the buffer.
        if (og.bsize != 0) while (og.bp < og.be) og.buf[og.bp++] = 0
        og.fp = null
        // Flush the last block unless it's empty.
        if (og.bp != 0) fp.write(og.buf, 0, og.bp)
        if (fp.isStd()) fp.flush()
        var errflag = fp.error()
        // Close the file (except stdout, which is closed on exit).
        if (!fp.isStd()) {
            if (fp.close() != 0) errflag = true
        }
        if (errflag) {
            wfdb_error(cformat("osigclose: write error in signal group %d\n", maxogroup))
            stat = -4
        }
    }
    st.nogroup = 0

    st.ostime = 0
    val oh = st.oheader
    if (oh != null) {
        st.oheader = null
        var errflag = oh.error()
        if (oh.close() != 0) errflag = true
        if (errflag) {
            wfdb_error("osigclose: write error in header file\n")
            stat = -4
        }
        if (st.outinfo == OUTINFO_HEADER) st.outinfo = OUTINFO_NONE
    }
    if (st.nisig == 0 && st.hsd.isNotEmpty()) st.hsd.clear()
    return stat
}

// ---------------------------------------------------------------------------
// Input positioning and reading

private fun Wfdb.seekerr(g: Int): Int {
    wfdb_error(cformat("isigsettime: improper seek on signal group %d\n", g))
    return -1
}

private fun Wfdb.overflow(g: Int): Int {
    wfdb_error(cformat("isigsettime: overflow in signal group %d\n", g))
    return -1
}

private fun Wfdb.isgsetframe(g: Int, t0: Long): Int {
    var t = t0
    val st = sig
    // Do nothing if there is no more than one input signal group and the
    // input pointer is correct already.
    if (st.nigroup < 2 && st.istime == t && st.gvc == st.ispfmax && g >= 0 && g < st.igd.size && st.igd[g].start == 0L) {
        return 0
    }

    // Find the first signal that belongs to group g.
    val nisig = st.nisig
    var s = 0
    while (s < nisig && g != st.isd[s].info.group) s++
    if (s == nisig) {
        wfdb_error(cformat("isgsettime: incorrect signal group number %d\n", g))
        return -2
    }

    // If the current record contains multiple segments, locate the segment
    // containing the desired sample.
    if (st.inMsrec != 0) {
        var tseg = st.segp
        if (t >= st.msnsamples) return seekerr(g)
        while (tseg > 0 && t < st.segarray[tseg].samp0) tseg--
        while (t >= st.segarray[tseg].samp0 + st.segarray[tseg].nsamp && tseg < st.segend) tseg++
        if (st.segp != tseg) {
            st.segp = tseg
            val name = st.segarray[tseg].recname
            if (isigopen(name, null, st.nvsig) <= 0) {
                wfdb_error(cformat("isigsettime: can't open segment %s\n", name))
                return -1
            }
            // Following isigopen(), nigroup may have changed: seek on all
            // non-zero groups (regardless of g), but on group 0 only if g is
            // 0.
            var h = 1
            while (h < sig.nigroup) {
                val i = isgsetframe(h, t)
                if (i != 0) return i
                h++
            }
            return if (g == 0) isgsetframe(0, t) else 0
        }
        t -= st.segarray[st.segp].samp0
    }

    val ig = st.igd[g]
    ig.initialSkip = 0
    // Determine the number of samples per frame for signals in the group.
    var n = 0
    var nn = 0
    while (s + n < nisig && st.isd[s + n].info.group == g) {
        nn += st.isd[s + n].info.spf
        n++
    }
    val msoff = if (st.inMsrec != 0) st.segarray[st.segp].samp0 else 0L
    // Determine the number of bytes per sample interval in the file: b bytes
    // hold d frames of the group's nn samples per frame (format 212 packs 2
    // samples in 3 bytes, 310 and 311 pack 3 in 4).
    val nnu = nn.toLong() and 0xffffffffL
    val b: Long
    var d = 1L
    when (st.isd[s].info.fmt) {
        0 -> {
            if (t < st.nsamples) {
                st.gvc = st.ispfmax
                if (s == 0) st.istime = if (st.inMsrec != 0) t + msoff else t
                st.isd[s].info.nsamp = st.nsamples - t
                ig.stat = 1
                return 0
            } else {
                if (s == 0) st.istime = if (st.inMsrec != 0) st.msnsamples else st.nsamples
                st.isd[s].info.nsamp = 0
                return -1
            }
        }
        508, 516, 524 -> {
            if (flacIsseek(g, t) < 0) return seekerr(g)
            // Reset the getvec sample-within-frame counter.
            st.gvc = st.ispfmax
            // Reset the time (if signal 0 belongs to the group) and disable
            // checksum testing.
            if (s == 0) st.istime = if (st.inMsrec != 0) t + msoff else t
            for (k in 0 until n) st.isd[s + k].info.nsamp = 0
            return 0
        }
        16, 61, 160 -> {
            if (nnu > 0xffffffffL / 2) return overflow(g)
            b = 2 * nnu
        }
        212 -> {
            if (nnu > 0xffffffffL / 3) return overflow(g)
            // Reset the input counter.
            ig.count = 0
            // If the desired sample does not lie on a byte boundary, seek to
            // the previous sample and then read ahead.
            if ((nn and 1) != 0 && (t and 1L) != 0L) {
                if (st.inMsrec != 0) t += msoff // absolute time
                val i = isgsetframe(g, t - 1)
                if (i != 0) return i
                val ig2 = sig.igd[g]
                for (k in 0 until nn) ig2.r212()
                sig.istime++
                var k = 0
                while (s + k < nisig && sig.isd[s + k].info.group == g) {
                    sig.isd[s + k].info.nsamp = 0
                    k++
                }
                return 0
            }
            b = 3 * nnu
            d = 2
        }
        310, 311 -> {
            val fmt = st.isd[s].info.fmt
            if (nnu > 0xffffffffL / 4) return overflow(g)
            ig.count = 0
            // If the desired sample does not lie on a byte boundary, seek to
            // the closest previous sample that does, then read ahead.
            val trem = (t % 3).toInt()
            if ((nn % 3) != 0 && trem != 0) {
                if (st.inMsrec != 0) t += msoff
                val i = isgsetframe(g, t - trem)
                if (i != 0) return i
                val ig2 = sig.igd[g]
                var j = nn * trem
                while (j > 0) {
                    if (fmt == 310) ig2.r310() else ig2.r311()
                    j--
                }
                sig.istime += trem
                var k = 0
                while (s + k < nisig && sig.isd[s + k].info.group == g) {
                    sig.isd[s + k].info.nsamp = 0
                    k++
                }
                return 0
            }
            b = 4 * nnu
            d = 3
        }
        24 -> {
            if (nnu > 0xffffffffL / 3) return overflow(g)
            b = 3 * nnu
        }
        32 -> {
            if (nnu > 0xffffffffL / 4) return overflow(g)
            b = 4 * nnu
        }
        else -> b = nnu // 8, 80
    }

    val start = ig.start
    if (b == 0L || t > Long.MAX_VALUE / b || (t * b) / d > Long.MAX_VALUE - start) return seekerr(g)

    var nb: Long
    val ibsize = st.ibsize
    // Seek to the beginning of the block which contains the desired sample.
    // For normal files, use fseek() to do so.
    if (ig.seek != 0) {
        val tt = t * b
        nb = tt / d + ig.start
        var i = ig.bsize
        if (i == 0L) i = ibsize.toLong()
        // Seek to a position such that the next block read will contain the
        // desired sample.
        val tt2 = nb / i
        val f = ig.fp
        if (f == null || f.seek(tt2 * i, SEEK_SET) != 0) return seekerr(g)
        nb %= i
    } else {
        // For special files, rewind if necessary and then read ahead.
        // Get the time of the earliest buffered sample ...
        val t0b = st.istime - ig.bp / b
        // ... and that of the earliest unread sample.
        val t1 = t0b + ig.be / b
        // Either the desired sample has been read and has passed out of the
        // buffer, requiring a rewind ...
        if (t < t0b) {
            val f = ig.fp
            if (f == null || f.seek(0, SEEK_SET) != 0) return seekerr(g)
            val tt = t * b
            nb = tt / d + ig.start
        } else if (t < t1) {
            // ... or it is in the buffer already ...
            val tt = (t - t0b) * b
            ig.bp = (tt / d).toInt()
            return 0
        } else {
            // ... or it has not yet been read.
            val tt = (t - t1) * b
            nb = tt / d
        }
        val bs = maxOf(ig.bsize, 0L)
        while (nb > ig.bsize) {
            val f = ig.fp ?: break
            if (f.eof()) break
            val m = minOf(bs, ig.buf.size.toLong()).toInt()
            nb -= f.read(ig.buf, 0, m)
        }
    }

    // Reset the block pointer to indicate nothing has been read in the
    // current block.
    ig.bp = ig.be
    ig.stat = 1
    // Read any bytes in the current block that precede the desired sample.
    while (nb > 0 && ig.stat > 0) {
        nb--
        ig.r8()
    }
    if (ig.stat <= 0) return -1

    // Reset the getvec sample-within-frame counter.
    st.gvc = st.ispfmax

    // Reset the time (if signal 0 belongs to the group) and disable checksum
    // testing (by setting the number of samples remaining to 0).
    if (s == 0) st.istime = if (st.inMsrec != 0) t + st.segarray[st.segp].samp0 else t
    for (k in 0 until n) st.isd[s + k].info.nsamp = 0
    return 0
}

private fun Wfdb.getskewedframe(vecstart: IntArray, voff: Int): Int {
    var stat = sig.nisig
    if (stat == 0) return if (sig.nvsig > 0) -1 else 0
    if (sig.istime == 0L) for (k in 0 until sig.nisig) sig.isd[k].samp = sig.isd[k].info.initval
    var g = sig.nigroup
    while (g > 0) {
        // Go through groups in reverse order since seeking on group 0 should
        // always be done last.
        g--
        // (a seek that failed may have closed the input signals)
        if (g < sig.nigroup && sig.igd[g].initialSkip != 0) {
            val t0 = if (sig.inMsrec != 0) sig.segarray[sig.segp].samp0 else 0L
            isgsetframe(g, t0)
        }
    }
    // (the seek may have closed the input signals: see isigsettime)
    val nisig = sig.nisig
    if (sig.emptyGroup) return -1 // WFDB-x (see isigopen)

    // If the vector needs to be rearranged (variable-layout record), then
    // read samples into a temporary buffer.
    val needSigmap = sig.needSigmap != 0
    val ovec = sig.ovec
    val target: IntArray = if (needSigmap) ovec else vecstart
    val toff = if (needSigmap) 0 else voff
    val pad = (sig.gvmode and WFDB_GVPAD) != 0
    var switch = false
    var vi = toff
    sigloop@ for (s in 0 until nisig) {
        val isv = sig.isd[s]
        val fmt = isv.info.fmt
        val spf = isv.info.spf
        val group = isv.info.group
        var cksum = isv.info.cksum
        val ig = sig.igd[group]
        // The lowest value of the format is its invalid-sample code (not used
        // by formats 0 and 8).
        val inval = fmtMin(fmt)
        for (c in 0 until spf) {
            var v: Int
            when (fmt) {
                0 -> {
                    // null signal: return sample tagged as invalid
                    v = if (pad) isv.samp else WFDB_INVALID_SAMPLE
                    target[vi] = v
                    if (isv.info.nsamp == 0L) ig.stat = -1
                }
                16 -> v = ig.r16()
                61 -> v = ig.r61()
                80 -> v = ig.r80()
                160 -> v = ig.r160()
                212 -> v = ig.r212()
                310 -> v = ig.r310()
                311 -> v = ig.r311()
                24 -> v = ig.r24()
                32 -> v = ig.r32()
                508, 516, 524 -> v = flacGetsamp(group)
                else -> {
                    // 8-bit first differences
                    val dv = ig.r8()
                    isv.samp += dv
                    v = isv.samp
                    target[vi] = v
                }
            }
            if (fmt != 0 && fmt != 8 && isfmt(fmt)) {
                if (v == inval) {
                    target[vi] = if (pad) isv.samp else WFDB_INVALID_SAMPLE
                } else {
                    isv.samp = v
                    target[vi] = v
                }
            }
            if (ig.stat <= 0) {
                // End of file -- reset input counter.
                ig.count = 0
                if (ig.stat == -2) {
                    // error in decoding compressed data
                    stat = -3
                } else if (isv.info.nsamp > 0) {
                    wfdb_error(cformat("getvec: unexpected EOF in signal %d\n", s))
                    stat = -3
                } else if (sig.inMsrec != 0 && sig.haveSegarray && sig.segp >= 0 && sig.segp < sig.segend) {
                    isv.info.cksum = cksum
                    switch = true
                    break@sigloop
                } else {
                    stat = -1
                }
            }
            cksum -= v
            vi++
        }
        isv.info.cksum = cksum
        if (isv.info.nsamp >= 0) {
            isv.info.nsamp--
            if (isv.info.nsamp == 0L && (cksum and 0xffff) != 0 && sig.inMsrec == 0 && sig.isedf == 0 && fmt != 0) {
                val msg = cformat("getvec: checksum error in signal %d\n", s)
                // WFDB-x: not printed during a high-level read (it prints its
                // own warning), but recorded
                if (sig.cksumQuiet) wfdbErrorUnprinted(msg) else wfdb_error(msg)
                stat = -4
            }
        }
    }
    if (switch) {
        sig.segp++
        val name = sig.segarray[sig.segp].recname
        if (isigopen(name, null, sig.nvsig) <= 0) {
            wfdb_error(cformat("getvec: error opening segment %s\n", name))
            return -3 // avoid looping if segment is bad
        }
        sig.istime = sig.segarray[sig.segp].samp0
        return getskewedframe(vecstart, voff)
    }

    if (needSigmap) {
        sigmap(vecstart, voff, ovec)
    } else {
        val framelen = sig.framelen
        val tspf = sig.tspf
        if (framelen != tspf) for (s in maxOf(framelen, 0) until tspf) vecstart[voff + s] = WFDB_INVALID_SAMPLE
    }
    return stat
}

private fun Wfdb.sigmap(vector: IntArray, off: Int, ivec: IntArray, ioff: Int = 0) {
    val st = sig
    for (i in 0 until maxOf(st.tspf, 0)) {
        val m = st.smi[i]
        val x = ivec[ioff + m.index]
        if (x == WFDB_INVALID_SAMPLE) {
            vector[off + i] = WFDB_INVALID_SAMPLE
        } else {
            // Scale the input sample and round it to the nearest integer
            // (halfway cases are rounded up; m.offset includes 0.5).
            val v = x * m.scale + m.offset
            vector[off + i] = if (m.sampleOffset != 0) {
                d2i(v) + m.sampleOffset
            } else if (v >= 0.0) {
                if (v <= WFDB_SAMPLE_MAX.toDouble()) v.toInt() else WFDB_SAMPLE_MAX
            } else if (v >= WFDB_SAMPLE_MIN.toDouble()) {
                var r = v.toInt()
                if (r.toDouble() > v) r--
                r
            } else {
                WFDB_SAMPLE_MIN
            }
        }
    }
}

private fun Wfdb.rgetvec(vector: IntArray, off: Int): Int {
    if (sig.ispfmax < 2) return getframeAt(vector, off) // all signals at the same frequency
    val tv = sig.tvector
    if ((sig.gvmode and WFDB_HIGHRES) != WFDB_HIGHRES) {
        // return one sample per frame, decimating by averaging if necessary
        sig.rgetvecStat = getframeAt(tv, 0)
        val st = sig
        var tp = 0
        for (s in 0 until maxOf(st.nvsig, 0)) {
            val sf = st.vsd[s].info.spf
            vector[off + s] = meansamp(tv, tp, sf)
            tp += sf
        }
    } else {
        // return ispfmax samples per frame, using zero-order interpolation if
        // necessary
        if (sig.gvc >= sig.ispfmax) {
            sig.rgetvecStat = getframeAt(tv, 0)
            sig.gvc = 0
        }
        val st = sig
        val ispfmax = st.ispfmax
        val gvc = st.gvc
        var tp = 0
        for (s in 0 until maxOf(st.nvsig, 0)) {
            val v = st.vsd[s]
            val sf = v.info.spf
            if (gvc == 0) {
                v.gvindex = 0
                v.gvcount = -ispfmax
            } else {
                v.gvcount += sf
                if (v.gvcount >= 0) {
                    v.gvindex++
                    v.gvcount -= ispfmax
                }
            }
            vector[off + s] = tv[tp + v.gvindex]
            tp += sf
        }
        st.gvc++
    }
    return sig.rgetvecStat
}

// ---------------------------------------------------------------------------
// Opening output signals

/**
 * WFDB-x: whether the signal file of a header line names one of the signal
 * files of the segment seg of the open multi-segment record (located as
 * isigopen locates them in normal mode, without changing hdrDir): a header
 * or signal file that cannot be found, or is at a URL, is not. No message
 * is printed.
 */
private fun Wfdb.segmentHasFile(seg: ByteArray, id: FileId): Boolean {
    val md = sig.msrecDir
    if (beq(seg, "~") || !inHeaderDir(seg) || (md != null && isUrl(md))) return false
    val name = sig.msrecName
    val hf = (if (name != null) wfdbx_open_in(md, "hea".latin1(), seg, name) else wfdb_open("hea".latin1(), seg, WFDB_READ))
        ?: return false
    try {
        val dir = if (hf.isStd() || hf.isRemote()) null else wfdbx_dirname(wfdb_filename())
        val line = ByteVec(256)
        var nsig = -1L
        while (nsig != 0L && hf.getline(line) > 0) {
            val toks = ArrayList<ByteArray>()
            val tk = Strtok(line.toByteArray())
            while (true) toks.add(tk.next(" \t\n\r") ?: break)
            if (toks.isEmpty()) continue
            val p = toks[0]
            if (p[0] == '#'.code.toByte()) continue
            if (nsig < 0) {
                // the record line
                nsig = if (toks.size > 1 && strchrAt(p, '/') < 0) strtol10(toks[1]) else 0 // (0: not a valid segment)
                if (nsig <= 0) break
                continue
            }
            nsig-- // a signal line: file name, format, ...
            val fmt = if (toks.size > 1) strtol10(toks[1]) else 0L
            if (dir == null) continue
            if (fmt == 0L || beq(p, "-") || !inHeaderDir(p) || isUrl(dir)) continue
            val sf = wfdbx_open_in(dir, null, p, seg)
            if (sf != null) {
                val same = sf.fileId() == id
                sf.close()
                if (same) return true
            }
        }
        return false
    } finally {
        hf.close()
    }
}

/**
 * WFDB-x: whether the output signal file fname (as named in an output
 * signal specification, created by wfdb_open(fname, NULL, WFDB_WRITE))
 * exists and is one of the signal files of the open input record: an open
 * input signal file, or a signal file of a segment of the open multi-segment
 * record. Files are compared by identity (device and inode numbers), not by
 * name.
 */
private fun Wfdb.isInputFile(fname: ByteArray): Boolean {
    val path = wfdbxOutputFile(fname) ?: return false
    val id = pathId(path) ?: return false // it does not exist: it is not an input file
    val ng = minOf(sig.nigroup, sig.igd.size)
    for (g in 0 until ng) if (sig.igd[g].fp?.fileId() == id) return true
    if (sig.inMsrec != 0 && sig.haveSegarray) {
        val end = minOf(maxOf(sig.segend + 1, 0), sig.segarray.size)
        val segs = (0 until end).map { cstr(sig.segarray[it].recname) }
        return segs.any { segmentHasFile(it, id) }
    }
    return false
}

private fun Wfdb.openosig(func: String, siOut: Array<Siginfo>?, siIn: Array<Siginfo>, nsig: Int): Int {
    if (nsig == 0) return 0
    val st = sig
    // Allocate workspace for output signals and signal groups.
    while (st.osd.size < st.nosig + nsig) st.osd.add(OsData())
    while (st.ogd.size < st.nogroup + siIn[nsig - 1].group + 1) st.ogd.add(OgData())
    // Initialize local variables.
    if (st.obsize <= 0) st.obsize = WFDB_BUFSIZ
    // Set the group number adjustment.
    val ga = st.nogroup

    // Open the signal files. One signal is handled per iteration.
    var s = 0
    while (s < nsig) {
        val osi = st.nosig
        val op = if (s == 0) osi else osi - 1
        val info = siIn[s].copy()
        if (info.spf < 1) info.spf = 1
        info.cksum = 0
        info.nsamp = 0
        info.group += ga
        if (siOut != null && s < siOut.size) siOut[s].set(info)
        val os = st.osd[osi]
        os.info = info
        os.samp = 0

        // Check if this signal is in the same group as the previous one.
        if (s == 0 || os.info.group != st.osd[op].info.group) {
            val gi = os.info.group
            while (st.ogd.size < gi + 1) st.ogd.add(OgData())
            val og = st.ogd[gi]
            og.bsize = os.info.bsize
            if (isflacfmt(os.info.fmt)) {
                var ns = 1
                while (s + ns < nsig && siIn[s + ns].group == siIn[s].group) ns++
                if (flacOsinit(gi, siIn, s, ns) < 0) {
                    osigclose()
                    return -3
                }
            }
            val obuflen = if (og.bsize != 0) og.bsize else st.obsize
            // This is the first signal in a new group; allocate buffer.
            og.buf = ByteArray(obuflen)
            og.bp = 0
            og.be = obuflen
            if (os.info.fmt == 0) {
                // If the signal file name was NULL or "~", don't create a
                // signal file.
                val fn = os.info.fname
                if (fn == null || beq(cstr(fn), "~")) {
                    og.fp = null
                } else {
                    // Otherwise, assume that the user wants to write a signal
                    // file in the default format (16).
                    os.info.fmt = 16
                }
            }
            if (os.info.fmt != 0) {
                val fname = os.info.fname
                // WFDB-x: never an input file (see isInputFile)
                if (!legacy && isInputFile(if (fname == null) ByteArray(0) else cstr(fname))) {
                    wfdb_error(cformat("%s: output file %s is also an input file\n", func, fname))
                    og.buf = ByteArray(0)
                    osigclose()
                    return -3
                }
                // An error in opening an output file is fatal.
                val f = wfdb_open(fname?.let { cstr(it) }, null, WFDB_WRITE)
                if (f != null) {
                    og.fp = f
                } else {
                    og.fp = null
                    wfdb_error(cformat("%s: can't open %s\n", func, fname))
                    og.buf = ByteArray(0)
                    osigclose()
                    return -3
                }
            }
            if (isflacfmt(os.info.fmt) && og.flac != null && og.flacOsopen() < 0) {
                osigclose()
                return -3
            }
            st.nogroup++
        } else {
            // This signal belongs to the same group as the previous one.
            if (os.info.fmt != st.osd[op].info.fmt || os.info.bsize != st.osd[op].info.bsize) {
                wfdb_error(cformat("%s: error in specification of signal %d or %d\n", func, s - 1, s))
                return -2
            }
        }
        st.nosig++
        s++
    }
    return s
}

// ---------------------------------------------------------------------------
// Hooks used by Wfdbinit.kt

/** `wfdb_sampquit()`: releases the sample() buffer (called by wfdbquit). */
internal fun Wfdb.wfdb_sampquit() {
    val st = sig
    if (st.haveSbuf) {
        st.sbuf = IntArray(0)
        st.haveSbuf = false
        st.sampleVflag = 0
    }
}

/** `wfdb_sigclose()`: closes all signals and resets the signal state (called by wfdbquit). */
internal fun Wfdb.wfdb_sigclose() {
    isigclose()
    osigclose()
    val st = sig
    st.btime = 0
    st.bdate = 0
    st.nsamples = 0
    st.msbtime = 0
    st.msbdate = 0
    st.msnsamples = 0
    st.sfreq = 0.0
    st.ifreq = 0.0
    st.ffreq = 0.0
    st.pdays = -1
    st.segments = 0
    st.inMsrec = 0
    st.msrecDir = null // WFDB-x
    st.msrecName = null
    st.hdrDir = null
    st.skewmax = 0
    if (st.haveDsbuf) {
        st.dsbuf = IntArray(0)
        st.haveDsbuf = false
        st.dsbi = -1
    }
    if (st.haveSegarray) {
        st.segarray.clear()
        st.haveSegarray = false
        st.segp = -1
        st.segend = -1
    }
    st.gv0 = IntArray(0)
    st.gv1 = IntArray(0)
    st.tvector = IntArray(0)
    st.uvector = IntArray(0)
    st.vvector = IntArray(0)
    st.tuvlen = 0
    sigmapCleanup()
}

/** `wfdb_osflush()`: writes out buffered output samples (called by wfdbflush). */
internal fun Wfdb.wfdb_osflush() {
    val st = sig
    if (st.osd.isEmpty() || st.ogd.isEmpty()) return
    val obsize = st.obsize
    val n = minOf(st.nosig, st.osd.size)
    for (s in 0 until n) {
        val g = st.osd[s].info.group
        if (g < 0 || g >= st.ogd.size) continue
        val fmt = st.osd[s].info.fmt
        val og = st.ogd[g]
        if (og.nrewind == 0) {
            if (og.forceFlush == 0 && og.seek == 0) {
                val f = og.fp
                val seekable = og.bsize == 0 && f != null && f.seek(0, SEEK_CUR) == 0
                og.seek = if (seekable) 1 else -1
            }
            if (og.forceFlush != 0 || og.seek > 0) {
                // Either we are closing the file (osigclose() was called), or
                // the file is seekable: write out any partially-completed
                // sets of bit-packed samples.
                when (fmt) {
                    212 -> og.f212(obsize)
                    310 -> og.f310(obsize)
                    311 -> og.f311(obsize)
                }
            }
        }
    }
    val ng = minOf(st.nogroup, st.ogd.size)
    for (g in 0 until ng) {
        val og = st.ogd[g]
        if (og.bsize == 0 && og.bp != 0) {
            og.fp?.write(og.buf, 0, og.bp)
            og.bp = 0
        }
        val f = og.fp
        if (f != null) {
            f.flush()
            if (og.forceFlush == 0 && og.nrewind != 0) {
                // Rewind the file so that subsequent samples will be written
                // in the right place.
                f.seek(-og.nrewind.toLong(), SEEK_CUR)
                og.nrewind = 0
            }
        }
    }
}

/** `wfdb_oinfoclose()`: closes the output info file (called by wfdbquit). */
internal fun Wfdb.wfdb_oinfoclose(): Int {
    var stat = 0
    val st = sig
    if (st.outinfo == OUTINFO_FILE) {
        val f = st.outinfoFile
        if (f != null) {
            st.outinfoFile = null
            var errflag = f.error()
            if (f.close() != 0) errflag = true
            if (errflag) {
                wfdb_error("setinfo: write error in info file\n")
                stat = -2
            }
        }
    }
    st.outinfoFile = null
    st.outinfo = OUTINFO_NONE
    return stat
}

/** The number of values getvec/getframe may store. */
private fun Wfdb.vecNeed(): Int {
    val st = sig
    return maxOf(maxOf(st.tspf, st.nvsig), maxOf(st.nisig, st.framelen), 0)
}

// ---------------------------------------------------------------------------
// WFDB library functions: opening and closing signals

/**
 * C `isigopen(record, siarray, nsig)`: opens the input signals of a record.
 *
 * The header of [record] is found as [wfdb_open] finds files (WFDB-x: the
 * signal files it names are in its directory; legacy mode: all are found in
 * the WFDB path), and up to [nsig] signals are opened; [siarray] (if not
 * null) receives their [Siginfo]. Input signals open before are closed
 * first, unless the record name begins with "+". With nsig <= 0, up to
 * -nsig elements of siarray are filled in from the header, without opening
 * the signals (with nsig == 0 and siarray null, this gives the number of
 * signals of the record).
 *
 * Returns the number of signals of the record (> 0), or: 0 if there are no
 * input signals, -1 if the header cannot be read, -2 if the header is
 * incorrect, -3 if the signal files cannot be opened (internal limits
 * exceeded).
 *
 * Translation of the C function isigopen() (lib/signal.c, WFDB 10.7.0): same
 * arguments and results. Differences: the signal files and segments named in
 * the header are read only from the header's directory, and no sampling
 * frequency, gain, ADC resolution or units are assumed; see
 * docs/DIVERGENCES.md.
 */
fun Wfdb.isigopen(record: ByteArray?, siarray: Array<Siginfo>?, nsig: Int): Int {
    val recArg0 = if (record == null) ByteArray(0) else cstr(record)
    var nsigv = nsig
    var firstSegment = false

    // Close previously opened input signals unless otherwise requested.
    val recArg = if (recArg0.isNotEmpty() && recArg0[0] == '+'.code.toByte()) {
        recArg0.copyOfRange(1, recArg0.size)
    } else {
        isigclose()
        recArg0
    }

    // Remove trailing .hea, if any, from record name.
    val rec = wfdb_striphea(recArg)

    // Save the current record name.
    if (sig.inMsrec == 0) wfdb_setirec(rec)

    // Read the header and determine how many signals are available.
    var navail = readheader(rec)
    if (navail <= 0) {
        if (navail == 0 && sig.segments != 0) {
            // this is a multi-segment record
            sig.inMsrec = 1
            firstSegment = true
            // Open the first segment to get signal information.
            if (sig.haveSegarray && sig.segp >= 0) {
                navail = readheader(sig.segarray[sig.segp].recname)
                if (navail >= 0) {
                    if (sig.msbtime == 0L) sig.msbtime = sig.btime
                    if (sig.msbdate == 0L) sig.msbdate = sig.bdate
                }
            }
            if (nsigv <= 0) sig.inMsrec = 0
        }
        if (navail == 0 && nsigv != 0) wfdb_error(cformat("isigopen: record %s has no signals\n", rec))
        if (navail <= 0) return navail
    }

    val st = sig
    // If nsig <= 0, isigopen fills in up to (-nsig) members of siarray based
    // on the contents of the header, but no signals are actually opened.
    if (nsigv <= 0) {
        nsigv = -nsigv
        if (navail < nsigv) nsigv = navail
        val n = minOf(maxOf(nsigv, 0), siarray?.size ?: 0)
        for (s in 0 until n) siarray!![s].set(st.hsd[s].info)
        st.inMsrec = 0 // necessary to avoid errors when reopening
        return navail
    }

    // Determine how many new signals we should attempt to open.
    if (nsigv > navail) nsigv = navail

    // Allocate input signals and signal group workspace.
    while (st.isd.size < st.nisig + nsigv) st.isd.add(IsData())
    var ngn = st.nigroup + st.hsd[navail - 1].info.group + 1
    if (ngn > st.nigroup + nsigv) ngn = st.nigroup + nsigv
    while (st.igd.size < ngn) st.igd.add(IgData())

    // Set default buffer size (if not set already by setibsize).
    if (st.ibsize <= 0) st.ibsize = WFDB_BUFSIZ

    // Open the signal files. One signal group is handled per iteration. In
    // this loop, si counts through the entries that have been read from hsd,
    // and s counts the entries that have been added to isd.
    var g = 0
    var si = 0
    var s = 0
    while (si < navail && s < nsigv) {
        // Find out how many signals are in this group.
        var sj = si + 1
        while (sj < navail && st.hsd[sj].info.group == st.hsd[si].info.group) sj++

        // Skip this group if there are too few slots in the caller's array.
        if (sj - si > nsigv - s) {
            si = sj
            continue
        }

        val gi = st.nigroup + g
        val hs = st.hsd[si]
        val ig = st.igd[gi]
        // Set the buffer size and the seek capability flag.
        if (hs.info.bsize < 0) {
            // WFDB-x: -2147483648 gives 2147483648 (C overflows)
            ig.bsize = -hs.info.bsize.toLong()
            hs.info.bsize = if (hs.info.bsize == Int.MIN_VALUE) Int.MAX_VALUE else -hs.info.bsize
            ig.seek = 0
        } else {
            ig.bsize = hs.info.bsize.toLong()
            if (ig.bsize == 0L) ig.bsize = st.ibsize.toLong()
            ig.seek = 1
        }
        // (allocated once the signal file is open)
        ig.buf = ByteArray(0)
        ig.flac = null
        ig.data = 0
        ig.datb = 0
        ig.count = 0

        // Check that the signal file is readable.
        val fmt = hs.info.fmt
        if (fmt == 0) {
            ig.fp?.close()
            ig.fp = null // Don't open a file for a null signal.
        } else {
            val fname = hs.info.fname?.let { cstr(it) }
            // WFDB-x: in the directory of the header
            val f = if (legacy) {
                wfdb_open(fname, null, WFDB_READ)
            } else {
                wfdbx_open_in(st.hdrDir, null, fname ?: ByteArray(0), rec)
            }
            ig.fp?.close()
            ig.fp = f
            // Skip this group if the signal file can't be opened.
            if (f == null) {
                ig.buf = ByteArray(0)
                si = sj
                continue
            }
            // WFDB-x: a buffer no larger than the file (a block can be
            // larger), so reads and seeks are the same
            var n = maxOf(ig.bsize, 0L)
            val size = f.localSize()
            if (size > 0) n = minOf(n, size)
            ig.buf = ByteArray(minOf(n, BUF_MAX.toLong()).toInt())
        }

        if (isflacfmt(fmt) && flacIsopen(gi, si, sj - si) < 0) {
            ig.buf = ByteArray(0)
            ig.fp?.close()
            ig.fp = null
            ig.flac = null
            si = sj
            continue
        }

        // All tests passed -- fill in remaining data for this group.
        // (nothing is in the buffer; C sets bp to bsize, of which the
        // buffer can now be a part)
        ig.bp = ig.buf.size
        ig.be = ig.bp
        ig.start = hs.start
        ig.initialSkip = if (ig.start > 0) 1 else 0
        ig.stat = 1
        while (si < sj && s < nsigv) {
            val isv = st.isd[st.nisig + s]
            isv.info = st.hsd[si].info.copy()
            isv.info.group = st.nigroup + g
            isv.skew = st.hsd[si].skew
            s++
            si++
        }
        si = sj
        g++
    }

    // Produce a warning message if none of the requested signals could be
    // opened.
    if (s == 0 && nsigv != 0) wfdb_error(cformat("isigopen: none of the signals for record %s is readable\n", rec))

    // Check that the total number of samples per frame is less than or equal
    // to INT_MAX.
    var spflimit = INT_MAX - st.framelen
    for (k in 0 until s) {
        spflimit -= st.isd[st.nisig + k].info.spf
        if (spflimit < 0) {
            wfdb_error(cformat("isigopen: total frame size too large in record %s\n", rec))
            isigclose()
            return -3
        }
    }

    // Copy the WFDB_Siginfo structures to the caller's array. Use these data
    // to construct the initial sample vector, and to determine the maximum
    // number of samples per signal per frame and the maximum skew.
    for (k in 0 until s) {
        val isv = st.isd[st.nisig + k]
        if (siarray != null && k < siarray.size) siarray[k].set(isv.info)
        isv.samp = isv.info.initval
        if (uless(st.ispfmax, isv.info.spf)) st.ispfmax = isv.info.spf
        if (uless(st.skewmax, isv.skew)) st.skewmax = isv.skew
    }
    st.nisig += s // Update the count of open input signals.
    st.nigroup += g // Update the count of open input groups.

    if (sigmapInit(firstSegment) < 0) {
        isigclose()
        return -3
    }
    st.spfmax = st.ispfmax
    setgvmode(st.gvmode) // Reset sfreq if appropriate.
    st.gvc = st.ispfmax // Initialize getvec's counter.

    // Determine the total number of samples per frame.
    st.framelen = 0
    for (k in 0 until st.nisig) st.framelen += st.isd[k].info.spf
    // WFDB-x: a signal group whose frames hold no samples
    st.emptyGroup = (0 until st.nigroup).any { g ->
        val gs = (0 until st.nisig).map { st.isd[it].info }.filter { it.group == g && it.fmt != 0 }
        gs.isNotEmpty() && gs.all { it.spf == 0 }
    }

    // Allocate workspace for getvec, isgsettime, and tnextvec.
    if (st.tspf > st.tuvlen) {
        st.tvector = IntArray(st.tspf)
        st.uvector = IntArray(st.tspf)
        st.vvector = IntArray(st.tspf)
        st.tuvlen = st.tspf
    }

    // If deskewing is required, allocate the deskewing buffer (unless this is
    // a multi-segment record and dsbuf has been allocated already).
    if (st.skewmax != 0 && (st.inMsrec == 0 || !st.haveDsbuf)) {
        if (st.tspf > INT_MAX / (st.skewmax + 1)) {
            wfdb_error(cformat("isigopen: maximum skew too large in record %s\n", rec))
            isigclose()
            return -3
        }
        st.dsbi = -1 // mark buffer contents as invalid
        st.dsblen = st.tspf * (st.skewmax + 1)
        st.dsbuf = IntArray(st.dsblen)
        st.haveDsbuf = true
    }
    return s
}

/** [isigopen] with the record name as a string. */
fun Wfdb.isigopen(record: String, siarray: Array<Siginfo>?, nsig: Int): Int = isigopen(record.latin1(), siarray, nsig)

/**
 * C `osigopen(record, siarray, nsig)`: opens output signals as described by
 * the header of an existing record (signal files, formats, gains, ...);
 * [siarray] (if not null) receives their [Siginfo].
 *
 * Returns the number of output signals opened (> 0; it should be nsig),
 * or: -1 if the header cannot be read, -2 if it is incorrect, -3 if the
 * output signal files cannot be opened (or, WFDB-x, one of them is one of
 * the input files, as for [osigfopen]).
 *
 * Translation of the C function osigopen() (lib/signal.c, WFDB 10.7.0): same
 * arguments and results. Differences: an output signal file that is one of the
 * input files of the open record is refused; see docs/DIVERGENCES.md.
 */
fun Wfdb.osigopen(record: ByteArray?, siarray: Array<Siginfo>?, nsig: Int): Int {
    val recArg0 = if (record == null) ByteArray(0) else cstr(record)
    // Close previously opened output signals unless otherwise requested.
    val recArg = if (recArg0.isNotEmpty() && recArg0[0] == '+'.code.toByte()) {
        recArg0.copyOfRange(1, recArg0.size)
    } else {
        osigclose()
        recArg0
    }

    // Remove trailing .hea, if any, from record name.
    val rec = wfdb_striphea(recArg)

    val n = readheader(rec)
    if (n < 0) return n
    if (uless(n, nsig)) {
        wfdb_error(cformat("osigopen: record %s has fewer signals than needed\n", rec))
        return -3
    }
    val hsi = Array(nsig) { sig.hsd[it].info.copy() }
    val out = if (siarray == null || siarray.isEmpty()) null else siarray
    return openosig("osigopen", out, hsi, nsig)
}

/** [osigopen] with the record name as a string. */
fun Wfdb.osigopen(record: String, siarray: Array<Siginfo>?, nsig: Int): Int = osigopen(record.latin1(), siarray, nsig)

/**
 * C `osigfopen(siarray, nsig)`: opens output signals as described by the
 * first [nsig] elements of [siarray] (file name, format, gain, ...),
 * closing the output signals open before. With nsig == 0, only closes them.
 *
 * Returns the number of output signals opened (> 0; it should be nsig), or:
 * -2 if a signal specification is incorrect (file name or description too
 * long, illegal format or block size, incorrect signal group), -3 if a
 * signal file cannot be opened, or (WFDB-x, except in legacy mode) is one of
 * the signal files of the open input record ("osigfopen: output file F is
 * also an input file"; the file is not touched). With nsig == 0 (or a null
 * or empty siarray): 0, or -4 on a write error while closing the previous
 * output signals.
 *
 * Translation of the C function osigfopen() (lib/signal.c, WFDB 10.7.0): same
 * arguments and results. Differences: an output signal file that is one of the
 * input files of the open record is refused; see docs/DIVERGENCES.md.
 */
fun Wfdb.osigfopen(siarray: Array<Siginfo>?, nsig: Int): Int {
    // Close any open output signals.
    val stat = osigclose()

    // Do nothing further if there are no signals to open.
    if (siarray == null || siarray.isEmpty() || nsig == 0) return stat
    val n = if (uless(siarray.size, nsig)) siarray.size else nsig

    if (sig.obsize <= 0) sig.obsize = WFDB_BUFSIZ

    // Prescan siarray to check the signal specifications and to determine
    // the number of signal groups.
    for (s in 0 until n) {
        val si = siarray[s]
        val lf = ostr(si.fname).size
        val ld = ostr(si.desc).size
        if (lf + ld > MAXFDLEN || si.bsize < 0 || !isfmt(si.fmt)) {
            wfdb_error(cformat("osigfopen: error in specification of signal %d\n", s))
            return -2
        }
        val f1 = ostr(si.fname)
        val f0 = if (s > 0) ostr(siarray[s - 1].fname) else ByteArray(0)
        val ok = (s == 0 && si.group == 0) ||
            (s > 0 && si.group == siarray[s - 1].group && f1.contentEquals(f0)) ||
            (s > 0 && si.group == siarray[s - 1].group + 1 && !f1.contentEquals(f0))
        if (!ok) {
            wfdb_error(cformat("osigfopen: incorrect file name or group for signal %d\n", s))
            return -2
        }
    }

    return openosig("osigfopen", null, siarray, n)
}

/**
 * C `findsig(p)`: returns the number of the input signal whose description
 * is [p] (or whose number is p, a decimal number), or -1 if there is none.
 *
 * Translation of the C function findsig() (lib/signal.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.findsig(p0: ByteArray): Int {
    val p = cstr(p0)
    val st = sig
    if (p.all { isdigit(it.toInt() and 0xff) }) {
        // all digits, probably a signal number
        val s = strtol10(p).toInt()
        if (uless(s, st.nisig) || s < st.nvsig) return s
    }
    // Otherwise, p is either an integer too large to be a signal number or a
    // string containing a non-digit character. Assume it's a signal name.
    if (st.needSigmap != 0) {
        for (s in 0 until maxOf(st.nvsig, 0)) {
            val d = st.vsd[s].info.desc
            if (d != null && cstr(d).contentEquals(p)) return s
        }
    } else {
        for (s in 0 until st.nisig) {
            val d = st.isd[s].info.desc
            if (d != null && cstr(d).contentEquals(p)) return s
        }
    }
    return -1
}

/** [findsig] with a string. */
fun Wfdb.findsig(p: String): Int = findsig(p.latin1())

// ---------------------------------------------------------------------------
// Frequencies and modes

/**
 * C `getspf()`: the number of samples per frame returned by getvec for each
 * signal (1 unless in WFDB_HIGHRES mode).
 *
 * Translation of the C function getspf() (lib/signal.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.getspf(): Int = if (sig.sfreq != sig.ffreq) d2i(sig.sfreq / sig.ffreq + 0.5) else 1

/**
 * C `setgvmode(mode)`: sets the getvec mode ([WFDB_LOWRES] or
 * [WFDB_HIGHRES], optionally with [WFDB_GVPAD]); a negative mode selects the
 * default (from WFDBGVMODE).
 *
 * Translation of the C function setgvmode() (lib/signal.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.setgvmode(mode0: Int) {
    var mode = mode0
    if (mode < 0) {
        // (re)set to default mode
        val p = getenv("WFDBGVMODE")
        mode = if (p != null) strtol10(p).toInt() else DEFWFDBGVMODE
    }
    val st = sig
    st.gvmode = mode and (WFDB_HIGHRES or WFDB_GVPAD)
    if ((mode and WFDB_HIGHRES) == WFDB_HIGHRES) {
        if (st.spfmax == 0) st.spfmax = 1
        st.sfreq = st.ffreq * st.spfmax
    } else {
        st.sfreq = st.ffreq
    }
}

/**
 * C `getgvmode()`: the current getvec mode ([WFDB_LOWRES] or [WFDB_HIGHRES],
 * with [WFDB_GVPAD] if invalid samples are replaced).
 *
 * Translation of the C function getgvmode() (lib/signal.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.getgvmode(): Int = sig.gvmode

/**
 * C `setifreq(f)`: sets the sampling frequency at which getvec returns the
 * input signals; they are resampled (by linear interpolation) to f Hz. A
 * record must be open.
 *
 * Returns 0 on success, or -1 if no input record is open, its sampling
 * frequency is not specified (WFDB-x), or f is not positive (resampling is
 * then turned off).
 *
 * Translation of the C function setifreq() (lib/signal.c, WFDB 10.7.0): same
 * arguments and results. Differences: it fails if the sampling frequency of the
 * input record is not specified; see docs/DIVERGENCES.md.
 */
fun Wfdb.setifreq(f0: Double): Int {
    var f = f0
    var g = sig.sfreq
    if (g <= 0.0) {
        sig.ifreq = 0.0
        if (sig.nisig > 0 && !legacy) {
            // WFDB-x: the frequency is unspecified
            wfdb_error("setifreq: sampling frequency is not specified\n")
        } else {
            wfdb_error("setifreq: no open input record\n")
        }
        return -1
    }
    if (f > 0.0) {
        val st = sig
        var n = maxOf(st.nvsig, st.nisig)
        if (n < st.tspf) n = st.tspf
        n = maxOf(n, 1)
        if (st.gv0.size < n) st.gv0 = st.gv0.copyOf(n)
        if (st.gv1.size < n) st.gv1 = st.gv1.copyOf(n)
        st.ifreq = f
        setafreq(f)
        // Euclid's algorithm for the GCD of sfreq and ifreq (in multiples of
        // 0.005 Hz, the maximum tolerable error in the resampling frequency).
        while (true) {
            val error = f - g
            if (!(error > 0.005 || error < -0.005)) break
            if (f > g) f -= g else g -= f
        }
        // f is now the GCD of sfreq and ifreq. Each raw sampling interval is
        // divided into mticks subintervals.
        st.mticks = d2l(st.sfreq / f + 0.5)
        // Each resampled interval is divided into nticks subintervals.
        st.nticks = d2l(st.ifreq / f + 0.5)
        // Raw and resampled intervals begin simultaneously once every mnticks
        // subintervals (an epoch).
        st.mnticks = st.mticks * st.nticks
        // gvtime is the number of subintervals from the beginning of the
        // current epoch to the next sample to be returned by getvec().
        st.gvtime = 0
        reloadGv()
        return 0
    }
    sig.ifreq = 0.0
    wfdb_error(cformat("setifreq: improper frequency %g (must be > 0)\n", f))
    return -1
}

/** `rgvstat = rgetvec(gv0); rgvstat = rgetvec(gv1); rgvtime = nticks;` */
private fun Wfdb.reloadGv() {
    sig.rgvstat = rgetvec(sig.gv0, 0)
    sig.rgvstat = rgetvec(sig.gv1, 0)
    sig.rgvtime = sig.nticks
}

/**
 * C `getifreq()`: the sampling frequency of the samples returned by getvec.
 *
 * Translation of the C function getifreq() (lib/signal.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.getifreq(): Double = if (sig.ifreq > 0.0) sig.ifreq else sig.sfreq

// ---------------------------------------------------------------------------
// Reading samples

/**
 * C `getvec(vector)`: reads the next sample of each input signal into
 * [vector] (one value per signal, in ADC units).
 *
 * Invalid or missing samples are [WFDB_INVALID_SAMPLE] unless the
 * [WFDB_GVPAD] mode is set (see [setgvmode]).
 *
 * Returns the number of input signals (> 0), or: 0 or -1 at the end of the
 * record (the contents of vector are then not valid), -3 at an unexpected
 * end of file (or on a decoding error), -4 on a checksum error (detected at
 * the end of the file).
 *
 * Translation of the C function getvec() (lib/signal.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.getvec(vector: IntArray): Int = getvecAt(vector, 0)

/** getvec into vector[off...]. */
private fun Wfdb.getvecAt(vector: IntArray, off: Int): Int {
    val need = vecNeed()
    if (vector.size - off < need) {
        val tmp = IntArray(need)
        val r = getvecImpl(tmp, 0)
        tmp.copyInto(vector, off, 0, vector.size - off)
        return r
    }
    return getvecImpl(vector, off)
}

private fun Wfdb.getvecImpl(vector: IntArray, off: Int): Int {
    val st = sig
    if (st.ifreq == 0.0 || st.ifreq == st.sfreq) return rgetvec(vector, off) // no resampling necessary
    // Resample the input.
    if (st.rgvtime > st.mnticks) {
        st.rgvtime -= st.mnticks
        st.gvtime -= st.mnticks
    }
    val nsig = maxOf(st.nvsig, st.nisig, 0)
    while (sig.gvtime > sig.rgvtime) {
        sig.gv1.copyInto(sig.gv0, 0, 0, nsig)
        sig.rgvstat = rgetvec(sig.gv1, 0)
        sig.rgvtime += sig.nticks
    }
    val s2 = sig
    val frac = s2.gvtime % s2.nticks
    for (i in 0 until nsig) {
        val a = s2.gv0[i]
        val b = s2.gv1[i]
        vector[off + i] = (a + frac * (b - a).toLong() / s2.nticks).toInt()
        s2.gv0[i] = b
    }
    s2.gvtime += s2.mticks
    return s2.rgvstat
}

/**
 * C `getframe(vector)`: reads the next frame: all the samples of every input
 * signal in it (spf samples of a signal with spf samples per frame), signal
 * after signal.
 *
 * Returns, as [getvec], the number of input signals, or a value <= 0 at the
 * end of the record or on an error.
 *
 * Translation of the C function getframe() (lib/signal.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.getframe(vector: IntArray): Int = getframeAt(vector, 0)

/** getframe into vector[off...]. */
private fun Wfdb.getframeAt(vector: IntArray, off: Int): Int {
    val need = vecNeed()
    if (vector.size - off < need) {
        val tmp = IntArray(need)
        val r = getframeImpl(tmp, 0)
        tmp.copyInto(vector, off, 0, vector.size - off)
        return r
    }
    return getframeImpl(vector, off)
}

private fun Wfdb.getframeImpl(vector: IntArray, off: Int): Int {
    var stat = -1
    if (sig.haveDsbuf) {
        // signals must be deskewed
        val ds = sig.dsbuf
        val tspf = sig.tspf
        val dsblen = sig.dsblen
        // First, obtain the samples needed.
        if (sig.dsbi < 0) {
            // dsbuf contents are invalid -- refill dsbuf
            var i = 0
            sig.dsbi = 0
            while (i < dsblen) {
                stat = getskewedframe(ds, i)
                if (stat < 0) break
                i += tspf
                sig.dsbi = i
            }
            sig.dsbi = 0
        } else {
            // replace oldest frame in dsbuf only
            stat = getskewedframe(ds, sig.dsbi)
            sig.dsbi += tspf
            if (sig.dsbi >= dsblen) sig.dsbi = 0
        }

        // Assemble the deskewed frame from the data in dsbuf.
        val st = sig
        var j = 0
        for (s in 0 until maxOf(st.nvsig, 0)) {
            var i = j + st.dsbi + st.vsd[s].skew * tspf
            if (i >= dsblen) i %= dsblen
            for (k in 0 until st.vsd[s].info.spf) {
                vector[off + j] = ds[i]
                j++
                i++
            }
        }
    } else {
        // no deskewing necessary
        stat = getskewedframe(vector, off)
    }
    sig.istime++
    return stat
}

/**
 * WFDB-x: reads up to n sample vectors (at most as many as fit in out from
 * off) at once, as whole frames, exactly as as many getvec calls would
 * (getskewedframe calls and istime if ispfmax < 2), and returns their
 * number (0 if the bulk path cannot be used for the next vector: the caller
 * then reads it frame by frame). Records of several sampling frequencies
 * (in high-resolution mode, from the start of a frame), the segments of
 * multi-segment records (mapped by sigmap if the layout varies) and null
 * signals of known length are read this way; the samples, checksums,
 * counts, gvc and the last frames are left as getvec leaves them. Only the
 * complete frames already in the input buffers are decoded: a frame that
 * crosses the end of a buffer (whose reading refills the buffer, as C
 * does), the frame at which a checksum is verified or a null signal ends,
 * the end of a file and a segment boundary go through getvec. The buffers
 * are therefore filled, and the files read, exactly as by the per-frame
 * path.
 */
private fun Wfdb.bulkFrames(out: IntArray, off: Int, n: Long): Int {
    val st = sig
    val nisig = st.nisig
    // No deskewing, no resampling; every signal of the layout read (or
    // mapped to the layout signals).
    if (st.bulkOff || n <= 0 || nisig == 0 || st.haveDsbuf || !(st.ifreq == 0.0 || st.ifreq == st.sfreq) ||
        (st.nvsig != nisig && st.needSigmap == 0) || st.isd.size < nisig
    ) {
        return 0
    }
    val highres = st.ispfmax > 1 && (st.gvmode and WFDB_HIGHRES) == WFDB_HIGHRES
    if (highres && st.gvc < st.ispfmax) return 0
    // The groups: one format each (0: null signals, no file), at the start
    // of a packed unit; the alignment period (in frames) keeps each on
    // whole packed units.
    val groups = ArrayList<BulkGroup>()
    var period = 1
    var pos = 0
    var s = 0
    while (s < nisig) {
        val fmt = st.isd[s].info.fmt
        val g = st.isd[s].info.group
        val ns = if (fmt == 0) 1 else (bulkUnit(fmt) ?: return 0)[1]
        var e = s
        var gfl = 0
        while (e < nisig && st.isd[e].info.group == g) {
            val info = st.isd[e].info
            if (info.fmt != fmt || info.spf < 1 || (fmt == 0 && info.nsamp <= 0)) return 0
            gfl += info.spf
            e++
        }
        if (g < 0 || g >= st.igd.size) return 0
        val ig = st.igd[g]
        if (ig.initialSkip != 0) return 0
        if (fmt == 0) {
            if (ig.stat <= 0) return 0
        } else {
            if (ig.seek != 1 || ig.fp == null || ig.count != 0 || ig.flac != null) return 0
            val p = ns / gcd(gfl % ns, ns)
            period = period / gcd(period, p) * p
        }
        groups.add(BulkGroup(s, e, fmt, gfl, pos))
        pos += gfl
        s = e
    }
    val flen = pos
    val tlen = maxOf(st.tspf, 0)
    val needSigmap = st.needSigmap != 0
    val frames = st.ispfmax < 2
    val nv = maxOf(st.nvsig, 0)
    // Vectors per frame, and values per vector.
    val per = if (highres) st.ispfmax else 1
    val vlen = if (frames) tlen else nv
    if (vlen == 0 || flen != st.framelen || (!needSigmap && flen > tlen)) return 0
    var nf = minOf(n / per, ((out.size - off) / (vlen * per)).toLong())
    // Not the frame at which a checksum is verified or a null signal ends
    // (nor any after it).
    for (k in 0 until nisig) {
        val ns = st.isd[k].info.nsamp
        if (ns > 0 && nf >= ns) nf = ns - 1
    }
    // Only the complete frames in every buffer.
    for (gr in groups) {
        if (gr.fmt == 0) continue
        val unit = bulkUnit(gr.fmt)!!
        val u = period * gr.gfl * unit[0] / unit[1]
        val ig = st.igd[st.isd[gr.s0].info.group]
        nf = minOf(nf, (maxOf(ig.be - ig.bp, 0) / u * period).toLong())
    }
    nf -= nf % period
    if (nf <= 0) return 0
    val m = nf.toInt()
    if (st.istime == 0L) for (k in 0 until nisig) st.isd[k].samp = st.isd[k].info.initval
    val pad = (st.gvmode and WFDB_GVPAD) != 0
    // The frames as getskewedframe reads them (flen samples each) go into
    // bulkIn if the layout varies; otherwise straight into the frames as
    // getframe gives them (tlen samples each): out if they are the vectors
    // of getvec (ispfmax < 2), else bulkFr.
    if (needSigmap && st.bulkIn.size < m * flen) st.bulkIn = IntArray(m * flen)
    if (!frames && st.bulkFr.size < m * tlen) st.bulkFr = IntArray(m * tlen)
    val inb = if (needSigmap) st.bulkIn else if (frames) out else st.bulkFr
    val ioff = if (frames && !needSigmap) off else 0
    val istride = if (needSigmap) flen else tlen
    for (gr in groups) {
        if (gr.fmt == 0) {
            // null signals
            var c = ioff + gr.pos
            for (k in gr.s0 until gr.s1) {
                val isv = st.isd[k]
                val spf = isv.info.spf
                val v = if (pad) isv.samp else WFDB_INVALID_SAMPLE
                var b = c
                for (f in 0 until m) {
                    inb.fill(v, b, b + spf)
                    b += istride
                }
                isv.info.cksum -= v * (m * spf)
                c += spf
            }
            continue
        }
        val fmt = gr.fmt
        val unit = bulkUnit(fmt)!!
        val gfl = gr.gfl
        val ig = st.igd[st.isd[gr.s0].info.group]
        // As getskewedframe does with each sample: signal by signal, in
        // tiles of frames (a whole number of packed units) decoded into
        // bulkRaw, which stays in the cache.
        val inval = fmtMin(fmt)
        val tile = BULK_TILE - BULK_TILE % period
        if (st.bulkRaw.size < tile * gfl) st.bulkRaw = IntArray(tile * gfl)
        val raw = st.bulkRaw
        val nsg = gr.s1 - gr.s0
        val samps = IntArray(nsg) { st.isd[gr.s0 + it].samp }
        val cks = IntArray(nsg) { st.isd[gr.s0 + it].info.cksum }
        var bp = ig.bp
        var f0 = 0
        while (f0 < m) {
            val nfr = minOf(m - f0, tile)
            val cnt = nfr * gfl
            bulkDecodeFlat(fmt, ig.buf, bp, cnt, raw, 0)
            bp += cnt / unit[1] * unit[0]
            var col = 0
            for (j in 0 until nsg) {
                val spf = st.isd[gr.s0 + j].info.spf
                var samp = samps[j]
                var cksum = cks[j]
                var r = col
                var o = ioff + gr.pos + col + f0 * istride
                if (spf == 1) {
                    if (fmt == 8) {
                        for (f in 0 until nfr) {
                            samp += raw[r]
                            inb[o] = samp
                            cksum -= samp
                            r += gfl
                            o += istride
                        }
                    } else {
                        for (f in 0 until nfr) {
                            val v = raw[r]
                            cksum -= v
                            if (v == inval) {
                                inb[o] = if (pad) samp else WFDB_INVALID_SAMPLE
                            } else {
                                samp = v
                                inb[o] = v
                            }
                            r += gfl
                            o += istride
                        }
                    }
                } else {
                    for (f in 0 until nfr) {
                        for (q in 0 until spf) {
                            val v = raw[r + q]
                            if (fmt == 8) {
                                samp += v
                                inb[o + q] = samp
                                cksum -= samp
                            } else {
                                cksum -= v
                                if (v == inval) {
                                    inb[o + q] = if (pad) samp else WFDB_INVALID_SAMPLE
                                } else {
                                    samp = v
                                    inb[o + q] = v
                                }
                            }
                        }
                        r += gfl
                        o += istride
                    }
                }
                samps[j] = samp
                cks[j] = cksum
                col += spf
            }
            f0 += nfr
        }
        ig.bp = bp
        for (j in 0 until nsg) {
            st.isd[gr.s0 + j].samp = samps[j]
            st.isd[gr.s0 + j].info.cksum = cks[j]
        }
    }
    if (!needSigmap && flen < tlen) {
        for (f in 0 until m) inb.fill(WFDB_INVALID_SAMPLE, ioff + f * tlen + flen, ioff + (f + 1) * tlen)
    }
    for (k in 0 until nisig) {
        val isv = st.isd[k]
        if (isv.info.nsamp > 0) {
            isv.info.nsamp -= m
        } else if (isv.info.nsamp == 0L) {
            isv.info.nsamp = -1
        }
    }
    st.istime += m
    st.bulkVectors += (m * per).toLong()
    // The frames as getframe gives them, mapped to the layout signals.
    if (needSigmap) {
        val fr = if (frames) out else st.bulkFr
        val foff = if (frames) off else 0
        for (f in 0 until m) sigmap(fr, foff + f * tlen, st.bulkIn, f * flen)
        // (the last frame read, as getskewedframe leaves it)
        st.bulkIn.copyInto(st.ovec, 0, (m - 1) * flen, (m - 1) * flen + minOf(flen, st.ovec.size))
    }
    if (frames) return m

    // The sample vectors of getvec, as rgetvec makes them.
    val fbuf = st.bulkFr
    if (!highres) {
        // (signal by signal)
        var tp0 = 0
        for (k in 0 until nv) {
            val sf = st.vsd[k].info.spf
            var tp = tp0
            var o = off + k
            if (sf == 1) {
                for (f in 0 until m) {
                    out[o] = fbuf[tp]
                    tp += tlen
                    o += nv
                }
            } else {
                for (f in 0 until m) {
                    out[o] = meansamp(fbuf, tp, sf)
                    tp += tlen
                    o += nv
                }
            }
            tp0 += sf
        }
    } else {
        // The column of the frame giving signal k in vector j of each frame:
        // col[j * nv + k].
        val ispfmax = st.ispfmax
        val col = IntArray(per * nv)
        var tp = 0
        for (k in 0 until nv) {
            val v = st.vsd[k]
            val sf = v.info.spf
            v.gvindex = 0
            v.gvcount = -ispfmax
            for (j in 0 until per) {
                if (j > 0) {
                    v.gvcount += sf
                    if (v.gvcount >= 0) {
                        v.gvindex++
                        v.gvcount -= ispfmax
                    }
                }
                col[j * nv + k] = tp + v.gvindex
            }
            tp += sf
        }
        var o = off
        for (f in 0 until m) {
            val base = f * tlen
            for (c in col) out[o++] = fbuf[base + c]
        }
        st.gvc = per
    }
    st.rgetvecStat = nisig
    // (the last frame, as rgetvec leaves it)
    fbuf.copyInto(st.tvector, 0, (m - 1) * tlen, (m - 1) * tlen + minOf(tlen, st.tvector.size))
    return m * per
}

/**
 * WFDB-x: turns the bulk path of [getvecs] on or off (it is on by default)
 * and returns the previous setting. The results are the same either way;
 * this is for testing the bulk path against the per-frame path.
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun Wfdb.wfdbx_bulk_read(on: Boolean): Boolean {
    val previous = !sig.bulkOff
    sig.bulkOff = !on
    return previous
}

/** WFDB-x: the number of sample vectors read by the bulk path of [getvecs] so far (for tests). */
internal fun Wfdb.wfdbxBulkVectors(): Long = sig.bulkVectors

/**
 * WFDB-x: the state of the input signals as text: istime, gvc, and each
 * signal's last sample, checksum and remaining samples (for tests).
 */
internal fun Wfdb.wfdbxInputState(): String {
    val st = sig
    val sb = StringBuilder("${st.istime} ${st.gvc}")
    for (k in 0 until minOf(st.nisig, st.isd.size)) {
        val isv = st.isd[k]
        sb.append("; ${isv.samp} ${isv.info.cksum} ${isv.info.nsamp}")
    }
    return sb.toString()
}

/** The result of [getvecs_status]: the number of vectors read and the status of the last getvec. */
data class GetvecsResult(
    /** The number of vectors read (>= 0), or the negative status of getvec if the first read failed. */
    val count: Long,
    /** The value returned by the last getvec (see [getvecs_status]). */
    val status: Int,
)

/**
 * Reads up to [n] sample vectors, as n calls of [getvec] would, into [out]
 * (vector after vector, one value per signal in each). Not part of the C
 * library; faster than calling getvec in a loop (WFDB-x: where no frame
 * needs special handling, it decodes the complete frames in the input
 * buffers at once, with the same results).
 *
 * Returns the number of vectors read (>= 0; less than n at the end of the
 * record), or the negative status of getvec if the first read failed.
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun Wfdb.getvecs(out: IntArray, n: Long): Long = getvecs_status(out, n).count

/**
 * As [getvecs], also returning the value returned by the last getvec call:
 * the negative status of the first vector that could not be read (-1 at the
 * end of the data, < -1 on an error, e.g. -3 for an unexpected end of
 * file), or the number of values per vector if all n were read (0 if n <=
 * 0). Not part of the C library.
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun Wfdb.getvecs_status(out: IntArray, n: Long): GetvecsResult = getvecsStatusAt(out, 0, n)

/** [getvecs_status] writing into [out] from index [off] (WFDB-x, for readRecord). */
internal fun Wfdb.getvecsStatusAt(out: IntArray, off: Int, n: Long): GetvecsResult {
    if (n <= 0) return GetvecsResult(0, 0)
    var stat = 0
    var k = 0L
    val st = sig
    if (!st.haveDsbuf && st.ispfmax < 2 && (st.ifreq == 0.0 || st.ifreq == st.sfreq)) {
        // Fast path: getvec is getframe (getskewedframe until a segment that
        // needs deskewing opens).
        val stride = maxOf(st.tspf, 0)
        val need = vecNeed()
        var pos = off
        while (k < n) {
            // WFDB-x: as many frames as possible at once (see bulkFrames)
            val m = bulkFrames(out, pos, n - k)
            if (m > 0) {
                stat = sig.nisig
                pos += m * stride
                k += m
                continue
            }
            if (pos + need > out.size) {
                // (the caller's array is too short for another vector)
                val tmp = IntArray(need)
                stat = getframeImpl(tmp, 0)
                val mm = minOf(maxOf(out.size - pos, 0), stride)
                if (stat == -4) tmp.copyInto(out, pos, 0, mm) // (valid data with a checksum mismatch)
                if (stat < 0) break
                tmp.copyInto(out, pos, 0, mm)
                k++
                if (mm < stride) break
                pos += stride
                continue
            }
            // (getframe, not getskewedframe: a segment opened by an earlier
            // frame may need deskewing)
            stat = getframeImpl(out, pos)
            if (stat < 0) break
            pos += stride
            k++
        }
    } else {
        // getvec returns one sample per signal
        var stride = maxOf(st.nvsig, 0)
        if (st.ifreq != 0.0 && st.ifreq != st.sfreq && st.nisig > st.nvsig) stride = st.nisig
        var pos = off
        while (k < n) {
            // WFDB-x: as many vectors as possible at once (see bulkFrames;
            // none if the input is resampled or deskewed)
            val m = bulkFrames(out, pos, n - k)
            if (m > 0) {
                stat = sig.nisig
                pos += m * stride
                k += m
                continue
            }
            if (pos + stride > out.size) break
            stat = getvecAt(out, pos)
            if (stat < 0) break
            pos += stride
            k++
        }
    }
    return if (k == 0L && stat < 0) GetvecsResult(stat.toLong(), stat) else GetvecsResult(k, stat)
}

// ---------------------------------------------------------------------------
// Writing samples

/**
 * C `putvec(vector)`: writes a frame to the output signals: one sample (in
 * ADC units) of each signal, or spf samples of a signal with spf samples
 * per frame.
 *
 * Returns the number of output signals (> 0), or: 0 if the slew rate is too
 * high for a signal (difference formats only; the level is corrected
 * later), -1 on a write error.
 *
 * Translation of the C function putvec() (lib/signal.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.putvec(vector: IntArray): Int {
    val st = sig
    var stat = st.nosig
    val obsize = st.obsize
    var errs: ArrayList<Int>? = null
    var vi = 0
    for (s in 0 until st.nosig) {
        val os = st.osd[s]
        val og = st.ogd[os.info.group]
        if (os.info.nsamp == 0L) {
            os.info.initval = vector[vi]
            os.samp = vector[vi]
        }
        os.info.nsamp++
        val fmt = os.info.fmt
        for (c in 0 until os.info.spf) {
            // Replace invalid samples with lowest possible value for the
            // format (formats 0 and 8 keep WFDB_INVALID_SAMPLE).
            var samp = vector[vi]
            if (samp == WFDB_INVALID_SAMPLE && fmt != 0 && fmt != 8) samp = fmtMin(fmt)
            when (fmt) {
                0 -> os.samp = samp // null signal (do not write)
                16 -> {
                    og.w16(samp, obsize); os.samp = samp
                }
                61 -> {
                    og.w61(samp, obsize); os.samp = samp
                }
                80 -> {
                    og.w80(samp, obsize); os.samp = samp
                }
                160 -> {
                    og.w160(samp, obsize); os.samp = samp
                }
                212 -> {
                    og.w212(samp, obsize); os.samp = samp
                }
                310 -> {
                    og.w310(samp, obsize); os.samp = samp
                }
                311 -> {
                    og.w311(samp, obsize); os.samp = samp
                }
                24 -> {
                    og.w24(samp, obsize); os.samp = samp
                }
                32 -> {
                    og.w32(samp, obsize); os.samp = samp
                }
                508, 516, 524 -> {
                    if (og.flacPutsamp(samp, fmt) < 0) stat = -1
                    os.samp = samp
                }
                else -> {
                    // 8-bit first differences
                    // Handle large slew rates sensibly.
                    var dif = samp - os.samp
                    if (dif < -128) {
                        dif = -128
                        stat = 0
                    } else if (dif > 127) {
                        dif = 127
                        stat = 0
                    }
                    os.samp += dif
                    og.w8(dif, obsize)
                }
            }
            if (og.fp?.error() == true) {
                if (errs == null) errs = ArrayList()
                errs.add(s)
                stat = -1
            } else {
                os.info.cksum += os.samp
            }
            vi++
        }
    }
    st.ostime++
    if (errs != null) for (s in errs) wfdb_error(cformat("putvec: write error in signal %d\n", s))
    return stat
}

/**
 * WFDB-x (for writeRecord): writes [nframes] frames held one after the
 * other in [x] (each a vector of [putvec]) to the output signals, with the
 * same result as putvec called for each frame. Returns the status of the
 * last putvec (0 if [nframes] is 0).
 *
 * When all output signals are in one signal file of one of the formats
 * 16, 61, 80, 160, 212, 310, 311, 24 and 32, the frames are encoded in one
 * loop (the per-frame work of putvec, and its checks of each sample,
 * were half of the time of writeRecord), byte for byte as putvec encodes
 * them; otherwise putvec is called for each frame. [bulkPutOff] turns the
 * loop off (for the tests).
 */
internal fun Wfdb.putframes(x: IntArray, nframes: Int): Int {
    if (nframes <= 0) return 0
    val st = sig
    val fl = x.size / nframes
    val nosig = st.nosig
    var fast = !bulkPutOff && nosig > 0 && st.nogroup == 1 && st.ogd.isNotEmpty() && st.ogd[0].fp != null &&
        st.ogd[0].flac == null
    val fmt = if (fast) st.osd[0].info.fmt else 0
    if (fast) {
        var tspf = 0
        for (s in 0 until nosig) {
            val info = st.osd[s].info
            if (info.fmt != fmt || info.group != 0 || info.spf < 1) fast = false
            tspf += info.spf
        }
        fast = fast && tspf == fl && fmt in intArrayOf(16, 61, 80, 160, 212, 310, 311, 24, 32)
    }
    if (!fast) {
        val v = IntArray(fl)
        var stat = 0
        for (i in 0 until nframes) {
            x.copyInto(v, 0, i * fl, i * fl + fl)
            stat = putvec(v)
        }
        return stat
    }
    val og = st.ogd[0]
    val ob = st.obsize
    val inv = fmtMin(fmt)
    val spf = IntArray(nosig) { st.osd[it].info.spf }
    val cks = IntArray(nosig)
    val lastv = IntArray(nosig)
    // (the first frame: the initial values, as putvec sets them)
    var c0 = 0
    for (s in 0 until nosig) {
        val os = st.osd[s]
        if (os.info.nsamp == 0L) os.info.initval = x[c0]
        c0 += spf[s]
    }
    var p = 0
    for (i in 0 until nframes) {
        for (s in 0 until nosig) {
            var ck = cks[s]
            var v = 0
            for (j in 0 until spf[s]) {
                v = x[p++]
                if (v == WFDB_INVALID_SAMPLE) v = inv
                when (fmt) {
                    16 -> og.w16(v, ob)
                    61 -> og.w61(v, ob)
                    80 -> og.w80(v, ob)
                    160 -> og.w160(v, ob)
                    212 -> og.w212(v, ob)
                    310 -> og.w310(v, ob)
                    311 -> og.w311(v, ob)
                    24 -> og.w24(v, ob)
                    else -> og.w32(v, ob)
                }
                ck += v
            }
            cks[s] = ck
            lastv[s] = v
        }
    }
    var stat = nosig
    if (og.fp?.error() == true) {
        wfdb_error(cformat("putvec: write error in signal %d\n", 0))
        stat = -1
    }
    for (s in 0 until nosig) {
        val os = st.osd[s]
        os.info.nsamp += nframes
        os.info.cksum += cks[s]
        os.samp = lastv[s]
    }
    st.ostime += nframes
    return stat
}

/** WFDB-x (for the tests): whether [putframes] calls putvec for each frame. */
internal var bulkPutOff = false

// ---------------------------------------------------------------------------
// Positioning

/**
 * C `isigsettime(t)`: positions all input signals so that the next sample
 * read is sample number [t]. Returns 0 on success, or -1 if t is beyond the
 * end of the record or the signal files cannot be repositioned.
 *
 * Translation of the C function isigsettime() (lib/signal.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.isigsettime(t: Long): Int {
    val st = sig
    // Return immediately if no seek is needed.
    if (st.nisig == 0) return 0
    if (st.ifreq <= 0.0) {
        val curtime = if ((st.gvmode and WFDB_HIGHRES) == 0 || st.ispfmax < 2) {
            st.istime
        } else {
            (st.istime - 1) * st.ispfmax + st.gvc
        }
        if (t == curtime) return 0
    }
    var stat = 0
    var g = 1
    while (g < sig.nigroup) {
        stat = isgsettime(g, t)
        if (stat < 0) break
        g++
    }
    // Seek on signal group 0 last (since doing so updates istime and would
    // confuse isgsettime if done first).
    if (stat == 0) stat = isgsettime(0, t)
    return stat
}

/**
 * C `isgsettime(g, t)`: as [isigsettime], for the signals of signal group
 * [g] only. Returns 0 on success, -1 if t is beyond the end of the record
 * or the signal files cannot be repositioned, -2 if g is not a valid signal
 * group.
 *
 * Translation of the C function isgsettime() (lib/signal.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.isgsettime(g: Int, t0: Long): Int {
    var t = t0
    var trem = 0
    // Handle negative arguments as equivalent positive arguments.
    if (t < 0) {
        if (t < -WFDB_TIME_MAX) return seekerr(g)
        t = -t
    }

    // Convert t to raw sample intervals if we are resampling.
    val st = sig
    if (st.ifreq > 0.0) {
        val tt = t * st.sfreq / st.ifreq
        if (tt > WFDB_TIME_MAX.toDouble()) return seekerr(g)
        t = d2l(tt)
    }

    // If we're in WFDB_HIGHRES mode, convert t from samples to frames, and
    // save the remainder (if any) in trem.
    if (st.gvmode and WFDB_HIGHRES != 0) {
        val m = maxOf(st.ispfmax.toLong(), 1L)
        trem = (t % m).toInt()
        t /= m
    }

    // Mark the contents of the deskewing buffer (if any) as invalid.
    st.dsbi = -1

    val stat = isgsetframe(g, t)
    if (stat == 0 && g == 0) {
        while (trem > 0) {
            trem--
            val need = vecNeed()
            if (sig.uvector.size < need) sig.uvector = sig.uvector.copyOf(need)
            if (rgetvec(sig.uvector, 0) < 0) return seekerr(g)
        }
        if (sig.ifreq > 0.0 && sig.ifreq != sig.sfreq) {
            sig.gvtime = 0
            reloadGv()
        }
    }
    return stat
}

/**
 * C `tnextvec(s, t)`: returns the time of the next valid sample of input
 * signal [s] at or after [t], positioning the input signals there; a
 * negative value (-1) at the end of the record or on an error.
 *
 * Translation of the C function tnextvec() (lib/signal.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.tnextvec(s: Int, t0: Long): Long {
    var t = t0
    var stat = 0
    var vv = IntArray(maxOf(vecNeed(), 1))

    if (sig.inMsrec != 0 && sig.needSigmap != 0) {
        // variable-layout multi-segment record
        if (!uless(s, sig.nvsig)) {
            wfdb_error(cformat("nextvect: illegal signal number %d\n", s))
            return -1
        }
        // Go to the start (t) if not already there.
        if (t != sig.istime && isigsettime(t) < 0) return -1
        while (stat >= 0) {
            val p = ostr(sig.vsd[s].info.desc)
            val seg = sig.segarray[sig.segp]
            val tf = seg.samp0 + seg.nsamp
            // Check if signal s is available in the current segment.
            var found = false
            for (k in 0 until sig.nisig) {
                val d = sig.isd[k].info.desc
                if (d != null && cstr(d).contentEquals(p)) {
                    found = true
                    break
                }
            }
            if (found) {
                // The current segment contains the desired signal. Read
                // samples until we find a valid one or reach the end of the
                // segment.
                while (t <= tf) {
                    val need = vecNeed()
                    if (vv.size < need) vv = vv.copyOf(need)
                    stat = getvec(vv)
                    if (stat <= 0) break
                    if (vv[s] != WFDB_INVALID_SAMPLE) {
                        isigsettime(t)
                        return t
                    }
                    t++
                }
                if (stat < 0) return -1
            }
            // Go on to the next segment.
            if (t != tf) {
                t = tf
                stat = isigsettime(t)
            }
        }
    } else {
        // single-segment or fixed-layout multi-segment record
        // Go to the start (t) if not already there.
        if (t != sig.istime && isigsettime(t) < 0) return -1
        if (!uless(s, sig.nisig)) {
            wfdb_error(cformat("nextvect: illegal signal number %d\n", s))
            return -1
        }
        while (true) {
            val need = vecNeed()
            if (vv.size < need) vv = vv.copyOf(need)
            stat = getvec(vv)
            if (stat <= 0) break
            // Read samples until we find a valid one or reach the end of the
            // record.
            if (vv[s] != WFDB_INVALID_SAMPLE) {
                isigsettime(t)
                return t
            }
            t++
        }
    }
    // Error or end of record without finding another sample of signal s.
    return stat.toLong()
}

/**
 * C `setibsize(n)`: sets the default input buffer size (in bytes) of signal
 * files opened later. Returns the new size (n, or the default size if n is
 * 0), or: -1 if input signals are open (the size cannot be changed then),
 * -2 if n is negative.
 *
 * Translation of the C function setibsize() (lib/signal.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.setibsize(n: Int): Int {
    if (sig.nisig != 0) {
        wfdb_error("setibsize: can't change buffer size after isigopen\n")
        return -1
    }
    if (n < 0) {
        wfdb_error(cformat("setibsize: illegal buffer size %d\n", n))
        return -2
    }
    val m = if (n == 0) WFDB_BUFSIZ else n
    sig.ibsize = m
    return m
}

/**
 * C `setobsize(n)`: sets the default output buffer size (in bytes) of
 * signal files opened later. Returns the new size (n, or the default size if
 * n is 0), or: -1 if output signals are open (the size cannot be changed
 * then), -2 if n is negative.
 *
 * Translation of the C function setobsize() (lib/signal.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.setobsize(n: Int): Int {
    if (sig.nosig != 0) {
        wfdb_error("setobsize: can't change buffer size after osig[f]open\n")
        return -1
    }
    if (n < 0) {
        wfdb_error(cformat("setobsize: illegal buffer size %d\n", n))
        return -2
    }
    val m = if (n == 0) WFDB_BUFSIZ else n
    sig.obsize = m
    return m
}

// ---------------------------------------------------------------------------
// Header writing

/**
 * WFDB-x: [name] as written into the header of [record]: outside legacy
 * mode, names are written relative to the header's directory (where the
 * reader looks for them): the directory part of record is removed from name
 * when name begins with it.
 */
private fun Wfdb.heaName(record: ByteArray, name: ByteArray): ByteArray {
    if (legacy) return name
    val k = record.lastIndexOf('/'.code.toByte())
    return if (k >= 0 && name.startsWith(record.copyOf(k + 1))) name.copyOfRange(k + 1, name.size) else name
}

private fun Wfdb.closeOheader() {
    val oh = sig.oheader ?: return
    sig.oheader = null
    oh.close()
    if (sig.outinfo == OUTINFO_HEADER) sig.outinfo = OUTINFO_NONE
}

/**
 * C `newheader(record)`: writes the header file record.hea for the open
 * output signals (with the sampling frequency, base time and number of
 * samples written so far). Returns 0 on success, or a negative value if the
 * header cannot be created (see [setheader]).
 *
 * Translation of the C function newheader() (lib/signal.c, WFDB 10.7.0): same
 * arguments and results. Differences: a header written under a path names the
 * record and its signal files relative to its own directory, and only the
 * record's own name (the last component) is checked; see docs/DIVERGENCES.md.
 */
fun Wfdb.newheader(record: ByteArray): Int {
    val rec = wfdb_striphea(record)
    val n = sig.nosig
    val osi = Array(n) { sig.osd[it].info.copy() }
    return setheader(rec, osi, n)
}

/** [newheader] with the record name as a string. */
fun Wfdb.newheader(record: String): Int = newheader(record.latin1())

/**
 * C `setheader(record, siarray, nsig)`: writes the header file record.hea
 * describing the [nsig] signals of [siarray].
 *
 * As in C, the units and desc strings of siarray are truncated at their
 * first space or line ending (C applies strtok to them).
 *
 * Returns 0 on success, or -1 if the header file cannot be created (or the
 * record name is illegal).
 *
 * Translation of the C function setheader() (lib/signal.c, WFDB 10.7.0): same
 * arguments and results. Differences: a header written under a path names the
 * record and its signal files relative to its own directory, and only the
 * record's own name (the last component) is checked; see docs/DIVERGENCES.md.
 */
fun Wfdb.setheader(record0: ByteArray, siarray: Array<Siginfo>, nsig0: Int): Int {
    // If another output header file was opened, close it.
    closeOheader()

    // Remove trailing .hea, if any, from record name.
    val record = wfdb_striphea(record0)

    // Quit (with message from wfdb_checkname) if name is illegal.
    if (wfdb_checkname(record, "record") != 0) return -1

    // Try to create the header file.
    val oh = wfdb_open("hea".latin1(), record, WFDB_WRITE)
    if (oh == null) {
        wfdb_error(cformat("newheader: can't create header for record %s\n", record))
        return -1
    }
    sig.oheader = oh
    val nsig = if (uless(siarray.size, nsig0)) siarray.size else nsig0

    // Write the general information line.
    val st = sig
    val out = ByteVec(256)
    out.addAll(cformat("%s %d %.12g", heaName(record, record), nsig, st.ffreq))
    if ((st.cfreq > 0.0 && st.cfreq != st.ffreq) || st.bcount != 0.0) {
        out.addAll(cformat("/%.12g", st.cfreq))
        if (st.bcount != 0.0) out.addAll(cformat("(%.12g)", st.bcount))
    }
    out.addAll(cformat(" %ld", if (nsig > 0) siarray[0].nsamp else 0L))
    if (st.btime != 0L || st.bdate != 0L) {
        if (st.btime == 0L) {
            out.addString(" 0:00")
        } else if (st.btime % 1000 == 0L) {
            out.add(' '.code)
            out.addAll(ftimstr(st.btime, 1000.0))
        } else {
            out.add(' '.code)
            out.addAll(fmstimstr(st.btime, 1000.0))
        }
    }
    if (st.bdate != 0L) out.addAll(datstr(st.bdate))
    out.addString("\r\n")

    // Write a signal specification line for each signal.
    val fnames = Array(nsig) { s -> siarray[s].fname?.let { heaName(record, cstr(it)) } }
    for (s in 0 until nsig) {
        val si = siarray[s]
        out.addAll(cformat("%s %d", fnames[s], si.fmt))
        if (si.spf > 1) out.addAll(cformat("x%d", si.spf))
        if (s < st.osd.size && st.osd[s].skew != 0) out.addAll(cformat(":%d", st.osd[s].skew * si.spf))
        val gstart = if (s < st.osd.size && st.osd[s].info.group >= 0 && st.osd[s].info.group < st.ogd.size) {
            st.ogd[st.osd[s].info.group].start
        } else {
            0L
        }
        if (gstart != 0L) {
            out.addAll(cformat("+%ld", gstart))
        } else if (st.prologBytes != 0L) {
            out.addAll(cformat("+%ld", st.prologBytes))
        }
        out.addAll(cformat(" %.12g", si.gain))
        if (si.baseline != si.adczero) out.addAll(cformat("(%d)", si.baseline))
        val u = si.units
        if (u != null) {
            val (p, rest) = strtokInplace(u, " \t\n\r")
            si.units = rest
            if (p != null) {
                out.add('/'.code)
                out.addAll(p)
            }
        }
        out.addAll(cformat(" %d %d %d %d %d", si.adcres, si.adczero, si.initval, (si.cksum and 0xffff).toShort().toInt(), si.bsize))
        val d = si.desc
        if (d != null) {
            val (p, rest) = strtokInplace(d, "\n\r")
            si.desc = rest
            if (p != null) {
                out.add(' '.code)
                out.addAll(p)
            }
        }
        out.addString("\r\n")
    }
    oh.write(out.bytes, 0, out.size)
    oh.flush()
    st.prologBytes = 0
    return 0
}

/** [setheader] with the record name as a string. */
fun Wfdb.setheader(record: String, siarray: Array<Siginfo>, nsig: Int): Int = setheader(record.latin1(), siarray, nsig)

/**
 * C `getseginfo(&sarray)`: the number of segments of the open multi-segment
 * record (0 if it is not one). If [sarray] is not null, it receives a copy
 * of the segment table (it is cleared first; it stays empty if there is
 * none).
 *
 * Translation of the C function getseginfo() (lib/signal.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.getseginfo(sarray: MutableList<Seginfo>?): Int {
    if (sarray != null) {
        sarray.clear()
        if (sig.haveSegarray) for (sg in sig.segarray) sarray.add(sg.copy())
    }
    return sig.segments
}

/**
 * C `setmsheader(record, segment_names, nsegments)`: writes the header of a
 * multi-segment record made of the existing records [segmentNames].
 *
 * Returns 0 on success, or: -1 if the record name is illegal, there are no
 * segments, or the header cannot be written; -2 if a segment name is too
 * long; -3 if a segment is itself a multi-segment record or its header
 * cannot be read; -4 if a segment length is unspecified, or the segments
 * differ in number of signals or sampling frequency.
 *
 * Translation of the C function setmsheader() (lib/signal.c, WFDB 10.7.0): same
 * arguments and results. Differences: a header written under a path names the
 * record and its segments relative to its own directory, and only the record's
 * own name (the last component) is checked; see docs/DIVERGENCES.md.
 */
fun Wfdb.setmsheader(record0: ByteArray, segmentNames: Array<ByteArray>, nsegments0: Int): Int {
    val oldInMsrec = sig.inMsrec
    var msfreq = 0.0
    var mscfreq = 0.0
    var msbcount = 0.0
    var nsig = 0

    isigclose() // close any open input signals

    // If another output header file was opened, close it.
    closeOheader()

    // Remove trailing .hea, if any, from record name.
    val record = wfdb_striphea(record0)

    // Quit (with message from wfdb_checkname) if name is illegal.
    if (wfdb_checkname(record, "record") != 0) return -1

    if (nsegments0 < 1) {
        wfdb_error("setmsheader: record must contain at least one segment\n")
        return -1
    }
    val nsegments = minOf(nsegments0, segmentNames.size)

    val ns = LongArray(nsegments)
    for (i in 0 until nsegments) {
        val name = cstr(segmentNames[i])
        if (name.size > WFDB_MAXRNL) {
            wfdb_error(cformat("setmsheader: `%s' is too long for a segment name in record %s\n", name, record))
            return -2
        }
        sig.inMsrec = 1
        sig.nsamples = 0
        sig.userSegments = true // WFDB-x: names given by the caller
        val n = readheader(name)
        sig.userSegments = false
        sig.inMsrec = oldInMsrec
        if (n < 0) {
            wfdb_error(cformat("setmsheader: can't read segment %s header\n", name))
            return -3
        }
        ns[i] = sig.nsamples
        if (ns[i] <= 0) {
            wfdb_error(cformat("setmsheader: length of segment %s must be specified\n", name))
            return -4
        }
        val st = sig
        if (i == 0) {
            nsig = n
            msfreq = st.ffreq
            mscfreq = st.cfreq
            msbcount = st.bcount
            st.msbtime = st.btime
            st.msbdate = st.bdate
            st.msnsamples = ns[i]
        } else {
            if (nsig != n) {
                wfdb_error(cformat("setmsheader: incorrect number of signals in segment %s\n", name))
                return -4
            }
            if (msfreq != st.ffreq) {
                wfdb_error(cformat("setmsheader: incorrect sampling frequency in segment %s\n", name))
                return -4
            }
            st.msnsamples += ns[i]
        }
    }

    // Try to create the header file.
    val oh = wfdb_open("hea".latin1(), record, WFDB_WRITE)
    if (oh == null) {
        wfdb_error(cformat("setmsheader: can't create header file for record %s\n", record))
        return -1
    }
    sig.oheader = oh

    // Write the first line of the master header.
    val st = sig
    val out = ByteVec(256)
    out.addAll(cformat("%s/%u %d %.12g", heaName(record, record), nsegments, nsig, msfreq))
    if ((mscfreq > 0.0 && mscfreq != msfreq) || msbcount != 0.0) {
        out.addAll(cformat("/%.12g", mscfreq))
        if (msbcount != 0.0) out.addAll(cformat("(%.12g)", msbcount))
    }
    out.addAll(cformat(" %lld", st.msnsamples))
    if (st.msbtime != 0L || st.msbdate != 0L) {
        out.add(' '.code)
        if (st.msbtime % 1000 == 0L) out.addAll(ftimstr(st.msbtime, 1000.0)) else out.addAll(fmstimstr(st.msbtime, 1000.0))
    }
    if (st.msbdate != 0L) out.addAll(datstr(st.msbdate))
    out.addString("\r\n")

    // Write a line for each segment.
    for (i in 0 until nsegments) out.addAll(cformat("%s %lld\r\n", heaName(record, cstr(segmentNames[i])), ns[i]))
    oh.write(out.bytes, 0, out.size)
    return 0
}

/** [setmsheader] with strings. */
fun Wfdb.setmsheader(record: String, segmentNames: Array<String>, nsegments: Int): Int =
    setmsheader(record.latin1(), Array(segmentNames.size) { segmentNames[it].latin1() }, nsegments)

// ---------------------------------------------------------------------------
// Skew and prolog

/**
 * C `wfdbgetskew(s)`: the skew (in frames) of input signal s.
 *
 * Translation of the C function wfdbgetskew() (lib/signal.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.wfdbgetskew(s: Int): Int = if (uless(s, maxOf(sig.nvsig, 0))) sig.vsd[s].skew else 0

/**
 * C `wfdbsetiskew(s, skew)`: sets the skew of input signal s (use with
 * care: only to restore skews reset as a side effect of, e.g., sampfreq).
 *
 * Translation of the C function wfdbsetiskew() (lib/signal.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.wfdbsetiskew(s: Int, skew: Int) {
    val st = sig
    if (uless(s, maxOf(st.nvsig, 0)) && skew >= 0 && st.tspf != 0 && uless(skew, (st.dsblen.toUInt() / st.tspf.toUInt()).toInt())) {
        st.vsd[s].skew = skew
    }
}

/**
 * C `wfdbsetskew(s, skew)`: sets the skew to be written by setheader for output
 * signal s.
 *
 * Translation of the C function wfdbsetskew() (lib/signal.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.wfdbsetskew(s: Int, skew: Int) {
    if (uless(s, sig.nosig)) sig.osd[s].skew = skew
}

/**
 * C `wfdbgetstart(s)`: the byte offset of sample 0 in the signal file of input
 * signal s.
 *
 * Translation of the C function wfdbgetstart() (lib/signal.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.wfdbgetstart(s: Int): Long {
    val st = sig
    return if (uless(s, st.nisig) && s < st.vsd.size && st.vsd[s].info.group < st.igd.size) {
        st.igd[st.vsd[s].info.group].start
    } else if (s == 0 && st.hsd.isNotEmpty()) {
        st.hsd[0].start
    } else {
        0
    }
}

/**
 * C `wfdbsetstart(s, bytes)`: sets the byte offset to be written by setheader
 * for output signal s.
 *
 * Translation of the C function wfdbsetstart() (lib/signal.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.wfdbsetstart(s: Int, bytes: Long) {
    val st = sig
    if (uless(s, st.nosig)) {
        val g = st.osd[s].info.group
        if (g >= 0 && g < st.ogd.size) st.ogd[g].start = bytes
    }
    st.prologBytes = bytes
}

/**
 * C `wfdbputprolog(buf, size, s)`: writes [size] bytes of [buf] (a prolog)
 * to the signal file of output signal [s], and records its length as the
 * byte offset of sample 0 (see [wfdbsetstart]). Returns 0, or -1 on a write
 * error.
 *
 * Translation of the C function wfdbputprolog() (lib/signal.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.wfdbputprolog(buf: ByteArray, size: Long, s: Int): Int {
    var n = 0L
    val st = sig
    if (uless(s, st.nosig)) {
        val g = st.osd[s].info.group
        val f = if (g >= 0 && g < st.ogd.size) st.ogd[g].fp else null
        if (f != null) {
            val k = minOf(maxOf(size, 0L), buf.size.toLong()).toInt()
            n = f.write(buf, 0, k).toLong()
        }
    }
    wfdbsetstart(s, n)
    if (n != size) wfdb_error(cformat("wfdbputprolog: only %ld of %ld bytes written\n", n, size))
    return if (n == size) 0 else -1
}

// ---------------------------------------------------------------------------
// Info strings

/**
 * C `setinfo(record)`: creates (or opens for appending) the info file
 * record.info, to which [putinfo] then writes; null closes it.
 *
 * Returns 0 on success, or: -1 if the record name is illegal or the file
 * cannot be opened, -2 on a write error when closing it (with null).
 *
 * Translation of the C function setinfo() (lib/signal.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.setinfo(record0: ByteArray?): Int {
    // Close any previously opened output info file.
    val stat = wfdb_oinfoclose()

    // Quit unless a record name has been specified.
    if (record0 == null) return stat

    // Remove trailing .hea, if any, from record name.
    val record = wfdb_striphea(record0)

    // Quit (with message from wfdb_checkname) if name is illegal.
    if (wfdb_checkname(record, "record") != 0) return -1

    // Try to create the .info file.
    val f = wfdb_open("info".latin1(), record, WFDB_APPEND)
    if (f == null) {
        wfdb_error(cformat("setinfo: can't create info file for record %s\n", record))
        return -1
    }
    sig.outinfoFile = f
    sig.outinfo = OUTINFO_FILE
    return 0
}

/** [setinfo] with the record name as a string. */
fun Wfdb.setinfo(record: String): Int = setinfo(record.latin1())

/**
 * C `putinfo(s)`: writes an info string (a comment line) to the info file
 * opened by [setinfo], or else to the header file written last by
 * newheader/setheader. Returns 0, or -1 if neither is open.
 *
 * Translation of the C function putinfo() (lib/signal.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.putinfo(s: ByteArray): Int {
    val st = sig
    if (st.outinfo == OUTINFO_NONE) {
        if (st.oheader != null) {
            st.outinfo = OUTINFO_HEADER
        } else {
            wfdb_error("putinfo: caller has not specified a record name\n")
            return -1
        }
    }
    val f = if (st.outinfo == OUTINFO_HEADER) st.oheader else st.outinfoFile
    if (f != null) {
        val line = ByteVec(s.size + 3)
        line.add('#'.code)
        line.addAll(cstr(s))
        line.addString("\r\n")
        f.write(line.bytes, 0, line.size)
        f.flush()
    }
    return 0
}

/** [putinfo] with a string. */
fun Wfdb.putinfo(s: String): Int = putinfo(s.latin1())

/** As in C, an info string is the line after its initial '#', without its line ending, up to its first null character. */
private fun SigState.saveInfo(b: ByteArray) {
    var l = cstr(b)
    if (l.isNotEmpty() && l[l.size - 1] == '\n'.code.toByte()) l = l.copyOf(l.size - 1)
    if (l.isNotEmpty() && l[l.size - 1] == '\r'.code.toByte()) l = l.copyOf(l.size - 1)
    pinfo.add(if (l.isEmpty()) l else l.copyOfRange(1, l.size))
    ninfo++
}

/**
 * C `getinfo(record)`: on the first call (or with a record name), reads
 * the info strings of the record (from its header and .info file) and
 * returns the first; with null, returns the next one. null when there are
 * no more.
 *
 * Translation of the C function getinfo() (lib/signal.c, WFDB 10.7.0): same
 * arguments and results.
 */
fun Wfdb.getinfo(record: ByteArray?): ByteArray? {
    val rec = record?.let { cstr(it) }
    if (rec != null) wfdb_freeinfo()

    if (!sig.havePinfo) {
        // info for record has not yet been read
        var recbuf = rec ?: wfdb_getirec()
        if (recbuf == null) {
            wfdb_error("getinfo: caller did not specify record name\n")
            return null
        }

        if (sig.ninfo != 0) {
            wfdb_freeinfo()
            sig.ninfo = 0
        }

        sig.infoI = 0
        sig.havePinfo = true
        sig.pinfo.clear()

        // Read info from the .hea file, if available (skip for EDF files).
        if (sig.isedf == 0) {
            recbuf = wfdb_striphea(recbuf)
            val ifile = wfdb_open("hea".latin1(), recbuf, WFDB_READ)
            if (ifile != null) {
                // As with wfdb_getline(), the buffer keeps its previous
                // contents when the end of the file is reached.
                var buf = ByteArray(0)
                val line = ByteVec(256)
                while (ifile.getline(line) > 0) {
                    buf = line.toByteArray()
                    if (buf[0] != '#'.code.toByte()) break // skip initial comments
                }
                while (ifile.getline(line) > 0) {
                    buf = line.toByteArray()
                    if (buf[0] == '#'.code.toByte()) break // skip header content
                }
                while (buf.isNotEmpty() && buf[0] != 0.toByte()) {
                    // read and save info
                    if (buf[0] == '#'.code.toByte()) sig.saveInfo(buf)
                    if (ifile.getline(line) == 0) break
                    buf = line.toByteArray()
                }
                ifile.close()
            }
        }
        // Read more info from the .info file, if available.
        val ifile = wfdb_open("info".latin1(), recbuf, WFDB_READ)
        if (ifile != null) {
            val line = ByteVec(256)
            while (ifile.getline(line) > 0) {
                val buf = line.toByteArray()
                if (buf[0] == '#'.code.toByte()) sig.saveInfo(buf)
            }
            ifile.close()
        }
    }
    val st = sig
    return if (st.infoI < st.ninfo) st.pinfo[st.infoI++].copyOf() else null
}

/** [getinfo] with the record name as a string. */
fun Wfdb.getinfo(record: String): ByteArray? = getinfo(record.latin1())

/**
 * C `wfdb_freeinfo()`: releases the info strings.
 *
 * Translation of the C function wfdb_freeinfo() (lib/signal.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.wfdb_freeinfo() {
    val st = sig
    st.pinfo.clear()
    st.havePinfo = false
    st.ninfo = 0
}

// ---------------------------------------------------------------------------
// Sampling frequency

/**
 * C `sampfreq(record)`: returns the sampling frequency (Hz) of [record]
 * (reading its header), or of the open record if record is null.
 *
 * Returns the frequency (> 0); 0 if the header does not specify it (WFDB-x:
 * C assumed 250 Hz) and none was set with setsampfreq; -1 if the header
 * cannot be read, -2 if it is incorrect.
 *
 * Translation of the C function sampfreq() (lib/signal.c, WFDB 10.7.0): same
 * arguments and results. Differences: it returns 0, not 250, if the header
 * gives no sampling frequency; see docs/DIVERGENCES.md.
 */
fun Wfdb.sampfreq(record: ByteArray?): Double {
    if (record != null) {
        // Remove trailing .hea, if any, from record name.
        val r = wfdb_striphea(record)
        // Save the current record name.
        wfdb_setirec(r)
        // Don't require the sampling frequency of this record to match that
        // of the previously opened record, if any.
        setsampfreq(0.0)
        // readheader sets sfreq if successful.
        val n = readheader(r)
        if (n < 0) return n.toDouble() // error message will come from readheader
    }
    return sig.sfreq
}

/** [sampfreq] with the record name as a string. */
fun Wfdb.sampfreq(record: String): Double = sampfreq(record.latin1())

/**
 * C `setsampfreq(freq)`: sets the sampling frequency (Hz) used for time
 * conversions and written in headers. Returns 0, or -1 if freq is negative.
 *
 * Translation of the C function setsampfreq() (lib/signal.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.setsampfreq(freq: Double): Int {
    if (freq >= 0.0) {
        val st = sig
        st.sfreq = freq
        st.ffreq = freq
        if (st.spfmax == 0) st.spfmax = 1
        if ((st.gvmode and WFDB_HIGHRES) == WFDB_HIGHRES) st.sfreq *= st.spfmax
        return 0
    }
    wfdb_error("setsampfreq: sampling frequency must not be negative\n")
    return -1
}

// ---------------------------------------------------------------------------
// Random access: sample()

/**
 * C `sample(s, t)`: sample number t of input signal s (buffered random access);
 * see [sample_valid].
 *
 * Translation of the C function sample() (lib/signal.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.sample(s: Int, t0: Long): Int {
    var t = t0
    val nsig = maxOf(sig.nvsig, sig.nisig, 0)
    // getvec may store tspf samples per call.
    val stride = nsig.toLong()

    // Allocate the sample buffer on the first call.
    if (!sig.haveSbuf) {
        val need = vecNeed()
        val width = maxOf(nsig, sig.tspf, 0)
        val w = maxOf(width, 1)
        sig.sbuf = IntArray(w * BUFLN.toInt() + maxOf(width, need))
        sig.haveSbuf = true
        sig.sampleTt = -1
    }

    // If the caller requested a sample from an unavailable signal, return an
    // invalid value. Note that sample_vflag is not cleared in this case.
    if (!uless(s, nsig)) {
        sig.sampleVflag = -1
        return WFDB_INVALID_SAMPLE
    }

    // If the caller specified a negative sample number, prepare to return
    // sample 0.
    if (t < 0) t = 0

    // If the caller has requested a sample that is no longer in the buffer,
    // or that is further ahead than the length of the buffer, reset the
    // signal file pointer(s).
    val tt0 = sig.sampleTt
    if (t <= tt0 - BUFLN || t > tt0 + BUFLN) {
        var tt = t - BUFLN
        if (tt < 0) tt = -1
        sig.sampleTt = tt
        if (isigsettime(tt + 1) < 0) {
            sig.sampleVflag = 0
            return WFDB_INVALID_SAMPLE
        }
    }
    // If the requested sample is not yet in the buffer, read and buffer more
    // samples. If we reach the end of the record, clear sample_vflag and
    // return the last valid value.
    while (t > sig.sampleTt) {
        sig.sampleTt++
        val pos = (stride * (sig.sampleTt and (BUFLN - 1))).toInt()
        val r = getvecAt(sig.sbuf, pos)
        if (r < 0) {
            sig.sampleTt--
            sig.sampleVflag = 0
            val k = (stride * (sig.sampleTt and (BUFLN - 1))).toInt() + s
            return sig.sbuf[k]
        }
    }

    // The requested sample is in the buffer. Set sample_vflag and return the
    // requested sample.
    val v = sig.sbuf[(stride * (t and (BUFLN - 1))).toInt() + s]
    sig.sampleVflag = if (v == WFDB_INVALID_SAMPLE) -1 else 1
    return v
}

/**
 * C `sample_valid()`: 1 if the value returned by the last sample() call was
 * valid, -1 if it was invalid, 0 at the end of the record.
 *
 * Translation of the C function sample_valid() (lib/signal.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.sample_valid(): Int = sig.sampleVflag

// ---------------------------------------------------------------------------
// WFDB-x: accessors for the high-level API and check_record

/** WFDB-x: the number of samples per signal given by the record line of the header read last (that of a multi-segment record for such a record; 0 if not given). */
internal fun Wfdb.wfdbxHeaderNsamples(): Long = if (sig.inMsrec != 0) sig.msnsamples else sig.nsamples

/** WFDB-x (for check_record): the number of samples of the record opened last: that of the master header for a multi-segment record ([multi], or while one is open), otherwise that of its header. */
internal fun Wfdb.wfdbxRecordNsamples(multi: Boolean): Long = if (sig.inMsrec != 0 || multi) sig.msnsamples else sig.nsamples

/** WFDB-x (for check_record): whether the open record is an EDF file. */
internal fun Wfdb.wfdbxIsEdf(): Boolean = sig.isedf != 0

/** WFDB-x (for check_record): the checksum accumulator of each open input signal (the header's checksum less the samples read so far). */
internal fun Wfdb.wfdbxCksumResiduals(): IntArray = IntArray(sig.nisig) { sig.isd[it].info.cksum }

/** WFDB-x (for check_record): the size of the file of each open input signal group, if it is a local file (-1 otherwise). */
internal fun Wfdb.wfdbxGroupFileSizes(): LongArray = LongArray(sig.nigroup) { sig.igd[it].fp?.localSize() ?: -1L }

/**
 * WFDB-x (for the high-level API): the base time, in milliseconds after
 * midnight (C btime), and the base date, as (year, month, day) (null if the
 * header gives no date: C bdate 0).
 */
internal fun Wfdb.wfdbxBaseTimeDate(): Pair<Long, IntArray?> =
    Pair(sig.btime, if (sig.bdate != 0L) julianToYmd(sig.bdate) else null)

/** WFDB-x (for the high-level API): whether getvec's checksum message is recorded without being printed; returns the previous setting. */
internal fun Wfdb.wfdbxSetCksumQuiet(on: Boolean): Boolean {
    val p = sig.cksumQuiet
    sig.cksumQuiet = on
    return p
}

// ---------------------------------------------------------------------------
// Top-level functions (default instance)

/** C `isigopen` on the default instance (see [Wfdb.isigopen]). */
fun isigopen(record: ByteArray?, siarray: Array<Siginfo>?, nsig: Int): Int = wfdbDefault().isigopen(record, siarray, nsig)

/** C `isigopen` on the default instance (see [Wfdb.isigopen]). */
fun isigopen(record: String, siarray: Array<Siginfo>?, nsig: Int): Int = wfdbDefault().isigopen(record, siarray, nsig)

/** C `osigopen` on the default instance (see [Wfdb.osigopen]). */
fun osigopen(record: ByteArray?, siarray: Array<Siginfo>?, nsig: Int): Int = wfdbDefault().osigopen(record, siarray, nsig)

/** C `osigopen` on the default instance (see [Wfdb.osigopen]). */
fun osigopen(record: String, siarray: Array<Siginfo>?, nsig: Int): Int = wfdbDefault().osigopen(record, siarray, nsig)

/** C `osigfopen` on the default instance (see [Wfdb.osigfopen]). */
fun osigfopen(siarray: Array<Siginfo>?, nsig: Int): Int = wfdbDefault().osigfopen(siarray, nsig)

/** C `findsig` on the default instance (see [Wfdb.findsig]). */
fun findsig(p: ByteArray): Int = wfdbDefault().findsig(p)

/** C `findsig` on the default instance (see [Wfdb.findsig]). */
fun findsig(p: String): Int = wfdbDefault().findsig(p)

/** C `getspf` on the default instance (see [Wfdb.getspf]). */
fun getspf(): Int = wfdbDefault().getspf()

/** C `setgvmode` on the default instance (see [Wfdb.setgvmode]). */
fun setgvmode(mode: Int) = wfdbDefault().setgvmode(mode)

/** C `getgvmode` on the default instance (see [Wfdb.getgvmode]). */
fun getgvmode(): Int = wfdbDefault().getgvmode()

/** C `setifreq` on the default instance (see [Wfdb.setifreq]). */
fun setifreq(f: Double): Int = wfdbDefault().setifreq(f)

/** C `getifreq` on the default instance (see [Wfdb.getifreq]). */
fun getifreq(): Double = wfdbDefault().getifreq()

/** C `getvec` on the default instance (see [Wfdb.getvec]). */
fun getvec(vector: IntArray): Int = wfdbDefault().getvec(vector)

/** C `getframe` on the default instance (see [Wfdb.getframe]). */
fun getframe(vector: IntArray): Int = wfdbDefault().getframe(vector)

/** `getvecs` on the default instance (see [Wfdb.getvecs]). */
fun getvecs(out: IntArray, n: Long): Long = wfdbDefault().getvecs(out, n)

/** `getvecs_status` on the default instance (see [Wfdb.getvecs_status]). */
fun getvecs_status(out: IntArray, n: Long): GetvecsResult = wfdbDefault().getvecs_status(out, n)

/** WFDB-x: `wfdbx_bulk_read` on the default instance (see [Wfdb.wfdbx_bulk_read]). */
fun wfdbx_bulk_read(on: Boolean): Boolean = wfdbDefault().wfdbx_bulk_read(on)

/** C `putvec` on the default instance (see [Wfdb.putvec]). */
fun putvec(vector: IntArray): Int = wfdbDefault().putvec(vector)

/** C `isigsettime` on the default instance (see [Wfdb.isigsettime]). */
fun isigsettime(t: Long): Int = wfdbDefault().isigsettime(t)

/** C `isgsettime` on the default instance (see [Wfdb.isgsettime]). */
fun isgsettime(g: Int, t: Long): Int = wfdbDefault().isgsettime(g, t)

/** C `tnextvec` on the default instance (see [Wfdb.tnextvec]). */
fun tnextvec(s: Int, t: Long): Long = wfdbDefault().tnextvec(s, t)

/** C `setibsize` on the default instance (see [Wfdb.setibsize]). */
fun setibsize(n: Int): Int = wfdbDefault().setibsize(n)

/** C `setobsize` on the default instance (see [Wfdb.setobsize]). */
fun setobsize(n: Int): Int = wfdbDefault().setobsize(n)

/** C `newheader` on the default instance (see [Wfdb.newheader]). */
fun newheader(record: ByteArray): Int = wfdbDefault().newheader(record)

/** C `newheader` on the default instance (see [Wfdb.newheader]). */
fun newheader(record: String): Int = wfdbDefault().newheader(record)

/** C `setheader` on the default instance (see [Wfdb.setheader]). */
fun setheader(record: ByteArray, siarray: Array<Siginfo>, nsig: Int): Int = wfdbDefault().setheader(record, siarray, nsig)

/** C `setheader` on the default instance (see [Wfdb.setheader]). */
fun setheader(record: String, siarray: Array<Siginfo>, nsig: Int): Int = wfdbDefault().setheader(record, siarray, nsig)

/** C `getseginfo` on the default instance (see [Wfdb.getseginfo]). */
fun getseginfo(sarray: MutableList<Seginfo>?): Int = wfdbDefault().getseginfo(sarray)

/** C `setmsheader` on the default instance (see [Wfdb.setmsheader]). */
fun setmsheader(record: ByteArray, segmentNames: Array<ByteArray>, nsegments: Int): Int =
    wfdbDefault().setmsheader(record, segmentNames, nsegments)

/** C `setmsheader` on the default instance (see [Wfdb.setmsheader]). */
fun setmsheader(record: String, segmentNames: Array<String>, nsegments: Int): Int =
    wfdbDefault().setmsheader(record, segmentNames, nsegments)

/** C `wfdbgetskew` on the default instance (see [Wfdb.wfdbgetskew]). */
fun wfdbgetskew(s: Int): Int = wfdbDefault().wfdbgetskew(s)

/** C `wfdbsetiskew` on the default instance (see [Wfdb.wfdbsetiskew]). */
fun wfdbsetiskew(s: Int, skew: Int) = wfdbDefault().wfdbsetiskew(s, skew)

/** C `wfdbsetskew` on the default instance (see [Wfdb.wfdbsetskew]). */
fun wfdbsetskew(s: Int, skew: Int) = wfdbDefault().wfdbsetskew(s, skew)

/** C `wfdbgetstart` on the default instance (see [Wfdb.wfdbgetstart]). */
fun wfdbgetstart(s: Int): Long = wfdbDefault().wfdbgetstart(s)

/** C `wfdbsetstart` on the default instance (see [Wfdb.wfdbsetstart]). */
fun wfdbsetstart(s: Int, bytes: Long) = wfdbDefault().wfdbsetstart(s, bytes)

/** C `wfdbputprolog` on the default instance (see [Wfdb.wfdbputprolog]). */
fun wfdbputprolog(buf: ByteArray, size: Long, s: Int): Int = wfdbDefault().wfdbputprolog(buf, size, s)

/** C `setinfo` on the default instance (see [Wfdb.setinfo]). */
fun setinfo(record: ByteArray?): Int = wfdbDefault().setinfo(record)

/** C `setinfo` on the default instance (see [Wfdb.setinfo]). */
fun setinfo(record: String): Int = wfdbDefault().setinfo(record)

/** C `putinfo` on the default instance (see [Wfdb.putinfo]). */
fun putinfo(s: ByteArray): Int = wfdbDefault().putinfo(s)

/** C `putinfo` on the default instance (see [Wfdb.putinfo]). */
fun putinfo(s: String): Int = wfdbDefault().putinfo(s)

/** C `getinfo` on the default instance (see [Wfdb.getinfo]). */
fun getinfo(record: ByteArray?): ByteArray? = wfdbDefault().getinfo(record)

/** C `getinfo` on the default instance (see [Wfdb.getinfo]). */
fun getinfo(record: String): ByteArray? = wfdbDefault().getinfo(record)

/** C `wfdb_freeinfo` on the default instance (see [Wfdb.wfdb_freeinfo]). */
fun wfdb_freeinfo() = wfdbDefault().wfdb_freeinfo()

/** C `sampfreq` on the default instance (see [Wfdb.sampfreq]). */
fun sampfreq(record: ByteArray?): Double = wfdbDefault().sampfreq(record)

/** C `sampfreq` on the default instance (see [Wfdb.sampfreq]). */
fun sampfreq(record: String): Double = wfdbDefault().sampfreq(record)

/** C `setsampfreq` on the default instance (see [Wfdb.setsampfreq]). */
fun setsampfreq(freq: Double): Int = wfdbDefault().setsampfreq(freq)

/** C `sample` on the default instance (see [Wfdb.sample]). */
fun sample(s: Int, t: Long): Int = wfdbDefault().sample(s, t)

/** C `sample_valid` on the default instance (see [Wfdb.sample_valid]). */
fun sample_valid(): Int = wfdbDefault().sample_valid()
