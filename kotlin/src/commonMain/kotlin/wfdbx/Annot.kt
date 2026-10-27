// Annotation I/O (port of lib/annot.c, from rust/src/annot.rs and
// cpp/src/annot.cpp): MIT and AHA annotation files, annotation code
// mnemonics and descriptions, annotation time resolution.
//
// This file contains annopen, getann, ungetann, putann, iannsettime, the
// annotation code/mnemonic/description conversion functions (ecgstr,
// strecg, setecgstr, annstr, strann, setannstr, anndesc, setanndesc), the
// time resolution functions (setafreq, getafreq, setiafreq, getiafreq,
// getiaorigfreq), iannclose, oannclose, and the library-private functions
// wfdb_anclose and wfdb_oaflush.
//
// Modification labels (NOTE annotations at time 0 that redefine annotation
// mnemonics and descriptions, and the time resolution record) are read by
// annopen and written before the first annotation of each output file.
// Output files whose annotations are not in canonical order are sorted
// when they are closed, in this process, with the result of the sortann
// program (in legacy mode, by running sortann, run_sortann, as the C
// library does).
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of lib/annot.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original code, but it is new code, not the original C code.
//
// Changes from the original: oannclose sorts an out-of-order output annotation
// file in this process, with the same result as the sortann program, which the
// original ran through the shell; the sort does not lose an out-of-order
// annotation at time 0 (num 0, chan 0), nor those inserted after it; the sort
// option of the high-level write_annotations decides, for its call, whether
// the file is sorted; legacy mode (wfdbx_set_legacy) restores the original
// behavior. Each change is marked "wfdb-x:" in the code; docs/DIVERGENCES.md
// gives the reasons.
//
// Original C code: lib/annot.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1989-2013 George B. Moody; revised 2015-2020 by
//   Benjamin Moody.
// Kotlin translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx

import wfdbx.cstd.ByteVec
import wfdbx.cstd.CDouble
import wfdbx.cstd.cformat
import wfdbx.cstd.cstr
import wfdbx.cstd.getenv
import wfdbx.cstd.latin1
import wfdbx.cstd.SEEK_SET
import wfdbx.cstd.sscanf
import wfdbx.cstd.startsWith
import wfdbx.cstd.strtol

// Annotation word format
private const val CODE = 0xfc00 // annotation code segment of word (0176000)
private const val CS = 10 // places by which code must be shifted
private const val DATA = 0x3ff // data segment of annotation word (01777)
private const val MAXRR = 0x3ffL // longest interval coded in a word

private const val MAXSKIP = 0x7fffffffL // largest interval of a SKIP
private const val MINSKIP = -0x7fffffffL // smallest interval of a SKIP

// Pseudo-annotation codes
private const val PAMIN = 59 shl CS
private const val SKIP = 59 shl CS // long null annotation
private const val NUM = 60 shl CS // change 'num' field
private const val SUB = 61 shl CS // subtype
private const val CHN = 62 shl CS // change 'chan' field
private const val AUX = 63 shl CS // auxiliary information

// Constants for AHA annotation files only
private const val ABLKSIZ = 1024L // AHA annotation file block length
private const val AUXBUFLEN = 771 // size of the aux string buffer
private const val AUXLEN = 6 // length of AHA aux field
private const val EOAF = 0xff // padding for end of AHA annotation files

/** Prefix of the NOTE annotation that gives the time resolution of an annotation file (followed by the frequency). */
private const val TIME_RESOLUTION = "## time resolution: "

private const val NCODES = ACMAX + 1

/** An input annotator. */
internal class IaData(
    /** Input annotation file. */
    val file: WfdbFile,
    /** Input annotator information. */
    val info: Anninfo,
) {
    /** Next annotation to be returned by getann. */
    val ann = Annotation()

    /** Pushed-back annotation from ungetann. */
    val pann = Annotation()

    /** Time resolution, in ticks/second. */
    var afreq = 0.0

    /** Next word from the input file (as C's unsigned: the sign-extended 16-bit value). */
    var word = 0

    /** EOF-reached indicator. */
    var ateof = 0

    /** Aux string buffer. */
    val auxstr = ByteArray(AUXBUFLEN)

    /** Next available position in auxstr. */
    var index = 0

    /** Position of the aux string of ann in auxstr (-1: none). */
    var auxpos = -1

    /** tmul * annotation time = sample count. */
    var tmul = 0.0

    /** Annotation time (MIT format only). */
    var tt = 0.0

    /** Unscaled annotation time of ann. */
    var annTt = 0.0

    /** Unscaled annotation time of pann. */
    var pannTt = 0.0

    /** Unscaled time of the last annotation returned by getann. */
    var prevTt = 0.0

    /** Sample number of the last annotation returned by getann. */
    var prevTime = 0L
}

/** An output annotator. */
internal class OaData(
    /** Output annotation file. */
    val file: WfdbFile,
    /** Output annotator information. */
    val info: Anninfo,
    /** Record with which the annotator is associated. */
    val rname: ByteArray,
    /** wfdb-x: name of the file (as created), for sortAnnFile. */
    val fname: ByteArray,
) {
    /** Most recent annotation written by putann. */
    val ann = Annotation()

    /** Time resolution, in ticks/second. */
    var afreq = 0.0

    /** Annotation serial number (AHA only). */
    var seqno = 0

    /** If true, annotations are not in order. */
    var outOfOrder = false

    /** If true, the table has been written. */
    var tableWritten = false
}

private val DEFAULT_MNEMONICS = arrayOf(
    " ", "N", "L", "R", "a", // 0 - 4
    "V", "F", "J", "A", "S", // 5 - 9
    "E", "j", "/", "Q", "~", // 10 - 14
    "[15]", "|", "[17]", "s", "T", // 15 - 19
    "*", "D", "\"", "=", "p", // 20 - 24
    "B", "^", "t", "+", "u", // 25 - 29
    "?", "!", "[", "]", "e", // 30 - 34
    "n", "@", "x", "f", "(", // 35 - 39
    ")", "r", "[42]", "[43]", "[44]", // 40 - 44
    "[45]", "[46]", "[47]", "[48]", "[49]", // 45 - 49
)

private val DEFAULT_DESCRIPTIONS: Array<String?> = arrayOf(
    "",
    "Normal beat",
    "Left bundle branch block beat",
    "Right bundle branch block beat",
    "Aberrated atrial premature beat",
    "Premature ventricular contraction",
    "Fusion of ventricular and normal beat",
    "Nodal (junctional) premature beat",
    "Atrial premature beat",
    "Supraventricular premature or ectopic beat",
    "Ventricular escape beat",
    "Nodal (junctional) escape beat",
    "Paced beat",
    "Unclassifiable beat",
    "Change in signal quality",
    null,
    "Isolated QRS-like artifact",
    null,
    "ST segment change",
    "T-wave change",
    "Systole",
    "Diastole",
    "Comment annotation",
    "Measurement annotation",
    "P-wave peak",
    "Bundle branch block beat (unspecified)",
    "(Non-captured) pacemaker artifact",
    "T-wave peak",
    "Rhythm change",
    "U-wave peak",
    "Beat not classified during learning",
    "Ventricular flutter wave",
    "Start of ventricular flutter/fibrillation",
    "End of ventricular flutter/fibrillation",
    "Atrial escape beat",
    "Supraventricular escape beat",
    "Link to external data (aux contains URL)",
    "Non-conducted P-wave (blocked APC)",
    "Fusion of paced and normal beat",
    "Waveform onset",
    "Waveform end",
    "R-on-T premature ventricular contraction",
    null, null, null, null, null, null, null, null,
)

/**
 * wfdb-x: a table of annotation type definitions: mnemonics, descriptions,
 * and flags marking the modified types. [AnnState] holds that of the
 * library; sortAnnFile uses one of its own.
 */
