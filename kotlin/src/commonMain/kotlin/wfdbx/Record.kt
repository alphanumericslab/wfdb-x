// The high-level functions: read and write whole records and annotation
// files in one call (port of python/src/wfdbx/highlevel.py, through
// rust/src/record.rs and cpp/src/record.cpp).
//
// | Function | What it does |
// |---|---|
// | readRecord | reads the signals of a record into a Record |
// | readHeader | reads the header of a record into a Header |
// | readAnnotations | reads an annotation file into an Annotations |
// | writeRecord | writes a header and a signal file (ADC or physical units) |
// | writeAnnotations | writes an annotation file |
// | wfdbxSetInputDir, ... | the input and output directories, network access and legacy mode |
//
// Each function is an extension function of Wfdb (`w.readRecord(...)`) and
// a top-level function using the default instance of the thread
// (`readRecord(...)`). Errors are thrown as WfdbException. Text read from
// files (signal descriptions, units, info strings, aux strings, mnemonics)
// is given as String with one character per byte (ISO-8859-1), so that
// every byte round-trips; record, annotator and directory names are file
// names, converted with the platform's file name encoding.
//
// Values that the record or the user does not give (sampling frequency, gain,
// ADC resolution, units) are never assumed; legacy = true gives the behavior
// of the original package. Files are found by explicit names (the input
// directory, the output directory, or a full path or URL), not by a search of
// the WFDB path, and a server is accessed only if asked for (network = true);
// the readers take inputDir and network, and the writers take dir, for one
// call. A checksum error (getvec status -4: the samples are complete, their
// sum does not match the header's checksums) is not an error of readRecord
// but a warning; the data are returned, and Record.checksumOk is false. See
// docs/DIVERGENCES.md.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It has no counterpart in the original package.
//
// Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx

import wfdbx.cstd.Platform
import wfdbx.cstd.cstr
import wfdbx.cstd.d2i
import wfdbx.cstd.latin1

/**
 * The error thrown by the high-level functions ([readRecord], [readHeader],
 * [readAnnotations], [writeRecord], [writeAnnotations], [checkRecord]). Its
 * message says what failed, such as `can't read record 100s` or
 * `can't read signal data of record 100s (getvec status -3)`.
 */
class WfdbException(message: String) : Exception(message)

/**
 * A time in a record: a sample number ([TimeSpec.Sample]) or a WFDB time
 * string ([TimeSpec.Text]), as `strtim` accepts it: an elapsed time
 * (`"0:10"`, `"1:02:03.5"`), a sample number (`"s3600"`), a time of day
 * (`"[12:00:00]"`) or `"e"` (the end of the record). A time in seconds
 * needs the sampling frequency.
 *
 * `TimeSpec(3600)` and `TimeSpec("0:10")` make one.
 */
sealed class TimeSpec {
    /** A sample number. */
    data class Sample(val sample: Long) : TimeSpec()

    /** A time string (converted with `strtim` for the open record). */
    data class Text(val text: String) : TimeSpec()

    companion object {
        /** A sample number. */
        operator fun invoke(sample: Long): TimeSpec = Sample(sample)

        /** A sample number. */
        operator fun invoke(sample: Int): TimeSpec = Sample(sample.toLong())

        /** A time string. */
        operator fun invoke(text: String): TimeSpec = Text(text)
    }
}

/** A date: year, month (1-12) and day (1-31). */
data class BaseDate(val year: Int, val month: Int, val day: Int)

/**
 * The signals of a record, or of a part of one, as returned by [readRecord].
 *
 * The samples are stored frame by frame in one array: `samples[i * nsig +
 * s]` is sample `i` of signal `s` (in ADC units; [at] returns it). With
 * `physical = true`, [physical] holds the same samples in physical units,
 * in the same layout.
 *
 * Arrays are compared by content in [equals].
 */
data class Record(
    /** Record name, as given to readRecord. */
    val name: String,
    /**
     * Sampling frequency in Hz, or 0 if the header gives none. With
     * `highres = true`, that of the fastest signal of a multi-frequency
     * record.
     */
    val fs: Double,
    /** Number of signals returned. */
    val nsig: Int,
    /** The number, in the record, of each returned signal. */
    val signalNumbers: IntArray,
    /**
     * Samples in ADC units, frame by frame (`samples[i * nsig + s]`).
     * Invalid samples are [WFDB_INVALID_SAMPLE].
     */
    val samples: IntArray,
    /**
     * With `physical = true`: the samples in physical units, as
     * `(adc - baseline) / gain`, in the layout of [samples] (NaN for an
     * invalid sample); otherwise null.
     */
    val physical: DoubleArray?,
    /**
     * Signal specifications, one per returned signal. A signal's `adcres` is
     * 0 if the header does not give it, and its `desc` has no white space at
     * either end.
     */
    val siginfo: List<Siginfo>,
    /**
     * Description of each signal, such as "MLII" ("" if none), without the
     * white space that a header may put at either end of it.
     */
    val names: List<String>,
    /** Physical units of each signal, or null if the header gives none. */
    val units: List<String?>,
    /** Gain of each signal, in ADC units per physical unit; 0 means uncalibrated. */
    val gains: List<Double>,
    /** ADC value of each signal that corresponds to 0 physical units. */
    val baselines: List<Int>,
    /** Start time and date as text, to the second, such as "[14:00:03 21/06/2024]", or null if the header gives none. */
    val baseTime: String?,
    /** Start time in milliseconds after midnight, such as 50403500 for 14:00:03.500; null when [baseTime] is null. */
    val baseTimeMs: Long?,
    /** Start date, or null if the header gives none. */
    val baseDate: BaseDate?,
    /** Number of the first sample returned. */
    val sampfrom: Long,
    /** The info strings of the header (and of the record's .info file, if any). */
    val comments: List<String>,
    /**
     * False if the data do not match the header's checksums. Checksums are
     * only checked when a read reaches the end of the record, so a shorter
     * read gives true.
     */
    val checksumOk: Boolean,
    /** True if the record was read in legacy mode (a gain of 200 is then used for uncalibrated signals). */
    val legacy: Boolean = false,
) {
    /** The number of samples per signal (the number of frames, or of sample vectors with `highres`). */
    val nsamples: Int get() = if (nsig == 0) 0 else samples.size / nsig

    /** Sample [i] of signal [s], in ADC units. */
    fun at(i: Int, s: Int): Int = samples[i * nsig + s]

    /** All samples of signal [s], in ADC units. */
    fun signal(s: Int): IntArray {
        require(s in 0 until nsig) { "no signal $s" }
        return IntArray(nsamples) { samples[it * nsig + s] }
    }

    /**
     * Sample [i] of signal [s] in physical units, `(adc - baseline) /
     * gain` (NaN for an invalid sample).
     *
     * @throws WfdbException if the signal is uncalibrated: "signal N of
     *   record REC is uncalibrated"
     */
    fun physicalAt(i: Int, s: Int): Double {
        val g = calibratedGain(s)
        val v = at(i, s)
        return if (v == WFDB_INVALID_SAMPLE) Double.NaN else (v.toDouble() - siginfo[s].baseline.toDouble()) / g
    }

    /**
     * All samples of signal [s] in physical units (see [physicalAt]).
     *
     * @throws WfdbException if the signal is uncalibrated
     */
    fun physicalSignal(s: Int): DoubleArray {
        val g = calibratedGain(s)
        val b = siginfo[s].baseline.toDouble()
        return DoubleArray(nsamples) {
            val v = samples[it * nsig + s]
            if (v == WFDB_INVALID_SAMPLE) Double.NaN else (v.toDouble() - b) / g
        }
    }

    private fun calibratedGain(s: Int): Double {
        val g = siginfo[s].gain
        if (g == 0.0 && legacy) return WFDB_DEFGAIN // WFDB-x: legacy mode (original behavior)
        if (g == 0.0) {
            throw WfdbException("signal ${signalNumbers.getOrElse(s) { s }} of record $name is uncalibrated")
        }
        return g
    }

    override fun equals(other: Any?): Boolean = other is Record && name == other.name && fs == other.fs &&
        nsig == other.nsig && signalNumbers.contentEquals(other.signalNumbers) &&
        samples.contentEquals(other.samples) && physicalEq(physical, other.physical) &&
        siginfo == other.siginfo && baseTime == other.baseTime && baseTimeMs == other.baseTimeMs &&
        baseDate == other.baseDate && sampfrom == other.sampfrom && comments == other.comments &&
        checksumOk == other.checksumOk && legacy == other.legacy

    override fun hashCode(): Int = (name.hashCode() * 31 + samples.contentHashCode()) * 31 + nsig

    override fun toString(): String = "Record(name=$name, fs=$fs, nsig=$nsig, nsamples=$nsamples, names=$names)"
}

