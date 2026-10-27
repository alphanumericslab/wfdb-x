//! a2m: convert an AHA format annotation file to MIT format (port of
//! `convert/a2m.c`).
//!
//! This program converts four types of AHA format annotation files to MIT
//! format:
//!
//! | Type | Description |
//! |---|---|
//! | 0 | AHA-format annotation files produced by WFDB library-based programs that use `AHA_WRITE` mode and `putann` (`m2a` is an example). Time is measured in sample intervals from the beginning of the record, and MIT annotation codes are included and read into the `chan` field of the annotation by `getann`; if such codes are present (`chan` non-zero), the AHA code is ignored. |
//! | 1 | Standard AHA annotation files from short-format AHA DB distribution tapes. Time is measured in milliseconds from the beginning of the test period (five minutes after the first sample); WFDB-x converts milliseconds at the sampling frequency of the record (or `-F`), where the C program assumed 4 ms per sample interval (250 Hz). |
//! | 2 | Standard AHA annotation files from long-format AHA DB distribution tapes. Time is measured as for type 1, except that the test period begins 2.5 hours after the first sample. |
//! | 3 | "Compressed" (`*.ANO`) annotation files from AHA DB CD-ROMs or floppy diskettes. Time is measured as for files of type 1 or 2, depending on the record name (x2xx or x3xx: short format, x0xx or x1xx: long format). |
//!
//! Where the C program has undefined behavior (an input file name ending
//! in `/` without `-r`, or a directory as input file), this port uses an
//! empty record name, and reports the directory as unreadable (see
//! `docs/KNOWN_C_BEHAVIORS.md`).
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Rust translation of convert/a2m.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: no built-in sampling frequency: the new option -F
// FREQ gives it when the record has no header or its header gives none, and is
// then required (the original assumed 250 Hz, or 1 sample per second without a
// header); annotation times given in milliseconds (AHA file types 1 to 3) are
// converted at the record's sampling frequency (the original assumed 4 ms per
// sample); --legacy, as the first argument, restores the original behavior.
// Each change is marked "wfdb-x:" in the code; docs/DIVERGENCES.md gives the
// reasons.
//
// Original C program: convert/a2m.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1983-2010 George B. Moody.
// Rust translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

use wfdbx::cstd;
use wfdbx::{ceprintf, csscanf, Anninfo, Annotation, WfdbFile, WFDB_AHA_READ, WFDB_WRITE};

const HELP_STRINGS: &[&[u8]] = &[
    b"usage: %s -i AHAFILE [ OPTIONS ... ]\n",
    b"where AHAFILE is the name of the AHA-format input annotation file,",
    b"and OPTIONS may include:",
    b" -a ANNOTATOR  specify the output annotator name (default: 'atr')",
    b" -F FREQ       sampling frequency, if the record header does not specify",
    b"                one (AHA database: 250)",
    b" -h            print this usage summary",
    b" -r RECORD     specify the name of the output RECORD (default: use the",
    b"                input file name, less path info and extension, as RECORD)",
    b" -s TIME       shift annotations by TIME",
    b"                (defaults: 0 for TYPE 0,",
    b"                      5:0 for TYPE 1, (or TYPE 3 if RECORD=x2xx or x3xx)",
    b"                   2:30:0 for TYPE 2, (or TYPE 3 if RECORD=x0xx or x1xx)",
    b" -t TYPE       specify type of file to be converted:",
    b"                0 for files produced by WFDB applications in AHA format,",
    b"                1 for short-format tape files,",
    b"                2 for long-format tape files, or",
    b"                3 for compressed files from AHA DB CD-ROMs or diskettes",
    b"                (defaults: 3 if AHAFILE ends in .ANO or .ano, else 0)",
];

/// wfdb-x: the lines of `HELP_STRINGS` added by WFDB-x, left out of the
/// help text of the original program (printed in legacy mode).
const WFDBX_HELP_LINES: &[&[u8]] = &[
    b" -F FREQ       sampling frequency, if the record header does not specify",
    b"                one (AHA database: 250)",
];

fn help(pname: &[u8]) {
    let legacy = wfdbx::wfdbx_get_legacy() != 0;
    ceprintf!(HELP_STRINGS[0], pname);
    for s in &HELP_STRINGS[1..] {
        if !(legacy && WFDBX_HELP_LINES.contains(s)) {
            ceprintf!(b"%s\n", s);
        }
    }
}

fn is_directory(name: &[u8]) -> bool {
    std::fs::metadata(cstd::bytes_to_path(name)).is_ok_and(|m| m.is_dir())
}

/// Input file types (`-t`; see the table above).
const FT_WFDB: i32 = 0;
const FT_SHORT: i32 = 1;
const FT_LONG: i32 = 2;
const FT_COMPRESSED: i32 = 3;

