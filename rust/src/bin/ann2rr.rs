//! ann2rr: extract a list of intervals from an annotation file (port of
//! `app/ann2rr.c`).
//
// Copyright (C) 1995-2009 George B. Moody (original C program, app/ann2rr.c;
// revised 2018-2020 by Benjamin Moody).
// Rust implementation part of wfdb-x, Reza Sameni, Oct 2026.
// Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
// gain, ADC resolution or units. Values that the record or the user does not
// give are never assumed (the original package assumed 250 Hz, 200 adu/mV,
// 12 bits and millivolts), because a silently assumed value corrupts every
// result derived from it. See docs/DIVERGENCES.md.
// GNU General Public License, version 2 or later (see LICENSE).

use wfdbx::cstd;
use wfdbx::{
    ceprintf, cformat, cprintf, csscanf, Anninfo, Annotation, WfdbFile, ACMAX, NOTQRS,
    WFDB_DEFFREQ, WFDB_READ,
};

const HELP_STRINGS: &[&[u8]] = &[
    b"usage: %s -r RECORD -a ANNOTATOR [OPTIONS ...]\n",
    b"where RECORD and ANNOTATOR specify the input, and OPTIONS may include:",
    b" -A      print all intervals between annotations (default: print only RR",
    b"          intervals; overrides -c, -p)",
    b" -c      print intervals between consecutive valid annotations only",
    b" -f TIME start at specified TIME",
    b" -F FREQ sampling frequency, if the record header does not specify one",
    b" -h      print this usage summary",
    b" -i FMT  print intervals using format FMT (see below for values of FMT)",
    b" -p TYPE [TYPE ...]  print intervals ending with annotations of specified",
    b"                      TYPEs only (use mnemonics such as N or V for TYPE)",
    b" -P TYPE [TYPE ...]  print intervals beginning with specified types only",
    b" -t TIME stop at specified TIME",
    b" -v FMT  print times of ends of intervals using format FMT (see below)",
    b" -V FMT  print times of beginnings of intervals using format FMT (see below)",
    b" -w      print annotations that end intervals",
    b" -W      print annotations that begin intervals",
    b"By default, the output contains the RR intervals only, unless one or more",
    b"of -v, -V, -w, or -W are used.  Intervals and times are printed in units of",
    b"sample intervals, unless a format is specified using -i, -v, or -V.",
    b"Formats can be 'h' (hours), 'm' (minutes), 's' (seconds), 't' (hh:mm:ss);",
    b"when used with -v or -V, format 'T' yields dates and times if available,",
    b"or the format can be omitted to obtain times in sample intervals.  Formats",
    b"'h', 'm', and 's' may be followed by a number between 0 and 15, specifying",
    b"the number of decimal places (default: 3).  For example, to obtain intervals",
    b"in seconds with 8 decimal places, use '-i s8'.",
];

/// Decimal places of times and intervals printed in hours, minutes or
/// seconds: the default and the largest accepted.
const DEFDIGITS: i32 = 3;
const MAXDIGITS: i32 = 15;

/// Lines of the usage summary shown before each "--More--" prompt.
const PAGELINES: usize = 23;

/// wfdb-x: the lines of `HELP_STRINGS` added by wfdb-x, left out of the
/// help text of the original program (printed in legacy mode).
const WFDBX_HELP_LINES: &[&[u8]] =
    &[b" -F FREQ sampling frequency, if the record header does not specify one"];

fn help(pname: &[u8]) {
    let legacy = wfdbx::wfdbx_get_legacy() != 0;
    ceprintf!(HELP_STRINGS[0], pname);
    let lines = HELP_STRINGS[1..]
        .iter()
        .filter(|s| !(legacy && WFDBX_HELP_LINES.contains(s)));
    for (i, s) in (1..).zip(lines) {
        ceprintf!(b"%s\n", s);
        if i % PAGELINES == 0 {
            ceprintf!(b"--More--");
            let mut b = Vec::new();
            let mut input = WfdbFile::stdin();
            input.fgets(&mut b, 5); // (C: a 5-byte buffer)
            drop(input);
            ceprintf!(b"\x1b[A\x1b[2K"); // erase "--More--"; assumes ANSI terminal
        }
    }
}

