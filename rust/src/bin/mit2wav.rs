//! mit2wav: convert WFDB format signal files to .wav format (port of
//! `convert/mit2wav.c`).
//!
//! The output file has exactly three chunks (a header chunk, a format chunk,
//! and a data chunk); see the C source for a description. The C program
//! writes the header and format chunks to a temporary file, and prepends it
//! to the signal file written by `putvec` using the `mv`, `cat`, and `rm`
//! commands; this port prepends them directly, with the same result. Where
//! the C program has undefined behavior (signals with more than 16 bits of
//! ADC resolution, for which it shifts by a negative amount), this port
//! shifts samples to the right and uses a gain multiplier of 0.
//
// Copyright (C) 2003-2010 George B. Moody (original C program,
// convert/mit2wav.c; revised 2018 by Benjamin Moody).
// Rust implementation part of wfdb-x, Reza Sameni, Oct 2026.
// Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
// gain, ADC resolution or units. Values that the record or the user does not
// give are never assumed (the original package assumed 250 Hz, 200 adu/mV,
// 12 bits and millivolts), because a silently assumed value corrupts every
// result derived from it. See docs/DIVERGENCES.md.
// GNU General Public License, version 2 or later (see LICENSE).

use wfdbx::cstd;
use wfdbx::{ceprintf, Siginfo, WfdbFile, NULL};

// The .wav format (see the C source): a header chunk ("RIFF", length,
// "WAVE"), a format chunk ("fmt ", its length, the PCM format tag, ...), and
// a data chunk ("data", length, then the samples, from byte WAV_HEADER_LEN).
/// Size of a chunk header (tag and length).
const CHUNK_HEADER_LEN: i64 = 8;
/// Length of a PCM format chunk (after its header).
const FMT_CHUNK_LEN: i64 = 16;
/// Format tag of uncompressed (PCM) samples.
const WAVE_FORMAT_PCM: i16 = 1;
/// Offset of the samples.
const WAV_HEADER_LEN: i64 = 44;
/// The samples written: 16-bit (format 16).
const WAV_BITS: i32 = 16;

fn out16(b: &mut Vec<u8>, x: i16) {
    b.extend_from_slice(&x.to_le_bytes());
}

fn out32(b: &mut Vec<u8>, x: i64) {
    b.extend_from_slice(&(x as u32).to_le_bytes());
}

const HELP_STRINGS: &[&[u8]] = &[
    b"usage: %s -o FILE.wav -r RECORD [ OPTIONS ... ]\n",
    b"where FILE.wav is the name of the wav-format output signal file,",
    b"RECORD is the record name, and OPTIONS may include:",
    b" -h         print this usage summary",
    b" -n NEWREC  create a header file for the output signal file, so it",
    b"             may be read as record NEWREC",
];

fn help(pname: &[u8]) {
    ceprintf!(HELP_STRINGS[0], pname);
    for s in &HELP_STRINGS[1..] {
        ceprintf!(b"%s\n", s);
    }
}

