//! edf2mit: convert EDF (European Data Format) file to MIT format header
//! and signal files (port of `convert/edf2mit.c`).
//!
//! As in the C program, the header fields are read into one reusable
//! 81-byte buffer, so a 16-character signal label is followed by a space
//! and by the bytes that remain in the buffer from earlier fields (see
//! `docs/KNOWN_C_BEHAVIORS.md`). Where the C program has undefined behavior,
//! this port uses: 0 for header fields that cannot be parsed and are left
//! uninitialized in C; the characters of the input file name only (not the
//! bytes beyond its end) for the default record name; 0 for samples beyond
//! the end of a data record (if the samples per frame do not divide the
//! samples per record); 0 frames per record if a signal has 0 samples per
//! frame; and `INT_MIN` for out-of-range conversions of doubles to int (as on
//! x86).
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Rust translation of convert/edf2mit.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: none, apart from the language and the --legacy
// option (as the first argument, it restores the original behavior).
//
// Original C program: convert/edf2mit.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1996-2004 George B. Moody.
// Rust translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

use wfdbx::cstd::{self, d2i};
use wfdbx::{ceprintf, cformat, cprintf, csscanf, Siginfo, WfdbFile, WFDB_MAXRNL};

const HELP_STRINGS: &[&[u8]] = &[
    b"usage: %s [OPTIONS ...]\n",
    b"where OPTIONS may include:",
    b" -b          input is in big-endian byte order (default: little-endian)",
    b" -h          print this usage summary",
    b" -i EDFILE   read the specified European Data Format file",
    b" -r RECORD   create the specified RECORD (default: input file name without",
    b"              suffix)",
    b" -s SIGNAL [SIGNAL ...]  copy only the specified signal(s) (use signal",
    b"              numbers, beginning with zero;  default: copy all signals)",
    b" -v          print debugging output",
    b"This program reads an EDF file and creates MIT-format signal and header",
    b"files containing the same data.",
];

fn help(pname: &[u8]) {
    ceprintf!(HELP_STRINGS[0], pname);
    for s in &HELP_STRINGS[1..] {
        ceprintf!(b"%s\n", s);
    }
}

/// Calculate the greatest common divisor of x and y. This function uses
/// Euclid's algorithm, modified so that an exact answer is not required if
/// the (possibly non-integral) arguments do not have a common divisor that
/// can be represented exactly.
fn gcd(mut x: f64, mut y: f64) -> f64 {
    let tol = if x > y { 0.001 * y } else { 0.001 * x }; // relative tolerance 0.1%
    loop {
        if x > y && x - y > tol {
            x -= y;
        } else if y > x && y - x > tol {
            y -= x;
        } else {
            return x;
        }
    }
}

/// Length of the longest EDF header field.
const MAXFIELD: usize = 80;

/// The reusable header field buffer of the C program (the longest field
/// and a NUL).
struct Field {
    buf: [u8; MAXFIELD + 1],
}

impl Field {
    /// Read a header field of n bytes into buf, mark its end with a space,
    /// and replace trailing spaces (from `buf[t]` backward) with NULs.
    /// Returns the index of the last non-space character (or -1).
    fn read(&mut self, ifile: &mut WfdbFile, n: usize, t: usize) -> i32 {
        ifile.fread(&mut self.buf[..n], 1, n);
        self.buf[n] = b' ';
        let mut jj = t as i32;
        while jj >= 0 && self.buf[jj as usize] == b' ' {
            self.buf[jj as usize] = 0;
            jj -= 1;
        }
        jj
    }

    /// The buffer as a C string.
    fn s(&self) -> &[u8] {
        cstd::cstr(&self.buf)
    }
}

