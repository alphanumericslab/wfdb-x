//! Header metadata: the `Key: value` info strings in the header of a record.
//!
//! The info strings of a header are its comment lines (lines that begin
//! with `#`) after the record line, as the function `getinfo` reads them.
//! The record line is the first line that holds something other than white
//! space and does not begin (after white space) with `#`, as the header
//! parser finds it.
//! Many datasets store facts about the recording in them as `Key: value`
//! pairs, for example:
//!
//! ```text
//! # Age: 63
//! # Sex: F
//! # Dx: 164889003
//! ```
//!
//! The functions of this module read and change such entries:
//!
//! | Function | What it does |
//! |---|---|
//! | [`read_metadata`], [`read_metadata_with`] | all the entries, in file order, as `(key, value)` pairs |
//! | [`get_metadata`], [`get_metadata_with`] | the value of one entry, or `None` |
//! | [`set_metadata`], [`set_metadata_with`] | changes the value of an entry, or adds the entry |
//! | [`remove_metadata`], [`remove_metadata_with`] | removes an entry; returns the number of lines removed |
//! | [`update_metadata`], [`update_metadata_with`] | several changes in one write (a value of `None` removes the entry) |
//!
//! [`read_header`](crate::read_header) also returns the entries
//! ([`Header::metadata`](crate::Header::metadata)), and
//! [`write_record`](crate::write_record) writes them
//! ([`WriteOptions::metadata`](crate::WriteOptions::metadata)). The `_with`
//! functions take a [`MetadataOptions`]: the input directory and network
//! access for the call, and, for the functions that change a header, the
//! directory in which to write it.
//!
//! ```
//! use wfdbx::metadata::{read_metadata, set_metadata_with, MetadataOptions};
//!
//! // The sample record 100s, the first minute of record 100 of the MIT-BIH
//! // Arrhythmia Database, included with WFDB-x in tests/data:
//! # wfdbx::wfdbx_set_input_dir("../tests/data");
//! # /*
//! wfdbx::wfdbx_set_input_dir("tests/data"); // from the repository root
//! # */
//! // Its header has one entry, in "#Produced by xform from record 100,
//! // beginning at 0:0" (the key is the text before the first colon).
//! let md = read_metadata("100s")?;
//! assert_eq!(md.len(), 1);
//! assert_eq!(md[0].1, b"0");
//!
//! // A copy of the header, with the entry "# Age: 69", in a new directory
//! // (the header in tests/data is not changed).
//! let out = std::env::temp_dir().join("wfdbx-metadata-example");
//! std::fs::create_dir_all(&out).unwrap();
//! let opt = MetadataOptions { dir: Some(out.clone()), ..Default::default() };
//! set_metadata_with("100s", "Age", "69", &opt)?;
//! # std::fs::remove_dir_all(&out).unwrap();
//! # Ok::<(), wfdbx::record::Error>(())
//! ```
//!
//! # Rules
//!
//! * **Reading.** An info string is an entry if it contains a colon (`:`).
//!   The key is the text between the `#` and the first colon, and the value
//!   is the rest of the line; spaces, tabs, VT, FF and CR at either end of
//!   each are removed. So `#Age:45`, `# Age: 45` and `#  Age : 45` all give
//!   `("Age", "45")`. An info string without a colon, or whose key is empty
//!   or contains `#`, is a free comment: it is not returned, and it is never
//!   changed. Comment lines (and empty or blank lines) before the record
//!   line are not info strings, and are never read or changed. Only the header file (`.hea`) is read,
//!   not the `.info` file that `getinfo` also reads. A header without a
//!   record line has no entries, and cannot be changed.
//! * **Keys.** Keys are compared without regard to letter case (A-Z and
//!   a-z; no other byte is changed), so `get_metadata(record, "age")` finds
//!   `Age`. A header should not hold two entries whose keys differ only in
//!   letter case. If one does (a file written by other software), reading
//!   returns the first of them, with a warning (one for each such key);
//!   [`set_metadata`] and [`update_metadata`] refuse to change that key
//!   (an error), and [`remove_metadata`] removes all of them. A key must
//!   not be empty, and must not contain `:`, `#`, a line break (CR, LF) or
//!   a NUL byte; it may contain spaces, as in `"Date of birth"`.
//! * **Values** are text, which may be a whole sentence. Spaces at either
//!   end are removed; a value must not contain a line break or a NUL byte.
//!   The empty string is allowed. Keys and values are bytes, stored and
//!   returned as given (as all the text of a header in this crate).
//! * **Writing.** Entries are written as `# Key: value` (one space after
//!   `#` and one after the colon; `# Key:` if the value is empty), with the
//!   caller's spelling of the key. A changed entry replaces its line, at
//!   the same position. A new entry is added after the last info string
//!   (or, if the header has none, after its last line that is not blank).
//!   Every other byte of the header is kept: the record and signal lines,
//!   the free comments and the line endings (a new line ends as the record
//!   line does: CR LF in the headers written by WFDB). The new header is
//!   written to a temporary file in the directory of the header, which then
//!   replaces the header (keeping its permissions), so that an error never
//!   leaves a partly written header. All the arguments are checked before
//!   anything is written. If nothing changes, nothing is written (unless
//!   [`MetadataOptions::dir`] is given).
//! * **Which file.** The header is found as the library finds a header
//!   ([`Wfdb::wfdb_open`]): under the input directory, or as given if the
//!   name is an absolute path, a `~` path or a URL (a URL only with network
//!   access). A trailing `.hea` of the record name is ignored. A header read
//!   from a URL can be read but not changed. A change is written to the
//!   header itself, or, with [`MetadataOptions::dir`], to a header of the
//!   same name in that directory, leaving the original unchanged (the signal
//!   files are not copied); the output directory is not used. Only the
//!   named header is read or changed: for a multi-segment record, that is
//!   the master header, unless the name of a segment is given.
//!
//! These functions do not close the records and annotators open in the
//! [`Wfdb`] value they use.
//!
//! # Errors and warnings
//!
//! Each function returns a [`Result`] whose error type is
//! [`record::Error`](Error), with these messages:
//!
//! * Invalid arguments (checked before the header is read): "record name
//!   must not be empty"; "the metadata of a header read from the standard
//!   input cannot be read or changed" (the record name `-`); "metadata key
//!   must not be empty"; "metadata key 'KEY' must not contain ':'" (or
//!   `'#'`, "a line break", "a NUL character"); "value of metadata key
//!   'KEY' must not contain a line break" (or "a NUL character");
//!   "metadata key 'KEY' is given more than once (keys are compared without
//!   regard to letter case)".
//! * Changes that the header does not allow: "header of record REC has
//!   more than one entry for key KEY (lines L1, L2); remove them first";
//!   "header of record REC has no record line"; "header of record REC was
//!   read from a URL, and cannot be changed (give dir to write the changed
//!   header to a local directory)".
//! * Files: "can't read header for record REC"; "can't write header for
//!   record REC"; "directory DIR does not exist".
//!
//! A key that appears more than once gives the warning "WFDB-x: header of
//! record REC has more than one entry for key KEY (lines L1, L2); the first
//! is used", which goes through [`Wfdb::wfdb_error`], as the checksum
//! warning of [`read_record`](crate::read_record) does:
//! [`Wfdb::wfdbquiet`] turns its printing off, and [`Wfdb::wfdberror`]
//! returns it.
//!
//! Metadata often holds information about patients. WFDB-x stores it as
//! plain text, exactly as given, and does not de-identify it.
//
// This module is specified in the same way for the seven languages
// (tests/metadata/README.md); the Python implementation
// (python/src/wfdbx/metadata.py) is the reference.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It has no counterpart in the original package.
//
// Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU Lesser General Public License as published by
// the Free Software Foundation, either version 2.1 of the License, or (at
// your option) any later version. See LICENSE.