private fun physicalEq(a: DoubleArray?, b: DoubleArray?): Boolean =
    if (a == null || b == null) a == null && b == null else a.contentEquals(b)

/** The header of a record, as returned by [readHeader]. */
data class Header(
    /** Record name, as given to readHeader. */
    val name: String,
    /** Sampling frequency in Hz, or 0 if the header gives none. */
    val fs: Double,
    /** Counter frequency, as getcfreq() returns it. */
    val counterFreq: Double,
    /** Base counter value, as getbasecount() returns it. */
    val baseCounter: Double,
    /** Number of samples per signal, or 0 if the header does not give it. */
    val nsamples: Long,
    /** Number of signals. */
    val nsig: Int,
    /**
     * Signal specifications, one per signal. A signal's `adcres` is 0 if the
     * header does not give it, and its `desc` has no white space at either
     * end.
     */
    val siginfo: List<Siginfo>,
    /** Start time and date as text, as in [Record.baseTime]. */
    val baseTime: String?,
    /** Start time in milliseconds after midnight, as in [Record.baseTimeMs]. */
    val baseTimeMs: Long?,
    /** Start date, as in [Record.baseDate]. */
    val baseDate: BaseDate?,
    /** The info strings of the header. */
    val comments: List<String>,
)

/**
 * The annotations of one file, as returned by [readAnnotations], in file
 * order. Each array or list has one entry per annotation. Arrays are
 * compared by content in [equals].
 */
data class Annotations(
    /** Record name. */
    val record: String,
    /** Annotator name, such as "atr". */
    val annotator: String,
    /** The frequency in which [samples] are counted, normally the sampling frequency of the record (0 if unknown). */
    val fs: Double,
    /** Annotation times, in samples. */
    val samples: LongArray,
    /** Annotation codes, such as [NORMAL] or [PVC]. */
    val codes: IntArray,
    /** Mnemonics of the codes, such as "N", "V" or "+". */
    val symbols: List<String>,
    /** Subtypes. */
    val subtypes: IntArray,
    /** Channel numbers. */
    val chans: IntArray,
    /** Annotator numbers (the `num` fields). */
    val nums: IntArray,
    /** Auxiliary text of each annotation, or null. */
    val aux: List<String?>,
) {
    /** The number of annotations. */
    val size: Int get() = samples.size

    override fun equals(other: Any?): Boolean = other is Annotations && record == other.record &&
        annotator == other.annotator && fs == other.fs && samples.contentEquals(other.samples) &&
        codes.contentEquals(other.codes) && symbols == other.symbols && subtypes.contentEquals(other.subtypes) &&
        chans.contentEquals(other.chans) && nums.contentEquals(other.nums) && aux == other.aux

    override fun hashCode(): Int = (record.hashCode() * 31 + annotator.hashCode()) * 31 + samples.contentHashCode()

    override fun toString(): String = "Annotations(record=$record, annotator=$annotator, n=$size)"
}

// ---------------------------------------------------------------------------
// Settings

/** A file name (record, annotator or directory) as bytes. */
internal fun fname(s: String): ByteArray = Platform.nameBytes(s)

private fun fnameStr(b: ByteArray?): String? = b?.let { Platform.nameString(it) }

/**
 * Sets the input directory: a local directory, a `~` path or a URL, from
 * which names that are not full paths are read (null: the default, the
 * current directory or `WFDBX_INPUT_DIR`). Returns the previous setting.
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun Wfdb.wfdbxSetInputDir(dir: String?): String? = fnameStr(wfdbx_set_input_dir(dir?.let { fname(it) }))

/**
 * The input directory (see [wfdbxSetInputDir]), or null for the default.
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun Wfdb.wfdbxGetInputDir(): String? = fnameStr(wfdbx_get_input_dir())

/**
 * Sets the output directory, in which files named without a full path are
 * created (null: the default, the current directory or
 * `WFDBX_OUTPUT_DIR`). Returns the previous setting.
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun Wfdb.wfdbxSetOutputDir(dir: String?): String? = fnameStr(wfdbx_set_output_dir(dir?.let { fname(it) }))

/**
 * The output directory (see [wfdbxSetOutputDir]), or null for the default.
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun Wfdb.wfdbxGetOutputDir(): String? = fnameStr(wfdbx_get_output_dir())

/**
 * Turns network access (reading URLs) on or off; returns the previous setting.
 * It is off unless `WFDBX_NETWORK=1`.
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun Wfdb.wfdbxSetNetwork(on: Boolean): Boolean = wfdbx_set_network(if (on) 1 else 0) != 0

/**
 * Whether network access is on.
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun Wfdb.wfdbxGetNetwork(): Boolean = wfdbx_get_network() != 0

/**
 * Turns legacy mode (the behavior of the original WFDB package, including
 * its assumed signal parameters and its search of the WFDB path) on or
 * off; returns the previous setting.
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun Wfdb.wfdbxSetLegacy(on: Boolean): Boolean = wfdbx_set_legacy(if (on) 1 else 0) != 0

/**
 * Whether legacy mode is on.
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun Wfdb.wfdbxGetLegacy(): Boolean = wfdbx_get_legacy() != 0

// ---------------------------------------------------------------------------
// Helpers

/** Runs [f] in legacy mode if [on] (restoring the previous setting afterwards, also on errors). */
private inline fun <T> Wfdb.withLegacy(on: Boolean, f: () -> T): T {
    if (!on) return f()
    val previous = wfdbx_set_legacy(1)
    try {
        return f()
    } finally {
        wfdbx_set_legacy(previous)
    }
}

/**
 * Runs [f], restoring the getvec mode ([setgvmode]) afterwards (also on
 * errors): readRecord sets it, and opening an EDF record changes it.
 */
private inline fun <T> Wfdb.withGvmode(f: () -> T): T {
    val previous = getgvmode()
    try {
        return f()
    } finally {
        setgvmode(previous)
    }
}

/** Runs [f] with the input directory and network access given (if not null), restoring the previous settings afterwards. */
internal inline fun <T> Wfdb.withInput(inputDir: String?, network: Boolean?, f: () -> T): T {
    val prevDir = if (inputDir != null) wfdbx_set_input_dir(fname(inputDir)) else null
    val prevNet = if (network != null) wfdbx_set_network(if (network) 1 else 0) else 0
    try {
        return f()
    } finally {
        if (network != null) wfdbx_set_network(prevNet)
        if (inputDir != null) wfdbx_set_input_dir(prevDir)
    }
}

