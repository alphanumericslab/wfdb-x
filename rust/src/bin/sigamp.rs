//! sigamp: measure signal amplitudes (port of `app/sigamp.c`).
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Rust translation of app/sigamp.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: no built-in sampling frequency or gain: the
// record must give the sampling frequency (the measurement windows are in
// seconds), and with -p the gain of each signal (the original assumed 250 Hz
// and 200 adu/mV); --legacy, as the first argument, restores the original
// behavior. Each change is marked "WFDB-x:" in the code; docs/DIVERGENCES.md
// gives the reasons.
//
// Original C program: app/sigamp.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1991-2009 George B. Moody; revised 2018 by Benjamin Moody.
// Rust translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

use wfdbx::cstd;
use wfdbx::{
    ceprintf, cprintf, Anninfo, Annotation, Siginfo, NORMAL, NULL, WFDB_DEFFREQ, WFDB_DEFGAIN,
    WFDB_GVPAD, WFDB_HIGHRES, WFDB_READ,
};

const NMAX: i32 = 300;

// values for timeunits
const SECONDS: i32 = 1;
const MINUTES: i32 = 2;
const HOURS: i32 = 3;
const TIMSTR: i32 = 4;
const HHMMSS: i32 = 7;
const SAMPLES: i32 = 8;

const HELP_STRINGS: &[&str] = &[
    "usage: %s -r RECORD [OPTIONS ...]\n",
    "where OPTIONS may include any of:",
    " -a ANN      specify annotator, measure amplitudes near QRS annotations",
    " -d DT1 DT2  set measurement window relative to QRS annotations",
    "              defaults: DT1 = 0.05 (seconds before annotation);",
    "              DT2 = 0.05 (seconds after annotation)",
    " -f TIME     begin at specified time",
    " -h          print this usage summary",
    " -H          read multifrequency signals in high resolution mode",
    " -n NMAX     make up to NMAX measurements per signal (default: NMAX = 300)",
    " -p          print results in physical units (default: ADC units)",
    "              -p may be followed by a character to choose a time format:",
    "  -pd         print time of day and date if known",
    "  -pe         print elapsed time as <hours>:<minutes>:<seconds>",
    "  -ph         print elapsed time in hours",
    "  -pm         print elapsed time in minutes",
    "  -ps         print elapsed time in seconds (default)",
    "  -pS         print elapsed time in sample intervals",
    " -q          quick mode: print individual measurements only",
    " -t TIME     stop at specified time",
    " -v          verbose mode: print individual measurements and trimmed means",
    " -w DTW      set RMS amplitude measurement window",
    "              default: DTW = 1 (second)",
];

fn help(pname: &[u8]) {
    ceprintf!(HELP_STRINGS[0].as_bytes(), pname);
    for s in &HELP_STRINGS[1..] {
        ceprintf!(b"%s\n", *s);
    }
}

/// The program's global state.
struct State {
    namp: usize,
    nsig: i32,
    pflag: bool,
    timeunits: i32,
    v0: Vec<i32>,
    vmax: Vec<i32>,
    vmin: Vec<i32>,
    vv: Vec<i32>,
    amp: Vec<Vec<f64>>,
    vmean: Vec<f64>,
    vsum: Vec<f64>,
    dt1: i64,
    dt2: i64,
    dtw: i64,
    sfreq: f64,
    si: Vec<Siginfo>,
}