use std::path::{Path, PathBuf};

use crate::cstd;
use crate::record::{Error, ReadOptions};
use crate::types::WFDB_READ;
use crate::wfdb::{with_default, Wfdb};
use crate::wfdbio::{expand_home, is_url, wfdb_striphea};

/// The entries of a header: `(key, value)` pairs, in file order.
pub type Metadata = Vec<(Vec<u8>, Vec<u8>)>;

/// Options of the `_with` metadata functions ([`read_metadata_with`],
/// [`get_metadata_with`], [`set_metadata_with`], [`remove_metadata_with`]
/// and [`update_metadata_with`]). The default reads the header with the
/// current settings, and changes it where it was read.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct MetadataOptions {
    /// The input directory for this call only (optional): a local
    /// directory, a `~` path or a URL, under which relative record names are
    /// read. It does not apply to full paths or URLs. An empty string means
    /// the default. `None`: the current setting (see
    /// [`Wfdb::wfdbx_set_input_dir`]).
    pub input_dir: Option<String>,
    /// Turn network access on (`Some(true)`) or off (`Some(false)`) for
    /// this call only (see [`Wfdb::wfdbx_set_network`]). `None`: the current
    /// setting.
    pub network: Option<bool>,
    /// For the functions that change a header: an existing directory in
    /// which to write the changed header, under the same file name, instead
    /// of changing the header that was read (which is then unchanged; the
    /// signal files are not copied). The header is written there even if
    /// nothing changes. A `~` path is expanded. `None` (or an empty path):
    /// the header is changed where it was read. Not used by
    /// [`read_metadata_with`] and [`get_metadata_with`].
    pub dir: Option<PathBuf>,
}

// ---------------------------------------------------------------------------
// Parsing

/// Removed from both ends of keys and values.
const TRIM: &[u8] = b" \t\x0b\x0c\r";
/// The line ending of the headers written by WFDB.
const DEFAULT_EOL: &[u8] = b"\r\n";

/// `s` without the bytes of [`TRIM`] at either end.
fn trim(s: &[u8]) -> &[u8] {
    let a = s.iter().position(|c| !TRIM.contains(c)).unwrap_or(s.len());
    let b = s
        .iter()
        .rposition(|c| !TRIM.contains(c))
        .map_or(a, |b| b + 1);
    &s[a..b]
}

/// `key` with the letters A-Z changed to a-z.
fn fold(key: &[u8]) -> Vec<u8> {
    key.to_ascii_lowercase()
}

/// One line of a header: its content (without the line ending) and its
/// line ending (`\r\n`, `\n`, or empty for a last line without one).
#[derive(Clone)]
struct Line {
    content: Vec<u8>,
    eol: &'static [u8],
}

/// The lines of `data`, split after each LF.
fn split_lines(data: &[u8]) -> Vec<Line> {
    let mut lines = Vec::new();
    let mut start = 0;
    while start < data.len() {
        match data[start..].iter().position(|&c| c == b'\n') {
            None => {
                lines.push(Line {
                    content: data[start..].to_vec(),
                    eol: b"",
                });
                break;
            }
            Some(k) => {
                let i = start + k;
                if i > start && data[i - 1] == b'\r' {
                    lines.push(Line {
                        content: data[start..i - 1].to_vec(),
                        eol: b"\r\n",
                    });
                } else {
                    lines.push(Line {
                        content: data[start..i].to_vec(),
                        eol: b"\n",
                    });
                }
                start = i + 1;
            }
        }
    }
    lines
}

/// `(key, value)` of an info string (beginning with `#`), or `None` if it
/// is a free comment.
fn entry(content: &[u8]) -> Option<(Vec<u8>, Vec<u8>)> {
    let text = content.get(1..).unwrap_or(b"");
    let i = text.iter().position(|&c| c == b':')?;
    let key = trim(&text[..i]);
    if key.is_empty() || key.contains(&b'#') {
        return None;
    }
    Some((key.to_vec(), trim(&text[i + 1..]).to_vec()))
}

/// A parsed header: its lines, the index of the record line, the indices
/// of the info strings, and the entries as (line index, key, value) in
/// file order.
struct Hdr {
    lines: Vec<Line>,
    rec: Option<usize>,
    info: Vec<usize>,
    entries: Vec<(usize, Vec<u8>, Vec<u8>)>,
}