/// Sampling frequency of the AHA Database (legacy mode).
const AHA_FREQ: f64 = 250.0;

/// Size of a compressed AHA annotation.
const CANNLEN: usize = 6;

/// Read a compressed AHA annotation; -1 at end of file.
fn getcann(input: &mut WfdbFile, ap: &mut Annotation) -> i32 {
    let mut buf = [0u8; CANNLEN];
    if input.fread(&mut buf, 1, CANNLEN) != CANNLEN {
        return -1; // hard EOF
    }
    // Compressed AHA format:
    //  buf[0]  AHA label (`N', `V', `F', `R', `E', `P', `Q', `[', `]', or `U')
    //  buf[1]  high byte of ahatime, or 0xff if at soft EOF
    //  buf[2]  middle byte of ahatime
    //  buf[3]  low byte of ahatime
    //  buf[4]  high byte of annotation serial number (ignored here)
    //  buf[5]  low byte of serial number
    if buf[1] == 0xff {
        return -1; // soft EOF
    }

    // convert AHA label to annotation code (C char is signed)
    ap.anntyp = wfdbx::ammap(buf[0] as i8 as i32) as i8;

    if ap.anntyp == 0 {
        return -1; // alternate soft EOF, used in a few AHA DB CD-ROM files
    }
    ap.subtyp = if buf[0] == b'U' {
        -1 // AHA `U' (unreadable data) label: decode as NOISE, subtype -1
    } else {
        0 // all others have subtype 0
    };

    let h = buf[1] as i64;
    let m = buf[2] as i64;
    let l = buf[3] as i64;
    // time in milliseconds from the start of the annotated segment
    ap.time = (h << 16) | (m << 8) | l;
    0
}

/// A time in milliseconds, in sample intervals at the record's sampling
/// frequency (WFDB-x; C, and legacy mode, assumed 4 ms per sample
/// interval).
fn ms_to_samples(t: i64, legacy: bool) -> i64 {
    if legacy {
        return t >> 2; // wfdb-x: legacy mode: 4 msec/sample
    }
    cstd::d2l(t as f64 * wfdbx::sampfreq(wfdbx::NULL) / 1000.0)
}

