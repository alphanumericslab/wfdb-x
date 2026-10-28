//! mit2edf: convert MIT format header and signal files to EDF (European
//! Data Format) file (port of `convert/mit2edf.c`).
//!
//! As in the C program, the current date and time are used as the start of
//! a record that has none. Where the C program has undefined behavior, this
//! port uses: 0 for time and date fields that cannot be parsed; the first
//! 50 characters of a long record name for the default output file name;
//! and it does not write header fields past the end of the header (if they
//! are longer than their space), divide by zero (when no frame fits in a
//! block, or in verbose mode when a block is longer than a minute), or name
//! a month outside 1-12 (DEC is used).
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Rust translation of convert/mit2edf.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: no built-in sampling frequency, gain or ADC
// resolution: the record must give the sampling frequency, and the gain and
// ADC resolution of every signal (the original assumed 250 Hz and 200 adu/mV,
// and guessed the resolution from the storage format); unspecified units are
// written as "nd" (the original wrote "mV"); an EDF file that cannot be
// written is reported, and the exit status is then 1; --legacy, as the first
// argument, restores the original behavior. Each change is marked "WFDB-x:" in
// the code; docs/DIVERGENCES.md gives the reasons.
//
// Original C program: convert/mit2edf.c, WFDB Software Package 10.7.0.
//   Copyright (C) 2002-2014 George B. Moody; revised 2020 by Benjamin Moody.
// Rust translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

use wfdbx::cstd::{self, d2l};
use wfdbx::{
    ceprintf, cformat, cprintf, csscanf, Siginfo, WfdbFile, NULL, WFDB_INVALID_SAMPLE, WFDB_MAXRNL,
};

const EDFMAXBLOCK: i64 = 61440; // maximum data block length, in bytes
/// Size of the fixed part of an EDF header, and of each signal's part.
const EDFHDRBLOCK: i64 = 256;
/// Bytes per sample in EDF data blocks.
const EDFSAMPLEBYTES: i64 = 2;

const MONTH_NAME: [&[u8]; 12] = [
    b"JAN", b"FEB", b"MAR", b"APR", b"MAY", b"JUN", b"JUL", b"AUG", b"SEP", b"OCT", b"NOV", b"DEC",
];

const HELP_STRINGS: &[&[u8]] = &[
    b"usage: %s -r RECORD [OPTIONS ...]\n",
    b"where RECORD is the name of the input record, and OPTIONS may include:",
    b" -h          print this usage summary",
    b" -o EDFILE   write the specified European Data Format file (default:",
    b"              RECORD.edf)",
    b" -p          write the output as an EDF+ file",
    b" -v          select verbose mode",
    b"This program reads MIT-format signal and header files and writes an EDF",
    b"file containing the same data.",
];

fn help(pname: &[u8]) {
    ceprintf!(HELP_STRINGS[0], pname);
    for s in &HELP_STRINGS[1..] {
        ceprintf!(b"%s\n", s);
    }
}

/// The EDF header being built, with the current position.
struct Header {
    h: Vec<u8>,
    pos: usize,
}

impl Header {
    /// `strncpy(header + pos, s, len)`: copy at most `len` bytes of `s`,
    /// padding with NULs (within the header).
    fn put(&mut self, s: &[u8], len: usize) {
        let s = cstd::cstr(s);
        for m in 0..len {
            if self.pos + m >= self.h.len() {
                break;
            }
            self.h[self.pos + m] = if m < s.len() { s[m] } else { 0 };
        }
    }

    /// Copy all of `s`.
    fn puts(&mut self, s: &[u8]) {
        self.put(s, cstd::cstr(s).len());
    }
}

/// The ADC resolution the C program guessed from the storage format
/// (legacy mode).
fn guess_adcres(fmt: i32) -> i32 {
    match fmt {
        524 | 24 => 24,
        32 => 32,
        508 | 80 => 8,
        212 => 12,
        310 | 311 => 10,
        516 | 16 | 61 | 160 => 16,
        // resolution for unknown future formats
        f if f >= 100 && f % 100 > 0 && f % 100 <= 32 => f % 100,
        _ => 16,
    }
}