/**
 * Runs [f] with the output directory [dir] (if not null or empty),
 * restoring the previous one afterwards. With [dir], [record] must not
 * contain a directory, and [dir] must exist.
 */
private inline fun <T> Wfdb.withOutputDir(dir: String?, record: String, f: () -> T): T {
    if (dir.isNullOrEmpty()) return f()
    if (record.contains('/')) throw WfdbException("record name must not contain a directory when dir is given")
    if (!Platform.isDirectory(fname(dir))) throw WfdbException("directory $dir does not exist")
    val previous = wfdbx_set_output_dir(fname(dir))
    try {
        return f()
    } finally {
        wfdbx_set_output_dir(previous)
    }
}

private fun Wfdb.fail(msg: String): Nothing {
    wfdbquit()
    throw WfdbException(msg)
}

private fun Wfdb.isLegacy(): Boolean = wfdbx_get_legacy() != 0

/** The sample number that [t] denotes for the open record (a time of day gives the elapsed time). */
private fun Wfdb.resolve(t: TimeSpec?): Long? = when (t) {
    null -> null
    is TimeSpec.Sample -> t.sample
    is TimeSpec.Text -> {
        val x = strtim(t.text.latin1())
        if (x < 0) -x else x
    }
}

private fun Wfdb.needsFreq(t: TimeSpec?): Boolean = t is TimeSpec.Text && wfdbx_time_needs_freq(t.text.latin1()) != 0

/**
 * Throws if the sampling frequency is not specified and [from] or [to]
 * needs it (WFDB-x: no default sampling frequency; C assumed 250 Hz).
 * Legacy mode: no check.
 */
private fun Wfdb.checkTimeFreq(record: String, from: TimeSpec?, to: TimeSpec?) {
    if (isLegacy() || sampfreq(null as ByteArray?) > 0.0) return
    if (needsFreq(from) || needsFreq(to)) fail("sampling frequency of record $record is not specified")
}

private class BaseFields(val text: String?, val ms: Long?, val date: BaseDate?)

/**
 * The base time text, base time in milliseconds and base date of the open
 * record (the text only if the record has a sampling frequency, or in
 * legacy mode: a header without a frequency cannot give a base time).
 */
private fun Wfdb.baseTimeFields(): BaseFields {
    val (ms, ymd) = wfdbxBaseTimeDate()
    val date = ymd?.let { BaseDate(it[0], it[1], it[2]) }
    if (sampfreq(null as ByteArray?) > 0.0 || isLegacy()) {
        val bt = timstr(0)
        if (bt.isNotEmpty() && bt[0] == '['.code.toByte()) return BaseFields(bt.latin1(), ms, date)
    }
    return BaseFields(null, null, date)
}

/** The info strings of the open record. */
private fun Wfdb.infoStrings(record: ByteArray): List<String> {
    val v = ArrayList<String>()
    var c = getinfo(record)
    while (c != null) {
        v.add(c.latin1())
        c = getinfo(null as ByteArray?)
    }
    return v
}

private fun strOrNull(b: ByteArray?): String? = b?.let { cstr(it).latin1() }

/** White space (C isspace). */
private const val SPACE = " \t\n\u000b\u000c\r"

/**
 * WFDB-x: the high-level readers give the signal descriptions without the
 * white space that some headers end them with (C keeps it, as the C-style
 * functions do).
 */
private fun stripDesc(si: Array<Siginfo>) {
    for (s in si) {
        val d = s.desc ?: continue
        s.desc = strOrNull(d)!!.trim { it in SPACE }.latin1()
    }
}

/** The value of a per-signal argument for signal [k]: its only value, its k-th one, or null. */
private fun <T> perSignal(v: List<T>?, k: Int): T? = when {
    v == null || v.isEmpty() -> null
    v.size == 1 -> v[0]
    k < v.size -> v[k]
    else -> null
}

private fun perSignal(v: IntArray?, k: Int): Int? = perSignal(v?.asList(), k)

private fun perSignal(v: DoubleArray?, k: Int): Double? = perSignal(v?.asList(), k)

/** The ADC resolution (bits) of the samples of a storage format, as the original package inferred it (legacy mode). */
private fun legacyAdcres(fmt: Int): Int = when (fmt) {
    80, 508 -> 8
    212 -> 12
    310, 311 -> 10
    24, 524 -> 24
    32 -> 32
    else -> 16
}

// ---------------------------------------------------------------------------
// Reading

/**
 * Reads the header of a record, without opening its signal files.
 *
 * Part of WFDB-x; not in the original WFDB package.
 *
 * @param record record name: a name in the input directory, or a full
 *   path, `~` path or URL
 * @param inputDir input directory for this call only (null: the current
 *   setting, see [wfdbxSetInputDir])
 * @param network network access for this call only (null: the current
 *   setting, see [wfdbxSetNetwork])
 * @param legacy read the header as the original WFDB package does
 * @return the [Header]
 * @throws WfdbException if the header cannot be found or read: "can't read
 *   header for record REC"
 *
 * ```
 * // 100s: the first minute of record 100 of the MIT-BIH Arrhythmia Database,
 * // included with WFDB-x in tests/data of a copy of the repository
 * val h = readHeader("100s", inputDir = "tests/data")
 * println("${h.nsig} signals at ${h.fs} Hz, ${h.nsamples} samples")
 * ```
 */
fun Wfdb.readHeader(record: String, inputDir: String? = null, network: Boolean? = null, legacy: Boolean = false): Header =
    withGvmode {
        withLegacy(legacy) {
            withInput(inputDir, network) {
                val rec = fname(record)
                wfdbquit()
                val n = isigopen(rec, null, 0)
                if (n < 0) fail("can't read header for record $record")
                val si = Array(n) { Siginfo() }
                if (n > 0) isigopen(rec, si, -n)
                stripDesc(si)
                val fs = sampfreq(null as ByteArray?)
                val b = baseTimeFields()
                val h = Header(
                    name = record, fs = fs, counterFreq = getcfreq(), baseCounter = getbasecount(),
                    nsamples = wfdbxHeaderNsamples(), nsig = n, siginfo = si.toList(), baseTime = b.text,
                    baseTimeMs = b.ms, baseDate = b.date, comments = infoStrings(rec),
                )
                wfdbquit()
                h
            }
        }
    }

/** Vectors read at a time by readRecord at most. */
private const val CHUNK_FRAMES = 1L shl 20

