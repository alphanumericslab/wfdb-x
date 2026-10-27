//! wrsamp: select fields or columns from a file and generate a WFDB record
//! (port of `app/wrsamp.c`).
//!
//! Where the C program's behavior is undefined (input lines that end with a
//! field separator, lines with fewer fields than the selected columns), the
//! behavior described in `docs/KNOWN_C_BEHAVIORS.md` is used.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Rust translation of app/wrsamp.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: no built-in sampling frequency, gain, ADC
// resolution or units: when a record is written (-o), -F, -G and the new
// option -R BITS are required, and the new option -U UNITS for calibrated
// signals unless the input gives the units (the original assumed 250 Hz, 200
// adu/mV, a resolution based on the format, and millivolts); -G 0 declares the
// signals uncalibrated; -G, -R and -U take one value per signal; --legacy, as
// the first argument, restores the original behavior. Each change is marked
// "wfdb-x:" in the code; docs/DIVERGENCES.md gives the reasons.
//
// Original C program: app/wrsamp.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1993-2014 George B. Moody; revised 2020 by Benjamin Moody.
// Rust translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

use wfdbx::cstd::{self, d2i, GlibcRand, EOF, RAND_MAX};
use wfdbx::WFDB_INVALID_SAMPLE;
use wfdbx::{ceprintf, csscanf, Siginfo, WfdbFile, WFDB_DEFFREQ, WFDB_DEFGAIN, WFDB_DEFRES};

/// The ADC resolution of the C program (legacy mode): from the format, or
/// WFDB_DEFRES.
fn legacy_adcres(format: i32) -> i32 {
    match format {
        508 | 80 => 8,
        310 | 311 => 10,
        212 => 12,
        516 | 16 | 160 | 61 => 16,
        524 | 24 => 24,
        32 => 32,
        // resolution for unknown future formats
        _ if format > 100 && format % 100 > 0 && format % 100 <= 32 => format % 100,
        _ => WFDB_DEFRES,
    }
}

/// The dither generator (triangular PDF in (-1,1)).
fn dither(rng: &mut GlibcRand) -> f64 {
    let a = rng.rand() as f64;
    let b = rng.rand() as f64;
    (a + b) / RAND_MAX as f64 - 1.0
}

/// Read a line delimited by `rsep` (an unterminated last line is
/// discarded). Returns `None` at the end of the input. As in C, the line is
/// a C string (it ends at its first null character, if any).
fn read_line(ifile: &mut WfdbFile, rsep: u8) -> Option<Vec<u8>> {
    let mut buf = Vec::new();
    loop {
        let c = ifile.getc();
        if c == rsep as i32 {
            break;
        }
        if c == EOF {
            return None;
        }
        buf.push(c as u8);
    }
    let n = cstd::cstr(&buf).len();
    buf.truncate(n);
    Some(buf)
}

fn line_has_alpha(line: Option<&[u8]>) -> bool {
    let Some(line) = line else {
        return false;
    };
    let at = |i: usize| -> u8 { line.get(i).copied().unwrap_or(0) };
    let mut p = 0usize;
    while at(p) != 0 {
        let c = at(p);
        if c == b'e' || c == b'E' {
            // might be a number in printf %f form: ignore 'e' or 'E' if
            // followed by a digit or a sign
            p += 1;
            let d = at(p);
            if (d as i8) <= b'9' as i8 || d == b'-' || d == b'+' {
                if d == 0 {
                    break;
                }
                p += 1;
                continue;
            }
        }
        let c = at(p);
        if c.is_ascii_alphabetic() {
            return true;
        }
        p += 1;
    }
    false
}

fn line_has_tab(line: &[u8]) -> bool {
    line.contains(&b'\t')
}

