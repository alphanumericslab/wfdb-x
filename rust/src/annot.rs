//! Annotation I/O (port of `lib/annot.c`): MIT and AHA annotation files,
//! annotation code mnemonics and descriptions, annotation time resolution.
//!
//! This module contains `annopen`, `getann`, `ungetann`, `putann`,
//! `iannsettime`, the annotation code/mnemonic/description conversion
//! functions (`ecgstr`, `strecg`, `setecgstr`, `annstr`, `strann`,
//! `setannstr`, `anndesc`, `setanndesc`), the time resolution functions
//! (`setafreq`, `getafreq`, `setiafreq`, `getiafreq`, `getiaorigfreq`),
//! `iannclose`, `oannclose`, and the library-private functions
//! `wfdb_anclose` and `wfdb_oaflush`.
//!
//! Modification labels (`NOTE` annotations at time 0 that redefine
//! annotation mnemonics and descriptions, and the time resolution record)
//! are read by `annopen` and written before the first annotation of each
//! output file. Output files whose annotations are not in canonical order
//! are sorted when they are closed, in this process, with the result of the
//! `sortann` program (in legacy mode, by running `sortann`,
//! [`crate::wfdbio::run_sortann`], as the C library does).
//
// Copyright (C) 1989-2013 George B. Moody (original C implementation,
// lib/annot.c; revised 2015-2020 by Benjamin Moody).
// Rust implementation part of wfdb-x, Reza Sameni, Oct 2026.
// Design decision (Reza Sameni, after a code review, Oct 2026): oannclose
// rearranges an out-of-order output annotation file itself, in the same
// process (sort_ann_file), with a result identical to that of the sortann
// program, which the C library ran through the shell (and found only if it
// was in the PATH). The sort (AnnList, shared with the sortann tool) no
// longer loses out-of-order annotations at time 0, which the original
// insertion took for duplicates of its list head (decided by Reza Sameni,
// Oct 2026). The original behavior remains available with --legacy (see
// docs/DIVERGENCES.md).
// GNU Library General Public License, version 2 or later (see LICENSE.LIB).

use crate::cformat;
use crate::cstd;
use crate::ecgcodes::{wfdb_ammap, wfdb_mamap, ACMAX, NOTE, NOTQRS};
use crate::types::*;
use crate::wfdb::{with_default, OptBytes, Wfdb, NULL};
use crate::wfdbio::{local_fopen, run_sortann, wfdb_striphea, WfdbFile};

// Annotation word format
const CODE: u32 = 0o176000; // annotation code segment of word
const CS: u32 = 10; // places by which code must be shifted
const DATA: u32 = 0o1777; // data segment of annotation word
const MAXRR: u64 = 0o1777; // longest interval coded in a word

const MAXSKIP: i64 = 0x7fffffff; // largest interval of a SKIP
const MINSKIP: i64 = -0x7fffffff; // smallest interval of a SKIP

// Pseudo-annotation codes
const PAMIN: u32 = 59 << CS;
const SKIP: u32 = 59 << CS; // long null annotation
const NUM: u32 = 60 << CS; // change 'num' field
const SUB: u32 = 61 << CS; // subtype
const CHN: u32 = 62 << CS; // change 'chan' field
const AUX: u32 = 63 << CS; // auxiliary information

// Constants for AHA annotation files only
const ABLKSIZ: i64 = 1024; // AHA annotation file block length
const AUXBUFLEN: usize = 771; // size of the aux string buffer
const AUXLEN: usize = 6; // length of AHA aux field
const EOAF: u8 = 0o377; // padding for end of AHA annotation files

/// Prefix of the `NOTE` annotation that gives the time resolution of an
/// annotation file (followed by the frequency).
const TIME_RESOLUTION: &[u8] = b"## time resolution: ";

const NCODES: usize = ACMAX as usize + 1;

/// An input annotator.
#[derive(Debug)]
struct IaData {
    /// Input annotation file.
    file: WfdbFile,
    /// Input annotator information.
    info: Anninfo,
    /// Next annotation to be returned by getann.
    ann: Annotation,
    /// Pushed-back annotation from ungetann.
    pann: Annotation,
    /// Time resolution, in ticks/second.
    afreq: f64,
    /// Next word from the input file.
    word: u32,
    /// EOF-reached indicator.
    ateof: i32,
    /// Aux string buffer.
    auxstr: [u8; AUXBUFLEN],
    /// Next available position in auxstr.
    index: usize,
    /// Position of the aux string of `ann` in auxstr (-1: none).
    auxpos: i32,
    /// tmul * annotation time = sample count.
    tmul: f64,
    /// Annotation time (MIT format only).
    tt: f64,
    /// Unscaled annotation time of `ann`.
    ann_tt: f64,
    /// Unscaled annotation time of `pann`.
    pann_tt: f64,
    /// Unscaled time of the last annotation returned by getann.
    prev_tt: f64,
    /// Sample number of the last annotation returned by getann.
    prev_time: i64,
}

/// An output annotator.
#[derive(Debug)]
struct OaData {
    /// Output annotation file.
    file: WfdbFile,
    /// Output annotator information.
    info: Anninfo,
    /// Most recent annotation written by putann.
    ann: Annotation,
    /// Time resolution, in ticks/second.
    afreq: f64,
    /// Annotation serial number (AHA only).
    seqno: i32,
    /// Record with which the annotator is associated.
    rname: Vec<u8>,
    /// wfdb-x: name of the file (as created), for `sort_ann_file`.
    fname: Vec<u8>,
    /// If true, annotations are not in order.
    out_of_order: bool,
    /// If true, the table has been written.
    table_written: bool,
}

const DEFAULT_MNEMONICS: [&[u8]; NCODES] = [
    b" ", b"N", b"L", b"R", b"a", // 0 - 4
    b"V", b"F", b"J", b"A", b"S", // 5 - 9
    b"E", b"j", b"/", b"Q", b"~", // 10 - 14
    b"[15]", b"|", b"[17]", b"s", b"T", // 15 - 19
    b"*", b"D", b"\"", b"=", b"p", // 20 - 24
    b"B", b"^", b"t", b"+", b"u", // 25 - 29
    b"?", b"!", b"[", b"]", b"e", // 30 - 34
    b"n", b"@", b"x", b"f", b"(", // 35 - 39
    b")", b"r", b"[42]", b"[43]", b"[44]", // 40 - 44
    b"[45]", b"[46]", b"[47]", b"[48]", b"[49]", // 45 - 49
];

const DEFAULT_DESCRIPTIONS: [Option<&[u8]>; NCODES] = [
    Some(b""),
    Some(b"Normal beat"),
    Some(b"Left bundle branch block beat"),
    Some(b"Right bundle branch block beat"),
    Some(b"Aberrated atrial premature beat"),
    Some(b"Premature ventricular contraction"),
    Some(b"Fusion of ventricular and normal beat"),
    Some(b"Nodal (junctional) premature beat"),
    Some(b"Atrial premature beat"),
    Some(b"Supraventricular premature or ectopic beat"),
    Some(b"Ventricular escape beat"),
    Some(b"Nodal (junctional) escape beat"),
    Some(b"Paced beat"),
    Some(b"Unclassifiable beat"),
    Some(b"Change in signal quality"),
    None,
    Some(b"Isolated QRS-like artifact"),
    None,
    Some(b"ST segment change"),
    Some(b"T-wave change"),
    Some(b"Systole"),
    Some(b"Diastole"),
    Some(b"Comment annotation"),
    Some(b"Measurement annotation"),
    Some(b"P-wave peak"),
    Some(b"Bundle branch block beat (unspecified)"),
    Some(b"(Non-captured) pacemaker artifact"),
    Some(b"T-wave peak"),
    Some(b"Rhythm change"),
    Some(b"U-wave peak"),
    Some(b"Beat not classified during learning"),
    Some(b"Ventricular flutter wave"),
    Some(b"Start of ventricular flutter/fibrillation"),
    Some(b"End of ventricular flutter/fibrillation"),
    Some(b"Atrial escape beat"),
    Some(b"Supraventricular escape beat"),
    Some(b"Link to external data (aux contains URL)"),
    Some(b"Non-conducted P-wave (blocked APC)"),
    Some(b"Fusion of paced and normal beat"),
    Some(b"Waveform onset"),
    Some(b"Waveform end"),
    Some(b"R-on-T premature ventricular contraction"),
    None,
    None,
    None,
    None,
    None,
    None,
    None,
    None,
];