impl Hdr {
    fn parse(data: &[u8]) -> Hdr {
        Hdr::from_lines(split_lines(data))
    }

    fn from_lines(lines: Vec<Line>) -> Hdr {
        // The record line: the first line that has a token (separated by
        // spaces, tabs, CRs and LFs, up to a null byte) that does not begin
        // with '#', as the header parser of the library (readheader) finds
        // it. (The C function getinfo() takes the first line that does not
        // begin with '#', so an empty or blank line before the record line;
        // WFDB-x's getinfo follows readheader, except in legacy mode. The
        // metadata functions follow readheader in every mode.)
        let rec = lines.iter().position(|ln| {
            let t = cstd::cstr(&ln.content);
            t.iter()
                .position(|c| !b" \t\r\n".contains(c))
                .is_some_and(|i| t[i] != b'#')
        });
        let mut info = Vec::new();
        let mut entries = Vec::new();
        if let Some(r) = rec {
            for (i, ln) in lines.iter().enumerate().skip(r + 1) {
                if ln.content.starts_with(b"#") {
                    info.push(i);
                    if let Some((k, v)) = entry(&ln.content) {
                        entries.push((i, k, v));
                    }
                }
            }
        }
        Hdr {
            lines,
            rec,
            info,
            entries,
        }
    }

    /// Parses the lines again (after a change).
    fn reparse(&mut self) {
        let lines = std::mem::take(&mut self.lines);
        *self = Hdr::from_lines(lines);
    }

    /// The line indices of the entries whose key is `key`, ignoring letter
    /// case.
    fn matches(&self, key: &[u8]) -> Vec<usize> {
        let f = fold(key);
        self.entries
            .iter()
            .filter(|(_, k, _)| fold(k) == f)
            .map(|(i, _, _)| *i)
            .collect()
    }

    /// The line ending of new lines: that of the record line, or of the
    /// first line that has one, or CR LF.
    fn eol(&self) -> &'static [u8] {
        if let Some(r) = self.rec {
            if !self.lines[r].eol.is_empty() {
                return self.lines[r].eol;
            }
        }
        self.lines
            .iter()
            .map(|ln| ln.eol)
            .find(|e| !e.is_empty())
            .unwrap_or(DEFAULT_EOL)
    }

    /// The index at which new entries are inserted: after the last info
    /// string, or after the last line that is not blank.
    fn insertion_point(&self) -> usize {
        if let Some(&i) = self.info.last() {
            return i + 1;
        }
        self.lines
            .iter()
            .rposition(|ln| !trim(&ln.content).is_empty())
            .map_or(self.lines.len(), |i| i + 1)
    }

    /// Inserts a line of the given content at the insertion point.
    fn insert(&mut self, content: Vec<u8>) {
        let eol = self.eol();
        let at = self.insertion_point();
        if at > 0 && self.lines[at - 1].eol.is_empty() {
            self.lines[at - 1].eol = eol;
        }
        self.lines.insert(at, Line { content, eol });
        self.reparse();
    }

    fn to_bytes(&self) -> Vec<u8> {
        let mut v = Vec::new();
        for ln in &self.lines {
            v.extend_from_slice(&ln.content);
            v.extend_from_slice(ln.eol);
        }
        v
    }
}

/// The 1-based line numbers of the line indices `idx`, as "L1, L2".
fn line_numbers(idx: &[usize]) -> String {
    idx.iter()
        .map(|i| (i + 1).to_string())
        .collect::<Vec<_>>()
        .join(", ")
}

/// Text for a message.
fn text(b: &[u8]) -> String {
    String::from_utf8_lossy(b).into_owned()
}

/// `s` quoted for a message, as Python's `repr` quotes a string: between
/// single quotes, with backslashes, quotes and control characters escaped.
fn quoted(s: &[u8]) -> String {
    let mut v = Vec::with_capacity(s.len() + 2);
    v.push(b'\'');
    for &c in s {
        match c {
            b'\\' => v.extend_from_slice(b"\\\\"),
            b'\'' => v.extend_from_slice(b"\\'"),
            b'\n' => v.extend_from_slice(b"\\n"),
            b'\r' => v.extend_from_slice(b"\\r"),
            b'\t' => v.extend_from_slice(b"\\t"),
            c if c < 0x20 || c == 0x7f => v.extend_from_slice(format!("\\x{c:02x}").as_bytes()),
            c => v.push(c),
        }
    }
    v.push(b'\'');
    text(&v)
}

// ---------------------------------------------------------------------------
// Arguments

/// The name of a forbidden byte, for a message.
fn byte_name(c: u8) -> &'static str {
    match c {
        b':' => "':'",
        b'#' => "'#'",
        b'\r' | b'\n' => "a line break",
        _ => "a NUL character",
    }
}

/// `key` without spaces at either end, checked.
fn check_key(key: &[u8]) -> Result<Vec<u8>, Error> {
    let k = trim(key);
    if k.is_empty() {
        return Err(Error::new("metadata key must not be empty"));
    }
    for c in [b':', b'#', b'\r', b'\n', 0] {
        if k.contains(&c) {
            return Err(Error::new(format!(
                "metadata key {} must not contain {}",
                quoted(key),
                byte_name(c)
            )));
        }
    }
    Ok(k.to_vec())
}

/// `value` (of `key`, as given) without spaces at either end, checked.
fn check_value(key: &[u8], value: &[u8]) -> Result<Vec<u8>, Error> {
    let v = trim(value);
    for c in [b'\r', b'\n', 0] {
        if v.contains(&c) {
            return Err(Error::new(format!(
                "value of metadata key {} must not contain {}",
                quoted(key),
                byte_name(c)
            )));
        }
    }
    Ok(v.to_vec())
}

/// The info string of an entry, as written: `# Key: value`.
fn entry_line(key: &[u8], value: &[u8]) -> Vec<u8> {
    let mut l = b"# ".to_vec();
    l.extend_from_slice(key);
    l.push(b':');
    if !value.is_empty() {
        l.push(b' ');
        l.extend_from_slice(value);
    }
    l
}

