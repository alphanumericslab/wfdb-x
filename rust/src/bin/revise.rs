//! revise: convert obsolete-format header files into new ones (port of
//! `convert/revise.c`).
//!
//! Like the C program (which includes `<wfdb/wfdblib.h>`), this port opens
//! the old header with the library's internal `wfdb_open`. As in C, an
//! old-style header that describes exactly 32 signals is rejected (see
//! `docs/KNOWN_C_BEHAVIORS.md`).
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Rust translation of convert/revise.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: no built-in ADC resolution: a missing resolution
// stays unspecified (the original assumed 12 bits); --legacy, as the first
// argument, restores the original behavior. Each change is marked "wfdb-x:" in
// the code; docs/DIVERGENCES.md gives the reasons.
//
// Original C program: convert/revise.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1999 George B. Moody; revised 2018 by Benjamin Moody.
// Rust translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

use wfdbx::cstd::{self, Strtok};
use wfdbx::{ceprintf, cformat, Siginfo, WfdbFile, WFDB_DEFRES, WFDB_MAXSIG, WFDB_READ};

const SEP: &[u8] = b" \t\n";
const MAXSIG: usize = WFDB_MAXSIG as usize;

fn incorrect(record: &[u8]) -> i32 {
    wfdbx::wfdb_error(cformat!(
        b"init: incorrect format in record %s header\n",
        record
    ));
    -2
}

/// Size of C's line buffer.
const LINEBUFLEN: usize = 256;

/// Read the next line (C `fgets(linebuf, 256, iheader)`).
fn next_line(iheader: &mut WfdbFile, linebuf: &mut Vec<u8>) -> bool {
    iheader.fgets(linebuf, LINEBUFLEN)
}