/**
 * Reads the signals of a record, or part of it.
 *
 * Part of WFDB-x; not in the original WFDB package.
 *
 * @param record record name: a name in the input directory, or a full
 *   path, `~` path or URL
 * @param channels the signals to read, by number (`"0"`) or name
 *   (`"MLII"`, as in [Record.names]), in the order wanted (null: all
 *   signals)
 * @param from the first sample: a sample number (not negative) or a time
 *   string (null: the start of the record)
 * @param to the sample after the last one (null: the end of the record)
 * @param physical also return the samples in physical units
 *   ([Record.physical]); every signal read must then have a gain
 * @param highres read every sample of a multi-frequency record, at its
 *   highest sampling frequency (by default, the samples of the faster
 *   signals are averaged to one per frame)
 * @param pad replace each invalid sample by the previous valid sample of
 *   the same signal
 * @param checksumWarning warn when the data do not match the header's
 *   checksums (the data are returned either way, and [Record.checksumOk]
 *   is false)
 * @param onWarning receives the warning (without the "WFDB-x: " prefix and
 *   the newline); null: the library prints "WFDB-x: " + the warning on
 *   the standard error, unless [wfdbquiet] was called
 * @param inputDir input directory for this call only (null: the current
 *   setting)
 * @param network network access for this call only (null: the current
 *   setting)
 * @param legacy behave as the original WFDB package
 * @return the [Record]
 * @throws WfdbException if the header or a signal file cannot be read
 *   ("can't read record REC"), if a channel is not in the record ("record
 *   REC has no signal C"), if `from` is a negative sample number
 *   ("readRecord: from must not be negative"), if a time string needs the
 *   sampling frequency
 *   and the header gives none ("sampling frequency of record REC is not
 *   specified"), if `physical` is true and a signal has no gain ("signal N
 *   of record REC is uncalibrated"), if `from` is beyond the end ("can't
 *   seek to sample N of record REC"), or if a signal file is shorter than
 *   its header says ("can't read signal data of record REC (getvec status
 *   -3)")
 *
 * The warning on a checksum error is "checksum error in record REC: the
 * signal data do not match the checksums in its header".
 *
 * ```
 * // 100s: the first minute of record 100 of the MIT-BIH Arrhythmia Database,
 * // included with WFDB-x in tests/data of a copy of the repository
 * val rec = readRecord("100s", inputDir = "tests/data", channels = listOf("MLII"),
 *                      from = TimeSpec("0:10"), to = TimeSpec("0:20"), physical = true)
 * rec.nsamples           // 3600: 10 s of lead MLII
 * rec.physical!![0]      // its first sample, in mV
 * ```
 */
fun Wfdb.readRecord(
    record: String,
    channels: List<String>? = null,
    from: TimeSpec? = null,
    to: TimeSpec? = null,
    physical: Boolean = false,
    highres: Boolean = false,
    pad: Boolean = false,
    checksumWarning: Boolean = true,
    onWarning: ((String) -> Unit)? = null,
    inputDir: String? = null,
    network: Boolean? = null,
    legacy: Boolean = false,
): Record = withGvmode {
    withLegacy(legacy) {
        withInput(inputDir, network) {
            readRecordImpl(record, channels, from, to, physical, highres, pad, checksumWarning, onWarning)
        }
    }
}

private fun Wfdb.readRecordImpl(
    record: String, channels: List<String>?, from: TimeSpec?, to: TimeSpec?, physical: Boolean,
    highres: Boolean, pad: Boolean, checksumWarning: Boolean, onWarning: ((String) -> Unit)?,
): Record {
    val rec = fname(record)
    val legacy = isLegacy()
    wfdbquit()
    var nsig = isigopen(rec, null, 0)
    if (nsig <= 0) fail("can't read record $record")
    val si = Array(nsig) { Siginfo() }
    nsig = isigopen(rec, si, nsig)
    if (nsig <= 0) fail("can't open signals of record $record")
    setgvmode((if (highres) WFDB_HIGHRES else WFDB_LOWRES) or (if (pad) WFDB_GVPAD else 0))
    val fs = sampfreq(null as ByteArray?)
    checkTimeFreq(record, from, to)
    val t0 = resolve(from) ?: 0L
    // WFDB-x: isigsettime would take a negative time as an absolute one
    if (t0 < 0) fail("readRecord: from must not be negative")
    val t1 = resolve(to)
    stripDesc(si)
    val cols: IntArray = if (channels == null) {
        IntArray(nsig) { it }
    } else {
        val names = si.map { strOrNull(it.desc) ?: "" }
        IntArray(channels.size) {
            val c = channels[it]
            // (a name as in Record.names, then as findsig finds it)
            val j = names.indexOf(c.trim { ch -> ch in SPACE })
            val k = if (j >= 0) j else findsig(c.latin1())
            if (k < 0 || k >= nsig) fail("record $record has no signal $c")
            k
        }
    }
    if (physical && !legacy) {
        // WFDB-x: no default gain (C, legacy mode: 200 adu/mV)
        for (k in cols) if (si[k].gain == 0.0) fail("signal $k of record $record is uncalibrated")
    }
    val b = baseTimeFields()
    if (isigsettime(t0) < 0) fail("can't seek to sample $t0 of record $record")

    // getvec returns one value per signal in either mode. The vectors are
    // read straight into one array, allocated for the number expected
    // (from `to`, or from the length the header gives; at most 2^26
    // values at first, in case the header or `to` promises more than the
    // files hold), and grown if there are more.
    val length = wfdbxHeaderNsamples() * (if (highres && sig.spfmax > 1) sig.spfmax.toLong() else 1L)
    // (t0 >= 0: no overflow)
    var remaining: Long? = if (t1 == null) null else if (t1 <= t0) 0L else t1 - t0
    val expected = remaining ?: maxOf(length - t0, 0L)
    var all = IntArray((minOf(expected, (1L shl 26) / nsig) * nsig).toInt().coerceAtLeast(nsig))
    // Vectors read per getvecs call at most: whole frames, and a multiple of
    // 6 of them, so that formats 212, 310 and 311 end each call on a whole
    // packed unit (the frames are then read in blocks).
    val unit = 6L * (if (highres) maxOf(sig.ispfmax, 1) else 1)
    val chunk = CHUNK_FRAMES - CHUNK_FRAMES % unit
    var used = 0 // values read
    var checksumError = false
    val quiet = wfdbxSetCksumQuiet(true) // (getvec's own message is replaced by the warning below)
    try {
        while (remaining == null || remaining > 0) {
            val have = (used / nsig).toLong()
            val n = when {
                remaining != null -> minOf(remaining, chunk)
                expected > have -> minOf(expected - have, chunk)
                else -> 65536L - 65536L % unit
            }
            val need = used.toLong() + n * nsig
            if (need > Int.MAX_VALUE - 8) fail("record $record is too long to be read at once")
            // (if they do not fit, the vectors are read into a separate
            // array first, so that `all` grows only if there are more)
            val probe = if (need > all.size) IntArray((n * nsig).toInt()) else null
            val r = if (probe == null) getvecsStatusAt(all, used, n) else getvecsStatusAt(probe, 0, n)
            val stat = r.status
            var got = maxOf(r.count, 0L)
            if (remaining != null) remaining -= got
            if (stat == -4) {
                // WFDB-x: a checksum error: the vector read last holds valid
                // data and is kept; reading continues (in high-resolution
                // mode, each vector of the last frame returns -4), and a
                // warning follows.
                got++
                checksumError = true
                if (remaining != null) remaining -= 1
            }
            if (probe != null && got > 0) {
                all = all.copyOf(maxOf(need, minOf(2L * all.size, Int.MAX_VALUE - 8L)).toInt())
                probe.copyInto(all, used, 0, (got * nsig).toInt())
            }
            used += (got * nsig).toInt()
            if (stat == -4) continue
            if (got < n) {
                // WFDB-x: a status below -1 (e.g. -3, unexpected EOF: a
                // signal file shorter than its header says, or a decoder or
                // I/O error) is an error, not the end of the data (-1).
                if (stat < -1) fail("can't read signal data of record $record (getvec status $stat)")
                break
            }
        }
    } finally {
        wfdbxSetCksumQuiet(quiet)
    }
    if (checksumError && checksumWarning) {
        val msg = "checksum error in record $record: the signal data do not match the checksums in its header"
        if (onWarning != null) onWarning(msg) else wfdb_error("WFDB-x: $msg\n")
    }
    val nframes = used / nsig
    val nout = cols.size
    val samples: IntArray = if (cols.contentEquals(IntArray(nsig) { it })) {
        if (used == all.size) all else all.copyOf(used)
    } else {
        val out = IntArray(nframes * nout)
        var p = 0
        for (i in 0 until nframes) {
            val base = i * nsig
            for (c in cols) out[p++] = all[base + c]
        }
        out
    }
    val sel = cols.map { si[it].copy() }
    var phys: DoubleArray? = null
    if (physical) {
        // (legacy mode: the default gain for uncalibrated signals)
        val g = DoubleArray(nout) { if (sel[it].gain != 0.0 || !legacy) sel[it].gain else WFDB_DEFGAIN }
        val bl = DoubleArray(nout) { sel[it].baseline.toDouble() }
        phys = toPhysical(samples, nout, bl, g)
    }
    val comments = infoStrings(rec)
    val result = Record(
        name = record, fs = fs, nsig = nout, signalNumbers = cols, samples = samples, physical = phys,
        siginfo = sel, names = sel.map { strOrNull(it.desc) ?: "" }, units = sel.map { strOrNull(it.units) },
        gains = sel.map { it.gain }, baselines = sel.map { it.baseline }, baseTime = b.text,
        baseTimeMs = b.ms, baseDate = b.date, sampfrom = t0, comments = comments,
        checksumOk = !checksumError, legacy = legacy,
    )
    wfdbquit()
    return result
}

