//! wrann: translate an ASCII annotation file to binary format (port of
//! `app/wrann.c`).
//!
//! The input is in the format produced by `rdann`. Where the C program has
//! undefined behavior (a line with no space after column 9, or a mnemonic
//! longer than 9 characters), this port treats the remainder of the line as
//! empty, and uses the full mnemonic (see `docs/KNOWN_C_BEHAVIORS.md`).
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Rust translation of app/wrann.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: none, apart from the language and the --legacy
// option (as the first argument, it restores the original behavior).
//
// Original C program: app/wrann.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1983-2010 George B. Moody; revised 2018 by Benjamin Moody.
// Rust translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

use wfdbx::cstd;
use wfdbx::{ceprintf, csscanf, Anninfo, Annotation, WfdbFile, NOTE, NOTQRS, WFDB_WRITE};

fn help(pname: &[u8]) {
    ceprintf!(b"usage: %s -r RECORD -a ANNOTATOR <TEXT-FILE\n", pname);
    ceprintf!(b"TEXT-FILE should be in the format produced by `rdann'.\n");
}

fn main() {
    let mut argv = cstd::args();
    wfdbx::wfdbx_legacy_args(&mut argv); // wfdb-x: --legacy (original behavior)
    let argc = argv.len();
    let pname = cstd::prog_name(&argv[0]).to_vec();
    let mut record: Option<&[u8]> = None;
    let mut ainame: Option<&[u8]> = None;
    let (mut sub, mut ch, mut nm) = (0i32, 0i32, 0i32);
    let mut tm: i64 = 0;
    let mut annot = Annotation::default();
    // The mnemonic buffer (static in C: it keeps its contents when a line
    // has no mnemonic).
    let mut mnem: Vec<u8> = Vec::new();

    // Interpret command-line options.
    let mut i = 1;
    while i < argc {
        let a = &argv[i];
        if a.first() == Some(&b'-') {
            match a.get(1).copied().unwrap_or(0) {
                b'a' => {
                    // annotator follows
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: annotator must follow -a\n", pname);
                        cstd::exit(1);
                    }
                    ainame = Some(&argv[i]);
                }
                b'h' => {
                    // print usage summary and quit
                    help(&pname);
                    cstd::exit(0);
                }
                b'r' => {
                    // input record name follows
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: input record name must follow -r\n", pname);
                        cstd::exit(1);
                    }
                    record = Some(&argv[i]);
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
    let (Some(record), Some(ainame)) = (record, ainame) else {
        help(&pname);
        cstd::exit(1);
    };

    wfdbx::setafreq(wfdbx::sampfreq(record));
    let ai = [Anninfo {
        name: ainame.to_vec(),
        stat: WFDB_WRITE,
    }];
    if wfdbx::annopen(record, &ai, 1) < 0 {
        // open annotation file
        cstd::exit(2);
    }
    // Sizes of C's line and aux string buffers.
    const LINELEN: usize = 400;
    const AUXBUFLEN: usize = 256;
    let mut input = WfdbFile::stdin();
    let mut buf = Vec::new();
    while input.fgets(&mut buf, LINELEN) {
        let line = cstd::cstr(&buf);
        let n = line.len();
        // Skip the time column (at least 9 characters, as "0:00.000" with
        // its leading space, or a "[...]" time of day).
        let mut p = 9;
        if line.first() == Some(&b'[') {
            while p < n && line[p] != b']' {
                p += 1;
            }
        }
        while p < n && line[p] != b' ' {
            p += 1;
        }
        let rest: &[u8] = if p < n { &line[p + 1..] } else { b"" };
        csscanf!(
            rest,
            b"%lld%s%d%d%d",
            &mut tm,
            &mut mnem,
            &mut sub,
            &mut ch,
            &mut nm
        );
        annot.anntyp = wfdbx::strann(&mnem[..]) as i8;
        if line.first() == Some(&b'[') {
            annot.time = -wfdbx::strtim(line);
            if annot.time < 0 {
                continue;
            }
        } else {
            annot.time = tm;
        }
        annot.subtyp = sub as i8;
        annot.chan = ch as u8;
        annot.num = nm as i8;
        // If mnem does not contain a recognizable mnemonic, write a NOTE
        // annotation and put mnem at the beginning of the aux field.
        let astr: Vec<u8> = if annot.anntyp as i32 == NOTQRS {
            annot.anntyp = NOTE as i8;
            mnem.clone()
        } else {
            mnem.clear();
            Vec::new()
        };
        let tab = rest.iter().position(|&c| c == b'\t');
        let have_ap = tab.is_some();
        let mut ap: Vec<u8> = Vec::new();
        if let Some(t) = tab {
            // auxinfo at end of line
            ap = rest[t..].to_vec();
            let mut cut: i64 = if astr.len() + ap.len() + 2 > AUXBUFLEN {
                AUXBUFLEN as i64 - astr.len() as i64 - 3
            } else {
                -1 // discard trailing newline
            };
            if cut < 0 {
                cut += ap.len() as i64;
            }
            if cut < 0 {
                cut = 0;
            }
            if (cut as usize) < ap.len() {
                ap.truncate(cut as usize);
            }
        }
        // Create an aux string if needed.
        if !astr.is_empty() || have_ap {
            let tail: &[u8] = if ap.len() > 1 { &ap[1..] } else { b"" };
            let mut s = Vec::new();
            if !astr.is_empty() && have_ap {
                s.extend_from_slice(&astr);
                s.push(b' ');
                s.extend_from_slice(tail);
            } else if !astr.is_empty() {
                s.extend_from_slice(&astr);
            } else {
                s.extend_from_slice(tail);
            }
            let mut aux = vec![(s.len() & 0xff) as u8];
            aux.extend_from_slice(&s);
            annot.aux = Some(aux);
        } else {
            annot.aux = None;
        }
        wfdbx::putann(0, &annot);
    }
    wfdbx::wfdbquit();
    cstd::exit(0);
}
