//! wfdbtime: convert between times and sample numbers (port of
//! `app/wfdbtime.c`).
//
// Copyright (C) 2001 George B. Moody (original C program, app/wfdbtime.c;
// revised 2017-2018 by Benjamin Moody).
// Rust implementation part of wfdb-x, Reza Sameni, Oct 2026.
// Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
// gain, ADC resolution or units. Values that the record or the user does not
// give are never assumed (the original package assumed 250 Hz, 200 adu/mV,
// 12 bits and millivolts), because a silently assumed value corrupts every
// result derived from it. See docs/DIVERGENCES.md.
// GNU General Public License, version 2 or later (see LICENSE).

use wfdbx::{ceprintf, cformat, cprintf, cstd};

fn main() {
    let mut argv = cstd::args();
    let legacy = wfdbx::wfdbx_legacy_args(&mut argv) != 0; // wfdb-x: --legacy
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
                // wfdb-x: no default sampling frequency (except in legacy mode)
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