/// A checked list of changes: (key, value, or `None` to remove).
type Changes = Vec<(Vec<u8>, Option<Vec<u8>>)>;

/// `changes` checked: valid keys and values, and no two keys that differ
/// only in letter case.
fn check_changes<K: AsRef<[u8]>, V: AsRef<[u8]>>(
    changes: &[(K, Option<V>)],
) -> Result<Changes, Error> {
    let mut out = Vec::with_capacity(changes.len());
    let mut seen: Vec<Vec<u8>> = Vec::new();
    for (key, value) in changes {
        let key = key.as_ref();
        let k = check_key(key)?;
        let f = fold(&k);
        if seen.contains(&f) {
            return Err(Error::new(format!(
                "metadata key {} is given more than once (keys are compared without regard to letter case)",
                quoted(key)
            )));
        }
        seen.push(f);
        let v = match value {
            Some(v) => Some(check_value(key, v.as_ref())?),
            None => None,
        };
        out.push((k, v));
    }
    Ok(out)
}

/// The info strings (as `putinfo` takes them: without the `#`) of the
/// entries of `metadata`, for `write_record`: `" Key: value"`. An error if
/// an entry is invalid, if two keys differ only in letter case, or if one
/// of `comments` (the other info strings) is already an entry for one of
/// these keys. The messages begin with `write_record: `.
pub(crate) fn info_lines(
    metadata: &[(Vec<u8>, Vec<u8>)],
    comments: &[Vec<u8>],
) -> Result<Vec<Vec<u8>>, Error> {
    let prefixed = |e: Error| Error::new(format!("write_record: {}", e.message()));
    let pairs: Vec<(&[u8], Option<&[u8]>)> = metadata
        .iter()
        .map(|(k, v)| (&k[..], Some(&v[..])))
        .collect();
    let entries = check_changes(&pairs).map_err(prefixed)?;
    let folded: Vec<Vec<u8>> = entries.iter().map(|(k, _)| fold(k)).collect();
    for c in comments {
        let mut line = vec![b'#'];
        line.extend_from_slice(cstd::cstr(c));
        if let Some((k, _)) = entry(&line) {
            if folded.contains(&fold(&k)) {
                return Err(Error::new(format!(
                    "write_record: metadata key {} is also given in comments",
                    quoted(&k)
                )));
            }
        }
    }
    Ok(entries
        .into_iter()
        .map(|(k, v)| entry_line(&k, v.as_deref().unwrap_or(b""))[1..].to_vec())
        .collect())
}

// ---------------------------------------------------------------------------
// Files

/// The record name without a trailing `.hea`, checked.
fn record_name(record: &[u8]) -> Result<Vec<u8>, Error> {
    let record = cstd::cstr(record);
    if record.is_empty() {
        return Err(Error::new("record name must not be empty"));
    }
    if record == b"-" {
        return Err(Error::new(
            "the metadata of a header read from the standard input cannot be read or changed",
        ));
    }
    Ok(wfdb_striphea(record))
}

/// Writes `data` to `dest` through a temporary file in the same directory,
/// which then replaces `dest` (keeping its permissions where the platform
/// has them). The temporary file is removed on failure.
fn write_atomic(dest: &Path, data: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let dir = match dest.parent() {
        Some(d) if !d.as_os_str().is_empty() => d.to_path_buf(),
        _ => PathBuf::from("."),
    };
    let base = dest
        .file_name()
        .map(|b| b.to_string_lossy().into_owned())
        .unwrap_or_default();
    let mode = dest_mode(dest);
    let mut attempt = 0;
    let (tmp, mut file) = loop {
        let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.subsec_nanos());
        let tmp = dir.join(format!(".{base}.{}{n}{nanos:x}.tmp", std::process::id()));
        let mut o = std::fs::OpenOptions::new();
        o.write(true).create_new(true);
        #[cfg(unix)]
        if let Some(m) = mode {
            // (not readable by others while it is written, if the header is
            // not; the exact bits are set below)
            use std::os::unix::fs::OpenOptionsExt;
            o.mode(m & 0o777);
        }
        match o.open(&tmp) {
            Ok(f) => break (tmp, f),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists && attempt < 100 => {
                attempt += 1;
            }
            Err(e) => return Err(e),
        }
    };
    let r = (|| {
        file.write_all(data)?;
        file.sync_all()?;
        drop(file);
        #[cfg(unix)]
        if let Some(m) = mode {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(m))?;
        }
        std::fs::rename(&tmp, dest)
    })();
    if r.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    r
}

/// The permission bits of `dest`, if it exists (on Unix).
#[cfg(unix)]
fn dest_mode(dest: &Path) -> Option<u32> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(dest)
        .ok()
        .map(|m| m.permissions().mode() & 0o7777)
}

#[cfg(not(unix))]
fn dest_mode(_dest: &Path) -> Option<u32> {
    None
}

impl Wfdb {
    /// The bytes of the header of `record`, the name of the file it was
    /// read from, and whether that is a URL.
    fn meta_read(&mut self, record: &[u8]) -> Result<(Vec<u8>, Vec<u8>, bool), Error> {
        let name = record_name(record)?;
        let fail = || Error::new(format!("can't read header for record {}", text(record)));
        let mut f = self
            .wfdb_open("hea", &name[..], WFDB_READ)
            .ok_or_else(fail)?;
        let path = self.wfdb_filename().to_vec();
        let data = f.read_to_end();
        let err = f.error();
        f.close();
        if err {
            return Err(fail());
        }
        let url = is_url(&path);
        Ok((data, path, url))
    }

    /// The entries of `data` (the header of `record`), one per key (the
    /// first), with a warning for each key that has more than one.
    fn unique_entries(&mut self, data: &[u8], record: &[u8]) -> Metadata {
        let hdr = Hdr::parse(data);
        // (first spelling of each folded key, and its line indices)
        let mut seen: Vec<(Vec<u8>, Vec<u8>, Vec<usize>)> = Vec::new();
        let mut out = Vec::new();
        for (i, k, v) in hdr.entries {
            let f = fold(&k);
            if let Some(s) = seen.iter_mut().find(|s| s.0 == f) {
                s.2.push(i);
                continue;
            }
            seen.push((f, k.clone(), vec![i]));
            out.push((k, v));
        }
        for (_, k, idx) in seen {
            if idx.len() > 1 {
                self.wfdb_error(format!(
                    "WFDB-x: header of record {} has more than one entry for key {} (lines {}); the first is used\n",
                    text(record),
                    text(&k),
                    line_numbers(&idx)
                ));
            }
        }
        out
    }