impl IaData {
    /// A new input annotator reading `file` (its format is still to be
    /// determined: see [`ann_file_format`]).
    fn new(file: WfdbFile, info: Anninfo) -> IaData {
        IaData {
            file,
            info,
            ann: Annotation::default(),
            pann: Annotation::default(),
            afreq: 0.0,
            word: 0,
            ateof: 0,
            auxstr: [0; AUXBUFLEN],
            index: 0,
            auxpos: -1,
            tmul: 0.0,
            tt: 0.0,
            ann_tt: 0.0,
            pann_tt: 0.0,
            prev_tt: 0.0,
            prev_time: 0,
        }
    }
}

impl OaData {
    /// A new output annotator writing `file` (named `fname`) for record
    /// `rname`.
    fn new(file: WfdbFile, info: Anninfo, rname: Vec<u8>, fname: Vec<u8>) -> OaData {
        OaData {
            file,
            info,
            ann: Annotation::default(),
            afreq: 0.0,
            seqno: 0,
            rname,
            fname,
            out_of_order: false,
            table_written: false,
        }
    }
}

/// wfdb-x: a table of annotation type definitions: mnemonics, descriptions,
/// and flags marking the modified types. [`AnnState`] holds that of the
/// library; `sort_ann_file` uses one of its own.
#[derive(Clone, Debug)]
struct AnnDefs {
    /// Mnemonic strings for each code.
    astring: Vec<Vec<u8>>,
    /// Descriptions for each code.
    tstring: Vec<Option<Vec<u8>>>,
    /// Mnemonic or description modified (by `setannstr`, `setanndesc`, or
    /// a definition read from a file).
    modified: [bool; NCODES],
}

impl Default for AnnDefs {
    /// The default definitions (none modified).
    fn default() -> Self {
        AnnDefs {
            astring: DEFAULT_MNEMONICS.iter().map(|s| s.to_vec()).collect(),
            tstring: DEFAULT_DESCRIPTIONS
                .iter()
                .map(|s| s.map(<[u8]>::to_vec))
                .collect(),
            modified: [false; NCODES],
        }
    }
}

impl AnnDefs {
    /// The body of `setannstr` (`desc` false) and `setanndesc` (`desc`
    /// true): with a positive code, the change is marked as a modification;
    /// with a negative one (-code is modified), it is not. Returns 0, or -1
    /// if the code is illegal.
    fn set(&mut self, desc: bool, code: i32, s: &[u8]) -> i32 {
        let mflag = code > 0;
        let code = if mflag { code } else { code.wrapping_neg() };
        if !(0..=ACMAX).contains(&code) {
            return -1;
        }
        let c = code as usize;
        let changed = if desc {
            self.tstring[c].as_deref() != Some(s)
        } else {
            self.astring[c] != s
        };
        if changed {
            if desc {
                self.tstring[c] = Some(s.to_vec());
            } else {
                self.astring[c] = s.to_vec();
            }
            if mflag {
                self.modified[c] = true;
            }
        }
        0
    }
}

/// Error messages produced by the annotator functions that do not have
/// access to the library instance, to be reported by the caller
/// ([`Wfdb::report`]).
type Msgs = Vec<Vec<u8>>;

/// The state of `annot.c` (part of [`Wfdb`]): input and output annotators,
/// mnemonic and description tables, annotation time resolution, ...
///
/// Dropping it flushes the output annotation files but writes no end
/// marks (as in a C program that exits without closing them).
#[derive(Debug)]
pub struct AnnState {
    iad: Vec<IaData>,
    oad: Vec<OaData>,
    /// Time resolution for new output annotators.
    oafreq: f64,
    /// If < 0, error while closing files (-6: annotations out of order,
    /// -7: write error).
    annclose_error: i32,
    /// ECG mnemonics for each code.
    cstring: Vec<Vec<u8>>,
    /// Annotation type definitions (mnemonics and descriptions).
    defs: AnnDefs,
}

impl Default for AnnState {
    fn default() -> Self {
        AnnState {
            iad: Vec::new(),
            oad: Vec::new(),
            oafreq: 0.0,
            annclose_error: 0,
            cstring: DEFAULT_MNEMONICS.iter().map(|s| s.to_vec()).collect(),
            defs: AnnDefs::default(),
        }
    }
}

/// Round a double to the nearest time, with halfway cases always rounded
/// up.
fn round_to_time(x: f64) -> i64 {
    if x.is_nan() {
        return WFDB_TIME_MIN; // as on x86
    }
    if x >= 0.0 {
        if x >= WFDB_TIME_MAX as f64 {
            return WFDB_TIME_MAX;
        }
        let t = x as i64;
        if x - t as f64 >= 0.5 {
            t + 1
        } else {
            t
        }
    } else {
        if x <= WFDB_TIME_MIN as f64 {
            return WFDB_TIME_MIN;
        }
        let t = x as i64;
        if x - (t as f64) < -0.5 {
            t - 1
        } else {
            t
        }
    }
}

/// The aux string of an annotation as a C string (the data following the
/// length byte, up to the first null).
fn aux_text(aux: &[u8]) -> &[u8] {
    cstd::cstr(aux.get(1..).unwrap_or(b""))
}

/// An aux field (length byte first) holding `s`.
fn make_aux(s: &[u8]) -> Vec<u8> {
    let mut a = vec![s.len() as u8];
    a.extend_from_slice(s);
    a
}

/// The aux string at position `pos` of the aux buffer: the length byte, the
/// data, and any following bytes up to a null (as a C string would be read).
fn aux_from_buffer(ia: &IaData, pos: usize) -> Vec<u8> {
    let len = ia.auxstr[pos] as usize;
    let mut s = vec![len as u8];
    let mut i = pos + 1;
    while i < AUXBUFLEN && (i - pos - 1 < len || ia.auxstr[i] != 0) {
        s.push(ia.auxstr[i]);
        i += 1;
    }
    s
}

/// Read the next annotation of an input annotator into `ia.ann` (the
/// second part of getann). Returns an error message to report, if any.
fn getann_next(ia: &mut IaData) -> Option<Vec<u8>> {
    let mut msg = None;
    let f = &mut ia.file;
    if ia.info.stat == WFDB_AHA_READ {
        if (ia.word & 0o377) == EOAF as u32 {
            // logical end of file
            ia.ateof = 1;
            return None;
        }
        let a = (ia.word >> 8) as i32; // AHA annotation code
        ia.ann.anntyp = wfdb_ammap(a) as i8;
        ia.ann_tt = f.g32() as f64;
        if f.g16() <= 0 {
            // serial number (starts at 1)
            msg = Some(cformat!(
                b"getann: unexpected annot number in annotator %s\n",
                ia.info.name
            ));
        }
        ia.ann.subtyp = f.getc() as i8;
        if a == b'U' as i32 && ia.ann.subtyp == 0 {
            ia.ann.subtyp = -1; // unreadable (noise subtype -1)
        }
        ia.ann.chan = f.getc() as u8;
        // (AHA aux strings, with their length byte and NUL, are kept in the
        // first 256 bytes of the buffer, as in C.)
        if ia.index >= 256 - (AUXLEN + 2) {
            ia.index = 0;
        }
        // read aux data
        let ix = ia.index;
        f.read(&mut ia.auxstr[ix + 1..ix + 1 + AUXLEN]);
        // There is very limited space in AHA format files for auxiliary
        // information, so no length byte is recorded; instead, we assume
        // that if the first byte of auxiliary data is not null, that up to
        // AUXLEN bytes may be significant.
        if ia.auxstr[ix + 1] != 0 {
            ia.auxstr[ix] = AUXLEN as u8;
            ia.auxpos = ix as i32; // save position
            ia.auxstr[ix + 1 + AUXLEN] = 0; // add a null
            ia.index += AUXLEN + 2; // update buffer index
        } else {
            ia.auxpos = -1;
        }
        ia.word = f.g16() as u32;
    } else {
        // MIT-format input file
        if ia.word == 0 {
            // logical end of file
            ia.ateof = 1;
            return None;
        }
        ia.tt += (ia.word & DATA) as f64; // annotation time
        ia.ann_tt = ia.tt;
        ia.ann.anntyp = ((ia.word & CODE) >> CS) as i8;
        ia.ann.subtyp = 0; // reset subtype field
        ia.auxpos = -1; // reset aux field
        loop {
            ia.word = f.g16() as u32;
            if (ia.word & CODE) < PAMIN || f.eof() {
                break;
            }
            match ia.word & CODE {
                // process pseudo-annotations
                SKIP => ia.tt += f.g32() as f64,
                SUB => ia.ann.subtyp = (DATA & ia.word) as i8,
                CHN => ia.ann.chan = (DATA & ia.word) as u8,
                NUM => ia.ann.num = (DATA & ia.word) as i8,
                AUX => {
                    // auxiliary information
                    let len = (ia.word & 0o377) as usize; // length of auxiliary data
                    if ia.index >= AUXBUFLEN - 2 - len {
                        ia.index = 0; // buffer index
                    }
                    ia.auxpos = ia.index as i32; // save position
                    ia.auxstr[ia.index] = len as u8;
                    ia.index += 1;
                    // Now read the data. Note that an extra byte may be
                    // present in the annotation file to preserve word
                    // alignment; if so, this extra byte is read and then
                    // overwritten by the null below.
                    let ix = ia.index;
                    f.read(&mut ia.auxstr[ix..ix + ((len + 1) & !1)]);
                    ia.auxstr[ix + len] = 0; // add a null
                    ia.index += len + 1; // update buffer index
                }
                _ => {}
            }
        }
    }
    ia.ann.time = round_to_time(ia.ann_tt * ia.tmul);
    if ia.file.eof() {
        ia.ateof = -1;
    }
    msg
}

