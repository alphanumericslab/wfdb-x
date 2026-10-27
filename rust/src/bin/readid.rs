//! readid: read an AHA-format ID block, write record name and file lengths
//! (port of `convert/readid.c`).
//!
//! The C program reads the record ID into a 9-byte buffer, which overflows
//! for longer IDs; this port prints the whole ID, as the C program does (see
//! `docs/KNOWN_C_BEHAVIORS.md`).
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Rust translation of convert/readid.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: none, apart from the language and the --legacy
// option (as the first argument, it restores the original behavior).
//
// Original C program: convert/readid.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1983-2005 George B. Moody.
// Rust translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

use wfdbx::cstd;
use wfdbx::{ceprintf, cprintf, WfdbFile};

/// Read a 16-bit integer in PDP-11 format (as `g16` in readid.c: EOF gives
/// 0xff bytes).
fn g16(fp: &mut WfdbFile) -> i32 {
    let l = fp.getc();
    let h = fp.getc();
    ((h << 8) & 0xff00) | (l & 0xff)
}

/// Size of an AHA ID block, and of the logical blocks counted in it.
const BLOCK_SIZE: usize = 512;

fn main() {
    let mut argv = cstd::args();
    wfdbx::wfdbx_legacy_args(&mut argv); // wfdb-x: --legacy (original behavior)
    if argv.len() < 3 {
        ceprintf!(b"usage: %s data-block-size annot-block-size\n", argv[0]);
        cstd::exit(1);
    }
    let dasize = cstd::atoi(&argv[1]).max(1);
    let ansize = cstd::atoi(&argv[2]).max(1);
    let mut stdin = WfdbFile::stdin();
    let mut buf = [0u8; BLOCK_SIZE];
    // Bytes 1-24: record ID, number of annotations, ..., last sample time.
    stdin.fread(&mut buf[..24], 1, 24);
    // sscanf(buf, "%s", name)
    let s = cstd::cstr(&buf);
    let name: Vec<u8> = s
        .iter()
        .copied()
        .skip_while(u8::is_ascii_whitespace)
        .take_while(|c| !c.is_ascii_whitespace())
        .collect();
    // Bytes 25-26: number of blocks of sample data.
    let block = BLOCK_SIZE as i64;
    let dcount = (g16(&mut stdin) as i64 * block + dasize as i64 - 1) / dasize as i64;
    // Bytes 27-40: unused, first and last annotation times.
    stdin.fread(&mut buf[..14], 1, 14);
    // Bytes 41-42: number of blocks of annotations.
    let acount = (g16(&mut stdin) as i64 * block + ansize as i64 - 1) / ansize as i64;
    drop(stdin);
    cprintf!(b"%s %ld %ld\n", name, dcount, acount);
    cstd::exit(0);
}
