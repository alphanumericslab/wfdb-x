//! rdann: print an annotation file in ASCII form (port of `app/rdann.c`).
//!
//! Caution: if the output format of `rdann` is modified, `wrann` will
//! require modification as well!
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Rust translation of app/rdann.c from the WFDB Software Package
// 10.7.0, by T. Baker and George B. Moody. The translation follows the logic
// and behavior of the original program, but it is new code, not the original C
// code.
//
// Changes from the original: no built-in sampling frequency: the new option -F
// FREQ gives it when the record has no header or its header gives none, and is
// then required (the original assumed 250 Hz); --legacy, as the first
// argument, restores the original behavior. Each change is marked "wfdb-x:" in
// the code; docs/DIVERGENCES.md gives the reasons.
//
// Original C program: app/rdann.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1981-2010 George B. Moody; revised 2017-2018 by
//   Benjamin Moody.
// Rust translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

use wfdbx::cstd::{self, d2l};
use wfdbx::{ceprintf, cprintf, csscanf, Anninfo, Annotation, ACMAX, WFDB_DEFFREQ, WFDB_READ};

const HELP_STRINGS: &[&[u8]] = &[
    b"usage: %s -r RECORD -a ANNOTATOR [OPTIONS ...]\n",
    b"where RECORD and ANNOTATOR specify the input, and OPTIONS may include:",
    b" -c CHAN             print annotations with specified CHAN only",
    b" -e                  * show annotation times as elapsed times",
    b" -f TIME             start at specified TIME",
    b" -F FREQ             sampling frequency, if the record header does not",
    b"                      specify one",
    b" -h                  print this usage summary",
    b" -n NUM              print annotations with specified NUM only",
    b" -p TYPE [TYPE ...]  print annotations of specified TYPEs only",
    b" -s SUBTYPE          print annotations with specified SUBTYPE only",
    b" -t TIME             stop at specified TIME",
    b" -v                  print column headings",
    b" -x                  * use alternate time format (seconds, minutes, hours)",
    b"* Only one of -e and -x can be used.",
];

/// wfdb-x: the lines of `HELP_STRINGS` added by WFDB-x, left out of the
/// help text of the original program (printed in legacy mode).
const WFDBX_HELP_LINES: &[&[u8]] = &[
    b" -F FREQ             sampling frequency, if the record header does not",
    b"                      specify one",
];

fn help(pname: &[u8]) {
    let legacy = wfdbx::wfdbx_get_legacy() != 0;
    ceprintf!(HELP_STRINGS[0], pname);
    for s in &HELP_STRINGS[1..] {
        if !(legacy && WFDBX_HELP_LINES.contains(s)) {
            ceprintf!(b"%s\n", s);
        }
    }
}

fn isann(code: i32) -> bool {
    wfdbx::isann(code) != 0
}

