// Types, constants and structures of the WFDB library API (<wfdb/wfdb.h>).
//
// The structures have the C field names; a new structure has C's zero
// values. Strings are byte strings (ByteArray); a field that C may set to
// NULL is nullable. Fields of C char types hold Int values normalized to
// the range of the C type (as a C assignment would convert them).
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of lib/wfdb.h from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original code, but it is new code, not the original C code.
//
// Changes from the original: WFDB_DEFFREQ, WFDB_DEFGAIN and WFDB_DEFRES remain
// defined but are used only in legacy mode, and missing units are never taken
// to be millivolts. Each change is marked "WFDB-x:" in the code;
// docs/DIVERGENCES.md gives the reasons.
//
// Original C code: lib/wfdb.h, WFDB Software Package 10.7.0.
//   Copyright (C) 1983-2013 George B. Moody; revised 2010-2020 by
//   Benjamin Moody.
// Kotlin translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx

import wfdbx.cstd.latin1

/** Version of the WFDB Software Package implemented (major). */
const val WFDB_MAJOR: Int = 10

/** Version (minor). */
const val WFDB_MINOR: Int = 7

/** Version (release). */
const val WFDB_RELEASE: Int = 0

/** Smallest sample value (WFDB_Sample is Int). */
const val WFDB_SAMPLE_MIN: Int = Int.MIN_VALUE

/** Largest sample value. */
const val WFDB_SAMPLE_MAX: Int = Int.MAX_VALUE

/** Smallest time (WFDB_Time is Long). */
const val WFDB_TIME_MIN: Long = Long.MIN_VALUE

/** Largest time. */
const val WFDB_TIME_MAX: Long = Long.MAX_VALUE

/** Value returned by getvec and getframe for invalid samples (unless padding is enabled; see [WFDB_GVPAD]). */
const val WFDB_INVALID_SAMPLE: Int = -32768

/** Historical limit: annotators. */
const val WFDB_MAXANN: Int = 2

/** Historical limit: signals. */
const val WFDB_MAXSIG: Int = 32

/** Historical limit: samples per signal per frame. */
const val WFDB_MAXSPF: Int = 4

/** Maximum length of a record name. */
const val WFDB_MAXRNL: Int = 50

/** Maximum length of a units string. */
const val WFDB_MAXUSL: Int = 50

/** Maximum length of a signal description. */
const val WFDB_MAXDSL: Int = 100

/** Standard input annotation file. */
const val WFDB_READ: Int = 0

/** Standard output annotation file. */
const val WFDB_WRITE: Int = 1

/** AHA-format input annotation file. */
const val WFDB_AHA_READ: Int = 2

/** AHA-format output annotation file. */
const val WFDB_AHA_WRITE: Int = 3

/** For output info files (open in append mode). */
const val WFDB_APPEND: Int = 4

/** Signal storage formats. */
val WFDB_FMT_LIST: IntArray = intArrayOf(0, 8, 16, 61, 80, 160, 212, 310, 311, 24, 32, 508, 516, 524)

/** Number of signal storage formats. */
const val WFDB_NFMTS: Int = 14

/** Default sampling frequency (Hz) of the C library; WFDB-x: used only in legacy mode. */
const val WFDB_DEFFREQ: Double = 250.0

/** Default gain (adu/physical unit) of the C library; WFDB-x: used only in legacy mode. */
const val WFDB_DEFGAIN: Double = 200.0

/** Default ADC resolution (bits) of the C library; WFDB-x: used only in legacy mode. */
const val WFDB_DEFRES: Int = 12

/** getvec mode: one sample per signal per frame. */
const val WFDB_LOWRES: Int = 0

/** getvec mode: each sample of oversampled signals. */
const val WFDB_HIGHRES: Int = 1

/** getvec mode flag: replace invalid samples. */
const val WFDB_GVPAD: Int = 2

/** Calibration pulse type: AC coupled. */
const val WFDB_AC_COUPLED: Int = 0

/** DC coupled. */
const val WFDB_DC_COUPLED: Int = 1

/** Square wave. */
const val WFDB_CAL_SQUARE: Int = 2

/** Sine wave. */
const val WFDB_CAL_SINE: Int = 4

/** Sawtooth wave. */
const val WFDB_CAL_SAWTOOTH: Int = 6

/** Undefined pulse shape. */
const val WFDB_CAL_UNDEF: Int = 8

