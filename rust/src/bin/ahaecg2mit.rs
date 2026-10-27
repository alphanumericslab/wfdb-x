//! ahaecg2mit: convert `*.ecg` or `*.txt` files from an AHA Database DVD to
//! WFDB-compatible format (port of `convert/ahaecg2mit.c`).
//!
//! Behaviors of the C program that are undefined are resolved as in the
//! other wfdb-x implementations (see `docs/KNOWN_C_BEHAVIORS.md`): the
//! 16-byte line buffer of `readtxtdata` keeps the bytes of earlier lines of
//! the same input file and is not NUL-terminated (bytes beyond it are
//! treated as NUL), and the record name is made of the (up to 4) characters
//! that precede the extension. The line buffer, the samples and the
//! annotation are reset for each input file; with `-s`, a record name of
//! fewer than 2 characters is left unchanged.
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Rust translation of convert/ahaecg2mit.c from the WFDB Software
// Package 10.7.0, by George B. Moody. The translation follows the logic and
// behavior of the original program, but it is new code, not the original C
// code.
//
// Changes from the original: no built-in signal parameters: the new options -F
// FREQ, -G GAIN, -R BITS and -U UNITS give the sampling frequency, gain, ADC
// resolution and units, and are required (-U unless the gain is 0; the
// original assumed those of the AHA database: 250 Hz, 400 adu/mV, 12 bits and
// millivolts); the options precede the input files, in any order; the
// short-format part of a long-format file (skipped by -s) is located from -F;
// --legacy, as the first argument, restores the original behavior. Each change
// is marked "wfdb-x:" in the code; docs/DIVERGENCES.md gives the reasons.
//
// Original C program: convert/ahaecg2mit.c, WFDB Software Package 10.7.0.
//   By George B. Moody (2008); revised 2017 by Benjamin Moody. The C source
//   has no copyright or license notice.
// Rust translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

use wfdbx::cstd::{self, EOF, SEEK_SET};
use wfdbx::{ceprintf, csscanf, Anninfo, Annotation, Siginfo, WfdbFile, WFDB_WRITE};

/// The signal parameters (-F, -G, -R, -U); wfdb-x: the C program assumed
/// those of the AHA database (250 Hz, 400 adu/mV, 12 bits, millivolts).
struct Params {
    freq: f64,
    gain: f64,
    adcres: i32,
    units: Option<Vec<u8>>,
}

/// Input file formats: binary (`.ecg`) and text (`.txt`).
const FMT_ECG: i32 = 1;
const FMT_TXT: i32 = 2;

/// A frame of a `.ecg` file: two 16-bit samples and an annotation code.
const ECG_FRAMELEN: usize = 5;

/// Size of C's `readtxtdata` line buffer.
const TXTBUFLEN: usize = 16;

/// Minutes skipped (with `-s`) at the start of a long-format input file
/// (not part of the short-format, 35-minute, record).
const SKIP_MINUTES: i64 = 145;

/// The state of the C program (its static variables).
struct State {
    format: i32,
    ifile: WfdbFile,
    a: Annotation,
    v: [i32; 2],
    /// `readtxtdata`'s line buffer.
    txtbuf: [u8; TXTBUFLEN],
}

impl State {
    fn readbindata(&mut self) -> i32 {
        let mut data = [0u8; ECG_FRAMELEN];
        if self.ifile.fread(&mut data, 1, ECG_FRAMELEN) != ECG_FRAMELEN {
            return 0; // EOF
        }
        self.v[0] = data[0] as i32 | ((data[1] as i32) << 8);
        self.v[1] = data[2] as i32 | ((data[3] as i32) << 8);
        if data[4] == b'.' {
            return 1; // samples, no annotation
        }
        self.a.anntyp = wfdbx::ammap(data[4] as i8 as i32) as i8;
        self.a.subtyp = if data[4] == b'U' { -1 } else { 0 };
        2 // samples and annotation
    }

    fn readtxtdata(&mut self) -> i32 {
        let mut c: i8 = 0; // char is signed in the reference C implementation
        for i in 0..self.txtbuf.len() {
            c = self.ifile.getc() as i8;
            if c == b'\r' as i8 || c as i32 == EOF || c == b'\n' as i8 {
                break;
            }
            self.txtbuf[i] = c as u8;
        }
        if c as i32 == EOF {
            return 0;
        }
        let s = cstd::cstr(&self.txtbuf);
        let (mut v0, mut v1) = (0i64, 0i64);
        let mut cc: u8 = c as u8;
        let n = csscanf!(s, b"%lld,%lld,\"%c", &mut v0, &mut v1, &mut cc);
        if n >= 1 {
            self.v[0] = v0 as i32;
        }
        if n >= 2 {
            self.v[1] = v1 as i32;
        }
        if n >= 3 {
            c = cc as i8;
        }
        if n < 3 {
            ceprintf!(b"Error: improperly formatted input!\n");
            ceprintf!(
                b" n = %d, buf = |%s|, v[0] = %d, v[1] = %d, c = |%c|\n",
                n,
                s,
                self.v[0],
                self.v[1],
                c
            );
            return 0;
        }
        if c == b'"' as i8 {
            return 1; // samples, no annotation
        }
        self.a.anntyp = wfdbx::ammap(c as i32) as i8;
        self.a.subtyp = if c == b'U' as i8 { -1 } else { 0 };
        2 // samples and annotation
    }

