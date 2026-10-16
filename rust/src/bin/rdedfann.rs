//! rdedfann: print annotations from an EDF+ file (port of
//! `convert/rdedfann.c`).
//!
//! This program prints the annotations from an EDF+ file in the same format
//! as `rdann` does for WFDB-compatible annotation files. As in the C
//! program, an annotation without a duration repeats the duration of the
//! previous one (see `docs/KNOWN_C_BEHAVIORS.md`). Where the C program would
//! overflow its 1024-byte onset, duration, or text buffers, this port
//! discards the excess characters.
//
// Copyright (C) 2008-2014 George B. Moody (original C program,
// convert/rdedfann.c); -x option contributed by Luca Citi, 2014.
// Rust implementation part of wfdb-x, Reza Sameni, Oct 2026.
// GNU General Public License, version 2 or later (see LICENSE).

use wfdbx::cstd::{self, d2l};
use wfdbx::{ceprintf, cprintf, csscanf, Siginfo, NULL, WFDB_HIGHRES, WFDB_LOWRES};

/// Size of C's TAL field buffers.
const BUFLEN: usize = 1024;

/// EDF+ TAL (time-stamped annotation list) delimiters: a TAL is `+onset`,
/// optionally DURATION and the duration, then annotations each followed by
/// SEP, and a NUL.
const DURATION: i32 = 0o25;
const SEP: i32 = 0o24;

/// States of the TAL parser.
const START: i32 = 0; // looking for a new TAL
const ONSET: i32 = 1;
const DURATION_TEXT: i32 = 2;
const ANNOTATION: i32 = 3;
const ANNOTATION_END: i32 = 4;

/// A fixed-size character buffer with a write position, as in C (characters
/// that would overflow the buffer are discarded).
struct Buf {
    b: [u8; BUFLEN],
    pos: usize,
}

impl Buf {
    fn new() -> Buf {
        Buf {
            b: [0; BUFLEN],
            pos: 0,
        }
    }

    fn put(&mut self, c: i32) {
        if self.pos < self.b.len() {
            self.b[self.pos] = c as u8;
        }
        self.pos += 1;
    }

    fn str(&self) -> Vec<u8> {
        cstd::cstr(&self.b).to_vec()
    }
}

struct State {
    pname: Vec<u8>,
    sfreq: f64,
    state: i32,
    xflag: bool,
    onset: Buf,
    duration: Buf,
    text: Buf,
}

impl State {
    fn proc(&mut self, x: i32) {
        let mut x = x & 0xff;

        match self.state {
            START => {
                // looking for a new TAL
                if x == 0 {
                    return;
                }
                if x != b'+' as i32 {
                    ceprintf!(b"%s: unexpected character '%c' in input\n", self.pname, x);
                } else {
                    self.state = ONSET;
                    self.onset.pos = 0;
                    self.duration.pos = 0;
                    self.text.pos = 0;
                    self.text.b[0] = 0;
                }
            }
            ONSET => {
                // accumulate characters from onset until 024 or 025
                if x == DURATION {
                    // end of onset, start of duration
                    x = 0;
                    self.state = DURATION_TEXT;
                } else if x == SEP {
                    // end of onset, start of annotation
                    x = 0;
                    self.state = ANNOTATION;
                }
                self.onset.put(x);
            }
            DURATION_TEXT => {
                // accumulate characters from duration until 024
                if x == SEP {
                    // end of onset, start of annotation
                    x = 0;
                    self.state = ANNOTATION;
                }
                self.duration.put(x);
            }
            ANNOTATION => {
                // accumulate characters from annotation until 024
                if x == SEP {
                    // end of annotation
                    x = 0;
                    self.state = ANNOTATION_END;
                }
                self.text.put(x);
            }
            ANNOTATION_END => {
                // annot just ended, there may be another
                if self.text.b[0] != 0 {
                    // the annotation was not empty -- output it
                    let os = self.onset.str();
                    let t = d2l(cstd::atof(&os) * self.sfreq + 0.5);
                    let mut ts = self.text.str();
                    let ds = self.duration.str();

                    // replace whitespace with '_'
                    for (k, c) in ts.iter_mut().enumerate() {
                        if *c == b' ' || *c == b'\t' {
                            *c = b'_';
                            self.text.b[k] = b'_';
                        }
                    }
                    let tstr: Vec<u8> = if t != 0 {
                        wfdbx::mstimstr(t)
                    } else {
                        b"    0:00.000".to_vec()
                    };
                    let empty: &[u8] = b"";
                    let quote: &[u8] = b"\"";
                    cprintf!(
                        b"%s  %7ld %5s%5d%5d%5d\t%s",
                        tstr,
                        t,
                        if self.xflag { quote } else { &ts[..] },
                        0,
                        0,
                        0,
                        if self.xflag { &ts[..] } else { empty }
                    );
                    if self.duration.b[0] != 0 {
                        cprintf!(
                            b"%cduration: %s",
                            if self.xflag { b' ' } else { b'\t' } as i32,
                            ds
                        );
                    }
                    cprintf!(b"\n");
                }
                if x != 0 {
                    self.text.b[0] = x as u8;
                    self.text.pos = 1;
                    self.state = ANNOTATION;
                } else {
                    // end of TAL
                    self.state = START;
                }
            }
            _ => {}
        }
    }
}