internal class AnnDefs {
    /** Mnemonic strings for each code. */
    val astring: Array<ByteArray> = Array(NCODES) { DEFAULT_MNEMONICS[it].latin1() }

    /** Descriptions for each code. */
    val tstring: Array<ByteArray?> = Array(NCODES) { DEFAULT_DESCRIPTIONS[it]?.latin1() }

    /** Mnemonic or description modified (by setannstr, setanndesc, or a definition read from a file). */
    val modified = BooleanArray(NCODES)

    /** A copy. */
    fun copy(): AnnDefs {
        val d = AnnDefs()
        astring.copyInto(d.astring)
        tstring.copyInto(d.tstring)
        modified.copyInto(d.modified)
        return d
    }

    /**
     * The body of setannstr (desc false) and setanndesc (desc true): with a
     * positive code, the change is marked as a modification; with a
     * negative one (-code is modified), it is not. Returns 0, or -1 if the
     * code is illegal.
     */
    fun set(desc: Boolean, code0: Int, s: ByteArray): Int {
        val mflag = code0 > 0
        val code = if (mflag) code0 else -code0
        if (code < 0 || code > ACMAX) return -1
        val changed = if (desc) !(tstring[code]?.contentEquals(s) ?: false) else !astring[code].contentEquals(s)
        if (changed) {
            if (desc) tstring[code] = s.copyOf() else astring[code] = s.copyOf()
            if (mflag) modified[code] = true
        }
        return 0
    }
}

/** Error messages produced by functions that have no access to the library instance, reported by the caller ([report]). */
private typealias Msgs = MutableList<ByteArray>

/**
 * The state of annot.c (part of [Wfdb]): input and output annotators,
 * mnemonic and description tables, annotation time resolution, ...
 */
internal class AnnState {
    val iad = ArrayList<IaData>()
    val oad = ArrayList<OaData>()

    /** Time resolution for new output annotators. */
    var oafreq = 0.0

    /** If < 0, error while closing files (-6: annotations out of order, -7: write error). */
    var annclose_error = 0

    /** ECG mnemonics for each code. */
    val cstring: Array<ByteArray> = Array(NCODES) { DEFAULT_MNEMONICS[it].latin1() }

    /** Annotation type definitions (mnemonics and descriptions). */
    var defs = AnnDefs()

    /**
     * wfdb-x: whether oannclose sorts an out-of-order file (non-null),
     * whatever WFDBANNSORT says; null: as WFDBANNSORT says. Set by the
     * high-level writeAnnotations for the duration of a call (its sort
     * option).
     */
    var sortOverride: Boolean? = null
}

private fun AnnState.iaAt(n: Int): IaData? = if (n in iad.indices) iad[n] else null

private fun AnnState.oaAt(n: Int): OaData? = if (n in oad.indices) oad[n] else null

/** Rounds a double to the nearest time, with halfway cases always rounded up. */
internal fun roundToTime(x: Double): Long {
    if (x.isNaN()) return WFDB_TIME_MIN // as on x86
    if (x >= 0.0) {
        if (x >= WFDB_TIME_MAX.toDouble()) return WFDB_TIME_MAX
        val t = x.toLong()
        return if (x - t.toDouble() >= 0.5) t + 1 else t
    }
    if (x <= WFDB_TIME_MIN.toDouble()) return WFDB_TIME_MIN
    val t = x.toLong()
    return if (x - t.toDouble() < -0.5) t - 1 else t
}

/** The aux string of an annotation as a C string (the data following the length byte, up to the first null). */
private fun auxText(aux: ByteArray): ByteArray = if (aux.size <= 1) ByteArray(0) else cstr(aux.copyOfRange(1, aux.size))

/** An aux field (length byte first) holding [s]. */
private fun makeAux(s: ByteArray): ByteArray {
    val a = ByteArray(s.size + 1)
    a[0] = s.size.toByte()
    s.copyInto(a, 1)
    return a
}

/** The aux string at position [pos] of the aux buffer: the length byte, the data, and any following bytes up to a null (as a C string would be read). */
private fun auxFromBuffer(ia: IaData, pos: Int): ByteArray {
    val len = ia.auxstr[pos].toInt() and 0xff
    var i = pos + 1
    while (i < AUXBUFLEN && (i - pos - 1 < len || ia.auxstr[i] != 0.toByte())) i++
    return ia.auxstr.copyOfRange(pos, i)
}

/** Reads the next annotation of an input annotator into ia.ann (the second part of getann). Returns an error message to report, if any. */
private fun getannNext(ia: IaData): ByteArray? {
    var msg: ByteArray? = null
    val f = ia.file
    if (ia.info.stat == WFDB_AHA_READ) {
        if ((ia.word and 0xff) == EOAF) {
            // logical end of file
            ia.ateof = 1
            return null
        }
        val a = ia.word ushr 8 // AHA annotation code
        ia.ann.anntyp = wfdb_ammap(a)
        ia.annTt = f.g32().toDouble()
        if (f.g16() <= 0) {
            // serial number (starts at 1)
            msg = cformat("getann: unexpected annot number in annotator %s\n", ia.info.name)
        }
        ia.ann.subtyp = f.getc()
        if (a == 'U'.code && ia.ann.subtyp == 0) ia.ann.subtyp = -1 // unreadable (noise subtype -1)
        ia.ann.chan = f.getc()
        // (AHA aux strings, with their length byte and NUL, are kept in the
        // first 256 bytes of the buffer, as in C.)
        if (ia.index >= 256 - (AUXLEN + 2)) ia.index = 0
        // read aux data
        val ix = ia.index
        f.read(ia.auxstr, ix + 1, AUXLEN)
        // There is very limited space in AHA format files for auxiliary
        // information, so no length byte is recorded; instead, we assume
        // that if the first byte of auxiliary data is not null, that up to
        // AUXLEN bytes may be significant.
        if (ia.auxstr[ix + 1] != 0.toByte()) {
            ia.auxstr[ix] = AUXLEN.toByte()
            ia.auxpos = ix // save position
            ia.auxstr[ix + 1 + AUXLEN] = 0 // add a null
            ia.index += AUXLEN + 2 // update buffer index
        } else {
            ia.auxpos = -1
        }
        ia.word = f.g16()
    } else {
        // MIT-format input file
        if (ia.word == 0) {
            // logical end of file
            ia.ateof = 1
            return null
        }
        ia.tt += (ia.word and DATA).toDouble() // annotation time
        ia.annTt = ia.tt
        ia.ann.anntyp = (ia.word and CODE) ushr CS
        ia.ann.subtyp = 0 // reset subtype field
        ia.auxpos = -1 // reset aux field
        while (true) {
            ia.word = f.g16()
            if ((ia.word and CODE) < PAMIN || f.eof()) break
            when (ia.word and CODE) {
                // process pseudo-annotations
                SKIP -> ia.tt += f.g32().toDouble()
                SUB -> ia.ann.subtyp = DATA and ia.word
                CHN -> ia.ann.chan = DATA and ia.word
                NUM -> ia.ann.num = DATA and ia.word
                AUX -> {
                    // auxiliary information
                    val len = ia.word and 0xff // length of auxiliary data
                    if (ia.index >= AUXBUFLEN - 2 - len) ia.index = 0 // buffer index
                    ia.auxpos = ia.index // save position
                    ia.auxstr[ia.index] = len.toByte()
                    ia.index++
                    // Now read the data. Note that an extra byte may be
                    // present in the annotation file to preserve word
                    // alignment; if so, this extra byte is read and then
                    // overwritten by the null below.
                    val ix = ia.index
                    f.read(ia.auxstr, ix, (len + 1) and 1.inv())
                    ia.auxstr[ix + len] = 0 // add a null
                    ia.index += len + 1 // update buffer index
                }
            }
        }
    }
    ia.ann.time = roundToTime(ia.annTt * ia.tmul)
    if (ia.file.eof()) ia.ateof = -1
    return msg
}

