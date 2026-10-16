//! ad2m: convert an AHA format signal file to MIT format (port of
//! `convert/ad2m.c`).
//!
//! The input is either an AHA DB distribution tape format file (read as
//! record `16`, two signals in format 16 on the standard input), or a
//! compressed (`*.CMP`) file from an AHA DB CD-ROM or floppy diskette.
//!
//! Where the C program has undefined behavior (an input file name ending
//! in `/` without `-r`, a record name of more than 7 characters, or a
//! directory as input file), this port uses an empty record name, the full
//! signal file name, and reports the directory as unreadable (see
//! `docs/KNOWN_C_BEHAVIORS.md`).
//
// Copyright (C) 1983-2007 George B. Moody (original C program,
// convert/ad2m.c).
// Rust implementation part of wfdb-x, Reza Sameni, Oct 2026.
// Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
// gain, ADC resolution or units. Values that the record or the user does not
// give are never assumed (the original package assumed 250 Hz, 200 adu/mV,
// 12 bits and millivolts), because a silently assumed value corrupts every
// result derived from it. See docs/DIVERGENCES.md.
// GNU General Public License, version 2 or later (see LICENSE).

use wfdbx::cstd;
use wfdbx::cstd::EOF;
use wfdbx::{ceprintf, csscanf, Siginfo, WfdbFile};

const EODF: i32 = 0o100000; // AHA data file end-of-data marker

const HELP_STRINGS: &[&[u8]] = &[
    b"usage: %s -i AHAFILE [ OPTIONS ... ]\n",
    b"where AHAFILE is the name of the AHA-format input signal file,",
    b"and OPTIONS may include:",
    b" -c         process a compressed input file (default if AHAFILE ends",
    b"             with .CMP or .cmp;  otherwise old AHA tape format assumed)",
    b" -f TIME    begin at specified TIME (default: 0, i.e., the beginning",
    b"             of the input file)",
    b" -F FREQ    sampling frequency in Hz (required; AHA database: 250)",
    b" -G GAIN    gain in adu per physical unit (required; AHA database: 400)",
    b" -h         print this usage summary",
    // (two strings concatenated by a misplaced comma in C)
    b" -r RECORD  specify the name of the output RECORD (default: use the,            input file name, less path info and extension, as RECORD)",
    b" -R BITS    ADC resolution in bits (required; AHA database: 12)",
    b" -t TIME    stop at specified TIME (default: 35 minutes after the",
    b"             starting time if RECORD=x2xx or x3xx, 3 hours if",
    b"             RECORD=x0xx or x1xx, or the end of the input file)",
    b" -U UNITS   physical units (required unless the gain is 0; AHA: mV)",
];