/**
 * (v - baseline) / gain for each value v of [samples] (frames of [nout]
 * values; the baselines and gains of the signals in [bl] and [g]), NaN
 * for an invalid sample.
 */
private fun toPhysical(samples: IntArray, nout: Int, bl: DoubleArray, g: DoubleArray): DoubleArray {
    val phys = DoubleArray(samples.size)
    if (nout == 0) return phys
    // (in pieces of 512 frames, with the baseline and the gain of each value
    // of a piece in bt and gt: a loop that the JIT compiles to vector
    // instructions; then the invalid samples)
    val tl = nout * 512
    val bt = DoubleArray(tl) { bl[it % nout] }
    val gt = DoubleArray(tl) { g[it % nout] }
    var i = 0
    while (i < samples.size) {
        val e = minOf(tl, samples.size - i)
        for (j in 0 until e) phys[i + j] = (samples[i + j].toDouble() - bt[j]) / gt[j]
        i += e
    }
    for (k in samples.indices) if (samples[k] == WFDB_INVALID_SAMPLE) phys[k] = Double.NaN
    return phys
}

/**
 * Reads an annotation file.
 *
 * Part of WFDB-x; not in the original WFDB package.
 *
 * @param record record name. Its header, if there is one, gives the
 *   sampling frequency.
 * @param annotator annotator name: the suffix of the file ("atr" reads
 *   RECORD.atr)
 * @param from the first time to read: a sample number or a time string
 *   (null: the start)
 * @param to the time at which to stop; annotations at or after it are not
 *   read (null: the end of the file)
 * @param fs sampling frequency (> 0) to use when the record has no header,
 *   or its header gives none; ignored otherwise
 * @param inputDir input directory for this call only
 * @param network network access for this call only
 * @param legacy behave as the original WFDB package
 * @return the [Annotations], in file order. Its `fs` is 0 if neither the
 *   record nor [fs] gives a sampling frequency.
 * @throws WfdbException if [fs] is not > 0 ("readAnnotations: fs must be >
 *   0"), if the file cannot be opened ("can't read annotator ANN for record
 *   REC"), if a time string needs the sampling frequency and none is known,
 *   or if the file ends before its end-of-file marker ("can't read
 *   annotation file ANN of record REC (getann status -3)")
 *
 * ```
 * // 100s: the first minute of record 100 of the MIT-BIH Arrhythmia Database,
 * // included with WFDB-x in tests/data of a copy of the repository
 * val ann = readAnnotations("100s", "atr", to = TimeSpec("0:30"), inputDir = "tests/data")
 * val beats = (0 until ann.size).filter { isqrs(ann.codes[it]) != 0 }.map { ann.samples[it] }
 * ```
 */
fun Wfdb.readAnnotations(
    record: String,
    annotator: String,
    from: TimeSpec? = null,
    to: TimeSpec? = null,
    fs: Double? = null,
    inputDir: String? = null,
    network: Boolean? = null,
    legacy: Boolean = false,
): Annotations {
    // (`!(f > 0)` also rejects NaN)
    if (fs != null && !(fs > 0.0)) throw WfdbException("readAnnotations: fs must be > 0")
    return withLegacy(legacy) { withInput(inputDir, network) { readAnnotationsImpl(record, annotator, from, to, fs) } }
}

private fun Wfdb.readAnnotationsImpl(record: String, annotator: String, from: TimeSpec?, to: TimeSpec?, fs: Double?): Annotations {
    val rec = fname(record)
    val an = fname(annotator)
    wfdbquit()
    // WFDB-x: no default sampling frequency (C assumed 250 Hz if the record
    // had no header, as legacy mode does); fs gives one, as rdann -F does.
    val sps = sampfreq(rec)
    if (sps <= 0.0 && fs != null) {
        setsampfreq(fs)
    } else if (sps < 0.0 && isLegacy()) {
        setsampfreq(WFDB_DEFFREQ) // legacy mode (original behavior)
    }
    checkTimeFreq(record, from, to)
    if (annopen(rec, arrayOf(Anninfo(an, WFDB_READ)), 1) < 0) fail("can't read annotator $annotator for record $record")
    val t0 = resolve(from) ?: 0L
    val t1 = resolve(to)
    if (t0 != 0L && iannsettime(t0) < 0) fail("can't seek in annotator $annotator")
    val r = getannAll(0, t1)
    val stat = r.status
    // WFDB-x: a status other than 0 and -1 (e.g. -3, unexpected EOF: the
    // file is truncated) is an error, not the end of the file.
    if (stat != 0 && stat != -1) fail("can't read annotation file $annotator of record $record (getann status $stat)")
    val res = Annotations(
        record = record, annotator = annotator, fs = getiafreq(0), samples = r.times, codes = r.codes,
        symbols = r.symbols, subtypes = r.subtypes, chans = r.chans, nums = r.nums, aux = r.aux,
    )
    wfdbquit()
    return res
}

// ---------------------------------------------------------------------------
// Writing

