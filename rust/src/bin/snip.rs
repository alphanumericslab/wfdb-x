//! snip: copy an excerpt of a database record (port of `app/snip.c`).
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Rust translation of app/snip.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: no built-in sampling frequency: the input record
// must give it, for the header of the excerpt (the original assumed 250 Hz);
// a master header that cannot be written is reported, and the exit status is
// then 1; --legacy, as the first argument, restores the original behavior.
// Each change is marked "wfdb-x:" in the code; docs/DIVERGENCES.md gives the
// reasons.
//
// Original C program: app/snip.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1989-2013 George B. Moody; revised 2011-2021 by
//   Benjamin Moody.
// Rust translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

use wfdbx::cstd;
use wfdbx::{
    ceprintf, cformat, cfprintf, Anninfo, Annotation, Seginfo, Siginfo, WfdbFile, NULL, WFDB_READ,
    WFDB_WRITE,
};

const HELP_STRINGS: &[&str] = &[
    "usage: %s -i IREC -n NREC [OPTIONS ...]\n",
    "where IREC is the name of the record to be converted, NREC is the name to",
    "be given to the record to be generated, and OPTIONS may include any of:",
    " -a ANNOTATOR [ANNOTATOR ...]  copy annotations for the specified ANNOTATOR",
    "              from IREC;  two or more ANNOTATORs may follow -a",
    " -f TIME     begin at specified time",
    " -h          print this usage summary",
    " -l DURATION snip only DURATION (hh:mm:ss or sNNNN; overrides -t)",
    " -m          preserve segments of multsegment input, if possible",
    " -O FORMAT   save output in the specified FORMAT (default: use best fit",
    "              to ADC resolution)",
    " -s          suppress output of info strings in header",
    " -t TIME     stop at specified time",
    "To change the sampling frequency, zero level, or gain, to select a",
    "subset of signals, or to re-order signals, use `xform'.",
];

/// The program's global state.
struct Snip {
    pname: Vec<u8>,
    fmt: i32,   // use specified output format if fmt > 0
    mflag: i32, // try to preserve segments if non-zero
    sflag: i32, // suppress copying info if non-zero
    /// Master header files being written (C closes them at `exit`).
    open_files: Vec<WfdbFile>,
}

impl Snip {
    fn help(&self) {
        ceprintf!(HELP_STRINGS[0].as_bytes(), self.pname);
        for s in &HELP_STRINGS[1..] {
            ceprintf!(b"%s\n", *s);
        }
    }

    /// C `exit`: the files the program opened are flushed and closed.
    fn exit(&mut self, status: i32) -> ! {
        for f in self.open_files.drain(..).rev() {
            f.close();
        }
        cstd::exit(status);
    }

    fn copy_ann(&mut self, nrec: &[u8], irec: &[u8], from: i64, to: i64, annotators: &[Vec<u8>]) {
        let nann = annotators.len();
        let mut annot = Annotation::default();

        // Set up data structures for nann annotators.
        let ai: Vec<Anninfo> = annotators
            .iter()
            .map(|a| Anninfo {
                name: a.clone(),
                stat: WFDB_READ,
            })
            .collect();
        let ao: Vec<Anninfo> = annotators
            .iter()
            .map(|a| Anninfo {
                name: a.clone(),
                stat: WFDB_WRITE,
            })
            .collect();

        // Open the input annotators.
        if wfdbx::annopen(irec, &ai, nann as u32) < 0 {
            ceprintf!(b"%s: error opening input annotators\n", self.pname);
            self.exit(2);
        }

        // Open the output annotators.
        let mut orec = b"+".to_vec();
        orec.extend_from_slice(nrec);
        if wfdbx::annopen(&orec, &ao, nann as u32) < 0 {
            ceprintf!(b"%s: error opening output annotators\n", self.pname);
            self.exit(2);
        }

        // Copy the selected segment.
        for i in 0..nann as u32 {
            while wfdbx::getann(i, &mut annot) == 0 {
                if annot.time >= from && (to == 0 || annot.time < to) {
                    annot.time -= from;
                    if wfdbx::putann(i, &annot) < 0 {
                        break;
                    }
                }
            }
        }
        wfdbx::wfdbquit();
    }

