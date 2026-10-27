//! Checking a record: [`check_record`] reads a record's header, signal
//! files and annotation files with the library's functions, and reports
//! every problem it finds, each with a [`Severity`]:
//!
//! | Severity | Meaning |
//! |---|---|
//! | `error` | the record is damaged or does not follow the WFDB format: programs will read wrong data or fail |
//! | `warning` | the record can be read, but something is missing or unusual, and may give wrong results |
//! | `info` | a fact worth knowing, such as invalid (missing) samples |
//!
//! ```
//! // The sample record 100s, the first minute of record 100 of the MIT-BIH
//! // Arrhythmia Database, included with WFDB-x in tests/data:
//! # wfdbx::wfdbx_set_input_dir("../tests/data");
//! # /*
//! wfdbx::wfdbx_set_input_dir("tests/data"); // from the repository root
//! # */
//! let report = wfdbx::check_record("100s", &["atr"])?;
//! println!("{report}"); // one line per problem, or "no problems found"
//! assert!(report.ok); // no error
//! # Ok::<(), wfdbx::record::Error>(())
//! ```
//!
//! It checks for problems similar to those found by Benjamin Moody's
//! [wfdbcheck](https://github.com/bemoody/wfdbcheck).
//
// check_record is specified in the same way for the seven languages (the
// messages, their order and the formatting of numbers are identical); the
// Python implementation (python/src/wfdbx/check.py) is the reference. The
// checks were designed for WFDB-x; no code or text of wfdbcheck was used. The
// header file's text is read only for the checks of its lines and of the
// record name.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It has no counterpart in the original package.
//
// Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

use std::collections::HashSet;
use std::fmt;

use crate::cformat;
use crate::cstd;
use crate::record::{Error, ReadOptions};
use crate::types::*;
use crate::wfdb::{with_default, Wfdb, NULL};
use crate::wfdbio::{in_header_dir, is_absolute_path, is_url, wfdbx_dirname};
use crate::ACMAX;

const INT32_MAX: i64 = 2147483647;
/// Frames read at a time.
const CHUNK_SAMPLES: usize = 1 << 20;

/// The severity of an [`Issue`].
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Severity {
    /// The record is damaged or does not follow the WFDB format: programs
    /// will read wrong data or fail.
    Error,
    /// The record can be read, but something is missing or unusual, and
    /// may give wrong results.
    Warning,
    /// A fact worth knowing, such as invalid (missing) samples.
    Info,
}

impl Severity {
    /// `"error"`, `"warning"` or `"info"`.
    pub fn as_str(self) -> &'static str {
        match self {
            Severity::Error => "error",
            Severity::Warning => "warning",
            Severity::Info => "info",
        }
    }
}

impl fmt::Display for Severity {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// A problem found by [`check_record`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Issue {
    /// Error, warning or info.
    pub severity: Severity,
    /// A stable identifier, such as `"checksum"` or `"gain_missing"`.
    pub code: &'static str,
    /// Where the problem is: `""` (the record), `"signal N"`,
    /// `"segment SEG"`, `"segment SEG, signal N"` or `"annotator ANN"`.
    pub r#where: String,
    /// The description of the problem.
    pub message: String,
}

impl fmt::Display for Issue {
    /// `SEVERITY: WHERE: MESSAGE` (without `WHERE: ` for the record
    /// itself).
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.r#where.is_empty() {
            write!(f, "{}: {}", self.severity, self.message)
        } else {
            write!(f, "{}: {}: {}", self.severity, self.r#where, self.message)
        }
    }
}

/// The result of [`check_record`].
///
/// `Display` gives the text form: one line per issue,
/// `SEVERITY: WHERE: MESSAGE` (without `WHERE: ` for the record itself), or
/// `no problems found`; [`CheckReport::lines`] gives the lines.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CheckReport {
    /// The record name, as given.
    pub record: Vec<u8>,
    /// `true` if no issue has the severity [`Severity::Error`].
    pub ok: bool,
    /// The problems, in the order of the checks.
    pub issues: Vec<Issue>,
}

impl CheckReport {
    /// The text form of the report, as a list of lines.
    pub fn lines(&self) -> Vec<String> {
        if self.issues.is_empty() {
            return vec!["no problems found".to_string()];
        }
        self.issues.iter().map(Issue::to_string).collect()
    }
}

impl fmt::Display for CheckReport {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.lines().join("\n"))
    }
}

// ---------------------------------------------------------------------------
// Text of the messages

fn lossy(b: &[u8]) -> String {
    String::from_utf8_lossy(b).into_owned()
}

/// A name quoted for a message: in double quotes, with each byte below 32
/// or above 126 shown as `\xHH` (lowercase hex).
fn q(name: Option<&[u8]>) -> String {
    let mut out = String::from("\"");
    for &c in name.unwrap_or(b"") {
        if !(32..=126).contains(&c) {
            out.push_str(&format!("\\x{c:02x}"));
        } else {
            out.push(c as char);
        }
    }
    out.push('"');
    out
}

/// "1 frame", "2 frames".
fn n(k: i64, word: &str) -> String {
    format!("{k} {word}{}", if k == 1 { "" } else { "s" })
}

/// A message about k items: "1 NOUN VERB WHAT: X" or "K NOUNs VERB WHAT;
/// the first is X".
fn count(k: i64, noun: &str, verb_one: &str, verb_many: &str, what: &str, x: &str) -> String {
    if k == 1 {
        format!("1 {noun} {verb_one} {what}: {x}")
    } else {
        format!("{k} {noun}s {verb_many} {what}; the first is {x}")
    }
}