fn main() {
    let mut argv = cstd::args();
    let legacy = wfdbx::wfdbx_legacy_args(&mut argv) != 0; // wfdb-x: --legacy
    let argc = argv.len();
    let pname = cstd::prog_name(&argv[0]).to_vec();
    let arg = |i: usize| -> &[u8] { &argv[i] };
    let c0 = |i: usize| -> u8 { argv[i].first().copied().unwrap_or(0) };
    let c1 = |i: usize| -> u8 { argv[i].get(1).copied().unwrap_or(0) };

    let mut ffreq = 0.0f64; // -F (WFDB-x)
    let mut record: Option<&[u8]> = None;
    let mut ainame: Option<&[u8]> = None;
    let (mut cflag, mut chanmatch, mut nflag, mut nummatch, mut sflag, mut submatch) =
        (false, 0i8, false, 0i8, false, 0i8);
    let (mut eflag, mut vflag, mut xflag) = (false, false, false);
    let (mut anum, mut ato, mut bnum, mut bto) = (0i64, 0i64, 0i64, 0i64);
    let (mut from, mut to): (i64, i64) = (0, 0);
    let mut flag = [false; ACMAX as usize + 1];
    let mut annot = Annotation::default();
    let mut i: usize;

    // Accept old syntax.
    if argc >= 3 && c0(1) != b'-' {
        ainame = Some(arg(1));
        record = Some(arg(2));
        i = 3;
        if argc > 3 {
            from = 3;
            i = 4;
        }
        if argc > 4 {
            to = 4;
            i = 5;
        }
        if argc <= 5 {
            flag[0] = true;
        } else {
            while i < argc && c0(i) != b'-' {
                let j = wfdbx::strann(arg(i));
                if isann(j) {
                    flag[j as usize] = true;
                }
                i += 1;
            }
        }
    } else {
        i = 1;
        flag[0] = true;
    }

    // Interpret command-line options.
    while i < argc {
        if c0(i) == b'-' {
            match c1(i) {
                b'a' => {
                    // annotator follows
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: annotator must follow -a\n", pname);
                        cstd::exit(1);
                    }
                    ainame = Some(arg(i));
                }
                b'c' => {
                    // chan value follows
                    i += 1;
                    if i >= argc {
                        ceprintf!(
                            b"%s: chan value (between -128 and 127) must follow -c\n",
                            pname
                        );
                        cstd::exit(1);
                    }
                    chanmatch = cstd::atoi(arg(i)) as i8;
                    cflag = true;
                }
                b'e' => {
                    // show elapsed time
                    eflag = true;
                    xflag = false;
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
                    if i >= argc || csscanf!(arg(i), b"%lf", &mut ffreq) != 1 || ffreq <= 0.0 {
                        ceprintf!(b"%s: sampling frequency (> 0) must follow -F\n", pname);
                        cstd::exit(1);
                    }
                }
                b'h' => {
                    // print usage summary and quit
                    help(&pname);
                    cstd::exit(0);
                }
                b'n' => {
                    // num value follows
                    i += 1;
                    if i >= argc {
                        ceprintf!(
                            b"%s: num value (between -128 and 127) must follow -n\n",
                            pname
                        );
                        cstd::exit(1);
                    }
                    nummatch = cstd::atoi(arg(i)) as i8;
                    nflag = true;
                }
                b'p' => {
                    // annotation mnemonic(s) follow
                    i += 1;
                    let j = if i < argc { wfdbx::strann(arg(i)) } else { 0 };
                    if i >= argc || !isann(j) {
                        ceprintf!(b"%s: annotation mnemonic(s) must follow -p\n", pname);
                        cstd::exit(1);
                    }
                    flag[j as usize] = true;
                    // Pick up any other mnemonics (arguments beginning with
                    // `-' are assumed to be options, not mnemonics).
                    i += 1;
                    while i < argc && c0(i) != b'-' {
                        let j = wfdbx::strann(arg(i));
                        if isann(j) {
                            flag[j as usize] = true;
                        }
                        i += 1;
                    }
                    if i == argc || c0(i) == b'-' {
                        i -= 1;
                    }
                    flag[0] = false;
                }
                b'r' => {
                    // input record name follows
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: input record name must follow -r\n", pname);
                        cstd::exit(1);
                    }
                    record = Some(arg(i));
                }
                b's' => {
                    // subtyp value follows
                    i += 1;
                    if i >= argc {
                        ceprintf!(
                            b"%s: subtyp value (between -128 and 127) must follow -s\n",
                            pname
                        );
                        cstd::exit(1);
                    }
                    submatch = cstd::atoi(arg(i)) as i8;
                    sflag = true;
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
                b'v' => vflag = true, // show column headings
                b'x' => {
                    // use alternate time format
                    xflag = true;
                    eflag = false;
                }
                _ => {
                    ceprintf!(b"%s: unrecognized option %s\n", pname, arg(i));
                    cstd::exit(1);
                }
            }
        } else {
            ceprintf!(b"%s: unrecognized argument %s\n", pname, arg(i));
            cstd::exit(1);
        }
        i += 1;
    }
    let (Some(record), Some(ainame)) = (record, ainame) else {
        help(&pname);
        cstd::exit(1);
    };

    // wfdb-x: no default sampling frequency (the C program assumed 250 Hz if
    // the record had no header); -F specifies one.
    let mut sps = wfdbx::sampfreq(record);
    if legacy {
        // wfdb-x: legacy mode (original behavior)
        if sps < 0.0 {
            sps = WFDB_DEFFREQ;
            wfdbx::setsampfreq(sps);
        }
    } else if sps <= 0.0 && ffreq > 0.0 {
        sps = ffreq;
        wfdbx::setsampfreq(sps);
    }
    if !legacy && sps <= 0.0 {
        ceprintf!(
            b"%s: sampling frequency of record %s is not specified (use -F)\n",
            pname,
            record
        );
        cstd::exit(1);
    }

    let ai = [Anninfo {
        name: ainame.to_vec(),
        stat: WFDB_READ,
    }];
    if wfdbx::annopen(record, &ai, 1) < 0 {
        // open annotation file
        cstd::exit(2);
    }

    let mut tps = wfdbx::getiaorigfreq(0);
    if tps < sps {
        tps = sps;
    }

    // Decimal places of the times in seconds, minutes and hours printed by
    // -x: enough to resolve a tick, and at least those of a millisecond.
    let mut sprec = 3;
    let mut n = 1000.0;
    while n < tps {
        sprec += 1;
        n *= 10.0;
    }

    let tpm = 60.0 * tps;
    let mut mprec = 5;
    n = 100000.0;
    while n < tpm {
        mprec += 1;
        n *= 10.0;
    }

    let tph = 60.0 * tpm;
    let mut hprec = 7;
    n = 10000000.0;
    while n < tph {
        hprec += 1;
        n *= 10.0;
    }

    if from != 0 {
        let fs = arg(from as usize);
        match fs.first().copied().unwrap_or(0) {
            b'a' => {
                let mut afrom = cstd::atol(&fs[1..]);
                if afrom < 0 {
                    afrom = 0;
                }
                while anum < afrom && wfdbx::getann(0, &mut annot) == 0 {
                    anum += 1;
                    if wfdbx::isqrs(annot.anntyp as i32) != 0 {
                        bnum += 1;
                    }
                }
                if anum < afrom {
                    cstd::exit(2);
                }
            }
            b'b' | b'#' => {
                let mut bfrom = cstd::atol(&fs[1..]);
                if bfrom < 0 {
                    bfrom = 0;
                }
                while bnum < bfrom && wfdbx::getann(0, &mut annot) == 0 {
                    anum += 1;
                    if wfdbx::isqrs(annot.anntyp as i32) != 0 {
                        bnum += 1;
                    }
                }
                if bnum < bfrom {
                    cstd::exit(2);
                }
            }
            _ => {
                if wfdbx::iannsettime(wfdbx::strtim(fs)) < 0 {
                    cstd::exit(2);
                }
            }
        }
    }
    if to != 0 {
        let ts = arg(to as usize);
        match ts.first().copied().unwrap_or(0) {
            b'a' => {
                ato = cstd::atol(&ts[1..]);
                if ato < 0 {
                    ato = 0;
                }
                bto = 0;
                to = 0;
            }
            b'b' => {
                bto = cstd::atol(&ts[1..]);
                if bto < 0 {
                    bto = 0;
                }
                ato = 0;
                to = 0;
            }
            b'#' => {
                bto = cstd::atol(&ts[1..]);
                if bto < 1 {
                    bto = 1;
                }
                bto += bnum;
                ato = 0;
                to = 0;
            }
            _ => {
                ato = 0;
                bto = 0;
                to = wfdbx::strtim(ts);
                if to < 0 {
                    to = -to;
                }
            }
        }
    }

    if vflag {
        // print column headings
        if eflag {
            cprintf!(b"Elapsed time  Sample #  ");
        } else if xflag {
            cprintf!(b"  Seconds   Minutes     Hours  ");
        } else {
            let m = wfdbx::mstimstr(-1);
            if m.contains(&b'/') {
                cprintf!(b"      Time       Date     Sample #  ");
            } else if m.first() == Some(&b'[') {
                cprintf!(b"      Time     Sample #  ");
            } else {
                cprintf!(b"      Time   Sample #  ");
            }
        }
        cprintf!(b"Type  Sub Chan  Num\tAux\n");
    }

    wfdbx::setifreq(tps);
    wfdbx::setiafreq(0, tps);
    while wfdbx::getann(0, &mut annot) == 0 {
        let sample_num = if tps == sps {
            annot.time
        } else {
            let x = annot.time as f64 * sps / tps + 0.5;
            let mut s = d2l(x);
            if s as f64 > x {
                s -= 1;
            }
            s
        };
        if to != 0 && sample_num > to {
            break;
        }
        let a = annot.anntyp as i32;
        if (flag[0] || (isann(a) && flag[a as usize]))
            && (!cflag || annot.chan as i32 == chanmatch as i32)
            && (!nflag || annot.num == nummatch)
            && (!sflag || annot.subtyp == submatch)
        {
            if eflag {
                cprintf!(b"%s  %7lld", wfdbx::mstimstr(annot.time), sample_num);
            } else if xflag {
                cprintf!(
                    b"%*.*f %*.*f %*.*f",
                    sprec + 6,
                    sprec,
                    annot.time as f64 / tps,
                    mprec + 4,
                    mprec,
                    annot.time as f64 / tpm,
                    hprec + 2,
                    hprec,
                    annot.time as f64 / tph
                );
            } else {
                cprintf!(b"%s  %7lld", wfdbx::mstimstr(-annot.time), sample_num);
            }
            cprintf!(
                b"%6s%5d%5d%5d",
                wfdbx::annstr(a),
                annot.subtyp as i32,
                annot.chan as i32,
                annot.num as i32
            );
            if let Some(aux) = &annot.aux {
                cprintf!(b"\t%s", cstd::cstr(aux.get(1..).unwrap_or(b"")));
            }
            cprintf!(b"\n");
        }
        if ato != 0 {
            anum += 1;
            if anum >= ato {
                break;
            }
        }
        if bto != 0 && wfdbx::isqrs(a) != 0 {
            bnum += 1;
            if bnum >= bto {
                break;
            }
        }
    }
    cstd::exit(0);
}