    fn copy_sig(&mut self, nrec: &[u8], irec: &[u8], from: i64, mut to: i64, recurse: i32) {
        let mut tstring: Option<Vec<u8>> = None;

        wfdbx::wfdbquit();
        let nsig = wfdbx::isigopen(irec, &mut [], 0);
        if nsig < 0 {
            ceprintf!(b"%s: error opening header for %s\n", self.pname, irec);
            self.exit(2);
        }

        // Allocate data structures for nsig signals.
        let mut v = vec![0i32; nsig.max(1) as usize];
        let mut si = vec![Siginfo::default(); nsig as usize];

        // Open the input signals.
        if wfdbx::isigopen(irec, &mut si, nsig) != nsig {
            ceprintf!(b"%s: error opening signals for %s\n", self.pname, irec);
            self.exit(2);
        }

        let ps = wfdbx::mstimstr(-from);
        if ps.first() == Some(&b'[') {
            let mut ts = cstd::cstr(&ps[1..]).to_vec();
            if let Some(k) = ts.iter().position(|&c| c == b']') {
                ts.truncate(k);
            }
            if let Some(k) = ts.iter().position(|&c| c == b' ') {
                if !ts[k..].contains(&b'/') {
                    ts.truncate(k);
                }
            }
            tstring = Some(ts);
        }

        let mut seginfop: Option<Vec<Seginfo>> = None;
        let maxseg = if recurse != 0 {
            wfdbx::getseginfo(&mut seginfop)
        } else {
            0
        };
        if recurse != 0 && maxseg > 0 {
            // irec has multiple segments
            let maxseg = maxseg as usize;
            let sfreq = wfdbx::sampfreq(NULL);
            let seginfo: Vec<Seginfo> = seginfop.unwrap_or_default();

            let mut ohfname = nrec.to_vec();
            ohfname.extend_from_slice(b".hea");
            let ohfile = match WfdbFile::fopen(&ohfname, b"wb") {
                Some(f) => f,
                None => {
                    ceprintf!(b"%s: can't create master header\n", self.pname);
                    self.exit(2);
                }
            };
            self.open_files.push(ohfile);
            let oh = self.open_files.len() - 1;

            if seginfo[0].nsamp == 0 {
                // irec has variable layout
                let mut olrecname = nrec.to_vec();
                olrecname.extend_from_slice(b"_layout");

                for s in &mut si {
                    s.fname = Some(b"~".to_vec());
                    s.fmt = 0;
                    s.nsamp = 0;
                    s.cksum = 0;
                }

                if let Some(ts) = &tstring {
                    wfdbx::setbasetime(ts);
                }

                if 0 > wfdbx::setheader(&olrecname, &mut si, nsig as u32) {
                    ceprintf!(b"%s: can't create layout header\n", self.pname);
                    self.exit(2);
                }

                if self.sflag == 0 {
                    wfdbx::wfdbquiet(); // Suppress errors from the WFDB library.
                    let mut info = wfdbx::getinfo(irec);
                    while let Some(s) = info {
                        wfdbx::putinfo(&s);
                        info = wfdbx::getinfo(NULL);
                    }
                    wfdbx::wfdbverbose();
                    self.sflag = 1;
                }
            }

            // Figure out which input segments contain data to be copied
            let mut first_seg = 0;
            let mut last_seg = maxseg - 1;
            for (i, s) in seginfo.iter().enumerate().take(maxseg) {
                let t = s.samp0;
                let tf = s.samp0 + s.nsamp;
                if t <= from && from < tf {
                    first_seg = i;
                }
                if t <= to && to <= tf {
                    last_seg = i;
                    break;
                }
            }
            let mut nseg = last_seg as i32 - first_seg as i32 + 1;
            if seginfo[0].nsamp == 0 {
                nseg += 1;
            }

            let tf = seginfo[last_seg].samp0 + seginfo[last_seg].nsamp;
            if to > tf {
                to = tf;
            }

            // Start writing the master output header.
            cfprintf!(
                self.open_files[oh],
                b"%s/%d %d %.12g %lld",
                nrec,
                nseg,
                nsig,
                sfreq,
                to - from
            );
            if let Some(ts) = &tstring {
                cfprintf!(self.open_files[oh], b" %s", ts);
            }
            cfprintf!(self.open_files[oh], b"\r\n");

            if seginfo[0].nsamp == 0 {
                cfprintf!(self.open_files[oh], b"%s_layout 0\r\n", nrec);
            }

            let mut i = 0;
            for seg in &seginfo[first_seg..=last_seg] {
                let t = seg.samp0;
                let mut tf = seg.samp0 + seg.nsamp;
                if to < tf {
                    // this is the last segment with data to copy
                    tf = to;
                }
                let (start, len) = if from > t {
                    (from - t, tf - from)
                } else {
                    (0, tf - t)
                };
                let orsegs = if cstd::cstr(&seg.recname) == b"~" {
                    b"~".to_vec()
                } else {
                    i += 1;
                    let mut o = nrec.to_vec();
                    o.extend_from_slice(&cformat!(b"_%04d", i));
                    self.copy_sig(&o, &seg.recname, start, start + len, 0);
                    o
                };
                cfprintf!(self.open_files[oh], b"%s %lld\r\n", orsegs, len);
            }
            let ohfile = self.open_files.remove(oh);
            wfdbx::wfdbx_fclose_output(ohfile, &self.pname, &ohfname); // WFDB-x
            return;
        }

        if self.fmt <= 0 {
            // no -O option, choose format based on ADC resolution
            let mut maxres = si[0].adcres;
            let mut fmt = si[0].fmt;
            for s in &si[1..] {
                if s.adcres > maxres {
                    maxres = s.adcres;
                }
                if s.fmt != fmt {
                    fmt = 0;
                }
            }
            if fmt == 0 {
                // the most compact format whose samples have at least
                // maxres bits
                fmt = if maxres > 24 {
                    32
                } else if maxres > 16 {
                    24
                } else if maxres > 12 {
                    16
                } else if maxres > 10 {
                    212
                } else if maxres > 8 {
                    310
                } else {
                    80
                };
            }
            self.fmt = fmt;
        }

        // Open the output signals.
        let mut ofname = nrec.to_vec();
        ofname.extend_from_slice(b".dat");
        for s in &mut si {
            s.fname = Some(ofname.clone());
            s.group = 0;
            s.fmt = self.fmt;
            s.spf = 1;
        }
        if wfdbx::osigfopen(&si, nsig as u32) != nsig {
            self.exit(2);
        }

        // Copy the selected segment.
        if wfdbx::isigsettime(from) < 0 {
            self.exit(2);
        }
        wfdbx::wfdbquiet();
        let mut nsamp: i64 = if to == 0 { -1 } else { to - from };
        while nsamp == -1 || {
            let c = nsamp > 0;
            nsamp -= 1;
            c
        } {
            let stat = wfdbx::getvec(&mut v);
            if stat > 0 || nsamp == 0 {
                wfdbx::putvec(&v);
            } else {
                break;
            }
        }

        // Clean up.
        wfdbx::wfdbverbose();
        wfdbx::setsampfreq(wfdbx::sampfreq(NULL));
        if let Some(ts) = &tstring {
            wfdbx::setbasetime(ts);
        }
        let _ = wfdbx::newheader(nrec);
    }