/// `x` with C's `%g`.
fn g(x: f64) -> String {
    lossy(&cformat!(b"%g", x))
}

/// The low 16 bits of `x`, as a signed value.
fn int16(x: i64) -> i64 {
    let x = x & 0xFFFF;
    if x & 0x8000 != 0 {
        x - 0x10000
    } else {
        x
    }
}

fn has_control(s: &[u8]) -> bool {
    s.iter().any(|&c| c < 32 || c == 127)
}

/// True if `s` is only a number: an optional sign, digits with at most one
/// '.', and at least one digit.
fn is_number(s: &[u8]) -> bool {
    let s = match s.first() {
        Some(b'+' | b'-') => &s[1..],
        _ => s,
    };
    if s.iter().filter(|&&c| c == b'.').count() > 1 {
        return false;
    }
    let mut digits = s.iter().filter(|&&c| c != b'.').peekable();
    digits.peek().is_some() && digits.all(u8::is_ascii_digit)
}

/// "segment s1" + "signal 0" -> "segment s1, signal 0".
fn at(prefix: &str, sub: &str) -> String {
    if !prefix.is_empty() && !sub.is_empty() {
        format!("{prefix}, {sub}")
    } else if prefix.is_empty() {
        sub.to_string()
    } else {
        prefix.to_string()
    }
}

/// The bits that a storage format can store (formats 8 and 0: no limit).
fn capacity(fmt: i32) -> Option<i32> {
    match fmt {
        80 | 508 => Some(8),
        310 | 311 => Some(10),
        212 => Some(12),
        16 | 61 | 160 | 516 => Some(16),
        24 | 524 => Some(24),
        32 => Some(32),
        _ => None,
    }
}

fn file_char(c: u8) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, b'_' | b'-' | b'.' | b'/')
}

fn adc_range(info: &Siginfo) -> (i64, i64) {
    let half = 1i64 << (info.adcres - 1);
    let z = i64::from(info.adczero);
    (z - half, z + half - 1)
}

#[derive(Default)]
struct Report {
    issues: Vec<Issue>,
}

impl Report {
    fn add(&mut self, severity: Severity, code: &'static str, r#where: &str, message: String) {
        self.issues.push(Issue {
            severity,
            code,
            r#where: r#where.to_string(),
            message,
        });
    }
}

use Severity::{Error as E, Info as I, Warning as W};

// ---------------------------------------------------------------------------
// The header file

/// The header file that the library reads for a record: its bytes, the
/// record name that its file name gives (without directory and ".hea"), and
/// its path.
struct HeaderText {
    text: Vec<u8>,
    base: Vec<u8>,
    path: Vec<u8>,
}

/// The fields of a header line, separated by spaces, tabs and CRs.
fn fields(line: &[u8]) -> Vec<&[u8]> {
    line.split(|&c| c == b' ' || c == b'\t' || c == b'\r')
        .filter(|f| !f.is_empty())
        .collect()
}

/// The fields of the record line of a header (the first line whose first
/// field does not begin with '#').
fn record_line(text: &[u8]) -> Option<Vec<&[u8]>> {
    text.split(|&c| c == b'\n')
        .map(fields)
        .find(|f| !f.is_empty() && f[0].first() != Some(&b'#'))
}

/// The length (number of samples) on the record line: 0 if not given.
fn header_length(text: &[u8]) -> i64 {
    let Some(f) = record_line(text) else {
        return 0;
    };
    if f.len() < 4 {
        return 0;
    }
    f[3].iter()
        .take_while(|c| c.is_ascii_digit())
        .fold(0i64, |v, &c| {
            v.saturating_mul(10).saturating_add(i64::from(c - b'0'))
        })
}

/// Checks 1.5-1.7: the lines of the header file and its record name.
fn check_text(hdr: &HeaderText, r#where: &str, rep: &mut Report) {
    let mut lines: Vec<&[u8]> = hdr.text.split(|&c| c == b'\n').collect();
    if lines.last() == Some(&&b""[..]) {
        lines.pop(); // (after the final newline)
    }
    for (k, line) in lines.iter().enumerate() {
        let line = line.strip_suffix(b"\r").unwrap_or(line);
        if line.len() > 255 {
            rep.add(
                E,
                "header_line_long",
                r#where,
                format!("line {} of the header is longer than 255 characters", k + 1),
            );
        }
    }
    if let Some(k) = lines.iter().position(|l| l.iter().any(|&c| c > 127)) {
        rep.add(
            W,
            "header_not_ascii",
            r#where,
            format!("line {} of the header contains non-ASCII characters", k + 1),
        );
    }
    if let Some(f) = record_line(&hdr.text) {
        let f0 = f[0];
        // (up to the first '/' after the first character)
        let x = match f0[1..].iter().position(|&c| c == b'/') {
            Some(k) => &f0[..k + 1],
            None => f0,
        };
        if x != hdr.base.as_slice() {
            rep.add(
                W,
                "header_name",
                r#where,
                format!(
                    "the header names the record {}, but its file name is {}",
                    q(Some(x)),
                    q(Some(&hdr.base))
                ),
            );
        }
    }
}

