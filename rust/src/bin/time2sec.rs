//! time2sec: convert a time interval to seconds (port of
//! `app/time2sec.c`).
//
// Copyright (C) 2003-2009 George B. Moody (original C program,
// app/time2sec.c).
// Rust implementation part of wfdb-x, Reza Sameni, Oct 2026.
// GNU General Public License, version 2 or later (see LICENSE).

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