fn main() {
    let mut argv = cstd::args();
    let legacy = wfdbx::wfdbx_legacy_args(&mut argv) != 0; // wfdb-x: --legacy
    let argc = argv.len();
    let pname = cstd::prog_name(&argv[0]).to_vec();
    let mut ifname: Option<&[u8]> = None;
    let mut record: Option<Vec<u8>> = None;
    let mut oann: &[u8] = b"atr";
    let mut ftype: i32 = -1;
    let mut offset_arg: usize = 0;
    let mut nann: u32 = 2;
    let mut annot = Annotation::default();
    let mut ffreq = 0.0; // wfdb-x: -F

    // Read and interpret command-line arguments.
    let mut i = 1;
    while i < argc {
        let a = &argv[i];
        if a.first() == Some(&b'-') {
            match a.get(1).copied().unwrap_or(0) {
                b'a' => {
                    // annotator name follows
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: output annotator name must follow -a\n", pname);
                        cstd::exit(1);
                    }
                    oann = &argv[i];
                }
                b'F' if !legacy => {
                    // sampling frequency follows (WFDB-x)
                    i += 1;
                    if i >= argc || csscanf!(&argv[i], b"%lf", &mut ffreq) != 1 || ffreq <= 0.0 {
                        ceprintf!(b"%s: sampling frequency (> 0) must follow -F\n", pname);
                        cstd::exit(1);
                    }
                }
                b'h' => {
                    // help requested
                    help(&pname);
                    cstd::exit(1);
                }
                b'i' => {
                    // input file name follows
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: name of AHA-format input file must follow -i\n", pname);
                        cstd::exit(1);
                    }
                    let f = cstd::cstr(&argv[i]);
                    ifname = Some(f);
                    if ftype < 0 && f.len() > 4 {
                        let p = &f[f.len() - 4..];
                        if p == b".ANO" || p == b".ano" {
                            ftype = FT_COMPRESSED;
                        }
                    }
                }
                b'r' => {
                    // record name follows
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: record name must follow -a\n", pname);
                        cstd::exit(1);
                    }
                    record = Some(cstd::cstr(&argv[i]).to_vec());
                }
                b's' => {
                    // time shift follows
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: time shift must follow -s\n", pname);
                        cstd::exit(1);
                    }
                    // save position in arg list, convert to time later when
                    // sampling frequency is known
                    offset_arg = i;
                }
                b't' => {
                    // file type follows
                    i += 1;
                    if i < argc {
                        ftype = cstd::atoi(&argv[i]);
                    }
                    if i >= argc || !(FT_WFDB..=FT_COMPRESSED).contains(&ftype) {
                        ceprintf!(b"%s: file type (0-3) must follow -t\n", pname);
                        cstd::exit(1);
                    }
                }
                _ => {
                    ceprintf!(b"%s: unrecognized option %s\n", pname, a);
                    cstd::exit(1);
                }
            }
        } else {
            ceprintf!(b"%s: unrecognized argument %s\n", pname, a);
            cstd::exit(1);
        }
        i += 1;
    }

    // Quit if input filename was not specified.
    let Some(ifname) = ifname else {
        help(&pname);
        cstd::exit(1);
    };

    // Attach the input file to the standard input.
    // (C reads a directory forever; WFDB-x reports it as unreadable)
    if ifname != b"-" && (is_directory(ifname) || !wfdbx::freopen_stdin(ifname)) {
        ceprintf!(b"%s: can't read input file `%s'\n", pname, ifname);
        cstd::exit(2);
    }

    // If no output record name was specified, use the basename of the input
    // file, less any extension.
    let record = record.unwrap_or_else(|| {
        let mut r = cstd::prog_name(ifname).to_vec();
        if let Some(p) = r.iter().skip(1).position(|&c| c == b'.') {
            r.truncate(p + 1);
        }
        r
    });

    if ftype < 0 {
        ftype = FT_WFDB;
    }

    // Open the annotation files.
    let mut afarray = vec![Anninfo {
        name: oann.to_vec(),
        stat: WFDB_WRITE,
    }];
    if ftype != FT_COMPRESSED {
        afarray.push(Anninfo {
            name: b"-".to_vec(),
            stat: WFDB_AHA_READ,
        });
    } else {
        nann = 1;
    }
    if wfdbx::annopen(&record, &afarray, nann) < 0 {
        cstd::exit(2);
    }

    // Set the time shift.
    // wfdb-x: if the record header does not give the sampling frequency, -F
    // must give it.  (The C program assumed the rate of the AHA database,
    // 250 Hz, if a header without a frequency existed, and 1 sample per
    // second if there was no header, as legacy mode does.)
    if legacy {
        if wfdbx::sampfreq(&record) == 0.0 {
            wfdbx::setsampfreq(AHA_FREQ);
        }
    } else if wfdbx::sampfreq(&record) <= 0.0 {
        if ffreq > 0.0 {
            wfdbx::setsampfreq(ffreq);
        } else {
            ceprintf!(
                b"%s: sampling frequency of record %s is not specified (use -F)\n",
                pname,
                record
            );
            cstd::exit(1);
        }
    }
    let mut offset: i64 = 0;
    if offset_arg != 0 {
        offset = wfdbx::strtim(&argv[offset_arg]);
    } else {
        match ftype {
            FT_SHORT => offset = wfdbx::strtim("5:0"),
            FT_LONG => offset = wfdbx::strtim("2:30:0"),
            FT_COMPRESSED => {
                if record.len() == 4 && (record[1] == b'0' || record[1] == b'1') {
                    offset = wfdbx::strtim("2:30:0"); // long format
                } else if record.len() == 4 && (record[1] == b'2' || record[1] == b'3') {
                    offset = wfdbx::strtim("5:0"); // short format
                }
                // otherwise, leave offset at zero (unrecognized format)
            }
            _ => {}
        }
    }

    // Reformat the annotations.
    match ftype {
        FT_WFDB => {
            while wfdbx::getann(0, &mut annot) >= 0 {
                if annot.chan != 0 {
                    // MIT annotation code present
                    annot.anntyp = annot.chan as i8;
                    annot.chan = 0;
                }
                annot.time = annot.time.wrapping_add(offset);
                if wfdbx::putann(0, &annot) < 0 {
                    break;
                }
            }
        }
        // Times in milliseconds are converted at the sampling frequency of
        // the record (WFDB-x; the C program assumed 4 ms per sample, i.e.,
        // 250 Hz, whatever the record's frequency, as legacy mode does).
        FT_SHORT | FT_LONG => {
            while wfdbx::getann(0, &mut annot) >= 0 {
                annot.time = ms_to_samples(annot.time, legacy).wrapping_add(offset);
                wfdbx::putann(0, &annot);
            }
        }
        _ => {
            let mut input = WfdbFile::stdin();
            while getcann(&mut input, &mut annot) >= 0 {
                annot.time = ms_to_samples(annot.time, legacy).wrapping_add(offset);
                wfdbx::putann(0, &annot);
            }
        }
    }

    wfdbx::wfdbquit();
    cstd::exit(0);
}
