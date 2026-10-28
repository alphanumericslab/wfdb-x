//! xform: sampling frequency, amplitude, and format conversion for WFDB
//! records (port of `app/xform.c`).
//!
//! Dither uses an exact emulation of glibc's `rand()` (after `srand(0)`),
//! so that the output is the same on all platforms. Conversions of
//! out-of-range doubles to int yield `INT_MIN` (as on x86), and int
//! additions and subtractions wrap around.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Rust translation of app/xform.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: no built-in sampling frequency, gain, ADC
// resolution or units: the input record must give its sampling frequency, and
// an output frequency of 0 is refused; rescaling an uncalibrated signal to a
// given gain, and rescaling by ADC resolution when a resolution is
// unspecified, are refused; an ADC resolution is offered only if it comes from
// the input (or the previous output signal) and suits the output format;
// unspecified units are shown as "nd" (the original assumed 250 Hz, 200
// adu/mV, a resolution based on the format, and millivolts); when an output
// signal file would be one of the input files, the message says so; --legacy,
// as the first argument, restores the original behavior. Each change is marked
// "WFDB-x:" in the code; docs/DIVERGENCES.md gives the reasons.
//
// Original C program: app/xform.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1983-2010 George B. Moody; revised 2017-2020 by
//   Benjamin Moody.
// Rust translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

use wfdbx::cstd::{self, d2i, d2l, GlibcRand, RAND_MAX};
use wfdbx::{
    ceprintf, cformat, csscanf, Anninfo, Annotation, Siginfo, WfdbFile, NOTE, NOTQRS, NULL,
    WFDB_DEFFREQ, WFDB_DEFGAIN, WFDB_DEFRES, WFDB_FMT_LIST, WFDB_HIGHRES, WFDB_INVALID_SAMPLE,
    WFDB_LOWRES, WFDB_MAXDSL, WFDB_MAXRNL, WFDB_MAXUSL, WFDB_NFMTS, WFDB_READ, WFDB_WRITE,
};

const HELP_STRINGS: &[&str] = &[
    "usage: %s -i IREC [OPTIONS ...]\n",
    "where IREC is the name of the record to be converted, and OPTIONS may",
    " include any of:",
    " -a ANNOTATOR [ANNOTATOR ...]  copy annotations for the specified ANNOTATOR",
    "              from IREC;  two or more ANNOTATORs may follow -a",
    " -c          clip output (default: wrap around if out-of-range)",
    " -d          add dither to the input if changing sampling frequency or gain",
    " -f TIME     begin at specified time",
    " -h          print this usage summary",
    " -H          open the input record in `high resolution' mode",
    " -M          process multifrequency record without changing frequencies",
    " -n NREC     create a header file, using record name NREC and signal",
    "              descriptions from IREC",
    " -N NREC     as for -n, but copy signal descriptions from OREC",
    " -o OREC     produce output signal file(s) as specified by the header file",
    "              for record OREC",
    " -s SIGNAL [SIGNAL ...]  write only the specified signal(s)",
    " -S SCRIPT   take answers to prompts from SCRIPT (a text file)",
    " -t TIME     stop at specified time",
    " -u          adjust annotation times if needed to make them unique",
    "Unless you use `-o' to specify an *existing* header that describes the",
    "desired signal files, you will be asked for output specifications.  Use",
    "`-n' to name the record to be created.  Use `-s' to select a subset of the",
    "input signals, or to re-order them in the output file;  arguments that",
    "follow `-s' are *input* signal numbers (0,1,2,...) or names.",
];

fn help(pname: &[u8]) {
    ceprintf!(HELP_STRINGS[0].as_bytes(), pname);
    for s in &HELP_STRINGS[1..] {
        ceprintf!(b"%s\n", *s);
    }
}

/// The dither generator: triangular PDF in (-1,1).
fn dither(rng: &mut GlibcRand) -> f64 {
    let a = rng.rand() as f64;
    let b = rng.rand() as f64;
    (a + b) / RAND_MAX as f64 - 1.0
}

/// C `fgets` on the prompt input, with xform's handling of end of file.
fn script_fgets(
    ttyin: &mut WfdbFile,
    length: usize,
    pname: &[u8],
    script: Option<&[u8]>,
) -> Vec<u8> {
    let mut buffer = Vec::new();
    if !ttyin.fgets(&mut buffer, length) {
        if let Some(script) = script {
            ceprintf!(b"\n%s: unexpected end of file in %s\n", pname, script);
            cstd::exit(1);
        } else {
            buffer = b"\n".to_vec();
        }
    }
    // (The C program treats the buffer as a C string.)
    let n = cstd::cstr(&buffer).len();
    buffer.truncate(n);
    buffer
}

/// Calculate the greatest common divisor of x and y.  This function uses
/// Euclid's algorithm, modified so that an exact answer is not required if
/// the (possibly non-integral) arguments do not have a common divisor that
/// can be represented exactly.
fn gcd(mut x: f64, mut y: f64) -> f64 {
    let tol = if x > y { 0.001 * y } else { 0.001 * x }; // relative tolerance 0.1%
    loop {
        if x > y && x - y > tol {
            x -= y;
        } else if y > x && y - x > tol {
            y -= x;
        } else {
            return x;
        }
    }
}

/// Round as xform does.
fn round(vd: f64) -> i32 {
    if vd >= 0.0 {
        d2i(vd + 0.5)
    } else {
        d2i(vd - 0.5)
    }
}

