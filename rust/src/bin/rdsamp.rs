//! rdsamp: print an arbitrary number of samples from each signal (port of
//! `app/rdsamp.c`).
//!
//! The output is identical to that of the C program. Samples are read in
//! blocks with `getvecs` (equivalent to repeated `getvec` calls) except
//! when the time column is printed with `timstr` or `mstimstr`, whose
//! results could depend on library state changed while reading (e.g., at
//! the start of a new segment); integers are formatted without `printf`
//! (with identical results) for speed.
//
// Copyright (C) 1983-2010 George B. Moody (original C program, app/rdsamp.c;
// revised 2017-2020 by Benjamin Moody).
// Rust implementation part of wfdb-x, Reza Sameni, Oct 2026.
// Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
// gain, ADC resolution or units. Values that the record or the user does not
// give are never assumed (the original package assumed 250 Hz, 200 adu/mV,
// 12 bits and millivolts), because a silently assumed value corrupts every
// result derived from it. See docs/DIVERGENCES.md.
// GNU General Public License, version 2 or later (see LICENSE).

use wfdbx::cstd::{self, sprintf_into, ToArg};
use wfdbx::{ceprintf, cformat, NULL, WFDB_DEFGAIN, WFDB_HIGHRES, WFDB_INVALID_SAMPLE};

// values for timeunits
const SECONDS: i32 = 1;
const MINUTES: i32 = 2;
const HOURS: i32 = 3;
const TIMSTR: i32 = 4;
const MSTIMSTR: i32 = 5;
const SHORTTIMSTR: i32 = 6;
const HHMMSS: i32 = 7;
const SAMPLES: i32 = 8;

// Column widths of the tab-separated output (those of the formats used):
// the time column, and the sample columns (with -P, high precision).
const TWIDTH: usize = 15;
const VWIDTH: usize = 7;
const VWIDTH_HI: usize = 15;

/// What the library puts in a default signal description ("record xxx,
/// signal n").
const DEFAULT_DESC: &[u8] = b", signal ";

const WFDBXMLPROLOG: &[u8] = b"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
<?xml-stylesheet type=\"text/xsl\" href=\"wfdb.xsl\"?>\n\
<!DOCTYPE wfdbsampleset PUBLIC \"-//PhysioNet//DTD WFDB 1.0//EN\" \"http://physionet.org/physiobank/database/XML/wfdb.dtd\">\n";

const HELP_STRINGS: &[&str] = &[
    "where RECORD is the name of the input record, and OPTIONS may include:",
    " -c          use CSV (comma-separated value) output format",
    " -f TIME     begin at specified time",
    " -h          print this usage summary",
    " -H          read multifrequency signals in high resolution mode",
    " -l INTERVAL truncate output after the specified time interval (hh:mm:ss)",
    " -p          print times and samples in physical units (default: raw units)",
    " -P          same as -p, but with greater precision",
    "              -p and -P may be followed by a character to choose a time",
    "              format;  choices are:",
    "  -pd (or -Pd)  print time of day and date if known",
    "  -pe (or -Pe)  print elapsed time as <hours>:<minutes>:<seconds>",
    "  -ph (or -Ph)  print elapsed time in hours",
    "  -pm (or -Pm)  print elapsed time in minutes",
    "  -ps (or -Ps)  print elapsed time in seconds",
    "  -pS (or -PS)  print elapsed time in sample intervals",
    " -s SIGNAL [SIGNAL ...]  print only the specified signal(s)",
    " -S SIGNAL   search for a valid sample of the specified SIGNAL at or after",
    "\t\tthe time specified with -f, and begin printing then",
    " -t TIME     stop at specified time",
    " -v          print column headings",
    " -X          output in WFDB-XML format",
];

fn help(pname: &[u8]) {
    ceprintf!(b"usage: %s -r RECORD [OPTIONS ...]\n", pname);
    for s in HELP_STRINGS {
        ceprintf!(b"%s\n", *s);
    }
}

/// Escape quotes and backslashes for CSV column headings. (The C version
/// of this function does not terminate for most strings that contain
/// these characters; see `docs/KNOWN_C_BEHAVIORS.md`.)
fn escapify(s: &[u8]) -> Vec<u8> {
    let mut r = Vec::with_capacity(s.len());
    for &c in cstd::cstr(s) {
        if c == b'\'' || c == b'\\' {
            r.push(b'\\');
        }
        r.push(c);
    }
    r
}

