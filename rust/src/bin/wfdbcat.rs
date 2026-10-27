//! wfdbcat: copy WFDB files to the standard output (port of
//! `app/wfdbcat.c`).
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Rust translation of app/wfdbcat.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: none, apart from the language and the --legacy
// option (as the first argument, it restores the original behavior). Through
// the library, each file is read from where it is named (the input directory,
// a full path or a URL), not found by a search of the WFDB path; see
// docs/DIVERGENCES.md.
//
// Original C program: app/wfdbcat.c, WFDB Software Package 10.7.0.
//   Copyright (C) 2000 George B. Moody; revised 2018 by Benjamin Moody.
// Rust translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

use wfdbx::cstd;
use wfdbx::{ceprintf, WFDB_READ};

const BUFSIZE: usize = 1024; // bytes read at a time

fn main() {
    let mut argv = cstd::args();
    wfdbx::wfdbx_legacy_args(&mut argv); // wfdb-x: --legacy (original behavior)
    let argc = argv.len();
    let pname = cstd::prog_name(&argv[0]).to_vec();
    let mut buf = [0u8; BUFSIZE];

    if argc < 2 || (argc == 2 && argv[1] == b"-h") {
        ceprintf!(b"usage: %s FILE [FILE ...]\n", pname);
        cstd::exit(1);
    }

    for arg in &argv[1..] {
        match wfdbx::wfdb_open(arg, wfdbx::NULL, WFDB_READ) {
            None => {
                cstd::flush_stdout();
                ceprintf!(b"%s: `%s' not found\n", pname, arg);
            }
            Some(mut ifile) => {
                loop {
                    let n = ifile.read(&mut buf);
                    if n == 0 {
                        break;
                    }
                    let mut out = cstd::out();
                    out.write(&buf[..n]);
                    if out.error() {
                        break;
                    }
                }
                ifile.close();
            }
        }
    }

    cstd::exit(0);
}
