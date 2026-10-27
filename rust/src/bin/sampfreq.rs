//! sampfreq: print the sampling frequency of a record (port of
//! `app/sampfreq.c`).
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Rust translation of app/sampfreq.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: none, apart from the language and the --legacy
// option (as the first argument, it restores the original behavior). Through
// the library, a record whose header gives no sampling frequency has the
// frequency 0, which is printed (the original printed 250); see
// docs/DIVERGENCES.md.
//
// Original C program: app/sampfreq.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1998-2012 George B. Moody.
// Rust translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

use wfdbx::cstd;
use wfdbx::{ceprintf, cprintf, Siginfo, NULL, WFDB_HIGHRES, WFDB_LOWRES};

fn help(pname: &[u8]) {
    ceprintf!(b"usage: %s [OPTION] RECORD\n", pname);
    ceprintf!(
        b"%s",
        " where RECORD is the name of the input record\n \
and OPTION may be either of:\n  \
-a   list all signals and their sampling frequencies\n  \
-h   show this help\n  \
-H   show the maximum sampling frequency of a multifrequency record)\n \
If no OPTION is used, show the base sampling frequency (frame rate).\n"
    );
}

fn main() {
    let mut argv = cstd::args();
    wfdbx::wfdbx_legacy_args(&mut argv); // wfdb-x: --legacy (original behavior)
    let pname = argv[0].clone();
    match argv.len() {
        1 => {
            help(&pname);
            cstd::exit(1);
        }
        2 => {
            cprintf!(b"%g\n", wfdbx::sampfreq(&argv[1]));
            cstd::exit(0);
        }
        3 if argv[1] == b"-a" || argv[1] == b"-H" => {
            let mut si: Vec<Siginfo> = Vec::new();
            let nsig = wfdbx::isigopen(&argv[2], &mut [], 0);
            if nsig > 0 {
                si = vec![Siginfo::default(); nsig as usize];
                wfdbx::isigopen(&argv[2], &mut si, nsig);
            }
            if argv[1][1] == b'H' {
                wfdbx::setgvmode(WFDB_HIGHRES);
                cprintf!(b"%g\n", wfdbx::sampfreq(NULL));
                cstd::exit(0);
            } else {
                wfdbx::setgvmode(WFDB_LOWRES);
                let freq = wfdbx::sampfreq(NULL);
                for s in si.iter().take(nsig.max(0) as usize) {
                    cprintf!(b"%s\t%g\n", s.desc, s.spf as f64 * freq);
                }
            }
        }
        _ => {}
    }
    // (The C program falls off the end of main; its exit status is 0.)
    cstd::exit(0);
}