    fn process(&mut self, record: &[u8], par: &Params) {
        let mut t: i64 = -1;

        wfdbx::setsampfreq(par.freq); // wfdb-x: -F (the C program set 250 Hz)
        let mut ofname = record.to_vec();
        ofname.extend_from_slice(b".dat");
        let s0 = Siginfo {
            fname: Some(ofname),
            desc: Some(b"ECG0".to_vec()),
            units: par.units.clone(),
            gain: par.gain,
            fmt: 212,
            adcres: par.adcres,
            ..Siginfo::default()
        };
        let mut s1 = s0.clone();
        s1.desc = Some(b"ECG1".to_vec());
        let si = [s0, s1];
        let ai = [Anninfo {
            name: b"atr".to_vec(),
            stat: WFDB_WRITE,
        }];
        if wfdbx::osigfopen(&si, 2) != 2 || wfdbx::annopen(record, &ai, 1) < 0 {
            wfdbx::wfdbquit();
            return;
        }
        if self.format == FMT_ECG {
            loop {
                let stat = self.readbindata();
                if stat == 0 {
                    break;
                }
                wfdbx::putvec(&self.v);
                if stat > 1 {
                    self.a.time = t;
                    wfdbx::putann(0, &self.a);
                }
                t += 1;
            }
        } else {
            loop {
                let stat = self.readtxtdata();
                if stat == 0 {
                    break;
                }
                t += 1;
                wfdbx::putvec(&self.v);
                if stat > 1 {
                    self.a.time = t;
                    wfdbx::putann(0, &self.a);
                }
            }
        }
        wfdbx::newheader(record);
        wfdbx::wfdbquit();
        ceprintf!(
            b"wrote %s.atr, %s.dat, and %s.hea\n",
            record,
            record,
            record
        );
    }
}

