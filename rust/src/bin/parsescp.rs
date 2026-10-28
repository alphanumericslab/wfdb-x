//! parsescp: parse an SCP-ECG file (read from the standard input) (port of
//! `convert/parsescp.c`, by way of `cpp/apps/parsescp.cpp`).
//!
//! `parsescp` converts SCP-ECG files produced by SpaceLabs/Burdick ECG
//! carts into more easily usable formats:
//!
//! * `RECORD.des` (text): description (age, sex, recording bandwidth,
//!   measurements, diagnoses)
//! * `RECORD.ecg` (binary): reconstructed ECGs
//! * `RECORD.key` (text): patient's name and ID (medical record number)
//! * `RECORD.txt` (text): reconstructed ECGs (with `-v`)
//! * `RECORD.dat`, `RECORD.hea`: WFDB-format record (with `-w`)
//!
//! With `-a`, an anonymized copy of the input is written to the standard
//! output instead.
//!
//! The input is held in one byte buffer and the C program's pointers into
//! it are represented by offsets. Behaviors of the C program that are
//! undefined (on defective inputs) are resolved as in the other WFDB-x
//! implementations (see `docs/KNOWN_C_BEHAVIORS.md`): bytes beyond the end
//! of the input are read as 0; signal arrays have at least 5000 samples and
//! samples beyond the end of a lead are 0; missing subtraction zones are
//! ignored and samples outside the arrays are skipped; strings copied into
//! fixed-size buffers are truncated; a missing date or time of acquisition
//! is left empty, and an invalid month is printed as `???`. Samples are
//! written in little-endian byte order, as the C program does on x86.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Rust translation of convert/parsescp.c from the WFDB Software
// Package 10.7.0, by George B. Moody and Edna S. Moody. The translation
// follows the logic and behavior of the original program, but it is new code,
// not the original C code.
//
// Changes from the original: the record is written with the sampling frequency
// given in the SCP file, and is not written if the file gives none (the
// original always wrote 500 Hz); signals and reference beats that could not be
// allocated, and samples beyond the end of a signal shorter than lead 0, are
// read as absent or as zeros (undefined behavior in the original); an output
// file that cannot be written is reported, and the exit status is then 1;
// --legacy, as the first argument, restores the original behavior. Each change
// is marked "WFDB-x:" in the code; docs/DIVERGENCES.md gives the reasons.
//
// Original C program: convert/parsescp.c, WFDB Software Package 10.7.0.
//   Copyright (C) 2000-2014 George B. Moody and Edna S. Moody; revised
//   2016-2020 by Benjamin Moody.
// Rust translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

use wfdbx::cstd;
use wfdbx::{ceprintf, cformat, cfprintf, cprintf, Siginfo, WfdbFile};

const VERSION_STRING: &[u8] = b"#ECG/1.0";

const WFDB_INVALID_SAMPLE: i16 = -32768;

/// The C program allocates every array with malloc/calloc; requests larger
/// than this many elements are treated as allocation failures.
const MAXALLOC: u64 = 1 << 28;
/// Signal arrays have at least this many elements (the .ecg file always
/// contains 5000 samples of lead II); samples beyond a lead's length are 0.
const MINSIGLEN: u64 = 5000;

// The SCP-ECG record layout. The record begins with a CRC and its length;
// each section begins with a header: a CRC, the section ID, the section
// length, version numbers and 6 reserved bytes. The CRCs cover what follows
// them (to the end of the record, or of the section).
const CRCLEN: i64 = 2;
const RECHDRLEN: usize = 6;
const SECHDRLEN: i64 = 16;
/// Offsets in a section header: ID, length, section and protocol versions.
const SEC_ID: i64 = 2;
const SEC_LEN: i64 = 4;
const SEC_VERSION: i64 = 8;
const SEC_PROTOCOL: i64 = 9;
/// A section must hold at least its CRC, ID and length.
const SECMINLEN: u64 = 8;
/// Offset of the "SCPECG" identifier in the reserved bytes of the header of
/// section 0, and the size of the pointers to sections that follow.
const SCPECG_POS: i64 = 10;
const SECPTRLEN: i64 = 10;
/// Section 1 holds tagged fields (a tag byte, a 16-bit length, the data),
/// ending with the tag `TAG_END`.
const TAGHDRLEN: i64 = 3;
const TAG_END: u32 = 255;
/// The value of an undefined axis (section 7).
const AXIS_UNDEF: i16 = 999;
/// The number of Huffman tables (section 2) meaning "the default table".
const HT_DEFAULT_ONLY: u32 = 19999;
/// Ages are censored to at most this when anonymizing (-a), as in HIPAA
/// de-identification.
const MAXAGE: i32 = 90;

type Sig = Vec<i16>;

/// C conversion of double to short (via a 32-bit int, as gcc does).
fn d2s(x: f64) -> i16 {
    cstd::d2i(x) as i16
}

/// C division of an int by 2 (truncation toward zero).
fn cdiv2(a: i32) -> i32 {
    a / 2
}

/// `calloc(n, sizeof(short))` for a signal; `None` if allocation fails.
fn newsig(n: u64) -> Option<Sig> {
    if n > MAXALLOC {
        return None;
    }
    Some(vec![0; n.max(MINSIGLEN) as usize])
}

/// Reference beat subtraction zone.
#[derive(Clone, Copy)]
struct Subzone {
    /// beat type (0: dominant)
    ztype: i16,
    /// first sample in zone
    t0: i64,
    /// fiducial
    t1: i64,
    /// last sample in zone
    t2: i64,
}

// Fields of the sets of measurements in section 10 (struct ECGmeas in C;
// each is a short).
const M_LEADID: usize = 0;
const M_VLEN: usize = 1;
const NMEAS: usize = 33;
type EcgMeas = [i16; NMEAS];

const MONTH: [&[u8]; 12] = [
    b"January",
    b"February",
    b"March",
    b"April",
    b"May",
    b"June",
    b"July",
    b"August",
    b"September",
    b"October",
    b"November",
    b"December",
];

/// Standard lead names.
#[rustfmt::skip]
const LEADNAME: [&[u8]; 86] = [
    //  0 -  4
    b"<Unspecified lead>", b"I", b"II", b"V1", b"V2",
    //  5 -  9
    b"V3", b"V4", b"V5", b"V6", b"V7",
    // 10 - 14
    b"V2R", b"V3R", b"V4R", b"V5R", b"V6R",
    // 15 - 19
    b"V7R", b"X", b"Y", b"Z", b"CC5",
    // 20 - 24
    b"CM5", b"Left Arm", b"Right Arm", b"Left Leg", b"I (Frank)",
    // 25 - 29
    b"E", b"C", b"A", b"M", b"F",
    // 30 - 34
    b"H", b"I-cal", b"II-cal", b"V1-cal", b"V2-cal",
    // 35 - 39
    b"V3-cal", b"V4-cal", b"V5-cal", b"V6-cal", b"V7-cal",
    // 40 - 44
    b"V2R-cal", b"V3R-cal", b"V4R-cal", b"V5R-cal", b"V6R-cal",
    // 45 - 49
    b"V7R-cal", b"X-cal", b"Y-cal", b"Z-cal", b"CC5-cal",
    // 50 - 54
    b"CM5-cal", b"Left Arm-cal", b"Right Arm-cal", b"Left Leg-cal", b"I-cal (Frank)",
    // 55 - 59
    b"E-cal", b"C-cal", b"A-cal", b"M-cal", b"F-cal",
    // 60 - 64
    b"H-cal", b"III", b"aVR", b"aVL", b"aVF",
    // 65 - 69
    b"-aVR", b"V8", b"V9", b"V8R", b"V9R",
    // 70 - 74
    b"D (Nehb - Dorsal)", b"A (Nehb - Anterior)", b"J (Nehb - Inferior",
    b"Defibrillator lead: anterior-lateral", b"External pacing lead: anterior-posterior",
    // 75 - 79
    b"A1 (Auxiliary unipolar lead 1)", b"A2 (Auxiliary unipolar lead 2)",
    b"A3 (Auxiliary unipolar lead 3)", b"A4 (Auxiliary unipolar lead 4)", b"V8-cal",
    // 80 - 84
    b"V9-cal", b"V8R-cal", b"V9R-cal", b"D-cal (Nehb - Dorsal)", b"A-cal (Nehb - Anterior)",
    // 85
    b"J-cal (Nehb - Inferior)",
];
const NLEADNAMES: i32 = LEADNAME.len() as i32;

/// The rows of the table of measurements: label, field index.
const MEASROWS: [(&[u8], usize); 29] = [
    (b"\nP duration    ms", 2),
    (b"\nPR interval   ms", 3),
    (b"\nQRS duration  ms", 4),
    (b"\nQT interval   ms", 5),
    (b"\nQ duration    ms", 6),
    (b"\nR duration    ms", 7),
    (b"\nS duration    ms", 8),
    (b"\nR' duration   ms", 9),
    (b"\nS' duration   ms", 10),
    (b"\nQ amplitude   uV", 11),
    (b"\nR amplitude   uV", 12),
    (b"\nS amplitude   uV", 13),
    (b"\nJ amplitude   uV", 16),
    (b"\nP+ amplitude  uV", 17),
    (b"\nP- amplitude  uV", 18),
    (b"\nT+ amplitude  uV", 19),
    (b"\nT- amplitude  uV", 20),
    (b"\nST slope    uV/s", 21),
    (b"\nP morphology  --", 22),
    (b"\nT morphology  --", 23),
    (b"\nIsoelec (I)   ms", 24),
    (b"\nIsoelec (K)   ms", 25),
    (b"\nIntrins defl  ms", 26),
    (b"\nQuality       --", 27),
    // FIXME: SCP spec doesn't specify units of st20, 60, 80, rr16, rr8 --
    // assume they are microvolts
    (b"\nST (J+20ms)   uV", 28),
    (b"\nST (J+60ms)   uV", 29),
    (b"\nST (J+80ms)   uV", 30),
    (b"\nST (J+RRm/16) uV", 31),
    (b"\nST (J+RRm/8)  uV", 32),
];

/// The default (SCP standard) Huffman table: pattern, suffix bits, base
/// value.
const HTDEFAULT: [(u16, u16, i16); 19] = [
    (0, 0, 0),
    (4, 0, 1),
    (5, 0, -1),
    (0xc, 0, 2),
    (0xd, 0, -2),
    (0x1c, 0, 3),
    (0x1d, 0, -3),
    (0x3c, 0, 4),
    (0x3d, 0, -4),
    (0x7c, 0, 5),
    (0x7d, 0, -5),
    (0xfc, 0, 6),
    (0xfd, 0, -6),
    (0x1fc, 0, 7),
    (0x1fd, 0, -7),
    (0x3fc, 0, 8),
    (0x3fd, 0, -8),
    (0x3fe, 8, 0),
    (0x3ff, 16, 0),
];

fn isprint_c(c: u32) -> bool {
    (32..127).contains(&c)
}

fn prval(out: &mut Vec<u8>, val: i16) {
    match val {
        29999 => out.extend_from_slice(b"  n/comp"), // not computed (ever) by analyzer
        29998 => out.extend_from_slice(b"     rej"), // lead rejected, not computed
        19999 => out.extend_from_slice(b"  absent"), // corresponding wave not present
        _ => {
            cstd::sprintf_into(out, b"%8d", &[cstd::ToArg::to_arg(&val)]);
        }
    }
}

/// Write `n` samples of signal `s`, beginning at sample `i0`, as
/// little-endian 16-bit integers.
fn write_samples(f: &mut WfdbFile, s: &[i16], i0: usize, n: usize) {
    let end = (i0 + n).min(s.len());
    if i0 >= end {
        return;
    }
    let mut buf = Vec::with_capacity(2 * (end - i0));
    for &v in &s[i0..end] {
        buf.extend_from_slice(&v.to_le_bytes());
    }
    f.write(&buf);
}

/// Weighted sums of the low-pass filter, evaluated in the order of the C
/// expressions.
fn wsum3(a: f64, wa: f64, bv: f64, wb: f64, c: f64, wc: f64) -> f64 {
    let x = a * wa;
    let y = bv * wb;
    let z = c * wc;
    let r = x + y;
    r + z
}

#[allow(clippy::too_many_arguments)]
fn wsum4(a: f64, wa: f64, bv: f64, wb: f64, c: f64, wc: f64, d: f64, wd: f64) -> f64 {
    let r = wsum3(a, wa, bv, wb, c, wc);
    let z = d * wd;
    r + z
}