/// Parse a line into tokens (as `parseline()` in `wrsamp.c`, with consecutive
/// delimiters collapsed and '\\' as the escape character). Quoted tokens
/// ('...', "...", or <...>) may contain delimiters.
fn parseline(line: &[u8], delim: &[u8]) -> Vec<Vec<u8>> {
    let esc = b'\\';
    let mut tokens = Vec::new();
    let n = line.len();
    let mut p = 0usize;
    while p < n {
        while p < n && delim.contains(&line[p]) {
            p += 1;
        }
        if p >= n {
            break;
        }
        let mut q = 0u8;
        if line[p] == b'"' || line[p] == b'\'' {
            q = line[p];
            p += 1;
        } else if line[p] == b'<' {
            p += 1;
            q = b'>';
        }
        let mut tok = Vec::new();
        while p < n && (q != 0 || !delim.contains(&line[p])) {
            let c = line[p];
            if c == esc {
                if p + 1 >= n {
                    break; // escape at end of line -- ignore
                }
                tok.push(line[p + 1]);
                p += 2;
                continue;
            }
            if c == q {
                // found the closing quote
                p += 1;
                break;
            }
            tok.push(c);
            p += 1;
        }
        tokens.push(tok);
    }
    tokens
}

const HELP_STRINGS: &[&str] = &[
    "usage: %s [OPTIONS ...] [COLUMN ...]\n",
    "where COLUMN selects a field to be copied (leftmost field is column 0),",
    "and OPTIONS may include:",
    " -c          check that each input line contains the same number of fields",
    " -d          add dither to the input",
    " -f N        start copying with line N (default: 0)",
    " -F FREQ     specify frequency to be written to header file (required",
    "              with -o)",
    " -G GAIN     specify gain(s) to be written to header file (required with",
    "              -o; 0 means uncalibrated)",
    " -h          print this usage summary",
    " -i FILE     read input from FILE (default: standard input)",
    " -o RECORD   save output in RECORD.dat, and generate a header file for",
    "              RECORD (default: write to standard output in format 16, do",
    "              not generate a header file)",
    " -O FORMAT   save output in the specified FORMAT (default: 16)",
    " -r RSEP     interpret RSEP as the input line separator (default: linefeed)",
    " -R BITS     specify ADC resolution(s) in bits (required with -o)",
    " -s FSEP     interpret any character in FSEP as an input field separator",
    "             (default: space, tab, carriage-return, or comma)  ",
    " -t N        stop copying at line N (default: end of input file)",
    " -U UNITS    specify units (required with -o for calibrated signals, unless",
    "              the input gives them)",
    " -x SCALE    multiply inputs by SCALE factor(s) (default: 1)",
    " -z          don't copy column 0 unless explicitly specified",
    "",
    "The input is a text file with a sample of each signal on each line. Samples",
    "can be separated by tabs, spaces, commas, or any combination of these.",
    "Consecutive separators are equivalent to single separators.",
    "",
    "To specify different GAIN or SCALE values for each output signal, provide",
    "a quoted list of values, e.g., -G \"100 50\" defines the gain for signal 0",
    "as 100, and the gain for signal 1 (and any additional signals) as 50.",
    "",
    "If the first input line contains any alphabetic characters, it is assumed",
    "to contain column headings, which are copied as signal descriptions into",
    "RECORD.hea.  If the second input line also contains alphabetic characters,",
    "it is assumed to specify the physical units for each column, which are",
    "copied as units strings into RECORD.hea.  The first line containing samples",
    "is line 0.",
    "",
    "If no COLUMN is specified, all fields are copied in order; column 0 can be",
    "omitted in this case by using the '-z' option.",
];

/// Lines of the usage summary shown before each "--More--" prompt.
const PAGELINES: usize = 23;

/// wfdb-x: the lines of `HELP_STRINGS` that differ in the help text of the
/// original program (printed in legacy mode): each is replaced by the
/// original line, or left out (`None`).
const LEGACY_HELP_EDITS: &[(&str, Option<&str>)] = &[
    (
        " -F FREQ     specify frequency to be written to header file (required",
        Some(" -F FREQ     specify frequency to be written to header file (default: 250)"),
    ),
    ("              with -o)", None),
    (
        " -G GAIN     specify gain(s) to be written to header file (required with",
        Some(" -G GAIN     specify gain(s) to be written to header file (default: 200)"),
    ),
    ("              -o; 0 means uncalibrated)", None),
    (
        " -R BITS     specify ADC resolution(s) in bits (required with -o)",
        None,
    ),
    (
        " -U UNITS    specify units (required with -o for calibrated signals, unless",
        None,
    ),
    ("              the input gives them)", None),
];

