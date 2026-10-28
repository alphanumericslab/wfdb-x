//! signame: print signal names for signal numbers given as arguments (port
//! of `app/signame.c`).
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Rust translation of app/signame.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: none, apart from the language and the --legacy
// option (as the first argument, it restores the original behavior).
//
// Original C program: app/signame.c, WFDB Software Package 10.7.0.
//   Copyright (C) 2008 George B. Moody.
// Rust translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

use wfdbx::cstd;
use wfdbx::{ceprintf, cprintf, Siginfo};

const HELP_STRINGS: &[&str] = &[
    "usage: %s -r RECORD [OPTIONS ...]\n",
    "where RECORD is the name of the input record, and OPTIONS may include:",
    " -h          print this usage summary",
    " -s SIGNAL [SIGNAL ...]  print signal name(s) for the specified signal(s)",
    "If no -s option is given, the names of all signals in the record are output.",
];

fn help(pname: &[u8]) {
    ceprintf!(HELP_STRINGS[0].as_bytes(), pname);
    for s in &HELP_STRINGS[1..] {
        ceprintf!(b"%s\n", *s);
    }
}

/// `%s` of a string that may be `NULL`.
fn str(s: &Option<Vec<u8>>) -> &[u8] {
    match s {
        Some(v) => cstd::cstr(v),
        None => b"(null)",
    }
}

fn main() {
    let mut argv = cstd::args();
    wfdbx::wfdbx_legacy_args(&mut argv); // WFDB-x: --legacy (original behavior)
    let argc = argv.len();
    let pname = cstd::prog_name(&argv[0]).to_vec();
    let mut record: Option<&[u8]> = None;
    let mut isiglist = 0;
    let mut nosig = 0;

    let mut i = 1;
    while i < argc {
        if argv[i].first() == Some(&b'-') {
            match argv[i].get(1).copied().unwrap_or(0) {
                b'h' => {
                    // help requested
                    help(&pname);
                    cstd::exit(0);
                }
                b'r' => {
                    // record name
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: record name must follow -r\n", pname);
                        cstd::exit(1);
                    }
                    record = Some(&argv[i]);
                }
                b's' => {
                    // signal list follows
                    isiglist = i + 1; // index of 1st argument with a signal #
                    while i + 1 < argc && argv[i + 1].first() != Some(&b'-') {
                        i += 1;
                        nosig += 1; // number of elements in signal list
                    }
                    if nosig == 0 {
                        ceprintf!(b"%s: signal list must follow -s\n", pname);
                        cstd::exit(1);
                    }
                }
                _ => {
                    ceprintf!(b"%s: unrecognized option %s\n", pname, argv[i]);
                    cstd::exit(1);
                }
            }
        } else {
            ceprintf!(b"%s: unrecognized argument %s\n", pname, argv[i]);
            cstd::exit(1);
        }
        i += 1;
    }
    let record = match record {
        Some(r) => r,
        None => {
            help(&pname);
            cstd::exit(1);
        }
    };
    let mut nsig = wfdbx::isigopen(record, &mut [], 0);
    if nsig <= 0 {
        cstd::exit(2);
    }
    let mut si = vec![Siginfo::default(); nsig as usize];
    nsig = wfdbx::isigopen(record, &mut si, -nsig);
    if nsig <= 0 {
        cstd::exit(2);
    }
    if isiglist != 0 {
        for arg in &argv[isiglist..isiglist + nosig] {
            let j = cstd::atoi(arg);
            // (The C program also accepts j == nsig, reading past the end of
            // its array; see `docs/KNOWN_C_BEHAVIORS.md`.)
            let p: &[u8] = if 0 <= j && j < nsig {
                str(&si[j as usize].desc)
            } else {
                b"[INVALID]"
            };
            cprintf!(b"%s\n", p);
        }
    } else {
        for s in si.iter().take(nsig as usize) {
            cprintf!(b"%s\n", str(&s.desc));
        }
    }
    wfdbx::wfdbquit();
    cstd::exit(0);
}