/// The state of the program (the global and static variables of C).
struct Scp {
    bflag: i32,    // 0: normal operation, 1: show baselines only
    fflag: i32,    // 0: quit on CRC error, 1: continue if possible
    tflag: i32,    // 0: normal operation, 1: show templates only
    vflag: i32,    // 0: run quietly, 1: print (lots of) messages
    xflag: i32,    // 0: run quietly, 1: print hexdump
    shift: i32,    // 0: normal operation; otherwise, shift templates by this many samples
    data: Vec<u8>, // the input
    pname: Vec<u8>,
    nleads: i32,      // number of ECG leads
    nqrs: i32,        // number of beats detected
    nsamp: Vec<u64>,  // nsamp[i]: number of samples in lead i
    rblen: i64,       // number of samples in refbeat (template)
    rblenms: i64,     // length of refbeat in milliseconds
    fc_m: i32,        // index of fiducial within refbeat
    gref: f64,        // gain for refbeat
    gres: f64,        // gain for residuals
    sfreq: f64,       // sampling frequency (samples/second/lead)
    recdate: Vec<u8>, // date of recording
    rectime: Vec<u8>, // time of recording
    recname: Vec<u8>, // record name
    patient_name: Vec<u8>,
    referring_dr: Vec<u8>,
    comments: Vec<u8>,
    patient_id: Vec<u8>,
    age: i32,
    sex: i32, // 1: male, 2: female, 0: unknown, 9: unspecified
    rrint: i32,
    pon: i32,
    pend: i32,
    qrson: i32,
    qrsend: i32,
    tend: i32,
    paxis: i16,
    qrsaxis: i16,
    taxis: i16,
    blfilt: i32,      // baseline filter -3 dB point
    lpfilt: i32,      // low-pass filter -3 dB point
    filter_bit: i32,  // see SCP spec
    tdevid: i32,      // ID number of acquiring device
    tinst: i32,       // institution number
    tdept: i32,       // department number
    dept: i64,        // offset of location description (-1: none)
    inst: i64,        // offset of institution description
    stmnts: i32,      // number of statements in report
    report: Vec<i64>, // offsets of the report statements (-1: none)
    lflag: i32,
    wflag: i32,
    zflag: i32,
    aflag: i32,
    skip: [i32; 12],
    nout: u64, // number of samples written per signal
    subz: Vec<Option<Subzone>>,
    ecg: Vec<Option<Sig>>, // ecg[i]: reconstructed ECG for ith lead
    have_ecg: bool,
    refbeat: Vec<Option<Sig>>, // reference beat (template)
    lead_i: i16,
    lead_ii: i16,
    lead_iii: i16,
    avr: i16,
    avf: i16,
    avl: i16,
    v1: i16,
    v2: i16,
    v3: i16,
    v4: i16,
    v5: i16,
    v6: i16,
    ecgmeas: Vec<EcgMeas>,
    nsecleads: i32,
    // static variables of getbits(), Huffdecode() and write_output()
    w: u8,
    hdx: i16,
    hx: i16,
    hxx: i16,
    hxxx: i16,
    hxout: i16,
    zbuf: Vec<i16>,
}

impl Scp {
    fn new(pname: Vec<u8>) -> Scp {
        Scp {
            bflag: 0,
            fflag: 0,
            tflag: 0,
            vflag: 0,
            xflag: 0,
            shift: 0,
            data: Vec::new(),
            pname,
            nleads: -1,
            nqrs: -1,
            nsamp: Vec::new(),
            rblen: 0,
            rblenms: 0,
            fc_m: 0,
            gref: 0.0,
            gres: 0.0,
            sfreq: -1.0,
            recdate: Vec::new(),
            rectime: Vec::new(),
            recname: Vec::new(),
            patient_name: Vec::new(),
            referring_dr: Vec::new(),
            comments: Vec::new(),
            patient_id: Vec::new(),
            age: -1,
            sex: -1,
            rrint: -1,
            pon: -1,
            pend: -1,
            qrson: -1,
            qrsend: -1,
            tend: -1,
            paxis: AXIS_UNDEF,
            qrsaxis: AXIS_UNDEF,
            taxis: AXIS_UNDEF,
            blfilt: -1,
            lpfilt: -1,
            filter_bit: -1,
            tdevid: -1,
            tinst: -1,
            tdept: -1,
            dept: -1,
            inst: -1,
            stmnts: -1,
            report: vec![-1; 1200],
            lflag: 0,
            wflag: 0,
            zflag: 0,
            aflag: 0,
            skip: [0; 12],
            nout: 0,
            subz: Vec::new(),
            ecg: Vec::new(),
            have_ecg: false,
            refbeat: Vec::new(),
            lead_i: -1,
            lead_ii: -1,
            lead_iii: -1,
            avr: -1,
            avf: -1,
            avl: -1,
            v1: -1,
            v2: -1,
            v3: -1,
            v4: -1,
            v5: -1,
            v6: -1,
            ecgmeas: Vec::new(),
            nsecleads: 0,
            w: 0,
            hdx: 0,
            hx: 0,
            hxx: 0,
            hxxx: 0,
            hxout: 0,
            zbuf: vec![0; 5000],
        }
    }

    // ---- access to the input buffer ----

    fn b(&self, off: i64) -> u32 {
        if off >= 0 && (off as u64) < self.data.len() as u64 {
            self.data[off as usize] as u32
        } else {
            0
        }
    }

    fn get16(&self, off: i64) -> u32 {
        self.b(off) | (self.b(off.wrapping_add(1)) << 8)
    }

    fn put16(&mut self, val: u32, off: i64) {
        if off >= 0 && (off as u64) < self.data.len() as u64 {
            self.data[off as usize] = (val & 0xff) as u8;
        }
        let o1 = off.wrapping_add(1);
        if o1 >= 0 && (o1 as u64) < self.data.len() as u64 {
            self.data[o1 as usize] = ((val >> 8) & 0xff) as u8;
        }
    }

    fn get32(&self, off: i64) -> u64 {
        let mut r = self.b(off) as u64
            | (self.b(off.wrapping_add(1)) as u64) << 8
            | (self.b(off.wrapping_add(2)) as u64) << 16
            | (self.b(off.wrapping_add(3)) as u64) << 24;
        if r & 0x8000_0000 != 0 {
            // *p << 24 is a sign-extended int
            r |= 0xFFFF_FFFF_0000_0000;
        }
        r
    }

    /// The NUL-terminated string at `off` (ends at the end of the data).
    fn cstr(&self, off: i64) -> Vec<u8> {
        if off < 0 || off as u64 >= self.data.len() as u64 {
            return Vec::new();
        }
        cstd::cstr(&self.data[off as usize..]).to_vec()
    }

    fn getcrc(&self, mut off: i64, mut length: i64) -> u16 {
        let (mut crchigh, mut crclow): (u8, u8) = (0xff, 0xff);

        while length > 0 {
            length -= 1;
            let mut a = (self.b(off) as u8) ^ crchigh;
            off = off.wrapping_add(1);
            crchigh = a;
            a >>= 4; // top 4 bits of a are now zero
            a ^= crchigh;

            // swap crchigh, crclow
            crchigh = crclow;
            crclow = a;

            // rotate a left by four bits (swap nibbles)
            let mut bb = (a & 0xf) << 4;
            a >>= 4;
            a |= bb;
            bb = a;

            // rotate a left by one more bit
            a = a.rotate_left(1);

            a &= 0x1f;
            crchigh ^= a;
            a = bb & 0xf0;
            crchigh ^= a; // crchigh complete

            // rotate b left by one bit
            bb = bb.rotate_left(1);

            bb &= 0xe0;
            crclow ^= bb; // crclow complete
        }
        ((crchigh as u16) << 8) | crclow as u16
    }

    fn crcok(&self, off: i64, length: i64, crcref: u16, description: &[u8]) -> i32 {
        let crc = self.getcrc(off, length);

        if crc == crcref {
            if self.vflag != 0 {
                cprintf!(b"%s: correct (%d)\n", description, crc);
            }
            1
        } else {
            if self.vflag != 0 {
                cprintf!(
                    b"%s: error (calculated: %d, expected: %d)\n",
                    description,
                    crc,
                    crcref
                );
            }
            if self.fflag != 0 {
                0
            } else {
                cstd::exit(1); // quit on CRC error unless in -f (force) mode
            }
        }
    }

    /// Signal k, if it exists.
    fn sigp(&self, k: i64) -> Option<&Sig> {
        if k < 0 || k as u64 >= self.ecg.len() as u64 {
            return None;
        }
        self.ecg[k as usize].as_ref()
    }

    fn sigp_mut(&mut self, k: i64) -> Option<&mut Sig> {
        if k < 0 || k as u64 >= self.ecg.len() as u64 {
            return None;
        }
        self.ecg[k as usize].as_mut()
    }

    /// A copy of signal k, or (if it does not exist) an array of zero
    /// samples (for reading).
    fn srcsig(&self, k: i64) -> Sig {
        match self.sigp(k) {
            Some(s) => s.clone(),
            None => vec![0; self.nout.max(MINSIGLEN) as usize],
        }
    }

    fn nsampk(&self, k: i64) -> u64 {
        if k < 0 || k as u64 >= self.nsamp.len() as u64 {
            return 0;
        }
        self.nsamp[k as usize]
    }