/// wfdb-x: the lines of `HELP_STRINGS` added by wfdb-x, left out of the
/// help text of the original program (printed in legacy mode).
const WFDBX_HELP_LINES: &[&[u8]] = &[
    b" -F FREQ    sampling frequency in Hz (required; AHA database: 250)",
    b" -G GAIN    gain in adu per physical unit (required; AHA database: 400)",
    b" -R BITS    ADC resolution in bits (required; AHA database: 12)",
    b" -U UNITS   physical units (required unless the gain is 0; AHA: mV)",
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

// The AHA Database: two ECG signals sampled at 250 Hz, with 12-bit
// resolution and 400 adu/mV (the parameters of the C program, legacy mode).
const AHA_FREQ: f64 = 250.0;
const AHA_GAIN: f64 = 400.0;
const AHA_ADCRES: i32 = 12;

fn is_directory(name: &[u8]) -> bool {
    std::fs::metadata(cstd::bytes_to_path(name)).is_ok_and(|m| m.is_dir())
}

/// Reader of compressed-format input (the static variables of C's
/// `getcvec`).
///
/// The compressed format stores first differences of the two signals: if
/// the high bit of the first byte is 0, its other 7 bits are the (signed)
/// difference for signal 0 and the next byte that for signal 1; otherwise
/// the next 15 bits are the difference for signal 0, and the following 16
/// bits that for signal 1.
struct Cmp {
    input: WfdbFile,
    v0: i32,
    v1: i32,
}

impl Cmp {
    /// Read a pair of samples; 2 on success, 0 at end of file.
    fn getcvec(&mut self, v: &mut [i32; 2]) -> i32 {
        let mut x = self.input.getc();
        if x == EOF {
            return 0;
        }
        let mut y = self.input.getc();
        if y == EOF {
            ceprintf!(b"unexpected EOF in input file\n");
            return 0;
        }

        if (x & 0x80) == 0 {
            self.v0 = self.v0.wrapping_add(x & 0x7f);
            if x & 0x40 != 0 {
                self.v0 = self.v0.wrapping_add(-128);
            }
            self.v1 = self.v1.wrapping_add(y);
            if y & 0x80 != 0 {
                self.v1 = self.v1.wrapping_add(-256);
            }
        } else {
            if x & 0x40 != 0 {
                x |= !0x3f;
            } else {
                x &= 0x7f;
            }
            self.v0 = self.v0.wrapping_add(x * 256 + y);
            x = self.input.getc();
            if x != EOF {
                y = self.input.getc();
            }
            if x == EOF || y == EOF {
                ceprintf!(b"unexpected EOF in input file\n");
                return 0;
            }
            if x & 0x80 != 0 {
                x |= !0xff;
            }
            self.v1 = self.v1.wrapping_add(x * 256 + y);
        }

        v[0] = self.v0;
        v[1] = self.v1;
        2
    }
}

fn main() {
    let mut argv = cstd::args();
    let legacy = wfdbx::wfdbx_legacy_args(&mut argv) != 0; // wfdb-x: --legacy
    let argc = argv.len();
    let pname = cstd::prog_name(&argv[0]).to_vec();
    let mut ifname: Option<&[u8]> = None;
    let mut record: Option<Vec<u8>> = None;
    let mut cflag = false;
    let mut v = [0i32; 2];
    let mut t: i64 = 0;
    let mut start_time: i64 = 0;
    let mut end_time: i64 = 0;
    // wfdb-x: the signal parameters (-F, -G, -R, -U), and the -f and -t
    // arguments (converted once -F is known)
    let mut uunits: Option<Vec<u8>> = None;
    let mut fstr: Option<&[u8]> = None;
    let mut tstr: Option<&[u8]> = None;
    let mut ffreq = 0.0;
    let mut ggain = 0.0;
    let mut gset = false;
    let mut rres: i32 = 0;
    if legacy {
        // wfdb-x: in legacy mode, the parameters of the AHA database, set by
        // the C program (250 Hz, 400 adu/mV, 12 bits, and no units, i.e.,
        // millivolts); -F, -G, -R and -U are not options then.
        ffreq = AHA_FREQ;
        ggain = AHA_GAIN;
        gset = true;
        rres = AHA_ADCRES;
        wfdbx::setsampfreq(AHA_FREQ);
    }

    let mut i = 1;
    while i < argc {
        let a = &argv[i];
        if a.first() == Some(&b'-') {
            match a.get(1).copied().unwrap_or(0) {
                b'c' => cflag = true,
                b'f' => {
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: start time must follow -f\n", pname);
                        cstd::exit(1);
                    }
                    if legacy {
                        start_time = wfdbx::strtim(&argv[i]); // as in the C program
                    } else {
                        fstr = Some(&argv[i]); // converted once -F is known (wfdb-x)
                    }
                }
                b'h' => {
                    // help requested
                    help(&pname);
                    cstd::exit(1);
                }
                b'i' => {
                    // input file name follows
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: name of AHA-format input file must follow -i\n", pname);
                        cstd::exit(1);
                    }
                    ifname = Some(cstd::cstr(&argv[i]));
                }
                b'r' => {
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: record name must follow -r\n", pname);
                        cstd::exit(1);
                    }
                    record = Some(cstd::cstr(&argv[i]).to_vec());
                }
                b't' => {
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: end time must follow -t\n", pname);
                        cstd::exit(1);
                    }
                    if legacy {
                        end_time = wfdbx::strtim(&argv[i]); // as in the C program
                    } else {
                        tstr = Some(&argv[i]); // converted once -F is known (wfdb-x)
                    }
                }
                b'F' if !legacy => {
                    // sampling frequency (wfdb-x)
                    i += 1;
                    if i >= argc || csscanf!(&argv[i], b"%lf", &mut ffreq) != 1 || ffreq <= 0.0 {
                        ceprintf!(b"%s: sampling frequency (> 0) must follow -F\n", pname);
                        cstd::exit(1);
                    }
                }
                b'G' if !legacy => {
                    // gain in adu per physical unit (wfdb-x)
                    i += 1;
                    if i >= argc || csscanf!(&argv[i], b"%lf", &mut ggain) != 1 || ggain < 0.0 {
                        ceprintf!(b"%s: gain (>= 0) must follow -G\n", pname);
                        cstd::exit(1);
                    }
                    gset = true;
                }
                b'R' if !legacy => {
                    // ADC resolution in bits (wfdb-x)
                    i += 1;
                    if i >= argc
                        || csscanf!(&argv[i], b"%d", &mut rres) != 1
                        || !(1..=32).contains(&rres)
                    {
                        ceprintf!(b"%s: ADC resolution (1-32 bits) must follow -R\n", pname);
                        cstd::exit(1);
                    }
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
    let Some(ifname) = ifname else {
        help(&pname);
        cstd::exit(1);
    };
    // wfdb-x: the signal parameters must be given explicitly; the C program
    // assumed those of the AHA database (250 Hz, 400 adu/mV, 12 bits, and no
    // units, i.e., millivolts), as legacy mode does (the values set above for
    // legacy mode pass these checks, and no units are required then).
    if ffreq <= 0.0 {
        ceprintf!(
            b"%s: the sampling frequency must be specified (-F)\n",
            pname
        );
        cstd::exit(1);
    }
    if !gset {
        ceprintf!(b"%s: the gain must be specified (-G)\n", pname);
        cstd::exit(1);
    }
    if rres < 1 {
        ceprintf!(b"%s: the ADC resolution must be specified (-R)\n", pname);
        cstd::exit(1);
    }
    if ggain != 0.0 && uunits.is_none() && !legacy {
        ceprintf!(b"%s: the units must be specified (-U)\n", pname);
        cstd::exit(1);
    }
    wfdbx::setsampfreq(ffreq);
    if let Some(f) = fstr {
        start_time = wfdbx::strtim(f);
    }
    if let Some(t) = tstr {
        end_time = wfdbx::strtim(t);
    }
    if 0 < end_time && end_time <= start_time {
        help(&pname);
        cstd::exit(1);
    }
    if !cflag && ifname.len() > 4 {
        let q = &ifname[ifname.len() - 4..];
        if q == b".CMP" || q == b".cmp" {
            cflag = true;
        }
    }

    // Attach the input file to the standard input.
    // (C reads a directory forever; wfdb-x reports it as unreadable)
    if ifname != b"-" && (is_directory(ifname) || !wfdbx::freopen_stdin(ifname)) {
        ceprintf!(b"%s: can't read input file `%s'\n", pname, ifname);
        cstd::exit(2);
    }

    // If no output record name was specified, use the basename of the input
    // file, less any extension.
    let record = record.unwrap_or_else(|| {
        let mut r = cstd::prog_name(ifname).to_vec();
        if let Some(p) = r.iter().skip(1).position(|&c| c == b'.') {
            r.truncate(p + 1);
        }
        r
    });

    if end_time == 0 && record.len() == 4 {
        // assume AHA DB input
        if record[1] == b'2' || record[1] == b'3' {
            // short format record
            end_time = wfdbx::strtim("35:0");
        } else if record[1] == b'0' || record[1] == b'1' {
            // long format record
            end_time = wfdbx::strtim("3:0:0");
        }
    }

    if end_time == 0 {
        ceprintf!(
            b"%s: warning: end time not specified, output may be truncated\n",
            pname
        );
        ceprintf!(b"               rerun with -t TIME to override\n");
        end_time = start_time.wrapping_add(wfdbx::strtim("100:0:0"));
    }

    let mut dfname = record.clone();
    dfname.extend_from_slice(b".dat");
    let si = Siginfo {
        fname: Some(dfname),
        desc: Some(Vec::new()),
        gain: ggain,
        units: uunits,
        fmt: 212,
        adcres: rres,
        ..Siginfo::default()
    };
    let mut dfarray = vec![si.clone(), si];
    if wfdbx::osigfopen(&dfarray, 2) < 0 {
        cstd::exit(3);
    }

    if !cflag {
        // process tape-format input file
        if wfdbx::isigopen("16", &mut dfarray[..], 2) < 2 {
            cstd::exit(2);
        }
        if start_time > 0 {
            t = start_time;
            if wfdbx::isigsettime(t) < 0 {
                cstd::exit(2);
            }
        }
        // continue to soft EOF, hard error, or specified time
        while wfdbx::getvec(&mut v) == 2 && v[0] != EODF && wfdbx::putvec(&v) > 0 && {
            t += 1;
            t < end_time
        } {}

        // write header with correct signal length and checksums
        wfdbx::newheader(&record);
        // continue to hard EOF (to position tape properly if reading from
        // tape)
        while wfdbx::getvec(&mut v) >= 0 {}
    } else {
        // process compressed-format input file
        let mut cmp = Cmp {
            input: WfdbFile::stdin(),
            v0: 0,
            v1: 0,
        };
        while t < start_time && cmp.getcvec(&mut v) == 2 {
            t += 1;
        }
        // continue to hard EOF, hard error, or specified time
        while cmp.getcvec(&mut v) == 2 && wfdbx::putvec(&v) > 0 && {
            t += 1;
            t < end_time
        } {}

        // write header with correct signal length and checksums
        wfdbx::newheader(&record);
    }

    wfdbx::wfdbquit();
    cstd::exit(0);
}
