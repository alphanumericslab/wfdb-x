//! wav2mit: convert a .wav format file to WFDB format (port of
//! `convert/wav2mit.c`).
//!
//! Most .wav files are already written in a WFDB-compatible format. This
//! program simply creates a .hea (WFDB header) file that describes the .wav
//! file; other WFDB applications can then read the .wav file directly. To
//! perform the reverse conversion, use `mit2wav`. (See the C source for a
//! description of the .wav format.)
//!
//! Where the C program has undefined behavior (without `-r`, the record
//! name it generates contains one uninitialized byte; a format chunk with
//! no signals divides by zero), this port uses the input file name without
//! `.wav` as the record name, and 0 as the number of samples (see
//! `docs/KNOWN_C_BEHAVIORS.md`).
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Rust translation of convert/wav2mit.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: no built-in gain or units: the new options -G
// GAIN (required) and -U UNITS (required unless the gain is 0) give them (the
// original wrote 12.5 adu/mV for 8-bit and 6400 adu/mV for 16-bit files, in
// millivolts); --legacy, as the first argument, restores the original
// behavior. Each change is marked "wfdb-x:" in the code; docs/DIVERGENCES.md
// gives the reasons.
//
// Original C program: convert/wav2mit.c, WFDB Software Package 10.7.0.
//   Copyright (C) 2003-2004 George B. Moody.
// Rust translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

use wfdbx::cstd::{self, EOF, SEEK_END, SEEK_SET};
use wfdbx::{ceprintf, csscanf, Siginfo, WfdbFile};

// The .wav format (see the C source): a header chunk ("RIFF", length,
// "WAVE"), a format chunk ("fmt ", its length, the PCM format tag, ...), and
// a data chunk ("data", length, then the samples, from byte WAV_HEADER_LEN).
/// Size of a chunk header (tag and length).
const CHUNK_HEADER_LEN: i64 = 8;
/// Length of a PCM format chunk (after its header).
const FMT_CHUNK_LEN: i64 = 16;
/// Format tag of uncompressed (PCM) samples.
const WAVE_FORMAT_PCM: i32 = 1;
/// Offset of the samples.
const WAV_HEADER_LEN: i64 = 44;

/// Read a 16-bit little-endian integer (`EOF` at the end of the file).
fn in16(ifile: &mut WfdbFile) -> i16 {
    let a = ifile.getc();
    if a == EOF {
        return EOF as i16;
    }
    let b = ifile.getc();
    if b == EOF {
        return EOF as i16;
    }
    ((a & 0xff) | ((b << 8) & 0xff00)) as i16
}

/// Read a 32-bit little-endian integer (`EOF` at the end of the file).
fn in32(ifile: &mut WfdbFile) -> i64 {
    let mut r: i64 = 0;
    for k in 0..4 {
        let c = ifile.getc();
        if c == EOF {
            return EOF as i64;
        }
        r |= ((c & 0xff) as i64) << (8 * k);
    }
    r
}

const HELP_STRINGS: &[&[u8]] = &[
    b"usage: %s -i FILE.wav -r RECORD [ OPTIONS ... ]\n",
    b"where FILE.wav is the name of the wav-format input signal file,",
    b"and OPTIONS may include:",
    b" -G GAIN    gain in adu per physical unit (required; 0: uncalibrated)",
    b" -h         print this usage summary",
    b" -r RECORD  create RECORD.hea (default: FILE.hea)",
    b" -U UNITS   physical units (required unless the gain is 0)",
];