    fn copy_info(&self, irec: &[u8], startp: &[u8]) {
        wfdbx::wfdbquiet(); // Suppress error messages from the WFDB library.
        let mut info = wfdbx::getinfo(irec);
        while let Some(s) = info {
            let _ = wfdbx::putinfo(&s);
            info = wfdbx::getinfo(NULL);
        }
        // Append additional info summarizing what snip has done.
        let xinfo = cformat!(
            b"Produced by %s from record %s, beginning at %s",
            self.pname,
            irec,
            startp
        );
        let _ = wfdbx::putinfo(&xinfo);
        wfdbx::wfdbverbose();
    }
}

fn main() {
    let mut argv = cstd::args();
    let legacy = wfdbx::wfdbx_legacy_args(&mut argv) != 0; // wfdb-x: --legacy
    let argc = argv.len();
    let mut sn = Snip {
        pname: cstd::prog_name(&argv[0]).to_vec(),
        fmt: 0,
        mflag: 0,
        sflag: 0,
        open_files: Vec::new(),
    };
    let pname = sn.pname.clone();
    let mut nrec: Option<&[u8]> = None;
    let mut irec: Option<&[u8]> = None;
    let mut startp: Option<&[u8]> = None;
    let mut endp: Option<&[u8]> = None;
    let mut length: Option<&[u8]> = None;
    let (mut ann_first, mut nann) = (0usize, 0usize);

    let mut i = 1;
    while i < argc {
        let a = &argv[i];
        if a.first() == Some(&b'-') {
            match a.get(1).copied().unwrap_or(0) {
                b'a' => {
                    // annotator(s) follow
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: annotator(s) must follow -a\n", pname);
                        cstd::exit(1);
                    }
                    // Accept the next argument unconditionally as an
                    // annotator name; accept additional arguments until we
                    // find one beginning with `-', or the end of the
                    // argument list.  As in C, the count of annotators is
                    // not reset if -a is given more than once, and the
                    // names are those that follow the last -a (see
                    // "Undefined behaviors" in docs/KNOWN_C_BEHAVIORS.md).
                    ann_first = i;
                    loop {
                        nann += 1;
                        i += 1;
                        if !(i < argc && argv[i].first() != Some(&b'-')) {
                            break;
                        }
                    }
                    if i < argc {
                        i -= 1;
                    }
                }
                b'f' => {
                    // starting time
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: time must follow -f\n", pname);
                        cstd::exit(1);
                    }
                    startp = Some(&argv[i]);
                }
                b'h' => {
                    // help requested
                    sn.help();
                    cstd::exit(0);
                }
                b'i' | b'r' => {
                    // input record name (-r is equivalent to -i)
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: input record name must follow -i\n", pname);
                        cstd::exit(1);
                    }
                    irec = Some(&argv[i]);
                }
                b'l' => {
                    // length of snip
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: duration must follow -l\n", pname);
                        cstd::exit(1);
                    }
                    length = Some(&argv[i]);
                }
                b'm' => {
                    // preserve segments of multisegment input, if possible
                    sn.mflag = 1;
                }
                b'n' => {
                    // new record name
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: new record name must follow -n\n", pname);
                        cstd::exit(1);
                    }
                    nrec = Some(&argv[i]);
                }
                b'O' => {
                    // output format
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: output format must follow -O\n", pname);
                        cstd::exit(1);
                    }
                    sn.fmt = cstd::strtol(&argv[i], 10).0 as i32;
                }
                b's' => {
                    // suppress copying of info
                    sn.sflag = 1;
                }
                b't' => {
                    // end time
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: time must follow -t\n", pname);
                        cstd::exit(1);
                    }
                    endp = Some(&argv[i]);
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
    let (irec, nrec) = match (irec, nrec) {
        (Some(i), Some(n)) => (i, n),
        _ => {
            sn.help();
            cstd::exit(1);
        }
    };
    let startp: &[u8] = startp.unwrap_or(b"0");
    let endp: &[u8] = endp.unwrap_or(b"e");

    // Verify that the output record can be written.
    if wfdbx::newheader(nrec) < 0 {
        ceprintf!(b"%s: can't create output header\n", pname);
        cstd::exit(2);
    }

    // Determine the number of signals.
    let nsig = wfdbx::isigopen(irec, &mut [], 0);
    if nsig < 0 {
        ceprintf!(b"%s: error reading input header\n", pname);
        cstd::exit(2);
    }
    // wfdb-x: the output header needs the sampling frequency (the C program
    // assumed 250 Hz if the input header did not specify one, as legacy mode does).
    if !legacy && wfdbx::sampfreq(NULL) <= 0.0 {
        ceprintf!(
            b"%s: sampling frequency of record %s is not specified\n",
            pname,
            irec
        );
        wfdbx::wfdbquit();
        cstd::exit(2);
    }

    // Evaluate the time limits.
    let mut from = wfdbx::strtim(startp);
    if from < 0 {
        from = -from;
    }
    let to = if let Some(length) = length {
        from + wfdbx::strtim(length)
    } else {
        let to = wfdbx::strtim(endp);
        if to < 0 {
            -to
        } else {
            to
        }
    };
    let endt = wfdbx::strtim("e");
    if (endt > 0 && endt < from) || (to > 0 && to < from) {
        ceprintf!(b"%s: improper interval selected\n", pname);
        wfdbx::wfdbquit();
        cstd::exit(1);
    }

    // Copy the annotations, if any.
    // (names beyond the last argument, which C reads past the end of argv,
    // are ignored)
    let annotators = &argv[ann_first.min(argc)..(ann_first + nann).min(argc)];
    if !annotators.is_empty() {
        sn.copy_ann(nrec, irec, from, to, annotators);
    }

    // Copy the signals, if any.
    if nsig > 0 {
        let recurse = sn.mflag;
        sn.copy_sig(nrec, irec, from, to, recurse);
    }

    // Copy info strings from the input header file into the new one, unless
    // suppressed with -s.
    if sn.sflag == 0 {
        sn.copy_info(irec, startp);
    }

    wfdbx::wfdbquit();
    cstd::exit(0);
}
