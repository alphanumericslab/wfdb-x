//! Signal I/O (port of `lib/signal.c`): headers (including EDF headers),
//! signal files in every storage format (0, 8, 16, 61, 80, 160, 212, 310,
//! 311, 24, 32, and the FLAC formats 508, 516 and 524), multi-segment and
//! multi-frequency records, header and info files, and conversion of times,
//! dates and amplitudes.
//!
//! The functions are methods of [`Wfdb`] (with free-function versions
//! that use the default instance); they behave as those of the C library,
//! with the same integer types and status codes. Their state is held in
//! [`SigState`], part of [`Wfdb`].
//!
//! Functions that fill a caller's array take a mutable slice: `getvec`
//! writes one sample per signal (`getframe` one frame, that is the sum of
//! the samples per frame of all signals). If the slice is shorter than
//! that, only its length is filled (the other values are discarded).
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Rust translation of lib/signal.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original code, but it is new code, not the original C code.
//
// Changes from the original: no built-in sampling frequency, gain, ADC
// resolution or units (the original assumed 250 Hz, 200 adu/mV, 12 bits or a
// resolution based on the format, and millivolts): a value that the header
// does not give stays unspecified, and the time and amplitude conversions that
// need it, and setifreq, report an error; the signal files and segments named
// in a header are read only from the header's directory (on disk or at its
// URL), never searched for, and a name that leaves that directory is refused;
// an output signal file is never one of the input files of the open record; a
// header written under a path names the record, its signal files and its
// segments relative to its own directory; FLAC signal files are read and
// written with WFDB-x's FLAC codec (flac.rs) instead of libFLAC; additions:
// wfdbx_set_legacy, wfdbx_get_legacy, wfdbx_legacy_args,
// wfdbx_time_needs_freq, getvecs, getvecs_status, and wfdbx_bulk_read,
// wfdbx_bulk_vectors and wfdbx_input_state (for tests); legacy mode
// (wfdbx_set_legacy) restores the original behavior. Each change is marked
// "WFDB-x:" in the code; docs/DIVERGENCES.md gives the reasons.
//
// Original C code: lib/signal.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1989-2013 George B. Moody; revised 2011-2022 by
//   Benjamin Moody, including FLAC support (2020).
// Rust translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

// (A line-by-line port of C: index loops are kept as in the C source.)
#![allow(
    clippy::needless_range_loop,
    clippy::explicit_counter_loop,
    clippy::manual_range_contains
)]

use crate::cstd::{self, d2i, d2l, Strtok, INT_MAX, SEEK_CUR, SEEK_END, SEEK_SET};
use crate::flac;
use crate::types::*;
use crate::wfdb::{with_default, OptBytes, Wfdb};
use crate::wfdbio::{in_header_dir, is_url, path_id, wfdb_striphea, FileId, WfdbFile};
use crate::{cformat, csscanf};

/// `BUFSIZ` of the reference platform (default buffer sizes).
const WFDB_BUFSIZ: i32 = 8192;
/// Size of the `sample()` buffer (a power of 2).
const BUFLN: i64 = 4096;

const SEP: &[u8] = b" \t\n\r";

// ---------------------------------------------------------------------------
// Data structures

#[derive(Clone, Default)]
struct HsData {
    /// Signal information from the header.
    info: Siginfo,
    /// Signal file byte offset to sample 0.
    start: i64,
    /// Intersignal skew (in frames).
    skew: i32,
}

#[derive(Clone, Default)]
struct IsData {
    info: Siginfo,
    /// Most recent sample read.
    samp: i32,
    /// Intersignal skew (in frames).
    skew: i32,
    /// Current high-resolution sample number.
    gvindex: i32,
    /// Counter for updating gvindex.
    gvcount: i32,
}

/// Shared by all signals in an input group (file).
#[derive(Default)]
struct IgData {
    data: i32,
    datb: i32,
    fp: Option<WfdbFile>,
    start: i64,
    /// Block size (WFDB-x: i64, since that of a header can be 2^31: see
    /// isigopen).
    bsize: i64,
    buf: Vec<u8>,
    bp: usize,
    be: usize,
    flac: Option<Box<FlacIn>>,
    count: i32,
    seek: i32,
    initial_skip: i32,
    stat: i32,
}

#[derive(Clone, Default)]
struct OsData {
    info: Siginfo,
    samp: i32,
    skew: i32,
}

struct FlacOut {
    enc: flac::Encoder,
    header_pos: i64,
    pending: Vec<u8>,
}

/// Shared by all signals in an output group (file).
#[derive(Default)]
struct OgData {
    data: i32,
    datb: i32,
    fp: Option<WfdbFile>,
    start: i64,
    bsize: i32,
    buf: Vec<u8>,
    bp: usize,
    be: usize,
    flac: Option<Box<FlacOut>>,
    count: i32,
    seek: i32,
    force_flush: i32,
    nrewind: i32,
}

#[derive(Clone, Default)]
struct SigMapInfo {
    desc: Vec<u8>,
    gain: f64,
    scale: f64,
    offset: f64,
    sample_offset: i32,
    baseline: i32,
    index: i32,
    spf: i32,
}

/// Where `putinfo` writes.
#[derive(Clone, Copy, PartialEq, Eq)]
enum OutInfo {
    None,
    Header,
    File,
}

/// The state of `signal.c` (part of [`Wfdb`]): the open record, input and
/// output signals, header data, time base, info strings, ...
pub struct SigState {
    // Set by readheader
    hsd: Vec<HsData>,
    hheader: Option<WfdbFile>,
    linebuf: Vec<u8>,

    ffreq: f64,
    ifreq: f64,
    sfreq: f64,
    cfreq: f64,
    spfmax: i32,
    btime: i64,
    bdate: i64,
    nsamples: i64,
    bcount: f64,
    prolog_bytes: i64,

    // WFDB-x: files named in a header (see open_header)
    /// Directory of the header read last by readheader (see
    /// `wfdbx_dirname`; `None` if unknown, i.e. for the standard input).
    hdr_dir: Option<Vec<u8>>,
    /// Directory and name of the header of the current multi-segment
    /// record (`msrec_name` is `None` if there is none).
    msrec_dir: Option<Vec<u8>>,
    msrec_name: Option<Vec<u8>>,
    /// True while setmsheader reads the headers of the segments it was
    /// given.
    user_segments: bool,
    /// WFDB-x: true during a high-level read: getvec's checksum message is
    /// recorded but not printed.
    pub(crate) cksum_quiet: bool,
    /// WFDB-x: true if `getvecs` must not use its bulk path (see
    /// `Wfdb::wfdbx_bulk_read`; for tests).
    bulk_off: bool,
    /// WFDB-x: the number of vectors read by the bulk path (for tests).
    bulk_vectors: i64,
    /// WFDB-x: storage of the bulk path: the signal groups, the frames as
    /// read and the frames as getframe gives them.
    bulk_groups: Vec<BulkGroup>,
    bulk_in: Vec<i32>,
    bulk_fr: Vec<i32>,
    /// (and the raw samples of a tile of frames)
    bulk_raw: Vec<i32>,

    // Multi-segment records
    segments: i32,
    in_msrec: i32,
    msbtime: i64,
    msbdate: i64,
    msnsamples: i64,
    segarray: Vec<Seginfo>,
    have_segarray: bool,
    segp: i32,
    segend: i32,

    // Open input signals
    isd: Vec<IsData>,
    igd: Vec<IgData>,
    nisig: u32,
    nigroup: u32,
    pub(crate) ispfmax: u32,
    tvector: Vec<i32>,
    uvector: Vec<i32>,
    vvector: Vec<i32>,
    tuvlen: i32,
    istime: i64,
    ibsize: i32,
    skewmax: u32,
    dsbuf: Vec<i32>,
    have_dsbuf: bool,
    dsbi: i32,
    dsblen: u32,
    framelen: u32,
    /// WFDB-x: is there a signal group whose frames hold no samples (an
    /// EDF file can give 0 samples per data record)? It is at the end of
    /// its data at once.
    empty_group: bool,
    gvmode: i32,
    gvc: i32,
    isedf: i32,
    sbuf: Vec<i32>,
    have_sbuf: bool,
    sample_vflag: i32,

    // Output signals
    osd: Vec<OsData>,
    ogd: Vec<OgData>,
    nosig: u32,
    nogroup: u32,
    oheader: Option<WfdbFile>,
    outinfo_file: Option<WfdbFile>,
    outinfo: OutInfo,
    ostime: i64,
    obsize: i32,

    // Info strings
    pinfo: Vec<Vec<u8>>,
    have_pinfo: bool,
    ninfo: i32,
    info_i: i32,

    // Variable-layout multi-segment records
    need_sigmap: i32,
    nvsig: i32,
    tspf: i32,
    vspfmax: i32,
    vsd: Vec<IsData>,
    ovec: Vec<i32>,
    smi: Vec<SigMapInfo>,

    // getvec resampling (setifreq)
    mticks: i64,
    nticks: i64,
    mnticks: i64,
    rgvstat: i32,
    rgvtime: i64,
    gvtime: i64,
    gv0: Vec<i32>,
    gv1: Vec<i32>,
    rgetvec_stat: i32,

    // Time and date strings
    date_string: Vec<u8>,
    pdays: i64,

    // sample()
    sample_tt: i64,

    // WFDB-x: legacy mode (see `Wfdb::wfdbx_set_legacy`)
    legacy: bool,
}

impl Default for SigState {
    fn default() -> Self {
        SigState {
            hsd: Vec::new(),
            hheader: None,
            linebuf: Vec::new(),
            ffreq: 0.0,
            ifreq: 0.0,
            sfreq: 0.0,
            cfreq: 0.0,
            spfmax: 0,
            btime: 0,
            bdate: 0,
            nsamples: 0,
            bcount: 0.0,
            prolog_bytes: 0,
            hdr_dir: None,
            msrec_dir: None,
            msrec_name: None,
            user_segments: false,
            cksum_quiet: false,
            bulk_off: false,
            bulk_vectors: 0,
            bulk_groups: Vec::new(),
            bulk_in: Vec::new(),
            bulk_fr: Vec::new(),
            bulk_raw: Vec::new(),
            segments: 0,
            in_msrec: 0,
            msbtime: 0,
            msbdate: 0,
            msnsamples: 0,
            segarray: Vec::new(),
            have_segarray: false,
            segp: -1,
            segend: -1,
            isd: Vec::new(),
            igd: Vec::new(),
            nisig: 0,
            nigroup: 0,
            ispfmax: 0,
            tvector: Vec::new(),
            uvector: Vec::new(),
            vvector: Vec::new(),
            tuvlen: 0,
            istime: 0,
            ibsize: 0,
            skewmax: 0,
            dsbuf: Vec::new(),
            have_dsbuf: false,
            dsbi: 0,
            dsblen: 0,
            framelen: 0,
            empty_group: false,
            gvmode: DEFWFDBGVMODE,
            gvc: 0,
            isedf: 0,
            sbuf: Vec::new(),
            have_sbuf: false,
            sample_vflag: 0,
            osd: Vec::new(),
            ogd: Vec::new(),
            nosig: 0,
            nogroup: 0,
            oheader: None,
            outinfo_file: None,
            outinfo: OutInfo::None,
            ostime: 0,
            obsize: 0,
            pinfo: Vec::new(),
            have_pinfo: false,
            ninfo: 0,
            info_i: 0,
            need_sigmap: 0,
            nvsig: 0,
            tspf: 0,
            vspfmax: 0,
            vsd: Vec::new(),
            ovec: Vec::new(),
            smi: Vec::new(),
            mticks: 0,
            nticks: 0,
            mnticks: 0,
            rgvstat: 0,
            rgvtime: 0,
            gvtime: 0,
            gv0: Vec::new(),
            gv1: Vec::new(),
            rgetvec_stat: 0,
            date_string: Vec::new(),
            pdays: -1,
            sample_tt: 0,
            legacy: false,
        }
    }
}

// ---------------------------------------------------------------------------
// Helpers

fn isfmt(f: i32) -> bool {
    WFDB_FMT_LIST.contains(&f)
}

/// FLAC-compressed signal formats are numbered from `FLAC_FMT_BASE` to
/// `FLAC_FMT_MAX`; the bits per sample are `fmt - FLAC_FMT_BASE` (formats
/// 508, 516 and 524 are defined).
const FLAC_FMT_BASE: i32 = 500;
const FLAC_FMT_MAX: i32 = 532;

fn isflacfmt(f: i32) -> bool {
    (FLAC_FMT_BASE..=FLAC_FMT_MAX).contains(&f)
}

/// `%s` of a string that may be `NULL` (glibc prints `(null)`).
fn str_or_null(s: &Option<Vec<u8>>) -> &[u8] {
    match s {
        Some(v) => cstd::cstr(v),
        None => b"(null)",
    }
}

/// The C string of an optional string (empty if `NULL`).
fn ostr(s: &Option<Vec<u8>>) -> &[u8] {
    match s {
        Some(v) => cstd::cstr(v),
        None => b"",
    }
}

/// `strtol(s, NULL, 10)`.
fn strtol10(s: &[u8]) -> i64 {
    cstd::strtol(s, 10).0
}

/// `strtod(s, NULL)`.
fn strtod0(s: &[u8]) -> f64 {
    cstd::strtod(s).0
}

/// `strchr(s, c)` on a C string: the index of `c`, if any.
fn strchr(s: &[u8], c: u8) -> Option<usize> {
    cstd::cstr(s).iter().position(|&x| x == c)
}

/// The first `n` bytes of a C string (`strnlen`).
fn strn(s: &[u8], n: usize) -> Vec<u8> {
    let s = cstd::cstr(s);
    s[..s.len().min(n)].to_vec()
}

/// strtok(s, delim) applied in place: the first token (if any), leaving
/// `s` as strtok leaves it (truncated after the token).
fn strtok_inplace(s: &mut Vec<u8>, delim: &[u8]) -> Option<Vec<u8>> {
    let c = cstd::cstr(s).to_vec();
    let i = c.iter().position(|x| !delim.contains(x))?;
    let j = c[i..]
        .iter()
        .position(|x| delim.contains(x))
        .map_or(c.len(), |k| i + k);
    let tok = c[i..j].to_vec();
    *s = c[..j].to_vec();
    Some(tok)
}

/// The current local time as (year, month 1-12, day, hour, minute, second)
/// (C `localtime(time(NULL))`). The time zone is read from the `TZif` file
/// named by `TZ` (or `/etc/localtime`); UTC is used if there is none.
pub(crate) fn local_time_now() -> (i64, i64, i64, i64, i64, i64) {
    let now = match std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH) {
        Ok(d) => d.as_secs() as i64,
        Err(_) => 0,
    };
    const SECS_PER_DAY: i64 = 24 * 3600;
    let t = now + tz_offset(now);
    let days = t.div_euclid(SECS_PER_DAY);
    let secs = t.rem_euclid(SECS_PER_DAY);
    // Civil date from days since 1970-01-01 (H. Hinnant's algorithm).
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d, secs / 3600, secs % 3600 / 60, secs % 60)
}

/// The UTC offset (seconds) of the local time zone at time `t`, from a
/// `TZif` file (0 if it cannot be determined).
fn tz_offset(t: i64) -> i64 {
    let path: Vec<u8> = match cstd::getenv("TZ") {
        Some(tz) if !tz.is_empty() => {
            let tz = tz.strip_prefix(b":").unwrap_or(&tz).to_vec();
            if tz.first() == Some(&b'/') {
                tz
            } else {
                let mut p = b"/usr/share/zoneinfo/".to_vec();
                p.extend_from_slice(&tz);
                p
            }
        }
        _ => b"/etc/localtime".to_vec(),
    };
    let data = match std::fs::read(cstd::bytes_to_path(&path)) {
        Ok(d) => d,
        Err(_) => return 0,
    };
    tzif_offset(&data, t).unwrap_or(0)
}

/// The UTC offset at time `t` given by the `TZif` data `d` (RFC 8536).
fn tzif_offset(d: &[u8], t: i64) -> Option<i64> {
    // The header: magic (4 bytes), version (1), unused (15), then six
    // 32-bit counts (isutcnt, isstdcnt, leapcnt, timecnt, typecnt, charcnt).
    const HEADER_LEN: usize = 44;
    const COUNTS_POS: usize = 20;
    // Record sizes: a local time type (32-bit UTC offset, isdst byte,
    // abbreviation index byte); a version 1 leap second record (two 32-bit
    // values); a transition (32-bit time and a type index byte).
    const TTINFO_LEN: usize = 6;
    const TTINFO_ISDST: usize = 4;
    const LEAP1_LEN: usize = 8;
    const TRANS1_LEN: usize = 5;
    let be32 = |p: usize| -> Option<i64> {
        Some(i64::from(i32::from_be_bytes(
            d.get(p..p + 4)?.try_into().ok()?,
        )))
    };
    if d.get(0..4)? != b"TZif" {
        return None;
    }
    let version = *d.get(4)?;
    let counts = |base: usize| -> Option<[usize; 6]> {
        let mut c = [0usize; 6];
        for (k, v) in c.iter_mut().enumerate() {
            *v = be32(base + COUNTS_POS + 4 * k)? as usize;
        }
        Some(c)
    };
    let mut base = 0usize;
    let mut c = counts(0)?;
    let mut tsize = 4usize;
    if version >= b'2' {
        // Skip the version 1 data block; use the 64-bit block.
        let [isutc, isstd, leap, timecnt, typecnt, charcnt] = c;
        base = HEADER_LEN
            + timecnt * TRANS1_LEN
            + typecnt * TTINFO_LEN
            + charcnt
            + leap * LEAP1_LEN
            + isstd
            + isutc;
        if d.get(base..base + 4)? != b"TZif" {
            return None;
        }
        c = counts(base)?;
        tsize = 8;
    }
    let [_isutc, _isstd, _leap, timecnt, typecnt, _charcnt] = c;
    let times = base + HEADER_LEN;
    let idx = times + timecnt * tsize;
    let types = idx + timecnt;
    let rd = |p: usize| -> Option<i64> {
        if tsize == 8 {
            Some(i64::from_be_bytes(d.get(p..p + 8)?.try_into().ok()?))
        } else {
            be32(p)
        }
    };
    if typecnt == 0 {
        return None;
    }
    let mut ty = 0usize;
    // The first non-DST type, as the default before the first transition.
    for k in 0..typecnt {
        if *d.get(types + TTINFO_LEN * k + TTINFO_ISDST)? == 0 {
            ty = k;
            break;
        }
    }
    for k in 0..timecnt {
        if rd(times + k * tsize)? <= t {
            ty = *d.get(idx + k)? as usize;
        } else {
            break;
        }
    }
    be32(types + TTINFO_LEN * ty)
}

// ---------------------------------------------------------------------------
// Low-level input routines (signal group as argument)

impl IgData {
    #[cold]
    fn r8_fill(&mut self) -> i32 {
        let n = if self.bsize > 0 {
            self.bsize as usize
        } else {
            self.buf.len()
        };
        let n = n.min(self.buf.len());
        let got = match &mut self.fp {
            Some(f) => f.read(&mut self.buf[..n]),
            None => 0,
        };
        self.stat = got as i32;
        self.bp = 0;
        self.be = got;
        let c = self.buf.first().copied().unwrap_or(0) as i8 as i32;
        self.bp = 1;
        c
    }

    #[inline(always)]
    fn r8(&mut self) -> i32 {
        if self.bp < self.be {
            let c = self.buf[self.bp] as i8 as i32;
            self.bp += 1;
            c
        } else {
            self.r8_fill()
        }
    }

    #[inline(always)]
    fn r16(&mut self) -> i32 {
        if self.bp + 2 <= self.be {
            let b = &self.buf[self.bp..self.bp + 2];
            self.bp += 2;
            return i16::from_le_bytes([b[0], b[1]]) as i32;
        }
        let l = self.r8();
        let h = self.r8();
        (((h << 8) | (l & 0xff)) as u16 as i16) as i32
    }

    #[inline(always)]
    fn r61(&mut self) -> i32 {
        if self.bp + 2 <= self.be {
            let b = &self.buf[self.bp..self.bp + 2];
            self.bp += 2;
            return i16::from_be_bytes([b[0], b[1]]) as i32;
        }
        let h = self.r8();
        let l = self.r8();
        (((l & 0xff) | (h << 8)) as u16 as i16) as i32
    }

    #[inline(always)]
    fn r24(&mut self) -> i32 {
        if self.bp + 3 <= self.be {
            let b = &self.buf[self.bp..self.bp + 3];
            self.bp += 3;
            let v = b[0] as u32 | (b[1] as u32) << 8 | (b[2] as u32) << 16;
            return ((v << 8) as i32) >> 8;
        }
        let lw = self.r16();
        let h = self.r8();
        ((h as u32) << 16 | (lw as u32 & 0xffff)) as i32
    }

    #[inline(always)]
    fn r32(&mut self) -> i32 {
        if self.bp + 4 <= self.be {
            let b = &self.buf[self.bp..self.bp + 4];
            self.bp += 4;
            return i32::from_le_bytes([b[0], b[1], b[2], b[3]]);
        }
        let lw = self.r16();
        let h = self.r16();
        ((h as u32) << 16 | (lw as u32 & 0xffff)) as i32
    }

    #[inline(always)]
    fn r80(&mut self) -> i32 {
        (self.r8() & 0xff) - (1 << 7)
    }

    #[inline(always)]
    fn r160(&mut self) -> i32 {
        (self.r16() & 0xffff) - (1 << 15)
    }

    /// Format 212: 2 12-bit samples bit-packed in 3 bytes.
    #[inline(always)]
    fn r212(&mut self) -> i32 {
        let mut v;
        let c = self.count;
        self.count += 1;
        if c == 0 {
            self.data = self.r16();
            v = self.data;
        } else {
            self.count = 0;
            v = ((self.data >> 4) & 0xf00) | (self.r8() & 0xff);
        }
        if v & 0x800 != 0 {
            v |= !0xfff;
        } else {
            v &= 0xfff;
        }
        v
    }

    /// Format 310: 3 10-bit samples bit-packed in 4 bytes.
    #[inline(always)]
    fn r310(&mut self) -> i32 {
        let c = self.count;
        self.count += 1;
        let mut v = match c {
            0 => {
                self.data = self.r16();
                self.data >> 1
            }
            1 => {
                self.datb = self.r16();
                self.datb >> 1
            }
            _ => {
                self.count = 0;
                ((self.data & 0xf800) >> 11) | ((self.datb & 0xf800) >> 6)
            }
        };
        if v & 0x200 != 0 {
            v |= !0x3ff;
        } else {
            v &= 0x3ff;
        }
        v
    }

    /// Format 311: 3 10-bit samples bit-packed in 4 bytes.
    #[inline(always)]
    fn r311(&mut self) -> i32 {
        let c = self.count;
        self.count += 1;
        let mut v = match c {
            0 => {
                self.data = self.r16();
                self.data
            }
            1 => {
                self.datb = self.r8() & 0xff;
                ((self.data & 0xfc00) >> 10) | ((self.datb & 0xf) << 6)
            }
            _ => {
                self.count = 0;
                self.datb |= self.r8().wrapping_shl(8);
                self.datb >> 4
            }
        };
        if v & 0x200 != 0 {
            v |= !0x3ff;
        } else {
            v &= 0x3ff;
        }
        v
    }
}

// ---------------------------------------------------------------------------
// WFDB-x: bulk input (getvecs)
//
// `Wfdb::bulk_frames` decodes many frames at once, straight from the input
// buffers, and makes the sample vectors of getvec from them, exactly as the
// same number of `getvec` calls would. It is used only where a frame needs
// no special handling (see `bulk_frames`), and only for the complete frames
// already in the buffers: a frame that crosses the end of a buffer (whose
// reading refills the buffer, as C does), the frame at which a checksum is
// verified or a null signal ends, the end of a file and a segment boundary
// go through `getvec`. The buffers are therefore filled, and the files
// read, exactly as by the per-frame path.

/// The packing of a format handled by the bulk path: (bytes, samples) per
/// packed unit; `None` for the other formats.
fn bulk_unit(fmt: i32) -> Option<(usize, usize)> {
    match fmt {
        8 | 80 => Some((1, 1)),
        16 | 61 | 160 => Some((2, 1)),
        24 => Some((3, 1)),
        32 => Some((4, 1)),
        212 => Some((3, 2)),
        310 | 311 => Some((4, 3)),
        _ => None,
    }
}

/// `v` with its low `bits` bits sign-extended.
#[inline(always)]
fn sext(v: u32, bits: u32) -> i32 {
    ((v << (32 - bits)) as i32) >> (32 - bits)
}

/// Decodes the raw samples (as the `rFMT` functions return them; for format
/// 8, the first differences) packed in `b` into `out`, one per value of
/// `out` (`b` holds exactly the bytes of `out.len()` samples).
fn bulk_decode(fmt: i32, b: &[u8], out: &mut [i32]) {
    match fmt {
        8 => {
            for (o, &c) in out.iter_mut().zip(b) {
                *o = c as i8 as i32;
            }
        }
        80 => {
            for (o, &c) in out.iter_mut().zip(b) {
                *o = c as i32 - (1 << 7);
            }
        }
        16 => {
            for (o, c) in out.iter_mut().zip(b.chunks_exact(2)) {
                *o = i16::from_le_bytes([c[0], c[1]]) as i32;
            }
        }
        61 => {
            for (o, c) in out.iter_mut().zip(b.chunks_exact(2)) {
                *o = i16::from_be_bytes([c[0], c[1]]) as i32;
            }
        }
        160 => {
            for (o, c) in out.iter_mut().zip(b.chunks_exact(2)) {
                *o = u16::from_le_bytes([c[0], c[1]]) as i32 - (1 << 15);
            }
        }
        24 => {
            for (o, c) in out.iter_mut().zip(b.chunks_exact(3)) {
                *o = sext(c[0] as u32 | (c[1] as u32) << 8 | (c[2] as u32) << 16, 24);
            }
        }
        32 => {
            for (o, c) in out.iter_mut().zip(b.chunks_exact(4)) {
                *o = i32::from_le_bytes([c[0], c[1], c[2], c[3]]);
            }
        }
        212 => {
            for (o, c) in out.chunks_exact_mut(2).zip(b.chunks_exact(3)) {
                let (b0, b1, b2) = (c[0] as u32, c[1] as u32, c[2] as u32);
                o[0] = sext(b0 | (b1 & 0x0f) << 8, 12);
                o[1] = sext(b2 | (b1 & 0xf0) << 4, 12);
            }
        }
        310 => {
            for (o, c) in out.chunks_exact_mut(3).zip(b.chunks_exact(4)) {
                let w0 = c[0] as u32 | (c[1] as u32) << 8;
                let w1 = c[2] as u32 | (c[3] as u32) << 8;
                o[0] = sext((w0 >> 1) & 0x3ff, 10);
                o[1] = sext((w1 >> 1) & 0x3ff, 10);
                o[2] = sext(((w0 & 0xf800) >> 11) | ((w1 & 0xf800) >> 6), 10);
            }
        }
        311 => {
            for (o, c) in out.chunks_exact_mut(3).zip(b.chunks_exact(4)) {
                let w0 = c[0] as u32 | (c[1] as u32) << 8;
                let w1 = c[2] as u32 | (c[3] as u32) << 8;
                o[0] = sext(w0 & 0x3ff, 10);
                o[1] = sext(((w0 & 0xfc00) >> 10) | ((c[2] as u32 & 0xf) << 6), 10);
                o[2] = sext((w1 >> 4) & 0x3ff, 10);
            }
        }
        _ => {}
    }
}

/// Stores the samples of one signal in `m` frames, as getskewedframe does
/// with each sample: from `raw` (`spf` samples every `rstride` values) into
/// `out` (`spf` every `ostride` values), invalid samples (code `inval`)
/// replaced by `samp` (the last valid sample) if `pad`, else by
/// `WFDB_INVALID_SAMPLE`; format 8 (`diff`): the running sums of the
/// differences. Updates `samp` and `cksum`.
#[allow(clippy::too_many_arguments)]
#[inline(always)]
fn bulk_signal(
    raw: &[i32],
    rstride: usize,
    out: &mut [i32],
    ostride: usize,
    m: usize,
    spf: usize,
    diff: bool,
    inval: i32,
    pad: bool,
    samp: &mut i32,
    cksum: &mut i32,
) {
    let (mut sp, mut ck) = (*samp, *cksum);
    if diff {
        for i in 0..m {
            for j in 0..spf {
                sp = sp.wrapping_add(raw[i * rstride + j]);
                out[i * ostride + j] = sp;
                ck = ck.wrapping_sub(sp);
            }
        }
    } else if pad {
        for i in 0..m {
            for j in 0..spf {
                let v = raw[i * rstride + j];
                ck = ck.wrapping_sub(v);
                if v != inval {
                    sp = v;
                }
                out[i * ostride + j] = sp;
            }
        }
    } else {
        for i in 0..m {
            for j in 0..spf {
                let v = raw[i * rstride + j];
                ck = ck.wrapping_sub(v);
                if v != inval {
                    sp = v;
                    out[i * ostride + j] = v;
                } else {
                    out[i * ostride + j] = WFDB_INVALID_SAMPLE;
                }
            }
        }
    }
    *samp = sp;
    *cksum = ck;
}

/// The number of frames decoded at once by the bulk path (at most).
const BULK_TILE: usize = 1024;

/// A group of input signals read by the bulk path (see
/// `Wfdb::bulk_frames`).
#[derive(Clone, Copy, Debug, Default)]
struct BulkGroup {
    /// Its first signal, and the signal after its last one.
    s0: usize,
    s1: usize,
    /// The format of its signals (0: null signals, without a file).
    fmt: i32,
    /// The number of its samples in a frame.
    gfl: usize,
    /// The position of its first sample in a frame.
    pos: usize,
}

fn gcd(a: usize, b: usize) -> usize {
    if b == 0 {
        a
    } else {
        gcd(b, a % b)
    }
}

// ---------------------------------------------------------------------------
// Low-level output routines

impl OgData {
    #[cold]
    fn w8_flush(&mut self, obsize: i32) {
        let n = if self.bsize > 0 { self.bsize } else { obsize } as usize;
        self.bp = 0;
        let n = n.min(self.buf.len());
        if let Some(f) = &mut self.fp {
            f.write(&self.buf[..n]);
        }
    }

    #[inline(always)]
    fn w8(&mut self, v: i32, obsize: i32) {
        self.buf[self.bp] = v as u8;
        self.bp += 1;
        if self.bp == self.be {
            self.w8_flush(obsize);
        }
    }

    #[inline(always)]
    fn w16(&mut self, v: i32, ob: i32) {
        self.w8(v, ob);
        self.w8(v >> 8, ob);
    }

    #[inline(always)]
    fn w61(&mut self, v: i32, ob: i32) {
        self.w8(v >> 8, ob);
        self.w8(v, ob);
    }

    #[inline(always)]
    fn w24(&mut self, v: i32, ob: i32) {
        self.w16(v, ob);
        self.w8(v >> 16, ob);
    }