fn help(pname: &[u8]) {
    let legacy = wfdbx::wfdbx_get_legacy() != 0;
    ceprintf!(HELP_STRINGS[0].as_bytes(), pname);
    let lines = HELP_STRINGS[1..].iter().filter_map(|&s| {
        match LEGACY_HELP_EDITS.iter().find(|e| legacy && e.0 == s) {
            Some(e) => e.1,
            None => Some(s),
        }
    });
    for (i, s) in (1..).zip(lines) {
        ceprintf!(b"%s\n", s);
        if i % PAGELINES == 0 {
            ceprintf!(b"--More--");
            let mut stdin = WfdbFile::stdin();
            let mut b = Vec::new();
            stdin.fgets(&mut b, 5); // (C: a 5-byte buffer)
            drop(stdin);
            ceprintf!(b"\x1b[A\x1b[2K"); // erase "--More--"
        }
    }
}

/// `sscanf(s, "%lf", &x)`.
fn scan_f64(s: &[u8], x: &mut f64) -> i32 {
    csscanf!(s, b"%lf", x)
}

fn main() {
    let mut argv = cstd::args();
    let legacy = wfdbx::wfdbx_legacy_args(&mut argv) != 0; // wfdb-x: --legacy
    let argc = argv.len();
    let pname = cstd::prog_name(&argv[0]).to_vec();
    let mut gain: Vec<u8> = Vec::new();
    let mut scale: Vec<u8> = Vec::new();
    let mut res: Vec<u8> = Vec::new(); // wfdb-x: -R
    let mut uopt: Option<Vec<u8>> = None; // wfdb-x: -U
    let mut record: Option<Vec<u8>> = None;
    let mut delim: Vec<u8> = b" \t\r\n,".to_vec(); // defpmode.delim
    let mut rsep = b'\n';
    let mut sflag = false;
    let mut xflag = false;
    let mut dstrings: Vec<Vec<u8>> = Vec::new();
    let mut ustrings: Vec<Vec<u8>> = Vec::new();
    let mut have_dstrings = false;
    let mut have_ustrings = false;
    // wfdb-x: no default frequency (legacy mode: that of the C program)
    let mut freq = if legacy { WFDB_DEFFREQ } else { 0.0 };
    let mut dflag = false;
    let mut format = 16;
    let mut zflag: u32 = 0;
    let mut ifile = WfdbFile::stdin();
    let mut ifile_is_stdin = true;
    let (mut t0, mut t1): (i64, i64) = (0, 0);
    let mut rng = GlibcRand::default();
    let mut ncols: u32;

    let mut i = 1usize;
    while i < argc && argv[i].first() == Some(&b'-') {
        match argv[i].get(1).copied().unwrap_or(0) {
            b'c' => {}
            b'd' => {
                dflag = true;
                rng.srand(0); // seed for dither RNG
            }
            b'f' => {
                i += 1;
                if i < argc {
                    t0 = cstd::atol(&argv[i]);
                }
                if i >= argc || t0 <= 0 {
                    ceprintf!(b"%s: starting line # must follow -f\n", pname);
                    cstd::exit(1);
                }
            }
            b'F' => {
                i += 1;
                if i < argc {
                    freq = cstd::atof(&argv[i]);
                }
                if i >= argc || freq <= 0.0 {
                    ceprintf!(b"%s: sampling frequency must follow -F\n", pname);
                    cstd::exit(1);
                }
            }
            b'G' => {
                i += 1;
                if i >= argc {
                    ceprintf!(b"%s: gain(s) must follow -G\n", pname);
                    cstd::exit(1);
                }
                gain = cstd::cstr(&argv[i]).to_vec();
            }
            b'h' => {
                help(&pname);
                cstd::exit(1);
            }
            b'R' if !legacy => {
                // wfdb-x: ADC resolution(s) in bits
                i += 1;
                if i >= argc {
                    ceprintf!(b"%s: ADC resolution(s) must follow -R\n", pname);
                    cstd::exit(1);
                }
                res = cstd::cstr(&argv[i]).to_vec();
            }
            b'U' if !legacy => {
                // wfdb-x: units
                i += 1;
                if i >= argc {
                    ceprintf!(b"%s: units must follow -U\n", pname);
                    cstd::exit(1);
                }
                uopt = Some(cstd::cstr(&argv[i]).to_vec());
            }
            b'i' => {
                i += 1;
                if i >= argc {
                    ceprintf!(b"%s: input file name must follow -i\n", pname);
                    cstd::exit(1);
                }
                if argv[i] == b"-" {
                    if !ifile_is_stdin {
                        ifile = WfdbFile::stdin();
                        ifile_is_stdin = true;
                    }
                } else {
                    match WfdbFile::fopen(&argv[i], b"r") {
                        Some(f) => {
                            ifile = f;
                            ifile_is_stdin = false;
                        }
                        None => {
                            ceprintf!(b"%s: can't read `%s'\n", pname, argv[i]);
                            cstd::exit(2);
                        }
                    }
                }
            }
            b'l' => {
                i += 1;
                if i >= argc {
                    i -= 1;
                }
                ceprintf!(b"%s: -l is obsolete, ignored\n", pname);
            }
            b'o' => {
                i += 1;
                if i >= argc {
                    ceprintf!(b"%s: record name must follow -o\n", pname);
                    cstd::exit(1);
                }
                record = Some(cstd::cstr(&argv[i]).to_vec());
            }
            b'O' => {
                i += 1;
                if i >= argc {
                    ceprintf!(b"%s: output format must follow -O\n", pname);
                    cstd::exit(1);
                }
                format = cstd::atoi(&argv[i]);
            }
            b'r' => {
                i += 1;
                if i >= argc {
                    ceprintf!(b"%s: line separator must follow -r\n", pname);
                    cstd::exit(1);
                }
                rsep = argv[i].first().copied().unwrap_or(0);
            }
            b's' => {
                i += 1;
                if i >= argc {
                    ceprintf!(b"%s: field separator(s) must follow -s\n", pname);
                    cstd::exit(1);
                }
                sflag = true;
                delim = cstd::cstr(&argv[i]).to_vec();
            }
            b't' => {
                i += 1;
                if i < argc {
                    t1 = cstd::atol(&argv[i]);
                }
                if i >= argc || t1 <= 0 {
                    ceprintf!(b"%s: ending line # must follow -t\n", pname);
                    cstd::exit(1);
                }
            }
            b'x' => {
                i += 1;
                if i >= argc {
                    ceprintf!(b"%s: scaling factor(s) must follow -x\n", pname);
                    cstd::exit(1);
                }
                scale = cstd::cstr(&argv[i]).to_vec();
            }
            b'z' => zflag = 1, // ignore column 0
            _ => {
                ceprintf!(b"%s: unrecognized option %s\n", pname, argv[i]);
                cstd::exit(1);
            }
        }
        i += 1;
    }

    // wfdb-x: the sampling frequency, the gains, the ADC resolutions, and the
    // units (of calibrated signals) must be specified when a header is
    // written (the C program assumed 250 Hz, 200 adu/mV, a resolution based
    // on the format, and millivolts), as legacy mode does.
    let check = record.is_some() && !legacy;
    if check && freq <= 0.0 {
        ceprintf!(
            b"%s: the sampling frequency must be specified (-F)\n",
            pname
        );
        cstd::exit(1);
    }
    if check && gain.is_empty() {
        ceprintf!(b"%s: the gain(s) must be specified (-G)\n", pname);
        cstd::exit(1);
    }
    if check && res.is_empty() {
        ceprintf!(b"%s: the ADC resolution(s) must be specified (-R)\n", pname);
        cstd::exit(1);
    }

    let mut nosig: u32 = (argc - i) as u32; // any remaining arguments are column numbers

    // Determine the number of input columns, and (if present) the signal
    // names and the units for each signal. Start by reading the first line
    // of the input file.
    let mut line = read_line(&mut ifile, rsep);
    if line.is_none() {
        if rsep != b'\n' {
            if record.is_none() {
                ceprintf!(b"%s: use -o to specify the output record name", pname);
            } else {
                ceprintf!(
                    b"%s: no record separators in input\nTry specifying a different separator after the -r option.\n",
                    pname
                );
            }
        } else {
            ceprintf!(b"%s: no newlines in input\n", pname);
        }
        cstd::exit(3);
    }
    let first = line.clone().unwrap();
    // Recognize WFDB-XML format if present.
    if first.starts_with(b"<?xml ") {
        xflag = true;
        zflag = 1; // ignore column 0
        ncols = 0;
        loop {
            line = read_line(&mut ifile, rsep);
            match &line {
                None => {
                    ceprintf!(b"%s: XML input, but no <wfdbsampleset> found\n", pname);
                    cstd::exit(1);
                }
                Some(l) if l == b"<wfdbsampleset>" => break,
                _ => {}
            }
        }
        loop {
            line = read_line(&mut ifile, rsep);
            let Some(l) = &line else {
                ceprintf!(b"%s: empty <wfdbsampleset>\n", pname);
                cstd::exit(1);
            };
            // strip `open` and `close` tags from the line
            let strip = |open: &[u8], close: &[u8]| -> &[u8] {
                if l.len() >= open.len() + close.len() {
                    &l[open.len()..l.len() - close.len()]
                } else {
                    b""
                }
            };
            if let Some(f) = l.strip_prefix(b"<samplingfrequency>") {
                scan_f64(f, &mut freq);
            } else if l.starts_with(b"<description>") {
                let d = strip(b"<description>", b"</description>");
                let ta = parseline(d, &delim);
                ncols = ta.len() as u32;
                dstrings = ta;
                have_dstrings = true;
            } else if l.starts_with(b"<units>") {
                let u = strip(b"<units>", b"</units>");
                ustrings = parseline(u, &delim);
                have_ustrings = true;
            }
            if l == b"<samplevectors>" {
                break;
            }
        }
        line = read_line(&mut ifile, rsep);
        if line.is_none() {
            ceprintf!(b"%s: empty <wfdbsampleset>\n", pname);
            cstd::exit(1);
        }
    } else {
        // non-XML input
        // Unless -s was given, note if line 0 contains any tab characters.
        if !sflag && line_has_tab(&first) {
            delim = b"\t".to_vec();
        }
        let ta = parseline(&first, &delim);
        ncols = ta.len() as u32;
        // If it contains any alphabetic characters, save the signal names.
        if line_has_alpha(Some(&first)) {
            have_dstrings = true;
            for tk in &ta {
                let k = tk.iter().take_while(|&&c| c == b' ').count();
                dstrings.push(tk[k..].to_vec());
            }
            // Read the second line.
            line = read_line(&mut ifile, rsep);
            match &line {
                None => {
                    ceprintf!(b"%s: no data\n", pname);
                    cstd::exit(1);
                }
                Some(l) if line_has_alpha(Some(l)) => {
                    // If it has any alphabetic characters, save the unit
                    // strings.
                    let ta = parseline(l, &delim);
                    have_ustrings = true;
                    for tk in &ta {
                        let k = tk.iter().take_while(|&&c| c == b' ').count();
                        let mut u = tk[k..].to_vec();
                        if u.first() == Some(&b'(') {
                            let last = *u.last().unwrap();
                            u.remove(0);
                            if last == b')' {
                                u.pop();
                            }
                        }
                        ustrings.push(u);
                    }
                    // Read the third line.
                    line = read_line(&mut ifile, rsep);
                    if line.is_none() {
                        ceprintf!(b"%s: no data\n", pname);
                        cstd::exit(1);
                    }
                }
                _ => {}
            }
        }
    }

    // read selected column numbers into fv[...]
    let mut fv: Vec<i32>;
    if nosig != 0 {
        fv = vec![0; nosig as usize];
        for (j, k) in (argc - nosig as usize..argc).enumerate() {
            if csscanf!(&argv[k], b"%d", &mut fv[j]) != 1 || fv[j] < 0 || fv[j] as u32 >= ncols {
                ceprintf!(b"%s: unrecognized argument %s\n", pname, argv[k]);
                cstd::exit(1);
            }
        }
    } else {
        // copy all column numbers (or all except 0) into fv[...]
        nosig = ncols.wrapping_sub(zflag);
        if nosig > i32::MAX as u32 {
            ceprintf!(
                b"WFDB: can't allocate (%lu*%lu) bytes for fv\n",
                nosig as u64,
                std::mem::size_of::<i32>() as u64
            );
            cstd::exit(1);
        }
        fv = (0..nosig as i32).map(|k| k + zflag as i32).collect();
    }

    let n = nosig as usize;
    let mut vout = vec![0i32; n];
    let mut si = vec![Siginfo::default(); n];
    let mut scalef = vec![0f64; n];

    // open the output record
    let ofname: Vec<u8> = match &record {
        None => b"-".to_vec(),
        Some(r) => {
            let mut v = r.clone();
            v.extend_from_slice(b".dat");
            v
        }
    };

    let mut gp = 0usize; // position in gain
    let mut sp = 0usize; // position in scale
    let mut rp = 0usize; // position in res
    let mut up = 0usize; // position in the -U string
    let mut prev_units: Vec<u8> = Vec::new();
    let mut prev_adcres = 0i32;
    for k in 0..n {
        let s = &mut si[k];
        s.fname = Some(ofname.clone());
        s.desc = Some(if have_dstrings {
            dstrings.get(fv[k] as usize).cloned().unwrap_or_default()
        } else {
            wfdbx::cformat!(b"col %d", fv[k])
        });
        if let Some(u) = &uopt {
            // wfdb-x: -U (the last one applies to the rest)
            let mut q = up;
            while u.get(q) == Some(&b' ') {
                q += 1;
            }
            up = q;
            if q < u.len() {
                while q < u.len() && u[q] != b' ' {
                    q += 1;
                }
                s.units = Some(u[up..q].to_vec());
                up = q;
            } else {
                s.units = Some(prev_units.clone());
            }
        } else {
            s.units = Some(if have_ustrings {
                ustrings.get(fv[k] as usize).cloned().unwrap_or_default()
            } else {
                Vec::new()
            });
        }
        prev_units = s.units.clone().unwrap_or_default();
        s.group = 0;
        s.fmt = format;
        s.spf = 1;
        s.bsize = 0;
        // wfdb-x: the ADC resolutions are given by -R (the last one applies
        // to the remaining signals); the C program inferred them from the
        // format or assumed WFDB_DEFRES, as legacy mode does.
        if legacy {
            s.adcres = legacy_adcres(format); // wfdb-x: legacy mode
        } else {
            while res.get(rp) == Some(&b' ') {
                rp += 1;
            }
            let mut r = 0i32;
            if csscanf!(&res[rp.min(res.len())..], b"%d", &mut r) < 1 {
                s.adcres = if k == 0 { 0 } else { prev_adcres };
            } else {
                s.adcres = r;
                while rp < res.len() && res[rp] != b' ' {
                    rp += 1;
                }
            }
        }
        prev_adcres = s.adcres;
        if check && s.adcres < 1 {
            ceprintf!(b"%s: the ADC resolution(s) must be specified (-R)\n", pname);
            cstd::exit(1);
        }
        s.adczero = 0;
        s.baseline = 0;
        while gain.get(gp) == Some(&b' ') {
            gp += 1;
        }
        let mut g = 0.0;
        if scan_f64(&gain[gp.min(gain.len())..], &mut g) < 1 {
            // wfdb-x: C (legacy mode): WFDB_DEFGAIN
            let g0 = if legacy { WFDB_DEFGAIN } else { 0.0 };
            si[k].gain = if k == 0 { g0 } else { si[k - 1].gain };
        } else {
            si[k].gain = g;
            while gp < gain.len() && gain[gp] != b' ' {
                gp += 1;
            }
        }
        // wfdb-x: the units of a calibrated signal must be specified, by -U
        // or by the input (the C program left them out: millivolts).
        if check && si[k].gain != 0.0 && si[k].units.as_deref().unwrap_or_default().is_empty() {
            ceprintf!(b"%s: the units must be specified (-U)\n", pname);
            cstd::exit(1);
        }
        while scale.get(sp) == Some(&b' ') {
            sp += 1;
        }
        let mut x = 0.0;
        if scan_f64(&scale[sp.min(scale.len())..], &mut x) < 1 {
            scalef[k] = if k == 0 { 1.0 } else { scalef[k - 1] };
        } else {
            scalef[k] = x;
            while sp < scale.len() && scale[sp] != b' ' {
                sp += 1;
            }
        }
    }

    // discard any additional lines containing text
    while line_has_alpha(line.as_deref()) {
        line = read_line(&mut ifile, rsep);
    }

    // (As in C, the result of osigfopen is compared with an unsigned number,
    // so that errors are not detected here.)
    if (wfdbx::osigfopen(&si, nosig) as u32) < nosig || wfdbx::setsampfreq(freq) < 0 {
        cstd::exit(2);
    }

    // skip any unwanted samples at the beginning
    let mut t: i64 = 0;
    while t < t0 {
        line = read_line(&mut ifile, rsep);
        t += 1;
    }

    // pick up base time if it's there ("[hh:mm:ss.sss dd/mm/yyyy]", at
    // most BTIMELEN characters between the brackets)
    const BTIMELEN: usize = 23;
    if zflag != 0 {
        if let Some(l) = &line {
            if l.first() == Some(&b'[') {
                let b = &l[1..];
                let btime = b[..b.len().min(BTIMELEN)].to_vec();
                wfdbx::setbasetime(&btime);
            } else if !l.is_empty() && l.get(1) == Some(&b'[') {
                let b = &l[2..];
                let btime = b[..b.len().min(BTIMELEN)].to_vec();
                wfdbx::setbasetime(&btime);
            }
        }
    }

    // read and copy samples
    while let Some(l) = &line {
        if t1 != 0 {
            let ok = t < t1;
            t += 1;
            if !ok {
                break;
            }
        }
        let ta = parseline(l, &delim);

        for k in 0..n {
            let tok: &[u8] = ta.get(fv[k] as usize).map(|v| &v[..]).unwrap_or(b"");
            let mut v = 0.0;
            if scan_f64(tok, &mut v) == 1 {
                v *= scalef[k];
                if dflag {
                    v += dither(&mut rng);
                }
                vout[k] = if v >= 0.0 { d2i(v + 0.5) } else { d2i(v - 0.5) };
            } else {
                vout[k] = WFDB_INVALID_SAMPLE;
            }
        }
        if wfdbx::putvec(&vout) < 0 {
            break;
        }

        line = read_line(&mut ifile, rsep);
        if xflag {
            if let Some(l) = &line {
                if l.starts_with(b"</samplevectors>") {
                    line = read_line(&mut ifile, rsep);
                    if let Some(l) = &line {
                        if l != b"</wfdbsampleset>" {
                            ceprintf!(b"%s: (warning) unexpected EOF in XML input\n", pname);
                        }
                    }
                    break;
                }
            }
        }
    }

    // write the header
    wfdbx::setsampfreq(freq);
    if let Some(r) = &record {
        wfdbx::newheader(r);
    }
    wfdbx::wfdbquit();
    drop(ifile);
    cstd::exit(0);
}