/// The header of a record, as read by the library.
struct HeaderInfo {
    nsig: i32,
    si: Vec<Siginfo>,
    fs: f64,
    nsamples: i64,
    segs: Vec<Seginfo>,
}

impl Wfdb {
    /// The header file that the library reads for record `name`; `None`
    /// if there is none (no such file, or a record read from another
    /// format, such as EDF).
    fn check_header_text(&mut self, name: &[u8]) -> Option<HeaderText> {
        let mut q = name.len().saturating_sub(1);
        while q > 0 && !b"./:\\".contains(&name[q]) {
            q -= 1;
        }
        let f = if name.get(q) == Some(&b'.') {
            if &name[q + 1..] != b"hea" {
                return None; // (EDF: no WFDB header)
            }
            self.wfdb_open(NULL, name, WFDB_READ)
        } else {
            self.wfdb_open("hea", name, WFDB_READ)
        };
        let mut f = f?;
        let path = match self.wfdb_filename() {
            p if !p.is_empty() => p.to_vec(),
            _ => name.to_vec(),
        };
        let text = f.read_to_end();
        let _ = f.close();
        let mut base = &path[wfdbx_dirname(&path).len()..];
        if let Some(b) = base.strip_suffix(b".hea") {
            base = b;
        } else if let Some(b) = base.strip_prefix(b"hea.") {
            base = b;
        }
        Some(HeaderText {
            text,
            base: base.to_vec(),
            path,
        })
    }

    /// Opens the header of record `name` (wfdbquit first); `None` if it
    /// cannot be read.
    fn check_open_header(&mut self, name: &[u8]) -> Option<HeaderInfo> {
        self.wfdbquit();
        let nsig = self.isigopen(name, &mut [], 0);
        if nsig < 0 {
            self.wfdbquit();
            return None;
        }
        let mut si = vec![Siginfo::default(); nsig as usize];
        if nsig > 0 {
            self.isigopen(name, &mut si, -nsig);
        }
        let mut segs = None;
        self.getseginfo(&mut segs);
        let segs = segs.unwrap_or_default();
        let nsamples = self.wfdbx_record_nsamples(!segs.is_empty());
        let fs = self.sampfreq(NULL);
        self.wfdbquit();
        Some(HeaderInfo {
            nsig,
            si,
            fs,
            nsamples,
            segs,
        })
    }

    // -----------------------------------------------------------------------
    // Signal data (section 3)

