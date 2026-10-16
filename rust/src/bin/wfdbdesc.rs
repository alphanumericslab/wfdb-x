//! wfdbdesc: describe signal specifications (port of `app/wfdbdesc.c`).
//!
//! This program is an expanded version of Example 5 in the WFDB
//! Programmer's Guide.
//
// Copyright (C) 1989-2012 George B. Moody (original C program, app/wfdbdesc.c;
// revised 2018-2020 by Benjamin Moody).
// Rust implementation part of wfdb-x, Reza Sameni, Oct 2026.
// Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
// gain, ADC resolution or units. Values that the record or the user does not
// give are never assumed (the original package assumed 250 Hz, 200 adu/mV,
// 12 bits and millivolts), because a silently assumed value corrupts every
// result derived from it. See docs/DIVERGENCES.md.
// GNU General Public License, version 2 or later (see LICENSE).

use wfdbx::cstd;
use wfdbx::{ceprintf, cprintf, Siginfo, NULL, WFDB_DEFGAIN, WFDB_LOWRES};

/// `%s` of a string that may be `NULL`.
fn str(s: &Option<Vec<u8>>) -> &[u8] {
    match s {
        Some(v) => cstd::cstr(v),
        None => b"(null)",
    }
}

/// The size of a regular file (C: `stat`, `fopen`, `fseek` to the end,
/// `ftell`), or `None`.
fn regular_file_size(name: &[u8]) -> Option<i64> {
    let path = cstd::bytes_to_path(name);
    let md = std::fs::metadata(&path).ok()?;
    if !md.is_file() {
        return None;
    }
    let mut f = wfdbx::WfdbFile::fopen(name, b"rb")?;
    if f.seek(0, cstd::SEEK_END) != 0 {
        return None;
    }
    let n = f.tell();
    f.close();
    Some(n)
}