    #[inline(always)]
    fn w32(&mut self, v: i32, ob: i32) {
        self.w16(v, ob);
        self.w16(v >> 16, ob);
    }

    #[inline(always)]
    fn w80(&mut self, v: i32, ob: i32) {
        self.w8((v & 0xff) + (1 << 7), ob);
    }

    #[inline(always)]
    fn w160(&mut self, v: i32, ob: i32) {
        self.w16((v & 0xffff) + (1 << 15), ob);
    }

    fn w212(&mut self, v: i32, ob: i32) {
        let c = self.count;
        self.count += 1;
        if c == 0 {
            self.data = v & 0xfff;
        } else {
            self.count = 0;
            self.data |= v.wrapping_shl(4) & 0xf000;
            let d = self.data;
            self.w16(d, ob);
            self.w8(v, ob);
        }
    }

    fn f212(&mut self, ob: i32) {
        if self.count == 1 {
            let d = self.data;
            self.w16(d, ob);
            self.nrewind = 2;
        }
    }

    fn w310(&mut self, v: i32, ob: i32) {
        let c = self.count;
        self.count += 1;
        match c {
            0 => self.data = v.wrapping_shl(1) & 0x7fe,
            1 => self.datb = v.wrapping_shl(1) & 0x7fe,
            _ => {
                self.count = 0;
                self.data |= v.wrapping_shl(11);
                let d = self.data;
                self.w16(d, ob);
                self.datb |= v.wrapping_shl(6) & !0x7fe;
                let d = self.datb;
                self.w16(d, ob);
            }
        }
    }

    fn f310(&mut self, ob: i32) {
        match self.count {
            0 => {}
            1 => {
                let d = self.data;
                self.w16(d, ob);
                self.nrewind = 2;
            }
            _ => {
                let (d, e) = (self.data, self.datb);
                self.w16(d, ob);
                self.w16(e, ob);
                self.nrewind = 4;
            }
        }
    }

    fn w311(&mut self, v: i32, ob: i32) {
        let c = self.count;
        self.count += 1;
        match c {
            0 => self.data = v & 0x3ff,
            1 => {
                self.data |= v.wrapping_shl(10);
                let d = self.data;
                self.w16(d, ob);
                self.datb = (v >> 6) & 0xf;
            }
            _ => {
                self.count = 0;
                self.datb |= v.wrapping_shl(4);
                self.datb &= 0x3fff;
                let d = self.datb;
                self.w16(d, ob);
            }
        }
    }