/**
 * Reads the first word of the input annotation file of [ia] and returns its
 * format: [WFDB_READ] (MIT format; any initial null annotations are then
 * read as well) or [WFDB_AHA_READ]. (wfdb-x: this was part of annopen.)
 */
private fun annFileFormat(ia: IaData): Int {
    // Try to figure out what format the file is in. AHA-format files begin
    // with a null byte and an ASCII character which is one of the legal AHA
    // annotation codes other than '[' or ']'. MIT annotation files cannot
    // begin in this way.
    ia.word = ia.file.g16()
    val a = (ia.word ushr 8) and 0xff
    if ((ia.word and 0xff) != 0 || wfdb_ammap(a) == NOTQRS || a == '['.code || a == ']'.code) {
        // read any initial null annotation(s)
        while ((ia.word and CODE) == SKIP) {
            ia.tt += ia.file.g32().toDouble()
            ia.word = ia.file.g16()
        }
        return WFDB_READ
    }
    return WFDB_AHA_READ
}

/** The body of getann, for the input annotator [ia] (wfdb-x). Error messages are added to [msgs]. */
private fun getannIa(ia: IaData, annot: Annotation, msgs: Msgs): Int {
    if (ia.pann.anntyp != 0) {
        // an annotation was pushed back
        annot.set(ia.pann)
        ia.pann.anntyp = 0
        ia.prevTime = annot.time
        ia.prevTt = ia.pannTt
        return 0
    }
    if (ia.ateof != 0) {
        if (ia.ateof != -1) return -1 // reached logical EOF
        msgs.add(cformat("getann: unexpected EOF in annotator %s\n", ia.info.name))
        return -3
    }
    annot.set(ia.ann)
    ia.prevTime = annot.time
    ia.prevTt = ia.annTt
    val retpos = ia.auxpos
    val msg = getannNext(ia)
    annot.aux = if (retpos >= 0) auxFromBuffer(ia, retpos) else null
    if (msg != null) msgs.add(msg)
    return 0
}

/** The body of ungetann (after the checks), for the input annotator [ia], whose pushback buffer is empty (wfdb-x). */
private fun ungetannIa(ia: IaData, annot: Annotation) {
    ia.pann.set(annot)
    ia.pannTt = if (annot.time == ia.prevTime) ia.prevTt else annot.time.toDouble() / ia.tmul
}

private fun isBlank(c: Byte) = c == ' '.code.toByte() || c == '\t'.code.toByte()

/**
 * The body of get_ann_table (wfdb-x), for the input annotator [ia] and the
 * definition table [defs] (the library's, or that of sortAnnFile): reads
 * the modification labels at the beginning of the file (the time
 * resolution goes into ia.afreq, the definitions into defs). Error
 * messages are added to [msgs].
 */
private fun readAnnTable(ia: IaData, defs: AnnDefs, msgs: Msgs): Int {
    ia.tmul = 1.0
    ia.afreq = 0.0
    val annot = Annotation()
    if (getannIa(ia, annot, msgs) < 0) return -1 // prime the pump
    while (getannIa(ia, annot, msgs) == 0 && annot.time == 0L && annot.anntyp == NOTE && annot.subtyp == 0) {
        val aux = annot.aux
        if (aux == null || aux.isEmpty() || (aux[0].toInt() and 0xff) < 1) continue
        val text = auxText(aux)
        if (text.isNotEmpty() && text[0] == '#'.code.toByte()) {
            if (text.startsWith(TIME_RESOLUTION)) {
                val f = CDouble(ia.afreq)
                sscanf(text.copyOfRange(TIME_RESOLUTION.length, text.size), "%lf", f)
                ia.afreq = f.v
            }
            continue
        }
        fun span(from: Int): Int {
            var i = from
            while (i < text.size && isBlank(text[i])) i++
            return i
        }
        fun cspan(from: Int): Int {
            var i = from
            while (i < text.size && !isBlank(text[i])) i++
            return i
        }
        var p1 = span(0) // whitespace before code
        val r = strtol(text, 10, p1)
        val a = r.value.toInt()
        if (a < 0 || a > ACMAX || r.end == p1) continue
        var p2 = cspan(r.end) // non-whitespace after code
        p1 = span(p2) // whitespace before mnemonic
        p2 = cspan(p1) // non-whitespace (mnemonic)
        if (p2 != p1) {
            defs.set(true, a, if (p2 + 1 <= text.size) text.copyOfRange(p2 + 1, text.size) else ByteArray(0))
            defs.set(false, a, text.copyOfRange(p1, p2))
        }
    }
    if (annot.time != 0L || annot.anntyp != NOTE || annot.subtyp != 0 || annot.aux == null) ungetannIa(ia, annot)
    return 0
}

/**
 * put_ann_table (wfdb-x: for the output annotator [oa], number [n], with
 * the time resolution [freq] and the definition table [defs]): writes the
 * modification labels. Error messages are added to [msgs].
 */
private fun putAnnTable(oa: OaData, n: Int, freq: Double, defs: AnnDefs, msgs: Msgs): Int {
    // 0: nothing written yet; 1: time resolution written; 2: at least one
    // table entry written.
    var flag = 0
    val annot = Annotation(time = 0, anntyp = NOTE)
    if (freq != oa.afreq && freq > 0.0) {
        annot.aux = makeAux(cformat("## time resolution: %.12g", freq))
        oa.afreq = freq
        if (putAnnWord(oa, n, annot, msgs) < 0) return -1
        flag = 1
    }
    for (a in 0 until NCODES) {
        if (defs.modified[a]) {
            if (flag < 2) {
                // mark the beginning of the table
                annot.aux = makeAux("## annotation type definitions".latin1())
                if (putAnnWord(oa, n, annot, msgs) < 0) return -1
            }
            val m = defs.astring[a]
            val d = defs.tstring[a]
            val s = if (d != null) cformat("%d %s %s", a, m, d) else cformat("%d %s ", a, m)
            annot.aux = makeAux(s.copyOf(minOf(s.size, 255)))
            if (putAnnWord(oa, n, annot, msgs) < 0) return -1
            flag = 2
        }
    }
    if (flag == 2) {
        // if a table was written, mark its end
        annot.aux = makeAux("## end of definitions".latin1())
        if (putAnnWord(oa, n, annot, msgs) < 0) return -1
    }
    if (flag != 0) {
        // if a table was written, mark its end
        annot.anntyp = 0
        annot.aux = null
        if (putAnnWord(oa, n, annot, msgs) < 0) return -1
    }
    return 0
}