/// wfdb-x: the lines of `HELP_STRINGS` added by wfdb-x, left out of the
/// help text of the original program (printed in legacy mode).
const WFDBX_HELP_LINES: &[&[u8]] = &[
    b" -G GAIN    gain in adu per physical unit (required; 0: uncalibrated)",
    b" -U UNITS   physical units (required unless the gain is 0)",
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

/// Read 4 bytes and compare them with `tag`.
fn check_tag(ifile: &mut WfdbFile, tag: &[u8; 4]) -> bool {
    let mut buf = [0u8; 4];
    ifile.fread(&mut buf, 1, 4) == 4 && &buf == tag
}

fn main() {
    let mut argv = cstd::args();
    let legacy = wfdbx::wfdbx_legacy_args(&mut argv) != 0; // wfdb-x: --legacy
    let argc = argv.len();
    let pname = cstd::prog_name(&argv[0]).to_vec();
    let mut ifname: Option<Vec<u8>> = None;
    let mut record: Option<Vec<u8>> = None;
    let mut uunits: Option<Vec<u8>> = None; // wfdb-x: -U
    let mut ggain = 0.0; // wfdb-x: -G
    let mut gset = false;

    // Interpret the command line.
    let mut i = 1;
    while i < argc {
        if argv[i].first() == Some(&b'-') {
            match argv[i].get(1).copied().unwrap_or(0) {
                b'G' if !legacy => {
                    // gain in adu per physical unit (wfdb-x)
                    i += 1;
                    if i >= argc || csscanf!(&argv[i], b"%lf", &mut ggain) != 1 || ggain < 0.0 {
                        ceprintf!(b"%s: gain (>= 0) must follow -G\n", pname);
                        cstd::exit(1);
                    }
                    gset = true;
                }
                b'h' => {
                    help(&pname);
                    cstd::exit(1);
                }
                b'i' => {
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: name of wav-format input file must follow -i\n", pname);
                        cstd::exit(1);
                    }
                    let f = cstd::cstr(&argv[i]).to_vec();
                    if f.len() <= b".wav".len() || !f.ends_with(b".wav") {
                        ceprintf!(b"%s: name of input file must end in '.wav'\n", pname);
                        cstd::exit(1);
                    }
                    ifname = Some(f);
                }
                b'r' => {
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: record name must follow -r\n", pname);
                        cstd::exit(1);
                    }
                    record = Some(cstd::cstr(&argv[i]).to_vec());
                }
                b'U' if !legacy => {
                    // physical units (wfdb-x)
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: units must follow -U\n", pname);
                        cstd::exit(1);
                    }
                    uunits = Some(cstd::cstr(&argv[i]).to_vec());
                }
                _ => {
                    ceprintf!(b"%s: unrecognized option %s\n", pname, argv[i]);
                    cstd::exit(1);
                }
            }
        } else {
            ceprintf!(b"%s: unrecognized argument %s\n", pname, argv[i]);
            cstd::exit(1);
        }
        i += 1;
    }

    // Check that required arguments are present and valid.
    let Some(ifname) = ifname else {
        help(&pname);
        cstd::exit(1);
    };
    // wfdb-x: the gain and units must be given explicitly; the C program
    // wrote 12.5 adu/mV for 8-bit and 6400 adu/mV for 16-bit files, with no
    // units (millivolts).  (The sampling frequency and the resolution are
    // those given in the file.)  Legacy mode: as in the C program.
    if !gset && !legacy {
        ceprintf!(b"%s: the gain must be specified (-G)\n", pname);
        cstd::exit(1);
    }
    if ggain != 0.0 && uunits.is_none() && !legacy {
        ceprintf!(b"%s: the units must be specified (-U)\n", pname);
        cstd::exit(1);
    }

    // If the record name was not specified, generate it from ifname.
    let record = record.unwrap_or_else(|| ifname[..ifname.len() - b".wav".len()].to_vec());

    // Open the input file.
    let Some(mut ifile) = WfdbFile::fopen(&ifname, b"rb") else {
        ceprintf!(b"%s: can't open %s\n", pname, ifname);
        cstd::exit(2);
    };

    // Determine the size of the input file.
    ifile.seek(0, SEEK_END);
    let flen = ifile.tell();
    ifile.seek(0, SEEK_SET);

    // Read and check the header chunk.
    if !check_tag(&mut ifile, b"RIFF") {
        ceprintf!(b"%s: %s is not a .wav-format file\n", pname, ifname);
        cstd::exit(3);
    }
    let len = in32(&mut ifile) + CHUNK_HEADER_LEN;
    if len != flen {
        ceprintf!(
            b"%s: header chunk of %s has incorrect length (%ld, should be %ld)\n",
            pname,
            ifname,
            len,
            flen
        );
        cstd::exit(3);
    }
    if !check_tag(&mut ifile, b"WAVE") {
        ceprintf!(b"%s: %s is not a .wav-format file\n", pname, ifname);
        cstd::exit(3);
    }

    // Read and check the format chunk.
    if !check_tag(&mut ifile, b"fmt ") {
        ceprintf!(
            b"%s: format chunk missing or corrupt in %s\n",
            pname,
            ifname
        );
        cstd::exit(3);
    }
    let len = in32(&mut ifile);
    let tag = in16(&mut ifile) as i32;
    if len != FMT_CHUNK_LEN || tag != WAVE_FORMAT_PCM {
        ceprintf!(b"%s: unsupported format %d in %s\n", pname, tag, ifname);
        cstd::exit(3);
    }
    let nsig = in16(&mut ifile) as i32;
    let sps = in32(&mut ifile) as f64;
    in32(&mut ifile); // bytes per second
    let framelen = in16(&mut ifile) as i32;
    let bitspersample = in16(&mut ifile) as i32;
    // (In legacy mode, the gains of the C program: full scale is 10.24 mV
    // with 8 bits, 5.12 mV with 16.)
    let wres: i32 = if bitspersample <= 8 {
        if legacy {
            ggain = 12.5;
        }
        8
    } else if bitspersample <= 16 {
        if legacy {
            ggain = 6400.0;
        }
        16
    } else {
        ceprintf!(
            b"%s: unsupported resolution (%d bits/sample) in %s\n",
            pname,
            bitspersample,
            ifname
        );
        cstd::exit(3);
    };
    if framelen != nsig * wres / 8 {
        ceprintf!(
            b"%s: format chunk of %s has incorrect frame length\n",
            pname,
            ifname
        );
        cstd::exit(3);
    }

    // Read and check the beginning of the data chunk.
    if !check_tag(&mut ifile, b"data") {
        ceprintf!(b"%s: data chunk missing or corrupt in %s\n", pname, ifname);
        cstd::exit(3);
    }
    let len = in32(&mut ifile);
    let wnsamp = if framelen != 0 {
        len / framelen as i64
    } else {
        0
    };

    if nsig < 0 {
        // (malloc fails in the C version)
        ceprintf!(b"%s: insufficient memory\n", pname);
        cstd::exit(2);
    }
    let mut s = vec![Siginfo::default(); nsig as usize];

    for (i, si) in s.iter_mut().enumerate() {
        si.fname = Some(ifname.clone());
        si.desc = None;
        si.units = uunits.clone();
        si.gain = ggain;
        si.initval = 0;
        si.group = 0;
        si.fmt = if wres == 16 { 16 } else { 80 };
        si.spf = 1;
        si.bsize = 0;
        si.adcres = wres;
        si.adczero = if wres == 16 { 0 } else { 128 }; // 8-bit .wav is unsigned
        si.baseline = si.adczero;
        si.nsamp = wnsamp;
        si.cksum = 0;
        wfdbx::wfdbsetstart(i as u32, WAV_HEADER_LEN);
    }
    wfdbx::setsampfreq(sps);

    if wfdbx::setheader(&record, &mut s, nsig as u32) != 0 {
        drop(ifile);
        cstd::exit(4);
    }

    // Clean up.
    wfdbx::wfdbquit();
    drop(ifile);
    cstd::exit(0);
}