const HELP_STRINGS: &[&[u8]] = &[
    b"usage: %s -r RECORD [OPTIONS ...]\n",
    b"where RECORD is the name of the input EDF+ record, and OPTIONS may include:",
    b" -F FREQ     set the sampling frequency to FREQ Hz\n",
    b" -h          print this usage summary",
    b" -v          print column headings",
    b" -x          print EDF+ annotation text in aux (default: print in anntyp)",
];

fn help(pname: &[u8]) {
    ceprintf!(HELP_STRINGS[0], pname);
    for s in &HELP_STRINGS[1..] {
        ceprintf!(b"%s\n", s);
    }
}

fn main() {
    let mut argv = cstd::args();
    wfdbx::wfdbx_legacy_args(&mut argv); // wfdb-x: --legacy (original behavior)
    let argc = argv.len();
    let pname = cstd::prog_name(&argv[0]).to_vec();
    let mut record: Option<Vec<u8>> = None;
    let mut sfreq: f64 = 0.0;
    let (mut vflag, mut xflag) = (false, false);

    let mut i = 1;
    while i < argc {
        if argv[i].first() == Some(&b'-') {
            match argv[i].get(1).copied().unwrap_or(0) {
                b'F' => {
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: sampling frequency must follow -F\n", pname);
                        cstd::exit(1);
                    }
                    csscanf!(&argv[i], b"%lf", &mut sfreq);
                    if sfreq <= 0.0 {
                        sfreq = 1.0;
                    }
                }
                b'h' => {
                    // help requested
                    help(&pname);
                    cstd::exit(0);
                }
                b'r' => {
                    // record name
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: record name must follow -r\n", pname);
                        cstd::exit(1);
                    }
                    record = Some(cstd::cstr(&argv[i]).to_vec());
                }
                b'v' => vflag = true, // verbose output -- include column headings
                b'x' => xflag = true, // save EDF annotation text in aux rather than anntyp
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
    let Some(record) = record else {
        help(&pname);
        cstd::exit(1);
    };
    wfdbx::setgvmode(WFDB_HIGHRES);
    let mut nsig = wfdbx::isigopen(&record, &mut [], 0);
    if nsig <= 0 {
        cstd::exit(2);
    }
    let mut si = vec![Siginfo::default(); nsig as usize];
    nsig = wfdbx::isigopen(&record, &mut si, nsig);
    if nsig <= 0 {
        cstd::exit(2);
    }
    let (mut aindex, mut alen, mut framelen) = (0usize, 0usize, 0usize);
    for s in si.iter().take(nsig as usize) {
        if s.desc.as_deref() == Some(b"EDF Annotations") {
            aindex = framelen;
            alen = s.spf as usize;
        }
        framelen += s.spf as usize;
    }
    if alen == 0 {
        ceprintf!(b"%s: record %s has no EDF annotations\n", pname, record);
        wfdbx::wfdbquit();
        cstd::exit(3);
    }
    let mut frame = vec![0i32; framelen];

    if sfreq > 0.0 {
        wfdbx::setgvmode(WFDB_LOWRES);
        wfdbx::setsampfreq(sfreq);
    } else {
        sfreq = wfdbx::sampfreq(NULL);
    }

    // Print column headers if '-v' option selected.
    if vflag {
        cprintf!(b"      Time   Sample #  Type  Sub Chan  Num\tAux\n");
    }

    let mut st = State {
        pname,
        sfreq,
        state: START,
        xflag,
        onset: Buf::new(),
        duration: Buf::new(),
        text: Buf::new(),
    };
    while wfdbx::getframe(&mut frame) > 0 {
        st.state = START;
        for &p in &frame[aindex..aindex + alen] {
            if p != 0 || st.state != START {
                st.proc(p);
                st.proc(p >> 8);
            } else {
                break;
            }
        }
    }

    wfdbx::wfdbquit();
    cstd::exit(0);
}