    fn f311(&mut self, ob: i32) {
        match self.count {
            0 => {}
            1 => {
                let d = self.data;
                self.w16(d, ob);
                self.nrewind = 2;
            }
            _ => {
                let d = self.datb;
                self.w16(d, ob);
                self.nrewind = 2;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// meansamp: the mean of n sample values, rounded to the nearest integer
// (halfway cases rounded up).
fn meansamp(s: &[i32], n: i32) -> i32 {
    let mut sum: i64 = (n / 2) as i64;
    for &x in &s[..n.max(0) as usize] {
        if x == WFDB_INVALID_SAMPLE {
            return WFDB_INVALID_SAMPLE;
        }
        sum += x as i64;
    }
    let neg = (sum < 0) as i64;
    if n & (n - 1) != 0 {
        ((sum + neg) / n as i64 - neg) as i32
    } else if n > 0 {
        // (n halvings, each rounding down)
        (sum >> n.trailing_zeros()) as i32
    } else {
        sum as i32
    }
}

/// Signal value range `(min, max)` of a storage format (the range of its
/// two's complement sample width). For formats other than 0 and 8, `min` is
/// also the code written for, and read back as, an invalid sample.
#[inline]
fn fmt_range(fmt: i32) -> (i32, i32) {
    match fmt {
        508 | 80 => (-0x80, 0x7f),
        310 | 311 => (-0x200, 0x1ff),
        212 => (-0x800, 0x7ff),
        16 | 61 | 516 | 160 => (-0x8000, 0x7fff),
        524 | 24 => (-0x800000, 0x7fffff),
        _ => (WFDB_SAMPLE_MIN, WFDB_SAMPLE_MAX),
    }
}

/// The (year, month, day) of a Julian date, as `datstr` gives them (the
/// calendar code of C's `datstr`).
fn julian_to_ymd(date: i64) -> [i32; 3] {
    let mut date = date;
    if date >= IGREG_JDN {
        // Gregorian calendar correction
        let gcorr = d2i(((date - 1867216) as f64 - 0.25) / 36524.25);
        date += 1 + gcorr as i64 - d2l(0.25 * gcorr as f64);
    }
    date += 1524;
    let jy = d2i(6680.0 + ((date - 2439870) as f64 - 122.1) / 365.25);
    let jd = d2l((365 * jy as i64) as f64 + 0.25 * jy as f64);
    let jm = d2i((date - jd) as f64 / 30.6001);
    let d = (date - jd - d2i(30.6001 * jm as f64) as i64) as i32;
    let mut m = jm - 1;
    if m > 12 {
        m -= 12;
    }
    let mut y = jy - 4715;
    if m > 2 {
        y -= 1;
    }
    if y <= 0 {
        y -= 1;
    }
    [y, m, d]
}

/// Lengths of C's static `date_string` and `time_string` buffers (without
/// the terminating NUL), to which C truncates the strings it formats.
const DATE_STRING_LEN: usize = 36;
const TIME_STRING_LEN: usize = 61;

/// The Julian day number of 15 October 1582, the first day of the
/// Gregorian calendar, and the same date as `d + 31 * (m + 12 * y)` (used
/// by `datstr` and `strdat`, after `caldat` and `julday` of Numerical
/// Recipes).
const IGREG_JDN: i64 = 2299161;
const IGREG_DMY: i64 = 15 + 31 * (10 + 12 * 1582);

/// Longest file name plus description accepted for an output signal (as in
/// C's `osigfopen`).
const MAXFDLEN: usize = 200;

/// Length of the longest EDF header field.
const EDF_MAXFIELD: usize = 80;
/// Size of the fixed part of an EDF header, and of each signal's part.
const EDF_HDRBLOCK: i64 = 256;

/// The buffer used by `edfparse` (C reads every header field into it, so
/// that stale bytes may follow a field): the longest field and a NUL.
struct EdfBuf([u8; EDF_MAXFIELD + 1]);

impl EdfBuf {
    /// Read a fixed-size field and remove trailing spaces.
    fn read_str(&mut self, size: usize, f: &mut WfdbFile) {
        if f.read(&mut self.0[..size]) != size {
            self.0[0] = 0;
        } else {
            let mut n = size;
            while n > 0 && self.0[n - 1] == b' ' {
                n -= 1;
            }
            self.0[n] = 0;
        }
    }

    fn s(&self) -> &[u8] {
        cstd::cstr(&self.0)
    }
}

// ---------------------------------------------------------------------------
// Internal functions

impl Wfdb {
    fn sigmap_cleanup(&mut self) {
        let st = &mut self.sig;
        st.need_sigmap = 0;
        st.nvsig = 0;
        st.tspf = 0;
        st.vspfmax = 0;
        st.ovec.clear();
        st.smi.clear();
        st.vsd.clear();
    }

    fn make_vsd(&mut self) -> i32 {
        let st = &mut self.sig;
        if st.nvsig != st.nisig as i32 {
            let msg = cformat!(
                b"make_vsd: oops! nvsig = %d, nisig = %d\n",
                st.nvsig,
                st.nisig
            );
            self.wfdb_error(msg);
            return -1;
        }
        let n = st.nvsig as usize;
        if st.vsd.len() < n {
            st.vsd.resize(n, IsData::default());
        }
        for i in 0..n {
            st.vsd[i].info = st.isd[i].info.clone();
            st.vsd[i].skew = st.isd[i].skew;
        }
        st.nvsig
    }

    fn segname(&self) -> Vec<u8> {
        let st = &self.sig;
        if st.have_segarray && st.segp >= 0 && (st.segp as usize) < st.segarray.len() {
            st.segarray[st.segp as usize].recname.clone()
        } else {
            Vec::new()
        }
    }

    fn sigmap_init(&mut self, first_segment: bool) -> i32 {
        let st = &mut self.sig;
        if st.in_msrec != 0
            && first_segment
            && st.have_segarray
            && !st.segarray.is_empty()
            && st.segarray[0].nsamp == 0
        {
            // This is the layout segment: set up the output side of the map.
            st.need_sigmap = 1;
            st.nvsig = st.nisig as i32;
            st.vspfmax = st.ispfmax as i32;
            st.tspf = 0;
            for s in 0..st.nisig as usize {
                st.tspf += st.isd[s].info.spf;
            }
            st.smi = vec![SigMapInfo::default(); st.tspf.max(0) as usize];
            let mut s = 0usize;
            for i in 0..st.nisig as usize {
                let m = &mut st.smi[s];
                m.desc = ostr(&st.isd[i].info.desc).to_vec();
                m.gain = st.isd[i].info.gain;
                m.baseline = st.isd[i].info.baseline;
                let k = st.isd[i].info.spf;
                m.spf = k;
                for j in 1..k.max(0) as usize {
                    st.smi[s + j] = st.smi[s].clone();
                }
                s += k.max(0) as usize;
            }
            st.ovec = vec![0; st.tspf.max(0) as usize];
            return self.make_vsd();
        } else if st.need_sigmap != 0 {
            // Set up the input side of the map.
            for m in &mut st.smi {
                m.index = 0;
                m.scale = 0.0;
                m.offset = 0.0;
                m.sample_offset = WFDB_INVALID_SAMPLE;
            }
            st.ispfmax = st.vspfmax as u32;
            if st.isd[0].info.fmt == 0 && st.nisig == 1 {
                return 0; // the current segment is a null record
            }
            let mut errs: Vec<Vec<u8>> = Vec::new();
            let segname = {
                let st = &self.sig;
                if st.have_segarray && st.segp >= 0 && (st.segp as usize) < st.segarray.len() {
                    st.segarray[st.segp as usize].recname.clone()
                } else {
                    Vec::new()
                }
            };
            let st = &mut self.sig;
            let tspf = st.tspf;
            let mut j = 0i32;
            for i in 0..st.nisig as usize {
                let ii = st.isd[i].info.clone();
                let idesc = ostr(&ii.desc).to_vec();
                let mut s = 0i32;
                while s < tspf {
                    if st.smi[s as usize].desc == idesc {
                        let mut kmax = st.smi[s as usize].spf;
                        if kmax != ii.spf {
                            errs.push(cformat!(
                                b"sigmap_init: unexpected spf for signal %d in segment %s\n",
                                i as i32,
                                segname
                            ));
                            if kmax > ii.spf {
                                kmax = ii.spf;
                            }
                        }
                        for k in 0..kmax {
                            let ps = &mut st.smi[(s + k) as usize];
                            ps.index = j + k;
                            ps.scale = ps.gain / ii.gain;
                            if ps.scale < 1.0 {
                                errs.push(cformat!(
                                    b"sigmap_init: loss of precision in signal %d in segment %s\n",
                                    i as i32,
                                    segname
                                ));
                            }
                            ps.offset = ps.baseline as f64 - ps.scale * ii.baseline as f64 + 0.5;
                            // If it is possible to add an additional offset
                            // such that all possible output values will fit
                            // into a positive signed integer, the "fast" case
                            // can be used in sigmap.
                            let (ivmin, ivmax) = fmt_range(ii.fmt);
                            let ovmin = ivmin as f64 * ps.scale + ps.offset;
                            let ovmax = ivmax as f64 * ps.scale + ps.offset;
                            if ovmin < ovmax
                                && ovmin >= WFDB_SAMPLE_MIN as f64 + 1.0
                                && ovmax <= WFDB_SAMPLE_MAX as f64
                                && ovmax - ovmin + 1.0 < WFDB_SAMPLE_MAX as f64
                            {
                                ps.sample_offset = d2i(ovmin - 1.0);
                                ps.offset -= ps.sample_offset as f64;
                            } else {
                                ps.sample_offset = 0;
                            }
                        }
                        break;
                    }
                    s += st.smi[s as usize].spf;
                }
                j += ii.spf;
            }
            let too_large = j > tspf;
            for e in errs {
                self.wfdb_error(e);
            }
            if too_large {
                let msg = cformat!(
                    b"sigmap_init: frame size too large in segment %s\n",
                    segname
                );
                self.wfdb_error(msg);
                return -1;
            }
        } else if st.in_msrec != 0 && !first_segment && st.framelen == 0 {
            // Opening a new segment of a fixed-layout multisegment record.
            st.ispfmax = st.vspfmax as u32;
            if st.nisig as i32 > st.nvsig {
                let msg = cformat!(
                    b"sigmap_init: wrong number of signals in segment %s\n",
                    self.segname()
                );
                self.wfdb_error(msg);
                return -1;
            }
            for i in 0..st.nisig as usize {
                if st.isd[i].info.spf != st.vsd[i].info.spf {
                    let msg = cformat!(
                        b"sigmap_init: wrong spf for signal %d in segment %s\n",
                        i as i32,
                        self.segname()
                    );
                    self.wfdb_error(msg);
                    return -1;
                }
            }
        } else {
            // Normal record, or multisegment record without a layout.
            st.nvsig = st.nisig as i32;
            st.vspfmax = st.ispfmax as i32;
            st.tspf = 0;
            for s in 0..st.nisig as usize {
                st.tspf += st.isd[s].info.spf;
            }
            return self.make_vsd();
        }
        0
    }

    // -----------------------------------------------------------------------
    // Header files

    /// Get header information from an EDF file.
    fn edfparse(&mut self) -> i32 {
        let mut buf = EdfBuf([0u8; EDF_MAXFIELD + 1]);
        let format;
        let (mut nsig, mut offset, mut day, mut month, mut year) = (0i32, 0i32, 0i32, 0i32, 0i32);
        let (mut hour, mut minute, mut second) = (0i32, 0i32, 0i32);
        let mut nframes: i64 = 0;
        let mut spr: f64;

        let fnamebuf = self.wfdb_filename().to_vec();
        let mut ifile = match self.sig.hheader.take() {
            Some(f) => f,
            None => return -1,
        };

        // Read the first 8 bytes and check for the magic string.
        ifile.read(&mut buf.0[..8]);
        if &buf.0[..8] == b"0       " {
            format = 16; // EDF or EDF+
        } else if &buf.0[1..8] == b"BIOSEMI" {
            format = 24; // BDF
        } else {
            let msg = cformat!(b"init: '%s' is not EDF or EDF+\n", fnamebuf);
            self.wfdb_error(msg);
            self.sig.hheader = Some(ifile);
            return -2;
        }

        // Read the remainder of the fixed-size section of the header.
        buf.read_str(80, &mut ifile); // patient ID (ignored)
        buf.read_str(80, &mut ifile); // recording ID (ignored)
        buf.read_str(8, &mut ifile); // recording date
        csscanf!(buf.s(), b"%d%*c%d%*c%d", &mut day, &mut month, &mut year);
        // EDF has only two-digit years: 85-99 are 1985-1999 (EDF dates from
        // 1985), 00-84 are 2000-2084.
        year = year.wrapping_add(1900);
        if year < 1985 {
            year += 100;
        }
        buf.read_str(8, &mut ifile); // recording time
        csscanf!(
            buf.s(),
            b"%d%*c%d%*c%d",
            &mut hour,
            &mut minute,
            &mut second
        );
        buf.read_str(8, &mut ifile); // number of bytes in header
        csscanf!(buf.s(), b"%d", &mut offset);
        buf.read_str(44, &mut ifile); // free space (ignored)
        buf.read_str(8, &mut ifile); // number of frames (EDF blocks)
        csscanf!(buf.s(), b"%ld", &mut nframes);
        if nframes < 0 {
            nframes = 0;
        }
        self.sig.nsamples = nframes;
        spr = 0.0;
        buf.read_str(8, &mut ifile); // data record duration (seconds)
        csscanf!(buf.s(), b"%lf", &mut spr);
        if spr <= 0.0 {
            spr = 1.0;
        }
        ifile.read(&mut buf.0[4..8]); // number of signals
        csscanf!(cstd::cstr(&buf.0[4..]), b"%d", &mut nsig);

        if nsig < 1 || (nsig as i64 + 1) * EDF_HDRBLOCK != offset as i64 {
            let msg = cformat!(b"init: '%s' is not EDF or EDF+\n", fnamebuf);
            self.wfdb_error(msg);
            self.sig.hheader = Some(ifile);
            return -2;
        }
        let ns = nsig as usize;

        // Allocate workspace.
        if self.sig.hsd.len() < ns {
            self.sig.hsd.resize(ns, HsData::default());
        }
        let mut dmax = vec![0i64; ns];
        let mut dmin = vec![0i64; ns];
        let mut pmax = vec![0f64; ns];
        let mut pmin = vec![0f64; ns];

        // Strip off any path info from the EDF file name (C starts the
        // search for '/' 5 bytes before the end of the name).
        let fname = cstd::cstr(&fnamebuf);
        let mut edf_fname: &[u8] = fname;
        let mut p = fname.len() as isize - 5;
        while p > 0 {
            if fname[p as usize] == b'/' {
                edf_fname = &fname[p as usize + 1..];
                break;
            }
            p -= 1;
        }
        let edf_fname = edf_fname.to_vec();

        // Read the variable-size section of the header.
        let spfmax0 = self.sig.spfmax;
        let mut spfmax = spfmax0;
        {
            let hsd = &mut self.sig.hsd;
            for h in hsd.iter_mut().take(ns) {
                h.start = offset as i64;
                h.skew = 0;
                h.info.fname = Some(edf_fname.clone());
                h.info.group = 0;
                h.info.bsize = 0;
                h.info.cksum = 0;
                h.info.fmt = format;
                h.info.nsamp = nframes;
                buf.read_str(16, &mut ifile); // signal type
                h.info.desc = Some(buf.s().to_vec());
            }
            for _ in 0..ns {
                buf.read_str(80, &mut ifile); // transducer type (ignored)
            }
            for h in hsd.iter_mut().take(ns) {
                buf.read_str(8, &mut ifile); // signal units
                h.info.units = Some(buf.s().to_vec());
            }
            for v in &mut pmin {
                buf.read_str(8, &mut ifile); // physical minimum
                csscanf!(buf.s(), b"%lf", v);
            }
            for v in &mut pmax {
                buf.read_str(8, &mut ifile); // physical maximum
                csscanf!(buf.s(), b"%lf", v);
            }
            for v in &mut dmin {
                buf.read_str(8, &mut ifile); // digital minimum
                csscanf!(buf.s(), b"%ld", v);
            }
            for s in 0..ns {
                buf.read_str(8, &mut ifile); // digital maximum
                csscanf!(buf.s(), b"%ld", &mut dmax[s]);
                let h = &mut hsd[s];
                let z = (dmax[s].wrapping_add(1).wrapping_add(dmin[s]) / 2) as i32;
                h.info.initval = z;
                h.info.adczero = z;
                let mut adcrange = dmax[s].wrapping_sub(dmin[s]);
                let mut i = 0;
                while adcrange > 0 {
                    adcrange /= 2;
                    i += 1;
                }
                h.info.adcres = i;
                if pmax[s] != pmin[s] {
                    h.info.gain = (dmax[s] - dmin[s]) as f64 / (pmax[s] - pmin[s]);
                    let baseline = dmax[s] as f64 - pmax[s] * h.info.gain;
                    h.info.baseline = if baseline >= 0.0 {
                        d2i(baseline + 0.5)
                    } else {
                        d2i(baseline - 0.5)
                    };
                } else {
                    // gain is undefined
                    h.info.gain = 0.0;
                    h.info.baseline = 0;
                }
            }
            for _ in 0..ns {
                buf.read_str(80, &mut ifile); // filtering information (ignored)
            }
            for h in hsd.iter_mut().take(ns) {
                let mut n = 0i32;
                buf.read_str(8, &mut ifile); // samples per frame (EDF block)
                csscanf!(buf.s(), b"%d", &mut n);
                h.info.spf = n;
                if n > spfmax {
                    spfmax = n;
                }
            }
        }
        self.sig.spfmax = spfmax;

        // Close the file (don't bother reading nsig*32 bytes of free space);
        // getinfo must not try to read the EDF file.
        drop(ifile);
        self.sig.hheader = None;

        let st = &mut self.sig;
        st.ffreq = 1.0 / spr; // frame frequency = 1/(seconds per EDF block)
        st.cfreq = st.ffreq; // set sampling and counter frequencies to match
        st.sfreq = st.ffreq * st.spfmax as f64;
        if self.getafreq() == 0.0 {
            let f = self.sig.sfreq;
            self.setafreq(f);
        }
        self.sig.gvmode |= WFDB_HIGHRES;
        let mut tb = cformat!(
            b"%02d:%02d:%02d %02d/%02d/%04d",
            hour,
            minute,
            second,
            day,
            month,
            year
        );
        tb.truncate(EDF_MAXFIELD); // C formats it into an 81-byte buffer
        self.setbasetime(&tb);

        self.sig.isedf = 1;
        nsig
    }

    /// WFDB-x: opens the header (of type `s`: `"hea"`, or `None` for a file
    /// name) of a record, or of a segment named in the header of the
    /// current multi-segment record (in the directory of that header), and
    /// notes its directory (`hdr_dir`). Legacy mode: `wfdb_open` (the WFDB
    /// path).
    fn open_header(&mut self, s: Option<&[u8]>, record: &[u8]) -> Option<WfdbFile> {
        if self.sig.legacy {
            return self.wfdb_open(s, record, WFDB_READ);
        }
        if self.sig.in_msrec == 0 {
            self.sig.msrec_dir = None;
            self.sig.msrec_name = None;
        }
        let f = match (
            &self.sig.msrec_name,
            self.sig.in_msrec != 0 && !self.sig.user_segments,
        ) {
            (Some(name), true) => {
                let (dir, name) = (self.sig.msrec_dir.clone(), name.clone());
                self.wfdbx_open_in(dir.as_deref(), s, record, &name)
            }
            _ => self.wfdb_open(s, record, WFDB_READ),
        };
        self.sig.hdr_dir = match &f {
            Some(f) if !f.is_std() => Some(crate::wfdbio::wfdbx_dirname(self.wfdb_filename())),
            _ => None,
        };
        f
    }

    fn readheader_err(&mut self, msg: Vec<u8>, ret: i32) -> i32 {
        self.wfdb_error(msg);
        ret
    }

    /// Read the header of `record` (or the EDF file it names). Returns the
    /// number of signals, -1 if the header cannot be opened, or -2 if it is
    /// invalid.
    fn readheader(&mut self, record: &[u8]) -> i32 {
        let record = cstd::cstr(record).to_vec();
        let record = &record[..];

        // If another input header file was opened, close it.
        self.sig.hheader = None;

        self.sig.spfmax = 1;
        self.sig.sfreq = self.sig.ffreq;
        self.sig.isedf = 0;
        if record == b"~" {
            let st = &mut self.sig;
            if st.in_msrec != 0 && !st.vsd.is_empty() {
                st.hsd = vec![HsData::default()];
                st.hsd[0].info.desc = Some(b"~".to_vec());
                st.hsd[0].info.spf = 1;
                st.hsd[0].info.fmt = 0;
                st.nsamples = st.segarray[st.segp as usize].nsamp;
                st.hsd[0].info.nsamp = st.nsamples;
                return 1;
            }
            return 0;
        }

        // If the final component of the record name includes a '.', assume
        // it is a file name.
        let mut qq = record.len().saturating_sub(1);
        while qq > 0 && !matches!(record[qq], b'.' | b'/' | b':' | b'\\') {
            qq -= 1;
        }
        if record.get(qq) == Some(&b'.') {
            match self.open_header(None, record) {
                None => {
                    let msg = cformat!(b"init: can't open %s\n", record);
                    return self.readheader_err(msg, -1);
                }
                Some(f) => {
                    self.sig.hheader = Some(f);
                    if &record[qq + 1..] != b"hea" {
                        // assume EDF if not '.hea'
                        return self.edfparse();
                    }
                }
            }
        } else {
            // Otherwise, assume the file name is record.hea.
            match self.open_header(Some(b"hea"), record) {
                None => {
                    let msg = cformat!(b"init: can't open header for record %s\n", record);
                    return self.readheader_err(msg, -1);
                }
                Some(f) => self.sig.hheader = Some(f),
            }
        }

        let mut line = std::mem::take(&mut self.sig.linebuf);
        let r = self.readheader_body(record, &mut line);
        self.sig.linebuf = line;
        r
    }

    fn hgetline(&mut self, line: &mut Vec<u8>) -> usize {
        match &mut self.sig.hheader {
            Some(f) => f.getline(line),
            None => 0,
        }
    }

    fn readheader_body(&mut self, record: &[u8], line: &mut Vec<u8>) -> i32 {
        let legacy = self.sig.legacy;
        // Read the first line and check for a magic string.
        if self.hgetline(line) == 0 {
            let msg = cformat!(b"init: record %s header is empty\n", record);
            return self.readheader_err(msg, -2);
        }
        const MAGIC: &[u8] = b"#wfdb"; // followed by the version required
        if line.starts_with(MAGIC) {
            let (mut major, mut minor, mut release) = (0i32, 0i32, 0i32);
            let n = csscanf!(
                cstd::cstr(&line[MAGIC.len()..]),
                b"%d.%d.%d",
                &mut major,
                &mut minor,
                &mut release
            );
            if (n > 0 && major > WFDB_MAJOR)
                || (n > 1 && major == WFDB_MAJOR && minor > WFDB_MINOR)
                || (n > 2 && major == WFDB_MAJOR && minor == WFDB_MINOR && release > WFDB_RELEASE)
            {
                let msg = cformat!(
                    b"init: reading record %s requires WFDB library version %d.%d.%d or later\n  (the most recent version is always available from http://physionet.org)\n",
                    record,
                    major,
                    minor,
                    release
                );
                return self.readheader_err(msg, -1);
            }
        }

        // Get the first token (the record name) from the first non-empty,
        // non-comment line.
        let mut lb = line.clone();
        let mut tok;
        loop {
            let mut st = Strtok::new(&lb);
            match st.next(SEP) {
                Some(p) if p[0] != b'#' => {
                    tok = Some((p.to_vec(), st.position()));
                    break;
                }
                _ => {}
            }
            if self.hgetline(line) == 0 {
                let msg = cformat!(
                    b"init: can't find record name in record %s header\n",
                    record
                );
                return self.readheader_err(msg, -2);
            }
            lb = line.clone();
        }
        let (mut p, pos) = tok.take().unwrap();
        // The rest of the line (for subsequent strtok calls).
        let rest: Vec<u8> = match pos {
            Some(k) => cstd::cstr(&lb)[k..].to_vec(),
            None => Vec::new(),
        };
        let mut save = Strtok::new(&rest);

        if let Some(q) = p.iter().skip(1).position(|&c| c == b'/').map(|k| k + 1) {
            if self.sig.in_msrec != 0 {
                let msg = cformat!(
                    b"init: record %s cannot be nested in another multi-segment record\n",
                    record
                );
                return self.readheader_err(msg, -2);
            }
            self.sig.segments = strtol10(&p[q + 1..]) as i32;
            p.truncate(q);
        }

        // For local files, be sure that the name (p) within the header file
        // matches the name (record) provided as an argument to this function.
        // (WFDB-x: a remote header, a fetched URL, is not checked, as the C
        // library did not check remote files.)
        let is_std = self
            .sig
            .hheader
            .as_ref()
            .is_some_and(|f| f.is_std() || f.is_remote());
        let plen = p.len();
        if !is_std && !(record.len() >= plen && record[..plen] == p[..]) {
            // If there is a mismatch, check to see if the record argument
            // includes a directory separator; if so, compare only the final
            // portion of the argument against the name in the header file.
            let r = record;
            let q2 = r.len() as isize - 1;
            let mut s2 = q2;
            while s2 > 0 {
                if matches!(r[s2 as usize], b'/' | b'\\' | b':') {
                    break;
                }
                s2 -= 1;
            }
            if q2 > s2 && p[..] != r[(s2 + 1) as usize..] {
                let msg = cformat!(
                    b"init: record name in record %s header is incorrect\n",
                    record
                );
                return self.readheader_err(msg, -2);
            }
        }

        // Identify which type of header file is being read by trying to get
        // another token from the line which contains the record name.
        let Some(p) = save.next(SEP) else {
            let msg = cformat!(b"init: obsolete format in record %s header\n", record);
            return self.readheader_err(msg, -2);
        };

        // The second token specifies the number of signals.
        let nsig = strtol10(p) as u32;

        // Determine the frame rate, if present and not set already.
        let p = save.next(SEP);
        if let Some(p) = p {
            let f = strtod0(p);
            if f <= 0.0 {
                let msg = cformat!(
                    b"init: sampling frequency in record %s header is incorrect\n",
                    record
                );
                return self.readheader_err(msg, -2);
            }
            if self.sig.ffreq > 0.0 && f != self.sig.ffreq {
                self.wfdb_error("warning (init):\n");
                let msg = cformat!(b" record %s sampling frequency differs", record);
                self.wfdb_error(msg);
                self.wfdb_error(" from that of previously opened record\n");
            } else {
                self.sig.ffreq = f;
            }
        } else if self.sig.legacy && self.sig.ffreq == 0.0 {
            self.sig.ffreq = WFDB_DEFFREQ;
        }
        // WFDB-x: if the header does not specify the sampling frequency (and
        // the caller has not set one with setsampfreq), it remains
        // unspecified (0); the C library assumed WFDB_DEFFREQ (250 Hz), as
        // legacy mode does.

        let st = &mut self.sig;
        // Set the sampling rate to the frame rate for now.
        st.sfreq = st.ffreq;

        // Determine the counter frequency and the base counter value.
        st.cfreq = 0.0;
        st.bcount = 0.0;
        if let Some(p) = p {
            if let Some(k) = p.iter().position(|&c| c == b'/') {
                let q = &p[k + 1..];
                st.cfreq = strtod0(q);
                if let Some(m) = q.iter().position(|&c| c == b'(') {
                    st.bcount = strtod0(&q[m + 1..]);
                }
            }
        }
        if st.cfreq <= 0.0 {
            st.cfreq = st.ffreq;
        }

        // Determine the number of samples per signal, if present and not set
        // already.
        let mut ns: i64;
        if let Some(p) = save.next(SEP) {
            ns = cstd::strtoll(p, 10).0;
            if ns < 0 {
                let msg = cformat!(
                    b"init: number of samples in record %s header is incorrect\n",
                    record
                );
                return self.readheader_err(msg, -2);
            }
            if st.nsamples == 0 {
                st.nsamples = ns;
            } else if ns > 0 && ns != st.nsamples && st.in_msrec == 0 {
                self.wfdb_error("warning (init):\n");
                let msg = cformat!(b" record %s duration differs", record);
                self.wfdb_error(msg);
                self.wfdb_error(" from that of previously opened record\n");
                // nsamples must match the shortest record duration.
                if self.sig.nsamples > ns {
                    self.sig.nsamples = ns;
                }
            }
        } else {
            ns = 0;
        }

        // Determine the base time and date, if present and not set already.
        if let Some(p) = save.next(b"\n\r") {
            if self.sig.btime == 0 && self.setbasetime(p) < 0 {
                return -2; // error message will come from setbasetime
            }
        }

        // Special processing for master header of a multi-segment record.
        if self.sig.segments != 0 && self.sig.in_msrec == 0 {
            let st = &mut self.sig;
            // WFDB-x: the segments are in the directory of this header
            if !st.legacy {
                st.msrec_dir = st.hdr_dir.clone();
                st.msrec_name = Some(record.to_vec());
            }
            st.msbtime = st.btime;
            st.msbdate = st.bdate;
            st.msnsamples = st.nsamples;
            // Read the names and lengths of the segment records.
            st.segarray.clear();
            st.have_segarray = true;
            ns = 0;
            let nseg = st.segments;
            for _ in 0..nseg.max(0) {
                // Get next segment spec, skip empty lines and comments.
                let (name, lenp) = loop {
                    if self.hgetline(line) == 0 {
                        let msg = cformat!(
                            b"init: unexpected EOF in header file for record %s\n",
                            record
                        );
                        return self.segfail(msg);
                    }
                    let mut tk = Strtok::new(line);
                    if let Some(p) = tk.next(SEP) {
                        if p[0] != b'#' {
                            let name = p.to_vec();
                            let lenp = tk.next(SEP).map(<[u8]>::to_vec);
                            break (name, lenp);
                        }
                    }
                };
                if name[0] == b'+' {
                    let msg = cformat!(
                        b"init: `%s' is not a valid segment name in record %s\n",
                        name,
                        record
                    );
                    return self.segfail(msg);
                }
                if name.len() > WFDB_MAXRNL {
                    let msg = cformat!(
                        b"init: `%s' is too long for a segment name in record %s\n",
                        name,
                        record
                    );
                    return self.segfail(msg);
                }
                let nsamp = lenp.as_ref().map(|x| cstd::strtoll(x, 10).0);
                match nsamp {
                    Some(n) if n >= 0 => {
                        self.sig.segarray.push(Seginfo {
                            recname: name,
                            nsamp: n,
                            samp0: ns,
                        });
                        // (C: the sum overflows if the lengths exceed the
                        // range of WFDB_Time; WFDB-x wraps it around, as C
                        // does on x86-64: see docs/KNOWN_C_BEHAVIORS.md)
                        ns = ns.wrapping_add(n);
                    }
                    _ => {
                        let msg = cformat!(
                            b"init: length must be specified for segment %s in record %s\n",
                            name,
                            record
                        );
                        return self.segfail(msg);
                    }
                }
            }
            let st = &mut self.sig;
            st.segend = st.segarray.len() as i32 - 1;
            st.segp = 0;
            if st.msnsamples == 0 {
                st.msnsamples = ns;
            } else if ns != st.msnsamples {
                let msg = cformat!(
                    b"warning (init): in record %s, stated record length (%lld)\n",
                    record,
                    st.msnsamples
                );
                self.wfdb_error(msg);
                let msg = cformat!(b" does not match sum of segment lengths (%lld)\n", ns);
                self.wfdb_error(msg);
            }
            return 0;
        }

        // Now get information for each signal.
        let mut s: u32 = 0;
        while s < nsig {
            let su = s as usize;
            if self.sig.hsd.len() <= su {
                self.sig.hsd.resize(su + 1, HsData::default());
            }

            // Get the first token (the signal file name) from the next
            // non-empty, non-comment line.
            let lb;
            loop {
                if self.hgetline(line) == 0 {
                    let msg = cformat!(
                        b"init: unexpected EOF in header file for record %s\n",
                        record
                    );
                    return self.readheader_err(msg, -2);
                }
                let mut tk = Strtok::new(line);
                if let Some(p) = tk.next(SEP) {
                    if p[0] != b'#' {
                        lb = line.clone();
                        break;
                    }
                }
            }
            let mut tk = Strtok::new(&lb);
            let p = tk.next(SEP).unwrap();

            let st = &mut self.sig;
            let (hp_group, hp_fname, hp_fmt, hp_bsize) = if s > 0 {
                let hp = &st.hsd[su - 1];
                (
                    hp.info.group,
                    hp.info.fname.clone(),
                    hp.info.fmt,
                    hp.info.bsize,
                )
            } else {
                (0, None, 0, 0)
            };
            let hs = &mut st.hsd[su];

            // Determine the signal group number.
            if s == 0 || p != str_or_null(&hp_fname) {
                hs.info.group = if s == 0 { 0 } else { hp_group + 1 };
                hs.info.fname = Some(p.to_vec());
            } else {
                hs.info.group = hp_group;
                hs.info.fname = hp_fname;
            }

            // Determine the signal format.
            let pf = tk.next(SEP);
            let ok = match pf {
                Some(pf) => {
                    hs.info.fmt = strtol10(pf) as i32;
                    isfmt(hs.info.fmt)
                }
                None => false,
            };
            if !ok {
                let msg = cformat!(
                    b"init: illegal format for signal %d, record %s\n",
                    s as i32,
                    record
                );
                return self.readheader_err(msg, -2);
            }
            let pf = pf.unwrap();
            hs.info.spf = 1;
            hs.skew = 0;
            hs.start = 0;
            // Parse the optional "xSPF", ":SKEW", and "+START" suffixes.
            // (If the token ends with one of the prefix characters, C reads
            // past its end; the suffix is ignored here.)
            let at = |i: usize| -> u8 { pf.get(i).copied().unwrap_or(0) };
            let mut i = 0usize;
            loop {
                i += 1;
                if at(i) == 0 {
                    break;
                }
                if at(i) == b'x' {
                    i += 1;
                    if at(i) != 0 {
                        hs.info.spf = strtol10(&pf[i..]) as i32;
                        if hs.info.spf < 1 {
                            hs.info.spf = 1;
                        }
                    } else {
                        break;
                    }
                }
                if at(i) == b':' {
                    i += 1;
                    if at(i) != 0 {
                        hs.skew = strtol10(&pf[i..]) as i32;
                        if hs.skew < 0 {
                            hs.skew = 0;
                        }
                    } else {
                        break;
                    }
                }
                if at(i) == b'+' {
                    i += 1;
                    if at(i) != 0 {
                        hs.start = strtol10(&pf[i..]);
                        if hs.start < 0 {
                            hs.start = 0;
                        }
                    } else {
                        break;
                    }
                }
            }
            if hs.info.spf > st.spfmax {
                st.spfmax = hs.info.spf;
            }
            // The skew in samples (given in the header) is converted to
            // skew in frames here.
            hs.skew = d2i(hs.skew as f64 / hs.info.spf as f64 + 0.5);

            // Determine the gain in ADC units per physical unit.
            let pg = tk.next(SEP);
            hs.info.gain = match pg {
                Some(g) => strtod0(g),
                None => 0.0,
            };

            // Determine the baseline if specified, and the physical units.
            let mut nobaseline = true;
            let mut units: Option<Vec<u8>> = None;
            if let Some(g) = pg {
                let mut k = 0usize;
                while k < g.len() && g[k] != b'(' && g[k] != b'/' {
                    k += 1;
                }
                if k < g.len() && g[k] == b'(' {
                    k += 1;
                    hs.info.baseline = strtol10(&g[k..]) as i32;
                    nobaseline = false;
                }
                while k < g.len() {
                    let c = g[k];
                    k += 1;
                    if c == b'/' && k < g.len() {
                        break;
                    }
                }
                if k < g.len() {
                    units = Some(strn(&g[k..], WFDB_MAXUSL));
                }
            }
            hs.info.units = units;

            // Determine the ADC resolution in bits.  WFDB-x: if this number
            // is missing, it is unspecified (0); the C library inferred it
            // from the format or assumed WFDB_DEFRES (12 bits), as legacy
            // mode does.
            hs.info.adcres = match tk.next(SEP) {
                Some(r) => strtol10(r) as u32 as i32,
                None if legacy => match hs.info.fmt {
                    80 => 8,
                    160 => 16,
                    212 => 12,
                    310 => 10,
                    311 => 10,
                    _ => WFDB_DEFRES,
                },
                None => 0,
            };

            // Determine the ADC zero (assumed to be zero if missing).
            hs.info.adczero = match tk.next(SEP) {
                Some(r) => strtol10(r) as i32,
                None => 0,
            };

            // Set the baseline to adczero if no baseline field was found.
            if nobaseline {
                hs.info.baseline = hs.info.adczero;
            }

            // Determine the initial value.
            hs.info.initval = match tk.next(SEP) {
                Some(r) => strtol10(r) as i32,
                None => hs.info.adczero,
            };

            // Determine the checksum (assumed to be zero if missing).
            match tk.next(SEP) {
                Some(r) => {
                    hs.info.cksum = strtol10(r) as i32;
                    hs.info.nsamp = ns;
                }
                None => {
                    hs.info.cksum = 0;
                    hs.info.nsamp = 0;
                }
            }

            // Determine the block size (assumed to be zero if missing).
            hs.info.bsize = match tk.next(SEP) {
                Some(r) => strtol10(r) as i32,
                None => 0,
            };

            // Check that formats and block sizes match for signals belonging
            // to the same group.
            if s > 0
                && hs.info.group == hp_group
                && (hs.info.fmt != hp_fmt || hs.info.bsize != hp_bsize)
            {
                let msg = cformat!(
                    b"init: error in specification of signal %d or %d\n",
                    s as i32 - 1,
                    s as i32
                );
                return self.readheader_err(msg, -2);
            }

            // Get the signal description.
            hs.info.desc = match tk.next(b"\n\r") {
                Some(d) => Some(strn(d, WFDB_MAXDSL)),
                None => Some(cformat!(b"record %s, signal %d", record, s as i32)),
            };
            s += 1;
        }
        let m = self.sig.gvmode;
        self.setgvmode(m); // Reset sfreq if appropriate.
        s as i32
    }

    fn segfail(&mut self, msg: Vec<u8>) -> i32 {
        self.wfdb_error(msg);
        let st = &mut self.sig;
        st.segarray.clear();
        st.have_segarray = false;
        st.segments = 0;
        -2
    }

    fn hsdfree(&mut self) {
        self.sig.hsd.clear();
    }
}

// ---------------------------------------------------------------------------
// FLAC input and output (glue to flac.rs)

/// FLAC input (one signal group): the FLAC fields of the C `igdata`.
#[derive(Default)]
struct FlacIn {
    /// The decoder (made from the signal file when the group is first read
    /// or sought).
    dec: Option<flac::StreamDecoder>,
    md5_check: bool,
    pack: FlacPack,
}

/// The decoded samples of a FLAC signal group not yet read, in frame
/// order, and what the decoder reports (C `iflac_samples` and
/// `iflac_error`, which receive the results of the libFLAC decoder).
#[derive(Default)]
struct FlacPack {
    /// Signals in the group (C `data`), and their resolution (`datb`).
    nsig: u32,
    datb: u32,
    /// Samples per frame of each signal (C `packspf`).
    spf: usize,
    /// `buf[bp..packptr]`: complete frames not yet read; then the frame
    /// being filled, of which `packcount` samples per signal are decoded.
    buf: Vec<i32>,
    bp: usize,
    packptr: usize,
    packcount: usize,
    /// Samples (per signal) to skip after a seek (C `count`).
    count: u64,
    /// The group's `stat` while the decoder runs.
    stat: i32,
    /// The messages to report.
    msgs: Vec<&'static [u8]>,
}

impl flac::Client for FlacPack {
    fn error(&mut self, e: flac::DecodeError) {
        self.msgs.push(match e {
            flac::DecodeError::LostSync => b"getvec: unable to decode FLAC (lost sync)\n",
            flac::DecodeError::BadHeader => b"getvec: unable to decode FLAC (invalid header)\n",
            flac::DecodeError::CrcMismatch => b"getvec: unable to decode FLAC (CRC mismatch)\n",
            flac::DecodeError::Unparseable => {
                b"getvec: unable to decode FLAC (unsupported format)\n"
            }
        });
        // (decoding stops at the next frame)
        self.stat = -2;
    }

    fn write(&mut self, h: &flac::FrameHeader, chans: &[&[i32]]) -> bool {
        if h.channels != self.nsig {
            self.msgs
                .push(b"getvec: wrong number of signals in FLAC signal file\n");
            self.stat = -2;
        }
        if h.bits_per_sample > self.datb {
            self.msgs
                .push(b"getvec: wrong sample resolution in FLAC signal file\n");
            self.stat = -2;
        }
        if self.stat < 0 {
            return false;
        }
        let (nsig, spf) = (chans.len(), self.spf);
        let frmsize = nsig * spf;
        // Shift out the samples already read.
        if self.bp > 0 {
            self.buf.drain(..self.bp);
            self.packptr -= self.bp;
            self.bp = 0;
        }
        let mut nsamp = h.blocksize as u64;
        if self.count > nsamp {
            self.count -= nsamp;
            return true;
        }
        let mut ipos = self.count as usize;
        nsamp -= self.count;
        self.count = 0;
        // Store the samples in frame order.
        let mut nsamp = nsamp as usize;
        let mut orem = spf - self.packcount;
        let mut p = self.packptr + self.packcount;
        self.buf.resize(self.packptr + frmsize, 0);
        while nsamp != 0 {
            let n = nsamp.min(orem);
            for (s, c) in chans.iter().enumerate() {
                let o = p + s * spf;
                self.buf[o..o + n].copy_from_slice(&c[ipos..ipos + n]);
            }
            nsamp -= n;
            orem -= n;
            if orem == 0 {
                self.packptr += frmsize;
                self.buf.resize(self.packptr + frmsize, 0);
                p = self.packptr;
                orem = spf;
                ipos += n;
            }
        }
        self.packcount = spf - orem;
        true
    }
}

/// `flac_isclose`: closes the decoder of a FLAC input (an error message if
/// the MD5 signature of its samples was checked and is wrong).
fn flac_isclose(ig: &mut IgData) -> Option<&'static [u8]> {
    let fi = ig.flac.as_mut()?;
    let ok = match fi.dec.as_mut() {
        Some(d) => d.finish(),
        // (a decoder that has read nothing has no STREAMINFO signature)
        None => !fi.md5_check,
    };
    (!ok).then_some(&b"isigclose: warning: incorrect MD5 hash in FLAC input\n"[..])
}

impl OgData {
    /// Write a sample to a FLAC signal group, wrapped (as C does) to the 8,
    /// 16 or 24 bits of the format.
    fn flac_putsamp(&mut self, v: i32, fmt: i32) -> i32 {
        let v = match fmt {
            508 => v as u8 as i8 as i32,
            516 => v as u16 as i16 as i32,
            524 => ((v as u32) << 8) as i32 >> 8,
            _ => v,
        };
        let Some(fo) = self.flac.as_mut() else {
            return -1;
        };
        fo.pending.clear();
        fo.enc.put(v, &mut fo.pending);
        if !fo.pending.is_empty() {
            if let Some(f) = &mut self.fp {
                f.write(&fo.pending);
            }
        }
        0
    }

    fn flac_osopen(&mut self) -> i32 {
        let Some(fo) = self.flac.as_mut() else {
            return 0;
        };
        let hdr = fo.enc.header();
        fo.header_pos = match &mut self.fp {
            Some(f) => f.tell(),
            None => 0,
        };
        if let Some(f) = &mut self.fp {
            f.write(&hdr);
        }
        0
    }

    fn flac_osclose(&mut self) {
        if let Some(mut fo) = self.flac.take() {
            fo.pending.clear();
            fo.enc.finish(&mut fo.pending);
            if let Some(f) = &mut self.fp {
                if !fo.pending.is_empty() {
                    f.write(&fo.pending);
                }
                if f.seek(fo.header_pos + flac::STREAMINFO_POS, SEEK_SET) == 0 {
                    let si = fo.enc.streaminfo();
                    f.write(&si);
                    f.seek(0, SEEK_END);
                }
            }
        }
        self.bp = 0;
        self.be = 0;
    }
}

impl Wfdb {
    /// The decoder of FLAC signal group `g`, made from its signal file
    /// when first needed (C makes it when the group is opened; it reads
    /// nothing until then).
    fn flac_decoder(&mut self, g: usize) {
        let ig = &mut self.sig.igd[g];
        let seekable = ig.seek != 0;
        let Some(fi) = ig.flac.as_mut() else {
            return;
        };
        if fi.dec.is_none() {
            let data = match &mut ig.fp {
                Some(f) => f.read_to_end(),
                None => Vec::new(),
            };
            fi.dec = Some(flac::StreamDecoder::new(data, seekable, fi.md5_check));
        }
    }

    /// Reports the messages of the decoder of a FLAC input.
    fn flac_messages(&mut self, fi: &mut FlacIn) {
        for m in std::mem::take(&mut fi.pack.msgs) {
            self.wfdb_error(m);
        }
    }

    /// `flac_getsamp`: the next sample of FLAC signal group `g`.
    fn flac_getsamp(&mut self, g: usize) -> i32 {
        self.flac_decoder(g);
        let Some(mut fi) = self.sig.igd[g].flac.take() else {
            self.sig.igd[g].stat = -2;
            return 0;
        };
        let mut stat = self.sig.igd[g].stat;
        let v = loop {
            let p = &mut fi.pack;
            if p.bp != p.packptr {
                // the next decoded sample
                let v = p.buf[p.bp];
                p.bp += 1;
                break v;
            }
            // Decode the next FLAC frame (or metadata block).
            let oldcount = p.packcount;
            p.stat = stat;
            let ok = match fi.dec.as_mut() {
                Some(d) => d.process_single(&mut fi.pack),
                None => false,
            };
            stat = fi.pack.stat;
            self.flac_messages(&mut fi);
            if !ok {
                if stat != -2 {
                    self.wfdb_error("getvec: unexpected FLAC decoding error\n");
                    stat = -2;
                }
                break 0;
            }
            if stat <= 0 {
                break 0;
            }
            let p = &mut fi.pack;
            if p.bp == p.packptr && p.packcount == oldcount {
                match fi.dec.as_ref().map(|d| d.state()) {
                    Some(flac::State::EndOfStream) => {
                        if p.packcount != 0 {
                            let msg = cformat!(
                                b"getvec: warning: %d samples left over at end of file\n",
                                p.packcount as i32
                            );
                            self.wfdb_error(msg);
                        }
                        fi.pack.packcount = 0;
                        stat = 0;
                        break 0;
                    }
                    Some(
                        flac::State::SearchForMetadata
                        | flac::State::ReadMetadata
                        | flac::State::SearchForFrameSync,
                    ) => {}
                    _ => {
                        self.wfdb_error("getvec: unknown FLAC decoding state\n");
                        stat = -2;
                        break 0;
                    }
                }
            }
        };
        let ig = &mut self.sig.igd[g];
        ig.stat = stat;
        ig.flac = Some(fi);
        v
    }

    fn flac_isopen(&mut self, g: usize, si: usize, ns: u32) -> i32 {
        if ns > flac::MAX_CHANNELS as u32 {
            let msg = cformat!(
                b"isigopen: cannot store %u signals in a single FLAC file\n",
                ns
            );
            self.wfdb_error(msg);
            return -1;
        }
        let hs = &self.sig.hsd[si..si + ns as usize];
        for h in &hs[1..] {
            if h.info.spf != hs[0].info.spf {
                self.wfdb_error(
                    "isigopen: every signal in a FLAC file must have\n  the same sampling frequency\n",
                );
                return -1;
            }
        }
        let fi = FlacIn {
            md5_check: cstd::getenv("WFDB_FLAC_CHECK_MD5").is_some_and(|p| !p.is_empty()),
            pack: FlacPack {
                nsig: ns,
                datb: (hs[0].info.fmt - FLAC_FMT_BASE) as u32,
                spf: hs[0].info.spf.max(1) as usize,
                ..Default::default()
            },
            ..Default::default()
        };
        let ig = &mut self.sig.igd[g];
        ig.flac = Some(Box::new(fi));
        ig.count = 0;
        0
    }

    /// `flac_isseek`: seeks FLAC signal group `g` to frame `t`.
    fn flac_isseek(&mut self, g: usize, t: i64) -> i32 {
        self.flac_decoder(g);
        let start = self.sig.igd[g].start;
        let Some(mut fi) = self.sig.igd[g].flac.take() else {
            self.sig.igd[g].stat = -1;
            return -1;
        };
        // After a failed seek, clear the decoder state to try again.
        let Some(dec) = fi.dec.as_mut() else {
            self.sig.igd[g].flac = Some(fi);
            self.sig.igd[g].stat = -1;
            return -1;
        };
        if dec.state() == flac::State::SeekError {
            dec.flush();
        }
        // Nothing is left of the current block.
        let p = &mut fi.pack;
        p.buf.clear();
        p.bp = 0;
        p.packptr = 0;
        p.packcount = 0;
        p.count = 0;
        p.stat = 1;
        // Seek to the sample before the one wanted (seeking to the end of
        // the stream fails), and skip it.
        let mut tt = t.wrapping_mul(p.spf as i64).wrapping_add(start);
        if tt != 0 {
            tt -= 1;
            p.count = 1;
        }
        let mut stat = if dec.seek_absolute(tt as u64, &mut fi.pack) {
            fi.pack.stat
        } else {
            -1
        };
        self.flac_messages(&mut fi);
        if stat > 0 {
            stat = 1;
        }
        let ig = &mut self.sig.igd[g];
        ig.stat = stat;
        ig.flac = Some(fi);
        stat
    }

    fn flac_osinit(&mut self, g: usize, si: &[Siginfo], ns: u32) -> i32 {
        if ns > flac::MAX_CHANNELS as u32 {
            let msg = cformat!(
                b"osigfopen: cannot store %u signals in a single FLAC file\n",
                ns
            );
            self.wfdb_error(msg);
            return -1;
        }
        for s in &si[1..ns as usize] {
            if s.spf != si[0].spf {
                self.wfdb_error(
                    "osigfopen: every signal in a FLAC file must have\n  the same sampling frequency\n",
                );
                return -1;
            }
        }
        let spf = if si[0].spf < 1 { 1 } else { si[0].spf };
        let og = &mut self.sig.ogd[g];
        og.flac = Some(Box::new(FlacOut {
            enc: flac::Encoder::new(ns as i32, si[0].fmt - FLAC_FMT_BASE, spf),
            header_pos: 0,
            pending: Vec::new(),
        }));
        // Make the buffer exactly large enough to hold a single frame of
        // 32-bit samples, as C does (a non-zero bsize also prevents
        // wfdb_osflush from flushing it).
        og.bsize = (ns as i32)
            .wrapping_mul(si[0].spf)
            .wrapping_mul(std::mem::size_of::<i32>() as i32);
        0
    }

    // -----------------------------------------------------------------------
    // Closing signals

    fn isigclose(&mut self) {
        let st = &mut self.sig;
        if st.have_sbuf && st.in_msrec == 0 {
            st.sbuf = Vec::new();
            st.have_sbuf = false;
            st.sample_vflag = 0;
        }
        st.isd.clear();
        st.nisig = 0;
        st.framelen = 0;
        st.empty_group = false;

        while let Some(mut ig) = self.sig.igd.pop() {
            if let Some(m) = flac_isclose(&mut ig) {
                self.wfdb_error(m);
            }
            ig.fp = None;
        }
        let st = &mut self.sig;
        st.nigroup = 0;

        st.istime = 0;
        st.gvc = 1;
        st.ispfmax = 1;
        st.hheader = None;
        st.linebuf = Vec::new();
        if st.nosig == 0 && !st.hsd.is_empty() {
            st.hsd.clear();
        }
    }

    fn osigclose(&mut self) -> i32 {
        let mut stat = 0;
        {
            let st = &mut self.sig;
            let n = (st.nogroup as usize).min(st.ogd.len());
            for og in &mut st.ogd[..n] {
                og.force_flush = 1;
            }
        }
        self.wfdb_osflush();

        self.sig.osd.clear();
        self.sig.nosig = 0;

        while let Some(mut og) = self.sig.ogd.pop() {
            let maxogroup = self.sig.ogd.len() as i32;
            if og.fp.is_some() {
                if og.flac.is_some() {
                    og.flac_osclose();
                }
                // If a block size has been defined, null-pad the buffer.
                if og.bsize != 0 {
                    while og.bp < og.be {
                        og.buf[og.bp] = 0;
                        og.bp += 1;
                    }
                }
                let mut fp = og.fp.take().unwrap();
                // Flush the last block unless it's empty.
                if og.bp != 0 {
                    fp.write(&og.buf[..og.bp]);
                }
                if fp.is_std() {
                    fp.flush();
                }
                let mut errflag = fp.error();
                // Close the file (except stdout, which is closed on exit).
                if !fp.is_std() {
                    if fp.close() != 0 {
                        errflag = true;
                    }
                } else {
                    drop(fp);
                }
                if errflag {
                    let msg = cformat!(b"osigclose: write error in signal group %d\n", maxogroup);
                    self.wfdb_error(msg);
                    stat = -4;
                }
            }
        }
        self.sig.nogroup = 0;

        self.sig.ostime = 0;
        if let Some(oh) = self.sig.oheader.take() {
            let mut errflag = oh.error();
            if oh.close() != 0 {
                errflag = true;
            }
            if errflag {
                self.wfdb_error("osigclose: write error in header file\n");
                stat = -4;
            }
            if self.sig.outinfo == OutInfo::Header {
                self.sig.outinfo = OutInfo::None;
            }
        }
        if self.sig.nisig == 0 && !self.sig.hsd.is_empty() {
            self.hsdfree();
        }
        stat
    }

    // -----------------------------------------------------------------------
    // Input positioning and reading

    fn seekerr(&mut self, g: u32) -> i32 {
        let msg = cformat!(b"isigsettime: improper seek on signal group %d\n", g);
        self.wfdb_error(msg);
        -1
    }

    fn overflow(&mut self, g: u32) -> i32 {
        let msg = cformat!(b"isigsettime: overflow in signal group %d\n", g);
        self.wfdb_error(msg);
        -1
    }

    fn isgsetframe(&mut self, g: u32, mut t: i64) -> i32 {
        let gu = g as usize;
        // Do nothing if there is no more than one input signal group and
        // the input pointer is correct already.
        {
            let st = &self.sig;
            if st.nigroup < 2
                && st.istime == t
                && st.gvc == st.ispfmax as i32
                && gu < st.igd.len()
                && st.igd[gu].start == 0
            {
                return 0;
            }
        }

        // Find the first signal that belongs to group g.
        let nisig = self.sig.nisig as usize;
        let mut s = 0usize;
        while s < nisig && g != self.sig.isd[s].info.group {
            s += 1;
        }
        if s == nisig {
            let msg = cformat!(b"isgsettime: incorrect signal group number %d\n", g);
            self.wfdb_error(msg);
            return -2;
        }

        // If the current record contains multiple segments, locate the
        // segment containing the desired sample.
        if self.sig.in_msrec != 0 {
            let st = &self.sig;
            let mut tseg = st.segp;
            if t >= st.msnsamples {
                return self.seekerr(g);
            }
            while tseg > 0 && t < st.segarray[tseg as usize].samp0 {
                tseg -= 1;
            }
            while t >= st.segarray[tseg as usize].samp0 + st.segarray[tseg as usize].nsamp
                && tseg < st.segend
            {
                tseg += 1;
            }
            if st.segp != tseg {
                self.sig.segp = tseg;
                let name = self.sig.segarray[tseg as usize].recname.clone();
                let nvsig = self.sig.nvsig;
                if self.isigopen(&name, &mut [], nvsig) <= 0 {
                    let msg = cformat!(b"isigsettime: can't open segment %s\n", name);
                    self.wfdb_error(msg);
                    return -1;
                }
                // Following isigopen(), nigroup may have changed: seek on
                // all non-zero groups (regardless of g), but on group 0 only
                // if g is 0.
                let mut h = 1;
                while h < self.sig.nigroup {
                    let i = self.isgsetframe(h, t);
                    if i != 0 {
                        return i;
                    }
                    h += 1;
                }
                return if g == 0 { self.isgsetframe(0, t) } else { 0 };
            }
            t -= self.sig.segarray[self.sig.segp as usize].samp0;
        }

        let st = &mut self.sig;
        st.igd[gu].initial_skip = 0;
        // Determine the number of samples per frame for signals in the group.
        let mut n = 0usize;
        let mut nn: u32 = 0;
        while s + n < nisig && st.isd[s + n].info.group == g {
            nn = nn.wrapping_add(st.isd[s + n].info.spf as u32);
            n += 1;
        }
        let msoff = if st.in_msrec != 0 {
            st.segarray[st.segp as usize].samp0
        } else {
            0
        };
        // Determine the number of bytes per sample interval in the file:
        // `b` bytes hold `d` frames of the group's `nn` samples per frame
        // (format 212 packs 2 samples in 3 bytes, 310 and 311 pack 3 in 4).
        let b: u32;
        let mut d: u32 = 1;
        match st.isd[s].info.fmt {
            0 => {
                if t < st.nsamples {
                    st.gvc = st.ispfmax as i32;
                    if s == 0 {
                        st.istime = if st.in_msrec != 0 { t + msoff } else { t };
                    }
                    st.isd[s].info.nsamp = st.nsamples - t;
                    st.igd[gu].stat = 1;
                    return 0;
                } else {
                    if s == 0 {
                        st.istime = if st.in_msrec != 0 {
                            st.msnsamples
                        } else {
                            st.nsamples
                        };
                    }
                    st.isd[s].info.nsamp = 0;
                    return -1;
                }
            }
            508 | 516 | 524 => {
                if self.flac_isseek(gu, t) < 0 {
                    return self.seekerr(g);
                }
                let st = &mut self.sig;
                // Reset the getvec sample-within-frame counter.
                st.gvc = st.ispfmax as i32;
                // Reset the time (if signal 0 belongs to the group) and
                // disable checksum testing.
                if s == 0 {
                    st.istime = if st.in_msrec != 0 { t + msoff } else { t };
                }
                for k in 0..n {
                    st.isd[s + k].info.nsamp = 0;
                }
                return 0;
            }
            16 | 61 | 160 => {
                if nn > u32::MAX / 2 {
                    return self.overflow(g);
                }
                b = 2 * nn;
            }
            212 => {
                if nn > u32::MAX / 3 {
                    return self.overflow(g);
                }
                // Reset the input counter.
                st.igd[gu].count = 0;
                // If the desired sample does not lie on a byte boundary,
                // seek to the previous sample and then read ahead.
                if (nn & 1) != 0 && (t & 1) != 0 {
                    if st.in_msrec != 0 {
                        t += msoff; // absolute time
                    }
                    let i = self.isgsetframe(g, t - 1);
                    if i != 0 {
                        return i;
                    }
                    let st = &mut self.sig;
                    for _ in 0..nn {
                        st.igd[gu].r212();
                    }
                    st.istime += 1;
                    let mut k = 0;
                    while s + k < nisig && st.isd[s + k].info.group == g {
                        st.isd[s + k].info.nsamp = 0;
                        k += 1;
                    }
                    return 0;
                }
                b = 3 * nn;
                d = 2;
            }
            310 | 311 => {
                let fmt = st.isd[s].info.fmt;
                if nn > u32::MAX / 4 {
                    return self.overflow(g);
                }
                st.igd[gu].count = 0;
                // If the desired sample does not lie on a byte boundary,
                // seek to the closest previous sample that does, then read
                // ahead.
                let trem = (t % 3) as i32;
                if (nn % 3) != 0 && trem != 0 {
                    if st.in_msrec != 0 {
                        t += msoff;
                    }
                    let i = self.isgsetframe(g, t - trem as i64);
                    if i != 0 {
                        return i;
                    }
                    let st = &mut self.sig;
                    let mut j = nn.wrapping_mul(trem as u32);
                    while j > 0 {
                        if fmt == 310 {
                            st.igd[gu].r310();
                        } else {
                            st.igd[gu].r311();
                        }
                        j -= 1;
                    }
                    st.istime += trem as i64;
                    let mut k = 0;
                    while s + k < nisig && st.isd[s + k].info.group == g {
                        st.isd[s + k].info.nsamp = 0;
                        k += 1;
                    }
                    return 0;
                }
                b = 4 * nn;
                d = 3;
            }
            24 => {
                if nn > u32::MAX / 3 {
                    return self.overflow(g);
                }
                b = 3 * nn;
            }
            32 => {
                if nn > u32::MAX / 4 {
                    return self.overflow(g);
                }
                b = 4 * nn;
            }
            _ => b = nn, // 8, 80
        }

        let st = &self.sig;
        let start = st.igd[gu].start;
        if b == 0
            || t > i64::MAX / b as i64
            || t.wrapping_mul(b as i64) / d as i64 > i64::MAX - start
        {
            return self.seekerr(g);
        }

        let mut nb: i64;
        let st = &mut self.sig;
        let ibsize = st.ibsize;
        let ig = &mut st.igd[gu];
        // Seek to the beginning of the block which contains the desired
        // sample. For normal files, use fseek() to do so.
        if ig.seek != 0 {
            let tt = t * b as i64;
            nb = tt / d as i64 + ig.start;
            let mut i = ig.bsize;
            if i == 0 {
                i = ibsize as i64;
            }
            // Seek to a position such that the next block read will contain
            // the desired sample.
            let tt = nb / i;
            let ok = match &mut ig.fp {
                Some(f) => f.seek(tt * i, SEEK_SET) == 0,
                None => false,
            };
            if !ok {
                return self.seekerr(g);
            }
            nb %= i;
        } else {
            // For special files, rewind if necessary and then read ahead.
            let istime = self.sig.istime;
            let ig = &mut self.sig.igd[gu];
            // Get the time of the earliest buffered sample ...
            let t0 = istime - ig.bp as i64 / b as i64;
            // ... and that of the earliest unread sample.
            let t1 = t0 + ig.be as i64 / b as i64;
            // Either the desired sample has been read and has passed out of
            // the buffer, requiring a rewind ...
            if t < t0 {
                let ok = match &mut ig.fp {
                    Some(f) => f.seek(0, SEEK_SET) == 0,
                    None => false,
                };
                if !ok {
                    return self.seekerr(g);
                }
                let tt = t * b as i64;
                nb = tt / d as i64 + ig.start;
            }
            // ... or it is in the buffer already ...
            else if t < t1 {
                let tt = (t - t0) * b as i64;
                ig.bp = (tt / d as i64) as usize;
                return 0;
            }
            // ... or it has not yet been read.
            else {
                let tt = (t - t1) * b as i64;
                nb = tt / d as i64;
            }
            let bs = ig.bsize.max(0) as usize;
            while nb > ig.bsize {
                let Some(f) = ig.fp.as_mut() else { break };
                if f.eof() {
                    break;
                }
                let n = bs.min(ig.buf.len());
                nb -= f.read(&mut ig.buf[..n]) as i64;
            }
        }

        let st = &mut self.sig;
        let ig = &mut st.igd[gu];
        // Reset the block pointer to indicate nothing has been read in the
        // current block.
        ig.bp = ig.be;
        ig.stat = 1;
        // Read any bytes in the current block that precede the desired
        // sample.
        while nb > 0 && ig.stat > 0 {
            nb -= 1;
            ig.r8();
        }
        if ig.stat <= 0 {
            return -1;
        }

        // Reset the getvec sample-within-frame counter.
        st.gvc = st.ispfmax as i32;

        // Reset the time (if signal 0 belongs to the group) and disable
        // checksum testing (by setting the number of samples remaining to 0).
        if s == 0 {
            st.istime = if st.in_msrec != 0 {
                t + st.segarray[st.segp as usize].samp0
            } else {
                t
            };
        }
        for k in 0..n {
            st.isd[s + k].info.nsamp = 0;
        }
        0
    }

    fn getskewedframe(&mut self, vecstart: &mut [i32]) -> i32 {
        let mut stat = self.sig.nisig as i32;
        if stat == 0 {
            return if self.sig.nvsig > 0 { -1 } else { 0 };
        }
        let nisig = self.sig.nisig as usize;
        if self.sig.istime == 0 {
            for is in &mut self.sig.isd[..nisig] {
                is.samp = is.info.initval;
            }
        }
        let mut g = self.sig.nigroup;
        while g > 0 {
            // Go through groups in reverse order since seeking on group 0
            // should always be done last.
            g -= 1;
            // A seek that opens another segment may leave fewer groups, or
            // fail and close the input signals: the allocated slots past
            // them are zeroed (no initial skip).  WFDB-x: a group number
            // past the allocated slots is reported as incorrect by
            // isgsetframe (C reads past its group array; see
            // docs/KNOWN_C_BEHAVIORS.md).
            if g as usize >= self.sig.igd.len() || self.sig.igd[g as usize].initial_skip != 0 {
                let t0 = if self.sig.in_msrec != 0 {
                    self.sig.segarray[self.sig.segp as usize].samp0
                } else {
                    0
                };
                self.isgsetframe(g, t0);
            }
        }
        // (the seek may have closed the input signals: see isigsettime)
        let nisig = self.sig.nisig as usize;
        if self.sig.empty_group {
            return -1; // WFDB-x (see isigopen)
        }

        // If the vector needs to be rearranged (variable-layout record),
        // then read samples into a temporary buffer.
        let need_sigmap = self.sig.need_sigmap != 0;
        let mut ovec = if need_sigmap {
            std::mem::take(&mut self.sig.ovec)
        } else {
            Vec::new()
        };
        let pad = (self.sig.gvmode & WFDB_GVPAD) != 0;
        let mut switch = false;
        {
            let target: &mut [i32] = if need_sigmap {
                &mut ovec
            } else {
                &mut *vecstart
            };
            let mut vi = 0usize;
            'sig: for s in 0..nisig {
                let (fmt, spf, group, mut cksum) = {
                    let is = &self.sig.isd[s];
                    (
                        is.info.fmt,
                        is.info.spf,
                        is.info.group as usize,
                        is.info.cksum,
                    )
                };
                // The lowest value of the format is its invalid-sample code
                // (not used by formats 0 and 8).
                let inval = fmt_range(fmt).0;
                for _c in 0..spf {
                    let v: i32;
                    match fmt {
                        0 => {
                            // null signal: return sample tagged as invalid
                            let st = &mut self.sig;
                            let is = &st.isd[s];
                            v = if pad { is.samp } else { WFDB_INVALID_SAMPLE };
                            target[vi] = v;
                            if is.info.nsamp == 0 {
                                st.igd[group].stat = -1;
                            }
                        }
                        16 => {
                            v = self.sig.igd[group].r16();
                        }
                        61 => {
                            v = self.sig.igd[group].r61();
                        }
                        80 => {
                            v = self.sig.igd[group].r80();
                        }
                        160 => {
                            v = self.sig.igd[group].r160();
                        }
                        212 => {
                            v = self.sig.igd[group].r212();
                        }
                        310 => {
                            v = self.sig.igd[group].r310();
                        }
                        311 => {
                            v = self.sig.igd[group].r311();
                        }
                        24 => {
                            v = self.sig.igd[group].r24();
                        }
                        32 => {
                            v = self.sig.igd[group].r32();
                        }
                        508 => {
                            v = self.flac_getsamp(group);
                        }
                        516 => {
                            v = self.flac_getsamp(group);
                        }
                        524 => {
                            v = self.flac_getsamp(group);
                        }
                        _ => {
                            // 8-bit first differences
                            let st = &mut self.sig;
                            let dv = st.igd[group].r8();
                            let is = &mut st.isd[s];
                            is.samp = is.samp.wrapping_add(dv);
                            v = is.samp;
                            target[vi] = v;
                        }
                    }
                    if !matches!(fmt, 0 | 8) && isfmt(fmt) {
                        let is = &mut self.sig.isd[s];
                        if v == inval {
                            target[vi] = if pad { is.samp } else { WFDB_INVALID_SAMPLE };
                        } else {
                            is.samp = v;
                            target[vi] = v;
                        }
                    }
                    if self.sig.igd[group].stat <= 0 {
                        // End of file -- reset input counter.
                        let st = &mut self.sig;
                        st.igd[group].count = 0;
                        if st.igd[group].stat == -2 {
                            // error in decoding compressed data
                            stat = -3;
                        } else if st.isd[s].info.nsamp > 0 {
                            let msg = cformat!(b"getvec: unexpected EOF in signal %d\n", s as i32);
                            self.wfdb_error(msg);
                            stat = -3;
                        } else if st.in_msrec != 0
                            && st.have_segarray
                            && st.segp >= 0
                            && st.segp < st.segend
                        {
                            st.isd[s].info.cksum = cksum;
                            switch = true;
                            break 'sig;
                        } else {
                            stat = -1;
                        }
                    }
                    cksum = cksum.wrapping_sub(v);
                    vi += 1;
                }
                let st = &mut self.sig;
                let is = &mut st.isd[s];
                is.info.cksum = cksum;
                if is.info.nsamp >= 0 {
                    is.info.nsamp -= 1;
                    if is.info.nsamp == 0
                        && (cksum & 0xffff) != 0
                        && st.in_msrec == 0
                        && st.isedf == 0
                        && fmt != 0
                    {
                        let msg = cformat!(b"getvec: checksum error in signal %d\n", s as i32);
                        // WFDB-x: not printed during a high-level read (it
                        // prints its own warning), but recorded
                        if self.sig.cksum_quiet {
                            self.wfdb_error_unprinted(msg);
                        } else {
                            self.wfdb_error(msg);
                        }
                        stat = -4;
                    }
                }
            }
        }
        if switch {
            if need_sigmap {
                self.sig.ovec = ovec;
            }
            self.sig.segp += 1;
            let name = self.sig.segarray[self.sig.segp as usize].recname.clone();
            let nvsig = self.sig.nvsig;
            if self.isigopen(&name, &mut [], nvsig) <= 0 {
                let msg = cformat!(b"getvec: error opening segment %s\n", name);
                self.wfdb_error(msg);
                return -3; // avoid looping if segment is bad
            }
            self.sig.istime = self.sig.segarray[self.sig.segp as usize].samp0;
            return self.getskewedframe(vecstart);
        }

        if need_sigmap {
            self.sigmap(vecstart, &ovec);
            self.sig.ovec = ovec;
        } else {
            let (framelen, tspf) = (self.sig.framelen as i32, self.sig.tspf);
            if framelen != tspf {
                for s in framelen.max(0)..tspf {
                    vecstart[s as usize] = WFDB_INVALID_SAMPLE;
                }
            }
        }
        stat
    }

    fn sigmap(&self, vector: &mut [i32], ivec: &[i32]) {
        let st = &self.sig;
        for i in 0..st.tspf.max(0) as usize {
            let m = &st.smi[i];
            // After a segment fails to open (sigmap_init: frame size too
            // large), an index can be past the end of ivec; C reads past its
            // buffer there, and finds 0 (as C++ does).
            let x = ivec.get(m.index as usize).copied().unwrap_or(0);
            if x == WFDB_INVALID_SAMPLE {
                vector[i] = WFDB_INVALID_SAMPLE;
            } else {
                // Scale the input sample and round it to the nearest integer
                // (halfway cases are rounded up; m.offset includes 0.5).
                let v = x as f64 * m.scale + m.offset;
                if m.sample_offset != 0 {
                    vector[i] = d2i(v).wrapping_add(m.sample_offset);
                } else if v >= 0.0 {
                    vector[i] = if v <= WFDB_SAMPLE_MAX as f64 {
                        v as i32
                    } else {
                        WFDB_SAMPLE_MAX
                    };
                } else if v >= WFDB_SAMPLE_MIN as f64 {
                    let mut r = v as i32;
                    if r as f64 > v {
                        r -= 1;
                    }
                    vector[i] = r;
                } else {
                    vector[i] = WFDB_SAMPLE_MIN;
                }
            }
        }
    }

    fn rgetvec(&mut self, vector: &mut [i32]) -> i32 {
        if self.sig.ispfmax < 2 {
            // all signals at the same frequency
            return self.getframe(vector);
        }
        let mut tv = std::mem::take(&mut self.sig.tvector);
        if (self.sig.gvmode & WFDB_HIGHRES) != WFDB_HIGHRES {
            // return one sample per frame, decimating by averaging if
            // necessary
            self.sig.rgetvec_stat = self.getframe(&mut tv);
            let st = &self.sig;
            let mut tp = 0usize;
            for s in 0..st.nvsig.max(0) as usize {
                let sf = st.vsd[s].info.spf;
                vector[s] = meansamp(&tv[tp..], sf);
                tp += sf as usize;
            }
        } else {
            // return ispfmax samples per frame, using zero-order
            // interpolation if necessary
            if self.sig.gvc >= self.sig.ispfmax as i32 {
                self.sig.rgetvec_stat = self.getframe(&mut tv);
                self.sig.gvc = 0;
            }
            let st = &mut self.sig;
            let ispfmax = st.ispfmax as i32;
            let gvc = st.gvc;
            let mut tp = 0usize;
            for s in 0..st.nvsig.max(0) as usize {
                let v = &mut st.vsd[s];
                let sf = v.info.spf;
                if gvc == 0 {
                    v.gvindex = 0;
                    v.gvcount = -ispfmax;
                } else {
                    v.gvcount += sf;
                    if v.gvcount >= 0 {
                        v.gvindex += 1;
                        v.gvcount -= ispfmax;
                    }
                }
                vector[s] = tv[tp + v.gvindex as usize];
                tp += sf as usize;
            }
            st.gvc += 1;
        }
        if self.sig.tvector.is_empty() {
            self.sig.tvector = tv;
        }
        self.sig.rgetvec_stat
    }

    // -----------------------------------------------------------------------
    // Opening output signals

    /// WFDB-x: whether the signal file `fname` of a header line names one of
    /// the signal files of the segment `seg` of the open multi-segment
    /// record (located as isigopen locates them in normal mode, without
    /// changing `hdr_dir`): a header or signal file that cannot be found, or
    /// is at a URL, is not. No message is printed.
    fn segment_has_file(&mut self, seg: &[u8], id: &FileId) -> bool {
        if seg == b"~" || !in_header_dir(seg) || self.sig.msrec_dir.as_deref().is_some_and(is_url) {
            return false;
        }
        let hf = match self.sig.msrec_name.clone() {
            Some(name) => {
                let dir = self.sig.msrec_dir.clone();
                self.wfdbx_open_in(dir.as_deref(), "hea", seg, &name)
            }
            None => self.wfdb_open("hea", seg, WFDB_READ),
        };
        let Some(mut hf) = hf else {
            return false;
        };
        let dir = if hf.is_std() || hf.is_remote() {
            None
        } else {
            Some(crate::wfdbio::wfdbx_dirname(self.wfdb_filename()))
        };
        let mut line = Vec::new();
        let mut nsig: i64 = -1;
        while nsig != 0 && hf.getline(&mut line) > 0 {
            let mut tok = line
                .split(|c| matches!(c, b' ' | b'\t' | b'\n' | b'\r'))
                .filter(|t| !t.is_empty());
            let Some(p) = tok.next() else { continue };
            if p[0] == b'#' {
                continue;
            }
            if nsig < 0 {
                // the record line
                nsig = match tok.next() {
                    Some(q) if !p.contains(&b'/') => strtol10(q),
                    _ => 0, // not a valid segment
                };
                if nsig <= 0 {
                    break;
                }
                continue;
            }
            nsig -= 1; // a signal line: file name, format, ...
            let fmt = tok.next().map_or(0, strtol10);
            let Some(d) = dir.as_deref() else { continue };
            if fmt == 0 || p == b"-" || !in_header_dir(p) || is_url(d) {
                continue;
            }
            let p = p.to_vec();
            if let Some(sf) = self.wfdbx_open_in(Some(d), crate::wfdb::NULL, &p, seg) {
                if sf.file_id().as_ref() == Some(id) {
                    return true;
                }
            }
        }
        false
    }

    /// WFDB-x: whether the output signal file `fname` (as named in an output
    /// signal specification, created by `wfdb_open(fname, NULL,
    /// WFDB_WRITE)`) exists and is one of the signal files of the open input
    /// record: an open input signal file, or a signal file of a segment of
    /// the open multi-segment record. Files are compared by identity (device
    /// and inode numbers), not by name.
    fn is_input_file(&mut self, fname: &[u8]) -> bool {
        let Some(id) = self.wfdbx_output_file(fname).and_then(|p| path_id(&p)) else {
            return false; // it does not exist: it is not an input file
        };
        let ng = (self.sig.nigroup as usize).min(self.sig.igd.len());
        if self.sig.igd[..ng]
            .iter()
            .any(|g| g.fp.as_ref().and_then(WfdbFile::file_id).as_ref() == Some(&id))
        {
            return true;
        }
        if self.sig.in_msrec != 0 && self.sig.have_segarray {
            let end = (self.sig.segend + 1).max(0) as usize;
            let segs: Vec<Vec<u8>> = self.sig.segarray[..end.min(self.sig.segarray.len())]
                .iter()
                .map(|sg| cstd::cstr(&sg.recname).to_vec())
                .collect();
            return segs.iter().any(|seg| self.segment_has_file(seg, &id));
        }
        false
    }

    fn openosig(
        &mut self,
        func: &[u8],
        mut si_out: Option<&mut [Siginfo]>,
        si_in: &[Siginfo],
        nsig: u32,
    ) -> i32 {
        if nsig == 0 {
            return 0;
        }
        let nsig_u = nsig as usize;
        {
            let st = &mut self.sig;
            // Allocate workspace for output signals and signal groups.
            let n = st.nosig as usize + nsig_u;
            if st.osd.len() < n {
                st.osd.resize(n, OsData::default());
            }
            let n = st.nogroup as usize + si_in[nsig_u - 1].group as usize + 1;
            while st.ogd.len() < n {
                st.ogd.push(OgData::default());
            }
            // Initialize local variables.
            if st.obsize <= 0 {
                st.obsize = WFDB_BUFSIZ;
            }
        }
        // Set the group number adjustment.
        let ga = self.sig.nogroup;

        // Open the signal files. One signal is handled per iteration.
        let mut s = 0usize;
        while s < nsig_u {
            let st = &mut self.sig;
            let osi = st.nosig as usize;
            let op = if s == 0 { osi } else { osi - 1 };
            let mut info = si_in[s].clone();
            if info.spf < 1 {
                info.spf = 1;
            }
            info.cksum = 0;
            info.nsamp = 0;
            info.group = info.group.wrapping_add(ga);
            if let Some(out) = si_out.as_deref_mut() {
                if s < out.len() {
                    out[s] = info.clone();
                }
            }
            st.osd[osi].info = info;
            st.osd[osi].samp = 0;

            // Check if this signal is in the same group as the previous one.
            if s == 0 || st.osd[osi].info.group != st.osd[op].info.group {
                let gi = st.osd[osi].info.group as usize;
                while st.ogd.len() < gi + 1 {
                    st.ogd.push(OgData::default());
                }
                st.ogd[gi].bsize = st.osd[osi].info.bsize;
                if isflacfmt(st.osd[osi].info.fmt) {
                    let mut ns = 1usize;
                    while s + ns < nsig_u && si_in[s + ns].group == si_in[s].group {
                        ns += 1;
                    }
                    if self.flac_osinit(gi, &si_in[s..s + ns], ns as u32) < 0 {
                        self.osigclose();
                        return -3;
                    }
                }
                let st = &mut self.sig;
                let og = &mut st.ogd[gi];
                let obuflen = if og.bsize != 0 { og.bsize } else { st.obsize } as usize;
                // This is the first signal in a new group; allocate buffer.
                og.buf = vec![0u8; obuflen];
                og.bp = 0;
                og.be = obuflen;
                let os = &mut st.osd[osi];
                if os.info.fmt == 0 {
                    // If the signal file name was NULL or "~", don't create
                    // a signal file.
                    match &os.info.fname {
                        None => og.fp = None,
                        Some(f) if cstd::cstr(f) == b"~" => og.fp = None,
                        // Otherwise, assume that the user wants to write a
                        // signal file in the default format (16).
                        _ => os.info.fmt = 16,
                    }
                }
                if os.info.fmt != 0 {
                    let fname = os.info.fname.clone();
                    // WFDB-x: never an input file (see is_input_file)
                    if !self.sig.legacy
                        && self.is_input_file(fname.as_deref().map_or(&b""[..], cstd::cstr))
                    {
                        let msg =
                            cformat!(b"%s: output file %s is also an input file\n", func, fname);
                        self.wfdb_error(msg);
                        self.sig.ogd[gi].buf = Vec::new();
                        self.osigclose();
                        return -3;
                    }
                    // An error in opening an output file is fatal.
                    let f = self.wfdb_open(
                        fname.as_ref().map(|v| cstd::cstr(v)),
                        crate::wfdb::NULL,
                        WFDB_WRITE,
                    );
                    let st = &mut self.sig;
                    match f {
                        Some(f) => st.ogd[gi].fp = Some(f),
                        None => {
                            st.ogd[gi].fp = None;
                            let msg = cformat!(b"%s: can't open %s\n", func, fname);
                            self.wfdb_error(msg);
                            self.sig.ogd[gi].buf = Vec::new();
                            self.osigclose();
                            return -3;
                        }
                    }
                }
                let st = &mut self.sig;
                if isflacfmt(st.osd[osi].info.fmt)
                    && st.ogd[gi].flac.is_some()
                    && st.ogd[gi].flac_osopen() < 0
                {
                    self.osigclose();
                    return -3;
                }
                self.sig.nogroup += 1;
            } else {
                // This signal belongs to the same group as the previous one.
                if st.osd[osi].info.fmt != st.osd[op].info.fmt
                    || st.osd[osi].info.bsize != st.osd[op].info.bsize
                {
                    let msg = cformat!(
                        b"%s: error in specification of signal %d or %d\n",
                        func,
                        s as i32 - 1,
                        s as i32
                    );
                    self.wfdb_error(msg);
                    return -2;
                }
            }
            self.sig.nosig += 1;
            s += 1;
        }
        s as i32
    }
}

// ---------------------------------------------------------------------------
// Hooks used by wfdbinit.rs

impl Wfdb {
    /// `wfdb_sampquit()`: release the `sample()` buffer (called by
    /// `wfdbquit`).
    pub(crate) fn wfdb_sampquit(&mut self) {
        let st = &mut self.sig;
        if st.have_sbuf {
            st.sbuf = Vec::new();
            st.have_sbuf = false;
            st.sample_vflag = 0;
        }
    }

    /// `wfdb_sigclose()`: close all signals and reset the signal state
    /// (called by `wfdbquit`).
    pub(crate) fn wfdb_sigclose(&mut self) {
        self.isigclose();
        self.osigclose();
        let st = &mut self.sig;
        st.btime = 0;
        st.bdate = 0;
        st.nsamples = 0;
        st.msbtime = 0;
        st.msbdate = 0;
        st.msnsamples = 0;
        st.sfreq = 0.0;
        st.ifreq = 0.0;
        st.ffreq = 0.0;
        st.pdays = -1;
        st.segments = 0;
        st.in_msrec = 0;
        st.msrec_dir = None; // WFDB-x
        st.msrec_name = None;
        st.hdr_dir = None;
        st.skewmax = 0;
        if st.have_dsbuf {
            st.dsbuf = Vec::new();
            st.have_dsbuf = false;
            st.dsbi = -1;
        }
        if st.have_segarray {
            st.segarray = Vec::new();
            st.have_segarray = false;
            st.segp = -1;
            st.segend = -1;
        }
        st.gv0 = Vec::new();
        st.gv1 = Vec::new();
        st.tvector = Vec::new();
        st.uvector = Vec::new();
        st.vvector = Vec::new();
        st.tuvlen = 0;
        self.sigmap_cleanup();
    }

    /// `wfdb_osflush()`: write out buffered output samples (called by
    /// `wfdbflush`).
    pub(crate) fn wfdb_osflush(&mut self) {
        let st = &mut self.sig;
        if st.osd.is_empty() || st.ogd.is_empty() {
            return;
        }
        let obsize = st.obsize;
        let n = (st.nosig as usize).min(st.osd.len());
        for s in 0..n {
            let g = st.osd[s].info.group as usize;
            if g >= st.ogd.len() {
                continue;
            }
            let fmt = st.osd[s].info.fmt;
            let og = &mut st.ogd[g];
            if og.nrewind == 0 {
                if og.force_flush == 0 && og.seek == 0 {
                    let seekable = og.bsize == 0
                        && match &mut og.fp {
                            Some(f) => f.seek(0, SEEK_CUR) == 0,
                            None => false,
                        };
                    og.seek = if seekable { 1 } else { -1 };
                }
                if og.force_flush != 0 || og.seek > 0 {
                    // Either we are closing the file (osigclose() was
                    // called), or the file is seekable: write out any
                    // partially-completed sets of bit-packed samples.
                    match fmt {
                        212 => og.f212(obsize),
                        310 => og.f310(obsize),
                        311 => og.f311(obsize),
                        _ => {}
                    }
                }
            }
        }
        let n = (st.nogroup as usize).min(st.ogd.len());
        for og in &mut st.ogd[..n] {
            if og.bsize == 0 && og.bp != 0 {
                if let Some(f) = &mut og.fp {
                    f.write(&og.buf[..og.bp]);
                }
                og.bp = 0;
            }
            if let Some(f) = &mut og.fp {
                f.flush();
                if og.force_flush == 0 && og.nrewind != 0 {
                    // Rewind the file so that subsequent samples will be
                    // written in the right place.
                    f.seek(-(og.nrewind as i64), SEEK_CUR);
                    og.nrewind = 0;
                }
            }
        }
    }

    /// `wfdb_oinfoclose()`: close the output info file (called by
    /// `wfdbquit`).
    pub(crate) fn wfdb_oinfoclose(&mut self) -> i32 {
        let mut stat = 0;
        if self.sig.outinfo == OutInfo::File {
            if let Some(f) = self.sig.outinfo_file.take() {
                let mut errflag = f.error();
                if f.close() != 0 {
                    errflag = true;
                }
                if errflag {
                    self.wfdb_error("setinfo: write error in info file\n");
                    stat = -2;
                }
            }
        }
        self.sig.outinfo_file = None;
        self.sig.outinfo = OutInfo::None;
        stat
    }

    /// The number of values `getvec`/`getframe` may store.
    fn vec_need(&self) -> usize {
        let st = &self.sig;
        (st.tspf
            .max(st.nvsig)
            .max(st.nisig as i32)
            .max(st.framelen as i32))
        .max(0) as usize
    }
}

// ---------------------------------------------------------------------------
// WFDB library functions

impl Wfdb {
    /// C `isigopen(record, siarray, nsig)`: opens the input signals of a
    /// record.
    ///
    /// The header of `record` is found as [`Wfdb::wfdb_open`] finds files
    /// (WFDB-x: the signal files it names are in its directory; legacy mode:
    /// all are found in the WFDB path), and up to `nsig` signals are
    /// opened; `siarray` receives their [`Siginfo`]. Input
    /// signals open before are closed first, unless the record name begins
    /// with `+`. With `nsig <= 0`, up to `-nsig` elements of `siarray` are
    /// filled in from the header, without opening the signals (with
    /// `nsig == 0` and an empty `siarray`, as C's `NULL`, this gives the
    /// number of signals of the record).
    ///
    /// # Returns
    ///
    /// The number of signals of the record (`> 0`), or: 0 if there are no
    /// input signals, -1 if the header cannot be read, -2 if the header is
    /// incorrect, -3 if the signal files cannot be opened (internal limits
    /// exceeded).
    ///
    /// Translation of the C function isigopen() (lib/signal.c, WFDB 10.7.0):
    /// same arguments and results. Differences: the signal files and segments
    /// named in the header are read only from the header's directory, and no
    /// sampling frequency, gain, ADC resolution or units are assumed; see
    /// docs/DIVERGENCES.md.
    pub fn isigopen(&mut self, record: impl OptBytes, siarray: &mut [Siginfo], nsig: i32) -> i32 {
        let rec_arg = record.opt_bytes().map(cstd::cstr).unwrap_or(b"").to_vec();
        let mut nsig = nsig;
        let mut first_segment = false;

        // Close previously opened input signals unless otherwise requested.
        let rec_arg: &[u8] = if rec_arg.first() == Some(&b'+') {
            &rec_arg[1..]
        } else {
            self.isigclose();
            &rec_arg
        };

        // Remove trailing .hea, if any, from record name.
        let record = wfdb_striphea(rec_arg);

        // Save the current record name.
        if self.sig.in_msrec == 0 {
            self.wfdb_setirec(&record);
        }

        // Read the header and determine how many signals are available.
        let mut navail = self.readheader(&record);
        if navail <= 0 {
            if navail == 0 && self.sig.segments != 0 {
                // this is a multi-segment record
                self.sig.in_msrec = 1;
                first_segment = true;
                // Open the first segment to get signal information.
                if self.sig.have_segarray && self.sig.segp >= 0 {
                    let name = self.sig.segarray[self.sig.segp as usize].recname.clone();
                    navail = self.readheader(&name);
                    if navail >= 0 {
                        let st = &mut self.sig;
                        if st.msbtime == 0 {
                            st.msbtime = st.btime;
                        }
                        if st.msbdate == 0 {
                            st.msbdate = st.bdate;
                        }
                    }
                }
                if nsig <= 0 {
                    self.sig.in_msrec = 0;
                }
            }
            if navail == 0 && nsig != 0 {
                let msg = cformat!(b"isigopen: record %s has no signals\n", record);
                self.wfdb_error(msg);
            }
            if navail <= 0 {
                return navail;
            }
        }

        // If nsig <= 0, isigopen fills in up to (-nsig) members of siarray
        // based on the contents of the header, but no signals are actually
        // opened.
        if nsig <= 0 {
            nsig = nsig.wrapping_neg();
            if navail < nsig {
                nsig = navail;
            }
            for s in 0..(nsig.max(0) as usize).min(siarray.len()) {
                siarray[s] = self.sig.hsd[s].info.clone();
            }
            self.sig.in_msrec = 0; // necessary to avoid errors when reopening
            return navail;
        }

        // Determine how many new signals we should attempt to open.
        if nsig > navail {
            nsig = navail;
        }

        // Allocate input signals and signal group workspace.
        {
            let st = &mut self.sig;
            let nn = st.nisig as usize + nsig as usize;
            if st.isd.len() < nn {
                st.isd.resize(nn, IsData::default());
            }
            let mut nn = st.nigroup as usize + st.hsd[navail as usize - 1].info.group as usize + 1;
            if nn > st.nigroup as usize + nsig as usize {
                nn = st.nigroup as usize + nsig as usize;
            }
            while st.igd.len() < nn {
                st.igd.push(IgData::default());
            }

            // Set default buffer size (if not set already by setibsize).
            if st.ibsize <= 0 {
                st.ibsize = WFDB_BUFSIZ;
            }
        }

        // Open the signal files. One signal group is handled per iteration.
        // In this loop, si counts through the entries that have been read
        // from hsd, and s counts the entries that have been added to isd.
        let navail_u = navail as usize;
        let nsig_u = nsig as usize;
        let (mut g, mut si, mut s) = (0usize, 0usize, 0usize);
        while si < navail_u && s < nsig_u {
            let st = &mut self.sig;
            // Find out how many signals are in this group.
            let mut sj = si + 1;
            while sj < navail_u && st.hsd[sj].info.group == st.hsd[si].info.group {
                sj += 1;
            }

            // Skip this group if there are too few slots in the caller's
            // array.
            if sj - si > nsig_u - s {
                si = sj;
                continue;
            }

            let gi = st.nigroup as usize + g;
            let ibsize = st.ibsize;
            {
                let hs = &mut st.hsd[si];
                let ig = &mut st.igd[gi];
                // Set the buffer size and the seek capability flag.
                if hs.info.bsize < 0 {
                    // WFDB-x: -2147483648 gives 2147483648 (C overflows)
                    ig.bsize = -(hs.info.bsize as i64);
                    hs.info.bsize = hs.info.bsize.saturating_neg();
                    ig.seek = 0;
                } else {
                    ig.bsize = hs.info.bsize as i64;
                    if ig.bsize == 0 {
                        ig.bsize = ibsize as i64;
                    }
                    ig.seek = 1;
                }
                // (allocated once the size of the signal file is known)
                ig.buf = Vec::new();
                ig.flac = None;
                ig.data = 0;
                ig.datb = 0;
                ig.count = 0;
            }

            // Check that the signal file is readable.
            let fmt = st.hsd[si].info.fmt;
            if fmt == 0 {
                st.igd[gi].fp = None; // Don't open a file for a null signal.
            } else {
                let fname = st.hsd[si].info.fname.clone();
                let fname = fname.as_ref().map(|v| cstd::cstr(v));
                // WFDB-x: in the directory of the header
                let f = if self.sig.legacy {
                    self.wfdb_open(fname, crate::wfdb::NULL, WFDB_READ)
                } else {
                    let dir = self.sig.hdr_dir.clone();
                    self.wfdbx_open_in(
                        dir.as_deref(),
                        crate::wfdb::NULL,
                        fname.unwrap_or(b""),
                        &record,
                    )
                };
                let ig = &mut self.sig.igd[gi];
                ig.fp = f;
                // Skip this group if the signal file can't be opened.
                if ig.fp.is_none() {
                    ig.buf = Vec::new();
                    si = sj;
                    continue;
                }
                // WFDB-x: a buffer no larger than the file (a block can be
                // larger), so reads and seeks are the same
                let mut n = ig.bsize.max(0) as u64;
                if let Some(size) = ig.fp.as_ref().and_then(WfdbFile::local_size) {
                    if size > 0 {
                        n = n.min(size);
                    }
                }
                ig.buf = vec![0u8; n as usize];
            }

            if isflacfmt(fmt) && self.flac_isopen(gi, si, (sj - si) as u32) < 0 {
                let ig = &mut self.sig.igd[gi];
                ig.buf = Vec::new();
                ig.fp = None;
                ig.flac = None;
                si = sj;
                continue;
            }

            // All tests passed -- fill in remaining data for this group.
            let st = &mut self.sig;
            let nisig = st.nisig as usize;
            let nigroup = st.nigroup;
            {
                let ig = &mut st.igd[gi];
                ig.bp = ig.bsize.max(0) as usize;
                ig.be = ig.bp;
                ig.start = st.hsd[si].start;
                ig.initial_skip = (ig.start > 0) as i32;
                ig.stat = 1;
            }
            while si < sj && s < nsig_u {
                let is = &mut st.isd[nisig + s];
                is.info = st.hsd[si].info.clone();
                is.info.group = nigroup + g as u32;
                is.skew = st.hsd[si].skew;
                s += 1;
                si += 1;
            }
            si = sj;
            g += 1;
        }

        // Produce a warning message if none of the requested signals could
        // be opened.
        if s == 0 && nsig != 0 {
            let msg = cformat!(
                b"isigopen: none of the signals for record %s is readable\n",
                record
            );
            self.wfdb_error(msg);
        }

        // Check that the total number of samples per frame is less than or
        // equal to INT_MAX.
        {
            let st = &self.sig;
            let mut spflimit = INT_MAX.wrapping_sub(st.framelen as i32);
            for k in 0..s {
                spflimit = spflimit.wrapping_sub(st.isd[st.nisig as usize + k].info.spf);
                if spflimit < 0 {
                    let msg = cformat!(
                        b"isigopen: total frame size too large in record %s\n",
                        record
                    );
                    self.wfdb_error(msg);
                    self.isigclose();
                    return -3;
                }
            }
        }

        // Copy the WFDB_Siginfo structures to the caller's array. Use these
        // data to construct the initial sample vector, and to determine the
        // maximum number of samples per signal per frame and the maximum
        // skew.
        {
            let st = &mut self.sig;
            let nisig = st.nisig as usize;
            for k in 0..s {
                let is = &mut st.isd[nisig + k];
                if k < siarray.len() {
                    siarray[k] = is.info.clone();
                }
                is.samp = is.info.initval;
                if st.ispfmax < is.info.spf as u32 {
                    st.ispfmax = is.info.spf as u32;
                }
                if st.skewmax < is.skew as u32 {
                    st.skewmax = is.skew as u32;
                }
            }
            st.nisig += s as u32; // Update the count of open input signals.
            st.nigroup += g as u32; // Update the count of open input groups.
        }
        if self.sigmap_init(first_segment) < 0 {
            self.isigclose();
            return -3;
        }
        self.sig.spfmax = self.sig.ispfmax as i32;
        let m = self.sig.gvmode;
        self.setgvmode(m); // Reset sfreq if appropriate.
        let st = &mut self.sig;
        st.gvc = st.ispfmax as i32; // Initialize getvec's counter.

        // Determine the total number of samples per frame.
        st.framelen = 0;
        for k in 0..st.nisig as usize {
            st.framelen = st.framelen.wrapping_add(st.isd[k].info.spf as u32);
        }
        // WFDB-x: a signal group whose frames hold no samples
        st.empty_group = (0..st.nigroup as usize).any(|g| {
            let mut sig = st.isd[..st.nisig as usize]
                .iter()
                .filter(|is| is.info.group as usize == g && is.info.fmt != 0);
            sig.clone().next().is_some() && sig.all(|is| is.info.spf == 0)
        });

        // Allocate workspace for getvec, isgsettime, and tnextvec.
        if st.tspf > st.tuvlen {
            let n = st.tspf as usize;
            st.tvector = vec![0; n];
            st.uvector = vec![0; n];
            st.vvector = vec![0; n];
            st.tuvlen = st.tspf;
        }

        // If deskewing is required, allocate the deskewing buffer (unless
        // this is a multi-segment record and dsbuf has been allocated
        // already).
        if st.skewmax != 0 && (st.in_msrec == 0 || !st.have_dsbuf) {
            if st.tspf > (INT_MAX as u32 / (st.skewmax + 1)) as i32 {
                let msg = cformat!(b"isigopen: maximum skew too large in record %s\n", record);
                self.wfdb_error(msg);
                self.isigclose();
                return -3;
            }
            st.dsbi = -1; // mark buffer contents as invalid
            st.dsblen = (st.tspf as u32).wrapping_mul(st.skewmax + 1);
            st.dsbuf = vec![0; st.dsblen as usize];
            st.have_dsbuf = true;
        }
        s as i32
    }

    /// C `osigopen(record, siarray, nsig)`: opens output signals as
    /// described by the header of an existing record `record` (signal files,
    /// formats, gains, ...); `siarray` receives their [`Siginfo`].
    ///
    /// # Returns
    ///
    /// The number of output signals opened (`> 0`; it should be `nsig`),
    /// or: -1 if the header cannot be read, -2 if it is incorrect, -3 if
    /// the output signal files cannot be opened (or, WFDB-x, one of them is
    /// one of the input files, as for [`Wfdb::osigfopen`]).
    ///
    /// Translation of the C function osigopen() (lib/signal.c, WFDB 10.7.0):
    /// same arguments and results. Differences: an output signal file that is
    /// one of the input files of the open record is refused; see
    /// docs/DIVERGENCES.md.
    pub fn osigopen(&mut self, record: impl OptBytes, siarray: &mut [Siginfo], nsig: u32) -> i32 {
        let rec_arg = record.opt_bytes().map(cstd::cstr).unwrap_or(b"").to_vec();
        // Close previously opened output signals unless otherwise requested.
        let rec_arg: &[u8] = if rec_arg.first() == Some(&b'+') {
            &rec_arg[1..]
        } else {
            self.osigclose();
            &rec_arg
        };

        // Remove trailing .hea, if any, from record name.
        let record = wfdb_striphea(rec_arg);

        let n = self.readheader(&record);
        if n < 0 {
            return n;
        }
        if n < nsig as i32 {
            let msg = cformat!(
                b"osigopen: record %s has fewer signals than needed\n",
                record
            );
            self.wfdb_error(msg);
            return -3;
        }
        let hsi: Vec<Siginfo> = self.sig.hsd[..nsig as usize]
            .iter()
            .map(|h| h.info.clone())
            .collect();
        let out = if siarray.is_empty() {
            None
        } else {
            Some(siarray)
        };
        self.openosig(b"osigopen", out, &hsi, nsig)
    }

    /// C `osigfopen(siarray, nsig)`: opens output signals as described by
    /// the first `nsig` elements of `siarray` (file name, format, gain, ...),
    /// closing the output signals open before. With `nsig == 0`, only
    /// closes them.
    ///
    /// # Returns
    ///
    /// The number of output signals opened (`> 0`; it should be `nsig`),
    /// or: -2 if a signal specification is incorrect (file name or
    /// description too long, illegal format or block size, incorrect signal
    /// group), -3 if a signal file cannot be opened, or (WFDB-x, except in
    /// legacy mode) is one of the signal files of the open input record
    /// (`osigfopen: output file F is also an input file`; the file is not
    /// touched). With `nsig == 0` (or an empty `siarray`): 0, or -4 on a
    /// write error while closing the previous output signals.
    ///
    /// Translation of the C function osigfopen() (lib/signal.c, WFDB 10.7.0):
    /// same arguments and results. Differences: an output signal file that is
    /// one of the input files of the open record is refused; see
    /// docs/DIVERGENCES.md.
    pub fn osigfopen(&mut self, siarray: &[Siginfo], nsig: u32) -> i32 {
        // Close any open output signals.
        let stat = self.osigclose();

        // Do nothing further if there are no signals to open.
        if siarray.is_empty() || nsig == 0 {
            return stat;
        }
        let nsig = nsig.min(siarray.len() as u32);

        if self.sig.obsize <= 0 {
            self.sig.obsize = WFDB_BUFSIZ;
        }

        // Prescan siarray to check the signal specifications and to
        // determine the number of signal groups.
        for s in 0..nsig as usize {
            let si = &siarray[s];
            let lf = ostr(&si.fname).len();
            let ld = ostr(&si.desc).len();
            if lf + ld > MAXFDLEN || si.bsize < 0 || !isfmt(si.fmt) {
                let msg = cformat!(
                    b"osigfopen: error in specification of signal %d\n",
                    s as i32
                );
                self.wfdb_error(msg);
                return -2;
            }
            let f1 = ostr(&si.fname);
            let f0: &[u8] = if s > 0 {
                ostr(&siarray[s - 1].fname)
            } else {
                b""
            };
            let ok = (s == 0 && si.group == 0)
                || (s > 0 && si.group == siarray[s - 1].group && f1 == f0)
                || (s > 0 && si.group == siarray[s - 1].group.wrapping_add(1) && f1 != f0);
            if !ok {
                let msg = cformat!(
                    b"osigfopen: incorrect file name or group for signal %d\n",
                    s as i32
                );
                self.wfdb_error(msg);
                return -2;
            }
        }

        self.openosig(b"osigfopen", None, siarray, nsig)
    }

    /// C `findsig(p)`: returns the number of the input signal whose
    /// description is `p` (or whose number is `p`, a decimal number), or -1
    /// if there is none.
    ///
    /// Translation of the C function findsig() (lib/signal.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn findsig(&mut self, p: impl AsRef<[u8]>) -> i32 {
        let p = cstd::cstr(p.as_ref());
        let st = &self.sig;
        if p.iter().all(u8::is_ascii_digit) {
            // all digits, probably a signal number
            let s = strtol10(p) as i32;
            if (s as u32) < st.nisig || s < st.nvsig {
                return s;
            }
        }
        // Otherwise, p is either an integer too large to be a signal number
        // or a string containing a non-digit character. Assume it's a
        // signal name.
        if st.need_sigmap != 0 {
            for s in 0..st.nvsig.max(0) as usize {
                if let Some(d) = &st.vsd[s].info.desc {
                    if cstd::cstr(d) == p {
                        return s as i32;
                    }
                }
            }
        } else {
            for s in 0..st.nisig as usize {
                if let Some(d) = &st.isd[s].info.desc {
                    if cstd::cstr(d) == p {
                        return s as i32;
                    }
                }
            }
        }
        -1
    }

    /// C `getspf()`: the number of samples per frame returned by `getvec`
    /// for each signal (1 unless in `WFDB_HIGHRES` mode).
    ///
    /// Translation of the C function getspf() (lib/signal.c, WFDB 10.7.0): same
    /// arguments and results.
    pub fn getspf(&mut self) -> i32 {
        let st = &self.sig;
        if st.sfreq != st.ffreq {
            d2i(st.sfreq / st.ffreq + 0.5)
        } else {
            1
        }
    }

    /// C `setgvmode(mode)`: set the getvec mode ([`WFDB_LOWRES`] or
    /// [`WFDB_HIGHRES`], optionally with [`WFDB_GVPAD`]); a negative mode
    /// selects the default (from `WFDBGVMODE`).
    ///
    /// Translation of the C function setgvmode() (lib/signal.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn setgvmode(&mut self, mut mode: i32) {
        if mode < 0 {
            // (re)set to default mode
            mode = match cstd::getenv("WFDBGVMODE") {
                Some(p) => strtol10(&p) as i32,
                None => DEFWFDBGVMODE,
            };
        }
        let st = &mut self.sig;
        st.gvmode = mode & (WFDB_HIGHRES | WFDB_GVPAD);
        if (mode & WFDB_HIGHRES) == WFDB_HIGHRES {
            if st.spfmax == 0 {
                st.spfmax = 1;
            }
            st.sfreq = st.ffreq * st.spfmax as f64;
        } else {
            st.sfreq = st.ffreq;
        }
    }