/**
 * Writes samples in ADC units as a new record: a header (RECORD.hea) and
 * one signal file (RECORD.dat) holding all signals. Existing files with
 * these names are overwritten.
 *
 * You must give the sampling frequency, the gain and ADC resolution of
 * each signal, and the units of each calibrated signal: there are no
 * defaults. Each per-signal argument ([gains], [baselines], [adczeros],
 * [adcres], [units], [names], [sampsPerFrame]) takes one value for all
 * signals, or one value per signal.
 *
 * Part of WFDB-x; not in the original WFDB package.
 *
 * @param record record name (a name in the output directory, or a full or
 *   `~` path; see the record name rules in the README)
 * @param samples the samples, frame by frame: signal 0, signal 1, ... of
 *   frame 0, then those of frame 1, and so on. A signal with `spf` samples
 *   per frame has `spf` consecutive values in each frame.
 * @param nsig the number of signals
 * @param fs sampling frequency in Hz (frames per second, > 0)
 * @param fmt storage format, such as 16, 212, 24 or 516 (FLAC)
 * @param gains gain in ADC units per physical unit; 0 marks a signal as
 *   uncalibrated
 * @param baselines ADC value that corresponds to 0 physical units
 *   (default: the ADC zero)
 * @param adczeros ADC value at the middle of the ADC range (default 0)
 * @param adcres ADC resolution in bits (>= 1)
 * @param units physical units, such as "mV"; required for each signal
 *   with a gain other than 0 (null for an uncalibrated signal)
 * @param names signal descriptions (default: none)
 * @param baseTime start time, with an optional date: "hh:mm:ss
 *   dd/mm/yyyy" (default: none)
 * @param comments info strings, written at the end of the header
 * @param sampsPerFrame samples per frame of each signal, at least 1, for
 *   a multi-frequency record (default 1)
 * @param dir an existing directory in which to create the files, for this
 *   call only; [record] must then be a plain name (the record opens from
 *   that directory under its plain name)
 * @param legacy behave as the original WFDB package (default gain 200, an
 *   ADC resolution based on the format, no units required)
 * @throws WfdbException "writeRecord: sampsPerFrame must hold integers >=
 *   1" (checked first, also in legacy mode), "writeRecord: gains must be specified",
 *   "writeRecord: ADC resolution(s) must be specified", "writeRecord: units
 *   must be specified", "writeRecord: the sampling frequency must be > 0",
 *   "writeRecord: no signals", "writeRecord: the number of samples is not a
 *   multiple of the frame size", "record name must not contain a directory
 *   when dir is given", "directory DIR does not exist", "can't create
 *   signal file for record REC" (also when the output would overwrite a
 *   file being read), "can't create header for record REC", "write error
 *   on record REC" (the signal file or the header cannot be written
 *   completely, for example when the disk is full; also in legacy mode)
 *
 * ```
 * writeRecord("copy", rec.samples, rec.nsig, rec.fs, gains = rec.gains.toDoubleArray(),
 *             adcres = intArrayOf(11), units = listOf("mV"), names = rec.names)
 * ```
 */
fun Wfdb.writeRecord(
    record: String,
    samples: IntArray,
    nsig: Int,
    fs: Double,
    fmt: Int = 16,
    gains: DoubleArray? = null,
    baselines: IntArray? = null,
    adczeros: IntArray? = null,
    adcres: IntArray? = null,
    units: List<String?>? = null,
    names: List<String>? = null,
    baseTime: String? = null,
    comments: List<String>? = null,
    sampsPerFrame: IntArray? = null,
    dir: String? = null,
    legacy: Boolean = false,
) {
    checkWriteSpf(sampsPerFrame)
    val spec = WriteSpec(fmt, gains, baselines, adczeros, adcres, units, names, baseTime, comments, sampsPerFrame)
    withOutputDir(dir, record) { withLegacy(legacy) { writeAdc(record, samples, nsig, fs, spec) } }
}

/**
 * Writes samples in physical units as a new record, as [writeRecord] does
 * from ADC units. Each value is converted to ADC units as `round(x * gain)
 * + baseline`, with halves rounded away from zero; NaN becomes an invalid
 * sample, and an infinite value, or one whose ADC value is beyond the range
 * of 32-bit integers, is an error (before anything is written). Every
 * signal must have a gain other than 0.
 *
 * Part of WFDB-x; not in the original WFDB package.
 *
 * @throws WfdbException as [writeRecord], "writeRecord: signal N is
 *   uncalibrated" if a gain is 0, and "writeRecord: sample I is infinite or
 *   beyond the range of 32-bit ADC units"
 *
 * ```
 * val x = DoubleArray(3600) { sin(it / 50.0) }
 * writeRecord("sine", x, nsig = 1, fs = 360.0, gains = doubleArrayOf(1000.0),
 *             adcres = intArrayOf(16), units = listOf("mV"), names = listOf("A"))
 * ```
 */
fun Wfdb.writeRecord(
    record: String,
    samples: DoubleArray,
    nsig: Int,
    fs: Double,
    fmt: Int = 16,
    gains: DoubleArray? = null,
    baselines: IntArray? = null,
    adczeros: IntArray? = null,
    adcres: IntArray? = null,
    units: List<String?>? = null,
    names: List<String>? = null,
    baseTime: String? = null,
    comments: List<String>? = null,
    sampsPerFrame: IntArray? = null,
    dir: String? = null,
    legacy: Boolean = false,
) {
    checkWriteSpf(sampsPerFrame)
    val spec = WriteSpec(fmt, gains, baselines, adczeros, adcres, units, names, baseTime, comments, sampsPerFrame)
    withOutputDir(dir, record) {
        withLegacy(legacy) {
            val leg = isLegacy()
            if (nsig <= 0) throw WfdbException("writeRecord: no signals")
            checkPerSignal(spec, nsig, leg)
            checkWriteFreq(fs, leg)
            // gain and baseline of each column of a frame
            val g = ArrayList<Double>()
            val b = ArrayList<Int>()
            for (k in 0 until nsig) {
                var gain = gainOf(spec.gains, k, leg)
                if (gain == 0.0 && leg) {
                    gain = WFDB_DEFGAIN // WFDB-x: legacy mode (original behavior)
                } else if (gain == 0.0) {
                    throw WfdbException("writeRecord: signal $k is uncalibrated") // WFDB-x: no default gain
                }
                val zero = perSignal(spec.adczeros, k) ?: 0
                val base = perSignal(spec.baselines, k) ?: zero
                val spf = perSignal(spec.sampsPerFrame, k) ?: 1
                repeat(spf) {
                    g.add(gain)
                    b.add(base)
                }
            }
            val nc = g.size
            val adc = IntArray(samples.size) {
                val c = it % nc
                val v = samples[it] * g[c]
                if (v.isNaN()) {
                    WFDB_INVALID_SAMPLE
                } else {
                    val r = (if (v >= 0.0) kotlin.math.truncate(v + 0.5) else kotlin.math.truncate(v - 0.5)) + b[c].toDouble()
                    // WFDB-x: an infinite value, or one beyond the range of
                    // 32-bit ADC units, cannot be written (C's conversion is
                    // undefined)
                    if (!(r >= Int.MIN_VALUE.toDouble() && r <= Int.MAX_VALUE.toDouble())) {
                        throw WfdbException("writeRecord: sample $it is infinite or beyond the range of 32-bit ADC units")
                    }
                    d2i(r)
                }
            }
            writeAdc(record, adc, nsig, fs, spec)
        }
    }
}

private class WriteSpec(
    val fmt: Int, val gains: DoubleArray?, val baselines: IntArray?, val adczeros: IntArray?,
    val adcres: IntArray?, val units: List<String?>?, val names: List<String>?, val baseTime: String?,
    val comments: List<String>?, val sampsPerFrame: IntArray?,
)

/** The gain of signal [k] (WFDB-x: no default gain; C assumed WFDB_DEFGAIN, as legacy mode does). */
private fun gainOf(gains: DoubleArray?, k: Int, legacy: Boolean): Double {
    val g = perSignal(gains, k)
    if (legacy) return g ?: WFDB_DEFGAIN
    return g ?: throw WfdbException("writeRecord: gains must be specified")
}

/** The ADC resolution of signal [k] (WFDB-x: no default; C inferred it from the format, as legacy mode does). */
private fun adcresOf(adcres: IntArray?, k: Int, fmt: Int, legacy: Boolean): Int {
    val r = perSignal(adcres, k)
    if (legacy) return r ?: legacyAdcres(fmt)
    if (r == null || r < 1) throw WfdbException("writeRecord: ADC resolution(s) must be specified")
    return r
}