/// Read an old-style header (the header file is left open, as in C).
fn readoldheader(
    record: &[u8],
    siarray: &mut [Siginfo],
    iheader_slot: &mut Option<WfdbFile>,
) -> i32 {
    let mut linebuf: Vec<u8> = Vec::new();
    let mut nsamples: i64 = 0;

    // Try to open the header file.
    let Some(ih) = wfdbx::wfdb_open("header", record, WFDB_READ) else {
        wfdbx::wfdb_error(cformat!(b"init: can't open header for record %s\n", record));
        return -1;
    };
    let iheader = iheader_slot.insert(ih);

    // Get the first token (the record name) from the first non-empty,
    // non-comment line.
    let first_line;
    loop {
        if !next_line(iheader, &mut linebuf) {
            wfdbx::wfdb_error(cformat!(
                b"init: can't find record name in record %s header\n",
                record
            ));
            return -2;
        }
        let line = cstd::cstr(&linebuf).to_vec();
        let mut tk = Strtok::new(&line);
        if let Some(p) = tk.next(SEP) {
            if p[0] != b'#' {
                let p = p.to_vec();
                let rest = tk.next(SEP).map(<[u8]>::to_vec);
                first_line = (p, rest);
                break;
            }
        }
    }
    let (p, rest) = first_line;
    if !iheader.is_std() && p != record {
        wfdbx::wfdb_error(cformat!(
            b"init: record name in record %s header is incorrect\n",
            record
        ));
        return -2;
    }

    // Identify which type of header file is being read by trying to get
    // another token from the line which contains the record name.
    // (Old-style headers have only one token on the first line, but
    // new-style headers have two or more.)
    if rest.is_some() {
        ceprintf!(
            b"The header for record %s appears not to be an old-style header.\n",
            record
        );
        return -2;
    }

    // The file appears to be an old-style header file.

    // Determine the number of signal groups.
    if !next_line(iheader, &mut linebuf) {
        return incorrect(record);
    }
    let line = cstd::cstr(&linebuf).to_vec();
    let Some(p) = Strtok::new(&line).next(SEP) else {
        return incorrect(record);
    };
    let ng = cstd::atoi(p) as u32;

    // Now get information for each signal group.
    let mut s: usize = 0;
    let mut g: u32 = 0;
    while g < ng {
        // Set the group number for the first signal in the group.
        siarray[s].group = g;

        // Get the signal file name.
        if !next_line(iheader, &mut linebuf) {
            return incorrect(record);
        }
        let line = cstd::cstr(&linebuf).to_vec();
        let Some(p) = Strtok::new(&line).next(SEP) else {
            return incorrect(record);
        };
        siarray[s].fname = Some(p.to_vec());

        // Determine the gain.
        if !next_line(iheader, &mut linebuf) {
            return incorrect(record);
        }
        let line = cstd::cstr(&linebuf).to_vec();
        let Some(p) = Strtok::new(&line).next(SEP) else {
            return incorrect(record);
        };
        siarray[s].gain = cstd::atof(p);

        // Determine the sampling frequency.
        if !next_line(iheader, &mut linebuf) {
            return incorrect(record);
        }
        let line = cstd::cstr(&linebuf).to_vec();
        let Some(p) = Strtok::new(&line).next(SEP) else {
            return incorrect(record);
        };
        let f = cstd::atof(p);
        if f <= 0.0 {
            return incorrect(record);
        }
        wfdbx::setsampfreq(f);

        // Determine the format, block size, and number of signals in this
        // group. In old-style headers these three quantities are encoded
        // into two fields.
        if !next_line(iheader, &mut linebuf) {
            return incorrect(record);
        }
        let line = cstd::cstr(&linebuf).to_vec();
        let mut tk = Strtok::new(&line);
        let Some(p) = tk.next(SEP) else {
            return incorrect(record);
        };
        let i = cstd::atoi(p) as u32;
        let mut mpx = tk.next(SEP).map_or(1, cstd::atoi);
        if mpx == 0 {
            mpx = 1;
        }
        if i != 8 && i != 16 {
            siarray[s].bsize = i as i32;
            if mpx < 0 {
                mpx = mpx.wrapping_neg();
                siarray[s].fmt = 8;
            } else {
                siarray[s].fmt = 16;
            }
        } else {
            siarray[s].fmt = i as i32;
            siarray[s].bsize = 0;
        }

        // Determine the ADC resolution.
        // wfdb-x: unspecified (0) if missing; C (and legacy mode) assumed
        // WFDB_DEFRES
        let dflt = if wfdbx::wfdbx_get_legacy() != 0 {
            WFDB_DEFRES
        } else {
            0
        };
        siarray[s].adcres = tk.next(SEP).map_or(dflt, cstd::atoi);

        // Determine the ADC zero.
        siarray[s].adczero = tk.next(SEP).map_or(0, cstd::atoi);

        // Determine the initial value.
        if !next_line(iheader, &mut linebuf) {
            return incorrect(record);
        }
        let line = cstd::cstr(&linebuf).to_vec();
        let mut tk = Strtok::new(&line);
        let Some(p) = tk.next(SEP) else {
            return incorrect(record);
        };
        siarray[s].initval = cstd::atoi(p);

        // Determine the number of samples.
        let ns = tk.next(SEP).map_or(0, cstd::atol);
        if ns < 0 {
            return incorrect(record);
        }
        if nsamples == 0 {
            nsamples = ns;
        } else if ns > 0 && ns != nsamples {
            wfdbx::wfdb_error(b"warning (init):\n");
            wfdbx::wfdb_error(cformat!(b" record %s durations are inconsistent\n", record));
            // nsamples must match the shortest record duration.
            if nsamples > ns {
                nsamples = ns;
            }
        }

        // Determine the checksum.
        if let Some(p) = tk.next(SEP) {
            siarray[s].cksum = cstd::atoi(p);
            siarray[s].nsamp = ns;
        } else {
            siarray[s].cksum = 0;
            siarray[s].nsamp = 0;
        }

        // If this signal group contains more than one signal, make
        // additional copies of the siginfo structure for the other signals.
        loop {
            s += 1;
            if s >= MAXSIG {
                break;
            }
            mpx -= 1;
            if mpx <= 0 {
                break;
            }
            siarray[s] = siarray[s - 1].clone();
        }

        if s == MAXSIG && (mpx > 0 || g < ng.wrapping_sub(1)) {
            wfdbx::wfdb_error(cformat!(b"init: too many signals in record %s\n", record));
            return -2;
        }
        g += 1;
    }

    // Now generate signal descriptions for each signal.
    for (i, si) in siarray.iter_mut().enumerate().take(s) {
        si.desc = Some(cformat!(b"record %s, signal %d", record, i as i32));
    }

    s as i32 // return number of available signals
}

fn main() {
    let mut argv = cstd::args();
    wfdbx::wfdbx_legacy_args(&mut argv); // wfdb-x: --legacy (original behavior)
    if argv.len() < 2 {
        ceprintf!(b"usage: %s record\n", argv[0]);
        ceprintf!(b" This program converts obsolete-format header files into new ones.\n");
        cstd::exit(1);
    }
    let mut record: &[u8] = cstd::cstr(&argv[1]);
    if let Some(r) = record.strip_prefix(b"header.") {
        record = r;
    }
    let record = record.to_vec();
    let mut si = vec![Siginfo::default(); MAXSIG];
    let mut iheader: Option<WfdbFile> = None;
    let nsig = readoldheader(&record, &mut si, &mut iheader);
    drop(iheader);
    if nsig < 0 {
        cstd::exit(2);
    }
    wfdbx::setheader(&record, &mut si, nsig as u32);
    cstd::exit(0);
}