    /// C `getgvmode()`: the current `getvec` mode ([`WFDB_LOWRES`] or
    /// [`WFDB_HIGHRES`], with [`WFDB_GVPAD`] if invalid samples are
    /// replaced).
    ///
    /// Translation of the C function getgvmode() (lib/signal.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn getgvmode(&mut self) -> i32 {
        self.sig.gvmode
    }

    /// C `setifreq(f)`: sets the sampling frequency at which `getvec`
    /// returns the input signals; they are resampled (by linear
    /// interpolation) to `f` Hz. A record must be open.
    ///
    /// # Returns
    ///
    /// 0 on success, or -1 if no input record is open, its sampling
    /// frequency is not specified (WFDB-x), or `f` is not positive
    /// (resampling is then turned off).
    ///
    /// Translation of the C function setifreq() (lib/signal.c, WFDB 10.7.0):
    /// same arguments and results. Differences: it fails if the sampling
    /// frequency of the input record is not specified; see
    /// docs/DIVERGENCES.md.
    pub fn setifreq(&mut self, f: f64) -> i32 {
        let mut f = f;
        let mut g = self.sig.sfreq;
        if g <= 0.0 {
            self.sig.ifreq = 0.0;
            if self.sig.nisig > 0 && !self.sig.legacy {
                // WFDB-x: the frequency is unspecified
                self.wfdb_error("setifreq: sampling frequency is not specified\n");
            } else {
                self.wfdb_error("setifreq: no open input record\n");
            }
            return -1;
        }
        if f > 0.0 {
            {
                let st = &mut self.sig;
                let mut n = st.nvsig.max(st.nisig as i32);
                if n < st.tspf {
                    n = st.tspf;
                }
                let n = n.max(1) as usize;
                if st.gv0.len() < n {
                    st.gv0.resize(n, 0);
                }
                if st.gv1.len() < n {
                    st.gv1.resize(n, 0);
                }
                st.ifreq = f;
            }
            self.setafreq(f);
            // Euclid's algorithm for the GCD of sfreq and ifreq (in
            // multiples of 0.005 Hz, the maximum tolerable error in the
            // resampling frequency).
            loop {
                let error = f - g;
                if !(error > 0.005 || error < -0.005) {
                    break;
                }
                if f > g {
                    f -= g;
                } else {
                    g -= f;
                }
            }
            let st = &mut self.sig;
            // f is now the GCD of sfreq and ifreq. Each raw sampling
            // interval is divided into mticks subintervals.
            st.mticks = d2l(st.sfreq / f + 0.5);
            // Each resampled interval is divided into nticks subintervals.
            st.nticks = d2l(st.ifreq / f + 0.5);
            // Raw and resampled intervals begin simultaneously once every
            // mnticks subintervals (an epoch).
            st.mnticks = st.mticks.wrapping_mul(st.nticks);
            // gvtime is the number of subintervals from the beginning of the
            // current epoch to the next sample to be returned by getvec().
            st.gvtime = 0;
            self.reload_gv();
            0
        } else {
            self.sig.ifreq = 0.0;
            let msg = cformat!(b"setifreq: improper frequency %g (must be > 0)\n", f);
            self.wfdb_error(msg);
            -1
        }
    }

    /// `rgvstat = rgetvec(gv0); rgvstat = rgetvec(gv1); rgvtime = nticks;`
    fn reload_gv(&mut self) {
        let mut g0 = std::mem::take(&mut self.sig.gv0);
        self.sig.rgvstat = self.rgetvec(&mut g0);
        self.sig.gv0 = g0;
        let mut g1 = std::mem::take(&mut self.sig.gv1);
        self.sig.rgvstat = self.rgetvec(&mut g1);
        self.sig.gv1 = g1;
        self.sig.rgvtime = self.sig.nticks;
    }

    /// C `getifreq()`: the sampling frequency of the samples returned by
    /// `getvec`.
    ///
    /// Translation of the C function getifreq() (lib/signal.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn getifreq(&mut self) -> f64 {
        let st = &self.sig;
        if st.ifreq > 0.0 {
            st.ifreq
        } else {
            st.sfreq
        }
    }

    /// C `getvec(vector)`: reads the next sample of each input signal into
    /// `vector` (one value per signal, in ADC units).
    ///
    /// Invalid or missing samples are [`WFDB_INVALID_SAMPLE`] unless the
    /// [`WFDB_GVPAD`] mode is set (see [`Wfdb::setgvmode`]).
    ///
    /// # Returns
    ///
    /// The number of input signals (`> 0`), or: 0 or -1 at the end of the
    /// record (the contents of `vector` are then not valid), -3 at an
    /// unexpected end of file (or on a decoding error), -4 on a checksum
    /// error (detected at the end of the file).
    ///
    /// Translation of the C function getvec() (lib/signal.c, WFDB 10.7.0): same
    /// arguments and results.
    pub fn getvec(&mut self, vector: &mut [i32]) -> i32 {
        let need = self.vec_need();
        if vector.len() < need {
            // (with the caller's values, which C leaves as they are where
            // it writes nothing, e.g. after the end of the record)
            let mut tmp = vec![0; need];
            tmp[..vector.len()].copy_from_slice(vector);
            let r = self.getvec_impl(&mut tmp);
            let n = vector.len();
            vector.copy_from_slice(&tmp[..n]);
            return r;
        }
        self.getvec_impl(vector)
    }

    fn getvec_impl(&mut self, vector: &mut [i32]) -> i32 {
        {
            let st = &self.sig;
            if st.ifreq == 0.0 || st.ifreq == st.sfreq {
                // no resampling necessary
                return self.rgetvec(vector);
            }
        }
        // Resample the input.
        let st = &mut self.sig;
        if st.rgvtime > st.mnticks {
            st.rgvtime -= st.mnticks;
            st.gvtime -= st.mnticks;
        }
        let nsig = st.nvsig.max(st.nisig as i32).max(0) as usize;
        while self.sig.gvtime > self.sig.rgvtime {
            let st = &mut self.sig;
            let (g0, g1) = (&mut st.gv0, &st.gv1);
            g0[..nsig].copy_from_slice(&g1[..nsig]);
            let mut g1 = std::mem::take(&mut st.gv1);
            self.sig.rgvstat = self.rgetvec(&mut g1);
            self.sig.gv1 = g1;
            self.sig.rgvtime += self.sig.nticks;
        }
        let st = &mut self.sig;
        let frac = st.gvtime % st.nticks;
        for i in 0..nsig {
            let (a, b) = (st.gv0[i], st.gv1[i]);
            vector[i] = (a as i64 + frac * (b.wrapping_sub(a) as i64) / st.nticks) as i32;
            st.gv0[i] = b;
        }
        st.gvtime += st.mticks;
        st.rgvstat
    }

    /// C `getframe(vector)`: reads the next frame: all the samples of every
    /// input signal in it (`spf` samples of a signal with `spf` samples per
    /// frame), signal after signal.
    ///
    /// # Returns
    ///
    /// As [`Wfdb::getvec`]: the number of input signals, or a value `<= 0`
    /// at the end of the record or on an error.
    ///
    /// Translation of the C function getframe() (lib/signal.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn getframe(&mut self, vector: &mut [i32]) -> i32 {
        let need = self.vec_need();
        if vector.len() < need {
            // (with the caller's values, which C leaves as they are where
            // it writes nothing, e.g. after the end of the record)
            let mut tmp = vec![0; need];
            tmp[..vector.len()].copy_from_slice(vector);
            let r = self.getframe_impl(&mut tmp);
            let n = vector.len();
            vector.copy_from_slice(&tmp[..n]);
            return r;
        }
        self.getframe_impl(vector)
    }

    fn getframe_impl(&mut self, vector: &mut [i32]) -> i32 {
        let mut stat = -1;
        if self.sig.have_dsbuf {
            // signals must be deskewed
            let mut ds = std::mem::take(&mut self.sig.dsbuf);
            let tspf = self.sig.tspf;
            let dsblen = self.sig.dsblen as i32;
            // First, obtain the samples needed.
            if self.sig.dsbi < 0 {
                // dsbuf contents are invalid -- refill dsbuf
                let mut i = 0i32;
                self.sig.dsbi = 0;
                while i < dsblen {
                    stat = self.getskewedframe(&mut ds[i as usize..]);
                    if stat < 0 {
                        break;
                    }
                    i += tspf;
                    self.sig.dsbi = i;
                }
                self.sig.dsbi = 0;
            } else {
                // replace oldest frame in dsbuf only
                let dsbi = self.sig.dsbi;
                stat = self.getskewedframe(&mut ds[dsbi as usize..]);
                self.sig.dsbi += tspf;
                if self.sig.dsbi >= dsblen {
                    self.sig.dsbi = 0;
                }
            }

            // Assemble the deskewed frame from the data in dsbuf.
            let st = &self.sig;
            let mut j = 0usize;
            for s in 0..st.nvsig.max(0) as usize {
                let mut i = j as i32 + st.dsbi + st.vsd[s].skew * tspf;
                if i >= dsblen {
                    i %= dsblen;
                }
                let mut i = i as usize;
                for _ in 0..st.vsd[s].info.spf {
                    vector[j] = ds[i];
                    j += 1;
                    i += 1;
                }
            }
            if self.sig.dsbuf.is_empty() {
                self.sig.dsbuf = ds;
            }
        } else {
            // no deskewing necessary
            stat = self.getskewedframe(vector);
        }
        self.sig.istime += 1;
        stat
    }

    /// WFDB-x: reads up to `n` sample vectors (at most as many as fit in
    /// `out`) at once, as whole frames, exactly as as many `getvec` calls
    /// would (`getskewedframe` calls and `istime` if `ispfmax < 2`), and
    /// returns their number (0 if the bulk path cannot be used for the next
    /// vector: the caller then reads it frame by frame). Records of several
    /// sampling frequencies (in high-resolution mode, from the start of a
    /// frame), the segments of multi-segment records (mapped by `sigmap` if
    /// the layout varies) and null signals of known length are read this
    /// way; the samples, checksums, counts, `gvc` and the last frames are
    /// left as `getvec` leaves them. Ported from `_bulk_frames` of the
    /// Python implementation, with one difference: only the complete frames
    /// already in the input buffers are decoded (see `bulk_unit`).
    fn bulk_frames(&mut self, out: &mut [i32], n: i64) -> usize {
        let st = &self.sig;
        let nisig = st.nisig as usize;
        // No deskewing, no resampling; every signal of the layout read (or
        // mapped to the layout signals).
        if st.bulk_off
            || n <= 0
            || nisig == 0
            || st.have_dsbuf
            || !(st.ifreq == 0.0 || st.ifreq == st.sfreq)
            || (st.nvsig != nisig as i32 && st.need_sigmap == 0)
            || st.isd.len() < nisig
        {
            return 0;
        }
        let highres = st.ispfmax > 1 && (st.gvmode & WFDB_HIGHRES) == WFDB_HIGHRES;
        if highres && st.gvc < st.ispfmax as i32 {
            return 0;
        }
        let mut groups = std::mem::take(&mut self.sig.bulk_groups);
        let m = self.bulk_frames_in(out, n, highres, &mut groups);
        self.sig.bulk_groups = groups;
        m
    }

    /// The work of `bulk_frames` (`groups`: storage for the signal groups).
    fn bulk_frames_in(
        &mut self,
        out: &mut [i32],
        n: i64,
        highres: bool,
        groups: &mut Vec<BulkGroup>,
    ) -> usize {
        let st = &mut self.sig;
        let nisig = st.nisig as usize;
        // The groups: one format each (0: null signals, no file), at the
        // start of a packed unit; the alignment period (in frames) keeps
        // each on whole packed units.
        groups.clear();
        let mut period = 1usize;
        let mut pos = 0usize;
        let mut s = 0usize;
        while s < nisig {
            let (fmt, g) = (st.isd[s].info.fmt, st.isd[s].info.group as usize);
            let ns = if fmt == 0 {
                1
            } else {
                match bulk_unit(fmt) {
                    Some((_, ns)) => ns,
                    None => return 0,
                }
            };
            let mut e = s;
            let mut gfl = 0usize;
            while e < nisig && st.isd[e].info.group as usize == g {
                let info = &st.isd[e].info;
                if info.fmt != fmt || info.spf < 1 || (fmt == 0 && info.nsamp <= 0) {
                    return 0;
                }
                gfl += info.spf as usize;
                e += 1;
            }
            let Some(ig) = st.igd.get(g) else {
                return 0;
            };
            if ig.initial_skip != 0 {
                return 0;
            }
            if fmt == 0 {
                if ig.stat <= 0 {
                    return 0;
                }
            } else {
                if ig.seek != 1 || ig.fp.is_none() || ig.count != 0 || ig.flac.is_some() {
                    return 0;
                }
                let p = ns / gcd(gfl % ns, ns);
                period = period / gcd(period, p) * p;
            }
            groups.push(BulkGroup {
                s0: s,
                s1: e,
                fmt,
                gfl,
                pos,
            });
            pos += gfl;
            s = e;
        }
        let (flen, tlen) = (pos, st.tspf.max(0) as usize);
        let need_sigmap = st.need_sigmap != 0;
        let frames = st.ispfmax < 2;
        let nv = st.nvsig.max(0) as usize;
        // Vectors per frame, and values per vector.
        let per = if highres { st.ispfmax as usize } else { 1 };
        let vlen = if frames { tlen } else { nv };
        if vlen == 0 || flen != st.framelen as usize || (!need_sigmap && flen > tlen) {
            return 0;
        }
        let mut nf = (n / per as i64).min((out.len() / (vlen * per)) as i64);
        // Not the frame at which a checksum is verified or a null signal
        // ends (nor any after it).
        for is in &st.isd[..nisig] {
            if is.info.nsamp > 0 && nf >= is.info.nsamp {
                nf = is.info.nsamp - 1;
            }
        }
        // Only the complete frames in every buffer.
        for gr in groups.iter().filter(|gr| gr.fmt != 0) {
            let (nb, ns) = bulk_unit(gr.fmt).unwrap_or((1, 1));
            let unit = period * gr.gfl * nb / ns;
            let ig = &st.igd[st.isd[gr.s0].info.group as usize];
            let avail = (ig.be.saturating_sub(ig.bp) / unit * period) as i64;
            nf = nf.min(avail);
        }
        nf -= nf % period as i64;
        if nf <= 0 {
            return 0;
        }
        let nf = nf as usize;
        if st.istime == 0 {
            for is in &mut st.isd[..nisig] {
                is.samp = is.info.initval;
            }
        }
        let pad = (st.gvmode & WFDB_GVPAD) != 0;
        // The frames as getskewedframe reads them (flen samples each) go
        // into `ibuf` if the layout varies; otherwise straight into the
        // frames as getframe gives them (tlen samples each): `out` if they
        // are the vectors of getvec (ispfmax < 2), else `fbuf`.
        let mut ibuf = std::mem::take(&mut st.bulk_in);
        let mut fbuf = std::mem::take(&mut st.bulk_fr);
        let mut raw = std::mem::take(&mut st.bulk_raw);
        if need_sigmap && ibuf.len() < nf * flen {
            ibuf.resize(nf * flen, 0);
        }
        if !frames && fbuf.len() < nf * tlen {
            fbuf.resize(nf * tlen, 0);
        }
        {
            let (inb, istride): (&mut [i32], usize) = if need_sigmap {
                (&mut ibuf[..nf * flen], flen)
            } else if frames {
                (&mut out[..nf * tlen], tlen)
            } else {
                (&mut fbuf[..nf * tlen], tlen)
            };
            for gr in groups.iter() {
                if gr.fmt == 0 {
                    // null signals
                    let mut c = gr.pos;
                    for is in &mut st.isd[gr.s0..gr.s1] {
                        let spf = is.info.spf as usize;
                        let v = if pad { is.samp } else { WFDB_INVALID_SAMPLE };
                        for f in 0..nf {
                            let b = f * istride + c;
                            inb[b..b + spf].fill(v);
                        }
                        is.info.cksum = is
                            .info
                            .cksum
                            .wrapping_sub(v.wrapping_mul((nf * spf) as i32));
                        c += spf;
                    }
                    continue;
                }
                let fmt = gr.fmt;
                let (nb, ns) = bulk_unit(fmt).unwrap_or((1, 1));
                let gfl = gr.gfl;
                let used = nf * gfl * nb / ns;
                let ig = &mut st.igd[st.isd[gr.s0].info.group as usize];
                let bytes = &ig.buf[ig.bp..ig.bp + used];
                let (diff, inval) = (fmt == 8, fmt_range(fmt).0);
                // Tile by tile (of whole packed units), signal by signal: the
                // tile's raw samples stay in the cache.
                let tile = BULK_TILE / period * period;
                if raw.len() < tile * gfl {
                    raw.resize(tile * gfl, 0);
                }
                let mut f0 = 0usize;
                while f0 < nf {
                    let m = tile.min(nf - f0);
                    let r = &mut raw[..m * gfl];
                    bulk_decode(fmt, &bytes[f0 * gfl * nb / ns..(f0 + m) * gfl * nb / ns], r);
                    let mut c = 0usize;
                    for is in &mut st.isd[gr.s0..gr.s1] {
                        let spf = is.info.spf as usize;
                        let o = &mut inb[f0 * istride + gr.pos + c..];
                        let (samp, cksum) = (&mut is.samp, &mut is.info.cksum);
                        if spf == 1 {
                            bulk_signal(
                                &r[c..],
                                gfl,
                                o,
                                istride,
                                m,
                                1,
                                diff,
                                inval,
                                pad,
                                samp,
                                cksum,
                            );
                        } else {
                            bulk_signal(
                                &r[c..],
                                gfl,
                                o,
                                istride,
                                m,
                                spf,
                                diff,
                                inval,
                                pad,
                                samp,
                                cksum,
                            );
                        }
                        c += spf;
                    }
                    f0 += m;
                }
                ig.bp += used;
            }
            if !need_sigmap && flen < tlen {
                for f in 0..nf {
                    inb[f * tlen + flen..(f + 1) * tlen].fill(WFDB_INVALID_SAMPLE);
                }
            }
        }
        for is in &mut st.isd[..nisig] {
            if is.info.nsamp > 0 {
                is.info.nsamp -= nf as i64;
            } else if is.info.nsamp == 0 {
                is.info.nsamp = -1;
            }
        }
        st.istime += nf as i64;
        st.bulk_vectors += (nf * per) as i64;
        // The frames as getframe gives them, mapped to the layout signals.
        if need_sigmap {
            let fr: &mut [i32] = if frames {
                &mut out[..nf * tlen]
            } else {
                &mut fbuf[..nf * tlen]
            };
            for f in 0..nf {
                self.sigmap(
                    &mut fr[f * tlen..(f + 1) * tlen],
                    &ibuf[f * flen..(f + 1) * flen],
                );
            }
            // (the last frame read, as getskewedframe leaves it)
            let last = &ibuf[(nf - 1) * flen..nf * flen];
            let ovec = &mut self.sig.ovec;
            let k = flen.min(ovec.len());
            ovec[..k].copy_from_slice(&last[..k]);
        }
        let st = &mut self.sig;
        st.bulk_in = ibuf;
        st.bulk_raw = raw;
        if frames {
            st.bulk_fr = fbuf;
            return nf;
        }

        // The sample vectors of getvec, as rgetvec makes them.
        if !highres {
            // (the first column and the samples per frame of each signal)
            let mut cols = Vec::with_capacity(nv);
            let mut tp = 0usize;
            for v in &st.vsd[..nv] {
                cols.push((tp, v.info.spf));
                tp += v.info.spf as usize;
            }
            for (f, o) in fbuf[..nf * tlen]
                .chunks_exact(tlen)
                .zip(out.chunks_exact_mut(nv))
            {
                for (x, &(tp, sf)) in o.iter_mut().zip(&cols) {
                    *x = if sf == 1 {
                        f[tp]
                    } else {
                        meansamp(&f[tp..], sf)
                    };
                }
            }
        } else {
            // The column of the frame giving signal s in vector k of each
            // frame: col[k * nv + s].
            let ispfmax = st.ispfmax as i32;
            let mut col = vec![0usize; per * nv];
            let mut tp = 0usize;
            for (s, v) in st.vsd[..nv].iter_mut().enumerate() {
                let sf = v.info.spf;
                v.gvindex = 0;
                v.gvcount = -ispfmax;
                for k in 0..per {
                    if k > 0 {
                        v.gvcount += sf;
                        if v.gvcount >= 0 {
                            v.gvindex += 1;
                            v.gvcount -= ispfmax;
                        }
                    }
                    col[k * nv + s] = tp + v.gvindex as usize;
                }
                tp += sf as usize;
            }
            for (f, o) in fbuf[..nf * tlen]
                .chunks_exact(tlen)
                .zip(out.chunks_exact_mut(per * nv))
            {
                for (x, &c) in o.iter_mut().zip(&col) {
                    *x = f[c];
                }
            }
            st.gvc = per as i32;
        }
        st.rgetvec_stat = nisig as i32;
        // (the last frame, as rgetvec leaves it)
        let k = tlen.min(st.tvector.len());
        st.tvector[..k].copy_from_slice(&fbuf[(nf - 1) * tlen..(nf - 1) * tlen + k]);
        st.bulk_fr = fbuf;
        nf * per
    }

    /// WFDB-x: turns the bulk path of [`Wfdb::getvecs`] on or off (it is on
    /// by default) and returns the previous setting. The results are the
    /// same either way; this is for testing the bulk path against the
    /// per-frame path.
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    #[doc(hidden)]
    pub fn wfdbx_bulk_read(&mut self, on: bool) -> bool {
        let previous = !self.sig.bulk_off;
        self.sig.bulk_off = !on;
        previous
    }

    /// WFDB-x: the number of sample vectors read by the bulk path of
    /// [`Wfdb::getvecs`] so far (for tests).
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    #[doc(hidden)]
    pub fn wfdbx_bulk_vectors(&self) -> i64 {
        self.sig.bulk_vectors
    }

    /// WFDB-x: the state of the input signals as text: `istime`, `gvc`,
    /// and each signal's last sample, checksum and remaining samples (for
    /// tests).
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    #[doc(hidden)]
    pub fn wfdbx_input_state(&self) -> String {
        let st = &self.sig;
        let mut s = format!("{} {}", st.istime, st.gvc);
        for is in &st.isd[..(st.nisig as usize).min(st.isd.len())] {
            s += &format!("; {} {} {}", is.samp, is.info.cksum, is.info.nsamp);
        }
        s
    }

    /// Reads up to `n` sample vectors, as `n` calls of [`Wfdb::getvec`]
    /// would, into `out` (vector after vector, one value per signal in
    /// each). Not part of the C library; faster than calling `getvec` in a
    /// loop (WFDB-x: where no frame needs special handling, it decodes the
    /// complete frames in the input buffers at once, with the same results).
    ///
    /// # Returns
    ///
    /// The number of vectors read (`>= 0`; less than `n` at the end of the
    /// record), or the negative status of `getvec` if the first read
    /// failed.
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn getvecs(&mut self, out: &mut [i32], n: i64) -> i64 {
        self.getvecs_status(out, n).0
    }

    /// As [`Wfdb::getvecs`], also returning the value returned by the last
    /// `getvec` call: the negative status of the first vector that could
    /// not be read (-1 at the end of the data, `< -1` on an error, e.g. -3
    /// for an unexpected end of file), or the number of values per vector
    /// if all `n` were read (0 if `n <= 0`). Not part of the C library.
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn getvecs_status(&mut self, out: &mut [i32], n: i64) -> (i64, i32) {
        if n <= 0 {
            return (0, 0);
        }
        let mut stat = 0;
        let mut k: i64 = 0;
        let st = &self.sig;
        if !st.have_dsbuf && st.ispfmax < 2 && (st.ifreq == 0.0 || st.ifreq == st.sfreq) {
            // Fast path: getvec is getframe (getskewedframe until a segment
            // that needs deskewing opens).
            let stride = st.tspf.max(0) as usize;
            let need = self.vec_need();
            let mut pos = 0usize;
            while k < n {
                // WFDB-x: as many frames as possible at once (see bulk_frames)
                let m = self.bulk_frames(&mut out[pos..], n - k);
                if m > 0 {
                    stat = self.sig.nisig as i32;
                    pos += m * stride;
                    k += m as i64;
                    continue;
                }
                if pos + need > out.len() {
                    // (the caller's array is too short for another vector)
                    let mut tmp = vec![0; need];
                    stat = self.getframe_impl(&mut tmp);
                    let m = out.len().saturating_sub(pos).min(stride);
                    if stat == -4 {
                        // (valid data with a checksum mismatch)
                        out[pos..pos + m].copy_from_slice(&tmp[..m]);
                    }
                    if stat < 0 {
                        break;
                    }
                    out[pos..pos + m].copy_from_slice(&tmp[..m]);
                    k += 1;
                    if m < stride {
                        break;
                    }
                    pos += stride;
                    continue;
                }
                // (getframe, not getskewedframe: a segment opened by an
                // earlier frame may need deskewing)
                stat = self.getframe_impl(&mut out[pos..]);
                if stat < 0 {
                    break;
                }
                pos += stride;
                k += 1;
            }
        } else {
            // getvec returns one sample per signal
            let mut stride = st.nvsig.max(0) as usize;
            if st.ifreq != 0.0 && st.ifreq != st.sfreq && st.nisig as i32 > st.nvsig {
                stride = st.nisig as usize;
            }
            let mut pos = 0usize;
            while k < n {
                // WFDB-x: as many vectors as possible at once (see
                // bulk_frames; none if the input is resampled or deskewed)
                let m = self.bulk_frames(&mut out[pos..], n - k);
                if m > 0 {
                    stat = self.sig.nisig as i32;
                    pos += m * stride;
                    k += m as i64;
                    continue;
                }
                if pos + stride > out.len() {
                    break;
                }
                stat = self.getvec(&mut out[pos..]);
                if stat < 0 {
                    break;
                }
                pos += stride;
                k += 1;
            }
        }
        if k == 0 && stat < 0 {
            (stat as i64, stat)
        } else {
            (k, stat)
        }
    }

    /// C `putvec(vector)`: writes a frame to the output signals: one sample
    /// (in ADC units) of each signal, or `spf` samples of a signal with
    /// `spf` samples per frame.
    ///
    /// # Returns
    ///
    /// The number of output signals (`> 0`), or: 0 if the slew rate is too
    /// high for a signal (difference formats only; the level is corrected
    /// later), -1 on a write error.
    ///
    /// Translation of the C function putvec() (lib/signal.c, WFDB 10.7.0): same
    /// arguments and results.
    pub fn putvec(&mut self, vector: &[i32]) -> i32 {
        let st = &mut self.sig;
        let mut stat = st.nosig as i32;
        let obsize = st.obsize;
        let mut errs: Vec<i32> = Vec::new();
        let mut vi = 0usize;
        let SigState { osd, ogd, .. } = st;
        for s in 0..st.nosig as usize {
            let os = &mut osd[s];
            let og = &mut ogd[os.info.group as usize];
            if os.info.nsamp == 0 {
                os.info.initval = vector[vi];
                os.samp = vector[vi];
            }
            os.info.nsamp += 1;
            let fmt = os.info.fmt;
            for _ in 0..os.info.spf {
                // Replace invalid samples with lowest possible value for
                // the format (formats 0 and 8 keep WFDB_INVALID_SAMPLE).
                let mut samp = vector[vi];
                if samp == WFDB_INVALID_SAMPLE && !matches!(fmt, 0 | 8) {
                    samp = fmt_range(fmt).0;
                }
                match fmt {
                    0 => os.samp = samp, // null signal (do not write)
                    16 => {
                        og.w16(samp, obsize);
                        os.samp = samp;
                    }
                    61 => {
                        og.w61(samp, obsize);
                        os.samp = samp;
                    }
                    80 => {
                        og.w80(samp, obsize);
                        os.samp = samp;
                    }
                    160 => {
                        og.w160(samp, obsize);
                        os.samp = samp;
                    }
                    212 => {
                        og.w212(samp, obsize);
                        os.samp = samp;
                    }
                    310 => {
                        og.w310(samp, obsize);
                        os.samp = samp;
                    }
                    311 => {
                        og.w311(samp, obsize);
                        os.samp = samp;
                    }
                    24 => {
                        og.w24(samp, obsize);
                        os.samp = samp;
                    }
                    32 => {
                        og.w32(samp, obsize);
                        os.samp = samp;
                    }
                    508 | 516 | 524 => {
                        if og.flac_putsamp(samp, fmt) < 0 {
                            stat = -1;
                        }
                        os.samp = samp;
                    }
                    _ => {
                        // 8-bit first differences
                        // Handle large slew rates sensibly.
                        let mut dif = samp.wrapping_sub(os.samp);
                        if dif < -128 {
                            dif = -128;
                            stat = 0;
                        } else if dif > 127 {
                            dif = 127;
                            stat = 0;
                        }
                        os.samp = os.samp.wrapping_add(dif);
                        og.w8(dif, obsize);
                    }
                }
                if og.fp.as_ref().is_some_and(super::wfdbio::WfdbFile::error) {
                    errs.push(s as i32);
                    stat = -1;
                } else {
                    os.info.cksum = os.info.cksum.wrapping_add(os.samp);
                }
                vi += 1;
            }
        }
        st.ostime += 1;
        for s in errs {
            let msg = cformat!(b"putvec: write error in signal %d\n", s);
            self.wfdb_error(msg);
        }
        stat
    }

    /// C `isigsettime(t)`: positions all input signals so that the next
    /// sample read is sample number `t`.
    ///
    /// # Returns
    ///
    /// 0 on success, or -1 if `t` is beyond the end of the record or the
    /// signal files cannot be repositioned.
    ///
    /// Translation of the C function isigsettime() (lib/signal.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn isigsettime(&mut self, t: i64) -> i32 {
        let st = &self.sig;
        // Return immediately if no seek is needed.
        if st.nisig == 0 {
            return 0;
        }
        if st.ifreq <= 0.0 {
            let curtime = if (st.gvmode & WFDB_HIGHRES) == 0 || st.ispfmax < 2 {
                st.istime
            } else {
                (st.istime - 1) * st.ispfmax as i64 + st.gvc as i64
            };
            if t == curtime {
                return 0;
            }
        }
        let mut stat = 0;
        let mut g = 1;
        while g < self.sig.nigroup {
            stat = self.isgsettime(g, t);
            if stat < 0 {
                break;
            }
            g += 1;
        }
        // Seek on signal group 0 last (since doing so updates istime and
        // would confuse isgsettime if done first).
        if stat == 0 {
            stat = self.isgsettime(0, t);
        }
        stat
    }

    /// C `isgsettime(g, t)`: as [`Wfdb::isigsettime`], for the signals of
    /// signal group `g` only.
    ///
    /// # Returns
    ///
    /// 0 on success, -1 if `t` is beyond the end of the record or the
    /// signal files cannot be repositioned, -2 if `g` is not a valid
    /// signal group.
    ///
    /// Translation of the C function isgsettime() (lib/signal.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn isgsettime(&mut self, g: u32, t: i64) -> i32 {
        let mut t = t;
        let mut trem = 0i32;
        // Handle negative arguments as equivalent positive arguments.
        if t < 0 {
            if t < -WFDB_TIME_MAX {
                return self.seekerr(g);
            }
            t = -t;
        }

        // Convert t to raw sample intervals if we are resampling.
        let st = &self.sig;
        if st.ifreq > 0.0 {
            let tt = t as f64 * st.sfreq / st.ifreq;
            if tt > WFDB_TIME_MAX as f64 {
                return self.seekerr(g);
            }
            t = d2l(tt);
        }

        // If we're in WFDB_HIGHRES mode, convert t from samples to frames,
        // and save the remainder (if any) in trem.
        let st = &mut self.sig;
        if st.gvmode & WFDB_HIGHRES != 0 {
            let m = (st.ispfmax as i64).max(1);
            trem = (t % m) as i32;
            t /= m;
        }

        // Mark the contents of the deskewing buffer (if any) as invalid.
        st.dsbi = -1;

        let stat = self.isgsetframe(g, t);
        if stat == 0 && g == 0 {
            while trem > 0 {
                trem -= 1;
                let mut uv = std::mem::take(&mut self.sig.uvector);
                if uv.len() < self.vec_need() {
                    uv.resize(self.vec_need(), 0);
                }
                let r = self.rgetvec(&mut uv);
                self.sig.uvector = uv;
                if r < 0 {
                    return self.seekerr(g);
                }
            }
            let st = &self.sig;
            if st.ifreq > 0.0 && st.ifreq != st.sfreq {
                self.sig.gvtime = 0;
                self.reload_gv();
            }
        }
        stat
    }

    /// C `tnextvec(s, t)`: returns the time of the next valid sample of
    /// input signal `s` at or after `t`, positioning the input signals
    /// there; a negative value (-1) at the end of the record or on an
    /// error.
    ///
    /// Translation of the C function tnextvec() (lib/signal.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn tnextvec(&mut self, s: u32, t: i64) -> i64 {
        let mut t = t;
        let mut stat: i32 = 0;
        let need = self.vec_need().max(1);
        let mut vv = vec![0i32; need];

        if self.sig.in_msrec != 0 && self.sig.need_sigmap != 0 {
            // variable-layout multi-segment record
            if s >= self.sig.nvsig as u32 {
                let msg = cformat!(b"nextvect: illegal signal number %d\n", s);
                self.wfdb_error(msg);
                return -1;
            }
            // Go to the start (t) if not already there.
            if t != self.sig.istime && self.isigsettime(t) < 0 {
                return -1;
            }
            while stat >= 0 {
                let p = ostr(&self.sig.vsd[s as usize].info.desc).to_vec();
                let st = &self.sig;
                let seg = &st.segarray[st.segp as usize];
                let tf = seg.samp0 + seg.nsamp;
                // Check if signal s is available in the current segment.
                let found = st.isd[..st.nisig as usize].iter().any(|is| {
                    is.info
                        .desc
                        .as_ref()
                        .is_some_and(|d| cstd::cstr(d) == &p[..])
                });
                if found {
                    // The current segment contains the desired signal. Read
                    // samples until we find a valid one or reach the end of
                    // the segment.
                    while t <= tf {
                        let need = self.vec_need();
                        if vv.len() < need {
                            vv.resize(need, 0);
                        }
                        stat = self.getvec(&mut vv);
                        if stat <= 0 {
                            break;
                        }
                        if vv[s as usize] != WFDB_INVALID_SAMPLE {
                            self.isigsettime(t);
                            return t;
                        }
                        t += 1;
                    }
                    if stat < 0 {
                        return -1;
                    }
                }
                // Go on to the next segment.
                if t != tf {
                    t = tf;
                    stat = self.isigsettime(t);
                }
            }
        } else {
            // single-segment or fixed-layout multi-segment record
            // Go to the start (t) if not already there.
            if t != self.sig.istime && self.isigsettime(t) < 0 {
                return -1;
            }
            if s >= self.sig.nisig {
                let msg = cformat!(b"nextvect: illegal signal number %d\n", s);
                self.wfdb_error(msg);
                return -1;
            }
            loop {
                let need = self.vec_need();
                if vv.len() < need {
                    vv.resize(need, 0);
                }
                stat = self.getvec(&mut vv);
                if stat <= 0 {
                    break;
                }
                // Read samples until we find a valid one or reach the end of
                // the record.
                if vv[s as usize] != WFDB_INVALID_SAMPLE {
                    self.isigsettime(t);
                    return t;
                }
                t += 1;
            }
        }
        // Error or end of record without finding another sample of signal s.
        stat as i64
    }

    /// C `setibsize(n)`: sets the default input buffer size (in bytes) of
    /// signal files opened later.
    ///
    /// # Returns
    ///
    /// The new size (`n`, or the default size if `n` is 0), or: -1 if input
    /// signals are open (the size cannot be changed then), -2 if `n` is
    /// negative.
    ///
    /// Translation of the C function setibsize() (lib/signal.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn setibsize(&mut self, n: i32) -> i32 {
        if self.sig.nisig != 0 {
            self.wfdb_error("setibsize: can't change buffer size after isigopen\n");
            return -1;
        }
        if n < 0 {
            let msg = cformat!(b"setibsize: illegal buffer size %d\n", n);
            self.wfdb_error(msg);
            return -2;
        }
        let n = if n == 0 { WFDB_BUFSIZ } else { n };
        self.sig.ibsize = n;
        n
    }

    /// C `setobsize(n)`: sets the default output buffer size (in bytes) of
    /// signal files opened later.
    ///
    /// # Returns
    ///
    /// The new size (`n`, or the default size if `n` is 0), or: -1 if output
    /// signals are open (the size cannot be changed then), -2 if `n` is
    /// negative.
    ///
    /// Translation of the C function setobsize() (lib/signal.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn setobsize(&mut self, n: i32) -> i32 {
        if self.sig.nosig != 0 {
            self.wfdb_error("setobsize: can't change buffer size after osig[f]open\n");
            return -1;
        }
        if n < 0 {
            let msg = cformat!(b"setobsize: illegal buffer size %d\n", n);
            self.wfdb_error(msg);
            return -2;
        }
        let n = if n == 0 { WFDB_BUFSIZ } else { n };
        self.sig.obsize = n;
        n
    }

    /// WFDB-x: `name` as written into the header of `record`: outside
    /// legacy mode, names are written relative to the header's directory
    /// (where the reader looks for them): the directory part of `record`
    /// is removed from `name` when `name` begins with it.
    fn hea_name(&self, record: &[u8], name: &[u8]) -> Vec<u8> {
        if self.sig.legacy {
            return name.to_vec();
        }
        match record.iter().rposition(|&c| c == b'/') {
            Some(k) if name.starts_with(&record[..=k]) => name[k + 1..].to_vec(),
            _ => name.to_vec(),
        }
    }

    /// C `newheader(record)`: writes the header file `record.hea` for the
    /// open output signals (with the sampling frequency, base time and
    /// number of samples written so far).
    ///
    /// # Returns
    ///
    /// 0 on success, or a negative value if the header cannot be created
    /// (see [`Wfdb::setheader`]).
    ///
    /// Translation of the C function newheader() (lib/signal.c, WFDB 10.7.0):
    /// same arguments and results. Differences: a header written under a path
    /// names the record and its signal files relative to its own directory,
    /// and only the record's own name (the last component) is checked; see
    /// docs/DIVERGENCES.md.
    pub fn newheader(&mut self, record: impl AsRef<[u8]>) -> i32 {
        let rec = wfdb_striphea(record.as_ref());
        let st = &self.sig;
        let mut osi: Vec<Siginfo> = st.osd[..st.nosig as usize]
            .iter()
            .map(|o| o.info.clone())
            .collect();
        let n = st.nosig;
        self.setheader(&rec, &mut osi, n)
    }

    /// C `setheader(record, siarray, nsig)`: writes the header file
    /// `record.hea` describing the `nsig` signals of `siarray`.
    ///
    /// As in C, the `units` and `desc` strings of `siarray` are truncated
    /// at their first space or line ending (C applies `strtok` to them).
    ///
    /// # Returns
    ///
    /// 0 on success, or -1 if the header file cannot be created (or the
    /// record name is illegal).
    ///
    /// Translation of the C function setheader() (lib/signal.c, WFDB 10.7.0):
    /// same arguments and results. Differences: a header written under a path
    /// names the record and its signal files relative to its own directory,
    /// and only the record's own name (the last component) is checked; see
    /// docs/DIVERGENCES.md.
    pub fn setheader(
        &mut self,
        record: impl AsRef<[u8]>,
        siarray: &mut [Siginfo],
        nsig: u32,
    ) -> i32 {
        // If another output header file was opened, close it.
        if let Some(oh) = self.sig.oheader.take() {
            oh.close();
            if self.sig.outinfo == OutInfo::Header {
                self.sig.outinfo = OutInfo::None;
            }
        }

        // Remove trailing .hea, if any, from record name.
        let record = wfdb_striphea(record.as_ref());

        // Quit (with message from wfdb_checkname) if name is illegal.
        if self.wfdb_checkname(&record, b"record") != 0 {
            return -1;
        }

        // Try to create the header file.
        match self.wfdb_open("hea", &record, WFDB_WRITE) {
            Some(f) => self.sig.oheader = Some(f),
            None => {
                let msg = cformat!(b"newheader: can't create header for record %s\n", record);
                self.wfdb_error(msg);
                return -1;
            }
        }
        let nsig = (nsig as usize).min(siarray.len());

        // Write the general information line.
        let (ffreq, cfreq, bcount, btime, bdate) = {
            let st = &self.sig;
            (st.ffreq, st.cfreq, st.bcount, st.btime, st.bdate)
        };
        let mut out = cformat!(
            b"%s %d %.12g",
            self.hea_name(&record, &record),
            nsig as i32,
            ffreq
        );
        if (cfreq > 0.0 && cfreq != ffreq) || bcount != 0.0 {
            out.extend(cformat!(b"/%.12g", cfreq));
            if bcount != 0.0 {
                out.extend(cformat!(b"(%.12g)", bcount));
            }
        }
        out.extend(cformat!(
            b" %ld",
            if nsig > 0 { siarray[0].nsamp } else { 0 }
        ));
        if btime != 0 || bdate != 0 {
            if btime == 0 {
                out.extend_from_slice(b" 0:00");
            } else if btime % 1000 == 0 {
                out.push(b' ');
                out.extend(self.ftimstr(btime, 1000.0));
            } else {
                out.push(b' ');
                out.extend(self.fmstimstr(btime, 1000.0));
            }
        }
        if bdate != 0 {
            out.extend(self.datstr(bdate));
        }
        out.extend_from_slice(b"\r\n");

        // Write a signal specification line for each signal.
        let fnames: Vec<Option<Vec<u8>>> = siarray[..nsig]
            .iter()
            .map(|si| si.fname.as_ref().map(|f| self.hea_name(&record, f)))
            .collect();
        let st = &self.sig;
        for (s, si) in siarray.iter_mut().enumerate().take(nsig) {
            out.extend(cformat!(b"%s %d", fnames[s], si.fmt));
            if si.spf > 1 {
                out.extend(cformat!(b"x%d", si.spf));
            }
            if s < st.osd.len() && st.osd[s].skew != 0 {
                out.extend(cformat!(b":%d", st.osd[s].skew.wrapping_mul(si.spf)));
            }
            let gstart = if s < st.osd.len() && (st.osd[s].info.group as usize) < st.ogd.len() {
                st.ogd[st.osd[s].info.group as usize].start
            } else {
                0
            };
            if gstart != 0 {
                out.extend(cformat!(b"+%ld", gstart));
            } else if st.prolog_bytes != 0 {
                out.extend(cformat!(b"+%ld", st.prolog_bytes));
            }
            out.extend(cformat!(b" %.12g", si.gain));
            if si.baseline != si.adczero {
                out.extend(cformat!(b"(%d)", si.baseline));
            }
            if let Some(u) = si.units.as_mut() {
                if let Some(p) = strtok_inplace(u, b" \t\n\r") {
                    out.push(b'/');
                    out.extend(p);
                }
            }
            out.extend(cformat!(
                b" %d %d %d %d %d",
                si.adcres,
                si.adczero,
                si.initval,
                (si.cksum & 0xffff) as i16 as i32,
                si.bsize
            ));
            if let Some(d) = si.desc.as_mut() {
                if let Some(p) = strtok_inplace(d, b"\n\r") {
                    out.push(b' ');
                    out.extend(p);
                }
            }
            out.extend_from_slice(b"\r\n");
        }
        let st = &mut self.sig;
        if let Some(oh) = st.oheader.as_mut() {
            oh.write(&out);
            oh.flush();
        }
        st.prolog_bytes = 0;
        0
    }

    /// C `getseginfo(&sarray)`: the number of segments of the open
    /// multi-segment record (0 if it is not one); `sarray` receives a copy
    /// of the segment table (`None` if there is none).
    ///
    /// Translation of the C function getseginfo() (lib/signal.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn getseginfo(&mut self, sarray: &mut Option<Vec<Seginfo>>) -> i32 {
        let st = &self.sig;
        *sarray = if st.have_segarray {
            Some(st.segarray.clone())
        } else {
            None
        };
        st.segments
    }

    /// C `setmsheader(record, segment_names, nsegments)`: writes the header
    /// of a multi-segment record made of the existing records
    /// `segment_names`.
    ///
    /// # Returns
    ///
    /// 0 on success, or: -1 if the record name is illegal, there are no
    /// segments, or the header cannot be written; -2 if a segment name is
    /// too long; -3 if a segment is itself a multi-segment record or its
    /// header cannot be read; -4 if a segment length is unspecified, or the
    /// segments differ in number of signals or sampling frequency.
    ///
    /// Translation of the C function setmsheader() (lib/signal.c, WFDB
    /// 10.7.0): same arguments and results. Differences: a header written
    /// under a path names the record and its segments relative to its own
    /// directory, and only the record's own name (the last component) is
    /// checked; see docs/DIVERGENCES.md.
    pub fn setmsheader<S: AsRef<[u8]>>(
        &mut self,
        record: impl AsRef<[u8]>,
        segment_name: &[S],
        nsegments: u32,
    ) -> i32 {
        let old_in_msrec = self.sig.in_msrec;
        let (mut msfreq, mut mscfreq, mut msbcount) = (0f64, 0f64, 0f64);
        let mut nsig = 0;

        self.isigclose(); // close any open input signals

        // If another output header file was opened, close it.
        if let Some(oh) = self.sig.oheader.take() {
            oh.close();
            if self.sig.outinfo == OutInfo::Header {
                self.sig.outinfo = OutInfo::None;
            }
        }

        // Remove trailing .hea, if any, from record name.
        let record = wfdb_striphea(record.as_ref());

        // Quit (with message from wfdb_checkname) if name is illegal.
        if self.wfdb_checkname(&record, b"record") != 0 {
            return -1;
        }

        if nsegments < 1 {
            self.wfdb_error("setmsheader: record must contain at least one segment\n");
            return -1;
        }
        let nsegments = (nsegments as usize).min(segment_name.len());

        let mut ns: Vec<i64> = vec![0; nsegments];
        for i in 0..nsegments {
            let name = cstd::cstr(segment_name[i].as_ref()).to_vec();
            if name.len() > WFDB_MAXRNL {
                let msg = cformat!(
                    b"setmsheader: `%s' is too long for a segment name in record %s\n",
                    name,
                    record
                );
                self.wfdb_error(msg);
                return -2;
            }
            self.sig.in_msrec = 1;
            self.sig.nsamples = 0;
            self.sig.user_segments = true; // WFDB-x: names given by the caller
            let n = self.readheader(&name);
            self.sig.user_segments = false;
            self.sig.in_msrec = old_in_msrec;
            if n < 0 {
                let msg = cformat!(b"setmsheader: can't read segment %s header\n", name);
                self.wfdb_error(msg);
                return -3;
            }
            ns[i] = self.sig.nsamples;
            if ns[i] <= 0 {
                let msg = cformat!(
                    b"setmsheader: length of segment %s must be specified\n",
                    name
                );
                self.wfdb_error(msg);
                return -4;
            }
            let st = &mut self.sig;
            if i == 0 {
                nsig = n;
                msfreq = st.ffreq;
                mscfreq = st.cfreq;
                msbcount = st.bcount;
                st.msbtime = st.btime;
                st.msbdate = st.bdate;
                st.msnsamples = ns[i];
            } else {
                if nsig != n {
                    let msg = cformat!(
                        b"setmsheader: incorrect number of signals in segment %s\n",
                        name
                    );
                    self.wfdb_error(msg);
                    return -4;
                }
                if msfreq != st.ffreq {
                    let msg = cformat!(
                        b"setmsheader: incorrect sampling frequency in segment %s\n",
                        name
                    );
                    self.wfdb_error(msg);
                    return -4;
                }
                st.msnsamples += ns[i];
            }
        }

        // Try to create the header file.
        match self.wfdb_open("hea", &record, WFDB_WRITE) {
            Some(f) => self.sig.oheader = Some(f),
            None => {
                let msg = cformat!(
                    b"setmsheader: can't create header file for record %s\n",
                    record
                );
                self.wfdb_error(msg);
                return -1;
            }
        }

        // Write the first line of the master header.
        let mut out = cformat!(
            b"%s/%u %d %.12g",
            self.hea_name(&record, &record),
            nsegments as u32,
            nsig,
            msfreq
        );
        if (mscfreq > 0.0 && mscfreq != msfreq) || msbcount != 0.0 {
            out.extend(cformat!(b"/%.12g", mscfreq));
            if msbcount != 0.0 {
                out.extend(cformat!(b"(%.12g)", msbcount));
            }
        }
        let (msnsamples, msbtime, msbdate) = {
            let st = &self.sig;
            (st.msnsamples, st.msbtime, st.msbdate)
        };
        out.extend(cformat!(b" %lld", msnsamples));
        if msbtime != 0 || msbdate != 0 {
            out.push(b' ');
            if msbtime % 1000 == 0 {
                out.extend(self.ftimstr(msbtime, 1000.0));
            } else {
                out.extend(self.fmstimstr(msbtime, 1000.0));
            }
        }
        if msbdate != 0 {
            out.extend(self.datstr(msbdate));
        }
        out.extend_from_slice(b"\r\n");

        // Write a line for each segment.
        for i in 0..nsegments {
            out.extend(cformat!(
                b"%s %lld\r\n",
                self.hea_name(&record, cstd::cstr(segment_name[i].as_ref())),
                ns[i]
            ));
        }
        if let Some(oh) = self.sig.oheader.as_mut() {
            oh.write(&out);
        }
        0
    }

    /// C `wfdbgetskew(s)`: the skew (in frames) of input signal `s`.
    ///
    /// Translation of the C function wfdbgetskew() (lib/signal.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn wfdbgetskew(&mut self, s: u32) -> i32 {
        let st = &self.sig;
        if s < st.nvsig.max(0) as u32 {
            st.vsd[s as usize].skew
        } else {
            0
        }
    }

    /// C `wfdbsetiskew(s, skew)`: set the skew of input signal `s` (use
    /// with care: only to restore skews reset as a side effect of, e.g.,
    /// `sampfreq`).
    ///
    /// Translation of the C function wfdbsetiskew() (lib/signal.c, WFDB
    /// 10.7.0): same arguments and results.
    pub fn wfdbsetiskew(&mut self, s: u32, skew: i32) {
        let st = &mut self.sig;
        if s < st.nvsig.max(0) as u32
            && skew >= 0
            && st.tspf != 0
            && (skew as u32) < st.dsblen / st.tspf as u32
        {
            st.vsd[s as usize].skew = skew;
        }
    }

    /// C `wfdbsetskew(s, skew)`: set the skew to be written by `setheader`
    /// for output signal `s`.
    ///
    /// Translation of the C function wfdbsetskew() (lib/signal.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn wfdbsetskew(&mut self, s: u32, skew: i32) {
        let st = &mut self.sig;
        if s < st.nosig {
            st.osd[s as usize].skew = skew;
        }
    }

    /// C `wfdbgetstart(s)`: the byte offset of sample 0 in the signal file
    /// of input signal `s`.
    ///
    /// Translation of the C function wfdbgetstart() (lib/signal.c, WFDB
    /// 10.7.0): same arguments and results.
    pub fn wfdbgetstart(&mut self, s: u32) -> i64 {
        let st = &self.sig;
        if s < st.nisig
            && (s as usize) < st.vsd.len()
            && (st.vsd[s as usize].info.group as usize) < st.igd.len()
        {
            st.igd[st.vsd[s as usize].info.group as usize].start
        } else if s == 0 && !st.hsd.is_empty() {
            st.hsd[0].start
        } else {
            0
        }
    }

    /// C `wfdbsetstart(s, bytes)`: set the byte offset to be written by
    /// `setheader` for output signal `s`.
    ///
    /// Translation of the C function wfdbsetstart() (lib/signal.c, WFDB
    /// 10.7.0): same arguments and results.
    pub fn wfdbsetstart(&mut self, s: u32, bytes: i64) {
        let st = &mut self.sig;
        if s < st.nosig {
            let g = st.osd[s as usize].info.group as usize;
            if g < st.ogd.len() {
                st.ogd[g].start = bytes;
            }
        }
        st.prolog_bytes = bytes;
    }

    /// C `wfdbputprolog(buf, size, s)`: writes `size` bytes of `buf` (a
    /// prolog) to the signal file of output signal `s`, and records its
    /// length as the byte offset of sample 0 (see
    /// [`Wfdb::wfdbsetstart`]). Returns 0, or -1 on a write error.
    ///
    /// Translation of the C function wfdbputprolog() (lib/signal.c, WFDB
    /// 10.7.0): same arguments and results.
    pub fn wfdbputprolog(&mut self, buf: &[u8], size: i64, s: u32) -> i32 {
        let mut n: i64 = 0;
        let st = &mut self.sig;
        if s < st.nosig {
            let g = st.osd[s as usize].info.group as usize;
            if let Some(f) = st.ogd.get_mut(g).and_then(|o| o.fp.as_mut()) {
                let k = (size.max(0) as usize).min(buf.len());
                n = f.write(&buf[..k]) as i64;
            }
        }
        self.wfdbsetstart(s, n);
        if n != size {
            let msg = cformat!(b"wfdbputprolog: only %ld of %ld bytes written\n", n, size);
            self.wfdb_error(msg);
        }
        if n == size {
            0
        } else {
            -1
        }
    }

    /// C `setinfo(record)`: creates (or opens for appending) the info file
    /// `record.info`, to which [`Wfdb::putinfo`] then writes; `NULL` closes
    /// it.
    ///
    /// # Returns
    ///
    /// 0 on success, or: -1 if the record name is illegal or the file
    /// cannot be opened, -2 on a write error when closing it (with
    /// `NULL`).
    ///
    /// Translation of the C function setinfo() (lib/signal.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn setinfo(&mut self, record: impl OptBytes) -> i32 {
        // Close any previously opened output info file.
        let stat = self.wfdb_oinfoclose();

        // Quit unless a record name has been specified.
        let Some(rec) = record.opt_bytes() else {
            return stat;
        };

        // Remove trailing .hea, if any, from record name.
        let record = wfdb_striphea(rec);

        // Quit (with message from wfdb_checkname) if name is illegal.
        if self.wfdb_checkname(&record, b"record") != 0 {
            return -1;
        }

        // Try to create the .info file.
        match self.wfdb_open("info", &record, WFDB_APPEND) {
            Some(f) => {
                self.sig.outinfo_file = Some(f);
                self.sig.outinfo = OutInfo::File;
                0
            }
            None => {
                let msg = cformat!(b"setinfo: can't create info file for record %s\n", record);
                self.wfdb_error(msg);
                -1
            }
        }
    }

    /// C `putinfo(s)`: writes an info string (a comment line) to the info
    /// file opened by [`Wfdb::setinfo`], or else to the header file written
    /// last by `newheader`/`setheader`. Returns 0, or -1 if neither is
    /// open.
    ///
    /// Translation of the C function putinfo() (lib/signal.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn putinfo(&mut self, s: impl AsRef<[u8]>) -> i32 {
        let st = &mut self.sig;
        if st.outinfo == OutInfo::None {
            if st.oheader.is_some() {
                st.outinfo = OutInfo::Header;
            } else {
                self.wfdb_error("putinfo: caller has not specified a record name\n");
                return -1;
            }
        }
        let f = match st.outinfo {
            OutInfo::Header => st.oheader.as_mut(),
            _ => st.outinfo_file.as_mut(),
        };
        if let Some(f) = f {
            let mut line = vec![b'#'];
            line.extend_from_slice(cstd::cstr(s.as_ref()));
            line.extend_from_slice(b"\r\n");
            f.write(&line);
            f.flush();
        }
        0
    }

    /// C `getinfo(record)`: on the first call (or with a record name), read
    /// the info strings of the record (from its header and `.info` file)
    /// and return the first; with `NULL`, return the next one. `None` when
    /// there are no more.
    ///
    /// Translation of the C function getinfo() (lib/signal.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn getinfo(&mut self, record: impl OptBytes) -> Option<Vec<u8>> {
        let record = record.opt_bytes().map(|r| cstd::cstr(r).to_vec());
        if record.is_some() {
            self.wfdb_freeinfo();
        }

        if !self.sig.have_pinfo {
            // info for record has not yet been read
            let mut recbuf = match record {
                Some(r) => r,
                None => match self.wfdb_getirec() {
                    Some(r) => r,
                    None => {
                        self.wfdb_error("getinfo: caller did not specify record name\n");
                        return None;
                    }
                },
            };

            if self.sig.ninfo != 0 {
                self.wfdb_freeinfo();
                self.sig.ninfo = 0;
            }

            self.sig.info_i = 0;
            self.sig.have_pinfo = true;
            self.sig.pinfo.clear();

            // As in C, an info string is the line after its initial '#',
            // without its line ending, up to its first null character.
            fn save(st: &mut SigState, b: &[u8]) {
                let mut l = cstd::cstr(b);
                if l.last() == Some(&b'\n') {
                    l = &l[..l.len() - 1];
                }
                if l.last() == Some(&b'\r') {
                    l = &l[..l.len() - 1];
                }
                st.pinfo.push(l.get(1..).unwrap_or(b"").to_vec());
                st.ninfo += 1;
            }

            // Read info from the .hea file, if available (skip for EDF
            // files).
            if self.sig.isedf == 0 {
                recbuf = wfdb_striphea(&recbuf);
                if let Some(mut ifile) = self.wfdb_open("hea", &recbuf, WFDB_READ) {
                    // As with wfdb_getline(), the buffer keeps its previous
                    // contents when the end of the file is reached.
                    let mut buf: Vec<u8> = Vec::new();
                    let mut line: Vec<u8> = Vec::new();
                    while ifile.getline(&mut line) > 0 {
                        buf.clone_from(&line);
                        if buf[0] != b'#' {
                            break; // skip initial comments
                        }
                    }
                    while ifile.getline(&mut line) > 0 {
                        buf.clone_from(&line);
                        if buf[0] == b'#' {
                            break; // skip header content
                        }
                    }
                    while !buf.is_empty() && buf[0] != 0 {
                        // read and save info
                        if buf[0] == b'#' {
                            save(&mut self.sig, &buf);
                        }
                        if ifile.getline(&mut line) == 0 {
                            break;
                        }
                        buf.clone_from(&line);
                    }
                }
            }
            // Read more info from the .info file, if available.
            if let Some(mut ifile) = self.wfdb_open("info", &recbuf, WFDB_READ) {
                let mut buf: Vec<u8> = Vec::new();
                while ifile.getline(&mut buf) > 0 {
                    if buf[0] == b'#' {
                        save(&mut self.sig, &buf);
                    }
                }
            }
        }
        let st = &mut self.sig;
        if st.info_i < st.ninfo {
            let r = st.pinfo[st.info_i as usize].clone();
            st.info_i += 1;
            Some(r)
        } else {
            None
        }
    }

    /// C `wfdb_freeinfo()`: release the info strings.
    ///
    /// Translation of the C function wfdb_freeinfo() (lib/signal.c, WFDB
    /// 10.7.0): same arguments and results.
    pub fn wfdb_freeinfo(&mut self) {
        let st = &mut self.sig;
        st.pinfo = Vec::new();
        st.have_pinfo = false;
        st.ninfo = 0;
    }

    /// C `sampfreq(record)`: returns the sampling frequency (Hz) of
    /// `record` (reading its header), or of the open record if `record` is
    /// `NULL`.
    ///
    /// # Returns
    ///
    /// The frequency (`> 0`); 0 if the header does not specify it (WFDB-x:
    /// C assumed 250 Hz) and none was set with `setsampfreq`; -1 if the
    /// header cannot be read, -2 if it is incorrect.
    ///
    /// Translation of the C function sampfreq() (lib/signal.c, WFDB 10.7.0):
    /// same arguments and results. Differences: it returns 0, not 250, if the
    /// header gives no sampling frequency; see docs/DIVERGENCES.md.
    pub fn sampfreq(&mut self, record: impl OptBytes) -> f64 {
        if let Some(r) = record.opt_bytes() {
            // Remove trailing .hea, if any, from record name.
            let record = wfdb_striphea(r);
            // Save the current record name.
            self.wfdb_setirec(&record);
            // Don't require the sampling frequency of this record to match
            // that of the previously opened record, if any.
            self.setsampfreq(0.0);
            // readheader sets sfreq if successful.
            let n = self.readheader(&record);
            if n < 0 {
                // error message will come from readheader
                return n as f64;
            }
        }
        self.sig.sfreq
    }

    /// C `setsampfreq(freq)`: sets the sampling frequency (Hz) used for time
    /// conversions and written in headers. Returns 0, or -1 if `freq` is
    /// negative.
    ///
    /// Translation of the C function setsampfreq() (lib/signal.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn setsampfreq(&mut self, freq: f64) -> i32 {
        if freq >= 0.0 {
            let st = &mut self.sig;
            st.sfreq = freq;
            st.ffreq = freq;
            if st.spfmax == 0 {
                st.spfmax = 1;
            }
            if (st.gvmode & WFDB_HIGHRES) == WFDB_HIGHRES {
                st.sfreq *= st.spfmax as f64;
            }
            return 0;
        }
        self.wfdb_error("setsampfreq: sampling frequency must not be negative\n");
        -1
    }

    /// C `setbasetime(string)`: sets the base time and date of the record
    /// (`"hh:mm:ss dd/mm/yyyy"`, the date being optional; `NULL` or empty:
    /// the current local time). Returns 0, or -1 if the string is
    /// incorrectly formatted.
    ///
    /// Translation of the C function setbasetime() (lib/signal.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn setbasetime(&mut self, string: impl OptBytes) -> i32 {
        self.sig.pdays = -1;
        let s = string.opt_bytes().map(cstd::cstr).unwrap_or(b"");
        if s.is_empty() {
            let (y, mo, d, h, mi, se) = local_time_now();
            let ds = cformat!(b"%02d/%02d/%d", d, mo, y);
            self.sig.bdate = self.strdat(&ds);
            self.sig.date_string = ds;
            let ts = cformat!(b"%d:%d:%d", h, mi, se);
            self.sig.btime = self.fstrtim(&ts, 1000.0);
            return 0;
        }
        let mut k = 0;
        while k < s.len() && s[k] == b' ' {
            k += 1;
        }
        let string = &s[k..];
        let (tpart, dpart) = match string.iter().position(|&c| c == b' ') {
            Some(p) => (&string[..p], Some(&string[p + 1..])),
            None => (string, None),
        };
        self.sig.btime = self.fstrtim(tpart, 1000.0);
        self.sig.bdate = match dpart {
            Some(p) => self.strdat(p),
            None => 0,
        };
        if self.sig.btime == 0 && self.sig.bdate == 0 && string.first() != Some(&b'[') {
            let msg = cformat!(b"setbasetime: incorrect time format, '%s'\n", string);
            self.wfdb_error(msg);
            return -1;
        }
        0
    }

    /// Convert a sample number to a string, using the given sampling
    /// frequency (`ftimstr`).
    fn ftimstr(&mut self, t: i64, f: f64) -> Vec<u8> {
        let ts = self.fmstimstr(t, f);
        let mut tk = Strtok::new(&ts);
        let Some(p) = tk.next(b".") else {
            return Vec::new();
        };
        let mut r = p.to_vec();
        let st = &self.sig;
        if t <= 0 && (st.btime != 0 || st.bdate != 0) {
            // time of day
            r.extend_from_slice(&st.date_string);
            r.push(b']');
        }
        r
    }

    /// Convert a sample number to a string with milliseconds, using the
    /// given sampling frequency (`fmstimstr`).
    fn fmstimstr(&mut self, t: i64, f: f64) -> Vec<u8> {
        let mut t = t;
        let (btime, bdate) = (self.sig.btime, self.sig.bdate);
        if t > 0 || (btime == 0 && bdate == 0) {
            // time interval
            if t < 0 {
                t = t.wrapping_neg();
            }
            // Convert from sample intervals to seconds.
            let mut s = d2l(t as f64 / f);
            let mut msec = d2i((t as f64 - s as f64 * f) * 1000.0 / f + 0.5);
            if msec == 1000 {
                msec = 0;
                s += 1;
            }
            t = s;
            let seconds = (t % 60) as i32;
            t /= 60;
            let minutes = (t % 60) as i32;
            let hours = (t / 60) as i32;
            if hours > 0 {
                cformat!(b"%2d:%02d:%02d.%03d", hours, minutes, seconds, msec)
            } else {
                cformat!(b"   %2d:%02d.%03d", minutes, seconds, msec)
            }
        } else {
            // time of day
            // Convert to milliseconds since midnight.
            let tms = btime as f64 - (t as f64 * 1000.0 / f);
            // Convert to seconds.
            let mut s = d2l(tms / 1000.0);
            let mut msec = d2i((tms - s as f64 * 1000.0) + 0.5);
            if msec == 1000 {
                msec = 0;
                s += 1;
            }
            t = s;
            let seconds = (t % 60) as i32;
            t /= 60;
            let minutes = (t % 60) as i32;
            t /= 60;
            let hours = (t % 24) as i32;
            let days = t / 24;
            if days != self.sig.pdays {
                if bdate > 0 {
                    self.datstr(days + bdate);
                } else if days == 0 {
                    self.sig.date_string.clear();
                } else {
                    self.sig.date_string = cformat!(b" %ld", days);
                }
                self.sig.pdays = days;
            }
            let mut r = cformat!(
                b"[%02d:%02d:%02d.%03d%s]",
                hours,
                minutes,
                seconds,
                msec,
                self.sig.date_string
            );
            r.truncate(TIME_STRING_LEN);
            r
        }
    }

    /// Convert a string to a sample number, using the given sampling
    /// frequency (`fstrtim`).
    fn fstrtim(&mut self, string: &[u8], f: f64) -> i64 {
        let mut string = cstd::cstr(string);
        while let Some(&c) = string.first() {
            if matches!(c, b' ' | b'\t' | b'\n' | b'\r') {
                string = &string[1..];
            } else {
                break;
            }
        }
        let st = &self.sig;
        match string.first().copied().unwrap_or(0) {
            b'c' => {
                if st.cfreq > 0.0 {
                    d2l((strtod0(&string[1..]) - st.bcount) * f / st.cfreq)
                } else {
                    cstd::strtoll(&string[1..], 10).0
                }
            }
            b'e' => {
                let n = if st.in_msrec != 0 {
                    st.msnsamples
                } else {
                    st.nsamples
                };
                n.wrapping_mul(if (st.gvmode & WFDB_HIGHRES) == WFDB_HIGHRES {
                    st.spfmax as i64
                } else {
                    1
                })
            }
            b'f' => d2l(cstd::strtoll(&string[1..], 10).0 as f64 * f / st.ffreq),
            b'i' => d2l(st.istime as f64
                * (if st.ifreq > 0.0 {
                    st.ifreq / st.sfreq
                } else {
                    1.0
                })
                * (if (st.gvmode & WFDB_HIGHRES) == WFDB_HIGHRES {
                    st.ispfmax as f64
                } else {
                    1.0
                })),
            b'o' => st.ostime,
            b's' => cstd::strtoll(&string[1..], 10).0,
            b'[' => {
                // time of day, possibly with date or days since start
                let string = &string[1..];
                let Some(q) = strchr(string, b']') else {
                    return 0; // '[...': malformed time string
                };
                let days: i64 = match strchr(string, b' ') {
                    Some(p) if p <= q => match strchr(&string[p + 1..], b'/') {
                        Some(r) if p + 1 + r <= q => {
                            // '[hh:mm:ss.sss dd/mm/yyyy]'
                            self.strdat(&string[p + 1..]) - self.sig.bdate
                        }
                        _ => strtol10(&string[p + 1..]), // '[hh:mm:ss.sss d]'
                    },
                    _ => 0, // '[hh:mm:ss.sss]': time since midnight only
                };
                let mut x = (self.fstrtim(string, 1000.0) - self.sig.btime) as f64;
                if days > 0 {
                    x += days as f64 * (24.0 * 60.0 * 60.0 * 1000.0);
                }
                let t = d2l(x * f / 1000.0 + 0.5);
                t.wrapping_neg()
            }
            _ => {
                let x = strtod0(string);
                let Some(p) = strchr(string, b':') else {
                    return d2l(x * f + 0.5);
                };
                let rest = &string[p + 1..];
                let y = strtod0(rest);
                let Some(p2) = strchr(rest, b':') else {
                    return d2l((60.0 * x + y) * f + 0.5);
                };
                let z = strtod0(&rest[p2 + 1..]);
                d2l((3600.0 * x + 60.0 * y + z) * f + 0.5)
            }
        }
    }

    /// The frequency used by `timstr`, `mstimstr` and `strtim`, or 0 if
    /// none is specified.
    ///
    /// WFDB-x: no default sampling frequency (C used 1 sample per second,
    /// as legacy mode does).
    fn tfreq(&self) -> f64 {
        let st = &self.sig;
        if st.ifreq > 0.0 {
            st.ifreq
        } else if st.sfreq > 0.0 {
            st.sfreq
        } else if st.legacy {
            1.0
        } else {
            0.0
        }
    }

    /// WFDB-x: the result of `timstr` and `mstimstr` (named `func` in the
    /// error message) when no sampling frequency is specified: the time as
    /// a sample number (`"s"` followed by `|t|`, a valid `strtim` argument).
    fn nofreq_timstr(&mut self, func: &str, t: i64) -> Vec<u8> {
        let msg = cformat!(b"%s: sampling frequency is not specified\n", func);
        self.wfdb_error(msg);
        cformat!(b"s%lld", t.unsigned_abs() as i64)
    }

    /// WFDB-x addition (C `wfdbx_time_needs_freq(string)`): whether
    /// [`Wfdb::strtim`] needs a sampling frequency to convert `string`.
    ///
    /// # Returns
    ///
    /// 0 if `string` (after leading spaces, tabs, newlines and carriage
    /// returns) begins with `e`, `i`, `o` or `s`, or with `c` while the
    /// counter frequency is not positive; 1 otherwise.
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn wfdbx_time_needs_freq(&mut self, string: impl AsRef<[u8]>) -> i32 {
        let string = string.as_ref();
        let first = string
            .iter()
            .copied()
            .find(|&c| !matches!(c, b' ' | b'\t' | b'\n' | b'\r'))
            .unwrap_or(0);
        match first {
            b'e' | b'i' | b'o' | b's' => 0,
            b'c' => (self.sig.cfreq > 0.0) as i32,
            _ => 1,
        }
    }

    /// Turns legacy mode on (`on != 0`) or off, and returns the previous
    /// setting (1: on, 0: off).
    ///
    /// In legacy mode, the library behaves exactly as the original WFDB library
    /// 10.7.0, including its assumed signal parameters and its search for files.
    /// Legacy mode is off by default. Use it only to reproduce old results. See
    /// `docs/DIVERGENCES.md` in the repository for what changes.
    ///
    /// # Examples
    ///
    /// ```
    /// let mut w = wfdbx::Wfdb::new();
    /// let previous = w.wfdbx_set_legacy(1);
    /// assert_eq!(w.wfdbx_get_legacy(), 1);
    /// w.wfdbx_set_legacy(previous);
    /// ```
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn wfdbx_set_legacy(&mut self, on: i32) -> i32 {
        let previous = self.sig.legacy as i32;
        self.sig.legacy = on != 0;
        previous
    }

    /// Returns 1 if legacy mode is on, 0 otherwise (see
    /// [`Wfdb::wfdbx_set_legacy`]).
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn wfdbx_get_legacy(&self) -> i32 {
        self.sig.legacy as i32
    }

    /// WFDB-x addition (C `wfdbx_legacy_args(&argc, &argv)`), called by the
    /// tools before anything else: if the first argument after the program
    /// name (`argv[1]`) is exactly `--legacy`, removes it from `argv`, turns
    /// legacy mode on and returns 1; otherwise changes nothing and returns
    /// 0. Only the first argument is recognized. It also enables the check
    /// of write errors at [`cstd::exit`] (the exit status of the tools).
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn wfdbx_legacy_args(&mut self, argv: &mut Vec<Vec<u8>>) -> i32 {
        if let Some(argv0) = argv.first() {
            cstd::exit_check_init(argv0); // WFDB-x: see cstd::exit
        }
        if argv.len() < 2 || argv[1] != b"--legacy" {
            return 0;
        }
        argv.remove(1);
        self.wfdbx_set_legacy(1);
        1
    }

    /// C `timstr(t)`: a time string (`hh:mm:ss`, or `[hh:mm:ss dd/mm/yyyy]`
    /// for a time of day: `t <= 0` when the base time is defined).
    ///
    /// WFDB-x: if no sampling frequency is specified, reports an error and
    /// returns the time as a sample number (`"s"` followed by `|t|`).
    ///
    /// Translation of the C function timstr() (lib/signal.c, WFDB 10.7.0):
    /// same arguments and results. Differences: if the sampling frequency is
    /// not specified, it reports an error and returns the time as a sample
    /// number (the original assumed 1 sample per second); see
    /// docs/DIVERGENCES.md.
    pub fn timstr(&mut self, t: i64) -> Vec<u8> {
        let f = self.tfreq();
        if f <= 0.0 {
            return self.nofreq_timstr("timstr", t);
        }
        self.ftimstr(t, f)
    }

    /// C `mstimstr(t)`: as `timstr`, with milliseconds.
    ///
    /// WFDB-x: if no sampling frequency is specified, reports an error and
    /// returns the time as a sample number (`"s"` followed by `|t|`).
    ///
    /// Translation of the C function mstimstr() (lib/signal.c, WFDB 10.7.0):
    /// same arguments and results. Differences: if the sampling frequency is
    /// not specified, it reports an error and returns the time as a sample
    /// number (the original assumed 1 sample per second); see
    /// docs/DIVERGENCES.md.
    pub fn mstimstr(&mut self, t: i64) -> Vec<u8> {
        let f = self.tfreq();
        if f <= 0.0 {
            return self.nofreq_timstr("mstimstr", t);
        }
        self.fmstimstr(t, f)
    }

    /// C `getcfreq()`: the counter frequency.
    ///
    /// Translation of the C function getcfreq() (lib/signal.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn getcfreq(&mut self) -> f64 {
        let st = &self.sig;
        if st.cfreq > 0.0 {
            st.cfreq
        } else {
            st.ffreq
        }
    }

    /// C `setcfreq(freq)`: set the counter frequency.
    ///
    /// Translation of the C function setcfreq() (lib/signal.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn setcfreq(&mut self, freq: f64) {
        self.sig.cfreq = freq;
    }

    /// C `getbasecount()`: the base counter value.
    ///
    /// Translation of the C function getbasecount() (lib/signal.c, WFDB
    /// 10.7.0): same arguments and results.
    pub fn getbasecount(&mut self) -> f64 {
        self.sig.bcount
    }

    /// WFDB-x (for the high-level API): the number of samples per signal
    /// given by the record line of the header read last (that of a
    /// multi-segment record for such a record; 0 if not given).
    pub(crate) fn wfdbx_header_nsamples(&self) -> i64 {
        let st = &self.sig;
        if st.in_msrec != 0 {
            st.msnsamples
        } else {
            st.nsamples
        }
    }

    /// WFDB-x (for `check_record`): the number of samples of the record
    /// opened last: that of the master header for a multi-segment record
    /// (`multi`, or while one is open), otherwise that of its header.
    pub(crate) fn wfdbx_record_nsamples(&self, multi: bool) -> i64 {
        let st = &self.sig;
        if st.in_msrec != 0 || multi {
            st.msnsamples
        } else {
            st.nsamples
        }
    }

    /// WFDB-x (for `check_record`): whether the open record is an EDF file.
    pub(crate) fn wfdbx_is_edf(&self) -> bool {
        self.sig.isedf != 0
    }

    /// WFDB-x (for `check_record`): the checksum accumulator of each open
    /// input signal (the header's checksum less the samples read so far).
    pub(crate) fn wfdbx_cksum_residuals(&self) -> Vec<i32> {
        let st = &self.sig;
        st.isd[..st.nisig as usize]
            .iter()
            .map(|s| s.info.cksum)
            .collect()
    }

    /// WFDB-x (for `check_record`): the size of the file of each open input
    /// signal group, if it is a local file (`None` otherwise).
    pub(crate) fn wfdbx_group_file_sizes(&self) -> Vec<Option<u64>> {
        let st = &self.sig;
        st.igd[..st.nigroup as usize]
            .iter()
            .map(|g| g.fp.as_ref().and_then(WfdbFile::local_size))
            .collect()
    }

    /// WFDB-x (for the high-level API): the base time, in milliseconds
    /// after midnight (C `btime`), and the base date, as (year, month, day)
    /// (`None` if the header gives no date: C `bdate` 0).
    pub(crate) fn wfdbx_base_time_date(&self) -> (i64, Option<[i32; 3]>) {
        let st = &self.sig;
        let date = (st.bdate != 0).then(|| julian_to_ymd(st.bdate));
        (st.btime, date)
    }

    /// C `setbasecount(count)`: set the base counter value.
    ///
    /// Translation of the C function setbasecount() (lib/signal.c, WFDB
    /// 10.7.0): same arguments and results.
    pub fn setbasecount(&mut self, counter: f64) {
        self.sig.bcount = counter;
    }

    /// C `strtim(string)`: converts a time string to a sample number.
    ///
    /// The string may be an elapsed time (`"1:02:03.5"`, `"10"` seconds), a
    /// sample number (`"s1000"`), a time of day (`"[12:00:00]"`, with an
    /// optional date), `"e"` (the end of the record), `"i"` (the current
    /// position of the input signals), or `"o"` (that of the output
    /// signals).
    ///
    /// # Returns
    ///
    /// The number of samples (`> 0`) for an elapsed time; the negated
    /// elapsed time from the start of the record for a time of day; 0 for
    /// the base time, or for an incorrectly formatted string.
    ///
    /// WFDB-x: if no sampling frequency is specified and the string needs
    /// one (see [`Wfdb::wfdbx_time_needs_freq`]), reports an error and
    /// returns 0.
    ///
    /// Translation of the C function strtim() (lib/signal.c, WFDB 10.7.0):
    /// same arguments and results. Differences: if the string needs a sampling
    /// frequency and none is specified, it reports an error and returns 0 (the
    /// original assumed 1 sample per second); see docs/DIVERGENCES.md.
    pub fn strtim(&mut self, string: impl AsRef<[u8]>) -> i64 {
        let string = string.as_ref();
        let mut f = self.tfreq();
        if f <= 0.0 {
            // WFDB-x: no default sampling frequency (C used 1 sample per
            // second)
            if self.wfdbx_time_needs_freq(string) != 0 {
                self.wfdb_error("strtim: sampling frequency is not specified\n");
                return 0;
            }
            f = 1.0; // not used
        }
        self.fstrtim(string, f)
    }

    /// C `datstr(date)`: a Julian date as ` dd/mm/yyyy` (with a leading
    /// space).
    ///
    /// Translation of the C function datstr() (lib/signal.c, WFDB 10.7.0): same
    /// arguments and results.
    pub fn datstr(&mut self, date: i64) -> Vec<u8> {
        let [y, m, d] = julian_to_ymd(date);
        let mut ds = cformat!(b" %02d/%02d/%d", d, m, y);
        ds.truncate(DATE_STRING_LEN);
        self.sig.date_string = ds.clone();
        self.sig.pdays = -1;
        ds
    }

    /// C `strdat(string)`: the Julian date of a `dd/mm/yyyy` date (0 if
    /// it is invalid).
    ///
    /// Translation of the C function strdat() (lib/signal.c, WFDB 10.7.0): same
    /// arguments and results.
    pub fn strdat(&mut self, string: impl AsRef<[u8]>) -> i64 {
        let string = cstd::cstr(string.as_ref());
        let Some(mp) = strchr(string, b'/') else {
            return 0;
        };
        let Some(yp) = strchr(&string[mp + 1..], b'/').map(|k| k + mp + 1) else {
            return 0;
        };
        let d = strtol10(string) as i32;
        if !(1..=31).contains(&d) {
            return 0;
        }
        let m = strtol10(&string[mp + 1..]) as i32;
        if !(1..=12).contains(&m) {
            return 0;
        }
        let y = strtol10(&string[yp + 1..]) as i32;
        if y == 0 {
            return 0;
        }
        let (jy, jm) = if m > 2 { (y, m + 1) } else { (y - 1, m + 13) };
        let mut date: i64 = if jy > 0 {
            d2l(365.25 * jy as f64)
        } else {
            -d2l(-365.25 * (jy as f64 + 0.25))
        };
        date += (d2i(30.6001 * jm as f64) + d) as i64 + 1720995;
        if d as i64 + 31 * (m as i64 + 12 * y as i64) >= IGREG_DMY {
            // 15/10/1582: Gregorian calendar correction
            let gcorr = d2i(0.01 * jy as f64);
            date += (2 - gcorr + d2i(0.25 * gcorr as f64)) as i64;
        }
        date
    }

    /// WFDB-x: the gain of signal `s` for the unit conversion functions
    /// (named `func` in error messages), or 0 after reporting an error if
    /// `s` is not a valid signal number or the signal is uncalibrated. The
    /// C library assumed WFDB_DEFGAIN (200 adu per physical unit) instead.
    /// In legacy mode, as in C: WFDB_DEFGAIN for an uncalibrated signal or
    /// an invalid signal number, without an error.
    fn conversion_gain(&mut self, func: &str, s: u32) -> f64 {
        if self.sig.legacy {
            // WFDB-x: legacy mode (original behavior)
            let g = self.baseline_gain(s).1;
            return if g == 0.0 { WFDB_DEFGAIN } else { g };
        }
        if s >= self.sig.nvsig as u32 {
            let msg = cformat!(b"%s: invalid signal number %u\n", func, s);
            self.wfdb_error(msg);
            return 0.0;
        }
        let g = self.sig.vsd[s as usize].info.gain;
        if g == 0.0 {
            let msg = cformat!(b"%s: signal %u is uncalibrated\n", func, s);
            self.wfdb_error(msg);
        }
        g
    }

    /// The baseline and gain of signal `s`, or (0, WFDB_DEFGAIN) if `s` is
    /// not a valid signal number (possible in legacy mode only).
    fn baseline_gain(&self, s: u32) -> (i32, f64) {
        let st = &self.sig;
        if s < st.nvsig.max(0) as u32 {
            let i = &st.vsd[s as usize].info;
            (i.baseline, i.gain)
        } else {
            (0, WFDB_DEFGAIN)
        }
    }

    /// C `adumuv(s, a)`: convert ADC units to microvolts.
    ///
    /// WFDB-x: returns `WFDB_INVALID_SAMPLE` (after reporting an error) if
    /// `s` is invalid or the signal is uncalibrated.
    ///
    /// Translation of the C function adumuv() (lib/signal.c, WFDB 10.7.0):
    /// same arguments and results. Differences: an uncalibrated signal or an
    /// invalid signal number is an error (the original assumed a gain of 200);
    /// see docs/DIVERGENCES.md.
    pub fn adumuv(&mut self, s: u32, a: i32) -> i32 {
        let g = self.conversion_gain("adumuv", s);
        if g == 0.0 {
            return WFDB_INVALID_SAMPLE;
        }
        let x = a as f64 * 1000.0 / g;
        if x >= 0.0 {
            d2i(x + 0.5)
        } else {
            d2i(x - 0.5)
        }
    }

    /// C `muvadu(s, v)`: convert microvolts to ADC units.
    ///
    /// WFDB-x: returns `WFDB_INVALID_SAMPLE` (after reporting an error) if
    /// `s` is invalid or the signal is uncalibrated.
    ///
    /// Translation of the C function muvadu() (lib/signal.c, WFDB 10.7.0):
    /// same arguments and results. Differences: an uncalibrated signal or an
    /// invalid signal number is an error (the original assumed a gain of 200);
    /// see docs/DIVERGENCES.md.
    pub fn muvadu(&mut self, s: u32, v: i32) -> i32 {
        let g = self.conversion_gain("muvadu", s);
        if g == 0.0 {
            return WFDB_INVALID_SAMPLE;
        }
        let x = g * v as f64 * 0.001;
        if x >= 0.0 {
            d2i(x + 0.5)
        } else {
            d2i(x - 0.5)
        }
    }

    /// C `aduphys(s, a)`: convert ADC units to physical units.
    ///
    /// WFDB-x: returns NaN (after reporting an error) if `s` is invalid or
    /// the signal is uncalibrated.
    ///
    /// Translation of the C function aduphys() (lib/signal.c, WFDB 10.7.0):
    /// same arguments and results. Differences: an uncalibrated signal or an
    /// invalid signal number is an error (the original assumed a gain of 200);
    /// see docs/DIVERGENCES.md.
    pub fn aduphys(&mut self, s: u32, a: i32) -> f64 {
        let g = self.conversion_gain("aduphys", s);
        if g == 0.0 {
            return f64::NAN;
        }
        let b = self.baseline_gain(s).0 as f64;
        (a as f64 - b) / g
    }

    /// C `physadu(s, v)`: convert physical units to ADC units.
    ///
    /// WFDB-x: returns `WFDB_INVALID_SAMPLE` (after reporting an error) if
    /// `s` is invalid or the signal is uncalibrated.
    ///
    /// Translation of the C function physadu() (lib/signal.c, WFDB 10.7.0):
    /// same arguments and results. Differences: an uncalibrated signal or an
    /// invalid signal number is an error (the original assumed a gain of 200);
    /// see docs/DIVERGENCES.md.
    pub fn physadu(&mut self, s: u32, v: f64) -> i32 {
        let g = self.conversion_gain("physadu", s);
        if g == 0.0 {
            return WFDB_INVALID_SAMPLE;
        }
        let b = self.baseline_gain(s).0;
        let v = v * g;
        if v >= 0.0 {
            d2i(v + 0.5).wrapping_add(b)
        } else {
            d2i(v - 0.5).wrapping_add(b)
        }
    }

    /// C `sample(s, t)`: sample number `t` of input signal `s` (buffered
    /// random access); see [`Wfdb::sample_valid`].
    ///
    /// Translation of the C function sample() (lib/signal.c, WFDB 10.7.0): same
    /// arguments and results.
    pub fn sample(&mut self, s: u32, t: i64) -> i32 {
        let mut t = t;
        let nsig = self.sig.nvsig.max(self.sig.nisig as i32).max(0);
        // getvec may store tspf samples per call.
        let stride = nsig as i64;

        // Allocate the sample buffer on the first call.
        if !self.sig.have_sbuf {
            let need = self.vec_need();
            let st = &mut self.sig;
            let width = nsig.max(st.tspf).max(0) as usize;
            let w = width.max(1);
            st.sbuf = vec![0; w * BUFLN as usize + width.max(need)];
            self.sig.have_sbuf = true;
            self.sig.sample_tt = -1;
        }

        // If the caller requested a sample from an unavailable signal,
        // return an invalid value. Note that sample_vflag is not cleared in
        // this case.
        if s >= nsig as u32 {
            self.sig.sample_vflag = -1;
            return WFDB_INVALID_SAMPLE;
        }

        // If the caller specified a negative sample number, prepare to
        // return sample 0.
        if t < 0 {
            t = 0;
        }

        // If the caller has requested a sample that is no longer in the
        // buffer, or that is further ahead than the length of the buffer,
        // reset the signal file pointer(s).
        let tt = self.sig.sample_tt;
        if t <= tt - BUFLN || t > tt + BUFLN {
            let mut tt = t - BUFLN;
            if tt < 0 {
                tt = -1;
            }
            self.sig.sample_tt = tt;
            if self.isigsettime(tt + 1) < 0 {
                self.sig.sample_vflag = 0;
                return WFDB_INVALID_SAMPLE;
            }
        }
        // If the requested sample is not yet in the buffer, read and buffer
        // more samples. If we reach the end of the record, clear
        // sample_vflag and return the last valid value.
        while t > self.sig.sample_tt {
            self.sig.sample_tt += 1;
            let pos = (stride * (self.sig.sample_tt & (BUFLN - 1))) as usize;
            let mut sb = std::mem::take(&mut self.sig.sbuf);
            let r = self.getvec(&mut sb[pos..]);
            self.sig.sbuf = sb;
            if r < 0 {
                self.sig.sample_tt -= 1;
                self.sig.sample_vflag = 0;
                let st = &self.sig;
                let k = (stride * (st.sample_tt & (BUFLN - 1))) as usize + s as usize;
                return st.sbuf[k];
            }
        }

        // The requested sample is in the buffer. Set sample_vflag and
        // return the requested sample.
        let st = &mut self.sig;
        let v = st.sbuf[(stride * (t & (BUFLN - 1))) as usize + s as usize];
        st.sample_vflag = if v == WFDB_INVALID_SAMPLE { -1 } else { 1 };
        v
    }

    /// C `sample_valid()`: 1 if the value returned by the last `sample()`
    /// call was valid, -1 if it was invalid, 0 at the end of the record.
    ///
    /// Translation of the C function sample_valid() (lib/signal.c, WFDB
    /// 10.7.0): same arguments and results.
    pub fn sample_valid(&mut self) -> i32 {
        self.sig.sample_vflag
    }
}

