//! rr2ann: create an annotation file from an RR interval list (port of
//! `app/rr2ann.c`).
//!
//! The input contains RR intervals (or times of occurrence, with -T) in
//! text format, one per line. The first token on each line is taken to be
//! an RR interval; any additional tokens on the same line are ignored. The
//! output is an annotation file in which all beats are marked NORMAL (or
//! have the types given in the second column of the input, with -w).
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Rust translation of app/rr2ann.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: no built-in sampling frequency: -F FREQ is
// required when the record has no header or its header gives none (the
// original assumed 250 Hz); --legacy, as the first argument, restores the
// original behavior. Each change is marked "wfdb-x:" in the code;
// docs/DIVERGENCES.md gives the reasons.
//
// Original C program: app/rr2ann.c, WFDB Software Package 10.7.0.
//   Copyright (C) 2000 George B. Moody.
// Rust translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

use wfdbx::cstd;
use wfdbx::{
    ceprintf, csscanf, Anninfo, Annotation, WfdbFile, NORMAL, NOTQRS, NULL, WFDB_DEFFREQ,
    WFDB_WRITE,
};

const MAXLINELEN: usize = 1024; // longer input lines will be silently split

const HELP_STRINGS: &[&[u8]] = &[
    b"usage: %s -r RECORD -a ANNOTATOR [OPTIONS ...] <TEXT-FILE\n",
    b"where RECORD and ANNOTATOR specify the output, and OPTIONS may include:",
    b" -F FREQ     use FREQ as the sampling frequency (effective only if the               header file does not exist or does not specify it)",
    b" -h          print this usage summary",
    b" -T          TEXT-FILE contains times of occurrence, not RR intervals",
    b" -x N        multiply input by N to obtain RR in sample intervals",
    b"               (default: N = 1)",
    b" -w          copy annotation types from second column of input",
    b"TEXT-FILE should contain a column of RR intervals (or times of occurrence,",
    b"if the -T option is specified), in units of sample intervals (unless the",
    b"-x option is used to specify a conversion factor).   The first token on",
    b"each line is taken as an RR interval, and (if the -w option is specified)",
    b"the second token is taken as an annotation mnemonic (N, V, etc.);  anything",
    b"else on the same line is ignored, as are empty lines, spaces and tabs at",
    b"the beginning of a line non-numeric tokens and anything following them on",
    b"the same line, negative intervals, and zero intervals.  The output consists",
    b"of a binary annotation file (RECORD.ANNOTATOR), and (if it does not exist",
    b"already) a text header file (RECORD.hea).",
];

/// wfdb-x: the -F line of the help text of the original program (printed
/// in legacy mode in place of `HELP_STRINGS[2]`).
const LEGACY_HELP_F: &[u8] = b" -F FREQ     use FREQ as the sampling frequency (effective only if no               header file exists;  default: 250)";

fn help(pname: &[u8]) {
    let legacy = wfdbx::wfdbx_get_legacy() != 0;
    ceprintf!(HELP_STRINGS[0], pname);
    for (i, s) in HELP_STRINGS.iter().enumerate().skip(1) {
        ceprintf!(b"%s\n", if legacy && i == 2 { LEGACY_HELP_F } else { s });
    }
}