    /// Signal k, or (if it does not exist) 5000 zero samples.
    fn sigr(&self, k: i64) -> std::borrow::Cow<'_, [i16]> {
        match self.sigp(k) {
            Some(s) => std::borrow::Cow::Borrowed(&s[..]),
            None => std::borrow::Cow::Owned(vec![0; MINSIGLEN as usize]),
        }
    }

    fn sample_at(&self, k: i64, i: u64) -> i16 {
        match self.sigp(k) {
            Some(s) if i < s.len() as u64 => s[i as usize],
            _ => 0,
        }
    }

    fn order(&self) -> [i64; 12] {
        [
            self.lead_i as i64,
            self.lead_ii as i64,
            self.lead_iii as i64,
            self.avr as i64,
            self.avf as i64,
            self.avl as i64,
            self.v1 as i64,
            self.v2 as i64,
            self.v3 as i64,
            self.v4 as i64,
            self.v5 as i64,
            self.v6 as i64,
        ]
    }

    // ---- output ----

    /// This low-pass filter is implemented as a 5-tap weighted moving
    /// average FIR filter. The -3 dB point is at roughly 1/10 the sampling
    /// frequency. It is applied only to the .ecg file, not to the
    /// text-format samples.
    fn lowpass(&mut self) {
        for i in 0..self.nleads.max(0) as i64 {
            let Some(inp) = self.sigp(i) else {
                continue;
            };
            let n = self.nsampk(i);
            let Some(mut out) = newsig(n) else {
                ceprintf!(b"Insufficient memory for filtering\n");
                break;
            };
            let inp: &Sig = inp;
            let (nin, nout) = (inp.len() as u64, out.len() as u64);
            // samples beyond the end of the input array read as 0, and
            // writes beyond the end of the output array are skipped
            let xs = |k: u64| if k < nin { inp[k as usize] as i32 } else { 0 };
            let x = |k: u64| xs(k) as f64;
            let mut put = |k: u64, v: i16| {
                if k < nout {
                    out[k as usize] = v;
                }
            };
            put(0, d2s(wsum3(x(0), 0.67, x(1), 0.22, x(2), 0.11)));
            put(
                1,
                d2s(wsum4(x(0), 0.33, x(1), 0.34, x(2), 0.22, x(3), 0.11)),
            );
            // C: for (j = 2; j < nsamp[i] - 2; j++), with an unsigned
            // (wrapping) bound; iterations past the end of the output array
            // would only make skipped writes, so the loop stops there (the
            // final writes below are then skipped too).
            let jend = n.wrapping_sub(2).min(nout);
            let mut j: u64 = 2;
            while j < jend {
                put(
                    j,
                    d2s(wsum3(
                        x(j),
                        0.34,
                        (xs(j - 1) + xs(j + 1)) as f64,
                        0.22,
                        (xs(j - 2) + xs(j + 2)) as f64,
                        0.11,
                    )),
                );
                j += 1;
            }
            put(
                j,
                d2s(wsum4(
                    x(j - 2),
                    0.11,
                    x(j - 1),
                    0.22,
                    x(j),
                    0.34,
                    x(j + 1),
                    0.33,
                )),
            );
            j += 1;
            put(j, d2s(wsum3(x(j - 2), 0.11, x(j - 1), 0.22, x(j), 0.67)));
            self.ecg[i as usize] = Some(out);
        }
    }

    fn precgmeas(&self) -> Vec<u8> {
        let mut out = b"Parameter  Units".to_vec();
        for m in &self.ecgmeas {
            let id = m[M_LEADID];
            if 0 < id && id <= 85 {
                cstd::sprintf_into(
                    &mut out,
                    b"%8s",
                    &[cstd::ToArg::to_arg(LEADNAME[id as usize])],
                );
            } else {
                cstd::sprintf_into(&mut out, b"  <%4d>", &[cstd::ToArg::to_arg(&id)]);
            }
        }
        for (label, field) in &MEASROWS {
            out.extend_from_slice(label);
            for m in &self.ecgmeas {
                prval(&mut out, m[*field]);
            }
        }
        out.push(b'\n');
        out
    }

    fn write_wfdb_record(&mut self) -> i32 {
        let mut filename = self.recname.clone();
        filename.extend_from_slice(b".dat");
        const WLEADNAME: [&[u8]; 12] = [
            b"I", b"II", b"III", b"aVR", b"aVF", b"aVL", b"V1", b"V2", b"V3", b"V4", b"V5", b"V6",
        ];
        let mut v = [0i32; 12];
        let order = self.order();

        // WFDB-x: the sampling frequency is the one given in the SCP file (the
        // C program always wrote 500 Hz, as legacy mode does); without one,
        // no record is written.
        let legacy = wfdbx::wfdbx_get_legacy() != 0;
        if !legacy {
            if self.sfreq <= 0.0 {
                ceprintf!(
                    b"%s: sampling frequency not specified; record %s not written\n",
                    self.pname,
                    self.recname
                );
                return 0;
            }
            wfdbx::setsampfreq(self.sfreq);
        }
        if wfdbx::newheader(&self.recname) < 0 {
            return 0;
        }
        if legacy {
            wfdbx::setsampfreq(500.0); // FIXME: we should calculate this!
        }

        let s: Vec<Siginfo> = WLEADNAME
            .iter()
            .map(|name| Siginfo {
                fname: Some(filename.clone()),
                desc: Some(name.to_vec()),
                units: Some(b"mV".to_vec()),
                fmt: 16,
                // WFDB-x: exact, not assumed: the samples have been rescaled
                // to units of 5000 nV (see gref and gres), i.e., 200 adu/mV
                gain: 200.0,
                adcres: 16, // FIXME: we should calculate this!
                ..Siginfo::default()
            })
            .collect();
        if wfdbx::osigfopen(&s, 12) < 12 {
            return 0;
        }
        let mut ptime = self.recdate.clone();
        ptime.push(b' ');
        ptime.extend_from_slice(&self.rectime);
        ptime.push(b'\n');
        wfdbx::setbasetime(&ptime);

        // write the ECG samples
        for i in 0..self.nout {
            for k in 0..12 {
                v[k] = self.sample_at(order[k], i) as i32;
            }
            if wfdbx::putvec(&v) < 0 {
                break;
            }
        }
        wfdbx::newheader(&self.recname);
        let info = cformat!(
            b"<age>: %d <sex>: %c",
            if self.age < MAXAGE { self.age } else { MAXAGE },
            match self.sex {
                1 => b'M',
                2 => b'F',
                _ => b'?',
            }
        );
        wfdbx::putinfo(&info);
        wfdbx::wfdbquit();
        1
    }

    fn write_output(&mut self) -> i32 {
        if self.recname.is_empty() {
            self.recname = b"ecg".to_vec(); // default record name
        }
        let recname = self.recname.clone();
        let name = |ext: &[u8]| {
            let mut n = recname.clone();
            n.extend_from_slice(ext);
            n
        };
        let (dname, ename, kname, tname) =
            (name(b".des"), name(b".ecg"), name(b".key"), name(b".txt"));
        let Some(mut dfile) = WfdbFile::fopen(&dname, b"wb") else {
            ceprintf!(b"%s: can't create '%s'\n", self.pname, dname);
            return 0;
        };
        let Some(mut efile) = WfdbFile::fopen(&ename, b"wb") else {
            dfile.close();
            ceprintf!(b"%s: can't create '%s'\n", self.pname, ename);
            return 0;
        };
        let Some(mut kfile) = WfdbFile::fopen(&kname, b"wb") else {
            dfile.close();
            efile.close();
            ceprintf!(b"%s: can't create '%s'\n", self.pname, kname);
            return 0;
        };
        let mut tfile = None;
        if self.vflag != 0 {
            match WfdbFile::fopen(&tname, b"wb") {
                Some(f) => tfile = Some(f),
                None => {
                    dfile.close();
                    efile.close();
                    kfile.close();
                    ceprintf!(b"%s: can't create '%s'\n", self.pname, tname);
                    return 0;
                }
            }
        }

        // Write the description file first.
        cfprintf!(dfile, b"%s description\n", VERSION_STRING);
        cfprintf!(
            dfile,
            b"Record: %s (%s %s)\n",
            recname,
            self.recdate,
            self.rectime
        );
        cfprintf!(dfile, b"Age: %d\n", self.age);
        cfprintf!(dfile, b"Sex: ");
        match self.sex {
            1 => cfprintf!(dfile, b"M\n"),
            2 => cfprintf!(dfile, b"F\n"),
            0 => cfprintf!(dfile, b"not known\n"),
            9 => cfprintf!(dfile, b"unspecified\n"),
            _ => cfprintf!(dfile, b"<error>\n"), // shouldn't happen
        };
        cfprintf!(dfile, b"Referring Dr: %s\n", self.referring_dr);
        cfprintf!(dfile, b"Comments: %s\n", self.comments);
        if self.tdevid == 0 {
            cfprintf!(dfile, b"Cart ID: <missing>\n");
        } else {
            cfprintf!(dfile, b"Cart ID: %d\n", self.tdevid);
        }
        let sdept = if self.dept < 0 {
            b"<missing>".to_vec()
        } else {
            self.cstr(self.dept)
        };
        cfprintf!(dfile, b"Department: %s\n", sdept);
        if self.tdept == 0 {
            cfprintf!(dfile, b"Department #: <missing>\n");
        } else {
            cfprintf!(dfile, b"Department #: %s\n", sdept);
        }
        let sinst = if self.inst < 0 {
            b"<missing>".to_vec()
        } else {
            self.cstr(self.inst)
        };
        cfprintf!(dfile, b"Institution: %s\n", sinst);
        if self.tinst == 0 {
            cfprintf!(dfile, b"Institution #: <missing>\n");
        } else {
            cfprintf!(dfile, b"Institution #: %d\n", self.tinst);
        }

        for i in 0..self.stmnts.max(0) as usize {
            let r = self.report[i];
            let s = if r < 0 {
                b"(null)".to_vec()
            } else {
                self.cstr(r)
            };
            cfprintf!(dfile, b"Report %d: %s\n", i as i32, s);
        }

        // FIXME -- according to the SCP spec, units for blfilt should be .01
        // Hz, not .0001 Hz;  but files from Spacelabs carts have blfilt equal
        // to 500 and clearly are diagnostic (0.05-100 Hz) bandwidth.
        cfprintf!(
            dfile,
            b"Bandwidth: %g-%d Hz\n",
            self.blfilt as f64 * 0.0001,
            self.lpfilt
        );
        cfprintf!(dfile, b"Filtering:");
        if self.filter_bit & 1 != 0 {
            cfprintf!(dfile, b" 60 Hz notch");
        }
        if self.filter_bit & 2 != 0 {
            cfprintf!(dfile, b" 50 Hz notch");
        }
        if self.filter_bit & 4 != 0 {
            cfprintf!(dfile, b" Artifact filter");
        }
        if self.filter_bit & 8 != 0 {
            cfprintf!(dfile, b" Baseline filter");
        }
        if self.filter_bit & 0xf0 != 0 {
            cfprintf!(dfile, b" <undefined>");
        }
        if self.filter_bit == 0 {
            cfprintf!(dfile, b" <not specified>");
        }
        cfprintf!(dfile, b"\n\n");

        cfprintf!(dfile, b"RR interval: %d\n", self.rrint);
        cfprintf!(dfile, b"P onset: %d\n", self.pon);
        cfprintf!(dfile, b"P end: %d\n", self.pend);
        cfprintf!(dfile, b"QRS onset: %d\n", self.qrson);
        cfprintf!(dfile, b"QRS end: %d\n", self.qrsend);
        cfprintf!(dfile, b"T end: %d\n", self.tend);
        cfprintf!(dfile, b"P axis: %d\n", self.paxis);
        cfprintf!(dfile, b"QRS axis: %d\n", self.qrsaxis);
        cfprintf!(dfile, b"T axis: %d\n", self.taxis);

        let m = self.precgmeas();
        dfile.write(&m);
        wfdbx::wfdbx_fclose_output(dfile, &self.pname, &dname); // WFDB-x

        // Generate the key file. The patient's name and ID number should
        // appear only in this file (and in the debugging output, if enabled
        // using -v).
        cfprintf!(kfile, b"%s key\n", VERSION_STRING);
        cfprintf!(
            kfile,
            b"Record: %s (%s %s)\n",
            recname,
            self.recdate,
            self.rectime
        );
        cfprintf!(kfile, b"Name: %s\n", self.patient_name);
        cfprintf!(kfile, b"MRN: %s\n", self.patient_id);
        wfdbx::wfdbx_fclose_output(kfile, &self.pname, &kname); // WFDB-x

        // If the -z option was selected, then for each signal:
        //  1. Calculate the median amplitude of the first 5000 samples in
        //     the signal
        //  2. If its final sample is zero, replace that sample with the
        //     previous one. This step eliminates transients that occur
        //     occasionally.
        //  3. Subtract the calculated median amplitude from all of the
        //     samples.
        // If the result after subtracting the median falls outside of the
        // +/- 10 millivolt range (+/- 2000 A/D units), it is assumed to be
        // invalid, and the sample is stored with the value
        // WFDB_INVALID_SAMPLE (-32768).
        if self.zflag != 0 {
            let nout = self.nout;
            for s in 0..self.nleads.max(0) as i64 {
                let ns = self.nsampk(s);
                let mut buf = std::mem::take(&mut self.zbuf);
                let Some(sig) = self.sigp_mut(s) else {
                    self.zbuf = buf;
                    continue;
                };
                let imax = if ns > 5000 { 5000 } else { ns as usize };
                for (i, bv) in buf.iter_mut().enumerate().take(imax) {
                    *bv = if i < sig.len() { sig[i] } else { 0 };
                }
                buf[..imax].sort_unstable();
                let m = buf[imax / 2];
                let k = ns.wrapping_sub(1);
                if 1 <= k && k < sig.len() as u64 && sig[k as usize] == 0 {
                    sig[k as usize] = sig[k as usize - 1];
                }
                let mut ii: u64 = 0;
                while ii < nout && ii < sig.len() as u64 {
                    let v = (sig[ii as usize] as i32 - m as i32) as i16;
                    sig[ii as usize] = v;
                    if !(-2000..=2000).contains(&v) {
                        sig[ii as usize] = WFDB_INVALID_SAMPLE;
                    }
                    ii += 1;
                }
                self.zbuf = buf;
            }
        }

        // Write the WFDB-format record if requested (-w option).
        if self.wflag != 0 {
            self.write_wfdb_record();
        }

        let order = self.order();

        // Write the ECG in text form if requested (-v option).
        if let Some(mut tfile) = tfile {
            if self.vflag > 1 {
                cfprintf!(
                    tfile,
                    b"samp#      I     II    III    aVR    aVF    aVL     V1     V2     V3     V4     V5     V6"
                );
            }
            let mut line = Vec::new();
            for i in 0..self.nout {
                line.clear();
                cstd::sprintf_into(&mut line, b"%5d", &[cstd::ToArg::to_arg(&(i as i32))]);
                for &o in &order {
                    cstd::sprintf_into(
                        &mut line,
                        b"%7d",
                        &[cstd::ToArg::to_arg(&self.sample_at(o, i))],
                    );
                }
                line.push(b'\n');
                tfile.write(&line);
            }
            wfdbx::wfdbx_fclose_output(tfile, &self.pname, &tname); // WFDB-x
        }

        // Finally, output the ECG in vector (binary) form.
        // ** FIXME ** This assumes that the sampling frequency is 500 Hz,
        // that nsamp[leadII] >= 5000, and that nsamp[all other leads] >=
        // 1250.
        let mut prolog = VERSION_STRING.to_vec();
        prolog.extend_from_slice(b" signals\nRecord: ");
        prolog.extend_from_slice(&recname);
        prolog.extend_from_slice(b" (");
        prolog.extend_from_slice(&self.recdate);
        prolog.push(b' ');
        prolog.extend_from_slice(&self.rectime);
        prolog.extend_from_slice(b")\n");
        if self.lflag != 0 {
            prolog.extend_from_slice(b"Low-pass filtered\n");
            self.lowpass();
        }
        prolog.resize(512, 0);
        efile.write(&prolog);
        let rows = [
            [self.lead_i, self.avr, self.v1, self.v4],
            [self.lead_ii, self.avl, self.v2, self.v5],
            [self.lead_iii, self.avf, self.v3, self.v6],
        ];
        for row in &rows {
            for (k, &l) in row.iter().enumerate() {
                write_samples(&mut efile, &self.sigr(l as i64), 1250 * k, 1250);
            }
        }
        write_samples(&mut efile, &self.sigr(self.lead_ii as i64), 0, 5000);
        wfdbx::wfdbx_fclose_output(efile, &self.pname, &ename); // WFDB-x

        1
    }

    // ---- sections ----

    fn hexdump(&self, p: i64, len: i64) {
        cprintf!(b"Hex dump of data area:\n\n");
        for i in 0..len.max(0) {
            if i % 16 == 0 {
                cprintf!(b"\n%4d:  ", i as i32);
            }
            cprintf!(b" %2x", self.b(p + i));
        }
        cprintf!(b"\n\n");
    }

    fn section0(&mut self, mut p: i64, mut len: i64) -> i32 {
        let id = b"SCPECG";
        let mut matched = true;
        for (k, &c) in id.iter().enumerate() {
            if self.b(p + SCPECG_POS + k as i64) != c as u32 {
                matched = false;
                break;
            }
        }
        if !matched && self.vflag != 0 {
            cprintf!(b" Warning: SCPECG identifier is missing in header\n");
        }
        p += SECHDRLEN;
        len -= SECHDRLEN; // move to data area
        if len < SECPTRLEN {
            if self.vflag != 0 {
                cprintf!(b" Error: section 0 contains no data\n");
            }
            return 0;
        }

        while len > 0 {
            let sec_id = self.get16(p);
            let sec_len = self.get32(p + 2);
            let sec_index = self.get32(p + 6);
            if self.vflag != 0 {
                cprintf!(
                    b"  Section %2d:%6lld bytes beginning at byte %6lld\n",
                    sec_id as i32,
                    sec_len as i64,
                    sec_index as i64
                );
            }
            len -= SECPTRLEN;
            p += SECPTRLEN;
        }
        if len < 0 {
            if self.vflag != 0 {
                cprintf!(b" Error: section 0 overlaps the next section\n");
            }
            return 0;
        }
        1
    }

    fn censor(&mut self, mut p: i64, mut len: u16, c: u8) {
        loop {
            len = len.wrapping_sub(1);
            if len == 0 {
                break;
            }
            if p >= 0 && (p as u64) < self.data.len() as u64 {
                self.data[p as usize] = c;
            }
            p += 1;
        }
        if p >= 0 && (p as u64) < self.data.len() as u64 {
            self.data[p as usize] = 0;
        }
    }

    fn section1(&mut self, mut p: i64, mut len: i64) -> i32 {
        #[derive(Clone, Copy, PartialEq)]
        enum Vt {
            Text,
            Date,
            Time,
            B1,
            B2,
            B2b1,
            Bn,
            Mixed,
        }
        let (mut tpatid, mut trefdr, mut tcomments, mut tdate, mut ttime) =
            (-1i64, -1i64, -1i64, -1i64, -1i64);
        let (mut pyob, mut firstname, mut lastname) = (-1i64, -1i64, -1i64);
        let p_save = p;
        let len_save = len;
        let v = self.vflag != 0;
        let a = self.aflag != 0;

        p += SECHDRLEN;
        len -= SECHDRLEN; // move to data area
        if len < TAGHDRLEN {
            if v {
                cprintf!(b" Error: section 1 contains no data\n");
            }
            return 0;
        }

        while len > 2 {
            let tag = self.b(p);
            if tag == TAG_END {
                break; // tag 255 is the terminator
            }
            let mut vlen = self.get16(p + 1);
            if vlen as i64 > len {
                if v {
                    cprintf!(b" Error: tagged field overlaps next section\n");
                }
                return 0;
            }
            let vtype;
            macro_rules! say {
                ($s:expr) => {
                    if v {
                        cprintf!($s);
                    }
                };
            }
            let d = p + TAGHDRLEN; // the field's data
            match tag {
                0 => {
                    say!(b"\n  Last name\n");
                    vtype = Vt::Text;
                    lastname = d;
                    if a {
                        self.censor(lastname, vlen as u16, b'x');
                    }
                }
                1 => {
                    say!(b"\n  First name\n");
                    vtype = Vt::Text;
                    firstname = d;
                    if a {
                        self.censor(firstname, vlen as u16, b'x');
                    }
                }
                2 => {
                    say!(b"\n  Patient ID number\n");
                    vtype = Vt::Text;
                    tpatid = d;
                    if a {
                        self.censor(tpatid, vlen as u16, b'0');
                    }
                }
                3 => {
                    say!(b"\n  Second last name\n");
                    vtype = Vt::Text;
                    if a {
                        self.censor(d, vlen as u16, b'x');
                    }
                }
                4 => {
                    say!(b"\n  Age\n");
                    vtype = Vt::B2b1;
                    self.age = self.get16(d) as i32; // FIXME
                    if a && self.age > MAXAGE {
                        self.put16(MAXAGE as u32, d); // censor age if over 90
                    }
                }
                5 => {
                    say!(b"\n  Date of birth\n");
                    vtype = Vt::Date;
                    if a {
                        pyob = d; // save pointer to year of birth
                        self.put16(257, d + 2); // censor month and day (257 => 1 Jan)
                    }
                }
                6 => {
                    say!(b"\n  Height\n");
                    vtype = Vt::B2b1;
                }
                7 => {
                    say!(b"\n  Weight\n");
                    vtype = Vt::B2b1;
                }
                8 => {
                    say!(b"\n  Sex\n");
                    vtype = Vt::B1;
                    self.sex = self.b(d) as i32;
                }
                9 => {
                    say!(b"\n  Race\n");
                    vtype = Vt::B1;
                }
                10 => {
                    say!(b"\n  Drug\n");
                    vtype = Vt::Mixed;
                }
                11 => {
                    say!(b"\n  Systolic blood pressure\n");
                    vtype = Vt::B2;
                }
                12 => {
                    say!(b"\n  Diastolic blood pressure\n");
                    vtype = Vt::B2;
                }
                13 => {
                    say!(b"\n  Diagnosis or referral indication\n");
                    vtype = Vt::Text;
                }
                14 => {
                    say!(b"\n  ID of the acquiring device\n");
                    self.tdevid = self.get16(d + 4) as i32;
                    self.tinst = self.get16(d) as i32; // institution #
                    self.tdept = self.get16(d + 2) as i32; // department #
                    if v {
                        cprintf!(b"   Institution number: %d\n", self.get16(d) as i32);
                        cprintf!(b"   Department number: %d\n", self.get16(d + 2) as i32);
                        cprintf!(b"   Device ID: %d\n", self.get16(d + 4) as i32);
                        let c = self.b(d + 6);
                        cprintf!(
                            b"   Device type: %d (%s)\n",
                            c as i32,
                            match c {
                                0 => &b"cart"[..],
                                1 => &b"system or host"[..],
                                _ => &b"<error>"[..],
                            }
                        );
                        cprintf!(b"   Manufacturer code: %d\n", self.b(d + 7) as i32);
                        cprintf!(b"   Text model description: [%d]", self.b(d + 8) as i32);
                        cprintf!(
                            b"   SCP-ECG protocol revision number: %g\n",
                            self.b(d + 14) as f64 / 10.0
                        );
                        cprintf!(
                            b"   SCP-ECG protocol compatibility level: %d\n",
                            self.b(d + 15) as i32
                        );
                        cprintf!(b"   Language support code: %d\n", self.b(d + 16) as i32);
                        cprintf!(b"   Device capabilities: %d\n", self.b(d + 17) as i32);
                        let c = self.b(d + 18);
                        cprintf!(b"   AC mains frequency environment: %d ", c as i32);
                        match c {
                            0 => cprintf!(b"(unspecified)\n"),
                            1 => cprintf!(b"(50 Hz)\n"),
                            2 => cprintf!(b"(60 Hz)\n"),
                            _ => cprintf!(b"<error>"),
                        };
                        const LABELS: [&[u8]; 5] = [
                            b"Analyzing program revision number",
                            b"Serial number of acquisition device",
                            b"Acquisition device system software ID",
                            b"Acquisition device SCP implementation ID",
                            b"Manufacturer of acquisition device",
                        ];
                        let mut q = d + 36;
                        for label in LABELS {
                            let s = self.cstr(q);
                            cprintf!(b"   %s: [%s]\n", label, s);
                            q += s.len() as i64 + 1;
                        }
                    }
                    vtype = Vt::Mixed;
                }
                15 => {
                    say!(b"\n  ID of the analyzing device\n");
                    vtype = Vt::Mixed;
                }
                16 => {
                    say!(b"\n  Acquiring institution\n");
                    vtype = Vt::Text;
                    self.inst = d;
                    if a {
                        self.censor(d, vlen as u16, b'x');
                    }
                }
                17 => {
                    say!(b"\n  Analyzing institution\n");
                    vtype = Vt::Text;
                    if a {
                        self.censor(d, vlen as u16, b'x');
                    }
                }
                18 => {
                    say!(b"\n  Acquiring department\n");
                    vtype = Vt::Text;
                    if a {
                        self.censor(d, vlen as u16, b'x');
                    }
                    self.dept = d;
                }
                19 => {
                    say!(b"\n  Analyzing department\n");
                    vtype = Vt::Text;
                    if a {
                        self.censor(d, vlen as u16, b'x');
                    }
                }
                20 => {
                    say!(b"\n  Referring physician\n");
                    vtype = Vt::Text;
                    if a {
                        self.censor(d, vlen as u16, b'x');
                    }
                    trefdr = d;
                }
                21 => {
                    say!(b"\n  Latest confirming physician\n");
                    vtype = Vt::Text;
                    if a {
                        self.censor(d, vlen as u16, b'x');
                    }
                }
                22 => {
                    say!(b"\n  Technician\n");
                    vtype = Vt::Text;
                    if a {
                        self.censor(d, vlen as u16, b'x');
                    }
                }
                23 => {
                    say!(b"\n  Room\n");
                    vtype = Vt::Text;
                    if a {
                        self.censor(d, vlen as u16, b'x');
                    }
                }
                24 => {
                    say!(b"\n  Stat code (urgency)\n");
                    vtype = Vt::B1;
                }
                25 => {
                    say!(b"\n  Date of acquisition\n");
                    tdate = d;
                    if a {
                        // (the pointer to the year of acquisition is saved,
                        // but never used)
                        self.put16(257, d + 2); // censor month and day (257 => 1 Jan)
                    }
                    vtype = Vt::Date;
                }
                26 => {
                    say!(b"\n  Time of acquisition\n");
                    ttime = d;
                    vtype = Vt::Time;
                }
                27 => {
                    say!(b"\n  Baseline filter\n");
                    vtype = Vt::B2;
                    self.blfilt = self.get16(d) as i32;
                }
                28 => {
                    say!(b"\n  Low-pass filter\n");
                    vtype = Vt::B2;
                    self.lpfilt = self.get16(d) as i32;
                }
                29 => {
                    say!(b"\n  Filter bit map\n");
                    vtype = Vt::B1;
                    self.filter_bit = self.b(d) as i32;
                }
                30 => {
                    say!(b"\n  Free text field (comments)\n");
                    tcomments = d;
                    vtype = Vt::Text;
                }
                31 => {
                    say!(b"\n  Sequence number\n");
                    vtype = Vt::Text;
                }
                32 => {
                    say!(b"\n  Medical history codes\n");
                    vtype = Vt::Bn;
                }
                33 => {
                    say!(b"\n  Electrode configuration code\n");
                    vtype = Vt::B2;
                }
                34 => {
                    say!(b"\n  Time zone\n");
                    vtype = Vt::Mixed;
                }
                35 => {
                    say!(b"\n  Free text medical history\n");
                    vtype = Vt::Text;
                }
                _ => {
                    say!(b"\n  <Undefined tag>\n");
                    vtype = Vt::Mixed;
                }
            }
            if v {
                cprintf!(b"   Tag%3d (%2d bytes): ", tag as i32, vlen as i32);
            }
            p += TAGHDRLEN;
            len -= vlen as i64 + TAGHDRLEN;
            if vlen == 0 {
                say!(b"<not defined>\n");
                continue;
            }
            match vtype {
                Vt::Text => {
                    if v {
                        cprintf!(b"[%*s]", vlen as i32 - 1, self.cstr(p));
                    }
                    p += vlen as i64;
                }
                Vt::Date => {
                    if vlen != 4 {
                        if v {
                            cprintf!(b"  Error: incorrect date format (%d bytes)\n", vlen as i32);
                        }
                    } else if v {
                        cprintf!(
                            b"%4d/%02d/%02d",
                            self.get16(p) as i32,
                            self.b(p + 2) as i32,
                            self.b(p + TAGHDRLEN) as i32
                        );
                    }
                    p += vlen as i64;
                }
                Vt::Time => {
                    if vlen != 3 {
                        if v {
                            cprintf!(b"  Error: incorrect time format (%d bytes)\n", vlen as i32);
                        }
                    } else if v {
                        cprintf!(
                            b"%02d:%02d:%02d",
                            self.b(p) as i32,
                            self.b(p + 1) as i32,
                            self.b(p + 2) as i32
                        );
                    }
                    p += vlen as i64;
                }
                Vt::B1 => {
                    if vlen != 1 {
                        if v {
                            cprintf!(
                                b"  Error: incorrect format (%d bytes instead of 1)\n",
                                vlen as i32
                            );
                        }
                    } else if v {
                        cprintf!(b"%d", self.b(p) as i32);
                    }
                    p += vlen as i64;
                }
                Vt::B2 => {
                    if vlen != 2 {
                        if v {
                            cprintf!(
                                b"  Error: incorrect format (%d bytes instead of 2)\n",
                                vlen as i32
                            );
                        }
                    } else if v {
                        cprintf!(b"%d", self.get16(p) as i32);
                    }
                    p += vlen as i64;
                }
                Vt::B2b1 => {
                    if vlen != 3 {
                        if v {
                            cprintf!(
                                b"  Error: incorrect format (%d bytes instead of 3)\n",
                                vlen as i32
                            );
                        }
                    } else if v {
                        cprintf!(b"%d (code %d)", self.get16(p) as i32, self.b(p + 2) as i32);
                    }
                    p += vlen as i64;
                }
                Vt::Bn => {
                    while vlen > 0 {
                        vlen -= 1;
                        if v {
                            cprintf!(b"%d, ", self.b(p) as i32);
                        }
                        p += 1;
                    }
                }
                Vt::Mixed => {
                    if v {
                        let mut o = Vec::new();
                        while vlen > 0 {
                            vlen -= 1;
                            let c = self.b(p);
                            if isprint_c(c) {
                                o.push(c as u8);
                            } else {
                                cstd::sprintf_into(&mut o, b"\\%03o", &[cstd::ToArg::to_arg(&c)]);
                            }
                            p += 1;
                        }
                        o.push(b'\n');
                        cstd::out().write(&o);
                    } else {
                        p += vlen as i64;
                    }
                }
            }
        }

        // (tdate and ttime are pointers to signed char)
        if tdate >= 0 {
            let mon = self.b(tdate + 2) as u8 as i8 as i32 - 1;
            self.recdate = cformat!(
                b"%d %s %d",
                self.b(tdate + 3) as u8 as i8,
                if (0..12).contains(&mon) {
                    MONTH[mon as usize]
                } else {
                    &b"???"[..]
                },
                self.get16(tdate) as i32
            );
        }
        if ttime >= 0 {
            self.rectime = cformat!(
                b"%02d:%02d:%02d",
                self.b(ttime) as u8 as i8,
                self.b(ttime + 1) as u8 as i8,
                self.b(ttime + 2) as u8 as i8
            );
        }
        let slast = if lastname < 0 {
            b"<last name missing>".to_vec()
        } else {
            self.cstr(lastname)
        };
        let sfirst = if firstname < 0 {
            b"<first name missing>".to_vec()
        } else {
            self.cstr(firstname)
        };
        if slast.len() + sfirst.len() < 100 - 3 {
            let mut n = slast.clone();
            n.extend_from_slice(b", ");
            n.extend_from_slice(&sfirst);
            self.patient_name = n;
        } else {
            ceprintf!(b"Patient name (%s, %s) is too long\n", slast, sfirst);
            self.patient_name = b"Name not available -- too long".to_vec();
        }
        let trunc = |mut s: Vec<u8>, n: usize| {
            s.truncate(n);
            s
        };
        self.patient_id = trunc(
            if tpatid < 0 {
                b"<patient ID missing>".to_vec()
            } else {
                self.cstr(tpatid)
            },
            30,
        );
        self.referring_dr = trunc(
            if trefdr < 0 {
                b"<referring physician missing>".to_vec()
            } else {
                self.cstr(trefdr)
            },
            100,
        );
        self.comments = trunc(
            if tcomments < 0 {
                b"<comments missing>".to_vec()
            } else {
                self.cstr(tcomments)
            },
            200,
        );

        if self.b(p) != TAG_END && v {
            cprintf!(b" Error: header terminator (tag 255) is missing\n");
        }
        // (tpatid cannot be NULL here, so that error is never reported)
        if (self.tdevid == -1 || self.tinst == -1 || self.tdept == -1) && v {
            cprintf!(b" Error: device ID number (tag 14) is missing\n");
        }
        if tdate < 0 && v {
            cprintf!(b" Error: date of acquisition (tag 25) is missing\n");
        }
        if ttime < 0 && v {
            cprintf!(b" Error: time of acquisition (tag 26) is missing\n");
        }

        if a && pyob >= 0 {
            // (the censored year of birth is computed but never stored)
            // Recalculate the CRC for this section.
            let crc = self.getcrc(p_save + CRCLEN, len_save - CRCLEN);
            self.put16(crc as u32, p_save);
        }

        if self.b(p) != TAG_END || self.tdevid == -1 || tdate < 0 || ttime < 0 {
            return 0;
        }
        1
    }

    fn section2(&mut self, mut p: i64, mut len: i64) -> i32 {
        p += SECHDRLEN;
        len -= SECHDRLEN; // move to data area
        if len < 2 {
            if self.vflag != 0 {
                cprintf!(b"  Error: section 2 contains no data\n");
            }
            return 0;
        }

        let ntables = self.get16(p);
        if ntables == HT_DEFAULT_ONLY {
            if self.vflag != 0 {
                cprintf!(b"  Using standard Huffman table only\n");
            }
        } else {
            if self.vflag != 0 {
                cprintf!(
                    b"  Number of Huffman tables defined: %d\n",
                    self.get16(p) as i32
                );
            }
            if self.vflag != 0 {
                cprintf!(
                    b"  Number of code structures in table 1: %d\n",
                    self.get16(p + 2) as i32
                );
            }
            // ** more to do here **
        }
        1
    }

    fn section3(&mut self, mut p: i64, mut len: i64) -> i32 {
        let mut i: i32 = 0;
        let mut nsmax: i32 = 0;
        let v = self.vflag != 0;

        p += SECHDRLEN;
        len -= SECHDRLEN; // move to data area

        if len < 2 {
            if v {
                cprintf!(b"  Error: section3 contains no data\n");
            }
            return 0;
        }

        self.nleads = self.b(p) as i32;
        p += 1;
        if v {
            cprintf!(b"  Number of leads: %d\n", self.nleads);
        }
        len -= 1;

        self.nsamp = vec![0; self.nleads as usize + 4];

        if v {
            cprintf!(b"  Flag byte: %xH\n", self.b(p));
        }
        len -= 1;
        if self.b(p) & 1 != 0 {
            if v {
                cprintf!(b"   Reference beat subtraction used for compression\n");
            }
        } else if v {
            cprintf!(b"   Reference beat subtraction not used for compression\n");
        }
        if self.b(p) & 4 != 0 {
            if v {
                cprintf!(b"   All leads recorded simultaneously\n");
            }
        } else if v {
            cprintf!(
                b"   %d leads recorded simultaneously\n",
                ((self.b(p) >> 3) & 0xf) as i32
            );
        }
        p += 1;

        while len > 8 {
            let j = self.b(p + 8) as i32;
            if j < NLEADNAMES {
                if v {
                    cprintf!(b"  %s", LEADNAME[j as usize]);
                }
                let idx = i as i16;
                match j {
                    1 => self.lead_i = idx,
                    2 => self.lead_ii = idx,
                    61 => self.lead_iii = idx,
                    62 => self.avr = idx,
                    64 => self.avf = idx,
                    63 => self.avl = idx,
                    3 => self.v1 = idx,
                    4 => self.v2 = idx,
                    5 => self.v3 = idx,
                    6 => self.v4 = idx,
                    7 => self.v5 = idx,
                    8 => self.v6 = idx,
                    _ => {}
                }
            } else if j < 100 {
                if v {
                    cprintf!(b"  <Reserved lead>");
                }
            } else if v {
                cprintf!(b"  <Manufacturer-defined lead>");
            }
            if v {
                cprintf!(
                    b": ID %d, samples %llu to %llu\n",
                    j,
                    self.get32(p),
                    self.get32(p + 4)
                );
            }
            let ns = self
                .get32(p + 4)
                .wrapping_sub(self.get32(p))
                .wrapping_add(1);
            if (i as usize) < self.nsamp.len() {
                self.nsamp[i as usize] = ns;
            } else {
                self.nsamp.push(ns);
            }
            i += 1;
            p += 9;
            len -= 9;
        }

        // allocate space for 4 extra signals that will be calculated later,
        // and for a NULL pointer to signal the end of the array
        self.ecg.clear();
        self.ecg.resize(self.nleads as usize + 5, None);
        self.have_ecg = true;

        for i in 0..(self.nleads + 4) as usize {
            if i as i32 >= self.nleads {
                self.nsamp[i] = nsmax as i64 as u64;
            } else if self.nsamp[i] > nsmax as i64 as u64 {
                nsmax = self.nsamp[i] as u32 as i32;
            }
            if self.nsamp[i] < 1 {
                self.nsamp[i] = 1;
            }
            match newsig(self.nsamp[i]) {
                Some(s) => self.ecg[i] = Some(s),
                None => {
                    if v {
                        cprintf!(b"  Error: too many (%d) leads\n", self.nleads);
                    }
                    return 0;
                }
            }
        }

        if len < 0 {
            return 0;
        }
        1
    }

    fn section4(&mut self, mut p: i64, mut len: i64) -> i32 {
        let mut stat = 1;
        let v = self.vflag != 0;

        p += SECHDRLEN;
        len -= SECHDRLEN; // move to data area
        if len < 6 {
            if v {
                cprintf!(b"  Error: section 4 contains no data\n");
            }
            return 0;
        }
        self.rblenms = self.get16(p) as i64;
        self.fc_m = self.get16(p + 2) as i32;
        self.nqrs = self.get16(p + 4) as i32;
        if v {
            cprintf!(
                b"  Length of reference beat type 0 data: %lld msec\n",
                self.rblenms
            );
            cprintf!(
                b"  Sample # of fiducial relative to start of ref beat type 0: %d\n",
                self.fc_m
            );
            cprintf!(
                b"  Number of QRS complexes in the entire record: %d\n",
                self.nqrs
            );
        }

        if self.nqrs < 1 {
            return 0; // no beats -- nothing else to do here
        }

        p += 6;
        len -= 6;
        self.subz.clear();
        self.subz.resize(self.nqrs as usize, None);

        if len >= self.nqrs as i64 * 14 {
            if v {
                cprintf!(b"  Reference beat subtraction zones:\n");
            }
            let mut i = 0;
            while i < self.nqrs && len >= 14 {
                let mut z = Subzone {
                    ztype: self.get16(p) as i16,
                    t0: self.get32(p + 2) as i64,
                    t1: self.get32(p + 6) as i64,
                    t2: self.get32(p + 10) as i64,
                };
                if z.ztype == 0 && z.t2 == 0 {
                    z.ztype = 9;
                }
                self.subz[i as usize] = Some(z);

                if v {
                    cprintf!(
                        b"   %2d  Type: %2d  start: %7lld  fiducial: %7lld  end: %7lld\n",
                        i + 1,
                        z.ztype,
                        z.t0,
                        z.t1,
                        z.t2
                    );
                    if z.ztype != 0 && (z.t0 != 0 || z.t2 != 0) {
                        cprintf!(
                            b"  Error: start and end should be zero for beats of non-zero types\n"
                        );
                    }
                }
                p += 14;
                len -= 14;
                i += 1;
            }
        } else {
            if v {
                cprintf!(b"  Error: reference beat subtraction zones are missing\n");
            }
            stat = 0;
        }
        if len >= self.nqrs as i64 * 8 {
            if v {
                cprintf!(b"  QRS locations:\n");
            }
            for i in 0..self.nqrs {
                if v {
                    cprintf!(
                        b"   %2d  start: %7llu  end: %7llu\n",
                        i + 1,
                        self.get32(p),
                        self.get32(p + 4)
                    );
                }
                p += 8;
            }
        } else {
            if v {
                cprintf!(b"  Error: QRS locations are missing\n");
            }
            stat = 0;
        }
        stat
    }

    fn section5(&mut self, mut p: i64, mut len: i64) -> i32 {
        p += SECHDRLEN;
        len -= SECHDRLEN; // move to data area

        if len <= 0 {
            if self.vflag != 0 {
                cprintf!(b" Error: section 5 contains no data\n");
            }
            return 0;
        }

        // Calculate length of template in samples
        let d = self.get16(p + 2);
        let mut x = self.rblenms as f64 * 1000.0;
        if d != 0 {
            x /= d as f64;
        } else {
            x = if x == 0.0 { f64::NAN } else { f64::INFINITY };
        }
        self.rblen = cstd::d2l(x);

        self.refbeat.clear();
        self.refbeat.resize((self.nleads + 1).max(0) as usize, None);

        for i in 0..self.nleads.max(0) as usize {
            if self.rblen < 0 || self.rblen as u64 > MAXALLOC {
                ceprintf!(b"  Error: too many (%d) leads\n", self.nleads);
                return 0;
            }
            self.refbeat[i] = Some(vec![0; self.rblen as usize]);
        }

        self.huffdecode(p, len, 5)
    }

    /// Read bits from the input buffer, beginning `ibits` bits from the MSB
    /// of the byte at `p`, until a Huffman-encoded value is recognized. The
    /// decoded value is stored into `x`; returns the number of bits read.
    fn getbits(&mut self, x: &mut i16, p: i64, mut ibits: u64) -> u64 {
        let mut bitbuffer: u16 = 0;
        let mut nbits: u32 = 0; // number of bits read on this call to getbits

        loop {
            bitbuffer <<= 1; // make room for a bit

            if (ibits & 7) == 0 {
                // once every 8 bits ... get 8
                self.w = self.b(p.wrapping_add((ibits / 8) as i64)) as u8;
            }
            // copy next bit from w into bitbuffer ...
            if self.w & 0x80 != 0 {
                bitbuffer |= 1;
            }
            // ... and discard it from w
            self.w <<= 1;

            ibits = ibits.wrapping_add(1);
            nbits += 1;

            // check bitbuffer against all of the Huffman table entries
            for &(pattern, suffixbits, basevalue) in &HTDEFAULT {
                if bitbuffer == pattern {
                    // we have a match
                    let mut j = suffixbits as i32;
                    if j == 0 {
                        *x = basevalue;
                    } else {
                        // j is the number of additional bits we need; as
                        // above, get 8 more bits if needed
                        if (ibits & 7) == 0 {
                            self.w = self.b(p.wrapping_add((ibits / 8) as i64)) as u8;
                        }
                        // Get the first (most significant) bit of the value;
                        // if it's a 1, sign-extend it.
                        let mut v: i16;
                        if self.w & 0x80 != 0 {
                            v = 1;
                            for _ in j..16 {
                                v <<= 1; // make room for another bit
                                v |= 1; // shift in another 1
                            }
                        } else {
                            v = 0;
                        }
                        self.w <<= 1;
                        ibits = ibits.wrapping_add(1);
                        nbits += 1;
                        j -= 1;
                        while j > 0 {
                            v <<= 1;
                            if (ibits & 7) == 0 {
                                self.w = self.b(p.wrapping_add((ibits / 8) as i64)) as u8;
                            }
                            if self.w & 0x80 != 0 {
                                v |= 1;
                            }
                            self.w <<= 1;
                            j -= 1;
                            ibits = ibits.wrapping_add(1);
                            nbits += 1;
                        }
                        *x = v;
                    }
                    return nbits as u64;
                }
            }
            if nbits >= 64 - 1 {
                break;
            }
        }
        if self.vflag != 0 {
            cprintf!(b"Huffman encoding error\n");
        }
        1000000
    }

    fn section6(&mut self, mut p: i64, mut len: i64) -> i32 {
        p += SECHDRLEN;
        len -= SECHDRLEN; // move to data area

        if len <= 6 {
            if self.vflag != 0 {
                cprintf!(b" Error: section 6 contains no data\n");
            }
            return 0;
        }
        self.huffdecode(p, len, 6)
    }

    #[allow(clippy::needless_range_loop)]
    fn huffdecode(&mut self, mut p: i64, mut len: i64, section: i32) -> i32 {
        let v = self.vflag != 0;
        let mut tleadlen: u64 = 0;
        let g = self.get16(p) as f64;

        if section == 5 {
            self.gref = g / 5000.0;
        } else {
            self.gres = g / 5000.0;
        }
        if v {
            cprintf!(b"  Amplitude value multiplier: %g nanovolts per unit\n", g);
        }
        let sampint = self.get16(p + 2) as i32;
        if v {
            cprintf!(b"  Sample time interval: %d microseconds\n", sampint);
        }
        if sampint > 0 {
            if self.sfreq > 0.0 && self.sfreq != 1.0e6 / sampint as f64 {
                cprintf!(b"Warning: section 5 and 6 sample intervals don't match");
            }
            // FIXME: If this ever happens, we need to redo the reconstruction
            // code in main()
            self.sfreq = 1.0e6 / sampint as f64;
        } else if wfdbx::wfdbx_get_legacy() != 0 {
            // WFDB-x: as in the C program (legacy mode)
            cprintf!(b"Error: sampling frequency not specified;  assuming 500 Hz\n");
            self.sfreq = 500.0;
        } else {
            // WFDB-x: the C program assumed 500 Hz
            cprintf!(b"Error: sampling frequency not specified\n");
        }
        // (the encoding type is read from the high byte of the sample
        // interval)
        if v {
            cprintf!(b"  Encoding type: %d ", self.b(p + 3) as i32);
        }
        let enctype = match self.b(p + 3) {
            0 => {
                if v {
                    cprintf!(b"(amplitudes)\n");
                }
                0
            }
            1 => {
                if v {
                    cprintf!(b"(first differences)\n");
                }
                1
            }
            2 => {
                if v {
                    cprintf!(b"(second differences)\n");
                }
                2
            }
            _ => {
                if v {
                    cprintf!(b"<undefined, assuming second differences>\n");
                }
                2
            }
        };
        if section == 6 {
            if v {
                cprintf!(b"  Compression type: %d ", self.b(p + 4) as i32);
            }
            match self.b(p + 4) {
                0 => {
                    if v {
                        cprintf!(b"(non-bimodal)\n");
                    }
                }
                1 => {
                    if v {
                        cprintf!(b"(bimodal)\n");
                    }
                }
                _ => {
                    if v {
                        cprintf!(b"<undefined, assuming bimodal>\n");
                    }
                }
            }
        }
        p += 6;
        len -= 6;

        if self.nleads < 0 {
            if v {
                cprintf!(
                    b"  Error: number of leads undefined -- section 3 missing or out of order\n"
                );
            }
            return 0;
        }
        if self.nleads == 0 {
            if v {
                cprintf!(b"  Error: no leads recorded\n");
            }
            return 0;
        }
        let nleads = self.nleads as usize;
        let mut leadlen = vec![0u64; nleads];

        for (i, ll) in leadlen.iter_mut().enumerate() {
            *ll = self.get16(p) as u64;
            tleadlen = tleadlen.wrapping_add(*ll);
            if v {
                cprintf!(b"  Lead %d:%5llu bytes\n", i as i32, *ll);
            }
            p += 2;
            len -= 2;
        }

        let ulen = len as u64;
        if ulen < tleadlen {
            if v {
                let d = tleadlen - ulen;
                cprintf!(
                    b"  Error: %llu data byte%s missing from section %d\n",
                    d,
                    if d == 1 { &b""[..] } else { &b"s"[..] },
                    section
                );
            }
            return 0;
        } else if ulen > ((tleadlen + 1) & !1u64) {
            // the expression above rounds tleadlen up to an even number
            if v {
                let d = ulen - tleadlen;
                cprintf!(
                    b"  Warning: %llu extra byte%s in section %d\n",
                    d,
                    if d == 1 { &b""[..] } else { &b"s"[..] },
                    section
                );
            }
        }

        for i in 0..nleads {
            if v {
                cprintf!(b"  Lead %d data\n", i as i32);
                for j in 0..10 {
                    cprintf!(b" %02x", self.b(p + j));
                }
                cprintf!(b"\n");
            }
            self.hxxx = 0;
            self.hxx = 0;
            let explen: i32;
            let gain: f64;
            if section == 6 {
                explen = self.nsamp[i] as u32 as i32;
                gain = self.gres;
            } else {
                explen = self.rblen as i32;
                gain = self.gref;
            }
            let tbits = leadlen[i].wrapping_mul(8);
            let mut ibits: u64 = 0;
            let mut j: i32 = 0;
            while j < explen && ibits < tbits {
                let mut x = self.hx;
                ibits = ibits.wrapping_add(self.getbits(&mut x, p, ibits));
                self.hx = x;
                if j == 0 {
                    self.hxx = x;
                    self.hxxx = x;
                } else if j == 1 {
                    self.hdx = x.wrapping_sub(self.hxxx);
                    self.hxxx = x;
                    self.hxx = self.hxx.wrapping_add(x);
                } else {
                    self.hdx = self.hdx.wrapping_add(x);
                    self.hxxx = self.hxxx.wrapping_add(self.hdx);
                    self.hxx = self.hxx.wrapping_add(x);
                }
                self.hxout = match enctype {
                    0 => x,
                    1 => self.hxx,
                    _ => self.hxxx,
                };
                let val = d2s(self.hxout as f64 * gain);
                let dest = if section == 6 {
                    self.ecg.get_mut(i).and_then(|s| s.as_mut())
                } else {
                    self.refbeat.get_mut(i).and_then(|s| s.as_mut())
                };
                if let Some(dest) = dest {
                    if (j as usize) < dest.len() {
                        dest[j as usize] = val;
                    }
                }
                if self.vflag > 1 {
                    cprintf!(b"   %5d %5d %5d %5d\n", j, x, self.hxx, self.hxxx);
                }
                j += 1;
            }
            if j < explen && v {
                let d = leadlen[i].wrapping_sub(j as i64 as u64);
                cprintf!(
                    b"   Error: %lld sample%s missing in lead %d\n",
                    d as i64,
                    if d == 1 { &b""[..] } else { &b"s"[..] },
                    i as i32
                );
            }
            if ibits < tbits && v {
                let d = tbits - ibits;
                cprintf!(
                    b"   Warning: %lld extra bit%s in lead %d\n",
                    d as i64,
                    if d == 1 { &b""[..] } else { &b"s"[..] },
                    i as i32
                );
            }
            p += leadlen[i] as i64;
            if v {
                cprintf!(b"\n");
            }
        }
        1
    }

    fn section7(&mut self, mut p: i64, mut len: i64) -> i32 {
        let v = self.vflag != 0;
        p += SECHDRLEN;
        len -= SECHDRLEN; // move to data area

        if len <= 0 {
            if v {
                cprintf!(b" Error: section 7 contains no data\n");
            }
            return 0;
        }

        if self.xflag != 0 && v {
            self.hexdump(p, len);
        }

        if len < 20 {
            // there isn't enough room left for measurements
            if v {
                cprintf!(b" Error: section 7 is too short (len = %lld)\n", len);
            }
            return 0;
        }

        self.rrint = self.get16(p + 2) as i32;

        // get P onset, etc from first measurement block
        let mut q = p + 6;
        self.pon = self.get16(q) as i32;
        self.pend = self.get16(q + 2) as i32;
        self.qrson = self.get16(q + 4) as i32;
        self.qrsend = self.get16(q + 6) as i32;
        self.tend = self.get16(q + 8) as i32;
        self.paxis = self.get16(q + 10) as i16;
        self.qrsaxis = self.get16(q + 12) as i16;
        self.taxis = self.get16(q + 14) as i16;

        let nmb = self.b(p);
        let nps = self.b(p + 1);
        let mut sec7qrs_offset = (6 + 16 * nmb + 10 * nps) as i16;
        if sec7qrs_offset as i64 > len {
            sec7qrs_offset = len as i16;
        }

        if sec7qrs_offset as i64 > len {
            if v {
                cprintf!(
                    b" Error: section 7 is too short (nmb = %d, nps = %d)\n",
                    nmb as i32,
                    nps as i32
                );
            }
            return 0;
        }

        let sec7qrs = self.get16(p + sec7qrs_offset as i64) & 0xff;

        if v {
            cprintf!(b" QRS complexes measured: %d\n", sec7qrs as i32);
            cprintf!(b" Measurement blocks: %d\n", nmb as i32);
            if nmb == sec7qrs + 1 {
                cprintf!(b"  (First measurement block contains measurements for reference beat type 0;\n   Others contain measurements for each individual beat)\n");
            } else {
                cprintf!(b"  (Measurements for each reference beat type)\n");
            }
            cprintf!(b"  Number of measurement blocks: %d\n", nmb as i32);
            cprintf!(b"  Number of pacemaker spikes: %d\n", nps as i32);
            cprintf!(b"  Mean RR interval: %d ms\n", self.rrint);
            cprintf!(b"  Mean PP interval: %d ms\n", self.get16(p + 4) as i32);
            q = p + 6;
            for i in 0..nmb as i32 {
                cprintf!(b"   Block %d\n", i);
                cprintf!(b"    P onset:   %d ms\n", self.get16(q) as i32);
                cprintf!(b"    P end:     %d ms\n", self.get16(q + 2) as i32);
                cprintf!(b"    QRS onset: %d ms\n", self.get16(q + 4) as i32);
                cprintf!(b"    QRS  end:  %d ms\n", self.get16(q + 6) as i32);
                cprintf!(b"    T end:     %d ms\n", self.get16(q + 8) as i32);
                let n = self.get16(q + 10) as i16;
                if n == AXIS_UNDEF {
                    cprintf!(b"    P axis:    undefined\n");
                } else {
                    cprintf!(b"    P axis:    %d degrees\n", n);
                }
                let n = self.get16(q + 12) as i16;
                if n == AXIS_UNDEF {
                    cprintf!(b"    QRS axis:  undefined\n");
                } else {
                    cprintf!(b"    QRS axis:  %d degrees\n", n);
                }
                let n = self.get16(q + 14) as i16;
                if n == AXIS_UNDEF {
                    cprintf!(b"    T axis:    undefined\n");
                } else {
                    cprintf!(b"    T axis:    %d degrees\n", n);
                }
                q += 16;
            }
            if nps > 0 {
                cprintf!(b" Pacemaker spike measurement data\n");
            }
            let mut r = q + nps as i64 * 4;
            for i in 0..nps as i32 {
                cprintf!(
                    b"Spike %d: %u ms, %d microvolts ",
                    i,
                    self.get16(q),
                    self.get16(q + 2) as i32
                );
                match self.b(r) {
                    0 => cprintf!(b"(unknown spike type, "),
                    1 => cprintf!(b"(triggers neither P nor QRS, "),
                    2 => cprintf!(b"(triggers a QRS, "),
                    3 => cprintf!(b"(triggers a P, "),
                    c => cprintf!(b"(spike type %d, ", c as i32),
                };
                match self.b(r + 1) {
                    0 => cprintf!(b"source unknown, "),
                    1 => cprintf!(b"internal, "),
                    2 => cprintf!(b"external, "),
                    c => cprintf!(b"source type %d, ", c as i32),
                };
                let n = self.get16(r + 2) as i16;
                if n == 0 {
                    cprintf!(b" not linked to a QRS, ");
                } else {
                    cprintf!(b" linked to QRS #%d, ", n);
                }
                let n = self.get16(r + 4) as i16;
                if n == 0 {
                    cprintf!(b"width unknown)\n");
                } else {
                    cprintf!(b"%d microseconds\n)", n);
                }
                q += 4;
                r += 6;
            }

            // The next part doesn't seem to be right ...
            cprintf!(b" <!> sec7qrs = <%d>\n", sec7qrs as i32);
            if sec7qrs > 0 {
                cprintf!(b" QRS type information (%d beats)\n", self.get16(r) as i32);
            }
            q = r + 2;
            for i in 0..sec7qrs as i32 {
                cprintf!(b"  QRS %d: reference beat type %d\n", i, self.b(q) as i32);
                q += 1;
            }

            cprintf!(b"%lld bytes remaining in section 7\n", len - (q - p));
            let mut o = Vec::new();
            while q < p + len {
                // get16(q) reads one byte past the end of the section at the
                // last iteration (read as 0 beyond the end of the data)
                cstd::sprintf_into(
                    &mut o,
                    b" %5d [%3d]",
                    &[
                        cstd::ToArg::to_arg(&(self.get16(q) as i32)),
                        cstd::ToArg::to_arg(&(self.b(q) as i32)),
                    ],
                );
                q += 1;
            }
            o.push(b'\n');
            cstd::out().write(&o);
        }

        // ** more to do here **
        1
    }

    fn section8(&mut self, mut p: i64, mut len: i64) -> i32 {
        let v = self.vflag != 0;
        p += SECHDRLEN;
        len -= SECHDRLEN; // move to data area

        if len <= 0 {
            if v {
                cprintf!(b" Error: section 8 contains no data\n");
            }
            return 0;
        }

        if v {
            cprintf!(b" Status: %d ", self.b(p) as i32);
            match self.b(p) {
                0 => cprintf!(b"(original report, not confirmed)\n"),
                1 => cprintf!(b"(confirmed report)\n"),
                2 => cprintf!(b"(overread report, but not confirmed)\n"),
                _ => cprintf!(b"<undefined>\n"),
            };
            cprintf!(
                b" Date: %4d/%02d/%02d\n",
                self.get16(p + 1) as i32,
                self.b(p + 3) as i32,
                self.b(p + 4) as i32
            );
            cprintf!(
                b" Time: %02d:%02d:%02d\n",
                self.b(p + 5) as i32,
                self.b(p + 6) as i32,
                self.b(p + 7) as i32
            );
        }
        let n = self.b(p + 8) as i32;
        self.stmnts = n;
        if v {
            cprintf!(b" Number of statements: %d\n", n);
        }
        p += 9;
        len -= 9;

        let mut i = 0;
        while i < n && len > 2 {
            self.report[i as usize] = p + 3;
            let slen = self.get16(p + 1) as i32;
            if v {
                cprintf!(b"  Statement %2d: (%d bytes)\n", self.b(p) as i32, slen);
                cprintf!(b"   [%*s]\n", slen, self.cstr(p + 3));
            }
            p += slen as i64 + 3;
            len -= slen as i64 + 3;
            i += 1;
        }

        if i < n {
            if v {
                cprintf!(b"  Error: data missing in section 8\n");
            }
            return 0;
        }

        1
    }

    fn section9(&mut self, mut p: i64, mut len: i64) -> i32 {
        p += SECHDRLEN;
        len -= SECHDRLEN; // move to data area

        if len <= 0 {
            if self.vflag != 0 {
                cprintf!(b" Error: section 9 contains no data\n");
            }
            return 0;
        }

        // FIXME: more to do here
        if self.vflag != 0 {
            let mut o = b"  Data:\n   ".to_vec();
            while len > 0 {
                len -= 1;
                let c = self.b(p);
                if isprint_c(c) {
                    o.push(c as u8);
                } else {
                    cstd::sprintf_into(&mut o, b"\\%03o", &[cstd::ToArg::to_arg(&c)]);
                }
                p += 1;
            }
            o.push(b'\n');
            cstd::out().write(&o);
        }

        1
    }

    fn section10(&mut self, mut p: i64, mut len: i64) -> i32 {
        p += SECHDRLEN;
        len -= SECHDRLEN; // move to data area

        if len <= 0 {
            if self.vflag != 0 {
                cprintf!(b" Error: section 10 contains no data\n");
            }
            return 0;
        }

        // Section 10 data area begins with a 4-byte header. The first 2
        // bytes specify the number of leads for which measurements are
        // stored.
        self.nsecleads = self.get16(p) as i32;
        // FIXME: the draft standard doesn't say what the next 2 bytes are --
        // so they are ignored here.

        // Fill the array of structures.
        let mut ecgmeas = vec![[0i16; NMEAS]; self.nsecleads as usize];
        p += 4;
        for m in &mut ecgmeas {
            for (k, f) in m.iter_mut().enumerate() {
                *f = self.get16(p + 2 * k as i64) as i16;
            }
            p += m[M_VLEN] as i64 + 4;
        }
        self.ecgmeas = ecgmeas;

        if self.vflag != 0 {
            cprintf!(b" Results for %d leads\n", self.nsecleads);
            let m = self.precgmeas();
            cstd::out().write(&m);
        }
        1
    }

    fn section11(&mut self, mut _p: i64, mut len: i64) -> i32 {
        _p += SECHDRLEN;
        len -= SECHDRLEN; // move to data area

        if len <= 0 {
            if self.vflag != 0 {
                cprintf!(b" Error: section 11 contains no data\n");
            }
            return 0;
        }

        // ** more to do here **
        1
    }
}