// ---------------------------------------------------------------------------
// Free functions (default instance)

/// C `isigopen` on the default instance (see [`Wfdb::isigopen`]).
///
/// Translation of the C function isigopen() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results. Differences: the signal files and segments named in
/// the header are read only from the header's directory, and no sampling
/// frequency, gain, ADC resolution or units are assumed; see
/// docs/DIVERGENCES.md.
pub fn isigopen(record: impl OptBytes, siarray: &mut [Siginfo], nsig: i32) -> i32 {
    with_default(|w| w.isigopen(record, siarray, nsig))
}

/// C `osigopen` on the default instance (see [`Wfdb::osigopen`]).
///
/// Translation of the C function osigopen() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results. Differences: an output signal file that is one of
/// the input files of the open record is refused; see docs/DIVERGENCES.md.
pub fn osigopen(record: impl OptBytes, siarray: &mut [Siginfo], nsig: u32) -> i32 {
    with_default(|w| w.osigopen(record, siarray, nsig))
}

/// C `osigfopen` on the default instance (see [`Wfdb::osigfopen`]).
///
/// Translation of the C function osigfopen() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results. Differences: an output signal file that is one of
/// the input files of the open record is refused; see docs/DIVERGENCES.md.
pub fn osigfopen(siarray: &[Siginfo], nsig: u32) -> i32 {
    with_default(|w| w.osigfopen(siarray, nsig))
}