/**
 * Checks that each per-signal argument holds no value, one value for all
 * signals, or one value per signal (WFDB-x: before anything is written).
 * A required argument ([WriteSpec.gains], [WriteSpec.adcres],
 * [WriteSpec.units]) with fewer values is reported as missing values
 * instead, except in legacy mode.
 */
private fun checkPerSignal(spec: WriteSpec, nsig: Int, legacy: Boolean) {
    val lens = listOf(
        Triple("gains", spec.gains?.size, true),
        Triple("baselines", spec.baselines?.size, false),
        Triple("adczeros", spec.adczeros?.size, false),
        Triple("adcres", spec.adcres?.size, true),
        Triple("units", spec.units?.size, true),
        Triple("names", spec.names?.size, false),
        Triple("sampsPerFrame", spec.sampsPerFrame?.size, false),
    )
    for ((name, n, required) in lens) {
        if (n != null && n > 1 && n != nsig && !(required && !legacy && n < nsig)) {
            throw WfdbException("writeRecord: $name must have one value per signal")
        }
    }
}

/** Checks the samples per frame (in both modes, before anything else): each signal has at least one sample per frame. */
private fun checkWriteSpf(spf: IntArray?) {
    if (spf != null && spf.any { it < 1 }) throw WfdbException("writeRecord: sampsPerFrame must hold integers >= 1")
}

/** Checks the sampling frequency (WFDB-x: no default; not checked in legacy mode, as in the original package). */
private fun checkWriteFreq(fs: Double, legacy: Boolean) {
    if (!(fs > 0.0) && !legacy) throw WfdbException("writeRecord: the sampling frequency must be > 0")
}

private fun Wfdb.writeAdc(record: String, samples: IntArray, nsig: Int, fs: Double, spec: WriteSpec) {
    if (nsig <= 0) throw WfdbException("writeRecord: no signals")
    val legacy = isLegacy()
    checkPerSignal(spec, nsig, legacy)
    checkWriteFreq(fs, legacy)
    val rec = fname(record)
    val datName = fname("$record.dat")
    var frame = 0
    val si = Array(nsig) { k ->
        val s = Siginfo()
        s.fname = datName
        s.desc = (perSignal(spec.names, k) ?: "").latin1()
        s.gain = gainOf(spec.gains, k, legacy)
        val u = perSignal(spec.units, k)
        // WFDB-x: there are no default units (C left them out: millivolts)
        if (!legacy && s.gain != 0.0 && u.isNullOrEmpty()) throw WfdbException("writeRecord: units must be specified")
        s.units = if (u.isNullOrEmpty()) null else u.latin1()
        s.fmt = spec.fmt
        s.spf = perSignal(spec.sampsPerFrame, k) ?: 1
        s.adczero = perSignal(spec.adczeros, k) ?: 0
        s.baseline = perSignal(spec.baselines, k) ?: s.adczero
        s.adcres = adcresOf(spec.adcres, k, spec.fmt, legacy)
        frame += s.spf
        s
    }
    if (samples.size % frame != 0) {
        throw WfdbException("writeRecord: the number of samples is not a multiple of the frame size")
    }
    wfdbquit()
    val errors = wfdbx_write_errors()
    try {
        if (osigfopen(si, nsig) != nsig) fail("can't create signal file for record $record")
        setsampfreq(fs)
        // The counter frequency and base count survive wfdbquit() (as in the
        // C library); a new record written here has neither.
        setcfreq(0.0)
        setbasecount(0.0)
        if (spec.baseTime != null) setbasetime(spec.baseTime.latin1())
        putframes(samples, samples.size / frame)
        if (newheader(rec) < 0) fail("can't create header for record $record")
        for (c in spec.comments ?: emptyList()) putinfo(c.latin1())
    } finally {
        // (the output signals are closed whatever happens)
        wfdbquit()
    }
    if (wfdbx_write_errors() > errors) throw WfdbException("write error on record $record")
}

/**
 * Writes an annotation file.
 *
 * Give the annotation types as [codes] or as [symbols] ([codes] is used if
 * both are given). If the annotations are not in time order, the file is
 * sorted when it is written; [sort] decides this for one call. Without
 * [sort], the WFDBANNSORT environment variable decides: sorting is on
 * unless it is 0.
 *
 * Part of WFDB-x; not in the original WFDB package.
 *
 * @param record record name
 * @param annotator annotator name: the suffix of the file (an existing file
 *   is overwritten)
 * @param samples annotation times, in samples
 * @param symbols mnemonics such as "N" or "V" (an unknown mnemonic becomes
 *   code 0, NOTQRS)
 * @param codes annotation codes, used instead of [symbols]
 * @param subtypes subtype of each annotation (null: 0; as in C, stored in
 *   one byte: other values wrap around to -128 to 127)
 * @param chans channel number of each annotation (null: 0; stored in one
 *   byte: other values wrap around to 0 to 255)
 * @param nums annotator number of each annotation (null: 0; stored in one
 *   byte: other values wrap around to -128 to 127)
 * @param aux auxiliary text of each annotation, or null where there is none
 *   (texts longer than 255 bytes are cut)
 * @param fs if given, written to the file as the frequency in which the
 *   times are counted
 * @param sort true to always sort, false to keep the order given (without
 *   the library's advice to run sortann), null to follow WFDBANNSORT
 * @param dir an existing directory in which to create the file, for this
 *   call only; [record] must then be a plain name
 * @param legacy behave as the original WFDB package
 * @throws WfdbException if neither symbols nor codes is given ("symbols or
 *   codes must be given"), if an array does not have one value per
 *   annotation, if the file cannot be created ("can't create annotator ANN
 *   for record REC"), if it cannot be written completely, for example when
 *   the disk is full ("write error on annotator ANN for record REC"; also in
 *   legacy mode), or as for [writeRecord]'s dir
 *
 * ```
 * writeAnnotations("rand", "qrs", longArrayOf(100, 460, 820), symbols = listOf("N", "N", "V"))
 * ```
 */
fun Wfdb.writeAnnotations(
    record: String,
    annotator: String,
    samples: LongArray,
    symbols: List<String>? = null,
    codes: IntArray? = null,
    subtypes: IntArray? = null,
    chans: IntArray? = null,
    nums: IntArray? = null,
    aux: List<String?>? = null,
    fs: Double? = null,
    sort: Boolean? = null,
    dir: String? = null,
    legacy: Boolean = false,
) {
    val n = samples.size
    fun check(name: String, size: Int?) {
        if (size != null && size != n) throw WfdbException("writeAnnotations: $name must have one value per annotation")
    }
    check("symbols", symbols?.size)
    check("codes", codes?.size)
    check("subtypes", subtypes?.size)
    check("chans", chans?.size)
    check("nums", nums?.size)
    check("aux", aux?.size)
    withOutputDir(dir, record) {
        withLegacy(legacy) {
            val types = codes ?: IntArray(n).also { t ->
                if (symbols == null) throw WfdbException("symbols or codes must be given")
                val cache = HashMap<String, Int>()
                for (k in 0 until n) t[k] = cache.getOrPut(symbols[k]) { strann(symbols[k].latin1()) }
            }
            val zeros = IntArray(n)
            val auxes = arrayOfNulls<ByteArray>(n)
            if (aux != null) for (k in 0 until n) auxes[k] = auxField(aux[k])
            val rec = fname(record)
            wfdbquit()
            val errors = wfdbx_write_errors()
            if (fs != null) setafreq(fs)
            try {
                if (annopen(rec, arrayOf(Anninfo(fname(annotator), WFDB_WRITE)), 1) < 0) {
                    fail("can't create annotator $annotator for record $record")
                }
                // (as putann for each annotation, but encoded at once)
                try {
                    putanns(0, n, samples, types, subtypes ?: zeros, chans ?: zeros, nums ?: zeros, auxes)
                } catch (e: Throwable) {
                    wfdbquit() // (the annotator is closed whatever happens)
                    throw e
                }
                val previous = ann.sortOverride
                ann.sortOverride = sort
                try {
                    wfdbquit()
                } finally {
                    ann.sortOverride = previous
                }
            } finally {
                if (fs != null) setafreq(0.0)
            }
            if (wfdbx_write_errors() > errors) throw WfdbException("write error on annotator $annotator for record $record")
        }
    }
}