fn main() {
    let mut argv = cstd::args();
    let legacy = wfdbx::wfdbx_legacy_args(&mut argv) != 0; // wfdb-x: --legacy
    let argc = argv.len();
    let pname = cstd::prog_name(&argv[0]).to_vec();
    let mut annot = Annotation::default();
    let mut sps: f64 = 0.0;
    let (mut rr, mut t, mut xfactor) = (0.0f64, 0.0f64, 1.0f64);
    let mut record: Option<&[u8]> = None;
    let mut ainame: Option<&[u8]> = None;
    let (mut tflag, mut wflag) = (false, false);

    // Interpret command-line options.
    let mut i = 1;
    while i < argc {
        let a = &argv[i];
        if a.first() == Some(&b'-') {
            match a.get(1).copied().unwrap_or(0) {
                b'a' => {
                    // annotator follows
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: annotator must follow -a\n", pname);
                        cstd::exit(1);
                    }
                    ainame = Some(&argv[i]);
                }
                b'F' => {
                    // sampling frequency in Hz
                    i += 1;
                    if i < argc {
                        sps = cstd::atof(&argv[i]);
                    }
                    if i >= argc || sps <= 0.0 {
                        ceprintf!(b"%s: sampling frequency (> 0) must follow -F\n", pname);
                        cstd::exit(1);
                    }
                }
                b'h' => {
                    // print usage summary and quit
                    help(&pname);
                    cstd::exit(0);
                }
                b'r' => {
                    // record name follows
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: record name must follow -r\n", pname);
                        cstd::exit(1);
                    }
                    record = Some(&argv[i]);
                }
                b'T' => tflag = true, // data are times of occurrence, not RR intervals
                b'x' => {
                    // multiplier to convert input to sample intervals
                    i += 1;
                    if i < argc {
                        xfactor = cstd::atof(&argv[i]);
                    }
                    if i >= argc || xfactor <= 0.0 {
                        ceprintf!(b"%s: an input multiplier (> 0) must follow -x\n", pname);
                        cstd::exit(1);
                    }
                }
                b'w' => wflag = true, // copy annotation types from second column of input
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
    let (Some(record), Some(ainame)) = (record, ainame) else {
        help(&pname);
        cstd::exit(1);
    };

    // sampfreq is likely to fail, since the header probably doesn't exist.
    // Suppress its error message.
    wfdbx::wfdbquiet();
    // wfdb-x: no default sampling frequency (the C program assumed 250 Hz);
    // -F specifies one if the record header does not.
    let f = wfdbx::sampfreq(record);
    if f <= 0.0 {
        wfdbx::wfdbverbose(); // re-enable error reporting
        if sps == 0.0 && legacy {
            sps = WFDB_DEFFREQ; // wfdb-x: legacy mode (original behavior)
        } else if sps == 0.0 {
            ceprintf!(
                b"%s: sampling frequency of record %s is not specified (use -F)\n",
                pname,
                record
            );
            cstd::exit(1);
        }
        wfdbx::setsampfreq(sps);
        // no header: create one (the C program: in any case)
        if (f < 0.0 || legacy) && wfdbx::newheader(record) < 0 {
            cstd::exit(2);
        }
    } else {
        wfdbx::wfdbverbose(); // re-enable error reporting
        if sps != 0.0 {
            ceprintf!(
                b"%s (warning): -F option ignored (using %g for sampling frequency)\n",
                pname,
                wfdbx::sampfreq(NULL)
            );
        }
    }

    let ai = [Anninfo {
        name: ainame.to_vec(),
        stat: WFDB_WRITE,
    }];
    if wfdbx::annopen(record, &ai, 1) < 0 {
        // open annotation file
        cstd::exit(3);
    }
    annot.anntyp = NORMAL as i8;

    // Read input, write an annotation for each line beginning with a
    // positive number.
    let mut input = WfdbFile::stdin();
    let mut line = Vec::new();
    let mut astring: Vec<u8> = Vec::new();
    while input.fgets(&mut line, MAXLINELEN) {
        let l = cstd::cstr(&line);
        if !wflag {
            // write all annotations as NORMAL
            if csscanf!(l, b"%lf", &mut rr) == 0 {
                continue;
            }
        } else {
            // copy annotation type from input
            if csscanf!(l, b"%lf%s", &mut rr, &mut astring) < 2 {
                continue;
            }
            annot.anntyp = wfdbx::strann(&astring[..]) as i8;
            if annot.anntyp as i32 == NOTQRS {
                continue;
            }
        }
        if rr <= 0.0 {
            continue;
        } else if tflag {
            t = rr * xfactor;
        } else {
            t += rr * xfactor;
        }
        annot.time = cstd::d2l(t + 0.5);
        wfdbx::putann(0, &annot);
    }

    // Flush buffered output.
    wfdbx::wfdbquit();
    cstd::exit(0);
}