fn main() {
    let mut argv = cstd::args();
    wfdbx::wfdbx_legacy_args(&mut argv); // wfdb-x: --legacy (original behavior)
    let argc = argv.len();
    let pname = argv[0].clone();
    let mut record: Vec<u8> = Vec::new();
    let mut ifile: Option<WfdbFile> = None;
    let mut big_endian = false;
    let mut vflag = false;
    let mut nsig: i32 = 0;
    let (mut day, mut month, mut year) = (0i32, 0i32, 0i32);
    let (mut hour, mut minute, mut second) = (0i32, 0i32, 0i32);
    let mut spr: f64 = 0.0;
    let mut siglist: Vec<i32> = Vec::new();

    let mut i = 1;
    while i < argc {
        if argv[i].first() == Some(&b'-') {
            match argv[i].get(1).copied().unwrap_or(0) {
                b'b' => big_endian = true, // input is in big-endian byte order
                b'h' => {
                    // show usage and quit
                    help(&pname);
                    cstd::exit(0);
                }
                b'i' => {
                    // file name follows
                    i += 1;
                    if i < argc {
                        if cstd::cstr(&argv[i]) == b"-" {
                            ifile = Some(WfdbFile::stdin());
                        } else {
                            let Some(f) = WfdbFile::fopen(&argv[i], b"rb") else {
                                ceprintf!(b"%s: can't read %s\n", pname, argv[i]);
                                cstd::exit(1);
                            };
                            ifile = Some(f);
                            if record.is_empty() {
                                for &c in cstd::cstr(&argv[i]).iter().take(WFDB_MAXRNL) {
                                    if c.is_ascii_alphanumeric() {
                                        record.push(c);
                                    } else if c == b'.' {
                                        break;
                                    } else {
                                        record.push(b'_');
                                    }
                                }
                            }
                        }
                    }
                }
                b'r' => {
                    // record name follows
                    i += 1;
                    if i < argc {
                        let r = cstd::cstr(&argv[i]);
                        record = r[..r.len().min(WFDB_MAXRNL)].to_vec();
                    } else {
                        ceprintf!(b"%s: record name must follow -r\n", pname);
                        cstd::exit(1);
                    }
                }
                b's' => {
                    // signal list follows
                    // count the number of output signals
                    let mut j = 0;
                    loop {
                        i += 1;
                        if !(i < argc && argv[i].first() != Some(&b'-')) {
                            break;
                        }
                        j += 1;
                    }
                    if j == 0 {
                        ceprintf!(b"%s: signal list must follow -s\n", pname);
                        cstd::exit(1);
                    }
                    // fill the signal list
                    i -= j;
                    while i < argc && argv[i].first() != Some(&b'-') {
                        siglist.push(cstd::atoi(&argv[i]));
                        i += 1;
                    }
                    i -= 1;
                }
                b'v' => vflag = true, // select verbose mode
                _ => {}
            }
        }
        i += 1;
    }
    let mut nosig = siglist.len();

    let Some(mut ifile) = ifile else {
        help(&pname);
        cstd::exit(1);
    };

    if record.is_empty() || wfdbx::newheader(&record) < 0 {
        ceprintf!(b"\n");
        help(&pname);
        ceprintf!(
            b"\nRun %s again, specifying a valid name for the output record,\n",
            argv[0]
        );
        ceprintf!(b"using the -r option as described above.\n\n");
        ceprintf!(b"  Valid record names may include letters, digits, and underscores only.\n");
        cstd::exit(1);
    }

    let mut f = Field {
        buf: [0; MAXFIELD + 1],
    };

    ifile.fread(&mut f.buf[..8], 1, 8);
    // Check to see that the input is an EDF file. (This check will detect
    // most but not all other types of files.)
    if &f.buf[..8] != b"0       " {
        ceprintf!(
            b"%s: input does not appear to be EDF -- no conversion attempted.\n",
            pname
        );
        cstd::exit(2);
    }
    f.buf[8] = b' ';
    let mut j: i32 = 8;
    while j >= 0 && f.buf[j as usize] == b' ' {
        f.buf[j as usize] = 0;
        j -= 1;
    }
    if vflag {
        cprintf!(b"EDF version number: '%s'\n", f.s());
    }

    f.read(&mut ifile, 80, 80);
    if vflag {
        cprintf!(b"Patient ID: '%s'\n", f.s());
    }

    f.read(&mut ifile, 80, 80);
    if vflag {
        cprintf!(b"Recording ID: '%s'\n", f.s());
    }

    f.read(&mut ifile, 8, 8);
    if vflag {
        cprintf!(b"Recording date: '%s'\n", f.s());
    }
    csscanf!(f.s(), b"%d%*c%d%*c%d", &mut day, &mut month, &mut year);
    if year < 1970 {
        year += 1900;
    }
    if year < 1970 {
        year += 100; // should work for a while
    }

    f.read(&mut ifile, 8, 8);
    if vflag {
        cprintf!(b"Recording time: '%s'\n", f.s());
    }
    csscanf!(f.s(), b"%d%*c%d%*c%d", &mut hour, &mut minute, &mut second);

    f.read(&mut ifile, 8, 8);
    if vflag {
        cprintf!(b"Number of bytes in header record: '%s'\n", f.s());
    }

    let j = f.read(&mut ifile, 44, 44);
    if j > 0 && vflag {
        cprintf!(b"Free space: '%s'\n", f.s());
    }

    f.read(&mut ifile, 8, 8);
    if vflag {
        cprintf!(b"Number of data records: '%s'\n", f.s());
    }

    f.read(&mut ifile, 8, 8);
    if vflag {
        cprintf!(b"Duration of each data record in seconds: '%s'\n", f.s());
    }
    csscanf!(f.s(), b"%lf", &mut spr);
    if spr <= 0.0 {
        spr = 1.0;
    }

    f.read(&mut ifile, 4, 4);
    if vflag {
        cprintf!(b"Number of signals: '%s'\n", f.s());
    }
    csscanf!(f.s(), b"%d", &mut nsig);

    if nsig < 1 {
        cstd::exit(1);
    }
    let ns = nsig as usize;

    let mut si = vec![Siginfo::default(); ns];
    let mut spb = vec![0i32; ns];
    let mut sigdmax = vec![0i64; ns];
    let mut sigdmin = vec![0i64; ns];
    let mut sigpmax = vec![0f64; ns];
    let mut sigpmin = vec![0f64; ns];
    let mut sampfreq = vec![0f64; ns];

    if nosig == 0 {
        // initialize signal list if necessary
        siglist = (0..nsig).collect();
        nosig = ns;
    } else {
        for &s in &siglist {
            if s < 0 || s >= nsig {
                ceprintf!(b"%s: invalid signal number, %d, in signal list\n", pname, s);
                cstd::exit(1);
            }
        }
    }
    let sl: Vec<usize> = siglist.iter().map(|&s| s as usize).collect();

    let mut so = vec![Siginfo::default(); nosig];

    for (i, s) in si.iter_mut().enumerate() {
        f.read(&mut ifile, 16, 15);
        if vflag {
            cprintf!(b"Signal %d label: '%s'\n", i as i32, f.s());
        }
        s.desc = Some(f.s().to_vec());
    }

    for i in 0..ns {
        let j = f.read(&mut ifile, 80, 80);
        if vflag && j > 0 {
            cprintf!(b"Signal %d transducer type: '%s'\n", i as i32, f.s());
        }
    }

    for (i, s) in si.iter_mut().enumerate() {
        f.read(&mut ifile, 8, 8);
        if vflag {
            cprintf!(b"Signal %d physical dimension: '%s'\n", i as i32, f.s());
        }
        s.units = Some(f.s().to_vec());
    }

    for (i, v) in sigpmin.iter_mut().enumerate() {
        f.read(&mut ifile, 8, 8);
        if vflag {
            cprintf!(b"Signal %d physical minimum: '%s'\n", i as i32, f.s());
        }
        csscanf!(f.s(), b"%lf", v);
    }

    for (i, v) in sigpmax.iter_mut().enumerate() {
        f.read(&mut ifile, 8, 8);
        if vflag {
            cprintf!(b"Signal %d physical maximum: '%s'\n", i as i32, f.s());
        }
        csscanf!(f.s(), b"%lf", v);
    }

    for (i, v) in sigdmin.iter_mut().enumerate() {
        f.read(&mut ifile, 8, 8);
        if vflag {
            cprintf!(b"Signal %d digital minimum: '%s'\n", i as i32, f.s());
        }
        csscanf!(f.s(), b"%ld", v);
    }

    for (i, v) in sigdmax.iter_mut().enumerate() {
        f.read(&mut ifile, 8, 8);
        if vflag {
            cprintf!(b"Signal %d digital maximum: '%s'\n", i as i32, f.s());
        }
        csscanf!(f.s(), b"%ld", v);
    }

    for i in 0..ns {
        if sigpmax[i] == sigpmin[i] {
            ceprintf!(b"gain for signal %d is undefined\n", i as i32);
            continue;
        }
        let s = &mut si[i];
        s.adczero = (sigdmax[i].wrapping_add(1).wrapping_add(sigdmin[i]) / 2) as i32;
        let mut adcrange = sigdmax[i].wrapping_sub(sigdmin[i]);
        s.gain = adcrange as f64 / (sigpmax[i] - sigpmin[i]);
        let mut j = 0;
        while adcrange > 1 {
            adcrange /= 2;
            j += 1;
        }
        s.adcres = j;
        s.baseline = d2i(sigdmax[i] as f64 - sigpmax[i] * s.gain + 1.0);
    }

    for i in 0..ns {
        let j = f.read(&mut ifile, 80, 80);
        if vflag && j > 0 {
            cprintf!(b"Signal %d filtering information: '%s'\n", i as i32, f.s());
        }
    }

    for i in 0..ns {
        f.read(&mut ifile, 8, 8);
        if vflag {
            cprintf!(
                b"Signal %d number of samples per record: '%s'\n",
                i as i32,
                f.s()
            );
        }
        csscanf!(f.s(), b"%lf", &mut sampfreq[i]);
        csscanf!(f.s(), b"%d", &mut spb[i]);
        sampfreq[i] /= spr;
    }

    for i in 0..ns {
        let j = f.read(&mut ifile, 32, 32);
        if vflag && j > 0 {
            cprintf!(b"Signal %d free space: '%s'\n", i as i32, f.s());
        }
    }

    // Determine the base sampling frequency (the greatest common divisor of
    // all sampling frequencies for the signals in the signal list)
    let mut sps = sampfreq[sl[0]];
    for &s in &sl[1..] {
        if sampfreq[s] != sps {
            sps = gcd(sps, sampfreq[s]);
        }
    }
    wfdbx::setsampfreq(sps);

    let mut bt = cformat!(
        b"%02d:%02d:%02d %02d/%02d/%04d",
        hour,
        minute,
        second,
        day,
        month,
        year
    );
    bt.truncate(MAXFIELD); // (C formats it into the field buffer)
    wfdbx::setbasetime(&bt);

    let mut fname = record.clone();
    fname.extend_from_slice(b".dat");
    let mut tspf: i32 = 0;
    for (i, &s) in sl.iter().enumerate() {
        si[s].fname = Some(fname.clone());
        si[s].fmt = 16;
        si[s].spf = d2i(sampfreq[s] / sps + 0.5);
        tspf = tspf.wrapping_add(si[s].spf);
        so[i] = si[s].clone();
    }

    let fpb = if si[sl[0]].spf != 0 {
        spb[sl[0]].wrapping_div(si[sl[0]].spf)
    } else {
        0
    };

    if vflag {
        cprintf!(b"\nOUTPUT:\nBase sampling frequency: %g Hz\n", sps);
    }

    if vflag {
        for (i, &s) in sl.iter().enumerate() {
            let j = si[s].spf;
            let plural: &[u8] = if j > 1 { b"s" } else { b"" };
            cprintf!(
                b" Signal %d samples per second: %g (%d sample%s per frame)\n",
                i as i32,
                sampfreq[s],
                j,
                plural
            );
        }
    }

    let mut vin: Vec<Vec<u8>> = spb
        .iter()
        .map(|&n| vec![0u8; if n > 0 { n as usize * 2 } else { 0 }])
        .collect();
    let mut vi = vec![0usize; nosig]; // positions within vin[siglist[j]]
    let room: usize = so.iter().map(|s| s.spf.max(0) as usize).sum();
    let mut vout = vec![0i32; room.max(tspf.max(0) as usize)];
    wfdbx::osigfopen(&so, nosig as u32);
    loop {
        let mut j = 0usize;
        for (i, v) in vin.iter_mut().enumerate() {
            j = if spb[i] > 0 {
                ifile.fread(v, 2, spb[i] as usize)
            } else {
                0
            };
        }
        if j == 0 {
            break;
        }
        vi.fill(0);
        for _ in 0..fpb {
            let mut vo = 0usize;
            for j in 0..nosig {
                let v = &vin[sl[j]];
                for _ in 0..so[j].spf {
                    let p = vi[j];
                    let b0 = v.get(p).map_or(0, |&c| c as i8 as i32);
                    let b1 = v.get(p + 1).map_or(0, |&c| c as i8 as i32);
                    vi[j] += 2;
                    let (h, l) = if big_endian { (b0, b1) } else { (b1, b0) };
                    vout[vo] = ((h << 8) | (l & 0xff)) as i16 as i32;
                    vo += 1;
                }
            }
            wfdbx::putvec(&vout);
        }
    }
    drop(ifile);

    wfdbx::newheader(&record);
    wfdbx::wfdbquit();
    cstd::exit(0);
}
