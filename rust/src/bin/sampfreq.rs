//! sampfreq: print the sampling frequency of a record (port of
//! `app/sampfreq.c`).
//
// Copyright (C) 1998-2012 George B. Moody (original C program,
// app/sampfreq.c).
// Rust implementation part of wfdb-x, Reza Sameni, Oct 2026.
// Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
// gain, ADC resolution or units. Values that the record or the user does not
// give are never assumed (the original package assumed 250 Hz, 200 adu/mV,
// 12 bits and millivolts), because a silently assumed value corrupts every
// result derived from it. See docs/DIVERGENCES.md.
// GNU General Public License, version 2 or later (see LICENSE).

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