fn main() {
    let mut argv = cstd::args();
    let legacy = wfdbx::wfdbx_legacy_args(&mut argv) != 0; // wfdb-x: --legacy
    let argc = argv.len();
    let pname = cstd::prog_name(&argv[0]).to_vec();
    let mut msrec = false;

    if argc < 2 {
        ceprintf!(b"usage: %s RECORD [-readable]\n", pname);
        cstd::exit(1);
    }
    // Discover the number of signals defined in the header.
    let mut nsig = wfdbx::isigopen(&argv[1], &mut [], 0);
    // (The C library's isigopen() removes a trailing ".hea" from its
    // argument in place, which changes the record name printed below.)
    let rec = wfdbx::wfdb_striphea(&argv[1]);
    if nsig < 0 {
        cstd::exit(2);
    }

    // Allocate storage for nsig signal information structures.
    let mut s: Vec<Siginfo> = vec![Siginfo::default(); nsig.max(0) as usize];

    // If the `-readable' option is given, report only on signals which can
    // be opened. Otherwise, report on all signals named in the header file,
    // without attempting to open them.
    if nsig > 0 && argc > 2 && b"-readable".starts_with(cstd::cstr(&argv[2])) {
        nsig = wfdbx::isigopen(&rec, &mut s, nsig);
    } else if nsig > 0 {
        nsig = wfdbx::isigopen(&rec, &mut s, -nsig);
    }
    cprintf!(b"Record %s", rec);
    wfdbx::setgvmode(WFDB_LOWRES);
    let mut t = wfdbx::strtim("e");
    if nsig > 0 && (s[0].fmt == 0 || s[0].nsamp != 0) && s[0].nsamp != t {
        msrec = true;
        cprintf!(
            b" (a %s-layout multi-segment record)\n",
            if s[0].nsamp == 0 { "variable" } else { "fixed" }
        );
        if s[0].nsamp != 0 {
            cprintf!(b"----------------------------------------------\n");
            cprintf!(b"The following data apply to the entire record:\n");
            cprintf!(b"----------------------------------------------");
        }
    }
    if let Some(mut info) = wfdbx::getinfo(&rec) {
        cprintf!(b"\nNotes\n=====\n");
        loop {
            cprintf!(b"%s\n", info);
            match wfdbx::getinfo(NULL) {
                Some(i) => info = i,
                None => break,
            }
        }
        cprintf!(b"=====\n");
    }
    // wfdb-x: if the sampling frequency is not specified, times are not
    // shown (the C program assumed 250 Hz). In legacy mode, the output is
    // that of the C program.
    let freq = wfdbx::sampfreq(NULL);
    let timed = freq > 0.0 || legacy;
    let p = if timed {
        wfdbx::mstimstr(0)
    } else {
        Vec::new()
    };
    cprintf!(
        b"\nStarting time: %s\n",
        if p.first() == Some(&b'[') {
            &p[..]
        } else {
            b"not specified"
        }
    );
    cprintf!(b"Length: ");
    if !timed && (nsig < 1 || t > 0) {
        cprintf!(b"%lld sample intervals\n", t);
    } else if nsig < 1 || t > 0 {
        let ts = if t > 0 {
            wfdbx::mstimstr(t)
        } else {
            b"0".to_vec()
        };
        cprintf!(b"%s (%lld sample intervals)\n", ts, t);
    } else {
        let size = match (&s[0].fname, s[0].fmt) {
            (Some(f), fmt) if fmt != 0 => regular_file_size(f),
            _ => None,
        };
        if let Some(size) = size {
            let mut framesize = 0i64;
            let nbytes = size - wfdbx::wfdbgetstart(0);
            for x in s.iter().take(nsig as usize) {
                if x.group != 0 {
                    break;
                }
                framesize += x.spf as i64;
            }
            // Frames in the file, from the bytes per sample of the format
            // (212 packs 2 samples in 3 bytes, 310 and 311 pack 3 in 4).
            t = match s[0].fmt {
                8 | 80 => nbytes / framesize,
                16 | 61 | 160 => nbytes / (2 * framesize),
                24 => nbytes / (3 * framesize),
                32 => nbytes / (4 * framesize),
                212 => (2 * nbytes) / (3 * framesize),
                310 | 311 => (3 * nbytes) / (4 * framesize),
                _ => -1,
            };
            if t >= 0 && !timed {
                cprintf!(b"%lld sample intervals [from signal file size]\n", t);
            } else if t >= 0 {
                cprintf!(
                    b"%s (%lld sample intervals) [from signal file size]\n",
                    wfdbx::mstimstr(t),
                    t
                );
            } else {
                cprintf!(b"not specified\n");
            }
        } else {
            cprintf!(b"not specified\n");
        }
    }
    if timed {
        cprintf!(b"Sampling frequency: %.12g Hz\n", freq);
    } else {
        cprintf!(b"Sampling frequency: not specified\n");
    }
    cprintf!(b"%d signal%s\n", nsig, if nsig == 1 { "" } else { "s" });
    if nsig < 1 {
        cstd::exit(2);
    }
    if msrec && s[0].nsamp != 0 {
        cprintf!(b"----------------------------------------------\n");
        cprintf!(b"The following data apply to the first segment:\n");
        cprintf!(b"----------------------------------------------\n");
        if timed {
            cprintf!(
                b"Segment length: %s (%ld sample intervals)\n",
                wfdbx::mstimstr(s[0].nsamp),
                s[0].nsamp
            );
        } else {
            cprintf!(b"Segment length: %ld sample intervals\n", s[0].nsamp);
        }
    }
    for (i, x) in s.iter().enumerate().take(nsig as usize) {
        cprintf!(b"Group %d, Signal %d:\n", x.group, i as i32);
        cprintf!(
            b" File: %s\n",
            if x.fmt != 0 { str(&x.fname) } else { b"[none]" }
        );
        cprintf!(b" Description: %s\n", str(&x.desc));
        cprintf!(b" Gain: ");
        if legacy {
            // wfdb-x: as in the C program (legacy mode)
            if x.gain == 0.0 {
                cprintf!(b"uncalibrated; assume %g", WFDB_DEFGAIN);
            } else {
                cprintf!(b"%.12g", x.gain);
            }
            cprintf!(
                b" adu/%s\n",
                x.units.as_deref().map_or(&b"mV"[..], cstd::cstr)
            );
        } else if x.gain == 0.0 {
            // wfdb-x: no default gain (C: "uncalibrated; assume 200")
            cprintf!(b"uncalibrated\n");
        } else {
            cprintf!(
                b"%.12g adu/%s\n",
                x.gain,
                match &x.units {
                    Some(u) => cstd::cstr(u),
                    // wfdb-x: unspecified units are shown as "nd" (C: mV)
                    None => b"nd",
                }
            );
        }
        cprintf!(b" Initial value: %d\n", x.initval);
        if x.fmt != 0 {
            cprintf!(b" Storage format: %d", x.fmt);
        }
        if x.spf > 1 {
            cprintf!(b" (%d samples per frame)", x.spf);
        }
        if x.fmt != 0 || x.spf > 1 {
            cprintf!(b"\n");
        }
        cprintf!(b" I/O: ");
        if x.bsize == 0 {
            cprintf!(b"can be unbuffered\n");
        } else {
            cprintf!(b"%d-byte blocks\n", x.bsize);
        }
        if x.adcres > 0 || legacy {
            cprintf!(b" ADC resolution: %d bits\n", x.adcres);
        } else {
            // wfdb-x: no default resolution
            cprintf!(b" ADC resolution: not specified\n");
        }
        cprintf!(b" ADC zero: %d\n", x.adczero);
        cprintf!(b" Baseline: %d\n", x.baseline);
        if x.nsamp > 0 {
            cprintf!(b" Checksum: %d\n", x.cksum);
        }
    }
    cstd::exit(0);
}