/// Output buffer (written to the standard output in large pieces).
struct Out {
    buf: Vec<u8>,
}

impl Out {
    const LIMIT: usize = 1 << 16; // bytes buffered before writing

    fn new() -> Out {
        Out {
            buf: Vec::with_capacity(Self::LIMIT + 1024), // (+ a line or so)
        }
    }

    #[inline]
    fn maybe_flush(&mut self) {
        if self.buf.len() >= Self::LIMIT {
            self.flush();
        }
    }

    fn flush(&mut self) {
        if !self.buf.is_empty() {
            cstd::out().write(&self.buf);
            self.buf.clear();
        }
    }

    fn puts(&mut self, s: &[u8]) {
        self.buf.extend_from_slice(s);
    }

    fn printf(&mut self, fmt: &[u8], args: &[cstd::Arg]) {
        sprintf_into(&mut self.buf, fmt, args);
    }

    /// `printf("<lead>%<width>.<prec>f", x)` (`lead` may be 0). `fmt` is
    /// that format (without the lead), used if the fast path cannot be.
    #[inline]
    fn fixed(&mut self, lead: u8, x: f64, width: usize, prec: u32, fmt: &[u8]) {
        if lead != 0 {
            self.buf.push(lead);
        }
        if !cstd::fixed_fast(&mut self.buf, x, width, prec) {
            sprintf_into(&mut self.buf, fmt, &[x.to_arg()]);
        }
    }

    /// `printf("<lead>%<width>ld", v)` (`lead` may be 0).
    #[inline]
    fn integer(&mut self, lead: u8, v: i64, width: usize) {
        let mut tmp = [0u8; 20]; // a sign and the 19 digits of an i64
        let mut p = tmp.len();
        let mut u = v.unsigned_abs();
        loop {
            p -= 1;
            tmp[p] = b'0' + (u % 10) as u8;
            u /= 10;
            if u == 0 {
                break;
            }
        }
        if v < 0 {
            p -= 1;
            tmp[p] = b'-';
        }
        let len = tmp.len() - p;
        if lead != 0 {
            self.buf.push(lead);
        }
        for _ in len..width {
            self.buf.push(b' ');
        }
        self.buf.extend_from_slice(&tmp[p..]);
    }
}

fn skip_spaces(s: &[u8]) -> &[u8] {
    let k = s.iter().take_while(|&&c| c == b' ').count();
    &s[k..]
}

