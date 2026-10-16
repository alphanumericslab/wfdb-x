//! signum: print signal numbers for signals named as arguments (port of
//! `app/signum.c`).
//
// Copyright (C) 2008 George B. Moody (original C program, app/signum.c;
// revised 2021 by Benjamin Moody).
// Rust implementation part of wfdb-x, Reza Sameni, Oct 2026.
// GNU General Public License, version 2 or later (see LICENSE).

use wfdbx::cstd;
use wfdbx::{ceprintf, cprintf, Siginfo};

const HELP_STRINGS: &[&str] = &[
    "usage: %s -r RECORD [OPTIONS ...]\n",
    "where RECORD is the name of the input record, and OPTIONS may include:",
    " -h          print this usage summary",
    " -s SIGNAL [SIGNAL ...]  print signal number(s) for the specified signal(s)",
];

fn help(pname: &[u8]) {
    ceprintf!(HELP_STRINGS[0].as_bytes(), pname);
    for s in &HELP_STRINGS[1..] {
        ceprintf!(b"%s\n", *s);
    }
}

fn main() {
    let mut argv = cstd::args();
    wfdbx::wfdbx_legacy_args(&mut argv); // wfdb-x: --legacy (original behavior)
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
                    isiglist = i + 1; // index of 1st argument with a signal name
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
        Some(r) if isiglist != 0 => r,
        _ => {
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
    for arg in &argv[isiglist..isiglist + nosig] {
        let mut found = false;
        for (j, s) in si.iter().enumerate().take(nsig as usize) {
            if let Some(desc) = &s.desc {
                if cstd::cstr(arg) == cstd::cstr(desc) {
                    if found {
                        cprintf!(b"\t");
                    }
                    cprintf!(b"%d", j as i32);
                    found = true;
                }
            }
        }
        if !found {
            cprintf!(b"X");
        }
        cprintf!(b"\n");
    }
    wfdbx::wfdbquit();
    cstd::exit(0);
}