/// Reads the first word of the input annotation file of `ia` and returns its
/// format: [`WFDB_READ`] (MIT format; any initial null annotations are then
/// read as well) or [`WFDB_AHA_READ`]. (wfdb-x: this was part of annopen.)
fn ann_file_format(ia: &mut IaData) -> i32 {
    // Try to figure out what format the file is in. AHA-format files begin
    // with a null byte and an ASCII character which is one of the legal AHA
    // annotation codes other than '[' or ']'. MIT annotation files cannot
    // begin in this way.
    ia.word = ia.file.g16() as u32;
    let a = ((ia.word >> 8) & 0xff) as i32;
    if (ia.word & 0xff) != 0 || wfdb_ammap(a) == NOTQRS || a == b'[' as i32 || a == b']' as i32 {
        // read any initial null annotation(s)
        while (ia.word & CODE) == SKIP {
            ia.tt += ia.file.g32() as f64;
            ia.word = ia.file.g16() as u32;
        }
        return WFDB_READ;
    }
    WFDB_AHA_READ
}

/// The body of getann, for the input annotator `ia` (wfdb-x). Error
/// messages are added to `msgs`.
fn getann_ia(ia: &mut IaData, annot: &mut Annotation, msgs: &mut Msgs) -> i32 {
    if ia.pann.anntyp != 0 {
        // an annotation was pushed back
        *annot = ia.pann.clone();
        ia.pann.anntyp = 0;
        ia.prev_time = annot.time;
        ia.prev_tt = ia.pann_tt;
        return 0;
    }

    if ia.ateof != 0 {
        if ia.ateof != -1 {
            return -1; // reached logical EOF
        }
        msgs.push(cformat!(
            b"getann: unexpected EOF in annotator %s\n",
            ia.info.name
        ));
        return -3;
    }
    let aux = annot.aux.take();
    *annot = ia.ann.clone();
    ia.prev_time = annot.time;
    ia.prev_tt = ia.ann_tt;
    let retpos = ia.auxpos;
    let msg = getann_next(ia);
    if retpos >= 0 {
        // reuse the caller's buffer
        let mut v = aux.unwrap_or_default();
        v.clear();
        v.extend_from_slice(&aux_from_buffer(ia, retpos as usize));
        annot.aux = Some(v);
    } else {
        annot.aux = None;
    }
    msgs.extend(msg);
    0
}

/// The body of ungetann (after the checks), for the input annotator `ia`,
/// whose pushback buffer is empty (wfdb-x).
fn ungetann_ia(ia: &mut IaData, annot: &Annotation) {
    ia.pann = annot.clone();
    if annot.time == ia.prev_time {
        ia.pann_tt = ia.prev_tt;
    } else {
        ia.pann_tt = annot.time as f64 / ia.tmul;
    }
}

/// The body of get_ann_table (wfdb-x), for the input annotator `ia` and the
/// definition table `defs` (the library's, or that of `sort_ann_file`):
/// reads the modification labels at the beginning of the file (the time
/// resolution goes into `ia.afreq`, the definitions into `defs`). Error
/// messages are added to `msgs`.
fn read_ann_table(ia: &mut IaData, defs: &mut AnnDefs, msgs: &mut Msgs) -> i32 {
    ia.tmul = 1.0;
    ia.afreq = 0.0;

    let mut annot = Annotation::default();
    if getann_ia(ia, &mut annot, msgs) < 0 {
        // prime the pump
        return -1;
    }
    while getann_ia(ia, &mut annot, msgs) == 0
        && annot.time == 0
        && annot.anntyp as i32 == NOTE
        && annot.subtyp == 0
    {
        let aux = match &annot.aux {
            Some(a) if !a.is_empty() && a[0] >= 1 => a.clone(),
            _ => continue,
        };
        let text = aux_text(&aux);
        if text.first() == Some(&b'#') {
            if text.starts_with(TIME_RESOLUTION) {
                crate::csscanf!(&text[TIME_RESOLUTION.len()..], b"%lf", &mut ia.afreq);
            }
            continue;
        }
        let span = |s: &[u8], from: usize| {
            from + s[from..]
                .iter()
                .take_while(|&&c| c == b' ' || c == b'\t')
                .count()
        };
        let cspan = |s: &[u8], from: usize| {
            from + s[from..]
                .iter()
                .take_while(|&&c| c != b' ' && c != b'\t')
                .count()
        };
        let p1 = span(text, 0); // whitespace before code
        let (a, end) = cstd::strtol(&text[p1..], 10);
        let a = a as i32;
        if !(0..=ACMAX).contains(&a) || end == 0 {
            continue;
        }
        let p2 = cspan(text, p1 + end); // non-whitespace after code
        let p1 = span(text, p2); // whitespace before mnemonic
        let p2 = cspan(text, p1); // non-whitespace (mnemonic)
        if p2 != p1 {
            defs.set(true, a, text.get(p2 + 1..).unwrap_or(b""));
            defs.set(false, a, &text[p1..p2]);
        }
    }
    if annot.time != 0 || annot.anntyp as i32 != NOTE || annot.subtyp != 0 || annot.aux.is_none() {
        ungetann_ia(ia, &annot);
    }
    0
}

/// put_ann_table (wfdb-x: for the output annotator `oa`, number `n`, with
/// the time resolution `freq` and the definition table `defs`; the C
/// library used `oad[n]`, `oafreq`, and the library's table): writes the
/// modification labels. Error messages are added to `msgs`.
fn put_ann_table(oa: &mut OaData, n: u32, freq: f64, defs: &AnnDefs, msgs: &mut Msgs) -> i32 {
    // 0: nothing written yet; 1: time resolution written; 2: at least one
    // table entry written.
    let mut flag = 0;
    let mut annot = Annotation {
        time: 0,
        anntyp: NOTE as i8,
        ..Default::default()
    };
    if freq != oa.afreq && freq > 0.0 {
        annot.aux = Some(make_aux(&cformat!(b"## time resolution: %.12g", freq)));
        oa.afreq = freq;
        if put_ann_word(oa, n, &annot, msgs) < 0 {
            return -1;
        }
        flag = 1;
    }
    for a in 0..NCODES {
        if defs.modified[a] {
            if flag < 2 {
                // mark the beginning of the table
                annot.aux = Some(make_aux(b"## annotation type definitions"));
                if put_ann_word(oa, n, &annot, msgs) < 0 {
                    return -1;
                }
            }
            let m = &defs.astring[a];
            let s = match &defs.tstring[a] {
                Some(d) => cformat!(b"%d %s %s", a as i32, m, d),
                None => cformat!(b"%d %s ", a as i32, m),
            };
            annot.aux = Some(make_aux(&s[..s.len().min(usize::from(u8::MAX))]));
            if put_ann_word(oa, n, &annot, msgs) < 0 {
                return -1;
            }
            flag = 2;
        }
    }
    if flag == 2 {
        // if a table was written, mark its end
        annot.aux = Some(make_aux(b"## end of definitions"));
        if put_ann_word(oa, n, &annot, msgs) < 0 {
            return -1;
        }
    }
    if flag != 0 {
        // if a table was written, mark its end
        annot.anntyp = 0;
        annot.aux = None;
        if put_ann_word(oa, n, &annot, msgs) < 0 {
            return -1;
        }
    }
    0
}