    /// The entries of the header of `record`, as [`read_metadata`] returns
    /// them, with the current input settings (for `read_header`, which does
    /// not call it for an EDF record or the standard input, `-`).
    pub(crate) fn header_metadata(&mut self, record: &[u8]) -> Result<Metadata, Error> {
        let (data, _, _) = self.meta_read(record)?;
        Ok(self.unique_entries(&data, record))
    }

    /// Runs `f` with the input directory and network access of `opt`.
    fn meta_input<T>(&mut self, opt: &MetadataOptions, f: impl FnOnce(&mut Wfdb) -> T) -> T {
        let ro = ReadOptions {
            input_dir: opt.input_dir.clone(),
            network: opt.network,
            ..Default::default()
        };
        self.with_input(&ro, f)
    }

    /// Applies `changes` (checked) to the header of `record`; returns the
    /// number of lines removed.
    fn meta_change(
        &mut self,
        record: &[u8],
        changes: Changes,
        opt: &MetadataOptions,
    ) -> Result<usize, Error> {
        let rname = text(record);
        let (data, path, url) = self.meta_input(opt, |w| w.meta_read(record))?;
        let dir = opt.dir.as_deref().filter(|d| !d.as_os_str().is_empty());
        let dest = match dir {
            None => {
                if url {
                    return Err(Error::new(format!(
                        "header of record {rname} was read from a URL, and cannot be changed (give dir to write the changed header to a local directory)"
                    )));
                }
                cstd::bytes_to_path(&path)
            }
            Some(d) => {
                let e = cstd::bytes_to_path(&expand_home(&cstd::os_to_bytes(
                    d.as_os_str().to_os_string(),
                )));
                if !e.is_dir() {
                    return Err(Error::new(format!(
                        "directory {} does not exist",
                        d.display()
                    )));
                }
                let k = path
                    .iter()
                    .rposition(|&c| c == b'/' || c == b'\\')
                    .map_or(0, |k| k + 1);
                e.join(cstd::bytes_to_path(&path[k..]))
            }
        };
        let mut hdr = Hdr::parse(&data);
        if hdr.rec.is_none() {
            return Err(Error::new(format!(
                "header of record {rname} has no record line"
            )));
        }
        // (every change is checked before the header is changed)
        for (k, v) in &changes {
            let idx = hdr.matches(k);
            if v.is_some() && idx.len() > 1 {
                return Err(Error::new(format!(
                    "header of record {rname} has more than one entry for key {} (lines {}); remove them first",
                    text(k),
                    line_numbers(&idx)
                )));
            }
        }
        let mut removed = 0;
        for (k, v) in &changes {
            let idx = hdr.matches(k);
            match v {
                None => {
                    for &i in idx.iter().rev() {
                        hdr.lines.remove(i);
                        hdr.reparse();
                    }
                    removed += idx.len();
                }
                Some(v) if !idx.is_empty() => {
                    hdr.lines[idx[0]].content = entry_line(k, v);
                    hdr.reparse();
                }
                Some(v) => hdr.insert(entry_line(k, v)),
            }
        }
        let out = hdr.to_bytes();
        if out != data || dir.is_some() {
            write_atomic(&dest, &out)
                .map_err(|_| Error::new(format!("can't write header for record {rname}")))?;
        }
        Ok(removed)
    }

    // -----------------------------------------------------------------------
    // The public methods

    /// Reads the metadata of a record, using this `Wfdb` value (see
    /// [`read_metadata`]).
    ///
    /// # Errors
    ///
    /// As [`read_metadata`].
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn read_metadata(&mut self, record: impl AsRef<[u8]>) -> Result<Metadata, Error> {
        self.read_metadata_with(record, &MetadataOptions::default())
    }

    /// Reads the metadata of a record with the `input_dir` and `network`
    /// options of `opt`, using this `Wfdb` value (see
    /// [`read_metadata_with`]).
    ///
    /// # Errors
    ///
    /// As [`read_metadata`].
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn read_metadata_with(
        &mut self,
        record: impl AsRef<[u8]>,
        opt: &MetadataOptions,
    ) -> Result<Metadata, Error> {
        let record = record.as_ref();
        record_name(record)?;
        self.meta_input(opt, |w| {
            let (data, _, _) = w.meta_read(record)?;
            Ok(w.unique_entries(&data, record))
        })
    }

    /// Returns the value of one metadata entry of a record, or `None`, using
    /// this `Wfdb` value (see [`get_metadata`]).
    ///
    /// # Errors
    ///
    /// As [`get_metadata`].
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn get_metadata(
        &mut self,
        record: impl AsRef<[u8]>,
        key: impl AsRef<[u8]>,
    ) -> Result<Option<Vec<u8>>, Error> {
        self.get_metadata_with(record, key, &MetadataOptions::default())
    }

    /// Returns the value of one metadata entry of a record, or `None`, with
    /// the `input_dir` and `network` options of `opt`, using this `Wfdb`
    /// value (see [`get_metadata_with`]).
    ///
    /// # Errors
    ///
    /// As [`get_metadata`].
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn get_metadata_with(
        &mut self,
        record: impl AsRef<[u8]>,
        key: impl AsRef<[u8]>,
        opt: &MetadataOptions,
    ) -> Result<Option<Vec<u8>>, Error> {
        let f = fold(&check_key(key.as_ref())?);
        let md = self.read_metadata_with(record, opt)?;
        Ok(md.into_iter().find(|(k, _)| fold(k) == f).map(|(_, v)| v))
    }