/** The body of putann (after the table; wfdb-x), for the output annotator [oa] (number [n], in messages). Error messages are added to [msgs]. */
private fun putAnnWord(oa: OaData, n: Int, annot: Annotation, msgs: Msgs): Int {
    val t = annot.time
    val f = oa.file
    var delta: ULong = t.toULong() - oa.ann.time.toULong()
    if (!(annot.chan > oa.ann.chan || annot.num > oa.ann.num || t > oa.ann.time || (t == 0L && oa.ann.time == 0L))) {
        oa.outOfOrder = true
    }
    // aux length (a null aux, or an empty string, has none)
    val auxv = annot.aux
    val auxlen = if (auxv != null && auxv.isNotEmpty()) auxv[0].toInt() and 0xff else 0
    if (oa.info.stat == WFDB_AHA_WRITE) {
        // AHA-format output file
        f.putc(0)
        f.putc(wfdb_mamap(annot.anntyp, annot.subtyp))
        f.p32(t)
        oa.seqno += 1
        f.p16(oa.seqno)
        f.putc(annot.subtyp)
        f.putc(annot.anntyp)
        val len = minOf(auxlen, AUXLEN)
        val aux = auxv ?: ByteArray(0)
        for (k in 1..len) f.putc(if (k < aux.size) aux[k].toInt() else 0)
        for (k in len until AUXLEN) f.putc(0)
    } else {
        // MIT-format output file. Do not allow annotations to be written at
        // the minimum or maximum possible time value.
        if (t == WFDB_TIME_MIN || t == WFDB_TIME_MAX) {
            msgs.add(cformat("putann: time overflow in annotation file %d\n", n))
            return -1
        }
        if (t > oa.ann.time) {
            while (delta > MAXSKIP.toULong()) {
                f.p16(SKIP)
                f.p32(MAXSKIP)
                delta -= MAXSKIP.toULong()
            }
        } else {
            while ((0UL - delta) > (-MINSKIP).toULong()) {
                f.p16(SKIP)
                f.p32(MINSKIP)
                delta -= MINSKIP.toULong()
            }
        }
        if (annot.anntyp == 0) {
            // putann must not write a word of zeroes that would be
            // interpreted as an EOF, so it writes a SKIP to the location just
            // before the desired one; thus annwd is never 0.
            f.p16(SKIP)
            f.p32((delta - 1UL).toLong())
            delta = 1UL
        } else if (delta > MAXRR.toULong()) {
            // skip forward by more than MAXRR, or skip backward by any distance
            f.p16(SKIP)
            f.p32(delta.toLong())
            delta = 0UL
        }
        val annwd = delta.toInt() + (annot.anntyp shl CS)
        f.p16(annwd)
        if (annot.subtyp != 0) f.p16(SUB + (DATA and annot.subtyp))
        if (annot.chan != oa.ann.chan) f.p16(CHN + (DATA and annot.chan))
        if (annot.num != oa.ann.num) f.p16(NUM + (DATA and annot.num))
        if (auxlen != 0) {
            f.p16(AUX + auxlen)
            val aux = auxv!!
            val data = ByteArray(auxlen)
            for (k in 0 until auxlen) if (k + 1 < aux.size) data[k] = aux[k + 1]
            f.write(data)
            if ((auxlen and 1) != 0) f.putc(0)
        }
    }
    if (f.error()) {
        msgs.add(cformat("putann: write error on annotation file %s\n", oa.info.name))
        return -1
    }
    oa.ann.set(annot)
    oa.ann.time = t
    return 0
}

// ---------------------------------------------------------------------------
// Private functions (for the use of other WFDB library functions only)

/** `wfdb_oaflush()`: flushes output annotation files (called by wfdbflush). */
internal fun Wfdb.wfdb_oaflush() {
    for (oa in ann.oad) oa.file.flush()
}

/** `wfdb_anclose()`: closes all annotators (called by wfdbquit and annopen). */
internal fun Wfdb.wfdb_anclose() {
    for (an in ann.iad.size - 1 downTo 0) iannclose(an)
    for (an in ann.oad.size - 1 downTo 0) oannclose(an)
}

/** Reports the error messages [msgs] (with wfdb_error). */
private fun Wfdb.report(msgs: Msgs) {
    for (m in msgs) wfdb_error(m)
}

private fun Wfdb.getAnnTable(i: Int): Int {
    val msgs: Msgs = ArrayList()
    val status = readAnnTable(ann.iaAt(i)!!, ann.defs, msgs)
    report(msgs)
    if (status < 0) return -1
    setiafreq(i, getifreq())
    return 0
}

// ---------------------------------------------------------------------------
// WFDB library functions

/**
 * C `annopen(record, aiarray, nann)`: opens the annotation files of
 * [record] for the first [nann] annotators of [aiarray].
 *
 * Each [Anninfo] gives an annotator name (the file name suffix, e.g.
 * "atr") and a stat ([WFDB_READ], [WFDB_WRITE], [WFDB_AHA_READ] or
 * [WFDB_AHA_WRITE]). Input annotators are numbered from 0 in the order
 * given, and so are output annotators; these numbers are the n arguments of
 * getann, putann, ... Unless record begins with "+", previously opened
 * annotators are closed first. Files are found as [wfdb_open] finds them.
 *
 * Returns 0 on success, or: -3 if an input file cannot be opened, -4 if an
 * output file cannot be created (or an annotator name is illegal), -5 if a
 * stat is illegal. With nann == 0, the status of closing the previously
 * opened annotators: 0, -6 if an output annotation file was written out of
 * order (whether or not it could then be sorted), -7 on a write error.
 *
 * Translation of the C function annopen() (lib/annot.c, WFDB 10.7.0): same
 * arguments and results. Differences: the annotation files are found only where
 * they are named, not by a search of the WFDB path; see docs/DIVERGENCES.md.
 */
fun Wfdb.annopen(record0: ByteArray?, aiarray: Array<Anninfo>, nann0: Int): Int {
    ann.annclose_error = 0
    var record = record0?.let { cstr(it) } ?: ByteArray(0)
    if (record.isNotEmpty() && record[0] == '+'.code.toByte()) {
        // don't close open annotation files
        record = record.copyOfRange(1, record.size) // discard the '+' prefix
    } else {
        wfdb_anclose() // close previously opened annotation files
    }

    // If no annotation files are to be opened, report whether errors
    // occurred while closing previously-opened files.
    if (nann0 == 0) return ann.annclose_error
    val nann = minOf(nann0, aiarray.size)

    // Remove trailing .hea, if any, from record name.
    record = wfdb_striphea(record)

    // Check the stat of each annotator.
    for (k in 0 until nann) {
        val ai = aiarray[k]
        when (ai.stat) {
            WFDB_READ, WFDB_AHA_READ, WFDB_WRITE, WFDB_AHA_WRITE -> {}
            else -> {
                wfdb_error(cformat("annopen: illegal stat %d for annotator %s, record %s\n", ai.stat, cstr(ai.name), record))
                return -5
            }
        }
    }

    for (k in 0 until nann) {
        val ai = aiarray[k]
        // open the annotation files
        val name = cstr(ai.name)
        if (ai.stat == WFDB_READ || ai.stat == WFDB_AHA_READ) {
            // standard (MIT-format) or AHA-format input file
            wfdb_setirec(record)
            val file = wfdb_open(name, record, WFDB_READ)
            if (file == null) {
                wfdb_error(cformat("annopen: can't read annotator %s for record %s\n", name, record))
                return -3
            }
            val ia = IaData(file, Anninfo(ai.name, ai.stat))
            if (annFileFormat(ia) == WFDB_READ) {
                if (ai.stat != WFDB_READ) {
                    wfdb_error(cformat("warning (annopen, annotator %s, record %s):\n", name, record))
                    wfdb_error(" file appears to be in MIT format\n")
                    wfdb_error(" ... continuing under that assumption\n")
                }
                ia.info.stat = WFDB_READ
            } else {
                if (ai.stat != WFDB_AHA_READ) {
                    wfdb_error(cformat("warning (annopen, annotator %s, record %s):\n", name, record))
                    wfdb_error(" file appears to be in AHA format\n")
                    wfdb_error(" ... continuing under that assumption\n")
                }
                ia.info.stat = WFDB_AHA_READ
            }
            ann.iad.add(ia)
            getAnnTable(ann.iad.size - 1)
        } else {
            // standard (MIT-format) or AHA-format output file. Quit (with
            // message from wfdb_checkname) if name is illegal.
            if (wfdb_checkname(name, "annotator") != 0) return -4
            val file = wfdb_open(name, record, WFDB_WRITE)
            if (file == null) {
                wfdb_error(cformat("annopen: can't write annotator %s for record %s\n", name, record))
                return -4
            }
            // wfdb-x: the name of the file, for sortAnnFile
            ann.oad.add(OaData(file, Anninfo(ai.name, ai.stat), record, wfdb_filename().copyOf()))
        }
    }
    return 0
}