/// The body of putann (after the table; wfdb-x), for the output annotator
/// `oa` (number `n`, in messages). Error messages are added to `msgs`.
fn put_ann_word(oa: &mut OaData, n: u32, annot: &Annotation, msgs: &mut Msgs) -> i32 {
    let t = annot.time;
    let f = &mut oa.file;
    let mut delta: u64 = (t as u64).wrapping_sub(oa.ann.time as u64);
    if !(annot.chan > oa.ann.chan
        || annot.num > oa.ann.num
        || t > oa.ann.time
        || (t == 0 && oa.ann.time == 0))
    {
        oa.out_of_order = true;
    }
    // aux length (a null aux, or an empty string, has none)
    let auxlen = match &annot.aux {
        Some(a) if !a.is_empty() => a[0] as usize,
        _ => 0,
    };
    if oa.info.stat == WFDB_AHA_WRITE {
        // AHA-format output file
        f.putc(0);
        f.putc(wfdb_mamap(annot.anntyp as i32, annot.subtyp as i32) as u8);
        f.p32(t);
        oa.seqno = oa.seqno.wrapping_add(1);
        f.p16(oa.seqno as u32);
        f.putc(annot.subtyp as u8);
        f.putc(annot.anntyp as u8);
        let len = auxlen.min(AUXLEN);
        let aux: &[u8] = annot.aux.as_deref().unwrap_or(b"");
        for k in 1..=len {
            f.putc(aux.get(k).copied().unwrap_or(0));
        }
        for _ in len..AUXLEN {
            f.putc(0);
        }
    } else {
        // MIT-format output file. Do not allow annotations to be
        // written at the minimum or maximum possible time value.
        if t == WFDB_TIME_MIN || t == WFDB_TIME_MAX {
            msgs.push(cformat!(
                b"putann: time overflow in annotation file %d\n",
                n
            ));
            return -1;
        }
        if t > oa.ann.time {
            while delta > MAXSKIP as u64 {
                f.p16(SKIP);
                f.p32(MAXSKIP);
                delta = delta.wrapping_sub(MAXSKIP as u64);
            }
        } else {
            while delta.wrapping_neg() > (-MINSKIP) as u64 {
                f.p16(SKIP);
                f.p32(MINSKIP);
                delta = delta.wrapping_sub(MINSKIP as u64);
            }
        }
        if annot.anntyp == 0 {
            // putann must not write a word of zeroes that would be
            // interpreted as an EOF, so it writes a SKIP to the location
            // just before the desired one; thus annwd is never 0.
            f.p16(SKIP);
            f.p32(delta.wrapping_sub(1) as i64);
            delta = 1;
        } else if delta > MAXRR {
            // skip forward by more than MAXRR, or skip backward by any
            // distance
            f.p16(SKIP);
            f.p32(delta as i64);
            delta = 0;
        }
        let annwd =
            (delta as i32 as u32).wrapping_add((annot.anntyp as i32 as u32).wrapping_shl(CS));
        f.p16(annwd);
        if annot.subtyp != 0 {
            f.p16(SUB + (DATA & annot.subtyp as i32 as u32));
        }
        if annot.chan != oa.ann.chan {
            f.p16(CHN + (DATA & annot.chan as u32));
        }
        if annot.num != oa.ann.num {
            f.p16(NUM + (DATA & annot.num as i32 as u32));
        }
        if auxlen != 0 {
            f.p16(AUX + auxlen as u32);
            let aux = annot.aux.as_deref().unwrap_or(b"");
            let mut data: Vec<u8> = aux[1..].iter().take(auxlen).copied().collect();
            data.resize(auxlen, 0);
            f.write(&data);
            if auxlen & 1 != 0 {
                f.putc(0);
            }
        }
    }
    if f.error() {
        msgs.push(cformat!(
            b"putann: write error on annotation file %s\n",
            oa.info.name
        ));
        return -1;
    }
    oa.ann = annot.clone();
    oa.ann.time = t;
    0
}

impl Wfdb {
    // -----------------------------------------------------------------------
    // Private functions (for the use of other WFDB library functions only)

    /// `wfdb_oaflush()`: flush output annotation files (called by
    /// `wfdbflush`).
    pub(crate) fn wfdb_oaflush(&mut self) {
        for oa in &mut self.ann.oad {
            oa.file.flush();
        }
    }

    /// `wfdb_anclose()`: close all annotators (called by `wfdbquit` and
    /// `annopen`).
    pub(crate) fn wfdb_anclose(&mut self) {
        for an in (0..self.ann.iad.len()).rev() {
            self.iannclose(an as u32);
        }
        for an in (0..self.ann.oad.len()).rev() {
            self.oannclose(an as u32);
        }
    }

    /// Reports the error messages `msgs` (with `wfdb_error`).
    fn report(&mut self, msgs: Msgs) {
        for m in msgs {
            self.wfdb_error(m);
        }
    }

    fn get_ann_table(&mut self, i: u32) -> i32 {
        let mut msgs = Msgs::new();
        let st = &mut self.ann;
        let status = read_ann_table(&mut st.iad[i as usize], &mut st.defs, &mut msgs);
        self.report(msgs);
        if status < 0 {
            return -1;
        }
        let f = self.getifreq();
        self.setiafreq(i, f);
        0
    }

    // -----------------------------------------------------------------------
    // WFDB library functions