    /// Checks 3.1-3.9: reads the signals of the record opened as `name`
    /// (header signals `si`, header length `ns`).
    fn check_data(
        &mut self,
        name: &[u8],
        si: &[Siginfo],
        prefix: &str,
        ns: i64,
        length_missing: bool,
        rep: &mut Report,
    ) {
        let nsig = si.len();
        if nsig == 0 {
            return;
        }
        if si
            .iter()
            .any(|s| s.fname.as_deref() == Some(b"-") && s.fmt != 0)
        {
            return; // (the standard input: not read)
        }
        self.wfdbquit();
        let mut opened = vec![Siginfo::default(); nsig];
        let k = self.isigopen(name, &mut opened, nsig as i32);
        if k < nsig as i32 {
            let have: Vec<&Option<Vec<u8>>> = opened[..k.max(0) as usize]
                .iter()
                .map(|s| &s.fname)
                .collect();
            let mut reported: Vec<&Option<Vec<u8>>> = Vec::new();
            for s in si {
                if s.fmt != 0 && !have.contains(&&s.fname) && !reported.contains(&&s.fname) {
                    reported.push(&s.fname);
                    rep.add(
                        E,
                        "file_unreadable",
                        prefix,
                        format!("the signal file {} cannot be read", q(s.fname.as_deref())),
                    );
                }
            }
            if reported.is_empty() {
                rep.add(
                    E,
                    "file_unreadable",
                    prefix,
                    format!(
                        "the signal file {} cannot be read",
                        q(si[0].fname.as_deref())
                    ),
                );
            }
            self.wfdbquit();
            return;
        }
        for (grp, size) in self.wfdbx_group_file_sizes().into_iter().enumerate() {
            if file_size(size).is_some_and(|z| z > INT32_MAX as u64) {
                let fname = si
                    .iter()
                    .find(|s| s.group as usize == grp)
                    .and_then(|s| s.fname.as_deref());
                rep.add(
                    W,
                    "file_large",
                    prefix,
                    format!(
                        "the signal file {} has more than 2147483647 bytes, which 32-bit applications cannot handle",
                        q(fname)
                    ),
                );
            }
        }
        self.setgvmode(WFDB_LOWRES);
        let inv = WFDB_INVALID_SAMPLE;
        let ranges: Vec<Option<(i64, i64)>> = si
            .iter()
            .map(|s| ((1..=32).contains(&s.adcres) && s.fmt != 0).then(|| adc_range(s)))
            .collect();
        let mut n_out = vec![0i64; nsig];
        let mut first_out: Vec<Option<(i64, i32)>> = vec![None; nsig];
        let mut n_inv = vec![0i64; nsig];
        let mut first_inv: Vec<Option<i64>> = vec![None; nsig];
        let rows = (CHUNK_SAMPLES / nsig).max(1024);
        let mut buf = vec![0i32; rows * nsig];
        let mut m: i64 = 0; // frames read
        let mut stat;
        let mut residual: Option<Vec<i32>> = None; // after ns frames
                                                   // (the checksums: not for EDF, nor for a record with skewed signals,
                                                   // whose samples the library reads ahead)
        let checked =
            ns > 0 && !self.wfdbx_is_edf() && (0..nsig).all(|s| self.wfdbgetskew(s as u32) == 0);
        loop {
            let mut want = rows as i64;
            if checked && residual.is_none() {
                want = want.min(ns - m);
            }
            let (k, st) = self.getvecs_status(&mut buf[..want as usize * nsig], want);
            stat = st;
            let mut got = k.max(0);
            if stat == -4 {
                got += 1; // (a checksum error: the frame was read completely)
            }
            for (j, frame) in buf[..got as usize * nsig].chunks_exact(nsig).enumerate() {
                for (s, &v) in frame.iter().enumerate() {
                    if si[s].fmt == 0 {
                        continue; // (a null signal: no data)
                    }
                    if v == inv {
                        n_inv[s] += 1;
                        first_inv[s].get_or_insert(m + j as i64);
                    } else if let Some((lo, hi)) = ranges[s] {
                        let x = i64::from(v);
                        if x < lo || x > hi {
                            n_out[s] += 1;
                            first_out[s].get_or_insert((m + j as i64, v));
                        }
                    }
                }
            }
            m += got;
            if checked && residual.is_none() && m >= ns {
                residual = Some(self.wfdbx_cksum_residuals());
            }
            if stat == -4 {
                continue;
            }
            if got < want {
                break;
            }
        }
        // (with skewed signals, getvec returns the frames of the files less
        // the largest skew)
        let skew = (0..nsig)
            .map(|s| self.wfdbgetskew(s as u32))
            .max()
            .unwrap_or(0);
        self.wfdbquit();
        if skew != 0 && m > 0 {
            m += i64::from(skew);
        }
        for s in 0..nsig {
            let r#where = at(prefix, &format!("signal {s}"));
            if let (Some((j, v)), Some((lo, hi))) = (first_out[s], ranges[s]) {
                rep.add(
                    E,
                    "sample_range",
                    &r#where,
                    count(
                        n_out[s],
                        "sample",
                        "is",
                        "are",
                        &format!("outside the ADC range ({lo} to {hi})"),
                        &format!("sample {j} (value {v})"),
                    ),
                );
            }
            if let Some(j) = first_inv[s] {
                rep.add(
                    I,
                    "invalid_samples",
                    &r#where,
                    count(
                        n_inv[s],
                        "sample",
                        "is",
                        "are",
                        "invalid (missing data)",
                        &format!("sample {j}"),
                    ),
                );
            }
        }
        if let Some(res) = residual {
            for (s, info) in si.iter().enumerate() {
                let r = i64::from(res.get(s).copied().unwrap_or(0));
                if info.nsamp > 0 && info.fmt != 0 && r & 0xFFFF != 0 {
                    rep.add(
                        E,
                        "checksum",
                        &at(prefix, &format!("signal {s}")),
                        format!(
                            "the checksum does not match: the header gives {}, the samples sum to {}",
                            int16(i64::from(info.cksum)),
                            int16(i64::from(info.cksum) - r)
                        ),
                    );
                }
            }
        }
        let end_ok = stat == -1 || stat >= 0;
        let short = ns > 0 && m < ns && (stat == -1 || stat == -3);
        if short {
            rep.add(
                E,
                "length_short",
                prefix,
                format!(
                    "the signal files end after {}, before the {ns} given in the header",
                    n(m, "frame")
                ),
            );
        }
        if ns > 0 && m > ns {
            rep.add(
                W,
                "length_long",
                prefix,
                format!(
                    "the signal files hold {}, more than the {ns} given in the header",
                    n(m, "frame")
                ),
            );
        }
        if length_missing && end_ok {
            rep.add(
                I,
                "length_unspecified_frames",
                prefix,
                format!("the signal files hold {}", n(m, "frame")),
            );
        }
        if !end_ok && !short {
            rep.add(
                E,
                "read_error",
                prefix,
                format!(
                    "the signal data cannot be read after {} (getvec status {stat})",
                    n(m, "frame")
                ),
            );
        }
    }

    // -----------------------------------------------------------------------
    // A record (sections 1-4)