/// Report (and clip, or widen the range for) an out-of-range sample.
fn check(vout: &mut i32, i: usize, vmax: &mut [i32], vmin: &mut [i32], clip: bool) {
    if *vout > vmax[i] {
        ceprintf!(b"v[%d] = %d (out of range)\n", i as i32, *vout);
        if clip {
            *vout = vmax[i];
        } else {
            vmax[i] = *vout;
        }
    } else if *vout < vmin[i] {
        ceprintf!(b"v[%d] = %d (out of range)\n", i as i32, *vout);
        if clip {
            *vout = vmin[i];
        } else {
            vmin[i] = *vout;
        }
    }
}

/// Progress indicator: a dot per minute of input, a newline per hour.
fn tick(nsm: &mut i64, spm: i64, nminutes: &mut i32) {
    *nsm += 1;
    if *nsm >= spm {
        *nsm = 0;
        ceprintf!(b".");
        *nminutes += 1;
        if *nminutes >= 60 {
            *nminutes = 0;
            ceprintf!(b"\n");
        }
    }
}

/// The largest ADC resolution (bits) of a storage format, and the resolution
/// the C program assumed for it (legacy mode; for historical compatibility,
/// WFDB_DEFRES for 16-bit formats, although 16 would make more sense).
fn format_res(fmt: i32) -> (i32, i32) {
    match fmt {
        80 | 508 => (8, 8),
        212 => (12, 12),
        310 => (10, 10),
        24 | 524 => (24, 24),
        32 => (32, 32),
        _ => (16, WFDB_DEFRES), // 16, 61, 160, 516, and others
    }
}