    /// Sets the value of a metadata entry in the header of a record, using
    /// this `Wfdb` value (see [`set_metadata`]).
    ///
    /// # Errors
    ///
    /// As [`set_metadata`].
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn set_metadata(
        &mut self,
        record: impl AsRef<[u8]>,
        key: impl AsRef<[u8]>,
        value: impl AsRef<[u8]>,
    ) -> Result<(), Error> {
        self.set_metadata_with(record, key, value, &MetadataOptions::default())
    }

    /// Sets the value of a metadata entry in the header of a record, with
    /// the options of `opt`, using this `Wfdb` value (see
    /// [`set_metadata_with`]).
    ///
    /// # Errors
    ///
    /// As [`set_metadata`].
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn set_metadata_with(
        &mut self,
        record: impl AsRef<[u8]>,
        key: impl AsRef<[u8]>,
        value: impl AsRef<[u8]>,
        opt: &MetadataOptions,
    ) -> Result<(), Error> {
        let (record, key) = (record.as_ref(), key.as_ref());
        let k = check_key(key)?;
        let v = check_value(key, value.as_ref())?;
        record_name(record)?;
        self.meta_change(record, vec![(k, Some(v))], opt)
            .map(|_| ())
    }

    /// Removes a metadata entry from the header of a record, using this
    /// `Wfdb` value (see [`remove_metadata`]).
    ///
    /// # Errors
    ///
    /// As [`remove_metadata`].
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn remove_metadata(
        &mut self,
        record: impl AsRef<[u8]>,
        key: impl AsRef<[u8]>,
    ) -> Result<usize, Error> {
        self.remove_metadata_with(record, key, &MetadataOptions::default())
    }

    /// Removes a metadata entry from the header of a record, with the
    /// options of `opt`, using this `Wfdb` value (see
    /// [`remove_metadata_with`]).
    ///
    /// # Errors
    ///
    /// As [`remove_metadata`].
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn remove_metadata_with(
        &mut self,
        record: impl AsRef<[u8]>,
        key: impl AsRef<[u8]>,
        opt: &MetadataOptions,
    ) -> Result<usize, Error> {
        let record = record.as_ref();
        let k = check_key(key.as_ref())?;
        record_name(record)?;
        self.meta_change(record, vec![(k, None)], opt)
    }

    /// Makes several changes to the metadata of a record in one write,
    /// using this `Wfdb` value (see [`update_metadata`]).
    ///
    /// # Errors
    ///
    /// As [`update_metadata`].
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn update_metadata<K: AsRef<[u8]>, V: AsRef<[u8]>>(
        &mut self,
        record: impl AsRef<[u8]>,
        changes: &[(K, Option<V>)],
    ) -> Result<(), Error> {
        self.update_metadata_with(record, changes, &MetadataOptions::default())
    }

    /// Makes several changes to the metadata of a record in one write, with
    /// the options of `opt`, using this `Wfdb` value (see
    /// [`update_metadata_with`]).
    ///
    /// # Errors
    ///
    /// As [`update_metadata`].
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn update_metadata_with<K: AsRef<[u8]>, V: AsRef<[u8]>>(
        &mut self,
        record: impl AsRef<[u8]>,
        changes: &[(K, Option<V>)],
        opt: &MetadataOptions,
    ) -> Result<(), Error> {
        let record = record.as_ref();
        let c = check_changes(changes)?;
        record_name(record)?;
        self.meta_change(record, c, opt).map(|_| ())
    }
}

// ---------------------------------------------------------------------------
// The free functions

/// Reads the metadata of a record: the `Key: value` entries of its header.
///
/// # Arguments
///
/// * `record`: the record name, without the `.hea` extension (a trailing
///   `.hea` is also accepted): a full path, absolute (`"/data/mitdb/100"`)
///   or in the home directory (`"~/Documents/100s"`), used as given; a
///   relative path (`"100s"`, `"data/100s"`), read from the input directory
///   if one is set (see [`Wfdb::wfdbx_set_input_dir`]), otherwise from the
///   current directory; or a URL
///   (`"https://physionet.org/files/mitdb/1.0.0/100"`), read only if network
///   access is on (see [`Wfdb::wfdbx_set_network`]).
///
/// Returns the `(key, value)` pairs, in file order (see the
/// [module documentation](self) for the rules). A key that appears more
/// than once (ignoring letter case) is returned once, with its first value,
/// and a warning is issued through [`Wfdb::wfdb_error`]. Uses the default
/// [`Wfdb`] value of the thread; [`Wfdb::read_metadata`] uses a given one.
/// [`read_metadata_with`] takes an input directory and network access for
/// the call.
///
/// # Examples
///
/// ```
/// // The sample record 100s, the first minute of record 100 of the MIT-BIH
/// // Arrhythmia Database, included with WFDB-x in tests/data:
/// # wfdbx::wfdbx_set_input_dir("../tests/data");
/// # /*
/// wfdbx::wfdbx_set_input_dir("tests/data"); // from the repository root
/// # */
/// for (key, value) in wfdbx::read_metadata("100s")? {
///     println!("{}: {}", String::from_utf8_lossy(&key), String::from_utf8_lossy(&value));
/// }
/// # Ok::<(), wfdbx::record::Error>(())
/// ```
///
/// # Errors
///
/// * The header cannot be found or read: "can't read header for record
///   REC".
/// * `record` is empty ("record name must not be empty") or `-` ("the
///   metadata of a header read from the standard input cannot be read or
///   changed").
///
/// Part of WFDB-x; not in the original WFDB package.
pub fn read_metadata(record: impl AsRef<[u8]>) -> Result<Metadata, Error> {
    with_default(|w| w.read_metadata(record))
}

/// Reads the metadata of a record, as [`read_metadata`] does, with the
/// `input_dir` and `network` options of `opt` (for this call only). Its
/// `dir` is not used. Uses the default [`Wfdb`] value of the thread.
///
/// # Examples
///
/// ```
/// use wfdbx::{read_metadata_with, MetadataOptions};
///
/// // The sample record 100s (see read_metadata), in tests/data:
/// let opt = MetadataOptions { input_dir: Some("../tests/data".into()), ..Default::default() };
/// # /*
/// let opt = MetadataOptions { input_dir: Some("tests/data".into()), ..Default::default() };
/// # */
/// let md = read_metadata_with("100s", &opt)?;
/// # Ok::<(), wfdbx::record::Error>(())
/// ```
///
/// # Errors
///
/// As [`read_metadata`].
///
/// Part of WFDB-x; not in the original WFDB package.
pub fn read_metadata_with(
    record: impl AsRef<[u8]>,
    opt: &MetadataOptions,
) -> Result<Metadata, Error> {
    with_default(|w| w.read_metadata_with(record, opt))
}

