//! wfdbcat: copy WFDB files (found in the WFDB path) to the standard
//! output (port of `app/wfdbcat.c`).
//
// Copyright (C) 2000 George B. Moody (original C program, app/wfdbcat.c;
// revised 2018 by Benjamin Moody).
// Rust implementation part of wfdb-x, Reza Sameni, Oct 2026.
// GNU General Public License, version 2 or later (see LICENSE).

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