    /// Sections 1-4. Returns the record length in samples for the
    /// annotation checks (0 if unknown), or `None` if the header cannot be
    /// read.
    fn check_record_signals(&mut self, record: &[u8], rep: &mut Report) -> Option<i64> {
        let hdr = self.check_header_text(record);
        let Some(info) = self.check_open_header(record) else {
            rep.add(
                E,
                "header_unreadable",
                "",
                "the header cannot be read".into(),
            );
            if let Some(h) = &hdr {
                check_text(h, "", rep);
            }
            return None;
        };
        let HeaderInfo {
            nsig,
            si,
            fs,
            nsamples,
            segs,
        } = info;
        if nsig == 0 {
            rep.add(I, "no_signals", "", "the record has no signals".into());
        }
        if fs == 0.0 {
            rep.add(
                W,
                "fs_missing",
                "",
                "the sampling frequency is not specified".into(),
            );
        }
        let given = if segs.is_empty() {
            nsamples
        } else {
            hdr.as_ref().map_or(nsamples, |h| header_length(&h.text))
        };
        if given == 0 {
            rep.add(
                W,
                "length_missing",
                "",
                "the record length is not specified".into(),
            );
        }
        if let Some(h) = &hdr {
            check_text(h, "", rep);
        }
        if nsamples > INT32_MAX {
            length_large(rep, "");
        }
        if segs.is_empty() {
            if nsig > 0 {
                check_specs(&si, record, "", rep, false);
                self.check_data(record, &si, "", nsamples, nsamples == 0, rep);
            }
            return Some(nsamples);
        }
        // A multi-segment record: the segments, next to the master header
        let hpath = match &hdr {
            Some(h) => h.path.clone(),
            None => self.wfdbfile("hea", record).unwrap_or_default(),
        };
        let mut d = wfdbx_dirname(&hpath);
        if d.is_empty() || (!is_url(&d) && !is_absolute_path(&d)) {
            let mut abs = std::env::current_dir()
                .map(|p| cstd::os_to_bytes(p.into_os_string()))
                .unwrap_or_default();
            abs.push(std::path::MAIN_SEPARATOR as u8);
            abs.extend_from_slice(&d);
            d = abs;
        }
        let variable = segs[0].nsamp == 0;
        let mut layout_descs: Vec<Option<Vec<u8>>> = Vec::new();
        let mut done: HashSet<Vec<u8>> = HashSet::new();
        for (k, seg) in segs.iter().enumerate() {
            let sname = cstd::cstr(&seg.recname);
            if sname == b"~" || !done.insert(sname.to_vec()) {
                continue;
            }
            let prefix = format!("segment {}", lossy(sname));
            let is_layout = variable && k == 0;
            if !in_header_dir(sname) {
                rep.add(
                    E,
                    "segment_unreadable",
                    &prefix,
                    "the segment cannot be read".into(),
                );
                continue;
            }
            let mut path = d.clone();
            path.extend_from_slice(sname);
            let seg_hdr = self.check_header_text(&path);
            let sinfo = self.check_open_header(&path);
            let Some(sinfo) = sinfo else {
                rep.add(
                    E,
                    "segment_unreadable",
                    &prefix,
                    "the segment cannot be read".into(),
                );
                continue;
            };
            if !sinfo.segs.is_empty() {
                rep.add(
                    E,
                    "nested",
                    &prefix,
                    "the segment is itself a multi-segment record".into(),
                );
                continue;
            }
            if sinfo.fs > 0.0 && fs > 0.0 && sinfo.fs != fs {
                rep.add(
                    E,
                    "segment_fs",
                    &prefix,
                    format!(
                        "the segment's sampling frequency ({}) differs from the record's ({})",
                        g(sinfo.fs),
                        g(fs)
                    ),
                );
            }
            if sinfo.nsig == 0 {
                rep.add(I, "no_signals", &prefix, "the record has no signals".into());
            }
            if let Some(h) = &seg_hdr {
                check_text(h, &prefix, rep);
            }
            if sinfo.nsamples > INT32_MAX {
                length_large(rep, &prefix);
            }
            if sinfo.nsig > 0 {
                check_specs(&sinfo.si, &path, &prefix, rep, !is_layout);
            }
            if is_layout {
                layout_descs = sinfo.si.iter().map(|s| s.desc.clone()).collect();
                continue;
            }
            if variable {
                for (s, x) in sinfo.si.iter().enumerate() {
                    if x.fmt != 0 && !layout_descs.contains(&x.desc) {
                        rep.add(
                            E,
                            "layout_missing_signal",
                            &at(&prefix, &format!("signal {s}")),
                            format!("the signal {} is not in the layout", q(x.desc.as_deref())),
                        );
                    }
                }
            } else {
                check_layout(&sinfo.si, &si, &prefix, rep);
            }
            if sinfo.nsig > 0 {
                self.check_data(&path, &sinfo.si, &prefix, sinfo.nsamples, false, rep);
            }
        }
        let total: i64 = segs.iter().map(|s| s.nsamp).sum();
        if given > 0 && total != given {
            rep.add(
                W,
                "segment_lengths",
                "",
                format!(
                    "the segment lengths add up to {}, but the master header gives {given}",
                    n(total, "sample")
                ),
            );
        }
        Some(total) // (the end of the signals)
    }

    // -----------------------------------------------------------------------
    // Annotators (section 5)