    /// C `annopen(record, aiarray, nann)`: opens the annotation files of
    /// `record` for the first `nann` annotators of `aiarray`.
    ///
    /// Each [`Anninfo`] gives an annotator name (the file name suffix, e.g.
    /// `"atr"`) and a `stat` ([`WFDB_READ`], [`WFDB_WRITE`],
    /// [`WFDB_AHA_READ`] or [`WFDB_AHA_WRITE`]). Input annotators are
    /// numbered from 0 in the order given, and so are output annotators;
    /// these numbers are the `n` arguments of `getann`, `putann`, ...
    /// Unless `record` begins with `+`, previously opened annotators are
    /// closed first. Files are found as [`Wfdb::wfdb_open`] finds them
    /// (wfdb-x: input files under the input directory, output files under
    /// the output directory, or as named; legacy mode: input files in the
    /// WFDB path, output files in the current directory or the output
    /// directory).
    ///
    /// # Returns
    ///
    /// 0 on success, or: -3 if an input file cannot be opened, -4 if an
    /// output file cannot be created (or an annotator name is illegal), -5
    /// if a `stat` is illegal. With `nann == 0`, the status of closing the
    /// previously opened annotators: 0, -6 if an output annotation file
    /// was written out of order (whether or not it could then be sorted),
    /// -7 on a write error.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// use wfdbx::{Annotation, Anninfo, Wfdb, WFDB_READ};
    ///
    /// let mut w = Wfdb::new();
    /// let ai = Anninfo { name: b"atr".to_vec(), stat: WFDB_READ };
    /// if w.annopen("100s", &[ai], 1) == 0 {
    ///     let mut a = Annotation::default();
    ///     while w.getann(0, &mut a) == 0 {
    ///         let mnemonic = w.annstr(a.anntyp as i32);
    ///         println!("{} {}", a.time, String::from_utf8_lossy(&mnemonic));
    ///     }
    /// }
    /// w.wfdbquit();
    /// ```
    pub fn annopen(&mut self, record: impl OptBytes, aiarray: &[Anninfo], nann: u32) -> i32 {
        self.ann.annclose_error = 0;
        let mut record = record.opt_bytes().map(cstd::cstr).unwrap_or(b"");
        if record.first() == Some(&b'+') {
            // don't close open annotation files
            record = &record[1..]; // discard the '+' prefix
        } else {
            self.wfdb_anclose(); // close previously opened annotation files
        }

        // If no annotation files are to be opened, report whether errors
        // occurred while closing previously-opened files.
        if nann == 0 {
            return self.ann.annclose_error;
        }
        let nann = (nann as usize).min(aiarray.len());

        // Remove trailing .hea, if any, from record name.
        let record = wfdb_striphea(record);

        // Check the stat of each annotator.
        for ai in &aiarray[..nann] {
            match ai.stat {
                WFDB_READ | WFDB_AHA_READ | WFDB_WRITE | WFDB_AHA_WRITE => {}
                _ => {
                    let msg = cformat!(
                        b"annopen: illegal stat %d for annotator %s, record %s\n",
                        ai.stat,
                        cstd::cstr(&ai.name),
                        record
                    );
                    self.wfdb_error(msg);
                    return -5;
                }
            }
        }

        for ai in &aiarray[..nann] {
            // open the annotation files
            let name = cstd::cstr(&ai.name).to_vec();
            match ai.stat {
                WFDB_READ | WFDB_AHA_READ => {
                    // standard (MIT-format) or AHA-format input file
                    self.wfdb_setirec(&record);
                    let Some(file) = self.wfdb_open(&name, &record, WFDB_READ) else {
                        let msg = cformat!(
                            b"annopen: can't read annotator %s for record %s\n",
                            name,
                            record
                        );
                        self.wfdb_error(msg);
                        return -3;
                    };
                    let info = Anninfo {
                        name: ai.name.clone(),
                        stat: ai.stat,
                    };
                    let mut ia = IaData::new(file, info);
                    if ann_file_format(&mut ia) == WFDB_READ {
                        if ai.stat != WFDB_READ {
                            let msg = cformat!(
                                b"warning (annopen, annotator %s, record %s):\n",
                                name,
                                record
                            );
                            self.wfdb_error(msg);
                            self.wfdb_error(" file appears to be in MIT format\n");
                            self.wfdb_error(" ... continuing under that assumption\n");
                        }
                        ia.info.stat = WFDB_READ;
                    } else {
                        if ai.stat != WFDB_AHA_READ {
                            let msg = cformat!(
                                b"warning (annopen, annotator %s, record %s):\n",
                                name,
                                record
                            );
                            self.wfdb_error(msg);
                            self.wfdb_error(" file appears to be in AHA format\n");
                            self.wfdb_error(" ... continuing under that assumption\n");
                        }
                        ia.info.stat = WFDB_AHA_READ;
                    }
                    self.ann.iad.push(ia);
                    let n = (self.ann.iad.len() - 1) as u32;
                    self.get_ann_table(n);
                }
                _ => {
                    // standard (MIT-format) or AHA-format output file.
                    // Quit (with message from wfdb_checkname) if name is
                    // illegal.
                    if self.wfdb_checkname(&name, b"annotator") != 0 {
                        return -4;
                    }
                    let Some(file) = self.wfdb_open(&name, &record, WFDB_WRITE) else {
                        let msg = cformat!(
                            b"annopen: can't write annotator %s for record %s\n",
                            name,
                            record
                        );
                        self.wfdb_error(msg);
                        return -4;
                    };
                    let info = Anninfo {
                        name: ai.name.clone(),
                        stat: ai.stat,
                    };
                    // wfdb-x: the name of the file, for sort_ann_file
                    let fname = self.wfdb_filename().to_vec();
                    self.ann
                        .oad
                        .push(OaData::new(file, info, record.clone(), fname));
                }
            }
        }
        0
    }

    /// C `getann(n, &annot)`: reads the next annotation from input
    /// annotator `n` into `annot`.
    ///
    /// # Returns
    ///
    /// 0 on success, or: -1 at the end of the file (`annot` is then not
    /// valid), -2 if `n` is not an open input annotator, -3 at an
    /// unexpected end of file.
    ///
    /// # Compatibility
    ///
    /// In C, `annot.aux` points into a 771-byte buffer of the library, and
    /// the library has already read the following annotation (whose aux
    /// data go into the same buffer) when `getann` returns. To give the
    /// same results, `annot.aux` is copied from that buffer after the
    /// following annotation has been read: where C would return aux data
    /// partly overwritten by those of the following annotation, so does
    /// this function.
    pub fn getann(&mut self, n: u32, annot: &mut Annotation) -> i32 {
        let Some(ia) = self.ann.iad.get_mut(n as usize) else {
            self.wfdb_error(cformat!(b"getann: can't read annotator %d\n", n));
            return -2;
        };
        let mut msgs = Msgs::new();
        let status = getann_ia(ia, annot, &mut msgs);
        self.report(msgs);
        status
    }

    /// C `ungetann(n, &annot)`: pushes back an annotation into input
    /// annotator `n`, so that the next `getann` returns it (one annotation
    /// at most). Returns 0, -1 if the push-back buffer is full, -2 if `n`
    /// is not an open input annotator.
    pub fn ungetann(&mut self, n: u32, annot: &Annotation) -> i32 {
        let Some(ia) = self.ann.iad.get_mut(n as usize) else {
            self.wfdb_error(cformat!(b"ungetann: annotator %d is not initialized\n", n));
            return -2;
        };
        if ia.pann.anntyp != 0 {
            self.wfdb_error("ungetann: pushback buffer is full\n");
            self.wfdb_error(cformat!(
                b"ungetann: annotation at %lld, annotator %d not pushed back\n",
                annot.time,
                n
            ));
            return -1;
        }
        ungetann_ia(ia, annot);
        0
    }

    /// C `putann(n, &annot)`: writes an annotation to output annotator `n`.
    /// Returns 0, -1 on a write error (or a time overflow), -2 if `n` is
    /// not an open output annotator.
    pub fn putann(&mut self, n: u32, annot: &Annotation) -> i32 {
        let nu = n as usize;
        if nu >= self.ann.oad.len() {
            self.wfdb_error(cformat!(b"putann: can't write annotation file %d\n", n));
            return -2;
        }
        let mut msgs = Msgs::new();
        let oafreq = self.ann.oafreq;
        let st = &mut self.ann;
        let oa = &mut st.oad[nu];
        let mut status = 0;
        if !oa.table_written {
            oa.table_written = true;
            status = put_ann_table(oa, n, oafreq, &st.defs, &mut msgs);
        }
        if status == 0 {
            status = put_ann_word(oa, n, annot, &mut msgs);
        }
        self.report(msgs);
        status
    }

    /// C `iannsettime(t)`: skips ahead (or rewinds) the input annotators so
    /// that the next annotation read from each has a time >= `t` (negative
    /// values are treated as positive, except `WFDB_TIME_MIN`, which
    /// rewinds to the very beginning). Returns 0, or -1 if no input
    /// annotator remains valid.
    pub fn iannsettime(&mut self, mut t: i64) -> i32 {
        let mut stat = 0;
        let mut niavalid = self.ann.iad.len() as i32;
        let mut tempann = Annotation::default();

        // Handle negative arguments as equivalent positive arguments. As an
        // exception, WFDB_TIME_MIN indicates that we should rewind to the
        // very beginning of the annotation file, even if there are
        // annotations at negative time values.
        if t < 0 && t != WFDB_TIME_MIN {
            t = -t;
        }

        for i in 0..self.ann.iad.len() {
            let iu = i as u32;
            let ia = &mut self.ann.iad[i];
            if ia.ann.time >= t {
                // "rewind" the annotation file
                ia.pann.anntyp = 0; // flush pushback buffer
                if ia.file.seek(0, cstd::SEEK_SET) == -1 {
                    self.wfdb_error("iannsettime: improper seek\n");
                    return -1;
                }
                ia.ann.subtyp = 0;
                ia.ann.chan = 0;
                ia.ann.num = 0;
                ia.ateof = 0;
                ia.ann.time = 0;
                ia.tt = 0.0;
                ia.word = ia.file.g16() as u32;
                if ia.info.stat == WFDB_READ {
                    while (ia.word & CODE) == SKIP {
                        ia.tt += ia.file.g32() as f64;
                        ia.word = ia.file.g16() as u32;
                    }
                }
                self.getann(iu, &mut tempann);
            }
            while self.ann.iad[i].ann.time < t {
                stat = self.getann(iu, &mut tempann);
                if stat != 0 {
                    break;
                }
            }
            if stat < 0 {
                niavalid -= 1;
            }
        }
        if niavalid > 0 {
            0
        } else {
            -1
        }
    }