fn main() {
    let mut argv = cstd::args();
    let legacy = wfdbx::wfdbx_legacy_args(&mut argv) != 0; // WFDB-x: --legacy
    let argc = argv.len();
    let pname = cstd::prog_name(&argv[0]).to_vec();
    let pname = &pname[..];
    let mut script: Option<&[u8]> = None;
    let mut rng = GlibcRand::new(1);
    let mut irec: Option<&[u8]> = None;
    let mut orec: Option<&[u8]> = None;
    let mut nrec: Option<Vec<u8>> = None;
    let mut startp: &[u8] = b"0:0";
    let mut ofreq: f64;
    let (mut clip, mut dflag, mut hflag, mut mflag) = (false, false, false, false);
    let (mut sflag, mut uflag) = (false, false);
    let mut use_irec_desc = true;
    let mut fflag = false;
    let mut gflag = false;
    let mut reopen = false;
    let mut nminutes = 0;
    let mut nosig: i32 = 0;
    let mut siglist: Vec<i32> = Vec::new();
    let (mut from, mut it, mut ot, mut to): (i64, i64, i64, i64) = (0, 0, 0, 0);
    let mut nsamp: i64 = -1;
    let mut nsm: i64 = 0;
    let mut ainames: Vec<Vec<u8>> = Vec::new();
    let mut dfin: Vec<Siginfo> = Vec::new();
    let mut dfout: Vec<Siginfo> = Vec::new();

    // Interpret the command-line arguments.
    let starts_dash = |i: usize| argv[i].first() == Some(&b'-');
    let mut i = 1;
    while i < argc {
        let a = &argv[i];
        if a.first() == Some(&b'-') {
            match a.get(1).copied().unwrap_or(0) {
                b'a' => {
                    // annotator(s)
                    // Count the number of annotators.  Accept the next
                    // argument unconditionally as an annotator name; accept
                    // additional arguments until we find one beginning with
                    // `-', or the end of the argument list.
                    let mut j = 0;
                    loop {
                        i += 1;
                        if !(i < argc && (j == 0 || !starts_dash(i))) {
                            break;
                        }
                        j += 1;
                    }
                    if j == 0 {
                        ceprintf!(b"%s: annotator(s) must follow -a\n", pname);
                        cstd::exit(1);
                    }
                    i -= j;
                    j = 0;
                    while i < argc && (j == 0 || !starts_dash(i)) {
                        ainames.push(argv[i].clone());
                        i += 1;
                        j += 1;
                    }
                    i -= 1;
                }
                b'c' => clip = true, // clip (limit) output
                b'd' => {
                    dflag = true;
                    rng.srand(0); // seed for dither RNG
                }
                b'f' => {
                    // starting time
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: time must follow -f\n", pname);
                        cstd::exit(1);
                    }
                    from = i as i64;
                }
                b'h' => {
                    // help requested
                    help(pname);
                    cstd::exit(0);
                }
                b'H' => hflag = true, // open the input record in high resolution mode
                b'i' => {
                    // input record name follows
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: input record name must follow -i\n", pname);
                        cstd::exit(1);
                    }
                    irec = Some(&argv[i]);
                }
                b'M' => mflag = true, // multifrequency mode (no frequency changes)
                b'n' => {
                    // new record name follows
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: new record name must follow -n\n", pname);
                        cstd::exit(1);
                    }
                    nrec = Some(argv[i].clone());
                }
                b'N' => {
                    // new record name follows;  use signal descriptions from
                    // output record header file in new header file
                    use_irec_desc = false;
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: new record name must follow -N\n", pname);
                        cstd::exit(1);
                    }
                    nrec = Some(argv[i].clone());
                }
                b'o' => {
                    // output record name follows
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: output record name must follow -o\n", pname);
                        cstd::exit(1);
                    }
                    orec = Some(&argv[i]);
                }
                b's' => {
                    // signal list follows
                    sflag = true;
                    // count the number of output signals
                    let mut j = 0;
                    loop {
                        i += 1;
                        if !(i < argc && !starts_dash(i)) {
                            break;
                        }
                        j += 1;
                    }
                    if j == 0 {
                        ceprintf!(b"%s: signal list must follow -s\n", pname);
                        cstd::exit(1);
                    }
                    // fill the signal list (with argument indices for now)
                    i -= j;
                    while i < argc && !starts_dash(i) {
                        siglist.push(i as i32);
                        nosig += 1;
                        i += 1;
                    }
                    i -= 1;
                }
                b'S' => {
                    // script name follows
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: script name must follow -S\n", pname);
                        cstd::exit(1);
                    }
                    script = Some(&argv[i]);
                }
                b't' => {
                    // end time
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: time must follow -t\n", pname);
                        cstd::exit(1);
                    }
                    to = i as i64;
                }
                b'u' => uflag = true, // make annotation times unique
                _ => {
                    ceprintf!(b"%s: unrecognized option %s\n", pname, a);
                    cstd::exit(1);
                }
            }
        } else {
            ceprintf!(b"%s: unrecognized argument %s\n", pname, a);
            cstd::exit(1);
        }
        i += 1;
    }

    // Check that an input record was specified.
    let irec = match irec {
        Some(r) => r,
        None => {
            help(pname);
            cstd::exit(1);
        }
    };

    // Check that nrec and orec differ if both were specified.
    if let (Some(n), Some(o)) = (&nrec, orec) {
        if cstd::cstr(n) == cstd::cstr(o) {
            ceprintf!(
                b"%s: arguments of -n (or -N) and -o cannot be identical\n",
                pname
            );
            cstd::exit(1);
        }
    }

    // Determine the number of input signals.  If isigopen returns a negative
    // value, quit (isigopen will have emitted an error message).
    let nisig = wfdbx::isigopen(irec, &mut [], 0);
    if nisig < 0 {
        cstd::exit(2);
    }

    // If the input record contains no signals, we won't write any -- but we
    // might still read and write annotations.
    if nisig == 0 {
        nosig = 0;
    }
    // Otherwise, prepare to read and write signals.
    else {
        // Allocate storage for variables related to the input signals.
        dfin = vec![Siginfo::default(); nisig as usize];

        // Open the input signals.
        if wfdbx::isigopen(irec, &mut dfin, nisig) != nisig {
            cstd::exit(2);
        }

        // If a signal list was specified using -s, check that the specified
        // signal numbers or names are legal.
        if sflag {
            let mut i = 0;
            while i < nosig as usize && nosig > 0 {
                let s = &argv[siglist[i] as usize];
                siglist[i] = wfdbx::findsig(s);
                if siglist[i] < 0 {
                    ceprintf!(
                        b"%s: warning: record %s doesn't have a signal '%s'\n",
                        pname,
                        irec,
                        s
                    );
                    // Delete illegal signal numbers from the list.
                    siglist.remove(i);
                    nosig -= 1;
                } else {
                    i += 1;
                }
            }
            // If the signal list contained no valid signal numbers, treat
            // this situation as if no signal list was specified.
            if nosig == 0 {
                sflag = false;
            }
        }

        // If the signal list was not specified using -s, initialize it now.
        if !sflag {
            nosig = nisig;
            siglist = (0..nosig).collect();
        }

        // Allocate storage for variables related to the output signals.
        dfout = vec![Siginfo::default(); nosig as usize];
    }
    let nosig_alloc = nosig.max(0) as usize;
    let mut gain = vec![0.0f64; nosig_alloc];
    let mut deltav = vec![0i32; nosig_alloc];
    let mut msiglist = vec![0i32; nosig_alloc];
    let mut v = vec![0i32; nosig_alloc];
    let mut vmax = vec![0i32; nosig_alloc];
    let mut vmin = vec![0i32; nosig_alloc];
    let mut vv = vec![0i32; nosig_alloc];

    // Determine the input sampling frequency.
    if mflag {
        wfdbx::setgvmode(WFDB_LOWRES);
    } else if hflag {
        wfdbx::setgvmode(WFDB_HIGHRES);
    }
    let ifreq = wfdbx::sampfreq(NULL);
    // WFDB-x: no default sampling frequency (the C program assumed 250 Hz if
    // the input header did not specify one, as legacy mode does).
    if ifreq <= 0.0 && !legacy {
        ceprintf!(
            b"%s: sampling frequency of record %s is not specified\n",
            pname,
            irec
        );
        wfdbx::wfdbquit();
        cstd::exit(2);
    }
    let mut spf = wfdbx::getspf();

    let (iframelen, oframelen) = if mflag {
        (
            dfin.iter().map(|s| s.spf).sum::<i32>(),
            siglist[..nosig_alloc]
                .iter()
                .map(|&k| dfin[k as usize].spf)
                .sum::<i32>(),
        )
    } else {
        (nisig, nosig)
    };
    let mut vin = vec![0i32; iframelen.max(1) as usize];
    let mut vout = vec![0i32; oframelen.max(1) as usize];

    if let Some(orec) = orec {
        // an output record was specified
        // If a new record name was specified, check that it can be created.
        if let Some(n) = &nrec {
            if wfdbx::newheader(n) < 0 {
                cstd::exit(2);
            }
        }

        // Determine the output sampling frequency.
        ofreq = wfdbx::sampfreq(orec);
        if ofreq == 0.0 && !legacy {
            // WFDB-x: no default sampling frequency
            ceprintf!(
                b"%s: sampling frequency of record %s is not specified\n",
                pname,
                orec
            );
            wfdbx::wfdbquit();
            cstd::exit(2);
        }
        let _ = wfdbx::setsampfreq(ifreq / spf as f64);

        if ifreq != ofreq && mflag {
            ceprintf!(
                b"%s: -M option may not be used if sampling frequency is to be changed\n",
                pname
            );
            wfdbx::wfdbquit();
            cstd::exit(1);
        }
    }
    // If no output record was specified, get signal specs interactively.
    else {
        let mut format = 0;
        let mut answer: Vec<u8>;
        let tty: &[u8] = script.unwrap_or(b"/dev/tty");
        let mut ttyin = WfdbFile::fopen(tty, b"r").unwrap_or_else(WfdbFile::stdin);
        let mut sfgets = |len: usize| script_fgets(&mut ttyin, len, pname, script);
        const ANSLEN: usize = 32; // size of C's answer and directory buffers
        if nrec.is_none() {
            let mut record;
            loop {
                ceprintf!(
                    b"Choose a name for the output record (up to %d characters): ",
                    WFDB_MAXRNL as i32
                );
                record = sfgets(WFDB_MAXRNL + 2);
                record.pop();
                if !record.is_empty() && wfdbx::newheader(&record) >= 0 {
                    break;
                }
            }
            nrec = Some(record);
        }
        if !sflag {
            loop {
                nosig = nisig;
                ceprintf!(
                    b"Number of signals to be written (1-%d) [%d]: ",
                    nisig,
                    nosig
                );
                answer = sfgets(ANSLEN);
                let _ = csscanf!(&answer, b"%d", &mut nosig);
                if nosig == 0 {
                    ceprintf!(b"No signals will be written.  Are you sure? [n]: ");
                    answer = sfgets(ANSLEN);
                    if answer.first() != Some(&b'y') && answer.first() != Some(&b'Y') {
                        nosig = -1;
                    }
                }
                if !(nosig < 0 || nosig > nisig) {
                    break;
                }
            }
        }
        if mflag {
            ofreq = ifreq;
            ceprintf!(
                b"Sampling frequency (%g frames/sec) will be unchanged\n",
                ofreq
            );
        } else {
            loop {
                ofreq = ifreq;
                ceprintf!(
                    b"Output sampling frequency (Hz per signal, > 0) [%g]: ",
                    ofreq
                );
                answer = sfgets(ANSLEN);
                let _ = csscanf!(&answer, b"%lf", &mut ofreq);
                if ofreq >= 0.0 || ofreq.is_nan() {
                    break;
                }
            }
        }
        if ofreq == 0.0 && legacy {
            ofreq = WFDB_DEFFREQ; // WFDB-x: as in the C program (legacy mode)
        } else if ofreq == 0.0 {
            // WFDB-x: the C program assumed 250 Hz
            ceprintf!(b"%s: the output sampling frequency must be > 0\n", pname);
            wfdbx::wfdbquit();
            cstd::exit(1);
        }
        let nrec_s = nrec.clone().unwrap_or_default();
        if nosig > 0 {
            ceprintf!(b"Specify the name of the directory in which the output\n");
            ceprintf!(b" signals should be written, or press <return> to write\n");
            ceprintf!(b" them in the current directory: ");
            let mut directory = sfgets(ANSLEN - 1);
            if directory.first() == Some(&b'\n') {
                directory.clear();
            } else if let Some(last) = directory.last_mut() {
                *last = b'/';
            }
            ceprintf!(b"Any of these output formats may be used:\n");
            ceprintf!(b"    8   8-bit first differences\n");
            ceprintf!(b"   16   16-bit two's complement amplitudes (LSB first)\n");
            ceprintf!(b"   61   16-bit two's complement amplitudes (MSB first)\n");
            ceprintf!(b"   80   8-bit offset binary amplitudes\n");
            ceprintf!(b"  160   16-bit offset binary amplitudes\n");
            ceprintf!(b"  212   2 12-bit amplitudes bit-packed in 3 bytes\n");
            ceprintf!(b"  310   3 10-bit amplitudes bit-packed in 15 LS bits of each of 2 words\n");
            ceprintf!(b"  311   3 10-bit amplitudes bit-packed in 30 LS bits of 4 bytes\n");
            ceprintf!(b"   24   24-bit two's complement amplitudes (LSB first)\n");
            ceprintf!(b"   32   32-bit two's complement amplitudes (LSB first)\n");
            ceprintf!(b"  508  8-bit amplitudes with FLAC compression\n");
            ceprintf!(b"  516  16-bit amplitudes with FLAC compression\n");
            ceprintf!(b"  524  24-bit amplitudes with FLAC compression\n");
            loop {
                format = dfin[0].fmt;
                ceprintf!(
                    b"Choose an output format from the list above [%d]: ",
                    format
                );
                answer = sfgets(ANSLEN);
                let _ = csscanf!(&answer, b"%d", &mut format);
                // skip format[0] (= 0)
                if WFDB_FMT_LIST[1..WFDB_NFMTS as usize].contains(&format) {
                    break;
                }
            }
            let mut save_answer: Vec<u8> = Vec::new();
            if nosig > 1 {
                ceprintf!(b"Save all signals in one file? [y]: ");
                save_answer = sfgets(ANSLEN);
            }
            // Use the input signal specifications as defaults for output.
            for i in 0..nosig as usize {
                dfout[i] = dfin[siglist[i] as usize].clone();
            }
            if nosig <= 1
                || (save_answer.first() != Some(&b'n') && save_answer.first() != Some(&b'N'))
            {
                let filename = cformat!(b"%s%s.dat", directory, nrec_s);
                for d in dfout.iter_mut().take(nosig as usize) {
                    d.fname = Some(filename.clone());
                    d.group = 0;
                }
            } else {
                for (i, d) in dfout.iter_mut().enumerate().take(nosig as usize) {
                    d.fname = Some(cformat!(b"%s%s.d%d", directory, nrec_s, i as i32));
                    d.group = i as u32;
                }
            }
        }
        for i in 0..nosig.max(0) as usize {
            // Make sure output signals are written in the chosen format.
            dfout[i].fmt = format;
            if !mflag {
                dfout[i].spf = 1;
            }
            dfout[i].bsize = 0; // no block size is defined
            if !use_irec_desc {
                ceprintf!(
                    b"Signal %d description (up to %d characters): ",
                    i as i32,
                    WFDB_MAXDSL as i32
                );
                let mut description = sfgets(WFDB_MAXDSL + 2);
                description.pop();
                dfout[i].desc = Some(description);
                ceprintf!(
                    b"Signal %d units (up to %d characters): ",
                    i as i32,
                    WFDB_MAXUSL as i32
                );
                let mut units = sfgets(WFDB_MAXUSL + 2);
                for k in 0..units.len() {
                    if units[k] == b' ' || units[k] == b'\t' {
                        units[k] = b'_';
                    } else if units[k] == b'\n' {
                        units.truncate(k);
                        break;
                    }
                }
                dfout[i].units = if units.is_empty() { None } else { Some(units) };
            }
            ceprintf!(
                b" Signal %d gain (adu/%s) [%g]: ",
                i as i32,
                match &dfout[i].units {
                    Some(u) => cstd::cstr(u).to_vec(),
                    // WFDB-x: C (legacy mode) showed "mV"
                    None if legacy => b"mV".to_vec(),
                    None => b"nd".to_vec(),
                },
                dfout[i].gain
            );
            answer = sfgets(ANSLEN);
            let _ = csscanf!(&answer, b"%lf", &mut dfout[i].gain);
            // WFDB-x: a resolution is offered only if it comes from the input
            // (or the previous output signal) and suits the output format;
            // the C program otherwise offered one based on the format (12
            // bits for 16-bit formats).  Without one, the user must give it.
            // Legacy mode: as in the C program.
            loop {
                if i > 0 {
                    dfout[i].adcres = dfout[i - 1].adcres;
                }
                let d = &mut dfout[i];
                let (maxres, legacy_res) = format_res(d.fmt);
                if legacy && (d.adcres < 8 || d.adcres > maxres) {
                    d.adcres = legacy_res; // WFDB-x: legacy mode
                }
                if d.adcres >= 8 && d.adcres <= maxres {
                    ceprintf!(
                        b" Signal %d ADC resolution in bits (8-32) [%d]: ",
                        i as i32,
                        d.adcres
                    );
                } else {
                    ceprintf!(b" Signal %d ADC resolution in bits (8-32): ", i as i32);
                    d.adcres = 0;
                }
                answer = sfgets(ANSLEN);
                let _ = csscanf!(&answer, b"%d", &mut d.adcres);
                if d.adcres == 0 && !legacy {
                    ceprintf!(
                        b"%s: the ADC resolution of signal %d must be specified\n",
                        pname,
                        i as i32
                    );
                    wfdbx::wfdbquit();
                    cstd::exit(1);
                }
                if !(d.adcres < 8 || d.adcres > 32) {
                    break;
                }
            }
            ceprintf!(
                b" Signal %d ADC zero level (adu) [%d]: ",
                i as i32,
                dfout[i].adczero
            );
            answer = sfgets(ANSLEN);
            let _ = csscanf!(&answer, b"%d", &mut dfout[i].adczero);
        }
    }

    // Check the starting and ending times.
    if from != 0 {
        startp = &argv[from as usize];
    }
    from = wfdbx::strtim(startp);
    if from < 0 {
        from = -from;
    }
    let mut btstring = wfdbx::mstimstr(-from);
    btstring.truncate(29); // (C: snprintf into a 30-byte buffer)
    if to != 0 {
        to = wfdbx::strtim(&argv[to as usize]);
        if to < 0 {
            to = -to;
        }
        if to > 0 {
            nsamp = to - from;
            if nsamp <= 0 {
                ceprintf!(b"%s: 'to' time must be later than 'from' time\n", pname);
                cstd::exit(1);
            }
        }
    }
    let spm = wfdbx::strtim("1:0");

    if mflag {
        // In multifrequency mode, the preceding calculations are performed
        // in low-resolution mode (so that 'from' and 'to' are rounded to the
        // nearest frame number, and 'nsamp' is the number of frames to
        // copy.)  For annotation processing, switch to high-resolution mode,
        // convert 'from' and 'to' into high-resolution sample numbers, and
        // set the output annotation resolution accordingly.
        wfdbx::setgvmode(WFDB_HIGHRES);
        spf = wfdbx::getspf();
        from = from.wrapping_mul(spf as i64);
        to = to.wrapping_mul(spf as i64);
        wfdbx::setafreq(ofreq * spf as f64);
    } else {
        // For a single-frequency record, the time resolution for output
        // annotations is equal to the output frame frequency (ofreq), so we
        // do not need an explicit time resolution.  If a default time
        // resolution is set by isigopen, remove it.
        wfdbx::setafreq(0.0);
    }

    // Process the annotation file(s), if any.
    let nann = ainames.len();
    if nann > 0 {
        let mut annot = Annotation::default();
        let mut ai: Vec<Anninfo> = ainames
            .iter()
            .map(|n| Anninfo {
                name: n.clone(),
                stat: WFDB_READ,
            })
            .collect();

        // Check that the input annotation files are readable.
        if wfdbx::annopen(irec, &ai, nann as u32) < 0 || wfdbx::iannsettime(from) < -1 {
            cstd::exit(2);
        }

        // Associate the output annotation files with the new record, if a
        // new record name was specified.  Otherwise, associate them with the
        // existing output record.
        let p0: &[u8] = match (&nrec, orec) {
            (Some(n), _) => n,
            (None, Some(o)) => o,
            (None, None) => b"(null)",
        };

        // Check that the output annotation files are writeable, without
        // closing the input annotation files.
        let mut p1 = b"+".to_vec();
        p1.extend_from_slice(cstd::cstr(p0));
        for a in &mut ai {
            a.stat = WFDB_WRITE;
        }
        if wfdbx::annopen(&p1, &ai, nann as u32) < 0 {
            cstd::exit(2);
        }

        // Write the annotation files.
        for i in 0..nann as u32 {
            let mut tt: i64 = 0;
            let mut cc: i32 = -129; // (less than any chan)
            while wfdbx::getann(i, &mut annot) == 0 && (to == 0 || annot.time <= to) {
                if annot.time == 0
                    && annot.subtyp == 0
                    && annot.chan == 0
                    && annot.num == 0
                    && (annot.anntyp as i32 == NOTQRS || annot.anntyp as i32 == NOTE)
                {
                    continue;
                }
                annot.time = d2l((annot.time - from) as f64 * ofreq / ifreq);
                // If the -u option was specified, make sure that the
                // corrected annotation time is positive and that it is later
                // than the previous annotation time (exception: if it
                // matches the previous annotation time, but the chan field
                // is greater than that of the previous annotation, no time
                // adjustment is performed).
                if uflag && (annot.time < tt || (annot.time == tt && (annot.chan as i32) <= cc)) {
                    tt += 1;
                    annot.time = tt;
                } else {
                    tt = annot.time;
                }
                cc = annot.chan as i32;
                let _ = wfdbx::putann(i, &annot);
            }
        }

        // Close the annotation files.
        for i in (0..nann as u32).rev() {
            wfdbx::iannclose(i);
            wfdbx::oannclose(i);
        }
    }

    // Quit if no signals are to be written.
    if nosig == 0 {
        cstd::exit(0);
    }
    let nosig_u = nosig as usize;

    // Check that the input signals are readable.
    ceprintf!(b"Checking input signals ...");
    if wfdbx::isigsettime(from) < 0 {
        cstd::exit(2);
    }
    ceprintf!(b" done\n");

    // If an output record was specified using `-o', check that the output
    // signals are writable.  Suppress warning messages about possible
    // sampling frequency differences.
    wfdbx::wfdbquiet();
    if let Some(orec) = orec {
        if wfdbx::osigopen(orec, &mut dfout[..nosig_u], nosig as u32) != nosig {
            // WFDB-x: say why if an output file is one of the input files
            // (the library's message, quieted above, is the last error)
            let e = wfdbx::wfdberror();
            const TAIL: &[u8] = b" is also an input file\n";
            if !legacy
                && e.starts_with(b"osigopen: output file ")
                && e.len() > 22 + TAIL.len()
                && e.ends_with(TAIL)
            {
                ceprintf!(
                    b"%s: can't write output signals (%s)\n",
                    pname,
                    &e[..e.len() - 1]
                );
            } else {
                ceprintf!(b"%s: can't write output signals\n", pname);
            }
            cstd::exit(2);
        }
    }
    wfdbx::wfdbverbose();

    // Make sure that signal file format is not 0 (putvec cannot write to a
    // null record).
    for (i, d) in dfout.iter_mut().enumerate().take(nosig_u) {
        if d.fmt == 0 {
            ceprintf!(
                b"%s: signal %d format cannot be 0 (changing to format 16)\n",
                pname,
                i as i32
            );
            d.fmt = 16;
            reopen = true; // record must be (re)opened using osigfopen to
                           // make the change effective
        }
    }

    // Without -M, the output frames hold one sample of each signal (as for
    // output signals specified interactively), so signals of the -o record
    // with more than one sample per frame are (re)opened with one. (C reads
    // past the end of its output array; see "Undefined behaviors" in
    // docs/KNOWN_C_BEHAVIORS.md.)
    if !mflag {
        for d in dfout.iter_mut().take(nosig_u) {
            if d.spf > 1 {
                d.spf = 1;
                reopen = true;
            }
        }
    }

    // If the `-n' option was specified, copy the signal descriptions from
    // the input record header file into the WFDB_Siginfo structures for the
    // output record (for eventual storage in the new output header file).
    // To make the changes effective, the output signals must be (re)opened
    // using osigfopen.
    if nrec.is_some() && use_irec_desc {
        for i in 0..nosig_u {
            dfout[i].desc = dfin[siglist[i] as usize].desc.clone();
        }
        reopen = true;
    }

    // Determine relative gains and offsets of the signals.  If any output
    // gain must be adjusted, the output signals must be reopened (to ensure
    // that the correct gains are written to the output header).
    for i in 0..nosig_u {
        let j = siglist[i] as usize;
        // A signal may be rescaled by xform depending on the gains and ADC
        // resolutions specified.  The rules for doing so are as follows:
        // 1.  If the output gain has not been specified, the signal is
        //     scaled only if the input and output ADC resolutions differ.
        //     In this case, the scale factor (gain[]) is determined so that
        //     the appropriate number of bits will be dropped from or added
        //     to each signal.
        // 2.  If the output gain has been specified, the signal is scaled by
        //     the ratio of the output and input gains.  (WFDB-x: if the input
        //     signal is uncalibrated, this is an error; the C program, and
        //     legacy mode, assumed an input gain of WFDB_DEFGAIN.)
        // These rules differ from those used by earlier versions of xform,
        // although the default behavior remains the same in most cases.
        if dfout[i].gain == 0.0 {
            // output gain not specified
            // WFDB-x: rescaling by ADC resolution needs both resolutions
            // (the C program guessed an unspecified input resolution from
            // the format, assuming WFDB_DEFRES for 16-bit formats, as legacy
            // mode does).
            if legacy {
                if dfin[j].adcres == 0 {
                    dfin[j].adcres = format_res(dfin[j].fmt).1;
                }
            } else if dfin[j].adcres == 0 || dfout[i].adcres == 0 {
                let (n, r): (i32, Vec<u8>) = if dfin[j].adcres == 0 {
                    (j as i32, irec.to_vec())
                } else {
                    (
                        i as i32,
                        match orec {
                            Some(o) => o.to_vec(),
                            None => nrec.clone().unwrap_or_default(),
                        },
                    )
                };
                ceprintf!(
                    b"%s: ADC resolution of signal %d of record %s is not specified\n",
                    pname,
                    n,
                    r
                );
                wfdbx::wfdbquit();
                cstd::exit(2);
            }
            gain[i] = 1i64.wrapping_shl(dfout[i].adcres as u32) as f64
                / 1i64.wrapping_shl(dfin[j].adcres as u32) as f64;
        } else if dfin[j].gain == 0.0 {
            // output gain specified, but input gain not specified
            if legacy {
                // WFDB-x: as in the C program (legacy mode)
                gain[i] = dfout[i].gain / WFDB_DEFGAIN;
            } else {
                ceprintf!(
                b"%s: signal %d of record %s is uncalibrated; it cannot be rescaled to the specified gain\n",
                pname,
                j as i32,
                irec
            );
                wfdbx::wfdbquit();
                cstd::exit(2);
            }
        } else {
            // input and output gains specified
            gain[i] = dfout[i].gain / dfin[j].gain;
        }

        if gain[i] != 1.0 {
            gflag = true;
        }
        deltav[i] = d2i(dfout[i].adczero as f64 - gain[i] * dfin[j].adczero as f64);
        if dfout[i].gain != dfin[j].gain * gain[i]
            || dfout[i].baseline as f64 != dfin[j].baseline as f64 * gain[i]
        {
            dfout[i].gain = dfin[j].gain * gain[i];
            dfout[i].baseline = d2i(dfin[j].baseline as f64 * gain[i]);
            reopen = true;
        }
        // Note that dfout[i].gain is 0 (indicating that the signal is
        // uncalibrated) if dfin[j].gain is 0.  This is a *feature*, not a
        // bug:  we don't want to create output signals that appear to have
        // been calibrated if the inputs weren't calibrated.
    }

    // Reopen output signals if necessary.
    if reopen && wfdbx::osigfopen(&dfout[..nosig_u], nosig as u32) != nosig {
        cstd::exit(2);
    }

    // Determine the legal range of sample values for each output signal.
    for i in 0..nosig_u {
        let half = 1u64.wrapping_shl(dfout[i].adcres.wrapping_sub(1) as u32);
        let z = dfout[i].adczero as i64 as u64;
        vmax[i] = z.wrapping_add(half).wrapping_sub(1) as i32;
        vmin[i] = z.wrapping_sub(half) as i32;
    }

    // If resampling is required, initialize the interpolation/decimation
    // parameters.
    let (mut m, mut n, mut mn) = (0i32, 0i32, 0i32);
    if ifreq != ofreq {
        let f = gcd(ifreq, ofreq);

        fflag = true;
        m = d2i(ifreq / f);
        n = d2i(ofreq / f);
        mn = m.wrapping_mul(n);
        let _ = wfdbx::getvec(&mut vin);
        for i in 0..nosig_u {
            let x = vin[siglist[i] as usize];
            vv[i] = if x != WFDB_INVALID_SAMPLE {
                d2i(x as f64 * gain[i] + deltav[i] as f64)
            } else {
                WFDB_INVALID_SAMPLE
            };
        }
    }

    // If in multifrequency mode, set msiglist offsets.
    if mflag {
        for i in 0..nosig_u {
            msiglist[i] = dfin[..siglist[i] as usize].iter().map(|s| s.spf).sum();
        }
        // WFDB-x: room for every output sample of a frame, and for every
        // input sample that they read (C sizes vout for the input frame and
        // writes past its end when the output frame is larger; the samples
        // read beyond the input frame are 0 here)
        let ospf: usize = dfout[..nosig_u].iter().map(|s| s.spf.max(0) as usize).sum();
        if vout.len() < ospf {
            vout.resize(ospf, 0);
        }
        let need = (0..nosig_u)
            .map(|i| msiglist[i] as usize + dfout[i].spf.max(0) as usize)
            .max()
            .unwrap_or(0);
        if vin.len() < need {
            vin.resize(need, 0);
        }
    }

    let more = |nsamp: &mut i64| -> bool {
        if *nsamp == -1 {
            return true;
        }
        let r = *nsamp > 0;
        *nsamp -= 1;
        r
    };

    // Process the signals.
    if !fflag {
        // no frequency changes; gain changes if gflag
        loop {
            let stat = if mflag {
                wfdbx::getframe(&mut vin)
            } else {
                wfdbx::getvec(&mut vin)
            };
            if !(stat >= nisig && more(&mut nsamp)) {
                break;
            }
            tick(&mut nsm, spm, &mut nminutes);
            if !mflag {
                // standard mode
                for i in 0..nosig_u {
                    let vt = vin[siglist[i] as usize];
                    if vt == WFDB_INVALID_SAMPLE {
                        vout[i] = vt;
                    } else {
                        if gflag {
                            let mut vd = vt as f64 * gain[i] + deltav[i] as f64;
                            if dflag {
                                vd += dither(&mut rng);
                            }
                            vout[i] = round(vd);
                        } else {
                            vout[i] = vt.wrapping_add(deltav[i]);
                        }
                        check(&mut vout[i], i, &mut vmax, &mut vmin, clip);
                    }
                }
            } else {
                // multifrequency mode
                let mut j = 0;
                for i in 0..nosig_u {
                    for k in 0..dfout[i].spf.max(0) as usize {
                        let vt = vin[msiglist[i] as usize + k];
                        if vt == WFDB_INVALID_SAMPLE {
                            vout[j] = vt;
                        } else {
                            if gflag {
                                let mut vd = vt as f64 * gain[i] + deltav[i] as f64;
                                if dflag {
                                    vd += dither(&mut rng);
                                }
                                vout[j] = round(vd);
                            } else {
                                vout[j] = vt.wrapping_add(deltav[i]);
                            }
                            check(&mut vout[j], i, &mut vmax, &mut vmin, clip);
                        }
                        j += 1;
                    }
                }
            }
            if wfdbx::putvec(&vout) < 0 {
                break;
            }
        }
    } else {
        // change frequency (and gain, if gflag)
        while wfdbx::getvec(&mut vin) >= nisig && more(&mut nsamp) {
            tick(&mut nsm, spm, &mut nminutes);
            for i in 0..nosig_u {
                let vt = vin[siglist[i] as usize];
                v[i] = if vt == WFDB_INVALID_SAMPLE {
                    vt
                } else if gflag {
                    let mut vd = vt as f64 * gain[i] + deltav[i] as f64;
                    if dflag {
                        vd += dither(&mut rng);
                    }
                    round(vd)
                } else {
                    vt.wrapping_add(deltav[i])
                };
            }
            while ot <= it {
                let r = ot % n as i64;
                let x = if r == 0 { 1.0 } else { r as f64 / n as f64 };
                for i in 0..nosig_u {
                    if v[i] == WFDB_INVALID_SAMPLE || vv[i] == WFDB_INVALID_SAMPLE {
                        vout[i] = WFDB_INVALID_SAMPLE;
                    } else {
                        let mut vd = vv[i] as f64 + x * v[i].wrapping_sub(vv[i]) as f64;
                        if dflag {
                            vd += dither(&mut rng);
                        }
                        vout[i] = round(vd);
                        check(&mut vout[i], i, &mut vmax, &mut vmin, clip);
                    }
                }
                if wfdbx::putvec(&vout) < 0 {
                    nsamp = 0;
                    break;
                }
                ot += m as i64;
            }
            vv[..nosig_u].copy_from_slice(&v[..nosig_u]);
            if it > mn as i64 {
                it -= mn as i64;
                ot -= mn as i64;
            }
            it += n as i64;
        }
    }
    if nminutes > 0 {
        ceprintf!(b"\n");
    }

    // Generate a new header file, if so requested.
    if let Some(nrec) = &nrec {
        let _ = wfdbx::setsampfreq(ofreq);
        if btstring.first() == Some(&b'[') {
            // discard final ']'
            let bt = cstd::cstr(&btstring);
            let _ = wfdbx::setbasetime(&bt[1..bt.len() - 1]);
        }
        let _ = wfdbx::newheader(nrec);

        // Copy info strings from the input header file into the new one.
        // Suppress error messages from the WFDB library.
        wfdbx::wfdbquiet();
        let mut info = wfdbx::getinfo(irec);
        while let Some(s) = info {
            let _ = wfdbx::putinfo(&s);
            info = wfdbx::getinfo(NULL);
        }

        // Append additional info summarizing what xform has done.
        let xinfo = cformat!(
            b"Produced by %s from record %s, beginning at %s",
            pname,
            irec,
            startp
        );
        let _ = wfdbx::putinfo(&xinfo);
        for i in 0..nosig_u {
            if siglist[i] != i as i32 {
                let mut xinfo = cformat!(
                    b"record %s, signal %d <- record %s, signal %d",
                    nrec,
                    i as i32,
                    irec,
                    siglist[i]
                );
                if gain[i] != 1.0 {
                    xinfo.extend_from_slice(&cformat!(b" * %g", gain[i]));
                }
                if deltav[i] != 0 {
                    xinfo.extend_from_slice(&cformat!(
                        b" %c %d",
                        if deltav[i] > 0 { b'+' } else { b'-' } as i32,
                        if deltav[i] > 0 {
                            deltav[i]
                        } else {
                            deltav[i].wrapping_neg()
                        }
                    ));
                }
                let _ = wfdbx::putinfo(&xinfo);
            }
        }
        wfdbx::wfdbverbose();
    }
    wfdbx::wfdbquit();
    cstd::exit(0);
}