/// Returns the value of one metadata entry of a record, or `None`.
///
/// # Arguments
///
/// * `record`: the record name (see [`read_metadata`]).
/// * `key`: the key, such as `"Age"`. Letter case is ignored, and spaces at
///   either end are removed.
///
/// Returns the value (empty for an entry with an empty value), or `None` if
/// the header has no entry for `key`. If it has more than one, the first is
/// returned, and a warning is issued (see [`read_metadata`]). Uses the
/// default [`Wfdb`] value of the thread; [`Wfdb::get_metadata`] uses a given
/// one. [`get_metadata_with`] takes an input directory and network access
/// for the call.
///
/// # Examples
///
/// ```
/// // The sample record 100s (see read_metadata), in tests/data:
/// # wfdbx::wfdbx_set_input_dir("../tests/data");
/// # /*
/// wfdbx::wfdbx_set_input_dir("tests/data"); // from the repository root
/// # */
/// assert_eq!(wfdbx::get_metadata("100s", "age")?, None);
/// # Ok::<(), wfdbx::record::Error>(())
/// ```
///
/// # Errors
///
/// As [`read_metadata`]; also if `key` is not a valid key (see
/// [`set_metadata`]), before the header is read.
///
/// Part of WFDB-x; not in the original WFDB package.
pub fn get_metadata(
    record: impl AsRef<[u8]>,
    key: impl AsRef<[u8]>,
) -> Result<Option<Vec<u8>>, Error> {
    with_default(|w| w.get_metadata(record, key))
}

/// Returns the value of one metadata entry of a record, as [`get_metadata`]
/// does, with the `input_dir` and `network` options of `opt` (for this call
/// only). Its `dir` is not used. Uses the default [`Wfdb`] value of the
/// thread.
///
/// # Examples
///
/// This reads a header from a web server (network access is on for this
/// call only).
///
/// ```no_run
/// use wfdbx::{get_metadata_with, MetadataOptions};
///
/// let opt = MetadataOptions { network: Some(true), ..Default::default() };
/// let age = get_metadata_with("https://example.org/db/rec", "Age", &opt)?;
/// # Ok::<(), wfdbx::record::Error>(())
/// ```
///
/// # Errors
///
/// As [`get_metadata`].
///
/// Part of WFDB-x; not in the original WFDB package.
pub fn get_metadata_with(
    record: impl AsRef<[u8]>,
    key: impl AsRef<[u8]>,
    opt: &MetadataOptions,
) -> Result<Option<Vec<u8>>, Error> {
    with_default(|w| w.get_metadata_with(record, key, opt))
}

/// Sets the value of a metadata entry in the header of a record.
///
/// If the header has an entry for `key` (ignoring letter case), its line is
/// replaced by `# Key: value`, at the same position, with the spelling of
/// `key` given here. Otherwise the entry is added after the last info
/// string of the header. Every other line is kept, byte for byte (see the
/// [module documentation](self) for the rules).
///
/// # Arguments
///
/// * `record`: the record name (see [`read_metadata`]). The header is
///   changed where it was read, unless [`MetadataOptions::dir`] is given; a
///   header read from a URL can only be written elsewhere, with
///   [`set_metadata_with`] and [`MetadataOptions::dir`].
/// * `key`: the key, such as `"Age"` or `"Date of birth"`. Spaces at either
///   end are removed. It must not be empty, and must not contain `:`, `#`,
///   a line break or a NUL byte.
/// * `value`: the value, which may be a sentence. Spaces at either end are
///   removed. It must not contain a line break or a NUL byte; it may be
///   empty.
///
/// The arguments are checked before anything is written, and the header is
/// replaced in one step (through a temporary file in its directory, which
/// is removed on failure), so that an error leaves it unchanged. Uses the
/// default [`Wfdb`] value of the thread; [`Wfdb::set_metadata`] uses a given
/// one.
///
/// # Examples
///
/// ```no_run
/// // Writes "# Age: 63" in the header rec.hea, in the input directory.
/// wfdbx::set_metadata("rec", "Age", "63")?;
/// # Ok::<(), wfdbx::record::Error>(())
/// ```
///
/// # Errors
///
/// * `key` or `value` is not valid: "metadata key must not be empty",
///   "metadata key 'KEY' must not contain C", "value of metadata key 'KEY'
///   must not contain C" (C is `':'`, `'#'`, "a line break" or "a NUL
///   character").
/// * `record` is empty or `-` (see [`read_metadata`]).
/// * The header cannot be read: "can't read header for record REC".
/// * The header has more than one entry for `key`: "header of record REC
///   has more than one entry for key KEY (lines L1, L2); remove them
///   first".
/// * The header has no record line: "header of record REC has no record
///   line".
/// * The header was read from a URL, and no `dir` is given: "header of
///   record REC was read from a URL, and cannot be changed (give dir to
///   write the changed header to a local directory)".
/// * With [`MetadataOptions::dir`], the directory does not exist:
///   "directory DIR does not exist".
/// * The changed header cannot be written: "can't write header for record
///   REC".
///
/// Part of WFDB-x; not in the original WFDB package.
pub fn set_metadata(
    record: impl AsRef<[u8]>,
    key: impl AsRef<[u8]>,
    value: impl AsRef<[u8]>,
) -> Result<(), Error> {
    with_default(|w| w.set_metadata(record, key, value))
}