    // -----------------------------------------------------------------------
    // Conversion between annotation codes, mnemonics, and descriptions

    /// C `ecgstr(code)`: the fixed mnemonic of an annotation code (`[N]`
    /// for codes outside 0..=ACMAX).
    pub fn ecgstr(&mut self, code: i32) -> Vec<u8> {
        if (0..=ACMAX).contains(&code) {
            self.ann.cstring[code as usize].clone()
        } else {
            cformat!(b"[%d]", code)
        }
    }

    /// C `strecg(str)`: the annotation code of a fixed mnemonic
    /// (`NOTQRS` if none).
    pub fn strecg(&mut self, s: impl OptBytes) -> i32 {
        let s = s.opt_bytes().map(cstd::cstr).unwrap_or(b"");
        (1..=ACMAX)
            .find(|&code| self.ann.cstring[code as usize] == s)
            .unwrap_or(NOTQRS)
    }

    /// C `setecgstr(code, string)`: modifies the fixed mnemonic of an
    /// annotation code (the one `ecgstr` and `strecg` use). Returns 0, or
    /// -1 if `code` is outside 0..=ACMAX.
    pub fn setecgstr(&mut self, code: i32, s: impl OptBytes) -> i32 {
        if (NOTQRS..=ACMAX).contains(&code) {
            let s = s.opt_bytes().map(cstd::cstr).unwrap_or(b"");
            self.ann.cstring[code as usize] = s.to_vec();
            return 0;
        }
        self.wfdb_error(cformat!(b"setecgstr: illegal annotation code %d\n", code));
        -1
    }

    /// C `annstr(code)`: the (possibly redefined) mnemonic of an annotation
    /// code (`[N]` for codes outside 0..=ACMAX).
    pub fn annstr(&mut self, code: i32) -> Vec<u8> {
        if (0..=ACMAX).contains(&code) {
            self.ann.defs.astring[code as usize].clone()
        } else {
            cformat!(b"[%d]", code)
        }
    }

    /// C `strann(str)`: the annotation code of a mnemonic (`NOTQRS` if
    /// none).
    pub fn strann(&mut self, s: impl OptBytes) -> i32 {
        let s = s.opt_bytes().map(cstd::cstr).unwrap_or(b"");
        (1..=ACMAX)
            .find(|&code| self.ann.defs.astring[code as usize] == s)
            .unwrap_or(NOTQRS)
    }

    /// C `setannstr(code, string)`: redefine the mnemonic of an annotation
    /// code. With a positive code, the change is recorded in the
    /// modification labels of output annotation files written later; with
    /// a negative code (-code is modified), it is not. Returns 0, or -1 if
    /// the code is outside 0..=ACMAX.
    pub fn setannstr(&mut self, code: i32, s: impl OptBytes) -> i32 {
        let s = s.opt_bytes().map(cstd::cstr).unwrap_or(b"");
        if self.ann.defs.set(false, code, s) == 0 {
            return 0;
        }
        let code = if code > 0 { code } else { code.wrapping_neg() };
        self.wfdb_error(cformat!(b"setannstr: illegal annotation code %d\n", code));
        -1
    }

    /// C `anndesc(code)`: the description of an annotation code (`None` if
    /// it has none; `illegal annotation code` for codes outside
    /// 0..=ACMAX).
    pub fn anndesc(&mut self, code: i32) -> Option<Vec<u8>> {
        if (0..=ACMAX).contains(&code) {
            self.ann.defs.tstring[code as usize].clone()
        } else {
            Some(b"illegal annotation code".to_vec())
        }
    }

    /// C `setanndesc(code, string)`: redefine the description of an
    /// annotation code (see [`Wfdb::setannstr`] for the sign of `code`).
    /// Returns 0, or -1 if the code is outside 0..=ACMAX.
    pub fn setanndesc(&mut self, code: i32, s: impl OptBytes) -> i32 {
        let s = s.opt_bytes().map(cstd::cstr).unwrap_or(b"");
        if self.ann.defs.set(true, code, s) == 0 {
            return 0;
        }
        let code = if code > 0 { code } else { code.wrapping_neg() };
        self.wfdb_error(cformat!(b"setanndesc: illegal annotation code %d\n", code));
        -1
    }

    // -----------------------------------------------------------------------
    // Time resolution

    /// C `setafreq(f)`: set the time resolution (ticks per second) of
    /// output annotation files opened later (0: the sampling frequency).
    pub fn setafreq(&mut self, f: f64) {
        self.ann.oafreq = f;
    }

    /// C `getafreq()`: the time resolution of output annotation files.
    pub fn getafreq(&mut self) -> f64 {
        self.ann.oafreq
    }

    /// C `setiafreq(n, f)`: set the time resolution in which the times of
    /// the annotations of input annotator `n` are returned.
    pub fn setiafreq(&mut self, n: u32, f: f64) {
        let nu = n as usize;
        if nu >= self.ann.iad.len() {
            return;
        }
        let tmul = if f > 0.0 && self.ann.iad[nu].afreq > 0.0 {
            f / self.ann.iad[nu].afreq
        } else if f > 0.0 {
            let sfreq = self.sampfreq(NULL);
            if sfreq > 0.0 {
                f * self.getspf() as f64 / sfreq
            } else {
                1.0
            }
        } else {
            1.0
        };
        let ia = &mut self.ann.iad[nu];
        ia.tmul = tmul;
        ia.ann.time = round_to_time(ia.ann_tt * ia.tmul);
        ia.pann.time = round_to_time(ia.pann_tt * ia.tmul);
        ia.prev_time = round_to_time(ia.prev_tt * ia.tmul);
    }

    /// C `getiafreq(n)`: the time resolution of the annotation times
    /// returned for input annotator `n` (-2 if `n` is not open).
    pub fn getiafreq(&mut self, n: u32) -> f64 {
        let nu = n as usize;
        if nu < self.ann.iad.len() {
            let (afreq, tmul) = (self.ann.iad[nu].afreq, self.ann.iad[nu].tmul);
            if afreq > 0.0 {
                return afreq * tmul;
            }
            return self.sampfreq(NULL) * tmul / self.getspf() as f64;
        }
        -2.0
    }

    /// C `getiaorigfreq(n)`: the time resolution recorded in the file of
    /// input annotator `n` (0 if none; -2 if `n` is not open).
    pub fn getiaorigfreq(&mut self, n: u32) -> f64 {
        match self.ann.iad.get(n as usize) {
            Some(ia) => ia.afreq,
            None => -2.0,
        }
    }

    // -----------------------------------------------------------------------
    // Closing annotators

    /// C `iannclose(n)`: close input annotator `n` (the annotators after it
    /// are renumbered, as in C).
    pub fn iannclose(&mut self, n: u32) {
        let nu = n as usize;
        if nu < self.ann.iad.len() {
            let ia = self.ann.iad.remove(nu);
            let _ = ia.file.close();
        }
    }