/** [annopen] with a string record name. */
fun Wfdb.annopen(record: String?, aiarray: Array<Anninfo>, nann: Int): Int = annopen(record?.latin1(), aiarray, nann)

/**
 * C `getann(n, &annot)`: reads the next annotation from input annotator
 * [n] into [annot].
 *
 * Returns 0 on success, or: -1 at the end of the file (annot is then not
 * valid), -2 if n is not an open input annotator, -3 at an unexpected end
 * of file.
 *
 * Compatibility: in C, annot.aux points into a 771-byte buffer of the
 * library, and the library has already read the following annotation
 * (whose aux data go into the same buffer) when getann returns. To give the
 * same results, annot.aux is copied from that buffer after the following
 * annotation has been read: where C would return aux data partly
 * overwritten by those of the following annotation, so does this function.
 *
 * Translation of the C function getann() (lib/annot.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.getann(n: Int, annot: Annotation): Int {
    val ia = ann.iaAt(n)
    if (ia == null) {
        wfdb_error(cformat("getann: can't read annotator %d\n", n))
        return -2
    }
    val msgs: Msgs = ArrayList()
    val status = getannIa(ia, annot, msgs)
    report(msgs)
    return status
}

/**
 * C `ungetann(n, &annot)`: pushes back an annotation into input annotator
 * [n], so that the next getann returns it (one annotation at most).
 * Returns 0, -1 if the push-back buffer is full, -2 if n is not an open
 * input annotator.
 *
 * Translation of the C function ungetann() (lib/annot.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.ungetann(n: Int, annot: Annotation): Int {
    val ia = ann.iaAt(n)
    if (ia == null) {
        wfdb_error(cformat("ungetann: annotator %d is not initialized\n", n))
        return -2
    }
    if (ia.pann.anntyp != 0) {
        wfdb_error("ungetann: pushback buffer is full\n")
        wfdb_error(cformat("ungetann: annotation at %lld, annotator %d not pushed back\n", annot.time, n))
        return -1
    }
    ungetannIa(ia, annot)
    return 0
}

/**
 * C `putann(n, &annot)`: writes an annotation to output annotator [n].
 * Returns 0, -1 on a write error (or a time overflow), -2 if n is not an
 * open output annotator.
 *
 * Translation of the C function putann() (lib/annot.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.putann(n: Int, annot: Annotation): Int {
    val oa = ann.oaAt(n)
    if (oa == null) {
        wfdb_error(cformat("putann: can't write annotation file %d\n", n))
        return -2
    }
    val msgs: Msgs = ArrayList()
    var status = 0
    if (!oa.tableWritten) {
        oa.tableWritten = true
        status = putAnnTable(oa, n, ann.oafreq, ann.defs, msgs)
    }
    if (status == 0) status = putAnnWord(oa, n, annot, msgs)
    report(msgs)
    return status
}

/**
 * wfdb-x: [putann] for each of [count] annotations given by columns (for
 * writeAnnotations): annotation k has time `times[k]`, type `anntyps[k]`,
 * subtype `subtyps[k]`, channel `chans[k]`, number `nums[k]` (converted to
 * their C types as by the [Annotation] setters) and aux `auxes[k]` (null,
 * or a length byte and the text, as [Annotation.aux]).
 *
 * In an MIT-format file, the annotations are encoded into one buffer, byte
 * for byte as putann encodes them, and written at once (calling putann
 * for each was the slowest part of writing a file); other formats use
 * putann. An annotation that putann rejects (time overflow) is skipped,
 * with putann's message. Returns 0, -1 on a write error, or -2 if [n] is
 * not an open output annotator.
 */
internal fun Wfdb.putanns(
    n: Int, count: Int, times: LongArray, anntyps: IntArray, subtyps: IntArray,
    chans: IntArray, nums: IntArray, auxes: Array<ByteArray?>,
): Int {
    val oa = ann.oaAt(n)
    if (oa == null) {
        wfdb_error(cformat("putann: can't write annotation file %d\n", n))
        return -2
    }
    if (oa.info.stat != WFDB_WRITE) {
        var stat = 0
        for (k in 0 until count) {
            val a = Annotation(times[k], anntyps[k], subtyps[k], chans[k], nums[k], auxes[k])
            if (putann(n, a) == -1 && stat == 0) stat = -1
        }
        return stat
    }
    if (count == 0) return 0
    val msgs: Msgs = ArrayList()
    if (!oa.tableWritten) {
        oa.tableWritten = true
        if (putAnnTable(oa, n, ann.oafreq, ann.defs, msgs) < 0) {
            report(msgs)
            return -1
        }
    }
    val f = oa.file
    val buf = ByteVec(65536 + 1024)
    fun p16(x: Int) {
        buf.add(x)
        buf.add(x shr 8)
    }
    fun p32(x: Long) {
        p16((x shr 16).toInt())
        p16(x.toInt())
    }
    // The previous annotation written: time, chan (unsigned char) and num
    // (signed char) are all that the encoding uses.
    var pt = oa.ann.time
    var pchan = oa.ann.chan
    var pnum = oa.ann.num
    var last = -1
    var outOfOrder = oa.outOfOrder
    var stat = 0
    for (k in 0 until count) {
        val t = times[k]
        val anntyp = anntyps[k].toByte().toInt()
        val subtyp = subtyps[k].toByte().toInt()
        val achan = chans[k] and 0xff
        val anum = nums[k].toByte().toInt()
        if (!(achan > pchan || anum > pnum || t > pt || (t == 0L && pt == 0L))) outOfOrder = true
        if (t == WFDB_TIME_MIN || t == WFDB_TIME_MAX) {
            msgs.add(cformat("putann: time overflow in annotation file %d\n", n))
            stat = -1
            continue
        }
        var delta: ULong = t.toULong() - pt.toULong()
        if (t > pt) {
            while (delta > MAXSKIP.toULong()) {
                p16(SKIP)
                p32(MAXSKIP)
                delta -= MAXSKIP.toULong()
            }
        } else {
            while ((0UL - delta) > (-MINSKIP).toULong()) {
                p16(SKIP)
                p32(MINSKIP)
                delta -= MINSKIP.toULong()
            }
        }
        if (anntyp == 0) {
            p16(SKIP)
            p32((delta - 1UL).toLong())
            delta = 1UL
        } else if (delta > MAXRR.toULong()) {
            p16(SKIP)
            p32(delta.toLong())
            delta = 0UL
        }
        p16(delta.toInt() + (anntyp shl CS))
        if (subtyp != 0) p16(SUB + (DATA and subtyp))
        if (achan != pchan) p16(CHN + (DATA and achan))
        if (anum != pnum) p16(NUM + (DATA and anum))
        val aux = auxes[k]
        val auxlen = if (aux != null && aux.isNotEmpty()) aux[0].toInt() and 0xff else 0
        if (auxlen != 0) {
            p16(AUX + auxlen)
            val avail = minOf(auxlen, aux!!.size - 1)
            buf.addAll(aux, 1, avail)
            // (zero padding to the stated length, and to an even length)
            buf.fill(0, auxlen - avail + (auxlen and 1))
        }
        pt = t
        pchan = achan
        pnum = anum
        last = k
        if (buf.size >= 65536) {
            f.write(buf.bytes, 0, buf.size)
            buf.clear()
        }
    }
    if (buf.size > 0) f.write(buf.bytes, 0, buf.size)
    oa.outOfOrder = outOfOrder
    if (f.error()) {
        msgs.add(cformat("putann: write error on annotation file %s\n", oa.info.name))
        stat = -1
    } else if (last >= 0) {
        oa.ann.set(Annotation(times[last], anntyps[last], subtyps[last], chans[last], nums[last], auxes[last]))
    }
    report(msgs)
    return stat
}