impl State {
    fn getrms(&mut self, t: i64) -> i32 {
        let nsig = self.nsig;
        let n = nsig as usize;
        if wfdbx::getvec(&mut self.vv) < nsig {
            return -1;
        }
        for i in 0..n {
            self.v0[i] = self.vv[i];
            self.vmean[i] = self.vv[i] as f64;
            self.vsum[i] = 0.0;
        }
        let mut tt = 1;
        while tt < self.dtw {
            if wfdbx::getvec(&mut self.vv) < nsig {
                return -1;
            }
            for i in 0..n {
                self.vmean[i] += self.vv[i] as f64;
            }
            tt += 1;
        }

        if wfdbx::isigsettime(t) < 0 || wfdbx::getvec(&mut self.vv) < nsig {
            return -1;
        }

        // The quantity vv[i] - v0[i] is normally zero, but may be non-zero
        // if the signals are stored in difference format (since isigsettime
        // may introduce a DC error in this case).  In the calculation of
        // vmean[i] below, this quantity is used to correct any such error.
        for i in 0..n {
            self.vmean[i] = self.vmean[i] / self.dtw as f64 + self.vv[i] as f64 - self.v0[i] as f64;
            let v = cstd::d2i(self.vv[i] as f64 - self.vmean[i]);
            self.vsum[i] += v as f64 * v as f64;
        }

        let mut tt = 1;
        while tt < self.dtw {
            if wfdbx::getvec(&mut self.vv) < nsig {
                return -1;
            }
            for i in 0..n {
                let v = cstd::d2i(self.vv[i] as f64 - self.vmean[i]);
                self.vsum[i] += v as f64 * v as f64;
            }
            tt += 1;
        }

        for i in 0..n {
            self.amp[i][self.namp] = (self.vsum[i] / self.dtw as f64).sqrt();
        }
        0
    }

    fn getptp(&mut self, t: i64) -> i32 {
        let nsig = self.nsig;
        let n = nsig as usize;
        if wfdbx::isigsettime(t + self.dt1) < 0 {
            return -1;
        }
        if wfdbx::getvec(&mut self.vmin) < nsig {
            return -1;
        }
        self.vmax[..n].copy_from_slice(&self.vmin[..n]);
        let mut tt = self.dt1;
        while tt < self.dt2 {
            if wfdbx::getvec(&mut self.vv) < nsig {
                return -1;
            }
            for i in 0..n {
                if self.vv[i] < self.vmin[i] {
                    self.vmin[i] = self.vv[i];
                } else if self.vv[i] > self.vmax[i] {
                    self.vmax[i] = self.vv[i];
                }
            }
            tt += 1;
        }
        for i in 0..n {
            self.amp[i][self.namp] = self.vmax[i].wrapping_sub(self.vmin[i]) as f64;
        }
        0
    }

    fn printamp(&self, t: i64) {
        match self.timeunits {
            TIMSTR => cprintf!(b"%s", wfdbx::mstimstr(-t)),
            HHMMSS => cprintf!(b"%s", wfdbx::mstimstr(t)),
            SAMPLES => cprintf!(b"%lld", t),
            _ => cprintf!(b"%lf", t as f64 / self.sfreq),
        };
        for i in 0..self.nsig as usize {
            let a = self.amp[i][self.namp];
            cprintf!(b"\t%g", if self.pflag { a / self.si[i].gain } else { a });
        }
        cprintf!(b"\n");
    }
}