fn main() {
    let mut argv = cstd::args();
    let legacy = wfdbx::wfdbx_legacy_args(&mut argv) != 0; // WFDB-x: --legacy
    let argc = argv.len();
    let pname = argv[0].clone();
    let mut ofname: Option<Vec<u8>> = None;
    let mut record: Option<Vec<u8>> = None;
    let mut edfplusflag = false;
    let mut vflag = false;
    let (mut day, mut month, mut year) = (0i32, 0i32, 0i32);
    let (mut hour, mut minute, mut second) = (0i32, 0i32, 0i32);
    let mut blocks_per_minute: i64 = 0;
    let mut blocks_per_hour: i64 = 0;

    // Interpret the command line.
    let mut i = 1;
    while i < argc {
        if argv[i].first() == Some(&b'-') {
            match argv[i].get(1).copied().unwrap_or(0) {
                b'h' => {
                    // show usage and quit
                    help(&pname);
                    cstd::exit(0);
                }
                b'o' => {
                    // output file name follows
                    i += 1;
                    if i < argc {
                        ofname = Some(cstd::cstr(&argv[i]).to_vec());
                    } else {
                        ceprintf!(b"%s: output file name must follow -o\n", pname);
                        cstd::exit(1);
                    }
                }
                b'p' => edfplusflag = true, // format output as EDF+
                b'r' => {
                    // record name follows
                    i += 1;
                    if i < argc {
                        record = Some(cstd::cstr(&argv[i]).to_vec());
                    } else {
                        ceprintf!(b"%s: record name must follow -r\n", pname);
                        cstd::exit(1);
                    }
                }
                b'v' => vflag = true, // select verbose mode
                _ => {}
            }
        }
        i += 1;
    }

    // Quit if no record was specified.
    let Some(mut record) = record else {
        help(&pname);
        cstd::exit(1);
    };

    // Construct or validate the name of the output file.
    let ofname: Vec<u8> = match ofname {
        None => {
            let q = match record.iter().rposition(|&c| c == b'/') {
                Some(p) => p + 1,
                None => 0,
            };
            let tail = &record[q..];
            let mut o = tail[..tail.len().min(WFDB_MAXRNL)].to_vec();
            o.extend_from_slice(b".edf");
            o
        }
        Some(o) => {
            if edfplusflag {
                let len = o.len();
                let p = &o[len.saturating_sub(4)..];
                if p != b".edf" && p != b".EDF" {
                    ceprintf!(b"%s: '%s' is not a valid EDF+ file name\n", pname, o);
                    ceprintf!(b" EDF+ file names must end with '.edf' or '.EDF')\n");
                    cstd::exit(1);
                }
            }
            o
        }
    };

    // Open the input record.
    let mut nsig = wfdbx::isigopen(&record, &mut [], 0);
    if nsig <= 0 {
        cstd::exit(2);
    }
    let mut si = vec![Siginfo::default(); nsig as usize];
    nsig = wfdbx::isigopen(&record, &mut si, nsig);
    if nsig <= 0 {
        cstd::exit(3);
    }

    // WFDB-x: an EDF file needs the sampling frequency, and the gain and ADC
    // resolution of each signal (the C program assumed 250 Hz and 200 adu/mV
    // if the header did not specify them, and guessed the resolution from
    // the format), as legacy mode does.
    if !legacy && wfdbx::sampfreq(NULL) <= 0.0 {
        ceprintf!(
            b"%s: sampling frequency of record %s is not specified\n",
            pname,
            record
        );
        cstd::exit(3);
    }
    for (i, s) in si[..nsig as usize].iter().enumerate().filter(|_| !legacy) {
        if s.gain == 0.0 {
            ceprintf!(
                b"%s: signal %d of record %s is uncalibrated\n",
                pname,
                i as i32,
                record
            );
            cstd::exit(3);
        }
        if s.adcres < 1 {
            // the EDF digital range needs it (WFDB-x: no default resolution)
            ceprintf!(
                b"%s: ADC resolution of signal %d of record %s is not specified\n",
                pname,
                i as i32,
                record
            );
            cstd::exit(3);
        }
    }
    let ns = nsig as usize;

    // Open the output (EDF) file.
    let Some(mut ofile) = WfdbFile::fopen(&ofname, b"wb") else {
        ceprintf!(b"%s: can't create %s\n", pname, ofname);
        cstd::exit(4);
    };

    // Get start date and time
    let mut ts = wfdbx::timstr(0);
    let mut start_date_recorded = true;
    if ts.first() != Some(&b'[') {
        // start date/time not recorded -- use current date
        wfdbx::setbasetime(NULL);
        ts = wfdbx::timstr(0);
        start_date_recorded = false;
    }
    let n = csscanf!(
        &ts,
        b"[%d:%d:%d %d/%d/%d",
        &mut hour,
        &mut minute,
        &mut second,
        &mut day,
        &mut month,
        &mut year
    );
    if n != 6 {
        // start time, but not date, recorded
        start_date_recorded = false;
        day = 1;
        month = 1;
        year = 1985; // beginning of EDF epoch
    }

    // Calculate block duration. (In the EDF spec, blocks are called
    // "records" or "data records", but this would be confusing here since
    // "record" refers to the entire recording -- so here we say "blocks".)
    let mut samples_per_frame: i32 = 0;
    for s in &si {
        samples_per_frame = samples_per_frame.wrapping_add(s.spf);
    }
    // i.e., the number of frames per minute, divided by 60
    let frames_per_second = wfdbx::strtim("1:0") as f64 / 60.0;
    let mut frames_per_block = d2l(10.0 * frames_per_second + 0.5); // ten seconds
    let mut bytes_per_block =
        (EDFSAMPLEBYTES * samples_per_frame as i64).wrapping_mul(frames_per_block);
    while bytes_per_block > EDFMAXBLOCK {
        // blocks would be too long -- reduce their length by a factor of 10
        frames_per_block /= 10;
        bytes_per_block =
            (samples_per_frame as i64 * EDFSAMPLEBYTES).wrapping_mul(frames_per_block);
    }

    let mut seconds_per_block = frames_per_block as f64 / frames_per_second;

    if frames_per_block < 1 && bytes_per_block < EDFMAXBLOCK / 60 {
        frames_per_block = wfdbx::strtim("1:0"); // the number of frames/minute
        bytes_per_block =
            (EDFSAMPLEBYTES * samples_per_frame as i64).wrapping_mul(frames_per_block);
        seconds_per_block = 60.0;
    }

    if bytes_per_block > EDFMAXBLOCK {
        ceprintf!(b"%s: can't convert record %s to EDF\n", pname, record);
        ceprintf!(
            b" EDF blocks cannot be larger than %d bytes, but each input frame requires\n",
            EDFMAXBLOCK as i32
        );
        ceprintf!(
            b" %d bytes.  Use 'snip' to select a subset of the input signals, or use\n 'xform' to reduce the sampling frequency.\n",
            samples_per_frame.wrapping_mul(EDFSAMPLEBYTES as i32)
        );
        drop(ofile);
        cstd::exit(5);
    }

    // Calculate the number of blocks to be written. strtim("e") is the
    // frame number of the last frame in the record, and that of the first
    // frame is 0, so the number of frames is strtim("e") + 1. The
    // calculation rounds up so that we don't lose any frames, even if the
    // number of frames is not an exact multiple of frames_per_block.
    let nblocks: i64 = (if frames_per_block != 0 {
        wfdbx::strtim("e").wrapping_div(frames_per_block)
    } else {
        0
    }) + 1;

    // Allocate and initialize arrays and buffers.
    let mut dmax = vec![0i32; ns];
    let mut dmin = vec![0i32; ns];
    let mut pmax = vec![0f64; ns];
    let mut pmin = vec![0f64; ns];
    let hlen = (ns + 1) * EDFHDRBLOCK as usize;
    let mut hd = Header {
        h: vec![b' '; hlen],
        pos: 0,
    };
    let mut v = vec![0i32; samples_per_frame.max(0) as usize];
    let mut block = vec![0u8; bytes_per_block.max(0) as usize];
    let mut blockp = vec![0i64; ns]; // offsets within block

    if vflag {
        let mode: &[u8] = if edfplusflag { b"EDF+" } else { b"EDF" };
        cprintf!(
            b"Converting record %s to %s (%s mode)\n",
            record,
            ofname,
            mode
        );
    }

    // Calculate physical and digital extrema.
    for i in 0..ns {
        let s = &mut si[i];
        // (WFDB-x: the ADC resolution was checked above; the C program
        // guessed it from the storage format if the header did not give it,
        // as legacy mode does.)
        if legacy && s.adcres < 1 {
            // invalid ADC resolution in input .hea file
            s.adcres = guess_adcres(s.fmt);
        }
        // (the shift count is masked as x86 masks it)
        let half: u32 = 1u32 << ((s.adcres.wrapping_sub(1)) & 31);
        dmax[i] = (s.adczero as u32).wrapping_add(half).wrapping_sub(1) as i32;
        dmin[i] = (s.adczero as u32).wrapping_sub(half) as i32;
        pmax[i] = wfdbx::aduphys(i as u32, dmax[i]);
        pmin[i] = wfdbx::aduphys(i as u32, dmin[i]);
    }

    // Start filling in the header. The first line of comments above each
    // entry is as given in the EDF technical specification
    // (http://www.hsr.nl/edf/edf_spec.htm).

    // Version of this data format (0).
    hd.put(b"0", 1);
    hd.pos += 8;

    // Local patient identification.
    if record.len() > 80 {
        record.truncate(79);
    }
    hd.puts(&record);
    hd.pos += 80;

    // Local recording identification.
    //
    // Bob Kemp recommends using this field to encode the start date
    // including an abbreviated month name in English and a full (4-digit)
    // year, as is done here if this information is available in the input
    // record. EDF+ requires this.
    let buf = if start_date_recorded {
        let m = if (1..=12).contains(&month) {
            (month - 1) as usize
        } else {
            11 // (an invalid month, undefined behavior in C, gives "DEC")
        };
        cformat!(b"Startdate %02d-%s-%d", day, MONTH_NAME[m], year)
    } else {
        if edfplusflag {
            ceprintf!(
                b"WARNING (%s): EDF+ requires start date (not specified)\n",
                pname
            );
        }
        b"Startdate not recorded".to_vec()
    };
    hd.puts(&buf);
    hd.pos += 80;

    // Start date of recording (dd.mm.yy).
    let buf = cformat!(b"%02d.%02d.%02d", day, month, year.wrapping_rem(100));
    hd.put(&buf, 8);
    hd.pos += 8;

    // Start time of recording (hh.mm.ss).
    let buf = cformat!(b"%02d.%02d.%02d", hour, minute, second);
    hd.put(&buf, 8);
    hd.pos += 8;

    // Number of bytes in header.
    hd.puts(&cformat!(b"%ld", (nsig as i64 + 1) * EDFHDRBLOCK));
    hd.pos += 8;

    // Reserved.
    if edfplusflag {
        hd.put(b"EDF+C", 5);
    }
    hd.pos += 44;

    // Number of blocks (-1 if unknown).
    hd.puts(&cformat!(b"%ld", nblocks));
    hd.pos += 8;

    // Duration of a block, in seconds.
    let mut buf = cformat!(b"%g", seconds_per_block);
    buf.truncate(8);
    hd.puts(&buf);
    hd.pos += 8;

    // Number of signals.
    hd.puts(&cformat!(b"%d", nsig));
    hd.pos += 4;

    // Label (e.g., EEG FpzCz or Body temp).
    for s in &mut si {
        let d = s.desc.get_or_insert_with(Vec::new);
        if d.len() > 16 {
            d.truncate(16);
        }
        hd.puts(d);
        hd.pos += 16;
    }

    // Transducer type (e.g., AgAgCl electrode).
    for _ in 0..ns {
        hd.puts(b"transducer type not recorded");
        hd.pos += 80;
    }

    // Physical dimension (e.g., uV or degreeC).
    for s in &mut si {
        // WFDB-x: unspecified units are shown as "nd" (C, legacy mode: mV)
        let u = s.units.get_or_insert_with(|| {
            if legacy {
                b"mV".to_vec()
            } else {
                b"nd".to_vec()
            }
        });
        if u.len() > 8 {
            u.truncate(8);
        }
        hd.puts(u);
        hd.pos += 8;
    }

    // Physical minimum (e.g., -500 or 34).
    for &x in &pmin {
        hd.puts(&cformat!(b"%g", x));
        hd.pos += 8;
    }

    // Physical maximum (e.g., 500 or 40).
    for &x in &pmax {
        hd.puts(&cformat!(b"%g", x));
        hd.pos += 8;
    }

    // Digital minimum (e.g., -2048).
    for &x in &dmin {
        hd.puts(&cformat!(b"%d", x));
        hd.pos += 8;
    }

    // Digital maximum (e.g., 2047).
    for &x in &dmax {
        hd.puts(&cformat!(b"%d", x));
        hd.pos += 8;
    }

    // Prefiltering (e.g., HP:0.1Hz LP:75Hz).
    for _ in 0..ns {
        hd.puts(b"prefiltering not recorded");
        hd.pos += 80;
    }

    // Number of samples per block.
    for s in &si {
        hd.puts(&cformat!(
            b"%ld",
            frames_per_block.wrapping_mul(s.spf as i64)
        ));
        hd.pos += 8;
    }

    // (The last 32*nsig bytes in the header are unused.)

    // Write the header to the output file.
    let header = hd.h;
    ofile.write(&header);

    // Check that all characters in the header are valid (printable ASCII
    // between 32 and 126 inclusive). Note that this test does not prevent
    // generation of files containing invalid characters; it merely warns
    // the user if this has happened.
    for (i, &c) in header.iter().enumerate() {
        let c = c as i8 as i32;
        if !(32..=126).contains(&c) {
            ceprintf!(
                b"WARNING (%s): output contains an invalid character, %d, at byte %d\n",
                pname,
                c,
                i as i32
            );
        }
    }

    // In verbose mode, summarize what we've done so far.
    if vflag {
        cprintf!(
            b" Header block size: %d bytes\n",
            (nsig + 1) * EDFHDRBLOCK as i32
        );
        let s1: &[u8] = if seconds_per_block == 1.0 { b"" } else { b"s" };
        let s2: &[u8] = if frames_per_block == 1 { b"" } else { b"s" };
        cprintf!(
            b" Data block size: %g second%s (%ld frame%s or %ld bytes)\n",
            seconds_per_block,
            s1,
            frames_per_block,
            s2,
            bytes_per_block
        );
        let es = wfdbx::timstr(wfdbx::strtim("e"));
        let k = es.iter().take_while(|&&c| c == b' ').count();
        cprintf!(
            b" Recording length: %s (%ld data blocks, %ld frames, %ld bytes)\n",
            &es[k..],
            nblocks,
            nblocks.wrapping_mul(frames_per_block),
            nblocks.wrapping_mul(bytes_per_block)
        );
        cprintf!(
            b" Total length of file to be written: %ld bytes\n",
            (nsig as i64 + 1) * EDFHDRBLOCK + nblocks.wrapping_mul(bytes_per_block)
        );

        blocks_per_minute = d2l(60.0 / seconds_per_block);
        blocks_per_hour = blocks_per_minute.wrapping_mul(60);
    }

    // Write the data blocks.
    let mut n: i64 = 1;
    while n <= nblocks {
        if ns > 0 {
            blockp[0] = 0;
        }
        for j in 1..ns {
            blockp[j] = blockp[j - 1].wrapping_add(
                (EDFSAMPLEBYTES * frames_per_block).wrapping_mul(si[j - 1].spf as i64),
            );
        }
        for _ in 0..frames_per_block {
            if nsig != wfdbx::getframe(&mut v) {
                // end of input: pad last block with invalid samples
                v.fill(WFDB_INVALID_SAMPLE);
            }
            let mut vp = 0usize;
            for j in 0..ns {
                for _ in 0..si[j].spf {
                    let x = v[vp];
                    vp += 1;
                    let b = blockp[j] as usize;
                    if let Some(c) = block.get_mut(b) {
                        *c = (x & 0xff) as u8;
                    }
                    if let Some(c) = block.get_mut(b + 1) {
                        *c = ((x >> 8) & 0xff) as u8;
                    }
                    blockp[j] += EDFSAMPLEBYTES;
                }
            }
        }
        ofile.write(&block);
        if vflag {
            if blocks_per_minute != 0 && n.wrapping_rem(blocks_per_minute) == 0 {
                cprintf!(b".");
                cstd::out().flush();
            }
            if blocks_per_hour != 0 && n.wrapping_rem(blocks_per_hour) == 0 {
                cprintf!(b"\n");
            }
        }
        n += 1;
    }
    wfdbx::wfdbx_fclose_output(ofile, &pname, &ofname); // WFDB-x
    cprintf!(b"\n");

    if edfplusflag {
        ceprintf!(
            b"\nWARNING (%s): EDF+ requires the subject's gender, birthdate, and name, as\n well as additional information about the recording that is not usually\n available.  This information is not saved in the output file even if\n available.  EDF+ also requires the use of standard names for signals and\n for physical units;  these requirements are not enforced by this program.\n To make the output file fully EDF+ compliant, its header must be edited\n manually.\n",
            pname
        );
        if !si
            .iter()
            .any(|s| s.desc.as_deref() == Some(b"EDF-Annotations"))
        {
            ceprintf!(
                b"\nWARNING:  The output file does not include EDF annotations, which are\n required for EDF+.\n"
            );
        }
    }

    wfdbx::wfdbquit();
    cstd::exit(0);
}