fn help(pname: &[u8]) {
    ceprintf!(b"usage: %s -o RECORD [OPTIONS ...] <SCPFILE\n", pname);
    ceprintf!(
        b"  where RECORD is the name (<= 11 alphanumeric characters) of this case,\n  SCPFILE is the name of a file containing ECG data in SCP-ECG format, and\n  OPTIONS may include:\n   -a    anonymize and copy stdin to stdout (suppresses other output).\n   -f    force parsing of a file with CRC errors.\n   -h    print brief help\n   -l    low-pass filter (smooth) the output waveforms.\n   -v    option to print a (very) detailed analysis of SCPFILE.\n   -w    produce a WFDB-format record\n   -z    zero-mean the input\n\n  Additional options for debugging only:\n   -b    show baseline (residuals);  suppress templates\n   -s N  shift templates by N samples before adding\n   -S N  skip parsing of section N\n   -t    show templates; suppress baseline\n   -x    show hex dumps (implies -v)\n"
    );
}

/// C `atoi` (`strtol` truncated to a 32-bit int).
fn c_atoi(s: &[u8]) -> i32 {
    cstd::strtoll(s, 10).0 as i32
}

fn main() {
    let mut argv = cstd::args();
    wfdbx::wfdbx_legacy_args(&mut argv); // WFDB-x: --legacy (original behavior)
    let argc = argv.len();
    let pname = cstd::prog_name(&argv[0]).to_vec();
    let mut s = Scp::new(pname.clone());

    let mut i = 1;
    while i < argc {
        let a = cstd::cstr(&argv[i]);
        if a.first() == Some(&b'-') {
            match a.get(1).copied().unwrap_or(0) {
                b'a' => {
                    // write an anonymized version of stdin to stdout
                    s.aflag = 1;
                    s.xflag = 0;
                    s.vflag = 0; // incompatible with -v and -x
                }
                b'b' => {
                    // show baseline (residuals);  suppress templates
                    s.bflag = 1;
                    s.tflag = 0;
                }
                b'f' => s.fflag = 1, // force parsing even if CRC error(s) found
                b'h' => {
                    // print a usage summary
                    help(&pname);
                    cstd::exit(1);
                }
                b'l' => s.lflag = 1, // low-pass filter the output waveforms
                b'o' => {
                    // record name follows
                    i += 1;
                    if i < argc && cstd::cstr(&argv[i]).len() <= 11 {
                        s.recname = cstd::cstr(&argv[i]).to_vec();
                    } else {
                        ceprintf!(
                            b"%s: a record name of 11 or fewer alphanumericcharacters must\n follow -o\n",
                            pname
                        );
                        cstd::exit(1);
                    }
                }
                b's' => {
                    // shift templates by N samples
                    i += 1;
                    if i < argc {
                        s.shift = c_atoi(&argv[i]);
                    } else {
                        ceprintf!(
                            b"%s: number of samples to shift templates must follow -s\n",
                            pname
                        );
                        cstd::exit(1);
                    }
                }
                b'S' => {
                    // skip a section (may be repeated)
                    i += 1;
                    if i < argc {
                        if argv[i].first() == Some(&b'-') {
                            s.skip = [1; 12];
                        } else {
                            let index = c_atoi(&argv[i]);
                            if (0..=11).contains(&index) {
                                s.skip[index as usize] = 1 - s.skip[index as usize];
                            }
                        }
                    } else {
                        ceprintf!(
                            b"%s: number of section to skip, or '-', must follow -S\n",
                            pname
                        );
                        cstd::exit(1);
                    }
                }
                b't' => {
                    // show templates;  suppress baseline
                    s.tflag = 1;
                    s.bflag = 0;
                }
                b'v' => {
                    // print a detailed analysis of the record contents
                    s.vflag += 1;
                    s.aflag = 0; // incompatible with -a
                }
                b'w' => s.wflag += 1, // create a WFDB-format record
                b'x' => {
                    // print a hex dump (implies -v)
                    s.xflag = 1;
                    s.vflag = 1;
                    s.aflag = 0;
                }
                b'z' => s.zflag += 1, // suppress final transients and zero-mean the ECGs
                _ => {
                    ceprintf!(b"%s: unrecognized option '%s'\n", pname, a);
                    help(&pname);
                    cstd::exit(1);
                }
            }
        } else {
            ceprintf!(b"%s: unrecognized argument '%s'\n", pname, a);
            help(&pname);
            cstd::exit(1);
        }
        i += 1;
    }

    let mut input = WfdbFile::stdin();
    let mut header = [0u8; RECHDRLEN];
    let mut bytesread = input.fread(&mut header, 1, RECHDRLEN) as u64;
    if bytesread != RECHDRLEN as u64 {
        ceprintf!(b"%s: input too short (only %llu bytes)\n", pname, bytesread);
        cstd::exit(1);
    }
    s.data = header.to_vec();
    let mut crc = s.get16(0) as u16;
    let length = s.get32(CRCLEN);
    if s.vflag != 0 {
        cprintf!(
            b"CRC = %d, expected length = %lld bytes\n",
            crc,
            length as i64
        );
    }
    if length > i64::MAX as u64 {
        ceprintf!(
            b"%s: insufficient memory (%lld bytes needed)\n",
            pname,
            length as i64
        );
        cstd::exit(2);
    }
    let mut buf = vec![0u8; 65536];
    while bytesread < length {
        let want = (length - bytesread).min(buf.len() as u64) as usize;
        let n = input.fread(&mut buf[..want], 1, want);
        if n == 0 {
            break;
        }
        s.data.extend_from_slice(&buf[..n]);
        bytesread += n as u64;
    }
    if bytesread < length {
        let d = length - bytesread;
        ceprintf!(
            b"%s: input too short (%llu byte%s missing)\n",
            pname,
            d,
            if d == 1 { &b""[..] } else { &b"s"[..] }
        );
        cstd::exit(3);
    }
    input.close();
    if s.vflag != 0 {
        cprintf!(b"Record length: %lld bytes\n", length as i64);
    }
    s.crcok(CRCLEN, length as i64 - CRCLEN, crc, b"Top-level CRC");

    // Now check the sections.
    let mut p = RECHDRLEN as i64; // skip the record header -- p points to section 0

    while (p as u64) < length {
        // true if there is at least 1 more section
        crc = s.get16(p) as u16;
        let sec_id = s.get16(p + SEC_ID);
        let mut sec_len = s.get32(p + SEC_LEN);
        let v = s.vflag != 0;
        if v {
            cprintf!(
                b"\nSection %d length: %lld bytes\n",
                sec_id as i32,
                sec_len as i64
            );
        }
        if sec_len < SECMINLEN {
            if v {
                cprintf!(
                    b" Warning: section length too short (must be at least 8 bytes)\n  Remaining data (%llu bytes) following short section will not be read\n",
                    length.wrapping_sub((p + SECMINLEN as i64) as u64)
                );
            }
            sec_len = SECMINLEN;
        }
        if sec_len > length.wrapping_sub(p as u64) {
            if v {
                cprintf!(b" Warning: section length exceeds amount of remaining data\n  This section will not be parsed\n");
            }
            break;
        }
        let desc = cformat!(b" Section %d CRC", sec_id as i32);
        s.crcok(p + CRCLEN, sec_len as i64 - CRCLEN, crc, &desc);
        if v {
            cprintf!(
                b" Section version number: %d\n",
                s.b(p + SEC_VERSION) as i32
            );
            cprintf!(
                b" Protocol version number: %d\n",
                s.b(p + SEC_PROTOCOL) as i32
            );
            cprintf!(b" Contents: ");
        }
        let sl = sec_len as i64;
        const CONTENTS: [&[u8]; 12] = [
            b" Pointers to data areas in the record\n",
            b" Header information - Patient data/ECG acquisition data\n",
            b" Huffman tables used in encoding of ECG data\n",
            b" ECG lead definition\n",
            b" QRS locations\n",
            b" Encoded reference beat data\n",
            b" Residual signal after reference beat subtraction (if reference beats\n  are stored);  otherwise, encoded rhythm data\n",
            b" Global measurements\n",
            b" Textual diagnosis from the interpretive device\n",
            b" Manufacturer specific diagnostic and overreading data\n",
            b" Lead measurement results\n",
            b" Universal statement codes resulting from the interpretation\n",
        ];
        if (sec_id as usize) < CONTENTS.len() {
            let id = sec_id as usize;
            if v {
                cprintf!(b"%s", CONTENTS[id]);
            }
            if s.skip[id] != 0 {
                cprintf!(b"  [skipped]\n");
            } else {
                match id {
                    0 => s.section0(p, sl),
                    1 => s.section1(p, sl),
                    2 => s.section2(p, sl),
                    3 => s.section3(p, sl),
                    4 => s.section4(p, sl),
                    5 => s.section5(p, sl),
                    6 => s.section6(p, sl),
                    7 => s.section7(p, sl),
                    8 => s.section8(p, sl),
                    9 => s.section9(p, sl),
                    10 => s.section10(p, sl),
                    _ => s.section11(p, sl),
                };
            }
        } else if v {
            cprintf!(
                b" Manufacturer-defined (non-standard) section %d\n",
                sec_id as i32
            );
        }
        p += sl;
    }

    // Low-pass filter the residuals.
    for i in 0..s.nleads.max(0) as usize {
        let n = s.nsampk(i as i64);
        let Some(inp) = s.ecg.get(i).and_then(|x| x.as_ref()) else {
            continue;
        };
        let Some(mut out) = newsig(n) else {
            ceprintf!(b"Insufficient memory for filtering\n");
            break;
        };
        if s.tflag == 0 {
            // true unless -t debugging option was given
            out[0] = inp[0];
            let mut jj: u64 = 1;
            while jj + 1 < n {
                let j = jj as usize;
                let v = inp[j - 1] as i32 + inp[j] as i32 + inp[j + 1] as i32;
                out[j] = if v > 0 {
                    ((v + 2) / 3) as i16
                } else if v < 0 {
                    ((v - 2) / 3) as i16
                } else {
                    0
                };
                jj += 1;
            }
            out[jj as usize] = inp[jj as usize];
            for k in 0..s.nqrs.max(0) as usize {
                if let Some(Some(z)) = s.subz.get(k) {
                    if z.ztype == 0 {
                        // restore unfiltered samples within protected zones
                        // and adjacent samples on either end of protected
                        // zones
                        let j0 = (z.t0 - 1).max(0);
                        let j1 = (z.t2 + 2).min(out.len() as i64);
                        let mut jx = j0;
                        while jx < j1 {
                            out[jx as usize] = inp[jx as usize];
                            jx += 1;
                        }
                    }
                }
            }
        }
        s.ecg[i] = Some(out);
    }

    // Add the reference beats back into the residuals to obtain the raw ECG
    if s.bflag == 0 {
        // true unless -b debugging option was given
        for k in 0..s.nqrs.max(0) as usize {
            let Some(&Some(z)) = s.subz.get(k) else {
                continue;
            };
            if z.ztype != 0 {
                continue;
            }
            for i in 0..s.nleads.max(0) as usize {
                let m = (s.fc_m as i64 - z.t1 + z.t0 - 1) as i32;
                if z.t2 - z.t0 + 1 > s.rblen || m < 0 {
                    ceprintf!(b"error: subtraction zone is larger than template\n");
                    cstd::exit(1);
                }
                let shift = s.shift as i64;
                let Some(Some(rf)) = s.refbeat.get(i) else {
                    continue;
                };
                let Some(Some(sig)) = s.ecg.get_mut(i) else {
                    continue;
                };
                let mut jlo = z.t0 - 1 + shift;
                let jhi = z.t2 - 1 + shift;
                let mut mm = m as i64;
                if jlo < 0 {
                    // skip samples before the start of the signal
                    mm += -jlo;
                    jlo = 0;
                }
                let mut jx = jlo;
                while jx <= jhi {
                    if jx as u64 >= sig.len() as u64 || mm as u64 >= rf.len() as u64 {
                        break;
                    }
                    sig[jx as usize] = sig[jx as usize].wrapping_add(rf[mm as usize]);
                    jx += 1;
                    mm += 1;
                }
            }
        }
    }

    // WFDB-x: signals that could not be allocated (undefined behavior in C)
    // are read as zeros, and so are samples beyond the end of a signal
    // shorter than lead 0.
    let mut n0: u64 = 0;
    if s.have_ecg {
        n0 = s.nsamp.first().copied().unwrap_or(0);
        n0 = if n0 <= MAXALLOC { n0 } else { 0 };
        s.nout = n0;
        for sig in &mut s.ecg {
            if sig.is_none() {
                *sig = newsig(0);
            }
            let sg = sig.as_mut().unwrap();
            if (sg.len() as u64) < n0 {
                sg.resize(n0 as usize, 0);
            }
        }
    }
    let vflag = s.vflag != 0;

    // Now calculate the missing leads. Normally the input contains only two
    // of the three limb leads (I, II, and III) and the missing one (usually
    // III) must be calculated from the other two, using the relationship:
    //          lead III = lead II - lead I
    if s.lead_iii < 0 {
        // we need to calculate lead III
        if s.lead_i >= 0 && s.lead_ii >= 0 {
            if vflag {
                cprintf!(b" Calculating lead III\n");
            }
            s.lead_iii = s.nleads as i16;
            s.nleads += 1;
            let (li, lii, liii) = (s.lead_i as i64, s.lead_ii as i64, s.lead_iii as i64);
            s.nsamp[liii as usize] = s.nsampk(li).min(s.nsampk(lii));
            let l1 = s.srcsig(li);
            let l2 = s.srcsig(lii);
            let ns = s.nsamp[liii as usize];
            if let Some(l3) = s.sigp_mut(liii) {
                let ne = ns
                    .min(l1.len() as u64)
                    .min(l2.len() as u64)
                    .min(l3.len() as u64) as usize;
                for jx in 0..ne {
                    l3[jx] = l2[jx].wrapping_sub(l1[jx]);
                }
            }
        } else if s.lead_i < 0 {
            if s.lead_ii < 0 {
                ceprintf!(b"Leads I, II, and III are missing\n");
            } else {
                ceprintf!(b"Leads I and III are missing\n");
            }
        } else {
            ceprintf!(b"Leads II and III are missing\n");
        }
    } else if s.lead_ii < 0 {
        // we need to calculate lead II
        if s.lead_i >= 0 {
            if vflag {
                cprintf!(b" Calculating lead II\n");
            }
            s.lead_ii = s.nleads as i16;
            s.nleads += 1;
            let (li, lii, liii) = (s.lead_i as i64, s.lead_ii as i64, s.lead_iii as i64);
            s.nsamp[lii as usize] = s.nsampk(li).min(s.nsampk(liii));
            let l1 = s.srcsig(li);
            let l3 = s.srcsig(liii);
            if let Some(l2) = s.sigp_mut(lii) {
                for jx in 0..n0 as usize {
                    l2[jx] = l1[jx].wrapping_add(l3[jx]);
                }
            }
        } else {
            ceprintf!(b"Leads I and II are missing\n");
        }
    } else if s.lead_i < 0 {
        // we need to calculate lead I
        if vflag {
            cprintf!(b" Calculating lead I\n");
        }
        s.lead_i = s.nleads as i16;
        s.nleads += 1;
        let (li, lii, liii) = (s.lead_i as i64, s.lead_ii as i64, s.lead_iii as i64);
        s.nsamp[li as usize] = s.nsampk(lii).min(s.nsampk(liii));
        let l2 = s.srcsig(lii);
        let l3 = s.srcsig(liii);
        if let Some(l1) = s.sigp_mut(li) {
            for jx in 0..n0 as usize {
                l1[jx] = l2[jx].wrapping_sub(l3[jx]);
            }
        }
    }

    // We need both lead I and lead II to derive aVR.
    if s.avr < 0 {
        if s.lead_i >= 0 && s.lead_ii >= 0 {
            if vflag {
                cprintf!(b" Calculating lead aVR\n");
            }
            s.avr = s.nleads as i16;
            s.nleads += 1;
            let (li, lii, k) = (s.lead_i as i64, s.lead_ii as i64, s.avr as i64);
            s.nsamp[k as usize] = s.nsampk(li).min(s.nsampk(lii));
            let l1 = s.srcsig(li);
            let l2 = s.srcsig(lii);
            if let Some(out) = s.sigp_mut(k) {
                for jx in 0..n0 as usize {
                    out[jx] = (-cdiv2(l1[jx] as i32 + l2[jx] as i32)) as i16;
                }
            }
        } else {
            ceprintf!(b"Lead aVR cannot be derived\n");
        }
    }

    // We need both lead II and lead III to derive aVL.
    if s.avl < 0 {
        if s.lead_ii >= 0 && s.lead_iii >= 0 {
            if vflag {
                cprintf!(b" Calculating lead aVL\n");
            }
            s.avl = s.nleads as i16;
            s.nleads += 1;
            let (lii, liii, k) = (s.lead_ii as i64, s.lead_iii as i64, s.avl as i64);
            s.nsamp[k as usize] = s.nsampk(lii).min(s.nsampk(liii));
            let l2 = s.srcsig(lii);
            let l3 = s.srcsig(liii);
            if let Some(out) = s.sigp_mut(k) {
                for jx in 0..n0 as usize {
                    out[jx] = (cdiv2(l2[jx] as i32) - l3[jx] as i32) as i16;
                }
            }
        } else {
            ceprintf!(b"Lead aVL cannot be derived\n");
        }
    }

    // We need both lead I and lead III to derive aVF.
    if s.avf < 0 {
        if s.lead_i >= 0 && s.lead_ii >= 0 {
            if vflag {
                cprintf!(b" Calculating lead aVF\n");
            }
            s.avf = s.nleads as i16;
            s.nleads += 1;
            let (li, liii, k) = (s.lead_i as i64, s.lead_iii as i64, s.avf as i64);
            s.nsamp[k as usize] = s.nsampk(li).min(s.nsampk(liii));
            let l1 = s.srcsig(li);
            let l3 = s.srcsig(liii);
            if let Some(out) = s.sigp_mut(k) {
                for jx in 0..n0 as usize {
                    out[jx] = (cdiv2(l1[jx] as i32) + l3[jx] as i32) as i16;
                }
            }
        } else {
            ceprintf!(b"Lead aVF cannot be derived\n");
        }
    }

    if s.v1 < 0 {
        ceprintf!(b"Lead V1 is missing\n");
    }
    if s.v2 < 0 {
        ceprintf!(b"Lead V2 is missing\n");
    }
    if s.v3 < 0 {
        ceprintf!(b"Lead V3 is missing\n");
    }
    if s.v4 < 0 {
        ceprintf!(b"Lead V4 is missing\n");
    }
    if s.v5 < 0 {
        ceprintf!(b"Lead V5 is missing\n");
    }
    if s.v6 < 0 {
        ceprintf!(b"Lead V6 is missing\n");
    }

    if s.nleads > 0 && s.order().iter().any(|&l| l < 0) {
        // Use an array of zero samples for the missing lead(s).
        let nl = s.nleads as usize;
        if s.ecg[nl].is_none() {
            s.ecg[nl] = newsig(0);
        }
        let nl = nl as i16;
        for l in [
            &mut s.lead_i,
            &mut s.lead_ii,
            &mut s.lead_iii,
            &mut s.avr,
            &mut s.avf,
            &mut s.avl,
            &mut s.v1,
            &mut s.v2,
            &mut s.v3,
            &mut s.v4,
            &mut s.v5,
            &mut s.v6,
        ] {
            if *l < 0 {
                *l = nl;
            }
        }
    }

    if s.aflag != 0 {
        // Recalculate the top-level CRC.
        let crc = s.getcrc(CRCLEN, bytesread as i64 - CRCLEN);
        s.put16(crc as u32, 0);
        cstd::out().write(&s.data[..bytesread as usize]);
    } else if s.nleads > 0 {
        s.write_output();
    }

    cstd::exit(0);
}