/**
 * C `iannsettime(t)`: skips ahead (or rewinds) the input annotators so that
 * the next annotation read from each has a time >= t (negative values are
 * treated as positive, except WFDB_TIME_MIN, which rewinds to the very
 * beginning). Returns 0, or -1 if no input annotator remains valid.
 *
 * Translation of the C function iannsettime() (lib/annot.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.iannsettime(t0: Long): Int {
    var t = t0
    var stat = 0
    var niavalid = ann.iad.size
    val tempann = Annotation()

    // Handle negative arguments as equivalent positive arguments. As an
    // exception, WFDB_TIME_MIN indicates that we should rewind to the very
    // beginning of the annotation file, even if there are annotations at
    // negative time values.
    if (t < 0 && t != WFDB_TIME_MIN) t = -t

    for (i in 0 until ann.iad.size) {
        val ia = ann.iaAt(i)!!
        if (ia.ann.time >= t) {
            // "rewind" the annotation file
            ia.pann.anntyp = 0 // flush pushback buffer
            if (ia.file.seek(0, SEEK_SET) == -1) {
                wfdb_error("iannsettime: improper seek\n")
                return -1
            }
            ia.ann.subtyp = 0
            ia.ann.chan = 0
            ia.ann.num = 0
            ia.ateof = 0
            ia.ann.time = 0
            ia.tt = 0.0
            ia.word = ia.file.g16()
            if (ia.info.stat == WFDB_READ) {
                while ((ia.word and CODE) == SKIP) {
                    ia.tt += ia.file.g32().toDouble()
                    ia.word = ia.file.g16()
                }
            }
            getann(i, tempann)
        }
        while (ia.ann.time < t) {
            stat = getann(i, tempann)
            if (stat != 0) break
        }
        if (stat < 0) niavalid--
    }
    return if (niavalid > 0) 0 else -1
}

// ---------------------------------------------------------------------------
// Conversion between annotation codes, mnemonics, and descriptions

/**
 * C `ecgstr(code)`: the fixed mnemonic of an annotation code ("[N]" for codes
 * outside 0..ACMAX).
 *
 * Translation of the C function ecgstr() (lib/annot.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.ecgstr(code: Int): ByteArray = if (code in 0..ACMAX) ann.cstring[code].copyOf() else cformat("[%d]", code)

/**
 * C `strecg(str)`: the annotation code of a fixed mnemonic (NOTQRS if none).
 *
 * Translation of the C function strecg() (lib/annot.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.strecg(s0: ByteArray?): Int {
    val s = s0?.let { cstr(it) } ?: ByteArray(0)
    for (code in 1..ACMAX) if (ann.cstring[code].contentEquals(s)) return code
    return NOTQRS
}

/** [strecg] with a string. */
fun Wfdb.strecg(s: String): Int = strecg(s.latin1())

/**
 * C `setecgstr(code, string)`: modifies the fixed mnemonic of an
 * annotation code (the one ecgstr and strecg use). Returns 0, or -1 if code
 * is outside 0..ACMAX.
 *
 * Translation of the C function setecgstr() (lib/annot.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.setecgstr(code: Int, s0: ByteArray?): Int {
    if (code in NOTQRS..ACMAX) {
        ann.cstring[code] = s0?.let { cstr(it) } ?: ByteArray(0)
        return 0
    }
    wfdb_error(cformat("setecgstr: illegal annotation code %d\n", code))
    return -1
}

/** [setecgstr] with a string. */
fun Wfdb.setecgstr(code: Int, s: String): Int = setecgstr(code, s.latin1())

/** wfdb-x (for checkRecord): the annotation mnemonics and descriptions, to be restored by [wfdbxRestoreAnnDefs]. */
internal fun Wfdb.wfdbxSaveAnnDefs(): AnnDefs = ann.defs.copy()

/** wfdb-x (for checkRecord): restores the annotation mnemonics and descriptions saved by [wfdbxSaveAnnDefs]. */
internal fun Wfdb.wfdbxRestoreAnnDefs(defs: AnnDefs) {
    ann.defs = defs
}

/**
 * C `annstr(code)`: the (possibly redefined) mnemonic of an annotation code
 * ("[N]" for codes outside 0..ACMAX).
 *
 * Translation of the C function annstr() (lib/annot.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.annstr(code: Int): ByteArray = if (code in 0..ACMAX) ann.defs.astring[code].copyOf() else cformat("[%d]", code)

/**
 * C `strann(str)`: the annotation code of a mnemonic (NOTQRS if none).
 *
 * Translation of the C function strann() (lib/annot.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.strann(s0: ByteArray?): Int {
    val s = s0?.let { cstr(it) } ?: ByteArray(0)
    for (code in 1..ACMAX) if (ann.defs.astring[code].contentEquals(s)) return code
    return NOTQRS
}

/** [strann] with a string. */
fun Wfdb.strann(s: String): Int = strann(s.latin1())

/**
 * C `setannstr(code, string)`: redefines the mnemonic of an annotation
 * code. With a positive code, the change is recorded in the modification
 * labels of output annotation files written later; with a negative code
 * (-code is modified), it is not. Returns 0, or -1 if the code is outside
 * 0..ACMAX.
 *
 * Translation of the C function setannstr() (lib/annot.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.setannstr(code: Int, s0: ByteArray?): Int {
    val s = s0?.let { cstr(it) } ?: ByteArray(0)
    if (ann.defs.set(false, code, s) == 0) return 0
    wfdb_error(cformat("setannstr: illegal annotation code %d\n", if (code > 0) code else -code))
    return -1
}

/** [setannstr] with a string. */
fun Wfdb.setannstr(code: Int, s: String): Int = setannstr(code, s.latin1())

/**
 * C `anndesc(code)`: the description of an annotation code (null if it has
 * none; "illegal annotation code" for codes outside 0..ACMAX).
 *
 * Translation of the C function anndesc() (lib/annot.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.anndesc(code: Int): ByteArray? =
    if (code in 0..ACMAX) ann.defs.tstring[code]?.copyOf() else "illegal annotation code".latin1()

/**
 * C `setanndesc(code, string)`: redefines the description of an annotation
 * code (see [setannstr] for the sign of code). Returns 0, or -1 if the code
 * is outside 0..ACMAX.
 *
 * Translation of the C function setanndesc() (lib/annot.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.setanndesc(code: Int, s0: ByteArray?): Int {
    val s = s0?.let { cstr(it) } ?: ByteArray(0)
    if (ann.defs.set(true, code, s) == 0) return 0
    wfdb_error(cformat("setanndesc: illegal annotation code %d\n", if (code > 0) code else -code))
    return -1
}

/** [setanndesc] with a string. */
fun Wfdb.setanndesc(code: Int, s: String): Int = setanndesc(code, s.latin1())

// ---------------------------------------------------------------------------
// Time resolution