/**
 * Default WFDB path (legacy mode), used when the WFDB environment variable
 * is not set (that of a release build of the C library 10.7.0 installed in
 * /usr/local; its URL component is not used, since legacy mode reads no
 * remote files).
 */
const val DEFWFDB: String = ". /usr/local/database http://physionet.org/physiobank/database"

/** Default calibration file name. */
const val DEFWFDBCAL: String = "wfdbcal"

/** Default value of WFDBANNSORT (sort out-of-order annotations). */
const val DEFWFDBANNSORT: Int = 1

/** Default getvec mode (WFDBGVMODE). */
const val DEFWFDBGVMODE: Int = WFDB_LOWRES

/** Path component type: a local directory. */
const val WFDB_LOCAL: Int = 0

/** Path component type: a URL. */
const val WFDB_NET: Int = 1

private fun bytesEq(a: ByteArray?, b: ByteArray?) = if (a == null || b == null) a === b else a.contentEquals(b)
private fun bytesHash(a: ByteArray?) = a?.contentHashCode() ?: 0
private fun bytesStr(a: ByteArray?) = a?.latin1() ?: "null"

/** Signal information (C `WFDB_Siginfo`). */
class Siginfo(
    /** Name of the signal file. */
    var fname: ByteArray? = null,
    /** Signal description. */
    var desc: ByteArray? = null,
    /** Physical units (null: not specified; WFDB-x: never assumed to be mV). */
    var units: ByteArray? = null,
    /** Gain (adu/physical unit; 0: uncalibrated). */
    var gain: Double = 0.0,
    /** Initial value (that of sample number 0). */
    var initval: Int = 0,
    /** Signal group number. */
    var group: Int = 0,
    /** Storage format (8, 16, etc.). */
    var fmt: Int = 0,
    /** Samples per frame (>1: oversampled). */
    var spf: Int = 0,
    /** Block size (for character special files). */
    var bsize: Int = 0,
    /** ADC resolution in bits (0: not specified). */
    var adcres: Int = 0,
    /** ADC output given 0 VDC input. */
    var adczero: Int = 0,
    /** ADC output given 0 physical units input. */
    var baseline: Int = 0,
    /** Number of samples (0: unspecified). */
    var nsamp: Long = 0,
    /** 16-bit checksum of all samples. */
    var cksum: Int = 0,
) {
    /** A copy (C structure assignment). */
    fun copy(): Siginfo = Siginfo(fname, desc, units, gain, initval, group, fmt, spf, bsize, adcres, adczero, baseline, nsamp, cksum)

    /** Copies all fields of [o] into this structure. */
    fun set(o: Siginfo) {
        fname = o.fname; desc = o.desc; units = o.units; gain = o.gain; initval = o.initval
        group = o.group; fmt = o.fmt; spf = o.spf; bsize = o.bsize; adcres = o.adcres
        adczero = o.adczero; baseline = o.baseline; nsamp = o.nsamp; cksum = o.cksum
    }

    override fun equals(other: Any?): Boolean = other is Siginfo && bytesEq(fname, other.fname) &&
        bytesEq(desc, other.desc) && bytesEq(units, other.units) && gain == other.gain &&
        initval == other.initval && group == other.group && fmt == other.fmt && spf == other.spf &&
        bsize == other.bsize && adcres == other.adcres && adczero == other.adczero &&
        baseline == other.baseline && nsamp == other.nsamp && cksum == other.cksum

    override fun hashCode(): Int = bytesHash(fname) * 31 + nsamp.hashCode()

    override fun toString(): String = "Siginfo(fname=${bytesStr(fname)}, desc=${bytesStr(desc)}, units=${bytesStr(units)}, " +
        "gain=$gain, initval=$initval, group=$group, fmt=$fmt, spf=$spf, bsize=$bsize, adcres=$adcres, " +
        "adczero=$adczero, baseline=$baseline, nsamp=$nsamp, cksum=$cksum)"
}