fn main() {
    let mut argv = cstd::args();
    let legacy = wfdbx::wfdbx_legacy_args(&mut argv) != 0; // wfdb-x: --legacy
    let argc = argv.len();
    let pname = cstd::prog_name(&argv[0]).to_vec();
    let mut nrec: Option<Vec<u8>> = None;
    let mut ofname: Option<Vec<u8>> = None;
    let mut record: Option<Vec<u8>> = None;
    let mut bitspersample: i32 = 0;

    // Interpret the command line.
    let mut i = 1;
    while i < argc {
        if argv[i].first() == Some(&b'-') {
            match argv[i].get(1).copied().unwrap_or(0) {
                b'h' => {
                    help(&pname);
                    cstd::exit(1);
                }
                b'n' => {
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: new record name must follow -n\n", pname);
                        cstd::exit(1);
                    }
                    nrec = Some(cstd::cstr(&argv[i]).to_vec());
                }
                b'o' => {
                    i += 1;
                    if i >= argc {
                        ceprintf!(
                            b"%s: name of wav-format output file must follow -o\n",
                            pname
                        );
                        cstd::exit(1);
                    }
                    let o = cstd::cstr(&argv[i]).to_vec();
                    if o.len() <= b".wav".len() || !o.ends_with(b".wav") {
                        ceprintf!(b"%s: name of output file must end in '.wav'\n", pname);
                        cstd::exit(1);
                    }
                    ofname = Some(o);
                }
                b'r' => {
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: record name must follow -r\n", pname);
                        cstd::exit(1);
                    }
                    record = Some(cstd::cstr(&argv[i]).to_vec());
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
    let (Some(ofname), Some(record)) = (ofname, record) else {
        help(&pname);
        cstd::exit(1);
    };
    if nrec.as_deref() == Some(&record[..]) {
        ceprintf!(
            b"%s: names of input and output records must not be identical\n",
            pname
        );
        cstd::exit(1);
    }

    // Open the input record and allocate memory for per-signal objects.
    let mut nsig = wfdbx::isigopen(&record, &mut [], 0);
    if nsig <= 0 {
        cstd::exit(2);
    }
    let mut s = vec![Siginfo::default(); nsig as usize];
    nsig = wfdbx::isigopen(&record, &mut s, nsig);
    if nsig <= 0 {
        cstd::exit(3);
    }
    if !legacy && wfdbx::sampfreq(NULL) <= 0.0 {
        // wfdb-x: no default sampling frequency (except in legacy mode)
        ceprintf!(
            b"%s: sampling frequency of record %s is not specified\n",
            pname,
            record
        );
        cstd::exit(3);
    }
    let n = nsig as usize;
    let mut offset = vec![0i32; n];
    let mut shift = vec![0i32; n];
    let mut x = vec![0i32; n];
    let mut y = vec![0i32; n];

    // Check that the new record name is legal before proceeding. Note that
    // this step creates a header file, which is overwritten after the
    // processing is completed.
    if let Some(nr) = &nrec {
        if wfdbx::newheader(nr) < 0 {
            cstd::exit(3);
        }
    }

    // Set the output signal parameters.
    for i in 0..n {
        let si = &mut s[i];
        if si.adcres > bitspersample {
            bitspersample = si.adcres;
        }
        offset[i] = si.adczero;
        si.adczero = 0;
        shift[i] = WAV_BITS - si.adcres;
        si.adcres = WAV_BITS;
        let mag: i32 = if shift[i] >= 0 {
            1u32.wrapping_shl(shift[i] as u32) as i32
        } else {
            0
        };
        si.gain *= mag as f64;
        si.baseline = si.baseline.wrapping_sub(offset[i]);
        si.baseline = (si.baseline as u32).wrapping_mul(mag as u32) as i32;
        si.fname = Some(ofname.clone());
        si.group = 0;
        si.fmt = 16;
        si.spf = 1;
    }

    // Get information needed for the header and format chunks.
    let nsamp = wfdbx::strtim("e");
    let sps = wfdbx::strtim("1") as f64;
    let framelen = nsig.wrapping_mul(WAV_BITS / 8);

    // Give up if the output cannot be written.
    if wfdbx::osigfopen(&s, nsig as u32) < nsig {
        cstd::exit(4);
    }

    for i in 0..nsig {
        wfdbx::wfdbsetstart(i as u32, WAV_HEADER_LEN);
    }

    // Make the header and format chunks, and the first 8 bytes of the data
    // chunk (written to a temporary file in the C version).
    let mut hdr: Vec<u8> = b"RIFF".to_vec();
    // nsamp*framelen sample bytes, and the rest of the header
    out32(
        &mut hdr,
        nsamp
            .wrapping_mul(framelen as i64)
            .wrapping_add(WAV_HEADER_LEN - CHUNK_HEADER_LEN),
    );
    hdr.extend_from_slice(b"WAVEfmt ");
    out32(&mut hdr, FMT_CHUNK_LEN); // number of bytes to follow in format chunk
    out16(&mut hdr, WAVE_FORMAT_PCM); // format tag
    out16(&mut hdr, nsig as i16);
    out32(&mut hdr, cstd::d2l(sps));
    out32(&mut hdr, cstd::d2l(sps * framelen as f64));
    out16(&mut hdr, framelen as i16);
    out16(&mut hdr, bitspersample as i16);
    hdr.extend_from_slice(b"data");
    out32(&mut hdr, nsamp.wrapping_mul(framelen as i64));

    // Copy the input to the output. Reformatting is handled by putvec().
    while wfdbx::getvec(&mut x) == nsig {
        for i in 0..n {
            let d = x[i].wrapping_sub(offset[i]);
            y[i] = if shift[i] >= 0 {
                (d as u32).wrapping_shl(shift[i] as u32) as i32
            } else {
                d.wrapping_shr((-shift[i]) as u32)
            };
        }
        if wfdbx::putvec(&y) != nsig {
            break;
        }
    }

    // Write the new header file if requested.
    wfdbx::setsampfreq(wfdbx::sampfreq(NULL));
    if let Some(nr) = &nrec {
        wfdbx::newheader(nr);
    }

    // Clean up.
    wfdbx::wfdbquit();

    // Prepend the header and format chunks to the new signal file.
    let mut data = Vec::new();
    if let Some(mut f) = WfdbFile::fopen(&ofname, b"rb") {
        data = f.read_to_end();
        f.close();
    }
    if let Some(mut f) = WfdbFile::fopen(&ofname, b"wb") {
        f.write(&hdr);
        f.write(&data);
        f.close();
    }

    cstd::exit(0);
}