/**
 * C `setafreq(f)`: sets the time resolution (ticks per second) of output
 * annotation files opened later (0: the sampling frequency).
 *
 * Translation of the C function setafreq() (lib/annot.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.setafreq(f: Double) {
    ann.oafreq = f
}

/**
 * C `getafreq()`: the time resolution of output annotation files.
 *
 * Translation of the C function getafreq() (lib/annot.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.getafreq(): Double = ann.oafreq

/**
 * C `setiafreq(n, f)`: sets the time resolution in which the times of the
 * annotations of input annotator [n] are returned.
 *
 * Translation of the C function setiafreq() (lib/annot.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.setiafreq(n: Int, f: Double) {
    val ia = ann.iaAt(n) ?: return
    val tmul = if (f > 0.0 && ia.afreq > 0.0) {
        f / ia.afreq
    } else if (f > 0.0) {
        val sfreq = sampfreq(null)
        if (sfreq > 0.0) f * getspf().toDouble() / sfreq else 1.0
    } else {
        1.0
    }
    ia.tmul = tmul
    ia.ann.time = roundToTime(ia.annTt * ia.tmul)
    ia.pann.time = roundToTime(ia.pannTt * ia.tmul)
    ia.prevTime = roundToTime(ia.prevTt * ia.tmul)
}

/**
 * C `getiafreq(n)`: the time resolution of the annotation times returned for
 * input annotator [n] (-2 if n is not open).
 *
 * Translation of the C function getiafreq() (lib/annot.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.getiafreq(n: Int): Double {
    val ia = ann.iaAt(n) ?: return -2.0
    if (ia.afreq > 0.0) return ia.afreq * ia.tmul
    return sampfreq(null) * ia.tmul / getspf().toDouble()
}

/**
 * C `getiaorigfreq(n)`: the time resolution recorded in the file of input
 * annotator [n] (0 if none; -2 if n is not open).
 *
 * Translation of the C function getiaorigfreq() (lib/annot.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.getiaorigfreq(n: Int): Double = ann.iaAt(n)?.afreq ?: -2.0

// ---------------------------------------------------------------------------
// Closing annotators

/**
 * C `iannclose(n)`: closes input annotator [n] (the annotators after it are
 * renumbered, as in C).
 *
 * Translation of the C function iannclose() (lib/annot.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.iannclose(n: Int) {
    if (n in ann.iad.indices) {
        val ia = ann.iad.removeAt(n)
        ia.file.close()
    }
}

/**
 * C `oannclose(n)`: closes output annotator [n], writing its end mark. If
 * its annotations were not written in canonical order, the file is
 * rearranged (unless the environment variable WFDBANNSORT is 0): wfdb-x: in
 * this process, with the result of the sortann program (see [AnnList]); in
 * legacy mode, as in C, by running sortann ([run_sortann]).
 *
 * Translation of the C function oannclose() (lib/annot.c, WFDB 10.7.0): same
 * arguments and results. Differences: an out-of-order file is sorted in this
 * process, without losing annotations, instead of by running sortann; see
 * docs/DIVERGENCES.md.
 */
fun Wfdb.oannclose(n: Int) {
    if (n !in ann.oad.indices) return
    val oa = ann.oad.removeAt(n)
    val f = oa.file
    when (oa.info.stat) {
        WFDB_WRITE -> f.p16(0) // write logical EOF for MIT-format files
        WFDB_AHA_WRITE -> {
            // write logical EOF for AHA-format files
            val pos = f.tell() and 0xffffffffL
            var i = ABLKSIZ - pos % ABLKSIZ
            while (i > 0) {
                f.putc(EOAF)
                i--
            }
        }
    }
    var errflag = f.error()
    if (f.close() != 0) errflag = true
    val name = cstr(oa.info.name)
    if (errflag) {
        wfdb_error(cformat("oannclose: write error on annotation file %s\n", name))
        ann.annclose_error = -7
    }
    var outOfOrder = oa.outOfOrder
    if (outOfOrder) {
        // wfdb-x: the sort option of writeAnnotations, if given, decides
        // instead of WFDBANNSORT.
        val so = ann.sortOverride
        val env = getenv("WFDBANNSORT")
        val dosort = if (so != null) (if (so) 1 else 0) else if (env != null) strtol(env, 10).value.toInt() else DEFWFDBANNSORT
        if (dosort != 0) {
            wfdb_error(cformat("Rearranging annotations for output annotator %s ...", name))
            // wfdb-x: the file is sorted in this process (sortAnnFile); the
            // C library ran the sortann program, as legacy mode does.
            val sorted = if (legacy) {
                run_sortann(oa.rname, name, wfdbx_get_output_dir()) == 0
            } else {
                sortAnnFile(oa.fname, name) == 0
            }
            if (sorted) {
                wfdb_error("done!\n")
                outOfOrder = false
            } else {
                wfdb_error("\nAnnotations still need to be rearranged.\n")
            }
            if (ann.annclose_error == 0) ann.annclose_error = -6
        }
    }
    // wfdb-x: no advice to run sortann when the caller of writeAnnotations
    // chose not to sort.
    if (outOfOrder && ann.sortOverride != false) {
        wfdb_error(cformat("Use the command:\n  sortann -r %s -a %s\n", oa.rname, name))
        wfdb_error("to rearrange annotations in the correct order.\n")
        if (ann.annclose_error == 0) ann.annclose_error = -6
    }
}

// ---------------------------------------------------------------------------
// In-process sorting of output annotation files (wfdb-x)

/** `a` follows `b` in canonical order (sortann.c; orSame: or they have the same time, num and chan). */
private fun after(a: Annotation, b: Annotation, orSame: Boolean): Boolean =
    a.time > b.time || (a.time == b.time && a.num > b.num) ||
        (a.time == b.time && a.num == b.num && (a.chan > b.chan || (orSame && a.chan == b.chan)))

/**
 * The annotation list of the sortann program (insert_ann in
 * app/sortann.c), used by the sortann tool and by oannclose.
 *
 * Annotations are inserted in canonical order (time, then num, then chan)
 * with the algorithm of insert_ann, including its rule for duplicates: an
 * annotation with the same time, num and chan as one already in the list
 * replaces it (but only when the duplicate is found while repairing
 * out-of-order input).
 *
 * wfdb-x: the (all-zero) list head is never compared as an annotation: an
 * out-of-order annotation that precedes all entries is inserted at the
 * beginning of the list. In C, and with [legacy] true, an annotation at
 * time 0 with num and chan 0 that precedes all entries "replaces" the head,
 * and neither it nor any annotation later inserted after it is in the list
 * (input times 5, 0, 3 give only 5; see docs/KNOWN_C_BEHAVIORS.md,
 * "sortann loses annotations"). Where C has undefined behavior (a replaced
 * first entry that is not linked back to the head), the head is updated,
 * in both modes.
 */
class AnnList(private val legacy: Boolean = false) {
    // Entry 0 is the list head (annlist), whose annotation is all zeros and
    // which takes part in comparisons exactly as in sortann.c. Links: -1 is
    // a null link.
    private val anns = ArrayList<Annotation>()
    private var next = IntArray(16)
    private var prev = IntArray(16)
    private var lastp = 0
    private var inOrder = true

    init {
        anns.add(Annotation())
        next[0] = -1
        prev[0] = -1
    }

    /** Whether all annotations were inserted in order (sortann then writes nothing). */
    fun inOrder(): Boolean = inOrder

    /** The annotations of the list, in order. */
    fun toList(): List<Annotation> {
        val r = ArrayList<Annotation>()
        var p = next[0]
        while (p >= 0) {
            r.add(anns[p])
            p = next[p]
        }
        return r
    }

