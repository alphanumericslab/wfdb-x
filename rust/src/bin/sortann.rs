//! sortann: rearrange annotations in canonical order (port of
//! `app/sortann.c`).
//!
//! This program rewrites annotation files with the annotations in time
//! order. Any simultaneous annotations are written in `num` and `chan`
//! order. If the input contains two or more annotations with the same
//! time, num, and chan fields, only the last one is copied (and none, if
//! that one has anntyp = NOTQRS) -- but only when the duplicates are found
//! while repairing out-of-order input, as in the C version.
//!
//! The sorted (output) annotation file is always written to the current
//! directory. If the input annotations are already in the correct order,
//! no output is written unless the -o option is used.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Rust translation of app/sortann.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: no built-in sampling frequency: the new option -F
// FREQ gives it when the record has no header or its header gives none, and is
// then required for the -f and -t times (the original assumed 250 Hz); an
// out-of-order annotation at time 0 (num 0, chan 0) is no longer lost, nor are
// those inserted after it; --legacy, as the first argument, restores the
// original behavior. Each change is marked "WFDB-x:" in the code;
// docs/DIVERGENCES.md gives the reasons.
//
// Original C program: app/sortann.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1997-2010 George B. Moody; revised 2017-2018 by
//   Benjamin Moody.
// Rust translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

use wfdbx::cstd;
use wfdbx::{
    ceprintf, csscanf, AnnList, Anninfo, Annotation, NOTQRS, WFDB_DEFFREQ, WFDB_READ, WFDB_WRITE,
};

const HELP_STRINGS: &[&[u8]] = &[
    b"usage: %s -r RECORD -a ANNOTATOR [OPTIONS ...]\n",
    b"where RECORD and ANNOTATOR specify the input, and OPTIONS may include:",
    b" -f TIME    start at specified TIME",
    b" -F FREQ    sampling frequency, if the record header does not specify one",
    b" -h         print this usage summary",
    b" -o OUTANN  write output as annotator OUTANN (required with -f or -t)",
    b" -t TIME    stop at specified TIME",
    b"The sorted output replaces the input if -o is omitted, the input is in",
    b"the current directory, and the input is not already sorted.",
];

/// WFDB-x: the lines of `HELP_STRINGS` added by WFDB-x, left out of the
/// help text of the original program (printed in legacy mode).
const WFDBX_HELP_LINES: &[&[u8]] =
    &[b" -F FREQ    sampling frequency, if the record header does not specify one"];

fn help(pname: &[u8]) {
    let legacy = wfdbx::wfdbx_get_legacy() != 0;
    ceprintf!(HELP_STRINGS[0], pname);
    for s in &HELP_STRINGS[1..] {
        if !(legacy && WFDBX_HELP_LINES.contains(s)) {
            ceprintf!(b"%s\n", s);
        }
    }
}