/// The flag tables are indexed by annotation type (types outside the
/// tables are not flagged).
fn flagged(table: &[bool], a: i32) -> bool {
    (0..=ACMAX).contains(&a) && table[a as usize]
}

/// wfdb-x: whether output format `c` (of -i, -v or -V) is a unit of time,
/// which needs the sampling frequency.
fn time_format_needs_freq(c: u8) -> bool {
    matches!(c, b'h' | b'm' | b's' | b't' | b'T')
}

fn isann(code: i32) -> bool {
    wfdbx::isann(code) != 0
}

fn main() {
    let mut argv = cstd::args();
    let legacy = wfdbx::wfdbx_legacy_args(&mut argv) != 0; // wfdb-x: --legacy
    let argc = argv.len();
    let pname = cstd::prog_name(&argv[0]).to_vec();
    let c0 = |i: usize| -> u8 { argv[i].first().copied().unwrap_or(0) };
    let mut record: Option<&[u8]> = None;
    let mut ainame: Option<&[u8]> = None;
    let (mut aflag_all, mut a0flag, mut a1flag, mut cflag) = (false, false, false, false);
    let mut previous_annot_valid = false;
    let (mut rrdigits, mut rrformat) = (DEFDIGITS, 0u8);
    let (mut t0digits, mut t0flag, mut t0format) = (DEFDIGITS, false, 0u8);
    let (mut t1digits, mut t1flag, mut t1format) = (DEFDIGITS, false, 0u8);
    let mut a0f = [false; ACMAX as usize + 1];
    let mut a1f = [false; ACMAX as usize + 1];
    let mut annot = Annotation::default();
    let (mut from, mut to): (i64, i64) = (0, 0);
    let mut ffreq = 0.0f64; // -F (wfdb-x)

    // Interpret command-line options.
    a0f[0] = true;
    a1f[0] = true;
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
                b'A' => aflag_all = true, // print intervals between annotations of all types
                b'c' => cflag = true,     // intervals between consecutive valid annotations only
                b'f' => {
                    // starting time follows
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: starting time must follow -f\n", pname);
                        cstd::exit(1);
                    }
                    from = i as i64; // to be converted to sample intervals below
                }
                b'F' if !legacy => {
                    // sampling frequency follows (wfdb-x)
                    i += 1;
                    if i >= argc || csscanf!(&argv[i], b"%lf", &mut ffreq) != 1 || ffreq <= 0.0 {
                        ceprintf!(b"%s: sampling frequency (> 0) must follow -F\n", pname);
                        cstd::exit(1);
                    }
                }
                b'h' => {
                    // print usage summary and quit
                    help(&pname);
                    cstd::exit(0);
                }
                b'i' => {
                    // specify interval output format
                    i += 1;
                    if i >= argc || c0(i) == b'-' {
                        ceprintf!(b"%s: interval output format must follow -i\n", pname);
                        cstd::exit(1);
                    }
                    rrformat = c0(i);
                    csscanf!(argv[i].get(1..).unwrap_or(b""), b"%d", &mut rrdigits);
                }
                b'p' | b'P' => {
                    // annotation mnemonic(s) follow
                    let (tbl, other) = if a[1] == b'p' {
                        (&mut a1f, b'P')
                    } else {
                        (&mut a0f, b'p')
                    };
                    i += 1;
                    let j = if i < argc {
                        wfdbx::strann(&argv[i][..])
                    } else {
                        0
                    };
                    if i >= argc || !isann(j) {
                        ceprintf!(
                            b"%s: annotation mnemonic(s) must follow -%c\n",
                            pname,
                            other
                        );
                        cstd::exit(1);
                    }
                    tbl[j as usize] = true;
                    // Pick up any other mnemonics (arguments beginning with
                    // `-' are assumed to be options, not mnemonics).
                    i += 1;
                    while i < argc && c0(i) != b'-' {
                        let j = wfdbx::strann(&argv[i][..]);
                        if isann(j) {
                            tbl[j as usize] = true;
                        }
                        i += 1;
                    }
                    if i == argc || c0(i) == b'-' {
                        i -= 1;
                    }
                    tbl[0] = false;
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
                b't' => {
                    // ending time follows
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: end time must follow -t\n", pname);
                        cstd::exit(1);
                    }
                    to = i as i64;
                }
                b'v' => {
                    // output times of ends of intervals
                    t1flag = true;
                    i += 1;
                    if i >= argc || c0(i) == b'-' {
                        i -= 1;
                    } else {
                        t1format = c0(i);
                        csscanf!(argv[i].get(1..).unwrap_or(b""), b"%d", &mut t1digits);
                    }
                }
                b'V' => {
                    // output times of beginnings of intervals
                    t0flag = true;
                    i += 1;
                    if i >= argc || c0(i) == b'-' {
                        i -= 1;
                    } else {
                        t0format = c0(i);
                        csscanf!(argv[i].get(1..).unwrap_or(b""), b"%d", &mut t0digits);
                    }
                }
                b'w' => a1flag = true, // output annotation types following intervals
                b'W' => a0flag = true, // output annotation types preceding intervals
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

    // wfdb-x: no default sampling frequency (the C program assumed 250 Hz if
    // the record had no header); -F specifies one. It is needed for times
    // and intervals in units of time.
    let mut sps = wfdbx::sampfreq(record);
    if legacy {
        // wfdb-x: legacy mode (original behavior)
        if sps < 0.0 {
            sps = WFDB_DEFFREQ;
            wfdbx::setsampfreq(sps);
        }
    } else if sps <= 0.0 && ffreq > 0.0 {
        sps = ffreq;
        wfdbx::setsampfreq(sps);
    }
    let needs_freq = |k: i64| k != 0 && wfdbx::wfdbx_time_needs_freq(&argv[k as usize]) != 0;
    if !legacy
        && sps <= 0.0
        && (needs_freq(from)
            || needs_freq(to)
            || time_format_needs_freq(rrformat)
            || (t0flag && time_format_needs_freq(t0format))
            || (t1flag && time_format_needs_freq(t1format)))
    {
        ceprintf!(
            b"%s: sampling frequency of record %s is not specified (use -F)\n",
            pname,
            record
        );
        cstd::exit(1);
    }
    let spm = 60.0 * sps;
    let sph = 60.0 * spm;

    let ai = [Anninfo {
        name: ainame.to_vec(),
        stat: WFDB_READ,
    }];
    if wfdbx::annopen(record, &ai, 1) < 0 {
        // open annotation file
        cstd::exit(2);
    }

    if !(0..=MAXDIGITS).contains(&rrdigits) {
        rrdigits = DEFDIGITS;
    }
    let rrfstr = cformat!(b"%%.%dlf", rrdigits);
    if !(0..=MAXDIGITS).contains(&t0digits) {
        t0digits = DEFDIGITS;
    }
    let t0fstr = cformat!(b"%%.%dlf", t0digits);
    if !(0..=MAXDIGITS).contains(&t1digits) {
        t1digits = DEFDIGITS;
    }
    let t1fstr = cformat!(b"%%.%dlf", t1digits);

    if from != 0 {
        from = wfdbx::strtim(&argv[from as usize][..]);
        if from < 0 {
            from = -from;
        }
    }
    if to != 0 {
        to = wfdbx::strtim(&argv[to as usize][..]);
        if to < 0 {
            to = -to;
        }
    }
    if to > 0 && to < from {
        std::mem::swap(&mut from, &mut to);
    }
    if from > 0 && wfdbx::iannsettime(from) < 0 {
        cstd::exit(2);
    }

    let mut a0 = NOTQRS;
    let mut t0 = from;

    while wfdbx::getann(0, &mut annot) == 0 && (to == 0 || annot.time <= to) {
        let a1 = annot.anntyp as i32;
        let mut t1 = annot.time;

        // Does t1 mark a valid interval end point?
        if aflag_all || (a1f[0] && wfdbx::isqrs(a1) != 0) || flagged(&a1f, a1) {
            // Does t0 mark a valid interval starting point?
            if !cflag || previous_annot_valid {
                // If requested, print time at beginning of interval.
                if t0flag {
                    match t0format {
                        b'h' => {
                            cprintf!(&t0fstr, t0 as f64 / sph);
                        }
                        b'm' => {
                            cprintf!(&t0fstr, t0 as f64 / spm);
                        }
                        b's' => {
                            cprintf!(&t0fstr, t0 as f64 / sps);
                        }
                        b't' => {
                            if t0 == 0 {
                                cprintf!(b"    0:00.000");
                            } else {
                                cprintf!(b"%s", wfdbx::mstimstr(t0));
                            }
                        }
                        b'T' => {
                            cprintf!(b"%s", wfdbx::mstimstr(-t0));
                        }
                        _ => {
                            cprintf!(b"%lld", t0);
                        }
                    }
                    cprintf!(b"\t");
                }

                // If requested, print annotation at beginning of interval.
                if a0flag {
                    if a0 == NOTQRS {
                        cprintf!(b"[0]\t");
                    } else {
                        cprintf!(b"%s\t", wfdbx::annstr(a0));
                    }
                }

                // Print the interval, and update t0 and a0.
                let rr = t1 - t0;
                let rrout = |div: f64| -> f64 {
                    // snprintf into a 20-byte buffer, then read it back
                    let mut s = cformat!(&rrfstr, rr as f64 / div);
                    s.truncate(20 - 1);
                    cprintf!(b"%s", s);
                    let mut frr = 0.0f64;
                    csscanf!(&s[..], b"%lf", &mut frr);
                    frr
                };
                match rrformat {
                    b'h' => {
                        let frr = rrout(sph);
                        t1 = cstd::d2l(t0 as f64 + frr * sph + 0.5);
                    }
                    b'm' => {
                        let frr = rrout(spm);
                        t1 = cstd::d2l(t0 as f64 + frr * spm + 0.5);
                    }
                    b's' => {
                        let frr = rrout(sps);
                        t1 = cstd::d2l(t0 as f64 + frr * sps + 0.5);
                    }
                    b't' => {
                        cprintf!(b"%s", wfdbx::mstimstr(t1));
                    }
                    _ => {
                        cprintf!(b"%lld", rr);
                    }
                }

                // If requested, print annotation at end of interval.
                if a1flag {
                    cprintf!(b"\t%s", wfdbx::annstr(a1));
                }

                // If requested, print time at end of interval.
                if t1flag {
                    cprintf!(b"\t");
                    match t1format {
                        b'h' => {
                            cprintf!(&t1fstr, t1 as f64 / sph);
                        }
                        b'm' => {
                            cprintf!(&t1fstr, t1 as f64 / spm);
                        }
                        b's' => {
                            cprintf!(&t1fstr, t1 as f64 / sps);
                        }
                        b't' => {
                            cprintf!(b"%s", wfdbx::mstimstr(t1));
                        }
                        b'T' => {
                            cprintf!(b"%s", wfdbx::mstimstr(-t1));
                        }
                        _ => {
                            cprintf!(b"%lld", t1);
                        }
                    }
                }

                cprintf!(b"\n");
            }
        }
        // Does t1 mark a valid interval starting point?
        if aflag_all || (a0f[0] && wfdbx::isqrs(a1) != 0) || flagged(&a0f, a1) {
            a0 = a1;
            t0 = t1;
            previous_annot_valid = true;
        } else if cflag {
            previous_annot_valid = false;
        }
    }
    cstd::exit(0);
}