/** The aux field (length byte first) of an aux string: its first 255 characters (null for null or ""). */
private fun auxField(x: String?): ByteArray? {
    if (x == null || x.isEmpty()) return null
    val m = minOf(x.length, 255) // (one length byte)
    val v = ByteArray(m + 1)
    v[0] = m.toByte()
    for (i in 0 until m) v[i + 1] = x[i].code.toByte()
    return v
}

/**
 * Writes the annotations [a] (its samples, codes, subtypes, chans, nums
 * and aux; its record, annotator and fs are not used) as [writeAnnotations]
 * does.
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun Wfdb.writeAnnotations(
    record: String,
    annotator: String,
    a: Annotations,
    fs: Double? = null,
    sort: Boolean? = null,
    dir: String? = null,
    legacy: Boolean = false,
) = writeAnnotations(
    record, annotator, a.samples, codes = a.codes, subtypes = a.subtypes, chans = a.chans, nums = a.nums,
    aux = a.aux, fs = fs, sort = sort, dir = dir, legacy = legacy,
)

// ---------------------------------------------------------------------------
// Top-level functions (default instance)

/** [Wfdb.wfdbxSetInputDir] on the default instance. */
fun wfdbxSetInputDir(dir: String?): String? = wfdbDefault().wfdbxSetInputDir(dir)

/** [Wfdb.wfdbxGetInputDir] on the default instance. */
fun wfdbxGetInputDir(): String? = wfdbDefault().wfdbxGetInputDir()

/** [Wfdb.wfdbxSetOutputDir] on the default instance. */
fun wfdbxSetOutputDir(dir: String?): String? = wfdbDefault().wfdbxSetOutputDir(dir)

/** [Wfdb.wfdbxGetOutputDir] on the default instance. */
fun wfdbxGetOutputDir(): String? = wfdbDefault().wfdbxGetOutputDir()

/** [Wfdb.wfdbxSetNetwork] on the default instance. */
fun wfdbxSetNetwork(on: Boolean): Boolean = wfdbDefault().wfdbxSetNetwork(on)

/** [Wfdb.wfdbxGetNetwork] on the default instance. */
fun wfdbxGetNetwork(): Boolean = wfdbDefault().wfdbxGetNetwork()

/** [Wfdb.wfdbxSetLegacy] on the default instance. */
fun wfdbxSetLegacy(on: Boolean): Boolean = wfdbDefault().wfdbxSetLegacy(on)

/** [Wfdb.wfdbxGetLegacy] on the default instance. */
fun wfdbxGetLegacy(): Boolean = wfdbDefault().wfdbxGetLegacy()

/** [Wfdb.readHeader] on the default instance of the thread. */
fun readHeader(record: String, inputDir: String? = null, network: Boolean? = null, legacy: Boolean = false): Header =
    wfdbDefault().readHeader(record, inputDir, network, legacy)

/** [Wfdb.readRecord] on the default instance of the thread. */
fun readRecord(
    record: String,
    channels: List<String>? = null,
    from: TimeSpec? = null,
    to: TimeSpec? = null,
    physical: Boolean = false,
    highres: Boolean = false,
    pad: Boolean = false,
    checksumWarning: Boolean = true,
    onWarning: ((String) -> Unit)? = null,
    inputDir: String? = null,
    network: Boolean? = null,
    legacy: Boolean = false,
): Record = wfdbDefault().readRecord(
    record, channels, from, to, physical, highres, pad, checksumWarning, onWarning, inputDir, network, legacy,
)

/** [Wfdb.readAnnotations] on the default instance of the thread. */
fun readAnnotations(
    record: String,
    annotator: String,
    from: TimeSpec? = null,
    to: TimeSpec? = null,
    fs: Double? = null,
    inputDir: String? = null,
    network: Boolean? = null,
    legacy: Boolean = false,
): Annotations = wfdbDefault().readAnnotations(record, annotator, from, to, fs, inputDir, network, legacy)

/** [Wfdb.writeRecord] (samples in ADC units) on the default instance of the thread. */
fun writeRecord(
    record: String,
    samples: IntArray,
    nsig: Int,
    fs: Double,
    fmt: Int = 16,
    gains: DoubleArray? = null,
    baselines: IntArray? = null,
    adczeros: IntArray? = null,
    adcres: IntArray? = null,
    units: List<String?>? = null,
    names: List<String>? = null,
    baseTime: String? = null,
    comments: List<String>? = null,
    sampsPerFrame: IntArray? = null,
    dir: String? = null,
    legacy: Boolean = false,
) = wfdbDefault().writeRecord(
    record, samples, nsig, fs, fmt, gains, baselines, adczeros, adcres, units, names, baseTime, comments,
    sampsPerFrame, dir, legacy,
)

/** [Wfdb.writeRecord] (samples in physical units) on the default instance of the thread. */
fun writeRecord(
    record: String,
    samples: DoubleArray,
    nsig: Int,
    fs: Double,
    fmt: Int = 16,
    gains: DoubleArray? = null,
    baselines: IntArray? = null,
    adczeros: IntArray? = null,
    adcres: IntArray? = null,
    units: List<String?>? = null,
    names: List<String>? = null,
    baseTime: String? = null,
    comments: List<String>? = null,
    sampsPerFrame: IntArray? = null,
    dir: String? = null,
    legacy: Boolean = false,
) = wfdbDefault().writeRecord(
    record, samples, nsig, fs, fmt, gains, baselines, adczeros, adcres, units, names, baseTime, comments,
    sampsPerFrame, dir, legacy,
)

/** [Wfdb.writeAnnotations] on the default instance of the thread. */
fun writeAnnotations(
    record: String,
    annotator: String,
    samples: LongArray,
    symbols: List<String>? = null,
    codes: IntArray? = null,
    subtypes: IntArray? = null,
    chans: IntArray? = null,
    nums: IntArray? = null,
    aux: List<String?>? = null,
    fs: Double? = null,
    sort: Boolean? = null,
    dir: String? = null,
    legacy: Boolean = false,
) = wfdbDefault().writeAnnotations(record, annotator, samples, symbols, codes, subtypes, chans, nums, aux, fs, sort, dir, legacy)

/** [Wfdb.writeAnnotations] (from an [Annotations]) on the default instance of the thread. */
fun writeAnnotations(
    record: String,
    annotator: String,
    a: Annotations,
    fs: Double? = null,
    sort: Boolean? = null,
    dir: String? = null,
    legacy: Boolean = false,
) = wfdbDefault().writeAnnotations(record, annotator, a, fs, sort, dir, legacy)