fn main() {
    let mut argv = cstd::args();
    let legacy = wfdbx::wfdbx_legacy_args(&mut argv) != 0; // WFDB-x: --legacy
    let argc = argv.len();
    let pname = cstd::prog_name(&argv[0]).to_vec();
    let mut record: Option<&[u8]> = None;
    let mut ainame: Option<&[u8]> = None;
    let mut gvmode = 0;
    let mut nmax = NMAX;
    let mut qflag = false;
    let mut vflag = false;
    let mut timeunits = SECONDS;
    let mut pflag = false;
    let (mut dt1, mut dtw): (i64, i64) = (0, 0);
    let mut dt2: i64;
    let (mut from, mut to): (i64, i64) = (0, 0);

    // Interpret command-line arguments.
    let mut i = 1;
    while i < argc {
        let a = &argv[i];
        if a.first() == Some(&b'-') {
            match a.get(1).copied().unwrap_or(0) {
                b'a' => {
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: annotator name must follow -a\n", pname);
                        cstd::exit(1);
                    }
                    ainame = Some(&argv[i]);
                }
                b'd' => {
                    i += 1;
                    if i >= argc - 1 {
                        ceprintf!(b"%s: DT1 and DT2 must follow -d\n", pname);
                        cstd::exit(1);
                    }
                    // save arg list index, convert arguments to samples
                    // later (after record has been opened and sampling
                    // frequency is known)
                    dt1 = i as i64;
                    i += 1;
                }
                b'f' => {
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: start time must follow -f\n", pname);
                        cstd::exit(1);
                    }
                    // save arg list index, convert argument to samples later
                    from = i as i64;
                }
                b'h' => {
                    // help requested
                    help(&pname);
                    cstd::exit(0);
                }
                b'H' => {
                    // operate in WFDB_HIGHRES mode
                    gvmode = WFDB_HIGHRES;
                }
                b'n' => {
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: number of measurements must follow -n\n", pname);
                        cstd::exit(1);
                    }
                    nmax = cstd::atoi(&argv[i]);
                    if nmax < 1 {
                        nmax = NMAX;
                    }
                }
                b'p' => {
                    pflag = true;
                    timeunits = match a.get(2).copied().unwrap_or(0) {
                        b'd' => TIMSTR,
                        b'e' => HHMMSS,
                        b'h' => HOURS,
                        b'm' => MINUTES,
                        b'S' => SAMPLES,
                        _ => SECONDS,
                    };
                }
                b'q' => qflag = true,
                b'r' => {
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: record name must follow -r\n", pname);
                        cstd::exit(1);
                    }
                    record = Some(&argv[i]);
                }
                b't' => {
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: stop time must follow -t\n", pname);
                        cstd::exit(1);
                    }
                    // save arg list index, convert argument to samples later
                    to = i as i64;
                }
                b'v' => vflag = true,
                b'w' => {
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: window size must follow -w\n", pname);
                        cstd::exit(1);
                    }
                    // save arg list index, convert argument to samples later
                    dtw = i as i64;
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
    let record = match record {
        Some(r) => r,
        None => {
            help(&pname);
            cstd::exit(1);
        }
    };

    // Finish initialization.
    if gvmode == 0 {
        if let Some(p) = cstd::getenv("WFDBGVMODE") {
            gvmode = cstd::atoi(&p);
        }
    }
    wfdbx::setgvmode(gvmode | WFDB_GVPAD);

    let nsig = wfdbx::isigopen(record, &mut [], 0);
    if nsig <= 0 {
        cstd::exit(2);
    }
    let n = nsig as usize;
    let mut si = vec![Siginfo::default(); n];
    if wfdbx::isigopen(record, &mut si, nsig) != nsig {
        cstd::exit(2);
    }
    // WFDB-x: no default gain (the C program assumed 200 adu/mV for
    // uncalibrated signals, as legacy mode does).
    if legacy {
        for s in &mut si {
            if s.gain == 0.0 {
                s.gain = WFDB_DEFGAIN;
            }
        }
    } else if pflag {
        if let Some(i) = si.iter().position(|s| s.gain == 0.0) {
            ceprintf!(
                b"%s: signal %d of record %s is uncalibrated\n",
                pname,
                i as i32,
                record
            );
            cstd::exit(2);
        }
    }
    // WFDB-x: no default sampling frequency (the C program assumed 250 Hz,
    // as legacy mode does); the measurement windows are defined in seconds.
    let mut sfreq = wfdbx::sampfreq(NULL);
    if sfreq <= 0.0 && legacy {
        sfreq = WFDB_DEFFREQ;
    } else if sfreq <= 0.0 {
        ceprintf!(
            b"%s: sampling frequency of record %s is not specified\n",
            pname,
            record
        );
        cstd::exit(2);
    }

    // Adjust timeunits if starting time is undefined.
    if (timeunits == TIMSTR || timeunits == HHMMSS) && wfdbx::timstr(0).first() != Some(&b'[') {
        timeunits = HHMMSS;
    }
    if timeunits == HOURS {
        sfreq *= 3600.;
    } else if timeunits == MINUTES {
        sfreq *= 60.;
    }

    if from > 0 {
        from = wfdbx::strtim(&argv[from as usize]);
    }
    if to > 0 {
        to = wfdbx::strtim(&argv[to as usize]);
    }
    if from < 0 {
        from = -from;
    }
    if to < 0 {
        to = -to;
    }
    if from >= to {
        to = wfdbx::strtim("e");
    }

    let mut st = State {
        namp: 0,
        nsig,
        pflag,
        timeunits,
        v0: vec![0; n],
        vmax: vec![0; n],
        vmin: vec![0; n],
        vv: vec![0; n],
        amp: vec![vec![0.0; nmax as usize]; n],
        vmean: vec![0.0; n],
        vsum: vec![0.0; n],
        dt1: 0,
        dt2: 0,
        dtw: 0,
        sfreq,
        si,
    };
    let nmax = nmax as usize;

    // Collect amplitudes, print them if qflag or vflag set.
    if let Some(ainame) = ainame {
        // windows are relative to annotations
        let mut annot = Annotation::default();
        let ai = Anninfo {
            name: ainame.to_vec(),
            stat: WFDB_READ,
        };
        if dtw > 0 {
            ceprintf!(b"%s: -a and -w options cannot be used together;\n", pname);
            ceprintf!(b"  -w option is being ignored\n");
        }
        if wfdbx::annopen(record, std::slice::from_ref(&ai), 1) < 0 {
            cstd::exit(2);
        }
        if dt1 == 0 {
            dt2 = wfdbx::strtim("0.05");
            dt1 = -dt2;
        } else {
            let p = &argv[dt1 as usize + 1];
            dt2 = if p.first() == Some(&b'-') {
                -wfdbx::strtim(&p[1..])
            } else {
                wfdbx::strtim(p)
            };
            let p = &argv[dt1 as usize];
            dt1 = if p.first() == Some(&b'-') {
                wfdbx::strtim(&p[1..])
            } else {
                -wfdbx::strtim(p)
            };
            if dt1 > dt2 {
                std::mem::swap(&mut dt1, &mut dt2);
            }
        }
        if dt1 == dt2 {
            dt2 += 1;
        }
        st.dt1 = dt1;
        st.dt2 = dt2;
        if wfdbx::iannsettime(from) < 0 {
            cstd::exit(2);
        }
        while wfdbx::getann(0, &mut annot) == 0 && st.namp < nmax && (to == 0 || annot.time < to) {
            if wfdbx::map1(annot.anntyp as i32) == NORMAL {
                if st.getptp(annot.time) < 0 {
                    break;
                }
                if vflag || qflag {
                    st.printamp(annot.time);
                }
                st.namp += 1;
            }
        }
    } else {
        // windows are consecutive nonoverlapping segments
        if dt1 > 0 {
            ceprintf!(b"%s: -d option must be used with -a;\n", pname);
            ceprintf!(b"  -d option is being ignored\n");
        }
        if dtw != 0 {
            dtw = wfdbx::strtim(&argv[dtw as usize]);
        }
        if dtw <= 0 {
            dtw = wfdbx::strtim("1");
        }
        st.dtw = dtw;
        if from > 0 && wfdbx::isigsettime(from) < 0 {
            cstd::exit(2);
        }
        let mut t = from;
        while st.namp < nmax && (to == 0 || t < to) {
            if st.getrms(t) < 0 {
                break;
            }
            if vflag || qflag {
                st.printamp(t);
            }
            st.namp += 1;
            t += dtw;
        }
    }

    // Calculate trimmed means of collected amplitudes unless -q option set.
    if !qflag {
        let namp = st.namp;
        let jlow = namp / 20; // trim the smallest and largest 5%
        let jhigh = namp - jlow;
        if vflag {
            cprintf!(b"Trimmed mean");
        }
        for i in 0..n {
            let amp = &mut st.amp[i][..namp];
            amp.sort_by(|p1, p2| p1.partial_cmp(p2).unwrap_or(std::cmp::Ordering::Less));
            let mut a = 0.0;
            for x in &amp[jlow..jhigh] {
                a += x;
            }
            if jhigh == jlow {
                a = -f64::NAN; // 0.0/0.0 gives a negative NaN on x86
            } else {
                a /= (jhigh - jlow) as f64;
            }
            cprintf!(b"\t%g", if st.pflag { a / st.si[i].gain } else { a });
        }
        cprintf!(b"\n");
    }
    cstd::exit(0);
}