    /// C `oannclose(n)`: close output annotator `n`, writing its end mark.
    /// If its annotations were not written in canonical order, the file is
    /// rearranged (unless the environment variable `WFDBANNSORT` is 0):
    /// wfdb-x: in this process, with the result of the `sortann` program
    /// (see [`AnnList`]); in legacy mode, as in C, by running `sortann`
    /// ([`run_sortann`]).
    pub fn oannclose(&mut self, n: u32) {
        let nu = n as usize;
        if nu >= self.ann.oad.len() {
            return;
        }
        let mut oa = self.ann.oad.remove(nu);
        let f = &mut oa.file;
        match oa.info.stat {
            WFDB_WRITE => f.p16(0), // write logical EOF for MIT-format files
            WFDB_AHA_WRITE => {
                // write logical EOF for AHA-format files
                let pos = f.tell() as u32 as i64;
                let mut i = ABLKSIZ - pos % ABLKSIZ;
                while i > 0 {
                    f.putc(EOAF);
                    i -= 1;
                }
            }
            _ => {}
        }
        let mut errflag = oa.file.error();
        if oa.file.close() != 0 {
            errflag = true;
        }
        let name = cstd::cstr(&oa.info.name).to_vec();
        if errflag {
            self.wfdb_error(cformat!(
                b"oannclose: write error on annotation file %s\n",
                name
            ));
            self.ann.annclose_error = -7;
        }
        let mut out_of_order = oa.out_of_order;
        if out_of_order {
            let dosort = match cstd::getenv("WFDBANNSORT") {
                Some(p) => cstd::strtol(&p, 10).0 as i32,
                None => DEFWFDBANNSORT,
            };
            if dosort != 0 {
                self.wfdb_error(cformat!(
                    b"Rearranging annotations for output annotator %s ...",
                    name
                ));
                // wfdb-x: the file is sorted in this process (sort_ann_file);
                // the C library ran the sortann program, as legacy mode does.
                let sorted = if self.wfdbx_get_legacy() != 0 {
                    let dir = self.wfdbx_get_output_dir();
                    run_sortann(&oa.rname, &name, dir.as_deref()) == 0
                } else {
                    self.sort_ann_file(&oa.fname, &name) == 0
                };
                if sorted {
                    self.wfdb_error("done!\n");
                    out_of_order = false;
                } else {
                    self.wfdb_error("\nAnnotations still need to be rearranged.\n");
                }
                if self.ann.annclose_error == 0 {
                    self.ann.annclose_error = -6;
                }
            }
        }
        if out_of_order {
            self.wfdb_error(cformat!(
                b"Use the command:\n  sortann -r %s -a %s\n",
                oa.rname,
                name
            ));
            self.wfdb_error("to rearrange annotations in the correct order.\n");
            if self.ann.annclose_error == 0 {
                self.ann.annclose_error = -6;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// In-process sorting of output annotation files (wfdb-x)

/// The annotation list of the `sortann` program (`insert_ann` in
/// `app/sortann.c`), used by the `sortann` tool and by `oannclose`.
///
/// Annotations are inserted in canonical order (time, then `num`, then
/// `chan`) with the algorithm of `insert_ann`, including its rule for
/// duplicates: an annotation with the same time, `num` and `chan` as one
/// already in the list replaces it (but only when the duplicate is found
/// while repairing out-of-order input).
///
/// wfdb-x: the (all-zero) list head is never compared as an annotation: an
/// out-of-order annotation that precedes all entries is inserted at the
/// beginning of the list. In C, and with [`AnnList::with_legacy`]`(true)`,
/// an annotation at time 0 with `num` and `chan` 0 that precedes all
/// entries "replaces" the head, and neither it nor any annotation later
/// inserted after it is in the list (input times 5, 0, 3 give only 5; see
/// `docs/KNOWN_C_BEHAVIORS.md`, "sortann loses annotations"). Where C has
/// undefined behavior (a replaced first entry that is not linked back to
/// the head), the head is updated, in both modes.
#[derive(Debug)]
pub struct AnnList {
    /// Entry 0 is the list head (`annlist`), whose annotation is all zeros
    /// and which takes part in comparisons exactly as in sortann.c.
    list: Vec<AnnEntry>,
    /// The last entry (initially the head).
    lastp: usize,
    in_order: bool,
    /// The original insertion (with its loss of annotations).
    legacy: bool,
}

/// An entry of an [`AnnList`] (`None`: a null link).
#[derive(Debug)]
struct AnnEntry {
    next: Option<usize>,
    prev: Option<usize>,
    annotation: Annotation,
}

/// `a` follows `b` in canonical order (sortann.c; `or_same`: or they have
/// the same time, num and chan).
fn after(a: &Annotation, b: &Annotation, or_same: bool) -> bool {
    a.time > b.time
        || (a.time == b.time && a.num > b.num)
        || (a.time == b.time
            && a.num == b.num
            && (a.chan > b.chan || (or_same && a.chan == b.chan)))
}

impl Default for AnnList {
    fn default() -> Self {
        AnnList::new()
    }
}

impl AnnList {
    /// An empty list (with the wfdb-x insertion).
    pub fn new() -> AnnList {
        AnnList::with_legacy(false)
    }

    /// An empty list; with `legacy`, the original insertion of sortann.c,
    /// which loses annotations (see [`AnnList`]).
    pub fn with_legacy(legacy: bool) -> AnnList {
        AnnList {
            list: vec![AnnEntry {
                next: None,
                prev: None,
                annotation: Annotation::default(),
            }],
            lastp: 0,
            in_order: true,
            legacy,
        }
    }

    /// Whether all annotations were inserted in order (sortann then writes
    /// nothing).
    pub fn in_order(&self) -> bool {
        self.in_order
    }

    /// The annotations of the list, in order.
    pub fn iter(&self) -> impl Iterator<Item = &Annotation> + '_ {
        let mut p = self.list[0].next;
        std::iter::from_fn(move || {
            let e = &self.list[p?];
            p = e.next;
            Some(&e.annotation)
        })
    }

    /// Inserts a copy of `pa` (`insert_ann`).
    pub fn insert(&mut self, pa: &Annotation) {
        let l = &mut self.list;
        let newp = l.len();
        l.push(AnnEntry {
            next: None,
            prev: None,
            annotation: pa.clone(),
        });
        let lastp = self.lastp;
        if lastp == 0 || after(pa, &l[lastp].annotation, false) {
            // this annotation is in order -- add to end of list
            l[newp].prev = Some(lastp);
            l[lastp].next = Some(newp);
            self.lastp = newp;
            return;
        }
        self.in_order = false; // input was out-of-order

        // Find the correct location in the list for this annotation. The
        // search is linear, beginning at the end of the list.
        let mut ap = Some(lastp);
        while let Some(a) = ap {
            if a == 0 && !self.legacy {
                // wfdb-x: the head is not an annotation (C compared it, and
                // took a (0, 0, 0) annotation for its duplicate)
                ap = None;
                break;
            }
            if after(pa, &l[a].annotation, true) {
                break;
            }
            ap = l[a].prev;
        }
        match ap {
            None => {
                // insert newp at the beginning of the list
                let nx = l[0].next;
                l[newp].next = nx;
                l[0].next = Some(newp);
                if let Some(nx) = nx {
                    l[nx].prev = Some(newp);
                }
            }
            Some(a) => {
                let aa = &l[a].annotation;
                if pa.time == aa.time && pa.num == aa.num && pa.chan == aa.chan {
                    // replace ap by newp
                    let (pv, nx) = (l[a].prev, l[a].next);
                    l[newp].prev = pv;
                    if let Some(pv) = pv {
                        l[pv].next = Some(newp);
                    }
                    l[newp].next = nx;
                    match nx {
                        Some(nx) => l[nx].prev = Some(newp),
                        None => self.lastp = newp,
                    }
                    // If ap was the first entry of the list but its 'prev'
                    // link does not lead back to the list head (an entry
                    // inserted at the beginning gets a null link, and one
                    // whose predecessor replaced the head is detached), C
                    // leaves the head pointing to the freed entry (undefined
                    // behavior): here the head is updated, so that the
                    // duplicate is replaced (see docs/KNOWN_C_BEHAVIORS.md).
                    if a != 0 && l[0].next == Some(a) {
                        l[0].next = Some(newp);
                    }
                } else {
                    // insert newp immediately after ap
                    let nx = l[a].next;
                    l[newp].prev = Some(a);
                    l[newp].next = nx;
                    if let Some(nx) = nx {
                        l[nx].prev = Some(newp);
                    }
                    l[a].next = Some(newp);
                }
            }
        }
    }
}

impl Wfdb {
    /// wfdb-x: rearranges the annotations of the (closed) annotation file
    /// `fname` of annotator `aname` in canonical order, with a result
    /// identical, byte for byte, to that of the sortann program as the C
    /// library ran it (`sortann -r. RECORD -a ANNOTATOR`, see `oannclose`),
    /// but without looking up the header of the record. As sortann does, it
    /// reads the file (with any time resolution and annotation type
    /// definitions it contains), inserts its annotations at nonnegative
    /// times in an [`AnnList`], and, unless they were already in order,
    /// rewrites the file in MIT format, with the time resolution of the
    /// input file (if any) and without the `NOTQRS` annotations. It uses its
    /// own reader, writer and definition table (the annotators and tables
    /// of the instance are not changed). Returns 0, or -1 if the file
    /// cannot be read or written.
    fn sort_ann_file(&mut self, fname: &[u8], aname: &[u8]) -> i32 {
        let mut msgs = Msgs::new();
        let status = sort_ann_file(fname, aname, &mut msgs);
        self.report(msgs);
        status
    }
}

/// The body of [`Wfdb::sort_ann_file`]; error messages are added to `msgs`.
fn sort_ann_file(fname: &[u8], aname: &[u8], msgs: &mut Msgs) -> i32 {
    // Read the file, starting from the default definition table.
    let mut defs = AnnDefs::default();
    let Some(file) = local_fopen(fname, b"rb", false) else {
        return -1;
    };
    let info = Anninfo {
        name: aname.to_vec(),
        stat: 0,
    };
    let mut ia = IaData::new(file, info);
    ia.info.stat = ann_file_format(&mut ia);
    read_ann_table(&mut ia, &mut defs, msgs);
    let mut list = AnnList::new();
    let mut annot = Annotation::default();
    let status = loop {
        let st = getann_ia(&mut ia, &mut annot, msgs);
        if st != 0 {
            break st;
        }
        if annot.time >= 0 {
            // (sortann's -f time is 0)
            list.insert(&annot);
        }
    };
    let _ = ia.file.close();
    if status != -1 {
        return -1; // not the logical end of the file
    }
    if list.in_order() {
        return 0;
    }

    // Write the sorted annotations.
    let Some(file) = local_fopen(fname, b"wb", false) else {
        return -1;
    };
    let info = Anninfo {
        name: aname.to_vec(),
        stat: WFDB_WRITE,
    };
    let mut oa = OaData::new(file, info, Vec::new(), fname.to_vec());
    let mut ok = true;
    for a in list.iter().filter(|a| a.anntyp as i32 != NOTQRS) {
        if !oa.table_written {
            oa.table_written = true;
            ok = put_ann_table(&mut oa, 0, ia.afreq, &defs, msgs) == 0;
        }
        if !ok || put_ann_word(&mut oa, 0, a, msgs) < 0 {
            ok = false;
            break;
        }
    }
    oa.file.p16(0);
    if oa.file.error() {
        ok = false;
    }
    if oa.file.close() != 0 {
        ok = false;
    }
    if ok {
        0
    } else {
        -1
    }
}

// ---------------------------------------------------------------------------
// Free functions (default instance)

/// C `annopen` on the default instance (see [`Wfdb::annopen`]).
pub fn annopen(record: impl OptBytes, aiarray: &[Anninfo], nann: u32) -> i32 {
    with_default(|w| w.annopen(record, aiarray, nann))
}

/// C `getann` on the default instance (see [`Wfdb::getann`]).
pub fn getann(n: u32, annot: &mut Annotation) -> i32 {
    with_default(|w| w.getann(n, annot))
}

/// C `ungetann` on the default instance (see [`Wfdb::ungetann`]).
pub fn ungetann(n: u32, annot: &Annotation) -> i32 {
    with_default(|w| w.ungetann(n, annot))
}

/// C `putann` on the default instance (see [`Wfdb::putann`]).
pub fn putann(n: u32, annot: &Annotation) -> i32 {
    with_default(|w| w.putann(n, annot))
}

/// C `iannsettime` on the default instance (see [`Wfdb::iannsettime`]).
pub fn iannsettime(t: i64) -> i32 {
    with_default(|w| w.iannsettime(t))
}

/// C `ecgstr` on the default instance (see [`Wfdb::ecgstr`]).
pub fn ecgstr(code: i32) -> Vec<u8> {
    with_default(|w| w.ecgstr(code))
}

/// C `strecg` on the default instance (see [`Wfdb::strecg`]).
pub fn strecg(s: impl OptBytes) -> i32 {
    with_default(|w| w.strecg(s))
}

/// C `setecgstr` on the default instance (see [`Wfdb::setecgstr`]).
pub fn setecgstr(code: i32, s: impl OptBytes) -> i32 {
    with_default(|w| w.setecgstr(code, s))
}

/// C `annstr` on the default instance (see [`Wfdb::annstr`]).
pub fn annstr(code: i32) -> Vec<u8> {
    with_default(|w| w.annstr(code))
}

/// C `strann` on the default instance (see [`Wfdb::strann`]).
pub fn strann(s: impl OptBytes) -> i32 {
    with_default(|w| w.strann(s))
}

/// C `setannstr` on the default instance (see [`Wfdb::setannstr`]).
pub fn setannstr(code: i32, s: impl OptBytes) -> i32 {
    with_default(|w| w.setannstr(code, s))
}

/// C `anndesc` on the default instance (see [`Wfdb::anndesc`]).
pub fn anndesc(code: i32) -> Option<Vec<u8>> {
    with_default(|w| w.anndesc(code))
}

/// C `setanndesc` on the default instance (see [`Wfdb::setanndesc`]).
pub fn setanndesc(code: i32, s: impl OptBytes) -> i32 {
    with_default(|w| w.setanndesc(code, s))
}

/// C `setafreq` on the default instance (see [`Wfdb::setafreq`]).
pub fn setafreq(f: f64) {
    with_default(|w| w.setafreq(f));
}

/// C `getafreq` on the default instance (see [`Wfdb::getafreq`]).
pub fn getafreq() -> f64 {
    with_default(super::wfdb::Wfdb::getafreq)
}

/// C `setiafreq` on the default instance (see [`Wfdb::setiafreq`]).
pub fn setiafreq(n: u32, f: f64) {
    with_default(|w| w.setiafreq(n, f));
}

/// C `getiafreq` on the default instance (see [`Wfdb::getiafreq`]).
pub fn getiafreq(n: u32) -> f64 {
    with_default(|w| w.getiafreq(n))
}

/// C `getiaorigfreq` on the default instance (see [`Wfdb::getiaorigfreq`]).
pub fn getiaorigfreq(n: u32) -> f64 {
    with_default(|w| w.getiaorigfreq(n))
}

/// C `iannclose` on the default instance (see [`Wfdb::iannclose`]).
pub fn iannclose(n: u32) {
    with_default(|w| w.iannclose(n));
}

/// C `oannclose` on the default instance (see [`Wfdb::oannclose`]).
pub fn oannclose(n: u32) {
    with_default(|w| w.oannclose(n));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rounding() {
        assert_eq!(round_to_time(2.5), 3);
        assert_eq!(round_to_time(2.49), 2);
        assert_eq!(round_to_time(-2.5), -2);
        assert_eq!(round_to_time(-2.51), -3);
        assert_eq!(round_to_time(f64::NAN), WFDB_TIME_MIN);
        assert_eq!(round_to_time(1e300), WFDB_TIME_MAX);
    }

    #[test]
    fn mnemonics() {
        let mut w = Wfdb::new();
        assert_eq!(w.annstr(1), b"N");
        assert_eq!(w.annstr(-1), b"[-1]");
        assert_eq!(w.ecgstr(50), b"[50]");
        assert_eq!(w.strann("V"), 5);
        assert_eq!(w.strann("zz"), NOTQRS);
        assert_eq!(w.anndesc(15), None);
        assert_eq!(w.anndesc(51), Some(b"illegal annotation code".to_vec()));
        w.wfdbquiet();
        assert_eq!(w.setannstr(50, "x"), -1);
        assert_eq!(w.setannstr(-5, "PVC"), 0);
        assert_eq!(w.strann("PVC"), 5);
        assert!(!w.ann.defs.modified[5]);
        assert_eq!(w.setanndesc(5, "desc"), 0);
        assert!(w.ann.defs.modified[5]);
        assert_eq!(w.strecg("V"), 5);
    }
}
