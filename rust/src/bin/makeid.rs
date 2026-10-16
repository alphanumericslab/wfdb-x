//! makeid: make an AHA-format ID block for a database record (port of
//! `convert/makeid.c`).
//!
//! Where the C program uses uninitialized variables (the time of the last
//! annotation if there is only one, or of the first if there is none), this
//! port uses 0 (see `docs/KNOWN_C_BEHAVIORS.md`).
//
// Copyright (C) 2003 George B. Moody (original C program, convert/makeid.c).
// Rust implementation part of wfdb-x, Reza Sameni, Oct 2026.
// GNU General Public License, version 2 or later (see LICENSE).

use wfdbx::cstd::{self, out};
use wfdbx::{ceprintf, Anninfo, Annotation, Siginfo, WFDB_READ};

/// Size of an AHA ID block, and of the record ID at its start.
const IDBLOCK_SIZE: usize = 512;
const RECID_LEN: usize = 8;
/// Size of the (unused) end of the ID block, after byte 48.
const NOTICE_LEN: usize = IDBLOCK_SIZE - 48;

/// Write a 16-bit integer in PDP-11 format.
fn p16(x: u32) {
    out().write(&[x as u8, (x >> 8) as u8]);
}

/// Write a 32-bit integer in PDP-11 format.
fn p32(x: i64) {
    p16((x >> 16) as u32);
    p16(x as u32);
}

fn main() {
    let mut argv = cstd::args();
    wfdbx::wfdbx_legacy_args(&mut argv); // wfdb-x: --legacy (original behavior)
    let nulls = [0u8; NOTICE_LEN];
    if argv.len() < 3 {
        ceprintf!(b"usage: %s annotator record\n", argv[0]);
        cstd::exit(1);
    }
    let rec = cstd::cstr(&argv[2]).to_vec();
    let len = rec.len();
    if len > RECID_LEN {
        ceprintf!(b"record name must be 8 characters or less\n");
        cstd::exit(1);
    }
    let afarray = [Anninfo {
        name: cstd::cstr(&argv[1]).to_vec(),
        stat: WFDB_READ,
    }];
    let mut dfarray = vec![Siginfo::default(); 2];
    if wfdbx::wfdbinit(&rec, &afarray, 1, &mut dfarray, 2) < 1 {
        cstd::exit(2);
    }
    let nsamp: i64 = dfarray[0].nsamp;
    let mut annot = Annotation::default();
    wfdbx::getann(0, &mut annot);
    let first = annot.time;
    let mut last: i64 = 0;
    let mut nann: i32 = 1;
    while wfdbx::getann(0, &mut annot) >= 0 {
        last = annot.time;
        nann += 1;
    }
    wfdbx::wfdbquit();

    // Bytes 1-8: record ID (null-padded)
    out().write(&rec);
    if len < RECID_LEN {
        out().write(&nulls[..RECID_LEN - len]);
    }
    ceprintf!(b"%s\n", rec);

    // Bytes 9-10: number of annotations
    p16(nann as u32);
    ceprintf!(b"%d annotations\n", nann);

    // Bytes 11-16: unused
    out().write(&nulls[..6]);

    // Bytes 17-20: time of first sample in the annotated segment of the
    // record, relative to the beginning of the record
    p32(0);
    ceprintf!(b"Annotated segment begins at sample 0\n");

    // Bytes 21-24: time of last sample in the annotated segment of the
    // record, relative to the beginning of the record
    p32(nsamp);
    ceprintf!(b"Annotated segment ends at sample %ld\n", nsamp);

    // Bytes 25-26: number of 512-byte logical blocks of sample data
    // (nsamp * 2 bytes per sample * 2 channels / 512, rounded upward)
    let blocks = ((nsamp + 127) >> 7) as i32;
    p16(blocks as u32);
    ceprintf!(b"%d blocks of sample data\n", blocks);

    // Bytes 27-32: unused
    out().write(&nulls[..6]);

    // Bytes 33-36: TOC of first annotation, relative to the beginning of
    // the annotated segment
    p32(first);
    ceprintf!(b"First annotation is at sample %ld\n", first);

    // Bytes 37-40: TOC of last annotation, relative to the beginning of the
    // annotated segment
    p32(last);
    ceprintf!(b"Last annotation is at sample %ld\n", last);

    // Bytes 41-42: number of 512-byte logical blocks of annotations
    // (nann * 16 bytes per annotation / 512, rounded upward)
    let blocks = (nann + 31) >> 5;
    p16(blocks as u32);
    ceprintf!(b"%d blocks of annotations\n", blocks);

    // Bytes 43-48: unused
    out().write(&nulls[..6]);

    // Bytes 49-512: may contain information such as a copyright notice
    out().write(&nulls);
    cstd::exit(0);
}
