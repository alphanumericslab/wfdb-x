//! wfdbwhich: find a WFDB file and print its pathname (port of
//! `app/wfdbwhich.c`).
//
// Copyright (C) 1999 George B. Moody (original C program, app/wfdbwhich.c).
// Rust implementation part of wfdb-x, Reza Sameni, Oct 2026.
// GNU General Public License, version 2 or later (see LICENSE).

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
