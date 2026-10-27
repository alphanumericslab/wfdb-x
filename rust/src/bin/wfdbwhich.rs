//! wfdbwhich: find a WFDB file and print its pathname (port of
//! `app/wfdbwhich.c`).
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Rust translation of app/wfdbwhich.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: none, apart from the language and the --legacy
// option (as the first argument, it restores the original behavior). Through
// the library, the file is looked for only where it is named (the input
// directory, a full path or a URL), not by a search of the WFDB path; see
// docs/DIVERGENCES.md.
//
// Original C program: app/wfdbwhich.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1999 George B. Moody.
// Rust translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

use wfdbx::cstd;
use wfdbx::{ceprintf, cprintf, NULL};

fn main() {
    let mut argv = cstd::args();
    wfdbx::wfdbx_legacy_args(&mut argv); // wfdb-x: --legacy (original behavior)
    let mut argc = argv.len();
    let pname = cstd::prog_name(&argv[0]).to_vec();
    let mut status = 0;

    if argc == 2 && argv[1] == b"-h" {
        argc = 0; // give usage instructions and quit
    }
    match argc {
        2 => {
            if let Some(filename) = wfdbx::wfdbfile(&argv[1], NULL) {
                cprintf!(b"%s\n", filename);
            } else {
                ceprintf!(b"`%s' not found\n", argv[1]);
                ceprintf!(b"(WFDB path = %s)\n", wfdbx::getwfdb());
                status = 2;
            }
        }
        3 => {
            wfdbx::wfdbquiet();
            let _ = wfdbx::isigopen(&argv[2], &mut [], 0);
            if let Some(filename) = wfdbx::wfdbfile(&argv[1], &argv[2]) {
                cprintf!(b"%s\n", filename);
            } else {
                ceprintf!(
                    b"No file of type `%s' found for record `%s'\n",
                    argv[1],
                    argv[2]
                );
                ceprintf!(b"(WFDB path = %s)\n", wfdbx::getwfdb());
                status = 2;
            }
        }
        _ => {
            if argc != 4 || argv[1] != b"-r" {
                ceprintf!(b"usage: %s [-r RECORD ] FILENAME\n", pname);
                ceprintf!(b" -or-  %s FILE-TYPE RECORD\n", pname);
                status = 1;
            } else {
                let _ = wfdbx::isigopen(&argv[2], &mut [], 0);
                if let Some(filename) = wfdbx::wfdbfile(&argv[3], NULL) {
                    cprintf!(b"%s\n", filename);
                } else {
                    ceprintf!(b"`%s' not found\n", argv[3]);
                    ceprintf!(b"(WFDB path = %s)\n", wfdbx::getwfdb());
                    status = 2;
                }
            }
        }
    }
    cstd::exit(status);
}