fn main() {
    // (C strips the extension of each argument in place, which shows in a
    // later "can't open" message that names argv[1].)
    let mut argv = cstd::args();
    let legacy = wfdbx::wfdbx_legacy_args(&mut argv) != 0; // wfdb-x: --legacy
    let argc = argv.len();
    let mut sflag = false;

    if argc < 2 || cstd::cstr(&argv[1]) == b"-h" {
        if legacy {
            // wfdb-x: the usage of the C program
            ceprintf!(b"usage: %s [-s] RECORD.XXX [RECORD.XXX]...\n", argv[0]);
        } else {
            ceprintf!(
                b"usage: %s [-s] -F FREQ -G GAIN -R BITS -U UNITS RECORD.XXX [RECORD.XXX]...\n",
                argv[0]
            );
        }
        ceprintf!(
            b" where RECORD.XXX is the name of the AHA DVD input file to be converted\n ('RECORD' is one of the 4-digit AHA DB record names, and 'XXX' may be either\n 'ecg' or 'txt', depending on the version of the AHA DVD.)\n Output files are RECORD.hea (text), RECORD.atr (binary), RECORD.dat (binary).\n Two or more input files may be converted in a single run.\n Use -s to make short-format (35-minute) records from long-format (2.5 hour)\n input files.  When using -s, the second digit in the output record name is\n incremented by 2.\n"
        );
        if !legacy {
            ceprintf!(
                b" -F, -G, -R and -U give the sampling frequency (Hz), gain (adu per physical\n unit), ADC resolution (bits) and units of the signals; for the AHA DVD\n files, use -F 250 -G 400 -R 12 -U mV.\n"
            );
        }
        cstd::exit(1);
    }
    // wfdb-x: options (-s and the signal parameters) precede the input
    // files, in any order.
    let pname = argv[0].clone();
    let mut par = Params {
        freq: 0.0,
        gain: 0.0,
        adcres: 0,
        units: None,
    };
    let mut gset = false;
    let mut i = 1;
    if legacy {
        // wfdb-x: in legacy mode, the option of the C program (-s only, as
        // the first argument), and the parameters of the AHA database that it
        // set (250 Hz, 400 adu/mV, 12 bits, millivolts).
        if cstd::cstr(&argv[1]) == b"-s" {
            sflag = true; // produce short-format (35-minute) records
            i = 2;
        }
        par = Params {
            freq: 250.0,
            gain: 400.0,
            adcres: 12,
            units: Some(b"mV".to_vec()),
        };
        gset = true;
    }
    while !legacy && i < argc {
        let a = cstd::cstr(&argv[i]);
        if !(a.len() == 2 && a[0] == b'-' && b"sFGRU".contains(&a[1])) {
            break;
        }
        match a[1] {
            b's' => sflag = true, // produce short-format (35-minute) records
            b'F' => {
                // sampling frequency (wfdb-x)
                i += 1;
                if i >= argc || csscanf!(&argv[i], b"%lf", &mut par.freq) != 1 || par.freq <= 0.0 {
                    ceprintf!(b"%s: sampling frequency (> 0) must follow -F\n", pname);
                    cstd::exit(1);
                }
            }
            b'G' => {
                // gain in adu per physical unit (wfdb-x)
                i += 1;
                if i >= argc || csscanf!(&argv[i], b"%lf", &mut par.gain) != 1 || par.gain < 0.0 {
                    ceprintf!(b"%s: gain (>= 0) must follow -G\n", pname);
                    cstd::exit(1);
                }
                gset = true;
            }
            b'R' => {
                // ADC resolution in bits (wfdb-x)
                i += 1;
                if i >= argc
                    || csscanf!(&argv[i], b"%d", &mut par.adcres) != 1
                    || !(1..=32).contains(&par.adcres)
                {
                    ceprintf!(b"%s: ADC resolution (1-32 bits) must follow -R\n", pname);
                    cstd::exit(1);
                }
            }
            _ => {
                // physical units (wfdb-x)
                i += 1;
                if i >= argc {
                    ceprintf!(b"%s: units must follow -U\n", pname);
                    cstd::exit(1);
                }
                par.units = Some(cstd::cstr(&argv[i]).to_vec());
            }
        }
        i += 1;
    }
    // wfdb-x: the signal parameters must be given explicitly (see
    // docs/DIVERGENCES.md); in legacy mode, these checks pass.
    if par.freq <= 0.0 {
        ceprintf!(
            b"%s: the sampling frequency must be specified (-F)\n",
            pname
        );
        cstd::exit(1);
    }
    if !gset {
        ceprintf!(b"%s: the gain must be specified (-G)\n", pname);
        cstd::exit(1);
    }
    if par.adcres < 1 {
        ceprintf!(b"%s: the ADC resolution must be specified (-R)\n", pname);
        cstd::exit(1);
    }
    if par.gain != 0.0 && par.units.is_none() {
        ceprintf!(b"%s: the units must be specified (-U)\n", pname);
        cstd::exit(1);
    }
    while i < argc {
        let arg = cstd::cstr(&argv[i]).to_vec();
        let arg = &arg[..];
        let len = arg.len();
        // position of '.ecg' or '.txt'
        let p = len.saturating_sub(4);
        let ext = &arg[p..];
        let format = if len >= 4 && (ext == b".ecg" || ext == b".ECG") {
            FMT_ECG
        } else if len >= 4 && (ext == b".txt" || ext == b".TXT") {
            FMT_TXT
        } else {
            ceprintf!(b"%s: ignoring '%s'\n", argv[0], arg);
            i += 1;
            continue; // not an .ecg or .txt file
        };
        let Some(ifile) = WfdbFile::fopen(arg, b"rb") else {
            ceprintf!(b"%s: can't open '%s'\n", argv[0], argv[1]);
            i += 1;
            continue;
        };
        // strip off the extension; AHA record names are 4 (ASCII) digits
        argv[i].truncate(p);
        let mut record = if p >= 4 {
            arg[p - 4..p].to_vec()
        } else {
            arg[..p].to_vec()
        };
        // reset the state kept for each input file
        let mut st = State {
            format,
            ifile,
            a: Annotation::default(),
            v: [0, 0],
            txtbuf: [0; TXTBUFLEN],
        };
        if sflag {
            // skip first 145 minutes if making a short-format record
            let nskip = cstd::d2l((SKIP_MINUTES * 60) as f64 * par.freq); // frames
            if format == FMT_ECG {
                st.ifile.seek(nskip * ECG_FRAMELEN as i64, SEEK_SET);
            } else if format == FMT_TXT {
                for _ in 0..nskip {
                    st.readtxtdata();
                }
            }
            if record.len() > 1 {
                record[1] = record[1].wrapping_add(2); // fix record name (n0nn->n2nn, n1nn->n3nn)
            }
        }
        st.process(&record, &par);
        st.ifile.close();
        i += 1;
    }
    cstd::exit(0);
}