/// C `findsig` on the default instance (see [`Wfdb::findsig`]).
///
/// Translation of the C function findsig() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
pub fn findsig(p: impl AsRef<[u8]>) -> i32 {
    with_default(|w| w.findsig(p))
}

/// C `getspf` on the default instance (see [`Wfdb::getspf`]).
///
/// Translation of the C function getspf() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
pub fn getspf() -> i32 {
    with_default(super::wfdb::Wfdb::getspf)
}

/// C `setgvmode` on the default instance (see [`Wfdb::setgvmode`]).
///
/// Translation of the C function setgvmode() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
pub fn setgvmode(mode: i32) {
    with_default(|w| w.setgvmode(mode));
}

/// C `getgvmode` on the default instance (see [`Wfdb::getgvmode`]).
///
/// Translation of the C function getgvmode() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
pub fn getgvmode() -> i32 {
    with_default(super::wfdb::Wfdb::getgvmode)
}

/// C `setifreq` on the default instance (see [`Wfdb::setifreq`]).
///
/// Translation of the C function setifreq() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results. Differences: it fails if the sampling frequency of
/// the input record is not specified; see docs/DIVERGENCES.md.
pub fn setifreq(f: f64) -> i32 {
    with_default(|w| w.setifreq(f))
}

/// C `getifreq` on the default instance (see [`Wfdb::getifreq`]).
///
/// Translation of the C function getifreq() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
pub fn getifreq() -> f64 {
    with_default(super::wfdb::Wfdb::getifreq)
}

