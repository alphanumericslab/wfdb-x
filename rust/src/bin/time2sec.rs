//! time2sec: convert a time interval to seconds (port of
//! `app/time2sec.c`).
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Rust translation of app/time2sec.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: none, apart from the language and the --legacy
// option (as the first argument, it restores the original behavior).
//
// Original C program: app/time2sec.c, WFDB Software Package 10.7.0.
//   Copyright (C) 2003-2009 George B. Moody.
// Rust translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

use wfdbx::{ceprintf, cprintf, cstd, NULL};

fn main() {
    let mut argv = cstd::args();
    wfdbx::wfdbx_legacy_args(&mut argv); // wfdb-x: --legacy (original behavior)
    let argc = argv.len();

    if argc == 4 && argv[1] == b"-r" {
        let _ = wfdbx::isigopen(&argv[2], &mut [], 0);
        let mut t = wfdbx::strtim(&argv[3]) as f64;
        if t < 0.0 {
            t = -t;
        }
        let mut seconds = cstd::d2l(t / wfdbx::sampfreq(NULL));
        t -= seconds as f64 * wfdbx::sampfreq(NULL);
        let mut milliseconds = cstd::d2l((t * 1000.) / wfdbx::sampfreq(NULL) + 0.5) as i32;
        if milliseconds >= 1000 {
            seconds += 1;
            milliseconds -= 1000;
        }
        cprintf!(b"%ld", seconds);
        if milliseconds != 0 {
            cprintf!(b".%03d", milliseconds);
        }
        cprintf!(b"\n");
        cstd::exit(0);
    } else if argc == 2 && argv[1].first() != Some(&b'-') {
        wfdbx::setsampfreq(1000.0);
        cprintf!(b"%.12g\n", wfdbx::strtim(&argv[1]) as f64 / 1000.0);
        cstd::exit(0);
    }

    ceprintf!(b"usage: %s [-r RECORD] TIME\n", argv[0]);
    ceprintf!(b" where TIME (in hh:mm:ss format) is a time interval\n");
    ceprintf!(b" to be converted into seconds.  Enclose TIME in\n");
    ceprintf!(b" square brackets (e.g., [9:0:0]) to convert a time\n");
    ceprintf!(b" of day to the elapsed time in seconds from the\n");
    ceprintf!(b" beginning of the (optionally) specified RECORD.\n");
    cstd::exit(1);
}