fn main() {
    let mut argv = cstd::args();
    let legacy = wfdbx::wfdbx_legacy_args(&mut argv) != 0; // WFDB-x: --legacy
    let argc = argv.len();
    let pname = cstd::prog_name(&argv[0]).to_vec();
    let mut ainame: [Option<&[u8]>; 2] = [None, None];
    let mut record: Option<&[u8]> = None;
    let (mut from, mut to): (i64, i64) = (0, 0);
    let mut ffreq = 0.0f64; // -F (WFDB-x)
    let mut annot = Annotation::default();

    // Interpret command-line options.
    let mut i = 1;
    while i < argc {
        let a = &argv[i];
        if a.first() == Some(&b'-') {
            match a.get(1).copied().unwrap_or(0) {
                b'a' => {
                    // (input) annotator follows
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: annotator must follow -a\n", pname);
                        cstd::exit(1);
                    }
                    ainame[0] = Some(&argv[i]);
                }
                b'f' => {
                    // starting time follows
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: starting time must follow -f\n", pname);
                        cstd::exit(1);
                    }
                    from = i as i64; // to be converted to sample intervals below
                }
                b'F' if !legacy => {
                    // sampling frequency follows (WFDB-x)
                    i += 1;
                    if i >= argc || csscanf!(&argv[i], b"%lf", &mut ffreq) != 1 || ffreq <= 0.0 {
                        ceprintf!(b"%s: sampling frequency (> 0) must follow -F\n", pname);
                        cstd::exit(1);
                    }
                }
                b'h' => {
                    // print usage summary and quit
                    help(&pname);
                    cstd::exit(0);
                }
                b'o' => {
                    // output annotator follows
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: annotator must follow -o\n", pname);
                        cstd::exit(1);
                    }
                    ainame[1] = Some(&argv[i]);
                }
                b'r' => {
                    // input record name follows. If -r is followed by a
                    // non-empty string (with no intervening space), use that
                    // string as the WFDB path. (The WFDB library invokes
                    // sortann with '-r.'.)
                    let p = cstd::cstr(&a[2..]);
                    if !p.is_empty() {
                        wfdbx::setwfdb(p);
                    }
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: input record name must follow -r\n", pname);
                        cstd::exit(1);
                    }
                    record = Some(&argv[i]);
                }
                b't' => {
                    // ending time follows
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: end time must follow -t\n", pname);
                        cstd::exit(1);
                    }
                    to = i as i64;
                }
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

    let (Some(record), Some(ain0)) = (record, ainame[0]) else {
        help(&pname);
        cstd::exit(1);
    };
    if (from != 0 || to != 0) && ainame[1].is_none() {
        ceprintf!(b"%s: -o required when using -f or -t options\n", pname);
        cstd::exit(1);
    }
    if let Some(a1) = ainame[1] {
        if cstd::cstr(ain0) == cstd::cstr(a1) {
            ceprintf!(
                b"%s: must specify different annotator names after -a and -o\n",
                pname
            );
            cstd::exit(1);
        }
    }

    // By setting WFDBANNSORT, we ensure that wfdbquit won't invoke this
    // program recursively if something goes wrong.
    cstd::setenv("WFDBANNSORT", b"0", true);

    // WFDB-x: no default sampling frequency (the C program assumed 250 Hz if
    // the record had no header); -F specifies one. It is needed only to
    // convert the -f and -t times.
    let mut sps = wfdbx::sampfreq(record);
    if legacy {
        // WFDB-x: legacy mode (original behavior)
        if sps < 0.0 {
            sps = WFDB_DEFFREQ;
            wfdbx::setsampfreq(sps);
        }
    } else if sps <= 0.0 && ffreq > 0.0 {
        sps = ffreq;
        wfdbx::setsampfreq(sps);
    }
    let needs_freq = |k: i64| k != 0 && wfdbx::wfdbx_time_needs_freq(&argv[k as usize][..]) != 0;
    if !legacy && sps <= 0.0 && (needs_freq(from) || needs_freq(to)) {
        ceprintf!(
            b"%s: sampling frequency of record %s is not specified (use -F)\n",
            pname,
            record
        );
        cstd::exit(1);
    }

    let ai0 = [Anninfo {
        name: ain0.to_vec(),
        stat: WFDB_READ,
    }];
    if wfdbx::annopen(record, &ai0, 1) < 0 {
        // open input annotation file
        cstd::exit(2);
    }

    if from != 0 {
        from = wfdbx::strtim(&argv[from as usize][..]);
        if from < 0 {
            from = -from;
        }
    }
    if to != 0 {
        to = wfdbx::strtim(&argv[to as usize][..]);
        if to < 0 {
            to = -to;
        }
    }

    let tps = wfdbx::getiaorigfreq(0);
    if tps > 0.0 {
        wfdbx::setafreq(tps);
        wfdbx::setiafreq(0, tps);
        if legacy || sps > 0.0 {
            from = cstd::d2l(from as f64 * tps / sps + 0.5);
            to = cstd::d2l(to as f64 * tps / sps + 0.5);
        } else if from != 0 || to != 0 {
            // WFDB-x: no default sampling frequency
            ceprintf!(
                b"%s: sampling frequency of record %s is not specified (use -F)\n",
                pname,
                record
            );
            cstd::exit(1);
        }
    }

    // Build a linked list of annotations in memory (wfdbx::AnnList; WFDB-x:
    // it no longer loses annotations at time 0, except in legacy mode).
    let mut list = AnnList::with_legacy(legacy);
    while wfdbx::getann(0, &mut annot) == 0 {
        if annot.time < from || (to > 0 && annot.time >= to) {
            continue;
        }
        list.insert(&annot);
    }
    wfdbx::iannclose(0);

    if list.in_order() && ainame[1].is_none() {
        // If all of the annotations were in order, don't copy them unless
        // another annotator name was specified (using -o).
        ceprintf!(
            b"%s: input is already ordered -- no output written\n",
            pname
        );
        cstd::exit(0);
    }

    if from == 0 && to == 0 && ainame[1].is_none() {
        // in this case, we are processing the entire input file, and it's
        // acceptable to overwrite it
        ainame[1] = ainame[0];
    }

    let ai1 = [Anninfo {
        name: ainame[1].unwrap_or(b"").to_vec(),
        stat: WFDB_WRITE,
    }];
    if wfdbx::annopen(record, &ai1, 1) < 0 {
        // open output annotation file
        cstd::exit(2);
    }
    for a in list.iter().filter(|a| a.anntyp as i32 != NOTQRS) {
        wfdbx::putann(0, a);
    }
    wfdbx::wfdbquit();

    cstd::exit(0);
}