/// C `getvec` on the default instance (see [`Wfdb::getvec`]).
///
/// Translation of the C function getvec() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
pub fn getvec(vector: &mut [i32]) -> i32 {
    with_default(|w| w.getvec(vector))
}

/// C `getframe` on the default instance (see [`Wfdb::getframe`]).
///
/// Translation of the C function getframe() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
pub fn getframe(vector: &mut [i32]) -> i32 {
    with_default(|w| w.getframe(vector))
}

/// C `getvecs` on the default instance (see [`Wfdb::getvecs`]).
///
/// Part of WFDB-x; not in the original WFDB package.
pub fn getvecs(out: &mut [i32], n: i64) -> i64 {
    with_default(|w| w.getvecs(out, n))
}

/// `getvecs_status` on the default instance (see [`Wfdb::getvecs_status`]).
///
/// Part of WFDB-x; not in the original WFDB package.
pub fn getvecs_status(out: &mut [i32], n: i64) -> (i64, i32) {
    with_default(|w| w.getvecs_status(out, n))
}

/// C `putvec` on the default instance (see [`Wfdb::putvec`]).
///
/// Translation of the C function putvec() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
pub fn putvec(vector: &[i32]) -> i32 {
    with_default(|w| w.putvec(vector))
}

/// C `isigsettime` on the default instance (see [`Wfdb::isigsettime`]).
///
/// Translation of the C function isigsettime() (lib/signal.c, WFDB 10.7.0):
/// same arguments and results.
pub fn isigsettime(t: i64) -> i32 {
    with_default(|w| w.isigsettime(t))
}