/** Calibration information (C `WFDB_Calinfo`). */
class Calinfo(
    /** Low level of calibration pulse. */
    var low: Double = 0.0,
    /** High level of calibration pulse. */
    var high: Double = 0.0,
    /** Customary plotting scale (units per cm). */
    var scale: Double = 0.0,
    /** Signal type. */
    var sigtype: ByteArray? = null,
    /** Physical units. */
    var units: ByteArray? = null,
    /** Calibration pulse type. */
    var caltype: Int = 0,
) {
    /** A copy. */
    fun copy(): Calinfo = Calinfo(low, high, scale, sigtype, units, caltype)

    /** Copies all fields of [o] into this structure. */
    fun set(o: Calinfo) {
        low = o.low; high = o.high; scale = o.scale; sigtype = o.sigtype; units = o.units; caltype = o.caltype
    }

    override fun equals(other: Any?): Boolean = other is Calinfo && low == other.low && high == other.high &&
        scale == other.scale && bytesEq(sigtype, other.sigtype) && bytesEq(units, other.units) && caltype == other.caltype

    override fun hashCode(): Int = bytesHash(sigtype) * 31 + caltype

    override fun toString(): String = "Calinfo(low=$low, high=$high, scale=$scale, sigtype=${bytesStr(sigtype)}, " +
        "units=${bytesStr(units)}, caltype=$caltype)"
}

/** Annotator information (C `WFDB_Anninfo`). */
class Anninfo(
    /** Annotator name. */
    var name: ByteArray = ByteArray(0),
    /** [WFDB_READ], [WFDB_WRITE], ... */
    var stat: Int = 0,
) {
    /** Annotator information with a name given as a string. */
    constructor(name: String, stat: Int) : this(name.latin1(), stat)

    /** A copy. */
    fun copy(): Anninfo = Anninfo(name, stat)

    override fun equals(other: Any?): Boolean = other is Anninfo && name.contentEquals(other.name) && stat == other.stat
    override fun hashCode(): Int = name.contentHashCode() * 31 + stat
    override fun toString(): String = "Anninfo(name=${name.latin1()}, stat=$stat)"
}

/**
 * An annotation (C `WFDB_Annotation`).
 *
 * As in C, [aux] is either absent (NULL) or holds the auxiliary information
 * preceded by a byte that gives its length (`aux[0]` is the length, the
 * data follow).
 */
class Annotation(
    /** Time, in sample intervals from the start of the record. */
    var time: Long = 0,
    anntyp: Int = 0,
    subtyp: Int = 0,
    chan: Int = 0,
    num: Int = 0,
    /** Auxiliary information (length byte first), or null. */
    var aux: ByteArray? = null,
) {
    /** Annotation type (see the codes in Ecgcodes.kt); C `char` (signed: -128..127). */
    var anntyp: Int = anntyp.toByte().toInt()
        set(v) {
            field = v.toByte().toInt()
        }

    /** Annotation subtype (C `signed char`). */
    var subtyp: Int = subtyp.toByte().toInt()
        set(v) {
            field = v.toByte().toInt()
        }

    /** Channel number (C `unsigned char`: 0..255). */
    var chan: Int = chan and 0xff
        set(v) {
            field = v and 0xff
        }

    /** Annotator number (C `signed char`). */
    var num: Int = num.toByte().toInt()
        set(v) {
            field = v.toByte().toInt()
        }

    /** A copy (C structure assignment: the aux pointer is shared). */
    fun copy(): Annotation = Annotation(time, anntyp, subtyp, chan, num, aux)

    /** Copies all fields of [o] into this structure. */
    fun set(o: Annotation) {
        time = o.time; anntyp = o.anntyp; subtyp = o.subtyp; chan = o.chan; num = o.num; aux = o.aux
    }

    override fun equals(other: Any?): Boolean = other is Annotation && time == other.time &&
        anntyp == other.anntyp && subtyp == other.subtyp && chan == other.chan && num == other.num &&
        bytesEq(aux, other.aux)

    override fun hashCode(): Int = (time.hashCode() * 31 + anntyp) * 31 + chan

    override fun toString(): String = "Annotation(time=$time, anntyp=$anntyp, subtyp=$subtyp, chan=$chan, num=$num, aux=${bytesStr(aux)})"
}

/** A segment of a multi-segment record (C `WFDB_Seginfo`). */
class Seginfo(
    /** Segment (record) name (at most [WFDB_MAXRNL] bytes). */
    var recname: ByteArray = ByteArray(0),
    /** Number of samples in the segment. */
    var nsamp: Long = 0,
    /** Sample number of the first sample of the segment. */
    var samp0: Long = 0,
) {
    /** A copy. */
    fun copy(): Seginfo = Seginfo(recname, nsamp, samp0)

    override fun equals(other: Any?): Boolean = other is Seginfo && recname.contentEquals(other.recname) &&
        nsamp == other.nsamp && samp0 == other.samp0

    override fun hashCode(): Int = recname.contentHashCode() * 31 + nsamp.hashCode()
    override fun toString(): String = "Seginfo(recname=${recname.latin1()}, nsamp=$nsamp, samp0=$samp0)"
}