/// Sets the value of a metadata entry, as [`set_metadata`] does, with the
/// options of `opt` (for this call only): the input directory and network
/// access for reading the header, and the directory `dir` in which to
/// write the changed header instead of changing the header itself. Uses the
/// default [`Wfdb`] value of the thread.
///
/// # Examples
///
/// ```
/// use wfdbx::{set_metadata_with, MetadataOptions};
///
/// // A copy of the header of the sample record 100s (see read_metadata),
/// // read from tests/data, with the entry "# Age: 69", written to a new
/// // directory. The header in tests/data is not changed.
/// let out = std::env::temp_dir().join("wfdbx-set-metadata-example");
/// std::fs::create_dir_all(&out).unwrap();
/// let opt = MetadataOptions {
///     input_dir: Some("../tests/data".into()),
/// # /*
///     input_dir: Some("tests/data".into()),
/// # */
///     dir: Some(out.clone()),
///     ..Default::default()
/// };
/// set_metadata_with("100s", "Age", "69", &opt)?;
/// # std::fs::remove_dir_all(&out).unwrap();
/// # Ok::<(), wfdbx::record::Error>(())
/// ```
///
/// # Errors
///
/// As [`set_metadata`].
///
/// Part of WFDB-x; not in the original WFDB package.
pub fn set_metadata_with(
    record: impl AsRef<[u8]>,
    key: impl AsRef<[u8]>,
    value: impl AsRef<[u8]>,
    opt: &MetadataOptions,
) -> Result<(), Error> {
    with_default(|w| w.set_metadata_with(record, key, value, opt))
}

/// Removes a metadata entry from the header of a record.
///
/// Every entry for `key` (ignoring letter case) is removed, so this also
/// repairs a header that has more than one. Other lines are kept, byte for
/// byte. Nothing is written if the header has no entry for `key`.
///
/// # Arguments
///
/// * `record`: the record name (see [`set_metadata`]).
/// * `key`: the key (see [`set_metadata`]).
///
/// Returns the number of lines removed (0 if the header has no entry for
/// `key`). Uses the default [`Wfdb`] value of the thread;
/// [`Wfdb::remove_metadata`] uses a given one.
///
/// # Examples
///
/// ```no_run
/// let n = wfdbx::remove_metadata("rec", "Age")?; // 1 if rec.hea had "# Age: ..."
/// # Ok::<(), wfdbx::record::Error>(())
/// ```
///
/// # Errors
///
/// As [`set_metadata`] (except that more than one entry for `key` is not an
/// error).
///
/// Part of WFDB-x; not in the original WFDB package.
pub fn remove_metadata(record: impl AsRef<[u8]>, key: impl AsRef<[u8]>) -> Result<usize, Error> {
    with_default(|w| w.remove_metadata(record, key))
}

/// Removes a metadata entry, as [`remove_metadata`] does, with the options
/// of `opt` (for this call only; see [`set_metadata_with`]). With
/// [`MetadataOptions::dir`], the header is written to `dir` even if nothing
/// is removed. Uses the default [`Wfdb`] value of the thread.
///
/// # Examples
///
/// ```no_run
/// use wfdbx::{remove_metadata_with, MetadataOptions};
///
/// let opt = MetadataOptions { input_dir: Some("data".into()), ..Default::default() };
/// remove_metadata_with("rec", "Age", &opt)?; // changes data/rec.hea
/// # Ok::<(), wfdbx::record::Error>(())
/// ```
///
/// # Errors
///
/// As [`remove_metadata`].
///
/// Part of WFDB-x; not in the original WFDB package.
pub fn remove_metadata_with(
    record: impl AsRef<[u8]>,
    key: impl AsRef<[u8]>,
    opt: &MetadataOptions,
) -> Result<usize, Error> {
    with_default(|w| w.remove_metadata_with(record, key, opt))
}

/// Makes several changes to the metadata of a record in one write.
///
/// # Arguments
///
/// * `record`: the record name (see [`set_metadata`]).
/// * `changes`: `(key, value)` pairs, applied in order: as [`set_metadata`]
///   does for a value `Some(value)`, or as [`remove_metadata`] does for
///   `None`. No two keys may differ only in letter case. (A list of
///   removals only needs the type of its values: `&[("Dx", None::<&str>)]`.)
///
/// All the changes are checked first: if one is not valid, none is made.
/// Uses the default [`Wfdb`] value of the thread; [`Wfdb::update_metadata`]
/// uses a given one.
///
/// # Examples
///
/// ```no_run
/// // "# Age: 64" (replaced or added), and no entry for Dx.
/// wfdbx::update_metadata("rec", &[("Age", Some("64")), ("Dx", None)])?;
/// # Ok::<(), wfdbx::record::Error>(())
/// ```
///
/// # Errors
///
/// As [`set_metadata`]; also "metadata key 'KEY' is given more than once
/// (keys are compared without regard to letter case)".
///
/// Part of WFDB-x; not in the original WFDB package.
pub fn update_metadata<K: AsRef<[u8]>, V: AsRef<[u8]>>(
    record: impl AsRef<[u8]>,
    changes: &[(K, Option<V>)],
) -> Result<(), Error> {
    with_default(|w| w.update_metadata(record, changes))
}

/// Makes several changes to the metadata of a record, as
/// [`update_metadata`] does, with the options of `opt` (for this call only;
/// see [`set_metadata_with`]). Uses the default [`Wfdb`] value of the
/// thread.
///
/// # Examples
///
/// ```no_run
/// use std::path::PathBuf;
/// use wfdbx::{update_metadata_with, MetadataOptions};
///
/// // rec.hea, changed, written to the existing directory "out".
/// let opt = MetadataOptions { dir: Some(PathBuf::from("out")), ..Default::default() };
/// update_metadata_with("rec", &[("Age", Some("64")), ("Sex", Some("F"))], &opt)?;
/// # Ok::<(), wfdbx::record::Error>(())
/// ```
///
/// # Errors
///
/// As [`update_metadata`].
///
/// Part of WFDB-x; not in the original WFDB package.
pub fn update_metadata_with<K: AsRef<[u8]>, V: AsRef<[u8]>>(
    record: impl AsRef<[u8]>,
    changes: &[(K, Option<V>)],
    opt: &MetadataOptions,
) -> Result<(), Error> {
    with_default(|w| w.update_metadata_with(record, changes, opt))
}