/// C `isgsettime` on the default instance (see [`Wfdb::isgsettime`]).
///
/// Translation of the C function isgsettime() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
pub fn isgsettime(g: u32, t: i64) -> i32 {
    with_default(|w| w.isgsettime(g, t))
}

/// C `tnextvec` on the default instance (see [`Wfdb::tnextvec`]).
///
/// Translation of the C function tnextvec() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
pub fn tnextvec(s: u32, t: i64) -> i64 {
    with_default(|w| w.tnextvec(s, t))
}

/// C `setibsize` on the default instance (see [`Wfdb::setibsize`]).
///
/// Translation of the C function setibsize() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
pub fn setibsize(n: i32) -> i32 {
    with_default(|w| w.setibsize(n))
}

/// C `setobsize` on the default instance (see [`Wfdb::setobsize`]).
///
/// Translation of the C function setobsize() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
pub fn setobsize(n: i32) -> i32 {
    with_default(|w| w.setobsize(n))
}

/// C `newheader` on the default instance (see [`Wfdb::newheader`]).
///
/// Translation of the C function newheader() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results. Differences: a header written under a path names the
/// record and its signal files relative to its own directory, and only the
/// record's own name (the last component) is checked; see docs/DIVERGENCES.md.
pub fn newheader(record: impl AsRef<[u8]>) -> i32 {
    with_default(|w| w.newheader(record))
}

/// C `setheader` on the default instance (see [`Wfdb::setheader`]).
///
/// Translation of the C function setheader() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results. Differences: a header written under a path names the
/// record and its signal files relative to its own directory, and only the
/// record's own name (the last component) is checked; see docs/DIVERGENCES.md.
pub fn setheader(record: impl AsRef<[u8]>, siarray: &mut [Siginfo], nsig: u32) -> i32 {
    with_default(|w| w.setheader(record, siarray, nsig))
}

/// C `getseginfo` on the default instance (see [`Wfdb::getseginfo`]).
///
/// Translation of the C function getseginfo() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
pub fn getseginfo(sarray: &mut Option<Vec<Seginfo>>) -> i32 {
    with_default(|w| w.getseginfo(sarray))
}

/// C `wfdbgetskew` on the default instance (see [`Wfdb::wfdbgetskew`]).
///
/// Translation of the C function wfdbgetskew() (lib/signal.c, WFDB 10.7.0):
/// same arguments and results.
pub fn wfdbgetskew(s: u32) -> i32 {
    with_default(|w| w.wfdbgetskew(s))
}

/// C `wfdbsetiskew` on the default instance (see [`Wfdb::wfdbsetiskew`]).
///
/// Translation of the C function wfdbsetiskew() (lib/signal.c, WFDB 10.7.0):
/// same arguments and results.
pub fn wfdbsetiskew(s: u32, skew: i32) {
    with_default(|w| w.wfdbsetiskew(s, skew));
}

/// C `wfdbsetskew` on the default instance (see [`Wfdb::wfdbsetskew`]).
///
/// Translation of the C function wfdbsetskew() (lib/signal.c, WFDB 10.7.0):
/// same arguments and results.
pub fn wfdbsetskew(s: u32, skew: i32) {
    with_default(|w| w.wfdbsetskew(s, skew));
}

/// C `wfdbgetstart` on the default instance (see [`Wfdb::wfdbgetstart`]).
///
/// Translation of the C function wfdbgetstart() (lib/signal.c, WFDB 10.7.0):
/// same arguments and results.
pub fn wfdbgetstart(s: u32) -> i64 {
    with_default(|w| w.wfdbgetstart(s))
}

/// C `wfdbsetstart` on the default instance (see [`Wfdb::wfdbsetstart`]).
///
/// Translation of the C function wfdbsetstart() (lib/signal.c, WFDB 10.7.0):
/// same arguments and results.
pub fn wfdbsetstart(s: u32, bytes: i64) {
    with_default(|w| w.wfdbsetstart(s, bytes));
}

/// C `wfdbputprolog` on the default instance (see [`Wfdb::wfdbputprolog`]).
///
/// Translation of the C function wfdbputprolog() (lib/signal.c, WFDB 10.7.0):
/// same arguments and results.
pub fn wfdbputprolog(buf: &[u8], size: i64, s: u32) -> i32 {
    with_default(|w| w.wfdbputprolog(buf, size, s))
}

/// C `setinfo` on the default instance (see [`Wfdb::setinfo`]).
///
/// Translation of the C function setinfo() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
pub fn setinfo(record: impl OptBytes) -> i32 {
    with_default(|w| w.setinfo(record))
}

/// C `putinfo` on the default instance (see [`Wfdb::putinfo`]).
///
/// Translation of the C function putinfo() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
pub fn putinfo(s: impl AsRef<[u8]>) -> i32 {
    with_default(|w| w.putinfo(s))
}

/// C `getinfo` on the default instance (see [`Wfdb::getinfo`]).
///
/// Translation of the C function getinfo() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
pub fn getinfo(record: impl OptBytes) -> Option<Vec<u8>> {
    with_default(|w| w.getinfo(record))
}

/// C `wfdb_freeinfo` on the default instance (see [`Wfdb::wfdb_freeinfo`]).
///
/// Translation of the C function wfdb_freeinfo() (lib/signal.c, WFDB 10.7.0):
/// same arguments and results.
pub fn wfdb_freeinfo() {
    with_default(super::wfdb::Wfdb::wfdb_freeinfo);
}

/// C `sampfreq` on the default instance (see [`Wfdb::sampfreq`]).
///
/// Translation of the C function sampfreq() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results. Differences: it returns 0, not 250, if the header
/// gives no sampling frequency; see docs/DIVERGENCES.md.
pub fn sampfreq(record: impl OptBytes) -> f64 {
    with_default(|w| w.sampfreq(record))
}

/// C `setsampfreq` on the default instance (see [`Wfdb::setsampfreq`]).
///
/// Translation of the C function setsampfreq() (lib/signal.c, WFDB 10.7.0):
/// same arguments and results.
pub fn setsampfreq(freq: f64) -> i32 {
    with_default(|w| w.setsampfreq(freq))
}

/// C `setbasetime` on the default instance (see [`Wfdb::setbasetime`]).
///
/// Translation of the C function setbasetime() (lib/signal.c, WFDB 10.7.0):
/// same arguments and results.
pub fn setbasetime(string: impl OptBytes) -> i32 {
    with_default(|w| w.setbasetime(string))
}

/// C `timstr` on the default instance (see [`Wfdb::timstr`]).
///
/// Translation of the C function timstr() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results. Differences: if the sampling frequency is not
/// specified, it reports an error and returns the time as a sample number (the
/// original assumed 1 sample per second); see docs/DIVERGENCES.md.
pub fn timstr(t: i64) -> Vec<u8> {
    with_default(|w| w.timstr(t))
}

/// C `mstimstr` on the default instance (see [`Wfdb::mstimstr`]).
///
/// Translation of the C function mstimstr() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results. Differences: if the sampling frequency is not
/// specified, it reports an error and returns the time as a sample number (the
/// original assumed 1 sample per second); see docs/DIVERGENCES.md.
pub fn mstimstr(t: i64) -> Vec<u8> {
    with_default(|w| w.mstimstr(t))
}

/// C `getcfreq` on the default instance (see [`Wfdb::getcfreq`]).
///
/// Translation of the C function getcfreq() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
pub fn getcfreq() -> f64 {
    with_default(super::wfdb::Wfdb::getcfreq)
}

/// C `setcfreq` on the default instance (see [`Wfdb::setcfreq`]).
///
/// Translation of the C function setcfreq() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
pub fn setcfreq(freq: f64) {
    with_default(|w| w.setcfreq(freq));
}

/// C `getbasecount` on the default instance (see [`Wfdb::getbasecount`]).
///
/// Translation of the C function getbasecount() (lib/signal.c, WFDB 10.7.0):
/// same arguments and results.
pub fn getbasecount() -> f64 {
    with_default(super::wfdb::Wfdb::getbasecount)
}

/// C `setbasecount` on the default instance (see [`Wfdb::setbasecount`]).
///
/// Translation of the C function setbasecount() (lib/signal.c, WFDB 10.7.0):
/// same arguments and results.
pub fn setbasecount(counter: f64) {
    with_default(|w| w.setbasecount(counter));
}

/// C `strtim` on the default instance (see [`Wfdb::strtim`]).
///
/// Translation of the C function strtim() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results. Differences: if the string needs a sampling
/// frequency and none is specified, it reports an error and returns 0 (the
/// original assumed 1 sample per second); see docs/DIVERGENCES.md.
pub fn strtim(string: impl AsRef<[u8]>) -> i64 {
    with_default(|w| w.strtim(string))
}

/// WFDB-x addition: `wfdbx_time_needs_freq` on the default instance (see
/// [`Wfdb::wfdbx_time_needs_freq`]).
///
/// Part of WFDB-x; not in the original WFDB package.
pub fn wfdbx_time_needs_freq(string: impl AsRef<[u8]>) -> i32 {
    with_default(|w| w.wfdbx_time_needs_freq(string))
}

/// Turns legacy mode on or off for the default `Wfdb` value of the thread
/// (see [`Wfdb::wfdbx_set_legacy`]). Returns the previous setting.
///
/// Part of WFDB-x; not in the original WFDB package.
pub fn wfdbx_set_legacy(on: i32) -> i32 {
    with_default(|w| w.wfdbx_set_legacy(on))
}

/// Returns 1 if legacy mode is on for the default `Wfdb` value of the
/// thread, 0 otherwise (see [`Wfdb::wfdbx_get_legacy`]).
///
/// Part of WFDB-x; not in the original WFDB package.
pub fn wfdbx_get_legacy() -> i32 {
    with_default(|w| w.wfdbx_get_legacy())
}

/// WFDB-x addition: `wfdbx_legacy_args` on the default instance (see
/// [`Wfdb::wfdbx_legacy_args`]).
///
/// Part of WFDB-x; not in the original WFDB package.
pub fn wfdbx_legacy_args(argv: &mut Vec<Vec<u8>>) -> i32 {
    with_default(|w| w.wfdbx_legacy_args(argv))
}

/// C `datstr` on the default instance (see [`Wfdb::datstr`]).
///
/// Translation of the C function datstr() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
pub fn datstr(date: i64) -> Vec<u8> {
    with_default(|w| w.datstr(date))
}

/// C `strdat` on the default instance (see [`Wfdb::strdat`]).
///
/// Translation of the C function strdat() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
pub fn strdat(string: impl AsRef<[u8]>) -> i64 {
    with_default(|w| w.strdat(string))
}

/// C `adumuv` on the default instance (see [`Wfdb::adumuv`]).
///
/// Translation of the C function adumuv() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results. Differences: an uncalibrated signal or an invalid
/// signal number is an error (the original assumed a gain of 200); see
/// docs/DIVERGENCES.md.
pub fn adumuv(s: u32, a: i32) -> i32 {
    with_default(|w| w.adumuv(s, a))
}

/// C `muvadu` on the default instance (see [`Wfdb::muvadu`]).
///
/// Translation of the C function muvadu() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results. Differences: an uncalibrated signal or an invalid
/// signal number is an error (the original assumed a gain of 200); see
/// docs/DIVERGENCES.md.
pub fn muvadu(s: u32, v: i32) -> i32 {
    with_default(|w| w.muvadu(s, v))
}

/// C `aduphys` on the default instance (see [`Wfdb::aduphys`]).
///
/// Translation of the C function aduphys() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results. Differences: an uncalibrated signal or an invalid
/// signal number is an error (the original assumed a gain of 200); see
/// docs/DIVERGENCES.md.
pub fn aduphys(s: u32, a: i32) -> f64 {
    with_default(|w| w.aduphys(s, a))
}

/// C `physadu` on the default instance (see [`Wfdb::physadu`]).
///
/// Translation of the C function physadu() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results. Differences: an uncalibrated signal or an invalid
/// signal number is an error (the original assumed a gain of 200); see
/// docs/DIVERGENCES.md.
pub fn physadu(s: u32, v: f64) -> i32 {
    with_default(|w| w.physadu(s, v))
}

/// C `sample` on the default instance (see [`Wfdb::sample`]).
///
/// Translation of the C function sample() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
pub fn sample(s: u32, t: i64) -> i32 {
    with_default(|w| w.sample(s, t))
}

/// C `sample_valid` on the default instance (see [`Wfdb::sample_valid`]).
///
/// Translation of the C function sample_valid() (lib/signal.c, WFDB 10.7.0):
/// same arguments and results.
pub fn sample_valid() -> i32 {
    with_default(super::wfdb::Wfdb::sample_valid)
}

/// C `setmsheader` on the default instance (see [`Wfdb::setmsheader`]).
///
/// Translation of the C function setmsheader() (lib/signal.c, WFDB 10.7.0):
/// same arguments and results. Differences: a header written under a path
/// names the record and its segments relative to its own directory, and only
/// the record's own name (the last component) is checked; see
/// docs/DIVERGENCES.md.
pub fn setmsheader<S: AsRef<[u8]>>(
    record: impl AsRef<[u8]>,
    segment_name: &[S],
    nsegments: u32,
) -> i32 {
    with_default(|w| w.setmsheader(record, segment_name, nsegments))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// meansamp as in C: for a power of 2, n halvings of the sum.
    fn meansamp_halving(s: &[i32], n: i32) -> i32 {
        let mut sum: i64 = (n / 2) as i64;
        for &x in &s[..n.max(0) as usize] {
            if x == WFDB_INVALID_SAMPLE {
                return WFDB_INVALID_SAMPLE;
            }
            sum += x as i64;
        }
        let neg = (sum < 0) as i64;
        if n & (n - 1) != 0 {
            ((sum + neg) / n as i64 - neg) as i32
        } else {
            let mut n = n;
            loop {
                n /= 2;
                if n == 0 {
                    break;
                }
                sum = (sum - (sum < 0) as i64) / 2;
            }
            sum as i32
        }
    }

    #[test]
    fn meansamp_as_halving() {
        let mut r: u64 = 12345;
        let mut next = || {
            r = r
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            (r >> 33) as i64
        };
        let mut s = [0i32; 64];
        for k in 0..200000 {
            let n = (next() % 65) as i32;
            let big = k % 3 == 0;
            for x in s.iter_mut() {
                *x = if big {
                    (next() as i32).wrapping_mul(2654435761u32 as i32)
                } else {
                    (next() % 9) as i32 - 4
                };
                if *x == WFDB_INVALID_SAMPLE && next() % 2 == 0 {
                    *x = 0;
                }
            }
            if k % 50 == 0 && n > 0 {
                s[(next() % n as i64) as usize] = WFDB_INVALID_SAMPLE;
            }
            assert_eq!(
                meansamp(&s, n),
                meansamp_halving(&s, n),
                "{:?} {n}",
                &s[..n as usize]
            );
        }
    }
}