    fn check_annotator(&mut self, record: &[u8], an: &[u8], length: Option<i64>, rep: &mut Report) {
        let r#where = format!("annotator {}", lossy(an));
        if !an.is_empty() && an.iter().all(u8::is_ascii_digit) {
            rep.add(
                W,
                "annotator_name",
                &r#where,
                "the annotator name consists only of digits".into(),
            );
        }
        self.wfdbquit();
        if length.is_some() {
            self.sampfreq(record); // (the record's frequency, for getann)
        }
        let saved = self.wfdbx_save_ann_defs();
        let ai = [Anninfo {
            name: an.to_vec(),
            stat: WFDB_READ,
        }];
        if self.annopen(record, &ai, 1) < 0 {
            self.wfdbquit();
            self.wfdbx_restore_ann_defs(saved);
            rep.add(
                E,
                "annotations_unreadable",
                &r#where,
                "the annotation file cannot be read".into(),
            );
            return;
        }
        let length = length.unwrap_or(0);
        let mut a = Annotation::default();
        let mut nread: i64 = 0;
        let mut prev: Option<i64> = None;
        let (mut n_order, mut order) = (0i64, None);
        let (mut n_code, mut code) = (0i64, None);
        let (mut n_null, mut null) = (0i64, None);
        let (mut n_undef, mut undef) = (0i64, None);
        let (mut n_after, mut after) = (0i64, None);
        let stat = loop {
            let stat = self.getann(0, &mut a);
            if stat != 0 {
                break stat;
            }
            nread += 1;
            let (t, c) = (a.time, i32::from(a.anntyp));
            if let Some(p) = prev.filter(|&p| t < p) {
                n_order += 1;
                order.get_or_insert((t, p));
            }
            prev = Some(t);
            if c > ACMAX {
                n_code += 1;
                code.get_or_insert((t, c));
            } else if c == 0 {
                n_null += 1;
                null.get_or_insert(t);
            } else if self.annstr(c) == cformat!(b"[%d]", c) {
                n_undef += 1;
                undef.get_or_insert((t, c));
            }
            if length > 0 && t >= length {
                n_after += 1;
                after.get_or_insert(t);
            }
        };
        self.wfdbquit();
        self.wfdbx_restore_ann_defs(saved);
        if stat != -1 {
            rep.add(
                E,
                "annotations_truncated",
                &r#where,
                format!(
                    "the annotation file ends unexpectedly after {}",
                    n(nread, "annotation")
                ),
            );
        }
        if let Some((s, p)) = order {
            let x = format!("at sample {s}, after sample {p}");
            rep.add(
                E,
                "annotations_order",
                &r#where,
                count(n_order, "annotation", "is", "are", "out of order", &x),
            );
        }
        if let Some((s, c)) = code {
            let x = format!("at sample {s} (code {c})");
            rep.add(
                E,
                "annotation_code",
                &r#where,
                count(n_code, "annotation", "has", "have", "an invalid code", &x),
            );
        }
        if let Some(s) = null {
            let x = format!("at sample {s}");
            rep.add(
                W,
                "annotation_null",
                &r#where,
                count(n_null, "annotation", "has", "have", "code 0 (NOTQRS)", &x),
            );
        }
        if let Some((s, c)) = undef {
            let x = format!("at sample {s} (code {c})");
            let msg = if n_undef == 1 {
                format!("1 annotation uses a code without a mnemonic: {x}")
            } else {
                format!("{n_undef} annotations use codes without a mnemonic; the first is {x}")
            };
            rep.add(W, "annotation_undefined", &r#where, msg);
        }
        if let Some(s) = after {
            let x = format!("at sample {s}");
            rep.add(
                W,
                "annotations_after_end",
                &r#where,
                count(
                    n_after,
                    "annotation",
                    "is",
                    "are",
                    &format!("after the end of the record ({})", n(length, "sample")),
                    &x,
                ),
            );
        }
    }

    // -----------------------------------------------------------------------

    /// Checks a record and its annotation files, using this `Wfdb` value
    /// (see [`check_record`]).
    ///
    /// # Errors
    ///
    /// If `record` is empty.
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn check_record(
        &mut self,
        record: impl AsRef<[u8]>,
        annotators: &[&str],
    ) -> Result<CheckReport, Error> {
        self.check_record_with(record, annotators, &ReadOptions::default())
    }

    /// Checks a record and its annotation files with the `input_dir` and
    /// `network` options of `opt`, using this `Wfdb` value (see
    /// [`check_record_with`]).
    ///
    /// # Errors
    ///
    /// If `record` is empty.
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn check_record_with(
        &mut self,
        record: impl AsRef<[u8]>,
        annotators: &[&str],
        opt: &ReadOptions,
    ) -> Result<CheckReport, Error> {
        let record = record.as_ref();
        if record.is_empty() {
            return Err(Error::new("record must not be empty"));
        }
        let mut rep = Report::default();
        let legacy = self.wfdbx_set_legacy(0);
        let printing = self.wfdbx_set_error_print(false);
        self.with_input(opt, |w| {
            w.wfdbquit();
            let length = w.check_record_signals(record, &mut rep);
            for a in annotators {
                w.check_annotator(record, a.as_bytes(), length, &mut rep);
            }
            w.wfdbquit();
        });
        self.wfdbx_set_error_print(printing);
        self.wfdbx_set_legacy(legacy);
        let ok = !rep.issues.iter().any(|i| i.severity == Severity::Error);
        Ok(CheckReport {
            record: record.to_vec(),
            ok,
            issues: rep.issues,
        })
    }
}

fn length_large(rep: &mut Report, r#where: &str) {
    rep.add(
        I,
        "length_large",
        r#where,
        "the record has more than 2147483647 samples, which 32-bit applications cannot handle"
            .into(),
    );
}

/// The size of a signal file, as found (`size`), or as simulated by a
/// test.
fn file_size(size: Option<u64>) -> Option<u64> {
    #[cfg(test)]
    if let Some(z) = tests::SIZE.with(std::cell::Cell::get) {
        return Some(z);
    }
    size
}

// ---------------------------------------------------------------------------
// Signal specifications (section 2)

/// Checks 2.1-2.13 of the signals `si` of a record opened under the name
/// `opened_as`. `skip_null`: signals of format 0 are not checked (a segment
/// of a multi-segment record).
fn check_specs(si: &[Siginfo], opened_as: &[u8], prefix: &str, rep: &mut Report, skip_null: bool) {
    let mut descs: Vec<&[u8]> = Vec::new(); // of the signals checked
    for (s, info) in si.iter().enumerate() {
        let null = info.fmt == 0;
        if null && skip_null {
            continue;
        }
        let r#where = at(prefix, &format!("signal {s}"));
        let mut dflt = b"record ".to_vec();
        dflt.extend_from_slice(opened_as);
        dflt.extend_from_slice(format!(", signal {s}").as_bytes());
        match info.desc.as_deref() {
            None | Some(b"") => missing_desc(rep, &r#where),
            Some(d) if d == dflt.as_slice() => missing_desc(rep, &r#where),
            Some(d) => {
                descs.push(d);
                if is_number(d) {
                    rep.add(
                        W,
                        "desc_number",
                        &r#where,
                        format!("the description {} is only a number", q(Some(d))),
                    );
                }
                if has_control(d) {
                    rep.add(
                        E,
                        "desc_control",
                        &r#where,
                        format!("the description {} contains control characters", q(Some(d))),
                    );
                }
            }
        }
        if info.fmt == 8 {
            rep.add(
                W,
                "format_difference",
                &r#where,
                "format 8 stores first differences, which cannot follow steep slopes".into(),
            );
        }
        if info.gain == 0.0 {
            rep.add(
                W,
                "gain_missing",
                &r#where,
                "the signal is uncalibrated (no gain is given)".into(),
            );
        } else if info.gain < 0.0 {
            rep.add(
                I,
                "gain_negative",
                &r#where,
                format!("the gain is negative ({})", g(info.gain)),
            );
        }
        let units = info.units.as_deref().unwrap_or(b"");
        if info.gain != 0.0 && units.is_empty() {
            rep.add(
                W,
                "units_missing",
                &r#where,
                "the units are not specified".into(),
            );
        }
        if has_control(units) {
            rep.add(
                E,
                "units_control",
                &r#where,
                format!("the units {} contain control characters", q(Some(units))),
            );
        }
        let b = info.adcres;
        let cap = if null { None } else { capacity(info.fmt) };
        if b == 0 {
            rep.add(
                W,
                "adcres_missing",
                &r#where,
                "the ADC resolution is not specified".into(),
            );
        } else if let Some(cap) = cap {
            if b > cap {
                rep.add(
                    E,
                    "adcres_too_large",
                    &r#where,
                    format!(
                        "the ADC resolution ({b} bits) exceeds what format {} can store ({cap} bits)",
                        info.fmt
                    ),
                );
            } else if b >= 1 {
                let (lo, hi) = adc_range(info);
                let (fmin, fmax) = (-(1i64 << (cap - 1)), (1i64 << (cap - 1)) - 1);
                if lo < fmin || hi > fmax {
                    rep.add(
                        E,
                        "adc_range",
                        &r#where,
                        format!(
                            "the ADC range ({lo} to {hi}) does not fit in format {} ({fmin} to {fmax})",
                            info.fmt
                        ),
                    );
                }
            }
        }
        let fname = info.fname.as_deref().unwrap_or(b"");
        if !null && fname != b"-" && fname != b"~" && !fname.iter().all(|&c| file_char(c)) {
            rep.add(
                W,
                "filename",
                &r#where,
                format!(
                    "the signal file name {} contains characters other than letters, digits, '_', '-' and '.'",
                    q(Some(fname))
                ),
            );
        }
    }
    let mut seen: Vec<(&[u8], usize)> = Vec::new();
    for d in descs {
        match seen.iter_mut().find(|(x, _)| *x == d) {
            Some((_, k)) => *k += 1,
            None => seen.push((d, 1)),
        }
    }
    for (d, k) in seen {
        if k > 1 {
            rep.add(
                W,
                "desc_duplicate",
                prefix,
                format!("{k} signals have the description {}", q(Some(d))),
            );
        }
    }
}

fn missing_desc(rep: &mut Report, r#where: &str) {
    rep.add(
        W,
        "desc_missing",
        r#where,
        "the signal has no description".into(),
    );
}

/// Check 4.6: the signals of a segment of a fixed-layout record match the
/// record's signals.
fn check_layout(ssi: &[Siginfo], si: &[Siginfo], prefix: &str, rep: &mut Report) {
    if ssi.len() != si.len() {
        rep.add(
            E,
            "layout_signals",
            prefix,
            format!(
                "the segment has {}, but the record has {}",
                n(ssi.len() as i64, "signal"),
                si.len()
            ),
        );
    }
    for (s, (a, b)) in ssi.iter().zip(si).enumerate() {
        if a.fmt == 0 {
            continue;
        }
        let r#where = at(prefix, &format!("signal {s}"));
        let fields = [
            ("description", q(a.desc.as_deref()), q(b.desc.as_deref())),
            ("units", q(a.units.as_deref()), q(b.units.as_deref())),
            ("gain", g(a.gain), g(b.gain)),
            ("baseline", a.baseline.to_string(), b.baseline.to_string()),
            ("samples per frame", a.spf.to_string(), b.spf.to_string()),
        ];
        for (field, x, y) in fields {
            if x != y {
                rep.add(
                    E,
                    "layout_mismatch",
                    &r#where,
                    format!(
                        "the signal differs from the record's signal {s} in its {field} ({x}, expected {y})"
                    ),
                );
            }
        }
    }
}

// ---------------------------------------------------------------------------

/// Checks a record and its annotation files, and reports every problem.
///
/// The header, the signal specifications, the signal files (all samples
/// are read) and the annotation files of `annotators` (such as `&["atr"]`;
/// `&[]` for none) are checked. Problems in the record are reported, never
/// returned as errors. `record` is a name in the input directory, or a full
/// path, `~` path or URL (as for [`read_record`](crate::read_record)). Uses
/// the default [`Wfdb`] value of the thread.
///
/// The result is a [`CheckReport`]: `report.ok` is `true` if there is no
/// error, `report.issues` lists the problems ([`Issue`] values, with
/// severity, code, where and message), and `Display` prints one line per
/// problem, such as
///
/// ```text
/// error: signal 1: the checksum does not match: the header gives 12, the samples sum to 13
/// ```
///
/// or `no problems found`. Severities: [`Severity::Error`] (the record is
/// damaged or does not follow the WFDB format), [`Severity::Warning`]
/// (something is missing or unusual, and may give wrong results) and
/// [`Severity::Info`] (a fact worth knowing). The checks run in normal
/// mode, even if legacy mode is on, and the library prints no messages
/// during the call.
///
/// ```
/// // The sample record 100s, the first minute of record 100 of the MIT-BIH
/// // Arrhythmia Database, included with WFDB-x in tests/data:
/// # wfdbx::wfdbx_set_input_dir("../tests/data");
/// # /*
/// wfdbx::wfdbx_set_input_dir("tests/data"); // from the repository root
/// # */
/// let report = wfdbx::check_record("100s", &["atr"])?;
/// println!("{report}");
/// if !report.ok {
///     // ...
/// }
/// # Ok::<(), wfdbx::record::Error>(())
/// ```
///
/// It checks for problems similar to those found by Benjamin Moody's
/// [wfdbcheck](https://github.com/bemoody/wfdbcheck).
///
/// # Errors
///
/// If `record` is empty.
///
/// Part of WFDB-x; not in the original WFDB package.
pub fn check_record(record: impl AsRef<[u8]>, annotators: &[&str]) -> Result<CheckReport, Error> {
    with_default(|w| w.check_record(record, annotators))
}

/// Checks a record and its annotation files, as [`check_record`] does,
/// with the `input_dir` and `network` options of `opt` (for this call
/// only). The other options are not used. Uses the default [`Wfdb`] value
/// of the thread.
///
/// # Errors
///
/// If `record` is empty.
///
/// Part of WFDB-x; not in the original WFDB package.
pub fn check_record_with(
    record: impl AsRef<[u8]>,
    annotators: &[&str],
    opt: &ReadOptions,
) -> Result<CheckReport, Error> {
    with_default(|w| w.check_record_with(record, annotators, opt))
}

#[cfg(test)]
mod tests {
    use super::*;

    thread_local! {
        /// A simulated size for the signal files.
        pub(super) static SIZE: std::cell::Cell<Option<u64>> = const { std::cell::Cell::new(None) };
    }

    #[test]
    fn quoting() {
        assert_eq!(q(Some(b"a\tb\x7f\xe9\"c")), "\"a\\x09b\\x7f\\xe9\"c\"");
        assert_eq!(q(None), "\"\"");
        assert!(is_number(b"12") && is_number(b"-1.5") && is_number(b"+.5"));
        assert!(!is_number(b"1.2.3") && !is_number(b"V5") && !is_number(b"-"));
        assert!(!is_number(b"") && !is_number(b"."));
        assert_eq!(g(200.5), "200.5");
        assert_eq!(g(1e6), "1e+06");
        assert_eq!((int16(65535), int16(32768), int16(5)), (-1, -32768, 5));
    }

    #[test]
    fn header_name() {
        let hdr = |text: &[u8]| HeaderText {
            text: text.to_vec(),
            base: b"/a".to_vec(),
            path: Vec::new(),
        };
        let mut rep = Report::default();
        check_text(&hdr(b"/a/2 1 360\n"), "", &mut rep);
        assert!(rep.issues.is_empty());
        check_text(&hdr(b"# c\nb/2 1 360\n"), "", &mut rep);
        assert_eq!(
            rep.issues[0].message,
            "the header names the record \"b\", but its file name is \"/a\""
        );
    }

    #[test]
    fn file_large() {
        // (a signal file of more than 2^31 - 1 bytes: its size is simulated)
        let dir = std::env::temp_dir().join(format!("wfdbx-rust-check-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let mut w = Wfdb::new();
        w.wfdbquiet();
        let o = crate::record::WriteOptions {
            fmt: 16,
            gains: vec![100.0],
            adcres: vec![16],
            units: vec![Some("mV".into())],
            names: vec!["ECG".into()],
            dir: Some(dir.clone()),
            ..Default::default()
        };
        let x: Vec<i32> = (0..100).collect();
        w.write_record("big", &x, 1, 100.0, &o).unwrap();
        let opt = ReadOptions {
            input_dir: Some(dir.to_string_lossy().into_owned()),
            ..Default::default()
        };
        assert_eq!(
            w.check_record_with("big", &[], &opt).unwrap().lines(),
            ["no problems found"]
        );
        SIZE.with(|s| s.set(Some(1 << 31)));
        let r = w.check_record_with("big", &[], &opt).unwrap();
        SIZE.with(|s| s.set(None));
        assert_eq!(
            r.lines(),
            ["warning: the signal file \"big.dat\" has more than 2147483647 bytes, which 32-bit applications cannot handle"]
        );
        assert!(r.ok);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