    /** Inserts a copy of [pa] (insert_ann). */
    fun insert(pa: Annotation) {
        val newp = anns.size
        anns.add(pa.copy())
        if (newp >= next.size) {
            next = next.copyOf(newp * 2)
            prev = prev.copyOf(newp * 2)
        }
        next[newp] = -1
        prev[newp] = -1
        val last = lastp
        if (last == 0 || after(pa, anns[last], false)) {
            // this annotation is in order -- add to end of list
            prev[newp] = last
            next[last] = newp
            lastp = newp
            return
        }
        inOrder = false // input was out-of-order

        // Find the correct location in the list for this annotation. The
        // search is linear, beginning at the end of the list.
        var ap = last
        while (ap >= 0) {
            if (ap == 0 && !legacy) {
                // wfdb-x: the head is not an annotation (C compared it, and
                // took a (0, 0, 0) annotation for its duplicate)
                ap = -1
                break
            }
            if (after(pa, anns[ap], true)) break
            ap = prev[ap]
        }
        if (ap < 0) {
            // insert newp at the beginning of the list
            val nx = next[0]
            next[newp] = nx
            next[0] = newp
            if (nx >= 0) prev[nx] = newp
            return
        }
        val aa = anns[ap]
        if (pa.time == aa.time && pa.num == aa.num && pa.chan == aa.chan) {
            // replace ap by newp
            val pv = prev[ap]
            val nx = next[ap]
            prev[newp] = pv
            if (pv >= 0) next[pv] = newp
            next[newp] = nx
            if (nx >= 0) prev[nx] = newp else lastp = newp
            // If ap was the first entry of the list but its 'prev' link does
            // not lead back to the list head (an entry inserted at the
            // beginning gets a null link, and one whose predecessor replaced
            // the head is detached), C leaves the head pointing to the freed
            // entry (undefined behavior): here the head is updated, so that
            // the duplicate is replaced (see docs/KNOWN_C_BEHAVIORS.md).
            if (ap != 0 && next[0] == ap) next[0] = newp
        } else {
            // insert newp immediately after ap
            val nx = next[ap]
            prev[newp] = ap
            next[newp] = nx
            if (nx >= 0) prev[nx] = newp
            next[ap] = newp
        }
    }
}

/**
 * wfdb-x: rearranges the annotations of the (closed) annotation file
 * [fname] of annotator [aname] in canonical order, with a result identical,
 * byte for byte, to that of the sortann program as the C library ran it
 * (sortann -r. RECORD -a ANNOTATOR, see oannclose), but without looking up
 * the header of the record. As sortann does, it reads the file (with any
 * time resolution and annotation type definitions it contains), inserts its
 * annotations at nonnegative times in an [AnnList], and, unless they were
 * already in order, rewrites the file in MIT format, with the time
 * resolution of the input file (if any) and without the NOTQRS
 * annotations. It uses its own reader, writer and definition table (the
 * annotators and tables of the instance are not changed). Returns 0, or -1
 * if the file cannot be read or written.
 */
private fun Wfdb.sortAnnFile(fname: ByteArray, aname: ByteArray): Int {
    val msgs: Msgs = ArrayList()
    val status = sortAnnFileBody(fname, aname, msgs)
    report(msgs)
    return status
}

private fun sortAnnFileBody(fname: ByteArray, aname: ByteArray, msgs: Msgs): Int {
    // Read the file, starting from the default definition table.
    val defs = AnnDefs()
    val file = localFopen(fname, "rb", false) ?: return -1
    val ia = IaData(file, Anninfo(aname, 0))
    ia.info.stat = annFileFormat(ia)
    readAnnTable(ia, defs, msgs)
    val list = AnnList()
    val annot = Annotation()
    var status: Int
    while (true) {
        status = getannIa(ia, annot, msgs)
        if (status != 0) break
        if (annot.time >= 0) list.insert(annot) // (sortann's -f time is 0)
    }
    ia.file.close()
    if (status != -1) return -1 // not the logical end of the file
    if (list.inOrder()) return 0

    // Write the sorted annotations.
    val out = localFopen(fname, "wb", false) ?: return -1
    val oa = OaData(out, Anninfo(aname, WFDB_WRITE), ByteArray(0), fname)
    var ok = true
    for (a in list.toList()) {
        if (a.anntyp == NOTQRS) continue
        if (!oa.tableWritten) {
            oa.tableWritten = true
            ok = putAnnTable(oa, 0, ia.afreq, defs, msgs) == 0
        }
        if (!ok || putAnnWord(oa, 0, a, msgs) < 0) {
            ok = false
            break
        }
    }
    oa.file.p16(0)
    if (oa.file.error()) ok = false
    if (oa.file.close() != 0) ok = false
    return if (ok) 0 else -1
}

// ---------------------------------------------------------------------------
// Top-level functions (default instance)

/** C `annopen` on the default instance. */
fun annopen(record: ByteArray?, aiarray: Array<Anninfo>, nann: Int): Int = wfdbDefault().annopen(record, aiarray, nann)

/** C `annopen` on the default instance. */
fun annopen(record: String?, aiarray: Array<Anninfo>, nann: Int): Int = wfdbDefault().annopen(record, aiarray, nann)

/** C `getann` on the default instance. */
fun getann(n: Int, annot: Annotation): Int = wfdbDefault().getann(n, annot)

/** C `ungetann` on the default instance. */
fun ungetann(n: Int, annot: Annotation): Int = wfdbDefault().ungetann(n, annot)

/** C `putann` on the default instance. */
fun putann(n: Int, annot: Annotation): Int = wfdbDefault().putann(n, annot)

/** C `iannsettime` on the default instance. */
fun iannsettime(t: Long): Int = wfdbDefault().iannsettime(t)

/** C `ecgstr` on the default instance. */
fun ecgstr(code: Int): ByteArray = wfdbDefault().ecgstr(code)

/** C `strecg` on the default instance. */
fun strecg(s: ByteArray?): Int = wfdbDefault().strecg(s)

/** C `strecg` on the default instance. */
fun strecg(s: String): Int = wfdbDefault().strecg(s)

/** C `setecgstr` on the default instance. */
fun setecgstr(code: Int, s: ByteArray?): Int = wfdbDefault().setecgstr(code, s)

/** C `setecgstr` on the default instance. */
fun setecgstr(code: Int, s: String): Int = wfdbDefault().setecgstr(code, s)

/** C `annstr` on the default instance. */
fun annstr(code: Int): ByteArray = wfdbDefault().annstr(code)

/** C `strann` on the default instance. */
fun strann(s: ByteArray?): Int = wfdbDefault().strann(s)

/** C `strann` on the default instance. */
fun strann(s: String): Int = wfdbDefault().strann(s)

/** C `setannstr` on the default instance. */
fun setannstr(code: Int, s: ByteArray?): Int = wfdbDefault().setannstr(code, s)

/** C `setannstr` on the default instance. */
fun setannstr(code: Int, s: String): Int = wfdbDefault().setannstr(code, s)

/** C `anndesc` on the default instance. */
fun anndesc(code: Int): ByteArray? = wfdbDefault().anndesc(code)

/** C `setanndesc` on the default instance. */
fun setanndesc(code: Int, s: ByteArray?): Int = wfdbDefault().setanndesc(code, s)

/** C `setanndesc` on the default instance. */
fun setanndesc(code: Int, s: String): Int = wfdbDefault().setanndesc(code, s)

/** C `setafreq` on the default instance. */
fun setafreq(f: Double) = wfdbDefault().setafreq(f)

/** C `getafreq` on the default instance. */
fun getafreq(): Double = wfdbDefault().getafreq()

/** C `setiafreq` on the default instance. */
fun setiafreq(n: Int, f: Double) = wfdbDefault().setiafreq(n, f)

/** C `getiafreq` on the default instance. */
fun getiafreq(n: Int): Double = wfdbDefault().getiafreq(n)

/** C `getiaorigfreq` on the default instance. */
fun getiaorigfreq(n: Int): Double = wfdbDefault().getiaorigfreq(n)

/** C `iannclose` on the default instance. */
fun iannclose(n: Int) = wfdbDefault().iannclose(n)

/** C `oannclose` on the default instance. */
fun oannclose(n: Int) = wfdbDefault().oannclose(n)