fn main() {
    let mut argv = cstd::args();
    let legacy = wfdbx::wfdbx_legacy_args(&mut argv) != 0; // wfdb-x: --legacy
    let argc = argv.len();
    let pname = cstd::prog_name(&argv[0]).to_vec();
    let mut record: Option<usize> = None;
    let mut search: Option<usize> = None;
    let mut cflag = 0;
    let mut highres = 0;
    let mut isiglist = 0usize;
    let mut nosig = 0usize;
    let mut pflag = 0;
    let mut timeunits = SECONDS;
    let mut vflag = 0;
    let mut xflag = 0;
    let (mut from, mut maxl, mut to): (i64, i64, i64) = (0, 0, 0);

    let mut i = 1;
    while i < argc {
        let a = &argv[i];
        if a.first() == Some(&b'-') {
            let c1 = a.get(1).copied().unwrap_or(0);
            let c2 = a.get(2).copied().unwrap_or(0);
            match c1 {
                b'c' => cflag = 1, // output in CSV format
                b'f' => {
                    // starting time
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: time must follow -f\n", pname);
                        cstd::exit(1);
                    }
                    from = i as i64;
                }
                b'h' => {
                    // help requested
                    help(&pname);
                    cstd::exit(0);
                }
                b'H' => highres = 1, // select high-resolution mode
                b'l' => {
                    // maximum length of output follows
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: max output length must follow -l\n", pname);
                        cstd::exit(1);
                    }
                    maxl = i as i64;
                }
                b'P' | b'p' => {
                    // output in (high-precision) physical units
                    if c1 == b'P' {
                        pflag += 1;
                    }
                    pflag += 1;
                    timeunits = match c2 {
                        b'd' => TIMSTR,
                        b'e' => HHMMSS,
                        b'h' => HOURS,
                        b'm' => MINUTES,
                        b'S' => SAMPLES,
                        _ => SECONDS,
                    };
                }
                b'r' => {
                    // record name
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: record name must follow -r\n", pname);
                        cstd::exit(1);
                    }
                    record = Some(i);
                }
                b's' => {
                    // signal list follows
                    isiglist = i + 1; // index of first argument with a signal #
                    while i + 1 < argc && argv[i + 1].first() != Some(&b'-') {
                        i += 1;
                        nosig += 1; // number of elements in signal list
                    }
                    if nosig == 0 {
                        ceprintf!(b"%s: signal list must follow -s\n", pname);
                        cstd::exit(1);
                    }
                }
                b'S' => {
                    // search for valid sample of specified signal
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: signal name or number must follow -S\n", pname);
                        cstd::exit(1);
                    }
                    search = Some(i);
                }
                b't' => {
                    // end time
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: time must follow -t\n", pname);
                        cstd::exit(1);
                    }
                    to = i as i64;
                }
                b'v' => vflag = 1, // verbose output -- include column headings
                b'X' => {
                    // output in WFDB-XML format
                    xflag = 1;
                    cflag = 1;
                    vflag = 1; // CSV inside an XML wrapper
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
    let Some(record) = record else {
        help(&pname);
        cstd::exit(1);
    };
    let record = argv[record].clone();
    let mut nsig = wfdbx::isigopen(&record, &mut [], 0);
    if nsig <= 0 {
        cstd::exit(2);
    }
    let navail = nsig as usize;
    let mut si = vec![wfdbx::Siginfo::default(); nsig as usize];
    nsig = wfdbx::isigopen(&record, &mut si, nsig);
    if nsig <= 0 {
        cstd::exit(2);
    }
    if legacy {
        // wfdb-x: the C program's default gain (legacy mode)
        for s in si.iter_mut().take(nsig as usize) {
            if s.gain == 0.0 {
                s.gain = WFDB_DEFGAIN;
            }
        }
    }
    if highres != 0 {
        wfdbx::setgvmode(WFDB_HIGHRES);
    }
    let mut freq = wfdbx::sampfreq(NULL);
    // wfdb-x: no default sampling frequency (the C program assumed 250 Hz
    // if the header did not specify one, as legacy mode does).
    let needs_freq = |k: i64| k > 0 && wfdbx::wfdbx_time_needs_freq(&argv[k as usize]) != 0;
    if !legacy
        && freq <= 0.0
        && (needs_freq(from)
            || needs_freq(to)
            || needs_freq(maxl)
            || xflag != 0
            || (pflag != 0 && (timeunits != SAMPLES || vflag != 0)))
    {
        ceprintf!(
            b"%s: sampling frequency of record %s is not specified\n",
            pname,
            record
        );
        cstd::exit(2);
    }
    if from > 0 {
        from = wfdbx::strtim(&argv[from as usize]);
        if from < 0 {
            from = -from;
        }
    }
    if wfdbx::isigsettime(from) < 0 {
        cstd::exit(2);
    }
    if to > 0 {
        to = wfdbx::strtim(&argv[to as usize]);
        if to < 0 {
            to = -to;
        }
    }
    // number of samples returned by getvec
    let nvec = nsig as usize;
    let sig: Vec<usize> = if nosig > 0 {
        // print samples only from specified signals
        let mut sig = Vec::with_capacity(nosig);
        for k in 0..nosig {
            let s = wfdbx::findsig(&argv[isiglist + k]);
            if s < 0 {
                ceprintf!(b"%s: can't read signal '%s'\n", pname, argv[isiglist + k]);
                cstd::exit(2);
            }
            sig.push(s as usize);
        }
        sig
    } else {
        // print samples from all signals
        (0..nsig as usize).collect()
    };
    let nsig = sig.len();

    // wfdb-x: no default gain (the C program assumed 200 adu/mV for
    // uncalibrated signals, as legacy mode does).
    if pflag != 0 && !legacy {
        for &s in &sig {
            if si[s].gain == 0.0 {
                ceprintf!(
                    b"%s: signal %d of record %s is uncalibrated\n",
                    pname,
                    s as i32,
                    record
                );
                cstd::exit(2);
            }
        }
    }

    // Reset 'from' if a search was requested.
    if let Some(sx) = search {
        let s = wfdbx::findsig(&argv[sx]);
        let ok = s >= 0 && {
            from = wfdbx::tnextvec(s as u32, from);
            from >= 0
        };
        if !ok {
            ceprintf!(b"%s: can't read signal '%s'\n", pname, argv[sx]);
            cstd::exit(2);
        }
    }

    // Reset 'to' if a duration limit was specified.
    if maxl > 0 {
        maxl = wfdbx::strtim(&argv[maxl as usize]);
        if maxl < 0 {
            maxl = -maxl;
        }
    }
    if maxl != 0 && (to == 0 || to > from + maxl) {
        to = from + maxl;
    }

    // Adjust timeunits if starting time or date is undefined.
    if timeunits == TIMSTR {
        let p = wfdbx::timstr(0);
        if p.first() != Some(&b'[') {
            timeunits = HHMMSS;
        } else if cstd::cstr(&p).len() < 16 {
            // "[hh:mm:ss.sss]": no date
            timeunits = SHORTTIMSTR;
        } else if freq > 1.0 {
            timeunits = MSTIMSTR;
        }
    }
    if timeunits == HOURS {
        freq *= 3600.0;
    } else if timeunits == MINUTES {
        freq *= 60.0;
    }

    // Set formats for output.
    let mut invalid: &[u8] = b"";
    let snfmt: &[u8];
    let tnfmt: &[u8];
    let mut tufmt: Vec<u8> = Vec::new();
    if cflag != 0 {
        // CSV output selected
        snfmt = b",'%s'";
        if pflag != 0 {
            // output in physical units
            let (tn, tu): (&[u8], Vec<u8>) = match timeunits {
                SAMPLES => {
                    let mut t = cformat!(b"'%g sec'", 1.0 / freq);
                    t.truncate(20); // (tustr has 21 bytes)
                    (b"'sample interval'", t)
                }
                SHORTTIMSTR => (b"'Time'", b"'hh:mm:ss.mmm'".to_vec()),
                TIMSTR => (b"'Time and date'", b"'hh:mm:ss dd/mm/yyyy'".to_vec()),
                MSTIMSTR => (b"'Time and date'", b"'hh:mm:ss.mmm dd/mm/yyyy'".to_vec()),
                HHMMSS => (b"'Elapsed time'", b"'hh:mm:ss.mmm'".to_vec()),
                HOURS => (b"'Elapsed time'", b"'hours'".to_vec()),
                MINUTES => (b"'Elapsed time'", b"'minutes'".to_vec()),
                _ => (b"'Elapsed time'", b"'seconds'".to_vec()),
            };
            tnfmt = tn;
            tufmt = tu;
            invalid = b",-";
        } else {
            // output in raw units
            tnfmt = b"'sample #'";
        }
    } else {
        // output in tab-separated columns selected
        if pflag != 0 {
            // output in physical units
            let (tn, tu): (&[u8], Vec<u8>) = match timeunits {
                SAMPLES => {
                    let mut speriod = cformat!(b"(%g", 1.0 / freq);
                    speriod.truncate(10); // (C: speriod[10] = '\0')
                    let mut t = cformat!(b"%10s sec)", speriod);
                    t.truncate(20); // (tustr has 21 bytes)
                    (b"sample interval", t)
                }
                SHORTTIMSTR => (b"     Time", b"(hh:mm:ss.mmm)".to_vec()),
                TIMSTR => (b"   Time      Date    ", b"(hh:mm:ss dd/mm/yyyy)".to_vec()),
                MSTIMSTR => (
                    b"      Time      Date    ",
                    b"(hh:mm:ss.mmm dd/mm/yyyy)".to_vec(),
                ),
                HHMMSS => (b"   Elapsed time", b"   hh:mm:ss.mmm".to_vec()),
                HOURS => (b"   Elapsed time", b"        (hours)".to_vec()),
                MINUTES => (b"   Elapsed time", b"      (minutes)".to_vec()),
                _ => (b"   Elapsed time", b"      (seconds)".to_vec()),
            };
            tnfmt = tn;
            tufmt = tu;
            if pflag > 1 {
                // output in high-precision physical units
                snfmt = b"\t%15s";
                invalid = b"\t              -";
            } else {
                snfmt = b"\t%7s";
                invalid = b"\t      -";
            }
        } else {
            // output in raw units
            snfmt = b"\t%7s";
            tnfmt = b"       sample #";
        }
    }

    let mut out = Out::new();

    // Print WFDB-XML prolog if '-X' option selected.
    if xflag != 0 {
        out.puts(WFDBXMLPROLOG);
        out.printf(
            b"<wfdbsampleset>\n<samplingfrequency>%g</samplingfrequency>\n<signals>%d</signals>\n<description>",
            &[freq.to_arg(), (nsig as i32).to_arg()],
        );
    }
    // Print column headers if '-v' option selected.
    if vflag != 0 {
        out.puts(tnfmt);

        for &s in &sig {
            // Check if a default signal description was provided by looking
            // for the string ", signal " in the desc field. If so, replace
            // it with a shorter string.
            let mut d = cstd::cstr(si[s].desc.as_deref().unwrap_or(b"")).to_vec();
            if d.windows(DEFAULT_DESC.len()).any(|w| w == DEFAULT_DESC) {
                d = cformat!(b"sig %d", s as i32);
            }
            let p: Vec<u8> = if cflag == 0 {
                let l = d.len();
                let lim = if pflag > 1 { VWIDTH_HI } else { VWIDTH };
                if l > lim {
                    d[l - lim..].to_vec()
                } else {
                    d
                }
            } else {
                escapify(&d)
            };
            out.printf(snfmt, &[p.to_arg()]);
        }
        if xflag != 0 {
            out.puts(b"</description>");
        }
        out.puts(b"\n");
    }

    const CHUNK: i64 = 4096; // frames read at a time
    let width = nvec.max(navail);
    // (with room to spare after the last frame, so that getvecs never has
    // to read a frame into a temporary buffer)
    let mut vbuf = vec![0i32; CHUNK as usize * width + width + 64];

    if pflag != 0 {
        // Print units as a second line of column headers if '-v' selected.
        if vflag != 0 {
            if xflag != 0 {
                out.puts(b"<units>");
            }
            out.puts(&tufmt);

            for &s in &sig {
                // wfdb-x: unspecified units are shown as "nd" (C, legacy
                // mode: mV)
                let nd: &[u8] = if legacy { b"mV" } else { b"nd" };
                let u = cstd::cstr(si[s].units.as_deref().unwrap_or(nd)).to_vec();
                if cflag == 0 {
                    // The units, in parentheses, fill the column.
                    let mut len = u.len();
                    if pflag > 1 {
                        if len > VWIDTH_HI - 2 {
                            len = VWIDTH_HI - 2;
                        }
                    } else if len > VWIDTH - 2 {
                        len = VWIDTH - 2;
                    }
                    let mut ustring = vec![b'('];
                    ustring.extend_from_slice(&u[..len]);
                    out.printf(
                        if pflag > 1 { b"\t%14s)" } else { b"\t%6s)" },
                        &[ustring.to_arg()],
                    );
                } else {
                    out.printf(b",'%s'", &[escapify(&u).to_arg()]);
                }
            }
            if xflag != 0 {
                out.puts(b"</units>");
            }
            out.puts(b"\n");
        }

        if xflag != 0 {
            out.puts(b"<samplevectors>\n");
        }
        // Frames are read in blocks unless timstr() or mstimstr() is used.
        let block = matches!(timeunits, SAMPLES | SECONDS | MINUTES | HOURS);
        let vlead = if cflag != 0 { b',' } else { b'\t' };
        let vprec = if pflag > 1 { 8 } else { 3 };
        let vwidth = if cflag != 0 {
            0
        } else if pflag > 1 {
            VWIDTH_HI
        } else {
            VWIDTH
        };
        let tprec = match timeunits {
            MINUTES => 5,
            HOURS => 7,
            _ => 3,
        };
        let twidth = if cflag != 0 { 0 } else { TWIDTH };
        let vfmt: &[u8] = match (cflag != 0, pflag > 1) {
            (true, true) => b"%.8f",
            (true, false) => b"%.3f",
            (false, true) => b"%15.8f",
            (false, false) => b"%7.3f",
        };
        let tfmt: &[u8] = match (cflag != 0, timeunits) {
            (false, MINUTES) => b"%15.5f",
            (false, HOURS) => b"%15.7f",
            (false, _) => b"%15.3f",
            (true, MINUTES) => b"%.5f",
            (true, HOURS) => b"%.7f",
            (true, _) => b"%.3f",
        };
        let gains: Vec<f64> = sig.iter().map(|&s| si[s].gain).collect();
        let bases: Vec<f64> = sig.iter().map(|&s| si[s].baseline as f64).collect();
        while to == 0 || from < to {
            let mut k = if block { CHUNK } else { 1 };
            if to != 0 && to - from < k {
                k = to - from;
            }
            let m = if block {
                wfdbx::getvecs(&mut vbuf, k)
            } else if wfdbx::getvec(&mut vbuf) >= 0 {
                1
            } else {
                0
            };
            for f in 0..m.max(0) as usize {
                let v = &vbuf[f * nvec..];
                if cflag == 0 {
                    match timeunits {
                        TIMSTR => {
                            let t = wfdbx::timstr(-from);
                            out.puts(cstd::cstr(&t));
                        }
                        SHORTTIMSTR | MSTIMSTR => {
                            let t = wfdbx::mstimstr(-from);
                            out.puts(cstd::cstr(&t));
                        }
                        HHMMSS => {
                            let t = if from == 0 {
                                b"0:00.000".to_vec()
                            } else {
                                wfdbx::mstimstr(from)
                            };
                            out.printf(b"%15s", &[t.to_arg()]);
                        }
                        SAMPLES => out.integer(0, from, TWIDTH),
                        _ => out.fixed(0, from as f64 / freq, twidth, tprec, tfmt),
                    }
                } else {
                    match timeunits {
                        TIMSTR => {
                            let t = wfdbx::timstr(-from);
                            out.printf(b"'%s'", &[skip_spaces(&t).to_arg()]);
                        }
                        SHORTTIMSTR | MSTIMSTR => {
                            let t = wfdbx::mstimstr(-from);
                            out.printf(b"'%s'", &[skip_spaces(&t).to_arg()]);
                        }
                        HHMMSS => {
                            if from == 0 {
                                out.puts(b"'0:00.000'");
                            } else {
                                let t = wfdbx::mstimstr(from);
                                out.printf(b"'%s'", &[skip_spaces(&t).to_arg()]);
                            }
                        }
                        SAMPLES => out.integer(0, from, 0),
                        _ => out.fixed(0, from as f64 / freq, twidth, tprec, tfmt),
                    }
                }

                from += 1;
                for (j, &s) in sig.iter().enumerate() {
                    if v[s] != WFDB_INVALID_SAMPLE {
                        out.fixed(
                            vlead,
                            (v[s] as f64 - bases[j]) / gains[j],
                            vwidth,
                            vprec,
                            vfmt,
                        );
                    } else {
                        out.puts(invalid);
                    }
                }
                out.buf.push(b'\n');
                out.maybe_flush();
            }
            if m < k {
                break;
            }
        }
    } else {
        // output in raw units
        if xflag != 0 {
            out.puts(b"<samplevectors>\n");
        }
        let vlead = if cflag != 0 { b',' } else { b'\t' };
        let (twidth, vwidth) = if cflag != 0 { (0, 0) } else { (TWIDTH, VWIDTH) };
        while to == 0 || from < to {
            let mut k = CHUNK;
            if to != 0 && to - from < k {
                k = to - from;
            }
            let m = wfdbx::getvecs(&mut vbuf, k);
            for f in 0..m.max(0) as usize {
                let v = &vbuf[f * nvec..];
                out.integer(0, from, twidth);
                from += 1;
                for &s in &sig {
                    out.integer(vlead, v[s] as i64, vwidth);
                }
                out.buf.push(b'\n');
            }
            out.maybe_flush();
            if m < k {
                break;
            }
        }
    }

    if xflag != 0 {
        // print trailer if WFDB-XML output was selected
        out.puts(b"</samplevectors>\n</wfdbsampleset>\n");
    }

    out.flush();
    wfdbx::wfdbquit();
    cstd::exit(0);
}
