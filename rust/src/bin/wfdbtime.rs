//! wfdbtime: convert between times and sample numbers (port of
//! `app/wfdbtime.c`).
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Rust translation of app/wfdbtime.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: no built-in sampling frequency: the record must
// give it (the original assumed 250 Hz); --legacy, as the first argument,
// restores the original behavior. Each change is marked "WFDB-x:" in the code;
// docs/DIVERGENCES.md gives the reasons.
//
// Original C program: app/wfdbtime.c, WFDB Software Package 10.7.0.
//   Copyright (C) 2001 George B. Moody; revised 2017-2018 by Benjamin Moody.
// Rust translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

use wfdbx::{ceprintf, cformat, cprintf, cstd};

fn main() {
    let mut argv = cstd::args();
    let legacy = wfdbx::wfdbx_legacy_args(&mut argv) != 0; // WFDB-x: --legacy
    let argc = argv.len();
    let mut record: Option<&[u8]> = None;

    let mut i = 1;
    while i < argc {
        if argv[i] == b"-r" {
            if record.is_some() {
                wfdbx::wfdbquit();
            }
            i += 1;
            if i == argc {
                break;
            }
            record = Some(&argv[i]);
            if wfdbx::isigopen(&argv[i], &mut [], 0) < 0 {
                cstd::exit(2);
            }
            if !legacy && wfdbx::sampfreq(wfdbx::NULL) <= 0.0 {
                // WFDB-x: no default sampling frequency (except in legacy mode)
                ceprintf!(
                    b"%s: sampling frequency of record %s is not specified\n",
                    argv[0],
                    argv[i]
                );
                cstd::exit(2);
            }
        } else if record.is_some() {
            let mut t = wfdbx::strtim(&argv[i]);
            if t < 0 {
                t = t.wrapping_neg();
            }
            let sbuf = cformat!(b"s%lld", t);
            // (C: snprintf into a 32-byte buffer; at most 31 bytes are kept.)
            let sbuf = &sbuf[..sbuf.len().min(31)];
            let ts = if t == 0 {
                b"0:00.000".to_vec()
            } else {
                wfdbx::mstimstr(t)
            };
            cprintf!(b"%15s\t%15s", sbuf, ts);
            cprintf!(b"\t%15s\n", wfdbx::mstimstr(t.wrapping_neg()));
        }
        i += 1;
    }
    if record.is_none() {
        ceprintf!(b"usage: %s [ -r RECORD [ TIME ] ]\n", argv[0]);
        ceprintf!(b" where RECORD is the name of the input record\n");
        ceprintf!(b" Each TIME is a time to be converted\n");
        cstd::exit(1);
    }
    wfdbx::wfdbquit();
    cstd::exit(0);
}
