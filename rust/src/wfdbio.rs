//! Low-level I/O of the WFDB library (port of `lib/wfdbio.c`): finding and
//! opening WFDB files (`wfdb_open`, `wfdb_fopen`, `wfdbfile`), the input
//! and output directories and network access (WFDB-x), the WFDB path of
//! legacy mode (`getwfdb`, `setwfdb`, ...), error reporting (`wfdb_error`,
//! `wfdberror`, `wfdbquiet`), and [`WfdbFile`], the buffered file type used
//! by the library and the tools (C's `WFDB_FILE` / `FILE *`).
//!
//! wfdb-x: files are found by explicit names (see [`Wfdb::wfdb_open`]): a
//! relative name is read under the input directory
//! ([`Wfdb::wfdbx_set_input_dir`], `WFDBX_INPUT_DIR`) and written under the
//! output directory ([`Wfdb::wfdbx_set_output_dir`], `WFDBX_OUTPUT_DIR`);
//! by default, the current directory. An absolute name, a `~` name or a
//! URL is used as given; nothing else is searched. A URL is opened only
//! with network access ([`Wfdb::wfdbx_set_network`], `WFDBX_NETWORK`); it
//! is then read in full by the `curl` program. Legacy mode searches the
//! WFDB path as the C library does, without network access.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Rust translation of lib/wfdbio.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original code, but it is new code, not the original C code.
//
// Changes from the original: files are found only where they are named, not by
// a search of the WFDB path: a relative name is read under the input directory
// and written under the output directory (by default, the current directory),
// and an absolute name, a ~ name or a URL is used as given; setwfdb, getwfdb
// and resetwfdb set and return the input directory, and the WFDB environment
// variable is ignored; a URL is opened only if network access is turned on
// (wfdbx_set_network or WFDBX_NETWORK), and is then read in full by the curl
// program, run without a shell; the original's HTTP and FTP code (NETFILES) is
// not translated; ".." is accepted in names, and only the last component of a
// record name is checked; write errors are counted (wfdbx_write_errors);
// additions: wfdbx_set_input_dir, wfdbx_get_input_dir, wfdbx_set_output_dir,
// wfdbx_get_output_dir, wfdbx_set_network, wfdbx_get_network,
// wfdbx_write_errors, wfdbx_note_write_error and wfdbx_fclose_output; legacy
// mode (wfdbx_set_legacy) restores the original behavior (the WFDB path,
// without network access). Each change is marked "wfdb-x:" in the code;
// docs/DIVERGENCES.md gives the reasons.
//
// Original C code: lib/wfdbio.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1988-2013 George B. Moody; revised 2010-2022 by
//   Benjamin Moody.
// Rust translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

use std::collections::HashMap;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom, Write};
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::{Mutex, OnceLock};

use crate::cstd::{self, sprintf_into, Arg, EOF, SEEK_CUR, SEEK_END, SEEK_SET};
use crate::types::*;
use crate::wfdb::{with_default, OptBytes, Wfdb};

/// The date reported by `wfdberror` (that of the 10.7.0 release; the C
/// library reports the date on which it was compiled).
const WFDB_BUILD_DATE: &[u8] = b"Jun 10 2022";

/// Directory separator.
const DSEP: u8 = b'/';

/// Default size of a [`WfdbFile`] buffer.
pub const WFDB_BUFSIZE: usize = 32768;

/// Size of the read buffer of a [`WfdbFile`] when the file system does not
/// give one: that of glibc's stdio buffers (`st_blksize`, usually 4096).
const RBUFSIZE: usize = 4096;

// ===========================================================================
// WfdbFile

enum Kind {
    /// A regular file (or device, pipe, ...).
    File(File),
    /// The standard input (a duplicate of its descriptor if available).
    Stdin(Option<File>),
    /// The standard output (writes go to the shared buffer of
    /// [`cstd::out`]).
    Stdout,
    /// The standard error (unbuffered).
    Stderr,
    /// An in-memory input file.
    Mem,
}

/// An open file with C stdio semantics (C's `FILE *` and the WFDB
/// library's `WFDB_FILE`).
///
/// * Reads and writes are buffered; [`getc`](WfdbFile::getc) and
///   [`putc`](WfdbFile::putc) are inlined fast paths.
/// * End of file and errors set sticky flags ([`eof`](WfdbFile::eof),
///   [`error`](WfdbFile::error)) as glibc does: after end of file, reads
///   return `EOF` until [`clearerr`](WfdbFile::clearerr) or a seek.
/// * A file opened on the standard input ([`WfdbFile::stdin`], or
///   `wfdb_open` of `"-"`) never closes it; bytes it buffered but did not
///   consume are given back to the next reader of the standard input
///   when it is closed or dropped.
/// * A file opened on the standard output writes into the shared buffered
///   standard output ([`cstd::out`]), so its output is ordered with
///   [`cprintf!`](crate::cprintf).
/// * Dropping a `WfdbFile` flushes it (errors are then ignored); use
///   [`close`](WfdbFile::close) to get the status of C's `fclose`.
pub struct WfdbFile {
    kind: Kind,
    rbuf: Vec<u8>,
    rpos: usize,
    rlen: usize,
    wbuf: Vec<u8>,
    /// Ready for buffered writes (a File, not in read mode).
    wready: bool,
    bufsize: usize,
    /// Read buffer size (glibc reads blocks of `st_blksize` bytes): so that
    /// the file is read when, and as far as, C reads it (this matters when
    /// a file is read while it is being rewritten).
    rbufsize: usize,
    /// Offset of the underlying descriptor (None if unknown/unseekable).
    fpos: Option<i64>,
    eof: bool,
    err: bool,
    can_read: bool,
    can_write: bool,
    append: bool,
    closed: bool,
    /// wfdb-x: an output file of the library (see [`wfdbx_write_errors`]).
    out: bool,
    /// wfdb-x: a remote file (a URL fetched in full, read from memory).
    remote: bool,
    /// The name with which a local file was opened (for [`FileId`] on
    /// systems without file identities in the standard library).
    path: Vec<u8>,
}

impl std::fmt::Debug for WfdbFile {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let k = match self.kind {
            Kind::File(_) => "file",
            Kind::Stdin(_) => "stdin",
            Kind::Stdout => "stdout",
            Kind::Stderr => "stderr",
            Kind::Mem => "memory",
        };
        f.debug_struct("WfdbFile")
            .field("kind", &k)
            .field("eof", &self.eof)
            .field("error", &self.err)
            .finish()
    }
}

impl WfdbFile {
    fn with_kind(kind: Kind, can_read: bool, can_write: bool) -> WfdbFile {
        WfdbFile {
            kind,
            rbuf: Vec::new(),
            rpos: 0,
            rlen: 0,
            wbuf: Vec::new(),
            wready: false,
            bufsize: WFDB_BUFSIZE,
            rbufsize: RBUFSIZE,
            fpos: Some(0),
            eof: false,
            err: false,
            can_read,
            can_write,
            append: false,
            closed: false,
            out: false,
            remote: false,
            path: Vec::new(),
        }
    }

    /// C `fopen(path, mode)` (no WFDB path search or name checks; see
    /// [`wfdb_fopen`] for the library's version). `mode` is a C mode
    /// string (`"rb"`, `"wb"`, `"ab"`, `"r+b"`, ...; `b` is ignored).
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn fopen(path: &[u8], mode: &[u8]) -> Option<WfdbFile> {
        let m: Vec<u8> = mode
            .iter()
            .copied()
            .filter(|&c| c != b'b' && c != b't')
            .collect();
        let plus = m.contains(&b'+');
        let mut o = std::fs::OpenOptions::new();
        let (r, w, append) = match m.first() {
            Some(b'r') => {
                o.read(true);
                if plus {
                    o.write(true);
                }
                (true, plus, false)
            }
            Some(b'w') => {
                o.write(true).create(true).truncate(true);
                if plus {
                    o.read(true);
                }
                (plus, true, false)
            }
            Some(b'a') => {
                o.append(true).create(true);
                if plus {
                    o.read(true);
                }
                (plus, true, true)
            }
            _ => return None,
        };
        let mut f = o.open(cstd::bytes_to_path(path)).ok()?;
        // (glibc positions append-mode streams at the end of the file.)
        let end = if append {
            f.seek(SeekFrom::End(0)).ok().map(|p| p as i64)
        } else {
            Some(0)
        };
        let blksize = file_blksize(&f);
        let mut wf = WfdbFile::with_kind(Kind::File(f), r, w);
        wf.path = path.to_vec();
        wf.fpos = end;
        wf.append = append;
        wf.rbufsize = blksize;
        Some(wf)
    }

    /// A file on the standard input (C's `stdin`; the file attached by
    /// [`freopen_stdin`], if any).
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn stdin() -> WfdbFile {
        let replaced = STDIN_REPLACEMENT
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .and_then(|f| f.try_clone().ok());
        let dup = replaced.or_else(Self::dup_stdin);
        let mut f = WfdbFile::with_kind(Kind::Stdin(dup), true, false);
        f.fpos = match &mut f.kind {
            Kind::Stdin(Some(file)) => file.stream_position().ok().map(|p| p as i64),
            _ => None,
        };
        f
    }

    #[cfg(unix)]
    fn dup_stdin() -> Option<File> {
        use std::os::fd::AsFd;
        std::io::stdin()
            .as_fd()
            .try_clone_to_owned()
            .ok()
            .map(File::from)
    }

    #[cfg(windows)]
    fn dup_stdin() -> Option<File> {
        use std::os::windows::io::AsHandle;
        std::io::stdin()
            .as_handle()
            .try_clone_to_owned()
            .ok()
            .map(File::from)
    }

    #[cfg(not(any(unix, windows)))]
    fn dup_stdin() -> Option<File> {
        None
    }

    /// A file on the standard output (C's `stdout`; writes go to the
    /// shared buffer of [`cstd::out`]).
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn stdout() -> WfdbFile {
        let mut f = WfdbFile::with_kind(Kind::Stdout, false, true);
        f.fpos = None;
        f
    }

    /// A file on the standard error (C's `stderr`, unbuffered).
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn stderr() -> WfdbFile {
        let mut f = WfdbFile::with_kind(Kind::Stderr, false, true);
        f.fpos = None;
        f
    }

    /// An input file reading from memory (seekable).
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn from_bytes(data: Vec<u8>) -> WfdbFile {
        let mut f = WfdbFile::with_kind(Kind::Mem, true, false);
        f.rlen = data.len();
        f.fpos = Some(data.len() as i64);
        f.rbuf = data;
        f
    }

    /// Is this the standard input, output, or error?
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn is_std(&self) -> bool {
        matches!(self.kind, Kind::Stdin(_) | Kind::Stdout | Kind::Stderr)
    }

    /// wfdb-x: is this a remote file (a URL, fetched in full)?
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn is_remote(&self) -> bool {
        self.remote
    }

    /// wfdb-x: the identity of an open local file (`None` for the standard
    /// streams, memory and remote files).
    pub(crate) fn file_id(&self) -> Option<FileId> {
        let Kind::File(f) = &self.kind else {
            return None;
        };
        if self.remote {
            return None;
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            let _ = &self.path;
            f.metadata().ok().map(|m| FileId(m.dev(), m.ino()))
        }
        #[cfg(not(unix))]
        {
            let _ = f;
            path_id(&self.path)
        }
    }

    /// wfdb-x: the size in bytes of an open local file (`None` for the
    /// standard streams, memory and remote files).
    pub(crate) fn local_size(&self) -> Option<u64> {
        match &self.kind {
            Kind::File(f) if !self.remote => f.metadata().ok().map(|m| m.len()),
            _ => None,
        }
    }

    /// The type of the file: [`WFDB_NET`] for a remote file (wfdb-x: a
    /// URL, fetched in full), otherwise [`WFDB_LOCAL`].
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn file_type(&self) -> i32 {
        if self.remote {
            WFDB_NET
        } else {
            WFDB_LOCAL
        }
    }

    /// Set the buffer size (C `setvbuf`, before any I/O).
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn set_bufsize(&mut self, n: usize) {
        self.bufsize = n.max(1);
    }

    // ---------------------------------------------------------------- input

    fn raw_read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        match &mut self.kind {
            Kind::File(f) => f.read(buf),
            Kind::Stdin(dup) => {
                {
                    let mut pb = cstd::STDIN_PUSHBACK
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                    if !pb.is_empty() {
                        let n = pb.len().min(buf.len());
                        buf[..n].copy_from_slice(&pb[..n]);
                        pb.drain(..n);
                        return Ok(n);
                    }
                }
                match dup {
                    Some(f) => f.read(buf),
                    None => std::io::stdin().lock().read(buf),
                }
            }
            _ => Ok(0),
        }
    }

    /// Refill the read buffer; false at end of file or on error.
    fn fill(&mut self) -> bool {
        if self.eof || self.err {
            return false;
        }
        if !self.can_read {
            self.err = true;
            return false;
        }
        if matches!(self.kind, Kind::Mem) {
            self.eof = true;
            return false;
        }
        if !self.wbuf.is_empty() && self.flush_wbuf() != 0 {
            return false;
        }
        self.wready = false;
        if self.rbuf.len() < self.rbufsize {
            self.rbuf.resize(self.rbufsize, 0);
        }
        loop {
            let mut tmp = std::mem::take(&mut self.rbuf);
            let n = self.rbufsize;
            let r = self.raw_read(&mut tmp[..n]);
            self.rbuf = tmp;
            match r {
                Ok(0) => {
                    self.rpos = 0;
                    self.rlen = 0;
                    self.eof = true;
                    return false;
                }
                Ok(n) => {
                    self.rpos = 0;
                    self.rlen = n;
                    if let Some(p) = self.fpos.as_mut() {
                        *p += n as i64;
                    }
                    return true;
                }
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(_) => {
                    self.err = true;
                    return false;
                }
            }
        }
    }

    /// C `getc`: the next byte (0..=255), or `EOF` (-1).
    ///
    /// Translation of the C function wfdb_getc() (lib/wfdbio.c, WFDB 10.7.0):
    /// same arguments and results.
    #[inline]
    pub fn getc(&mut self) -> i32 {
        if self.rpos < self.rlen {
            let c = self.rbuf[self.rpos];
            self.rpos += 1;
            c as i32
        } else {
            self.getc_slow()
        }
    }

    #[cold]
    fn getc_slow(&mut self) -> i32 {
        if self.fill() {
            let c = self.rbuf[self.rpos];
            self.rpos += 1;
            c as i32
        } else {
            EOF
        }
    }

    /// C `ungetc(c, fp)`: push a byte back (returns `c`, or `EOF` if `c`
    /// is `EOF`).
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn ungetc(&mut self, c: i32) -> i32 {
        if c == EOF {
            return EOF;
        }
        if self.rpos > 0 {
            self.rpos -= 1;
            self.rbuf[self.rpos] = c as u8;
        } else {
            self.rbuf.insert(0, c as u8);
            self.rlen += 1;
        }
        self.eof = false;
        c
    }

    /// C `fread(buf, 1, buf.len(), fp)`: returns the number of bytes read.
    ///
    /// As in glibc, a request for less than a buffer refills the buffer,
    /// and larger ones read whole blocks directly into `buf`.
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn read(&mut self, buf: &mut [u8]) -> usize {
        let mut done = 0;
        while done < buf.len() {
            let avail = self.rlen - self.rpos;
            if avail > 0 {
                let n = avail.min(buf.len() - done);
                buf[done..done + n].copy_from_slice(&self.rbuf[self.rpos..self.rpos + n]);
                self.rpos += n;
                done += n;
                continue;
            }
            let want = buf.len() - done;
            if want < self.rbufsize || !matches!(self.kind, Kind::File(_) | Kind::Stdin(_)) {
                if !self.fill() {
                    break;
                }
                continue;
            }
            let count = want - want % self.rbufsize;
            match self.read_direct(&mut buf[done..done + count]) {
                0 => break,
                n => done += n,
            }
        }
        done
    }

    /// One read(2) into `buf` (the read buffer being empty), as glibc does
    /// for large requests; returns the number of bytes read (0 at end of
    /// file or on error).
    fn read_direct(&mut self, buf: &mut [u8]) -> usize {
        if self.eof || self.err {
            return 0;
        }
        if !self.can_read {
            self.err = true;
            return 0;
        }
        if !self.wbuf.is_empty() && self.flush_wbuf() != 0 {
            return 0;
        }
        self.wready = false;
        loop {
            match self.raw_read(buf) {
                Ok(0) => {
                    self.eof = true;
                    return 0;
                }
                Ok(n) => {
                    if let Some(p) = self.fpos.as_mut() {
                        *p += n as i64;
                    }
                    return n;
                }
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(_) => {
                    self.err = true;
                    return 0;
                }
            }
        }
    }

    /// C `fread(p, size, n, fp)`: reads up to `n` items of `size` bytes
    /// into `buf` (which must hold `size * n` bytes) and returns the number
    /// of complete items read.
    ///
    /// Translation of the C function wfdb_fread() (lib/wfdbio.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn fread(&mut self, buf: &mut [u8], size: usize, n: usize) -> usize {
        if size == 0 || n == 0 {
            return 0;
        }
        let got = self.read(&mut buf[..size * n]);
        got / size
    }

    /// Read a line, including its newline if any, into `line` (which is
    /// cleared first). Returns the number of bytes read (0 at end of file).
    ///
    /// Translation of the C function wfdb_getline() (lib/wfdbio.c, WFDB
    /// 10.7.0): same arguments and results.
    pub fn getline(&mut self, line: &mut Vec<u8>) -> usize {
        line.clear();
        loop {
            if self.rpos < self.rlen {
                let avail = &self.rbuf[self.rpos..self.rlen];
                match avail.iter().position(|&c| c == b'\n') {
                    Some(k) => {
                        line.extend_from_slice(&avail[..=k]);
                        self.rpos += k + 1;
                        return line.len();
                    }
                    None => {
                        line.extend_from_slice(avail);
                        self.rpos = self.rlen;
                    }
                }
            }
            if !self.fill() {
                return line.len();
            }
        }
    }

    /// C `fgets(s, size, fp)`: read at most `size - 1` bytes, up to and
    /// including a newline, into `s` (cleared first). Returns false (C's
    /// `NULL`) if end of file (or an error) occurs before any byte is read.
    ///
    /// Translation of the C function wfdb_fgets() (lib/wfdbio.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn fgets(&mut self, s: &mut Vec<u8>, size: usize) -> bool {
        s.clear();
        let lim = size.saturating_sub(1);
        if lim == 0 {
            return size == 1;
        }
        loop {
            if self.rpos < self.rlen {
                let want = lim - s.len();
                let end = (self.rpos + want).min(self.rlen);
                let avail = &self.rbuf[self.rpos..end];
                match avail.iter().position(|&c| c == b'\n') {
                    Some(k) => {
                        s.extend_from_slice(&avail[..=k]);
                        self.rpos += k + 1;
                        return true;
                    }
                    None => {
                        s.extend_from_slice(avail);
                        self.rpos = end;
                        if s.len() >= lim {
                            return true;
                        }
                    }
                }
            }
            if !self.fill() {
                return !s.is_empty();
            }
        }
    }

    /// Read everything up to the end of the file.
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn read_to_end(&mut self) -> Vec<u8> {
        let mut v = Vec::new();
        loop {
            if self.rpos < self.rlen {
                v.extend_from_slice(&self.rbuf[self.rpos..self.rlen]);
                self.rpos = self.rlen;
            }
            if !self.fill() {
                return v;
            }
        }
    }

    /// `wfdb_g16`: a 16-bit integer in PDP-11 (little-endian) byte order,
    /// sign-extended. At end of file the missing bytes read as 0xff (EOF).
    ///
    /// Translation of the C function wfdb_g16() (lib/wfdbio.c, WFDB 10.7.0):
    /// same arguments and results.
    #[inline]
    pub fn g16(&mut self) -> i32 {
        let x = self.getc();
        let y = self.getc();
        (((y << 8) | (x & 0xff)) as i16) as i32
    }

    /// `wfdb_g32`: a 32-bit integer in PDP-11 byte order (high 16-bit word
    /// first, each word little-endian), as a C `long`.
    ///
    /// Translation of the C function wfdb_g32() (lib/wfdbio.c, WFDB 10.7.0):
    /// same arguments and results.
    #[inline]
    pub fn g32(&mut self) -> i64 {
        let x = self.g16() as i64;
        let y = self.g16() as i64;
        (x << 16) | (y & 0xffff)
    }

    // --------------------------------------------------------------- output

    fn flush_wbuf(&mut self) -> i32 {
        if self.wbuf.is_empty() {
            return 0;
        }
        let r = match &mut self.kind {
            Kind::File(f) => f.write_all(&self.wbuf),
            _ => Ok(()),
        };
        let n = self.wbuf.len() as i64;
        self.wbuf.clear();
        match r {
            Ok(()) => {
                if self.append {
                    if let Kind::File(f) = &mut self.kind {
                        self.fpos = f.stream_position().ok().map(|p| p as i64);
                    }
                } else if let Some(p) = self.fpos.as_mut() {
                    *p += n;
                }
                0
            }
            Err(_) => {
                self.err = true;
                EOF
            }
        }
    }

    /// Prepare for writing (leave read mode); false if not writable.
    fn prepare_write(&mut self) -> bool {
        if !self.can_write {
            self.err = true;
            return false;
        }
        if self.rpos < self.rlen {
            // Reposition the descriptor at the logical position.
            let back = (self.rlen - self.rpos) as i64;
            if let Kind::File(f) = &mut self.kind {
                match f.seek(SeekFrom::Current(-back)) {
                    Ok(p) => self.fpos = Some(p as i64),
                    Err(_) => {
                        self.err = true;
                        return false;
                    }
                }
            }
        }
        self.rpos = 0;
        self.rlen = 0;
        if matches!(self.kind, Kind::File(_)) {
            self.wready = true;
            if self.wbuf.capacity() < self.bufsize {
                self.wbuf.reserve(self.bufsize - self.wbuf.len());
            }
        }
        true
    }

    /// C `putc`: write a byte; returns it, or `EOF` on error.
    ///
    /// Translation of the C function wfdb_putc() (lib/wfdbio.c, WFDB 10.7.0):
    /// same arguments and results.
    #[inline]
    pub fn putc(&mut self, c: u8) -> i32 {
        if self.wready && self.wbuf.len() < self.bufsize {
            self.wbuf.push(c);
            return c as i32;
        }
        self.putc_slow(c)
    }

    #[cold]
    fn putc_slow(&mut self, c: u8) -> i32 {
        if self.write(&[c]) == 1 {
            c as i32
        } else {
            EOF
        }
    }

    /// C `fwrite(b, 1, b.len(), fp)`: returns the number of bytes written.
    ///
    /// Translation of the C function wfdb_fwrite() (lib/wfdbio.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn write(&mut self, b: &[u8]) -> usize {
        if !self.wready && !self.prepare_write() {
            return 0;
        }
        match self.kind {
            Kind::Stdout => {
                cstd::out().write(b);
                b.len()
            }
            Kind::Stderr => {
                cstd::ewrite(b);
                b.len()
            }
            _ => {
                if self.wbuf.len() + b.len() > self.bufsize {
                    if self.flush_wbuf() != 0 {
                        return 0;
                    }
                    if b.len() >= self.bufsize {
                        let r = match &mut self.kind {
                            Kind::File(f) => f.write_all(b),
                            _ => Ok(()),
                        };
                        return match r {
                            Ok(()) => {
                                if self.append {
                                    if let Kind::File(f) = &mut self.kind {
                                        self.fpos = f.stream_position().ok().map(|p| p as i64);
                                    }
                                } else if let Some(p) = self.fpos.as_mut() {
                                    *p += b.len() as i64;
                                }
                                b.len()
                            }
                            Err(_) => {
                                self.err = true;
                                0
                            }
                        };
                    }
                }
                self.wbuf.extend_from_slice(b);
                b.len()
            }
        }
    }

    /// C `fprintf(fp, fmt, ...)`: returns the number of bytes written (or
    /// -1 on error). See [`cfprintf!`](crate::cfprintf).
    ///
    /// Translation of the C function wfdb_fprintf() (lib/wfdbio.c, WFDB
    /// 10.7.0): same arguments and results.
    pub fn printf(&mut self, fmt: &[u8], args: &[Arg]) -> i32 {
        match self.kind {
            Kind::Stdout => cstd::out().printf(fmt, args),
            Kind::Stderr => cstd::eprintf(fmt, args),
            _ => {
                if !self.wready && !self.prepare_write() {
                    return -1;
                }
                let n = sprintf_into(&mut self.wbuf, fmt, args);
                if self.wbuf.len() >= self.bufsize && self.flush_wbuf() != 0 {
                    return -1;
                }
                n as i32
            }
        }
    }

    /// `wfdb_p16`: write a 16-bit integer in PDP-11 byte order.
    ///
    /// Translation of the C function wfdb_p16() (lib/wfdbio.c, WFDB 10.7.0):
    /// same arguments and results.
    #[inline]
    pub fn p16(&mut self, x: u32) {
        self.putc(x as u8);
        self.putc((x >> 8) as u8);
    }

    /// `wfdb_p32`: write a 32-bit integer in PDP-11 byte order (high word
    /// first).
    ///
    /// Translation of the C function wfdb_p32() (lib/wfdbio.c, WFDB 10.7.0):
    /// same arguments and results.
    #[inline]
    pub fn p32(&mut self, x: i64) {
        self.p16((x >> 16) as u32);
        self.p16(x as u32);
    }

    /// C `fflush`: returns 0, or `EOF` on error.
    ///
    /// Translation of the C function wfdb_fflush() (lib/wfdbio.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn flush(&mut self) -> i32 {
        match self.kind {
            Kind::Stdout => cstd::out().flush(),
            _ => self.flush_wbuf(),
        }
    }

    // ------------------------------------------------------------ positions

    /// C `ftell`: the current position, or -1 if it is unknown (a pipe).
    ///
    /// Translation of the C function wfdb_ftell() (lib/wfdbio.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn tell(&mut self) -> i64 {
        match self.kind {
            Kind::Stdout => stdout_tell(),
            _ => match self.fpos {
                Some(p) => p - (self.rlen - self.rpos) as i64 + self.wbuf.len() as i64,
                None => -1,
            },
        }
    }

    /// C `fseek(fp, offset, whence)` ([`SEEK_SET`], [`SEEK_CUR`],
    /// [`SEEK_END`]): returns 0, or -1 on error (e.g. on a pipe). Clears
    /// the end-of-file flag.
    ///
    /// Translation of the C function wfdb_fseek() (lib/wfdbio.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn seek(&mut self, offset: i64, whence: i32) -> i32 {
        if matches!(self.kind, Kind::Stdout | Kind::Stderr) {
            return -1;
        }
        if self.flush_wbuf() != 0 {
            return -1;
        }
        self.wready = false;
        let Some(fpos) = self.fpos else {
            return -1;
        };
        let cur = fpos - (self.rlen - self.rpos) as i64;
        let target = match whence {
            SEEK_SET => offset,
            SEEK_CUR => cur + offset,
            SEEK_END => {
                if let Kind::Mem = self.kind {
                    self.rbuf.len() as i64 + offset
                } else {
                    let r = match &mut self.kind {
                        Kind::File(f) => f.seek(SeekFrom::End(offset)),
                        Kind::Stdin(Some(f)) => f.seek(SeekFrom::End(offset)),
                        _ => return -1,
                    };
                    return match r {
                        Ok(p) => {
                            self.fpos = Some(p as i64);
                            self.rpos = 0;
                            self.rlen = 0;
                            self.eof = false;
                            0
                        }
                        Err(_) => -1,
                    };
                }
            }
            _ => return -1,
        };
        if target < 0 {
            return -1;
        }
        if let Kind::Mem = self.kind {
            self.rpos = (target as usize).min(self.rbuf.len());
            self.eof = false;
            return 0;
        }
        // Within the current read buffer: just move.
        let bstart = fpos - self.rlen as i64;
        if self.rlen > 0 && target >= bstart && target <= fpos {
            self.rpos = (target - bstart) as usize;
            self.eof = false;
            return 0;
        }
        let r = match &mut self.kind {
            Kind::File(f) => f.seek(SeekFrom::Start(target as u64)),
            Kind::Stdin(Some(f)) => f.seek(SeekFrom::Start(target as u64)),
            _ => return -1,
        };
        match r {
            Ok(p) => {
                self.fpos = Some(p as i64);
                self.rpos = 0;
                self.rlen = 0;
                self.eof = false;
                0
            }
            Err(_) => -1,
        }
    }

    /// C `feof`.
    ///
    /// Translation of the C function wfdb_feof() (lib/wfdbio.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn eof(&self) -> bool {
        self.eof
    }

    /// C `ferror`.
    ///
    /// Translation of the C function wfdb_ferror() (lib/wfdbio.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn error(&self) -> bool {
        self.err || (matches!(self.kind, Kind::Stdout) && cstd::out().error())
    }

    /// C `clearerr`.
    ///
    /// Translation of the C function wfdb_clearerr() (lib/wfdbio.c, WFDB
    /// 10.7.0): same arguments and results.
    pub fn clearerr(&mut self) {
        self.eof = false;
        self.err = false;
    }

    fn release(&mut self) -> i32 {
        if self.closed {
            return 0;
        }
        self.closed = true;
        let mut status = if self.err { EOF } else { 0 };
        match self.kind {
            Kind::Stdin(_) => {
                if self.rpos < self.rlen {
                    let rest = &self.rbuf[self.rpos..self.rlen];
                    let mut pb = cstd::STDIN_PUSHBACK
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                    let mut v = rest.to_vec();
                    v.extend_from_slice(&pb);
                    *pb = v;
                }
            }
            Kind::Stdout => {
                if cstd::out().flush() != 0 {
                    status = EOF;
                }
            }
            _ => {
                if self.flush_wbuf() != 0 {
                    status = EOF;
                }
            }
        }
        self.rpos = 0;
        self.rlen = 0;
        status
    }

    /// C `fclose` (the standard streams are flushed, not closed): returns
    /// 0, or `EOF` if an error occurred (including earlier write errors).
    ///
    /// wfdb-x: an output file opened by the library (`wfdb_open`,
    /// `wfdb_fopen`) that could not be written, flushed or closed counts as
    /// a write error (see [`wfdbx_write_errors`]).
    ///
    /// Translation of the C function wfdb_fclose() (lib/wfdbio.c, WFDB 10.7.0):
    /// same arguments and results. Differences: write errors are counted;
    /// see docs/DIVERGENCES.md.
    pub fn close(mut self) -> i32 {
        let status = self.release();
        if self.out && status != 0 {
            wfdbx_note_write_error();
        }
        status
    }
}

impl Drop for WfdbFile {
    fn drop(&mut self) {
        let _ = self.release();
    }
}

/// `ftell(stdout)`: the offset of the standard output (after writing out
/// pending output), or -1 if it is not seekable.
fn stdout_tell() -> i64 {
    #[cfg(unix)]
    {
        use std::os::fd::AsFd;
        cstd::flush_stdout();
        if let Ok(fd) = std::io::stdout().as_fd().try_clone_to_owned() {
            if let Ok(p) = File::from(fd).stream_position() {
                return p as i64;
            }
        }
        -1
    }
    #[cfg(not(unix))]
    {
        -1
    }
}

// ===========================================================================
// Library state of wfdbio.c

/// A component of the WFDB path.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct PathComponent {
    pub prefix: Vec<u8>,
    pub ptype: i32,
}

/// The state of `wfdbio.c` (part of [`Wfdb`]).
#[derive(Debug)]
pub struct IoState {
    wfdbpath: Option<Vec<u8>>,
    wfdbpath_init: Option<Vec<u8>>,
    path_list: Vec<PathComponent>,
    error_print: bool,
    error_flag: bool,
    error_message: Vec<u8>,
    /// Name of the file most recently opened by `wfdb_open`.
    filename: Vec<u8>,
    /// Current record name (for `%r` in the WFDB path).
    irec: Vec<u8>,
    mem_behavior: i32,
    /// wfdb-x: the directory in which `wfdb_open` creates output files
    /// (`None`: files are created as named; see `wfdbx_set_output_dir`).
    output_dir: Option<Vec<u8>>,
    /// wfdb-x: the value of `WFDBX_OUTPUT_DIR` (read on first use).
    env_output_dir: Option<Vec<u8>>,
    output_dir_init: bool,
    /// WFDB-x (normal mode): the directory under which relative names are
    /// read (`None`: the current directory; see `wfdbx_set_input_dir`).
    input_dir: Option<Vec<u8>>,
    /// wfdb-x: the value of `WFDBX_INPUT_DIR` (read on first use).
    env_input_dir: Option<Vec<u8>>,
    input_dir_init: bool,
    /// WFDB-x (normal mode): the input directory set by the last
    /// `setwfdb`, for `resetwfdb`, and whether `setwfdb` was called.
    setwfdb_input_dir: Option<Vec<u8>>,
    setwfdb_called: bool,
    /// wfdb-x: network access allowed (`None` until first needed: then
    /// from `WFDBX_NETWORK`, whose value is `env_network`).
    network: Option<bool>,
    env_network: bool,
}

impl Default for IoState {
    fn default() -> Self {
        IoState {
            wfdbpath: None,
            wfdbpath_init: None,
            path_list: Vec::new(),
            error_print: true,
            error_flag: false,
            error_message: Vec::new(),
            filename: Vec::new(),
            irec: Vec::new(),
            mem_behavior: 1,
            output_dir: None,
            env_output_dir: None,
            output_dir_init: false,
            input_dir: None,
            env_input_dir: None,
            input_dir_init: false,
            setwfdb_input_dir: None,
            setwfdb_called: false,
            network: None,
            env_network: false,
        }
    }
}

/// `record.type`, or `record` if the type is empty (C `spr1`).
fn spr1(record: &[u8], ftype: &[u8]) -> Vec<u8> {
    let mut v = record.to_vec();
    if !ftype.is_empty() {
        v.push(b'.');
        v.extend_from_slice(ftype);
    }
    v
}

/// wfdb-x: whether `s` is an absolute local path: on POSIX systems, one
/// beginning with `/`; on Windows, one beginning with `X:\`, `X:/`, `\\` or
/// `/`.
pub(crate) fn is_absolute_path(s: &[u8]) -> bool {
    if cfg!(windows)
        && ((s.len() >= 3
            && s[0].is_ascii_alphabetic()
            && s[1] == b':'
            && (s[2] == b'\\' || s[2] == b'/'))
            || s.starts_with(b"\\\\"))
    {
        return true;
    }
    s.first() == Some(&b'/')
}

// ---------------------------------------------------------------------------
// wfdb-x: names, directories and remote files (normal mode)

/// wfdb-x: the identity of a file: device and inode numbers on POSIX
/// systems; elsewhere (the standard library has no file IDs there), the
/// canonical absolute path, compared case-insensitively.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct FileId(#[cfg(unix)] u64, #[cfg(unix)] u64, #[cfg(not(unix))] String);

/// The identity of the existing file `path` (`None` if it does not exist).
pub(crate) fn path_id(path: &[u8]) -> Option<FileId> {
    let p = cstd::bytes_to_path(path);
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        std::fs::metadata(p).ok().map(|m| FileId(m.dev(), m.ino()))
    }
    #[cfg(not(unix))]
    {
        std::fs::canonicalize(p)
            .ok()
            .map(|c| FileId(c.to_string_lossy().to_lowercase()))
    }
}

/// `record` with a final `/` expanded by another copy of the final element
/// (`"abc/123/"` becomes `"abc/123/123"`).
fn expand_record(record: &[u8]) -> Vec<u8> {
    let mut r = record.to_vec();
    let rlen = r.len();
    if rlen > 1 && r[rlen - 1] == b'/' {
        let p = rlen - 1;
        let mut q = p - 1;
        while q > 0 {
            if record[q] == b'/' {
                q += 1;
                break;
            }
            q -= 1;
        }
        if q < p {
            r.extend_from_slice(&record[q..p]);
        }
    }
    r
}

/// Messages printed at most once per process.
static WFDB_WARNED: AtomicBool = AtomicBool::new(false);
static NETWORK_WARNED: AtomicBool = AtomicBool::new(false);
static CURL_WARNED: AtomicBool = AtomicBool::new(false);

/// The remote files fetched by this process, by URL (`None`: the fetch
/// failed), so that each URL is requested at most once.
static FETCHED: OnceLock<Mutex<FetchCache>> = OnceLock::new();

/// Contents (or `None`: failure) of the fetched URLs.
type FetchCache = HashMap<Vec<u8>, Option<Vec<u8>>>;

const OUTPUT_URL_ERROR: &[u8] =
    b"wfdbx_set_output_dir: the output directory must be a local directory\n";

/// Whether `s` is an `http://` or `https://` URL.
pub(crate) fn is_url(s: &[u8]) -> bool {
    s.starts_with(b"http://") || s.starts_with(b"https://")
}

/// Whether `c` is a directory separator (`/`, and on Windows also `\`).
fn is_dsep(c: u8) -> bool {
    c == b'/' || (cfg!(windows) && c == b'\\')
}

/// `dir` + `sep` + `name`, with exactly one separator between them (`/` in
/// a URL).
fn join(dir: &[u8], name: &[u8], sep: u8) -> Vec<u8> {
    let sep = if is_url(dir) { b'/' } else { sep };
    let mut r = dir.to_vec();
    if r.last().is_some_and(|&c| c != sep && !is_dsep(c)) {
        r.push(sep);
    }
    r.extend_from_slice(name);
    r
}

/// Whether a file name found in a header names a file in the header's
/// directory or below it: a relative name that does not begin with `~` and
/// has no `..` component (on Windows, no drive letter either).
pub(crate) fn in_header_dir(name: &[u8]) -> bool {
    if is_absolute_path(name) || is_url(name) || name.first() == Some(&b'~') {
        return false;
    }
    if cfg!(windows) && name.get(1) == Some(&b':') {
        return false;
    }
    !name.split(|&c| is_dsep(c)).any(|c| c == b"..")
}

/// The directory part of the file name or URL `s`, including its final
/// separator (empty if it has none).
pub(crate) fn wfdbx_dirname(s: &[u8]) -> Vec<u8> {
    let n = s.iter().rposition(|&c| is_dsep(c)).map_or(0, |k| k + 1);
    s[..n].to_vec()
}

/// `s` with a leading `~` or `~/` replaced by the home directory (`HOME`,
/// or, if it is not set, that of the user running the process; on Windows,
/// `USERPROFILE`), and, on POSIX systems, `~user` by the home directory of
/// that user (if there is no such user, `s` is unchanged), as Python's
/// `os.path.expanduser` does. (The users' home directories are those of
/// `/etc/passwd`.)
fn expand_home(s: &[u8]) -> Vec<u8> {
    if s.first() != Some(&b'~') {
        return s.to_vec();
    }
    let i = s[1..]
        .iter()
        .position(|&c| is_dsep(c))
        .map_or(s.len(), |k| k + 1);
    let home = if i == 1 {
        if cfg!(windows) {
            cstd::getenv("USERPROFILE")
        } else {
            cstd::getenv("HOME").or_else(|| passwd_home(None))
        }
    } else if cfg!(windows) {
        None
    } else {
        passwd_home(Some(&s[1..i]))
    };
    let Some(mut r) = home else {
        return s.to_vec();
    };
    while r.last().is_some_and(|&c| is_dsep(c)) {
        r.pop();
    }
    r.extend_from_slice(&s[i..]);
    if r.is_empty() {
        r.push(b'/');
    }
    r
}

/// The home directory of `user` (or of the user running the process) in
/// `/etc/passwd`.
fn passwd_home(user: Option<&[u8]>) -> Option<Vec<u8>> {
    let uid = match user {
        Some(_) => None,
        None => Some(current_uid()?.to_string().into_bytes()),
    };
    let data = std::fs::read("/etc/passwd").ok()?;
    data.split(|&c| c == b'\n').find_map(|line| {
        let f: Vec<&[u8]> = line.split(|&c| c == b':').collect();
        let found = match (user, &uid) {
            (Some(u), _) => f[0] == u,
            (None, Some(id)) => f.get(2) == Some(&&id[..]),
            _ => false,
        };
        if found && f.len() >= 7 {
            Some(f[5].to_vec())
        } else {
            None
        }
    })
}

/// The user id of this process (that of the owner of `/proc/self`).
fn current_uid() -> Option<u32> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        std::fs::metadata("/proc/self").ok().map(|m| m.uid())
    }
    #[cfg(not(unix))]
    {
        None
    }
}

/// The next component of the WFDB path string `s`, from position `q`
/// (after any whitespace): returns its start, its end (the position of the
/// character that follows it) and its type ([`WFDB_LOCAL`] or
/// [`WFDB_NET`]). (wfdb-x: formerly in the body of `wfdb_parse_path`; also
/// used by `setwfdb` in normal mode.)
fn path_component(s: &[u8], mut q: usize) -> (usize, usize, i32) {
    let n = s.len();
    while q < n && matches!(s[q], b' ' | b'\t' | b'\n' | b'\r') {
        q += 1;
    }
    let start = q;
    let mut ptype = WFDB_LOCAL;
    let mut slashes = 0;
    loop {
        let c = if q < n { s[q] } else { 0 };
        if c == b':' {
            if s[q + 1..].starts_with(b"//") {
                ptype = WFDB_NET;
            } else if ptype != WFDB_NET || slashes > 2 {
                // ':' ends a component, except in the host part of a URL
                // (before the third '/': "host:port")
                break;
            }
        } else if matches!(c, b';' | b' ' | b'\t' | b'\n' | b'\r' | 0) {
            break;
        } else if c == b'/' {
            slashes += 1;
        }
        q += 1;
    }
    (start, q, ptype)
}

/// Runs `curl --silent --fail --location --connect-timeout 30 --speed-limit 1
/// --speed-time 30 URL` (without a shell: it gives up if connecting takes 30
/// seconds or no data arrives for 30 seconds, with no limit on the total
/// time, since record files can be large) and returns its standard output, or `Err(true)` if curl could not
/// be started, `Err(false)` if it failed.
fn run_curl(url: &[u8]) -> Result<Vec<u8>, bool> {
    let out = std::process::Command::new("curl")
        .args(["--silent", "--fail", "--location"])
        .args([
            "--connect-timeout",
            "30",
            "--speed-limit",
            "1",
            "--speed-time",
            "30",
        ])
        .arg(cstd::bytes_to_os(url))
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output();
    match out {
        Err(_) => Err(true),
        Ok(o) => match o.status.code() {
            Some(0) => Ok(o.stdout),
            Some(127) => Err(true), // the shell's code for "command not found"
            _ => Err(false),
        },
    }
}

/// `record.typ`, the type truncated to 3 characters (C `"%s.%.3s"`, the
/// MS-DOS form of the file name).
fn spr2(record: &[u8], ftype: &[u8]) -> Vec<u8> {
    let mut v = record.to_vec();
    v.push(b'.');
    v.extend_from_slice(&ftype[..ftype.len().min(3)]);
    v
}

/// The file attached to the standard input by [`freopen_stdin`].
static STDIN_REPLACEMENT: std::sync::Mutex<Option<File>> = std::sync::Mutex::new(None);

/// C `freopen(name, "rb", stdin)`: attach the file `name` to the standard
/// input, so that later readers of the standard input ([`WfdbFile::stdin`],
/// `wfdb_open` of `"-"`) read it from its beginning. Bytes of the previous
/// standard input that were buffered but not consumed are discarded.
/// Returns false (and leaves the standard input unchanged) if the file
/// cannot be opened.
///
/// Part of WFDB-x; not in the original WFDB package.
pub fn freopen_stdin(name: &[u8]) -> bool {
    match File::open(cstd::bytes_to_path(name)) {
        Ok(f) => {
            *STDIN_REPLACEMENT
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(f);
            cstd::STDIN_PUSHBACK
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .clear();
            true
        }
        Err(_) => false,
    }
}

fn is_directory(name: &[u8]) -> bool {
    std::fs::metadata(cstd::bytes_to_path(name)).is_ok_and(|m| m.is_dir())
}

fn contains(hay: &[u8], needle: &[u8]) -> bool {
    hay.windows(needle.len()).any(|w| w == needle)
}

fn mkdir(d: &[u8]) -> bool {
    let mut b = std::fs::DirBuilder::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        b.mode(0o755);
    }
    b.create(cstd::bytes_to_path(d)).is_ok()
}

/// `wfdb_fopen(fname, mode)` on the default instance (see
/// [`Wfdb::wfdb_fopen`]).
///
/// Translation of the C function wfdb_fopen() (lib/wfdbio.c, WFDB 10.7.0):
/// same arguments and results. Differences: a URL is read only if network
/// access is on, and names containing ".." are accepted; see
/// docs/DIVERGENCES.md.
pub fn wfdb_fopen(fname: &[u8], mode: &[u8]) -> Option<WfdbFile> {
    with_default(|w| w.wfdb_fopen(fname, mode))
}

/// The local part of `wfdb_fopen`: a directory cannot be opened for
/// reading; when a file cannot be created (`"wb"` or `"ab"`), the missing
/// directories in its path are created and the file is opened again. With
/// `legacy`, as in the C library (built without network support), names
/// containing `..` or `://` are rejected.
pub(crate) fn local_fopen(fname: &[u8], mode: &[u8], legacy: bool) -> Option<WfdbFile> {
    let fname = cstd::cstr(fname);
    if legacy && (contains(fname, b"..") || contains(fname, b"://")) {
        return None;
    }
    if mode.first() == Some(&b'r') && is_directory(fname) {
        return None;
    }
    let out = mode.first() != Some(&b'r'); // wfdb-x: see wfdbx_write_errors
    if let Some(mut f) = WfdbFile::fopen(fname, mode) {
        f.out = out;
        return Some(f);
    }
    if mode == b"wb" || mode == b"ab" {
        // Try to create any missing directories in the path.
        let mut ok = false;
        let mut tried = false;
        for (i, &c) in fname.iter().enumerate() {
            if c == b'/' {
                tried = true;
                ok = mkdir(&fname[..i]);
            }
        }
        if tried && ok {
            let mut f = WfdbFile::fopen(fname, mode)?;
            f.out = out;
            return Some(f);
        }
    }
    None
}

// wfdb-x: write errors. Decided by Reza Sameni, Oct 2026: a program must not
// report success when its output was not written.
static WRITE_ERRORS: AtomicI32 = AtomicI32::new(0);

/// The number of write errors since the program started: the output files
/// that the library could not write, flush or close (found when they are
/// closed, as by `wfdbquit`), and the errors reported with
/// [`wfdbx_note_write_error`]. The count is process-wide.
///
/// The high-level writers return an error when they meet one, and the
/// command-line tools then exit with status 1.
///
/// # Examples
///
/// ```
/// let before = wfdbx::wfdbx_write_errors();
/// wfdbx::wfdbx_note_write_error();
/// assert!(wfdbx::wfdbx_write_errors() > before);
/// ```
///
/// Part of WFDB-x; not in the original WFDB package.
pub fn wfdbx_write_errors() -> i32 {
    WRITE_ERRORS.load(Ordering::Relaxed)
}

/// Count a write error (see [`wfdbx_write_errors`]): for an application
/// that writes a file itself.
///
/// Part of WFDB-x; not in the original WFDB package.
pub fn wfdbx_note_write_error() {
    WRITE_ERRORS.fetch_add(1, Ordering::Relaxed);
}

/// `wfdbx_fclose_output(fp, pname, name)` on the default instance (see
/// [`Wfdb::wfdbx_fclose_output`]).
///
/// Part of WFDB-x; not in the original WFDB package.
pub fn wfdbx_fclose_output(fp: WfdbFile, pname: &[u8], name: &[u8]) -> i32 {
    with_default(|w| w.wfdbx_fclose_output(fp, pname, name))
}

/// `wfdb_striphea(record)`: the record name without a trailing `.hea`.
///
/// Translation of the C function wfdb_striphea() (lib/wfdbio.c, WFDB 10.7.0):
/// same arguments and results.
pub fn wfdb_striphea(record: &[u8]) -> Vec<u8> {
    let r = cstd::cstr(record);
    if r.len() > 4 && r.ends_with(b".hea") {
        r[..r.len() - 4].to_vec()
    } else {
        r.to_vec()
    }
}

/// Run `sortann --legacy -r. RECORD -a ANNOTATOR` to sort an annotation
/// file (used by `oannclose` in legacy mode; wfdb-x: the program is run
/// without a shell, with the arguments passed directly, with `--legacy` so
/// that it behaves as the original, and in the output directory `dir`, if
/// one is set, where the file was written). The program is looked for in
/// the directory of the running executable, then in the `PATH`. The
/// standard output and error are flushed first. Returns the exit status
/// (-1 if it could not be run).
///
/// Part of WFDB-x; not in the original WFDB package.
pub fn run_sortann(record: &[u8], annotator: &[u8], dir: Option<&[u8]>) -> i32 {
    let mut prog = std::path::PathBuf::from("sortann");
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let name = if cfg!(windows) {
                "sortann.exe"
            } else {
                "sortann"
            };
            let cand = dir.join(name);
            if cand.exists() {
                prog = cand;
            }
        }
    }
    cstd::flush_stdout();
    let _ = std::io::stderr().flush();
    let mut cmd = std::process::Command::new(prog);
    if let Some(d) = dir {
        cmd.current_dir(cstd::bytes_to_os(d)); // wfdb-x: the output directory
    }
    match cmd
        .arg("--legacy") // wfdb-x: the child behaves as the original
        .arg("-r.")
        .arg(cstd::bytes_to_os(record))
        .arg("-a")
        .arg(cstd::bytes_to_os(annotator))
        .status()
    {
        Ok(s) => s.code().unwrap_or(-1),
        Err(_) => -1,
    }
}

/// The version of the WFDB library implemented (`"10.7.0"`).
///
/// Translation of the C function wfdbversion() (lib/wfdbio.c, WFDB 10.7.0):
/// same arguments and results.
pub fn wfdbversion() -> Vec<u8> {
    b"10.7.0".to_vec()
}

/// C `wfdbldflags`: the linker flags needed to build WFDB applications
/// (none: `""`; in C, this depends on how the library was built).
///
/// Translation of the C function wfdbldflags() (lib/wfdbio.c, WFDB 10.7.0):
/// same arguments and results. Differences: the result is always empty; see
/// docs/KNOWN_C_BEHAVIORS.md.
pub fn wfdbldflags() -> Vec<u8> {
    Vec::new()
}

/// C `wfdbcflags`: the compiler flags needed to build WFDB applications
/// (none: `""`).
///
/// Translation of the C function wfdbcflags() (lib/wfdbio.c, WFDB 10.7.0):
/// same arguments and results. Differences: the result is always empty; see
/// docs/KNOWN_C_BEHAVIORS.md.
pub fn wfdbcflags() -> Vec<u8> {
    Vec::new()
}

/// C `wfdbdefwfdb`: the default WFDB path ([`DEFWFDB`]).
///
/// Translation of the C function wfdbdefwfdb() (lib/wfdbio.c, WFDB 10.7.0):
/// same arguments and results.
pub fn wfdbdefwfdb() -> Vec<u8> {
    DEFWFDB.to_vec()
}

/// C `wfdbdefwfdbcal`: the default calibration file name (`"wfdbcal"`).
///
/// Translation of the C function wfdbdefwfdbcal() (lib/wfdbio.c, WFDB 10.7.0):
/// same arguments and results.
pub fn wfdbdefwfdbcal() -> Vec<u8> {
    DEFWFDBCAL.to_vec()
}

fn export_config(p: &[u8]) {
    cstd::setenv("WFDB", p, true);
    cstd::setenv("WFDBCAL", DEFWFDBCAL, false);
    cstd::setenv("WFDBANNSORT", b"1", false);
    cstd::setenv("WFDBGVMODE", b"0", false);
}

impl Wfdb {
    /// If `p` begins with `@`, read the WFDB path from the named file
    /// (`wfdb_getiwfdb`).
    fn getiwfdb(&mut self, mut p: Vec<u8>) -> Vec<u8> {
        const MAXINDIRECT: i32 = 10; // levels of '@file' indirection followed
        let mut i = 0;
        while i < MAXINDIRECT && p.first() == Some(&b'@') {
            match std::fs::read(cstd::bytes_to_path(&p[1..])) {
                Err(_) => p.clear(),
                Ok(mut data) => {
                    while matches!(data.last(), Some(b'\r' | b'\n')) {
                        data.pop();
                    }
                    p = data;
                }
            }
            i += 1;
        }
        if p.first() == Some(&b'@') {
            self.wfdb_error("getwfdb: files nested too deeply\n");
            p.clear();
        }
        p
    }

    /// C `getwfdb()`: wfdb-x: in normal mode, the input directory (see
    /// [`Wfdb::wfdbx_set_input_dir`]), or `"."` if none is set. In legacy
    /// mode, the WFDB path (initialized from the `WFDB` environment
    /// variable, or [`DEFWFDB`], on first use).
    ///
    /// Translation of the C function getwfdb() (lib/wfdbio.c, WFDB 10.7.0):
    /// same arguments and results. Differences: it returns the input directory
    /// (the WFDB path in legacy mode); see docs/DIVERGENCES.md.
    pub fn getwfdb(&mut self) -> Vec<u8> {
        if self.wfdbx_get_legacy() == 0 {
            self.init_input_dir();
            return self.io.input_dir.clone().unwrap_or_else(|| b".".to_vec());
        }
        if self.io.wfdbpath.is_none() {
            let p = cstd::getenv("WFDB").unwrap_or_else(|| DEFWFDB.to_vec());
            let path = self.getiwfdb(p);
            self.io.wfdbpath = Some(path.clone());
            self.io.wfdbpath_init = Some(path.clone());
            self.wfdb_parse_path(Some(&path));
        }
        self.io.wfdbpath.clone().unwrap_or_default()
    }

    /// C `setwfdb(path)`: wfdb-x: in normal mode, `path`, split into
    /// components as the WFDB path is (at spaces, `;`, and `:` outside
    /// URLs), must contain at most one non-empty component, which becomes
    /// the input directory (none, e.g. `""` or `";"`: the default; see
    /// [`Wfdb::wfdbx_set_input_dir`]); with more, it reports `setwfdb:
    /// wfdb-x reads from a single input directory; ...` and changes
    /// nothing. Nothing is exported to the environment.
    ///
    /// In legacy mode, as in C: set the WFDB path (`NULL`: from the
    /// environment or the default), and export `WFDB` (and defaults of
    /// `WFDBCAL`, `WFDBANNSORT`, `WFDBGVMODE`) to the environment.
    ///
    /// Translation of the C function setwfdb() (lib/wfdbio.c, WFDB 10.7.0):
    /// same arguments and results. Differences: it sets a single input
    /// directory (the WFDB path in legacy mode); see docs/DIVERGENCES.md.
    pub fn setwfdb(&mut self, p: impl OptBytes) {
        if self.wfdbx_get_legacy() == 0 {
            self.setwfdb_normal(p.opt_bytes().map(cstd::cstr));
            return;
        }
        let value = match p.opt_bytes() {
            Some(b) => cstd::cstr(b).to_vec(),
            None => cstd::getenv("WFDB").unwrap_or_else(|| DEFWFDB.to_vec()),
        };
        export_config(&value);
        let path = self.getiwfdb(value);
        self.io.wfdbpath = Some(path.clone());
        self.wfdb_parse_path(Some(&path));
    }

    /// C `resetwfdb()`: wfdb-x: in normal mode, restore the input directory
    /// set by the last `setwfdb`, if any (`wfdbquit` does not call it in
    /// normal mode). In legacy mode, restore the WFDB path to its initial
    /// value (only if `getwfdb` was called before any `setwfdb`).
    ///
    /// Translation of the C function resetwfdb() (lib/wfdbio.c, WFDB 10.7.0):
    /// same arguments and results. Differences: it restores the input
    /// directory set by the last setwfdb() (the WFDB path in legacy mode); see
    /// docs/DIVERGENCES.md.
    pub fn resetwfdb(&mut self) {
        if self.wfdbx_get_legacy() == 0 {
            if self.io.setwfdb_called {
                let d = self.io.setwfdb_input_dir.clone();
                self.put_input_dir(d.as_deref());
            }
            return;
        }
        if let Some(init) = &self.io.wfdbpath_init {
            self.io.wfdbpath = Some(init.clone());
        }
    }

    /// C `wfdbquiet()`: suppress error messages.
    ///
    /// Translation of the C function wfdbquiet() (lib/wfdbio.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn wfdbquiet(&mut self) {
        self.io.error_print = false;
    }

    /// wfdb-x: turns the printing of error messages on or off (as
    /// `wfdbverbose` and `wfdbquiet`); returns the previous setting.
    pub(crate) fn wfdbx_set_error_print(&mut self, on: bool) -> bool {
        std::mem::replace(&mut self.io.error_print, on)
    }

    /// C `wfdbverbose()`: print error messages (the default).
    ///
    /// Translation of the C function wfdbverbose() (lib/wfdbio.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn wfdbverbose(&mut self) {
        self.io.error_print = true;
    }

    /// C `wfdberror()`: the most recent error message (or, before any
    /// error, the library version string).
    ///
    /// Translation of the C function wfdberror() (lib/wfdbio.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn wfdberror(&mut self) -> Vec<u8> {
        if !self.io.error_flag {
            self.io.error_message = crate::cformat!(
                b"WFDB library version %d.%d.%d (%s).\n",
                WFDB_MAJOR,
                WFDB_MINOR,
                WFDB_RELEASE,
                WFDB_BUILD_DATE
            );
        }
        self.io.error_message.clone()
    }

    /// C `wfdb_error(format, ...)`, with the message already formatted
    /// (use [`cformat!`](crate::cformat)): record it as the latest error
    /// and print it on the standard error unless `wfdbquiet()` was called.
    ///
    /// ```
    /// # let mut w = wfdbx::Wfdb::new();
    /// # w.wfdbquiet();
    /// w.wfdb_error(wfdbx::cformat!(b"init: can't open header for record %s\n", "100"));
    /// ```
    ///
    /// Translation of the C function wfdb_error() (lib/wfdbio.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn wfdb_error(&mut self, msg: impl AsRef<[u8]>) {
        self.io.error_flag = true;
        self.io.error_message = msg.as_ref().to_vec();
        if self.io.error_print {
            cstd::ewrite(&self.io.error_message);
        }
    }

    /// C `wfdb_error` with a C format and arguments (see also
    /// [`Wfdb::wfdb_error`]).
    ///
    /// Translation of the C function wfdb_error() (lib/wfdbio.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn wfdb_error_fmt(&mut self, fmt: &[u8], args: &[Arg]) {
        let msg = cstd::sprintf(fmt, args);
        self.wfdb_error(msg);
    }

    /// C `wfdbmemerr(behavior)`: whether a memory allocation error is fatal
    /// (nonzero) or not (0).
    ///
    /// Translation of the C function wfdbmemerr() (lib/wfdbio.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn wfdbmemerr(&mut self, behavior: i32) {
        self.io.mem_behavior = behavior;
    }

    /// C `wfdb_me_fatal()`: the behavior set by [`Wfdb::wfdbmemerr`]
    /// (nonzero if memory allocation errors are fatal; 1 by default).
    ///
    /// Translation of the C function wfdb_me_fatal() (lib/wfdbio.c, WFDB
    /// 10.7.0): same arguments and results.
    pub fn wfdb_me_fatal(&self) -> i32 {
        self.io.mem_behavior
    }

    /// Reads `WFDBX_INPUT_DIR` on first use, and (once per process, in
    /// normal mode) warns that `WFDB` is ignored.
    fn init_input_dir(&mut self) {
        if !self.io.input_dir_init {
            self.io.input_dir_init = true;
            if let Some(p) = cstd::getenv("WFDBX_INPUT_DIR").filter(|p| !p.is_empty()) {
                self.io.env_input_dir = Some(p.clone());
                self.io.input_dir = Some(p);
            }
        }
        if self.wfdbx_get_legacy() == 0
            && !WFDB_WARNED.swap(true, Ordering::Relaxed)
            && cstd::getenv("WFDB").is_some_and(|p| !p.is_empty())
        {
            self.wfdb_error(
                "wfdb-x: the WFDB environment variable is ignored; set \
                 WFDBX_INPUT_DIR instead (or use legacy mode)\n",
            );
        }
    }

    /// Replaces the input directory (the default if `dir` is `None` or
    /// empty).
    fn put_input_dir(&mut self, dir: Option<&[u8]>) {
        self.init_input_dir();
        self.io.input_dir = match dir.filter(|d| !d.is_empty()) {
            Some(d) => Some(d.to_vec()),
            None => self.io.env_input_dir.clone(),
        };
    }

    /// `setwfdb` in normal mode: `p` must name at most one input directory.
    fn setwfdb_normal(&mut self, p: Option<&[u8]>) -> i32 {
        let p = p.unwrap_or(b"");
        let mut found: Vec<&[u8]> = Vec::new();
        let mut q = 0;
        while q < p.len() {
            let (start, end, _) = path_component(p, q);
            if end > start {
                found.push(&p[start..end]);
            }
            q = end + 1;
        }
        if found.len() > 1 {
            self.wfdb_error(
                "setwfdb: wfdb-x reads from a single input directory; use \
                 wfdbx_set_input_dir (or legacy mode for the WFDB search path)\n",
            );
            return -1;
        }
        let d = found.first().map(|d| d.to_vec());
        self.put_input_dir(d.as_deref());
        self.io.setwfdb_input_dir = d;
        self.io.setwfdb_called = true;
        0
    }

    /// Sets the input directory, from which files with a relative name are
    /// read: `NAME` is read as `DIR/NAME`.
    ///
    /// `dir` is a local directory, a `~` path or the URL of a directory. A URL
    /// is opened only when network access is on (see
    /// [`Wfdb::wfdbx_set_network`]). `None` or an empty string restores the
    /// default: the value of the environment variable `WFDBX_INPUT_DIR`, or the
    /// current directory if it is not set. Returns the previous setting (`None`
    /// if none was set). Legacy mode does not use this setting.
    ///
    /// # Examples
    ///
    /// Here `/data/mitdb` stands for a local copy of the MIT-BIH Arrhythmia
    /// Database in `/data/mitdb`:
    ///
    /// ```
    /// let mut w = wfdbx::Wfdb::new();
    /// w.wfdbx_set_input_dir("/data/mitdb");   // reads record "100" as /data/mitdb/100
    /// assert_eq!(w.wfdbx_get_input_dir().as_deref(), Some(&b"/data/mitdb"[..]));
    /// ```
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn wfdbx_set_input_dir(&mut self, dir: impl OptBytes) -> Option<Vec<u8>> {
        self.init_input_dir();
        let previous = self.io.input_dir.take();
        self.put_input_dir(dir.opt_bytes().map(cstd::cstr));
        previous
    }

    /// Returns the input directory (see [`Wfdb::wfdbx_set_input_dir`]), or
    /// `None` if none is set.
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn wfdbx_get_input_dir(&mut self) -> Option<Vec<u8>> {
        self.init_input_dir();
        self.io.input_dir.clone()
    }

    /// Reads `WFDBX_OUTPUT_DIR` on first use (a URL is refused).
    fn init_output_dir(&mut self) {
        if self.io.output_dir_init {
            return;
        }
        self.io.output_dir_init = true;
        if let Some(p) = cstd::getenv("WFDBX_OUTPUT_DIR").filter(|p| !p.is_empty()) {
            if is_url(&p) {
                self.wfdb_error(OUTPUT_URL_ERROR);
            } else {
                self.io.env_output_dir = Some(p.clone());
                self.io.output_dir = Some(p);
            }
        }
    }

    /// Sets the output directory, in which files with a relative name are
    /// created: `NAME` is written as `DIR/NAME`.
    ///
    /// `dir` is a local directory or a `~` path. Missing directories are created
    /// when a file is written. `None` or an empty string restores the default:
    /// the value of the environment variable `WFDBX_OUTPUT_DIR`, or the current
    /// directory if it is not set. Returns the previous setting (`None` if none
    /// was set). The setting is kept by `wfdbquit`, and also applies in legacy
    /// mode.
    ///
    /// # Errors
    ///
    /// A URL is refused with the message "wfdbx_set_output_dir: the output
    /// directory must be a local directory". The setting is then unchanged, and
    /// the current value is returned.
    ///
    /// # Examples
    ///
    /// ```
    /// let mut w = wfdbx::Wfdb::new();
    /// w.wfdbx_set_output_dir("out");   // a record "rec" written later goes to out/rec.hea, ...
    /// assert_eq!(w.wfdbx_get_output_dir().as_deref(), Some(&b"out"[..]));
    /// ```
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn wfdbx_set_output_dir(&mut self, dir: impl OptBytes) -> Option<Vec<u8>> {
        self.init_output_dir();
        let dir = dir.opt_bytes().map(cstd::cstr);
        if dir.is_some_and(is_url) {
            self.wfdb_error(OUTPUT_URL_ERROR);
            return self.io.output_dir.clone();
        }
        let new = match dir.filter(|d| !d.is_empty()) {
            Some(d) => Some(d.to_vec()),
            None => self.io.env_output_dir.clone(),
        };
        std::mem::replace(&mut self.io.output_dir, new)
    }

    /// Returns the output directory (see [`Wfdb::wfdbx_set_output_dir`]), or
    /// `None` if none is set.
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn wfdbx_get_output_dir(&mut self) -> Option<Vec<u8>> {
        self.init_output_dir();
        self.io.output_dir.clone()
    }

    /// Turns network access on (`on > 0`) or off (`on == 0`). With network
    /// access on, names that are `http://` or `https://` URLs are read with the
    /// `curl` program.
    ///
    /// A negative `on` restores the default: on if the environment variable
    /// `WFDBX_NETWORK` is a nonzero number, otherwise off. Returns the previous
    /// setting (1: on, 0: off). Legacy mode has no network access.
    ///
    /// # Examples
    ///
    /// ```
    /// let mut w = wfdbx::Wfdb::new();
    /// w.wfdbx_set_network(1);
    /// // The MIT-BIH Arrhythmia Database on PhysioNet:
    /// w.wfdbx_set_input_dir("https://physionet.org/files/mitdb/1.0.0/");
    /// assert_eq!(w.wfdbx_get_network(), 1);
    /// ```
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn wfdbx_set_network(&mut self, on: i32) -> i32 {
        let previous = self.wfdbx_get_network();
        self.io.network = Some(if on < 0 { self.io.env_network } else { on != 0 });
        previous
    }

    /// Returns 1 if network access is on, 0 otherwise (see
    /// [`Wfdb::wfdbx_set_network`]).
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn wfdbx_get_network(&mut self) -> i32 {
        if self.io.network.is_none() {
            self.io.env_network =
                cstd::getenv("WFDBX_NETWORK").is_some_and(|p| cstd::strtol(&p, 10).0 != 0);
            self.io.network = Some(self.io.env_network);
        }
        i32::from(self.io.network == Some(true))
    }

    /// Close `fp`, a file named `name` that an application has written
    /// itself, and return the status of [`WfdbFile::close`]. In normal
    /// mode, if the file could not be written or closed, print `PNAME:
    /// write error on NAME` and count a write error (see
    /// [`wfdbx_write_errors`]); legacy mode prints and counts nothing.
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn wfdbx_fclose_output(&mut self, fp: WfdbFile, pname: &[u8], name: &[u8]) -> i32 {
        let status = fp.close();
        if status != 0 && self.wfdbx_get_legacy() == 0 {
            crate::ceprintf!(b"%s: write error on %s\n", pname, name);
            wfdbx_note_write_error();
        }
        status
    }

    /// wfdb-x: the name of the local file that `wfdb_open(name, NULL,
    /// WFDB_WRITE)` creates in normal mode, or `None` if it creates none
    /// (the standard output, or a URL).
    pub(crate) fn wfdbx_output_file(&mut self, name: &[u8]) -> Option<Vec<u8>> {
        let name = cstd::cstr(name);
        if name.is_empty() || name == b"-" {
            return None;
        }
        let r = expand_record(name);
        if is_url(&r) {
            return None;
        }
        Some(self.resolve(&r, true))
    }

    /// Records `msg` as the latest error (as `wfdb_error` does), without
    /// printing it (wfdb-x: for a message that a high-level function
    /// replaces with its own).
    pub(crate) fn wfdb_error_unprinted(&mut self, msg: impl AsRef<[u8]>) {
        let print = std::mem::replace(&mut self.io.error_print, false);
        self.wfdb_error(msg);
        self.io.error_print = print;
    }

    /// The location of the file `name` in normal mode: an absolute name or
    /// a URL as given, a `~` name expanded, and a relative name under the
    /// input directory (for reading) or the output directory (`output`),
    /// if one is set.
    fn resolve(&mut self, name: &[u8], output: bool) -> Vec<u8> {
        if name.first() == Some(&b'~') {
            return expand_home(name);
        }
        if is_absolute_path(name) || is_url(name) {
            return name.to_vec();
        }
        let dir = if output {
            self.init_output_dir();
            self.io.output_dir.clone()
        } else {
            self.init_input_dir();
            self.io.input_dir.clone()
        };
        match dir {
            None => name.to_vec(),
            Some(d) => join(&expand_home(&d), name, if output { DSEP } else { b'/' }),
        }
    }

    /// The name of the file most recently opened by
    /// [`wfdb_open`](Wfdb::wfdb_open) (C's `wfdb_filename`).
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn wfdb_filename(&self) -> &[u8] {
        &self.io.filename
    }

    /// `wfdb_open(type, record, mode)`: open a WFDB file, named
    /// `RECORD.TYPE` (or `TYPE`, if `record` is empty or `NULL`; `"-"` is
    /// the standard input or output; a record name ending in `/` names the
    /// record of that directory, `"a/b/"` meaning `"a/b/b"`).
    ///
    /// WFDB-x, normal mode: the file is opened at the one location its
    /// name designates; nothing is searched. An absolute name, or a URL
    /// (`http://`, `https://`; read only, and only with network access,
    /// see [`Wfdb::wfdbx_set_network`]), is used as given; a name beginning
    /// with `~` is expanded (the home directory); any other (relative) name
    /// is read under the input directory ([`Wfdb::wfdbx_set_input_dir`])
    /// and written under the output directory
    /// ([`Wfdb::wfdbx_set_output_dir`]), if one is set, otherwise relative
    /// to the current directory. For reading, the type truncated to 3
    /// characters is also tried there.
    ///
    /// Legacy mode, as in C: for input ([`WFDB_READ`]), the file is looked
    /// for in each directory of the WFDB path (with `%r` in a path
    /// component replaced by the current record name, `%Nr` by its first N
    /// characters), then with the type truncated to 3 characters, and the
    /// directory where it was found is added to the path; URLs are not
    /// opened. For output ([`WFDB_WRITE`], [`WFDB_APPEND`]), it is created
    /// in the current directory (or the directory given in the record
    /// name), within the output directory if one is set.
    ///
    /// Translation of the C function wfdb_open() (lib/wfdbio.c, WFDB 10.7.0):
    /// same arguments and results. Differences: a file is opened only where
    /// its name says (under the input or output directory, or as given), never
    /// searched for, and a URL is read only if network access is on; see
    /// docs/DIVERGENCES.md.
    pub fn wfdb_open(
        &mut self,
        s: impl OptBytes,
        record: impl OptBytes,
        mode: i32,
    ) -> Option<WfdbFile> {
        let mut s: &[u8] = s.opt_bytes().map(cstd::cstr).unwrap_or(b"");
        let record = match record.opt_bytes().map(cstd::cstr) {
            Some(r) if !r.is_empty() => r,
            _ => {
                if !s.is_empty() {
                    let r = s;
                    s = b"";
                    r
                } else {
                    return None;
                }
            }
        };
        if record == b"-" {
            return Some(if mode == WFDB_READ {
                WfdbFile::stdin()
            } else {
                let mut f = WfdbFile::stdout();
                f.out = true; // wfdb-x: see wfdbx_write_errors
                f
            });
        }
        // If the record name ends with '/', append the last component of
        // the directory name ("foo/bar/" becomes "foo/bar/bar").
        let r = expand_record(record);

        if mode == WFDB_WRITE || mode == WFDB_APPEND {
            let mut name = spr1(&r, s);
            self.init_output_dir();
            if self.wfdbx_get_legacy() == 0 {
                // wfdb-x: a relative name in the output directory, if one
                // is set; a URL cannot be written
                if is_url(&name) {
                    self.io.filename = name;
                    return None;
                }
                name = self.resolve(&name, true);
            } else if let Some(dir) = &self.io.output_dir {
                // wfdb-x: legacy mode: any name in the output directory
                let mut d = dir.clone();
                d.push(DSEP);
                d.append(&mut name);
                name = d;
            }
            self.io.filename = name.clone();
            let fmode: &[u8] = if mode == WFDB_WRITE { b"wb" } else { b"ab" };
            return self.wfdb_fopen(&name, fmode);
        }

        // wfdb-x: in normal mode, the file is opened at the one location
        // that its name designates (see resolve); nothing is searched.
        if self.wfdbx_get_legacy() == 0 {
            let p = self.resolve(&r, false);
            return self.open_at(&p, s);
        }

        if self.io.path_list.is_empty() {
            self.getwfdb();
        }
        let plist = self.io.path_list.clone();
        for c in &plist {
            // Substitute the record name for %r (or its first N characters
            // for %Nr) in the path component.
            let mut b: Vec<u8> = Vec::new();
            let pr = &c.prefix;
            let n = pr.len();
            let mut i = 0;
            while i < n {
                let ch = pr[i];
                if ch == b'%' {
                    i += 1;
                    let ch = if i < n { pr[i] } else { 0 };
                    if ch == b'r' {
                        b.extend_from_slice(&self.io.irec);
                        i += 1;
                    } else if (b'1'..=b'9').contains(&ch) && i + 1 < n && pr[i + 1] == b'r' {
                        let k = ((ch - b'0') as usize).min(self.io.irec.len());
                        b.extend_from_slice(&self.io.irec[..k]);
                        i += 2;
                    } else {
                        if ch != 0 {
                            b.push(ch);
                        }
                        i += 1;
                    }
                } else {
                    b.push(ch);
                    i += 1;
                }
            }
            if c.ptype == WFDB_NET {
                continue; // remote files: not supported
            }
            if b.last().is_some_and(|&c| c != DSEP) {
                b.push(DSEP);
            }
            b.extend_from_slice(&r);
            self.io.filename = spr1(&b, s);
            if let Some(f) = local_fopen(&self.io.filename, b"rb", true) {
                let name = self.io.filename.clone();
                self.wfdb_addtopath(&name);
                return Some(f);
            }
            let long_filename = std::mem::take(&mut self.io.filename);
            self.io.filename = spr2(&b, s);
            if self.io.filename != long_filename {
                if let Some(f) = local_fopen(&self.io.filename, b"rb", true) {
                    let name = self.io.filename.clone();
                    self.wfdb_addtopath(&name);
                    return Some(f);
                }
            }
        }
        None
    }

    /// wfdb-x: opens the file at location `p` (as resolved, or in the
    /// directory of a header) for reading, trying the two forms of the name
    /// (`P.TYPE`, then `P.TYP`) there.
    fn open_at(&mut self, p: &[u8], s: &[u8]) -> Option<WfdbFile> {
        self.io.filename = spr1(p, s);
        let name = self.io.filename.clone();
        if let Some(f) = self.wfdb_fopen(&name, b"rb") {
            return Some(f);
        }
        let short = spr2(p, s);
        self.io.filename = short.clone();
        if short != name {
            return self.wfdb_fopen(&short, b"rb");
        }
        None
    }

    /// wfdb-x: opens, for reading, a file named in the header of record
    /// `record` (a signal file, or a segment of a multi-segment record, of
    /// type `s`): `name`, in the directory `dir` of that header (as
    /// returned by `wfdbx_dirname`; `None` if unknown, for a header read
    /// from the standard input: then `name` is resolved as any relative
    /// name). `name` must be in that directory or below it (otherwise
    /// `init: file NAME named in the header of record RECORD is not in the
    /// header's directory` is reported); the signal file name `-` (the
    /// standard input) is also accepted.
    ///
    /// Part of WFDB-x; not in the original WFDB package.
    pub fn wfdbx_open_in(
        &mut self,
        dir: Option<&[u8]>,
        s: impl OptBytes,
        name: &[u8],
        record: &[u8],
    ) -> Option<WfdbFile> {
        let name = cstd::cstr(name);
        if name == b"-" {
            return self.wfdb_open(s, name, WFDB_READ);
        }
        if !in_header_dir(name) {
            self.wfdb_error(crate::cformat!(
                b"init: file %s named in the header of record %s is not in the header's directory\n",
                name,
                record
            ));
            return None;
        }
        match dir {
            None => self.wfdb_open(s, name, WFDB_READ),
            Some(d) => {
                let mut p = d.to_vec();
                p.extend_from_slice(name);
                let s = s.opt_bytes().map(cstd::cstr).unwrap_or(b"").to_vec();
                self.open_at(&p, &s)
            }
        }
    }

    /// `wfdb_fopen(fname, mode)`: open a file as the WFDB library does: a
    /// directory cannot be opened for reading; when a file cannot be
    /// created (`"wb"` or `"ab"`), the missing directories in its path are
    /// created and the file is opened again.
    ///
    /// WFDB-x, normal mode: an `http://` or `https://` URL is fetched (read
    /// only; see [`Wfdb::wfdbx_set_network`]), and names containing `..`
    /// are accepted. Legacy mode, as in C (built without network support):
    /// names containing `..` or `://` are rejected.
    ///
    /// Translation of the C function wfdb_fopen() (lib/wfdbio.c, WFDB 10.7.0):
    /// same arguments and results. Differences: a URL is read only if network
    /// access is on, and names containing ".." are accepted; see
    /// docs/DIVERGENCES.md.
    pub fn wfdb_fopen(&mut self, fname: &[u8], mode: &[u8]) -> Option<WfdbFile> {
        let fname = cstd::cstr(fname);
        if self.wfdbx_get_legacy() != 0 {
            return local_fopen(fname, mode, true);
        }
        if is_url(fname) {
            return if mode.first() == Some(&b'r') {
                self.fetch_open(fname)
            } else {
                None
            };
        }
        local_fopen(fname, mode, false)
    }

    /// wfdb-x: opens a URL for reading: if network access is allowed, the
    /// file is read in full by `curl` (once per process: the contents, or
    /// the failure, are kept), and read from memory.
    fn fetch_open(&mut self, url: &[u8]) -> Option<WfdbFile> {
        if self.wfdbx_get_network() == 0 {
            if !NETWORK_WARNED.swap(true, Ordering::Relaxed) {
                self.wfdb_error(crate::cformat!(
                    b"wfdb-x: network access is disabled; set WFDBX_NETWORK=1 or call wfdbx_set_network(1) to open %s\n",
                    url
                ));
            }
            return None;
        }
        let cache = FETCHED.get_or_init(|| Mutex::new(HashMap::new()));
        let cached = cache
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(url)
            .cloned();
        let data = match cached {
            Some(d) => d,
            None => {
                let d = match run_curl(url) {
                    Ok(d) => Some(d),
                    Err(not_found) => {
                        if not_found && !CURL_WARNED.swap(true, Ordering::Relaxed) {
                            self.wfdb_error(
                                "wfdb-x: network access needs the curl program, which was not found\n",
                            );
                        }
                        None
                    }
                };
                cache
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .insert(url.to_vec(), d.clone());
                d
            }
        };
        let mut f = WfdbFile::from_bytes(data?);
        f.remote = true;
        Some(f)
    }

    /// `wfdb_checkname(name, description)`: 0 if `name` contains only
    /// letters, digits, `_`, `~`, `-` and `/`; otherwise prints `init:
    /// illegal character N in DESCRIPTION name` and returns -1.
    ///
    /// wfdb-x: a record name (`description` "record") may be a path;
    /// outside legacy mode only its last component (the record's own name)
    /// is checked, so that directories with other characters (such as
    /// `my.data/rec`) can be written.
    ///
    /// Translation of the C function wfdb_checkname() (lib/wfdbio.c, WFDB
    /// 10.7.0): same arguments and results. Differences: only the last
    /// component of a record name is checked; see docs/DIVERGENCES.md.
    pub fn wfdb_checkname(&mut self, name: &[u8], desc: &[u8]) -> i32 {
        let mut name = cstd::cstr(name);
        if desc == b"record" && self.wfdbx_get_legacy() == 0 {
            name = &name[name.iter().rposition(|&c| c == DSEP).map_or(0, |k| k + 1)..];
        }
        let mut i = 0;
        loop {
            let c = name.get(i).copied().unwrap_or(0);
            if c.is_ascii_alphanumeric() || c == b'_' || c == b'~' || c == b'-' || c == DSEP {
                i += 1;
            } else {
                let msg =
                    crate::cformat!(b"init: illegal character %d in %s name\n", c as i8, desc);
                self.wfdb_error(msg);
                return -1;
            }
            if i >= name.len() {
                return 0;
            }
        }
    }

    /// `wfdb_setirec(record)`: set the current record name (its last path
    /// component, at most [`WFDB_MAXRNL`] bytes), used for `%r` in the
    /// WFDB path. `"-"` is ignored.
    ///
    /// Translation of the C function wfdb_setirec() (lib/wfdbio.c, WFDB
    /// 10.7.0): same arguments and results.
    pub fn wfdb_setirec(&mut self, p: &[u8]) {
        let p = cstd::cstr(p);
        let r = match p.iter().rposition(|&c| c == DSEP) {
            Some(k) => &p[k + 1..],
            None => p,
        };
        if r != b"-" {
            self.io.irec = r[..r.len().min(WFDB_MAXRNL)].to_vec();
        }
    }

    /// `wfdb_getirec()`: the current record name (`None` if not set).
    ///
    /// Translation of the C function wfdb_getirec() (lib/wfdbio.c, WFDB
    /// 10.7.0): same arguments and results.
    pub fn wfdb_getirec(&self) -> Option<Vec<u8>> {
        if self.io.irec.is_empty() {
            None
        } else {
            Some(self.io.irec.clone())
        }
    }

    /// `wfdb_parse_path(path)`: split a WFDB path into its components
    /// (separated by `;`, spaces, tabs or newlines; `:` also separates
    /// local components, but not the `://` of URLs).
    ///
    /// Translation of the C function wfdb_parse_path() (lib/wfdbio.c, WFDB
    /// 10.7.0): same arguments and results. Differences: it is used only in
    /// legacy mode; see docs/DIVERGENCES.md.
    pub fn wfdb_parse_path(&mut self, p: Option<&[u8]>) -> i32 {
        self.io.path_list.clear();
        let Some(s) = p else {
            return 0;
        };
        let s = cstd::cstr(s);
        let n = s.len();
        let mut q = 0;
        while q < n {
            let (start, end, ptype) = path_component(s, q);
            self.io.path_list.push(PathComponent {
                prefix: s[start..end].to_vec(),
                ptype,
            });
            q = end;
            if q < n {
                q += 1;
            }
        }
        0
    }

    /// `wfdb_addtopath(pathname)`: move (or add) the directory of
    /// `pathname` to the front of the WFDB path (after `.`, if `.` is
    /// first), so that other files of the same record are found quickly.
    ///
    /// Translation of the C function wfdb_addtopath() (lib/wfdbio.c, WFDB
    /// 10.7.0): same arguments and results. Differences: it is used only in
    /// legacy mode; see docs/DIVERGENCES.md.
    pub fn wfdb_addtopath(&mut self, s: &[u8]) {
        let s = cstd::cstr(s);
        if s.is_empty() {
            return;
        }
        let is_sep = |c: u8| c == b'/' || c == b'\\' || c == b':';
        let mut p = s.len() as i64 - 1;
        while p >= 0 && !is_sep(s[p as usize]) {
            p -= 1;
        }
        if p == 0 && is_sep(s[0]) {
            p += 1;
        }
        if p < 0 {
            return;
        }
        let p = p as usize;
        if self.io.wfdbpath.is_none() {
            self.getwfdb();
        }
        if self.io.path_list.is_empty() {
            return;
        }
        let plist = &mut self.io.path_list;
        let mut found: Option<PathComponent> = None;
        for idx in 0..plist.len() {
            // strncmp(prefix, s, p) == 0
            let pre = &plist[idx].prefix;
            if pre.len() >= p && pre[..p] == s[..p] {
                if idx == 0 || (idx == 1 && plist[0].prefix == b".") {
                    return; // no changes needed
                }
                found = Some(plist.remove(idx));
                break;
            }
        }
        let c = found.unwrap_or_else(|| {
            let prefix = s[..p].to_vec();
            let ptype = if contains(&prefix, b"://") {
                WFDB_NET
            } else {
                WFDB_LOCAL
            };
            PathComponent { prefix, ptype }
        });
        if plist[0].prefix == b"." {
            plist.insert(1, c);
        } else {
            plist.insert(0, c);
        }
    }

    /// C `wfdbfile(type, record)`: the pathname of a WFDB file (found as
    /// [`wfdb_open`](Wfdb::wfdb_open) finds it), or `None`. With both
    /// arguments `NULL`, the name of the file most recently opened.
    ///
    /// Translation of the C function wfdbfile() (lib/wfdbio.c, WFDB 10.7.0):
    /// same arguments and results. Differences: the file is found as
    /// wfdb_open() finds it, not by a search of the WFDB path; see
    /// docs/DIVERGENCES.md.
    pub fn wfdbfile(&mut self, s: impl OptBytes, record: impl OptBytes) -> Option<Vec<u8>> {
        let s = s.opt_bytes();
        let record = record.opt_bytes();
        if s.is_none() && record.is_none() {
            return Some(self.io.filename.clone());
        }
        let rec = record.map(wfdb_striphea);
        let f = self.wfdb_open(s, rec.as_ref(), WFDB_READ);
        if f.is_some() {
            Some(self.io.filename.clone())
        } else {
            None
        }
    }

    /// C `wfdbversion()`: the version of the WFDB library implemented
    /// (`"10.7.0"`).
    ///
    /// Translation of the C function wfdbversion() (lib/wfdbio.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn wfdbversion(&self) -> Vec<u8> {
        wfdbversion()
    }
}

// ===========================================================================
// Free functions (default instance)

/// C `getwfdb()` on the default instance (see [`Wfdb::getwfdb`]).
///
/// Translation of the C function getwfdb() (lib/wfdbio.c, WFDB 10.7.0): same
/// arguments and results. Differences: it returns the input directory (the
/// WFDB path in legacy mode); see docs/DIVERGENCES.md.
pub fn getwfdb() -> Vec<u8> {
    with_default(super::wfdb::Wfdb::getwfdb)
}

/// C `setwfdb(path)` on the default instance (see [`Wfdb::setwfdb`]).
///
/// Translation of the C function setwfdb() (lib/wfdbio.c, WFDB 10.7.0): same
/// arguments and results. Differences: it sets a single input directory (the
/// WFDB path in legacy mode); see docs/DIVERGENCES.md.
pub fn setwfdb(p: impl OptBytes) {
    with_default(|w| w.setwfdb(p));
}

/// C `resetwfdb()` on the default instance (see [`Wfdb::resetwfdb`]).
///
/// Translation of the C function resetwfdb() (lib/wfdbio.c, WFDB 10.7.0): same
/// arguments and results. Differences: it restores the input directory set by
/// the last setwfdb() (the WFDB path in legacy mode); see docs/DIVERGENCES.md.
pub fn resetwfdb() {
    with_default(super::wfdb::Wfdb::resetwfdb);
}

/// C `wfdbquiet()` on the default instance (see [`Wfdb::wfdbquiet`]).
///
/// Translation of the C function wfdbquiet() (lib/wfdbio.c, WFDB 10.7.0): same
/// arguments and results.
pub fn wfdbquiet() {
    with_default(super::wfdb::Wfdb::wfdbquiet);
}

/// C `wfdbverbose()` on the default instance (see [`Wfdb::wfdbverbose`]).
///
/// Translation of the C function wfdbverbose() (lib/wfdbio.c, WFDB 10.7.0):
/// same arguments and results.
pub fn wfdbverbose() {
    with_default(super::wfdb::Wfdb::wfdbverbose);
}

/// C `wfdberror()` on the default instance (see [`Wfdb::wfdberror`]).
///
/// Translation of the C function wfdberror() (lib/wfdbio.c, WFDB 10.7.0): same
/// arguments and results.
pub fn wfdberror() -> Vec<u8> {
    with_default(super::wfdb::Wfdb::wfdberror)
}

/// C `wfdb_error` (message already formatted) on the default instance.
///
/// Translation of the C function wfdb_error() (lib/wfdbio.c, WFDB 10.7.0): same
/// arguments and results.
pub fn wfdb_error(msg: impl AsRef<[u8]>) {
    with_default(|w| w.wfdb_error(msg));
}

/// C `wfdbmemerr(behavior)` on the default instance (see [`Wfdb::wfdbmemerr`]).
///
/// Translation of the C function wfdbmemerr() (lib/wfdbio.c, WFDB 10.7.0): same
/// arguments and results.
pub fn wfdbmemerr(behavior: i32) {
    with_default(|w| w.wfdbmemerr(behavior));
}

/// C `wfdb_me_fatal()` on the default instance (see [`Wfdb::wfdb_me_fatal`]).
///
/// Translation of the C function wfdb_me_fatal() (lib/wfdbio.c, WFDB 10.7.0):
/// same arguments and results.
pub fn wfdb_me_fatal() -> i32 {
    with_default(|w| w.wfdb_me_fatal())
}

/// C `wfdbfile(type, record)` on the default instance (see [`Wfdb::wfdbfile`]).
///
/// Translation of the C function wfdbfile() (lib/wfdbio.c, WFDB 10.7.0): same
/// arguments and results. Differences: the file is found as wfdb_open() finds
/// it, not by a search of the WFDB path; see docs/DIVERGENCES.md.
pub fn wfdbfile(s: impl OptBytes, record: impl OptBytes) -> Option<Vec<u8>> {
    with_default(|w| w.wfdbfile(s, record))
}

/// Sets the output directory of the default `Wfdb` value of the thread
/// (see [`Wfdb::wfdbx_set_output_dir`]). Returns the previous setting.
///
/// Part of WFDB-x; not in the original WFDB package.
pub fn wfdbx_set_output_dir(dir: impl OptBytes) -> Option<Vec<u8>> {
    with_default(|w| w.wfdbx_set_output_dir(dir))
}

/// Returns the output directory of the default `Wfdb` value of the thread
/// (see [`Wfdb::wfdbx_get_output_dir`]).
///
/// Part of WFDB-x; not in the original WFDB package.
pub fn wfdbx_get_output_dir() -> Option<Vec<u8>> {
    with_default(|w| w.wfdbx_get_output_dir())
}

/// Sets the input directory of the default `Wfdb` value of the thread (see
/// [`Wfdb::wfdbx_set_input_dir`]). Returns the previous setting.
///
/// Part of WFDB-x; not in the original WFDB package.
pub fn wfdbx_set_input_dir(dir: impl OptBytes) -> Option<Vec<u8>> {
    with_default(|w| w.wfdbx_set_input_dir(dir))
}

/// Returns the input directory of the default `Wfdb` value of the thread
/// (see [`Wfdb::wfdbx_get_input_dir`]).
///
/// Part of WFDB-x; not in the original WFDB package.
pub fn wfdbx_get_input_dir() -> Option<Vec<u8>> {
    with_default(|w| w.wfdbx_get_input_dir())
}

/// Turns network access on or off for the default `Wfdb` value of the
/// thread (see [`Wfdb::wfdbx_set_network`]). Returns the previous setting.
///
/// Part of WFDB-x; not in the original WFDB package.
pub fn wfdbx_set_network(on: i32) -> i32 {
    with_default(|w| w.wfdbx_set_network(on))
}

/// Returns 1 if network access is on for the default `Wfdb` value of the
/// thread, 0 otherwise (see [`Wfdb::wfdbx_get_network`]).
///
/// Part of WFDB-x; not in the original WFDB package.
pub fn wfdbx_get_network() -> i32 {
    with_default(|w| w.wfdbx_get_network())
}

/// `wfdb_open(type, record, mode)` on the default instance.
///
/// Translation of the C function wfdb_open() (lib/wfdbio.c, WFDB 10.7.0): same
/// arguments and results. Differences: a file is opened only where its name
/// says (under the input or output directory, or as given), never searched
/// for, and a URL is read only if network access is on; see
/// docs/DIVERGENCES.md.
pub fn wfdb_open(s: impl OptBytes, record: impl OptBytes, mode: i32) -> Option<WfdbFile> {
    with_default(|w| w.wfdb_open(s, record, mode))
}

/// `wfdb_checkname(name, description)` on the default instance.
///
/// Translation of the C function wfdb_checkname() (lib/wfdbio.c, WFDB 10.7.0):
/// same arguments and results. Differences: only the last component of a
/// record name is checked; see docs/DIVERGENCES.md.
pub fn wfdb_checkname(name: &[u8], desc: &[u8]) -> i32 {
    with_default(|w| w.wfdb_checkname(name, desc))
}

/// `wfdb_setirec(record)` on the default instance.
///
/// Translation of the C function wfdb_setirec() (lib/wfdbio.c, WFDB 10.7.0):
/// same arguments and results.
pub fn wfdb_setirec(record: &[u8]) {
    with_default(|w| w.wfdb_setirec(record));
}

/// `wfdb_getirec()` on the default instance.
///
/// Translation of the C function wfdb_getirec() (lib/wfdbio.c, WFDB 10.7.0):
/// same arguments and results.
pub fn wfdb_getirec() -> Option<Vec<u8>> {
    with_default(|w| w.wfdb_getirec())
}

/// `wfdb_parse_path(path)` on the default instance.
///
/// Translation of the C function wfdb_parse_path() (lib/wfdbio.c, WFDB
/// 10.7.0): same arguments and results. Differences: it is used only in legacy
/// mode; see docs/DIVERGENCES.md.
pub fn wfdb_parse_path(p: Option<&[u8]>) -> i32 {
    with_default(|w| w.wfdb_parse_path(p))
}

/// `wfdb_addtopath(pathname)` on the default instance.
///
/// Translation of the C function wfdb_addtopath() (lib/wfdbio.c, WFDB 10.7.0):
/// same arguments and results. Differences: it is used only in legacy mode;
/// see docs/DIVERGENCES.md.
pub fn wfdb_addtopath(s: &[u8]) {
    with_default(|w| w.wfdb_addtopath(s));
}

/// The block size of a file (glibc's stdio buffer size: `st_blksize`).
fn file_blksize(f: &File) -> usize {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if let Ok(m) = f.metadata() {
            let b = m.blksize() as usize;
            if b > 0 {
                return b;
            }
        }
    }
    let _ = f;
    RBUFSIZE
}

#[cfg(test)]
mod tests {
    use super::*;

    fn prefixes(w: &Wfdb) -> Vec<Vec<u8>> {
        w.io.path_list.iter().map(|c| c.prefix.clone()).collect()
    }

    #[test]
    fn parse_path() {
        let mut w = Wfdb::new();
        w.wfdb_parse_path(Some(
            b". /usr/local/database http://physionet.org/physiobank/database",
        ));
        assert_eq!(
            prefixes(&w),
            vec![
                b".".to_vec(),
                b"/usr/local/database".to_vec(),
                b"http://physionet.org/physiobank/database".to_vec()
            ]
        );
        assert_eq!(w.io.path_list[2].ptype, WFDB_NET);
        w.wfdb_parse_path(Some(b"a:b;c\td"));
        assert_eq!(
            prefixes(&w),
            vec![b"a".to_vec(), b"b".to_vec(), b"c".to_vec(), b"d".to_vec()]
        );
        w.wfdb_parse_path(Some(b""));
        assert!(w.io.path_list.is_empty());
    }

    #[test]
    fn addtopath() {
        let mut w = Wfdb::new();
        w.io.wfdbpath = Some(b". a b".to_vec());
        w.wfdb_parse_path(Some(b". a b"));
        w.wfdb_addtopath(b"b/100s.hea");
        assert_eq!(
            prefixes(&w),
            vec![b".".to_vec(), b"b".to_vec(), b"a".to_vec()]
        );
        w.wfdb_addtopath(b"x/y/100s.hea");
        assert_eq!(
            prefixes(&w),
            vec![b".".to_vec(), b"x/y".to_vec(), b"b".to_vec(), b"a".to_vec()]
        );
        w.wfdb_addtopath(b"100s.hea");
        assert_eq!(prefixes(&w).len(), 4);
        w.wfdb_addtopath(b"./100s.hea");
        assert_eq!(prefixes(&w).len(), 4);
    }

    #[test]
    fn striphea_setirec() {
        assert_eq!(wfdb_striphea(b"100s.hea"), b"100s");
        assert_eq!(wfdb_striphea(b".hea"), b".hea");
        let mut w = Wfdb::new();
        assert_eq!(w.wfdb_getirec(), None);
        w.wfdb_setirec(b"a/b/rec");
        assert_eq!(w.wfdb_getirec(), Some(b"rec".to_vec()));
        w.wfdb_setirec(b"-");
        assert_eq!(w.wfdb_getirec(), Some(b"rec".to_vec()));
    }

    #[test]
    fn checkname() {
        let mut w = Wfdb::new();
        w.wfdbquiet();
        assert_eq!(w.wfdb_checkname(b"a-b_c~/9", b"record"), 0);
        assert_eq!(w.wfdb_checkname(b"a.b", b"record"), -1);
        assert_eq!(
            w.wfdberror(),
            b"init: illegal character 46 in record name\n"
        );
        assert_eq!(w.wfdb_checkname(b"", b"record"), -1);
        // wfdb-x: only the last component of a record name is checked
        // (outside legacy mode)
        assert_eq!(w.wfdb_checkname(b"my.data/rec", b"record"), 0);
        assert_eq!(w.wfdb_checkname(b"/a.b/c d/rec", b"record"), 0);
        assert_eq!(w.wfdb_checkname(b"my.data/", b"record"), -1);
        assert_eq!(w.wfdberror(), b"init: illegal character 0 in record name\n");
        assert_eq!(w.wfdb_checkname(b"a:b/rec.1", b"record"), -1);
        assert_eq!(
            w.wfdberror(),
            b"init: illegal character 46 in record name\n"
        );
        assert_eq!(w.wfdb_checkname(b"my.data/a", b"annotator"), -1);
        w.wfdbx_set_legacy(1);
        assert_eq!(w.wfdb_checkname(b"my.data/rec", b"record"), -1);
        assert_eq!(
            w.wfdberror(),
            b"init: illegal character 46 in record name\n"
        );
        assert_eq!(w.wfdb_checkname(b"dir/rec", b"record"), 0);
    }

    #[test]
    fn wfdberror_initial() {
        let mut w = Wfdb::new();
        assert_eq!(
            w.wfdberror(),
            b"WFDB library version 10.7.0 (Jun 10 2022).\n"
        );
    }

    #[test]
    fn percent_r_and_files() {
        let dir = std::env::temp_dir().join(format!("wfdbx-io-{}", std::process::id()));
        let sub = dir.join("rec1");
        std::fs::create_dir_all(&sub).unwrap();
        std::fs::write(sub.join("rec1.hea"), b"rec1 0\n").unwrap();
        std::fs::write(sub.join("rec1.abc"), b"x").unwrap();
        let mut w = Wfdb::new();
        w.wfdbx_set_legacy(1); // (the WFDB path, %r: legacy mode)
        let d = cstd::os_to_bytes(dir.clone().into_os_string());
        let mut path = d.clone();
        path.extend_from_slice(b"/%r");
        w.setwfdb(&path);
        w.wfdb_setirec(b"rec1");
        let f = w.wfdbfile("hea", "rec1").unwrap();
        assert!(f.ends_with(b"rec1/rec1.hea"));
        // Type truncated to 3 characters.
        let f = w.wfdbfile("abcdef", "rec1").unwrap();
        assert!(f.ends_with(b"rec1/rec1.abc"));
        assert!(w.wfdbfile("hea", "nosuch").is_none());
        // ".." is rejected (legacy mode).
        std::fs::write(dir.join("x"), b"").unwrap();
        let mut dotdot = d.clone();
        dotdot.extend_from_slice(b"/rec1/../x");
        assert!(w.wfdb_fopen(&dotdot, b"rb").is_none());
        // Output: missing directories are created.
        let mut out = d.clone();
        out.extend_from_slice(b"/new/dir/file.txt");
        let mut f = w.wfdb_fopen(&out, b"wb").unwrap();
        cfprintf_test(&mut f);
        assert_eq!(f.tell(), 6);
        assert_eq!(f.close(), 0);
        assert_eq!(
            std::fs::read(cstd::bytes_to_path(&out)).unwrap(),
            b"x=42\n\x01"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn cfprintf_test(f: &mut WfdbFile) {
        crate::cfprintf!(f, b"x=%d\n", 42);
        f.putc(1);
    }

    #[test]
    fn memfile() {
        let mut f = WfdbFile::from_bytes(b"ab\ncd\x01\x80\xff\xff".to_vec());
        let mut line = Vec::new();
        assert_eq!(f.getline(&mut line), 3);
        assert_eq!(line, b"ab\n");
        assert_eq!(f.tell(), 3);
        assert_eq!(f.getc(), b'c' as i32);
        assert!(f.fgets(&mut line, 2));
        assert_eq!(line, b"d");
        assert_eq!(f.g16(), -32767);
        assert_eq!(f.seek(-2, SEEK_END), 0);
        assert_eq!(f.g16(), -1);
        assert_eq!(f.getc(), EOF);
        assert!(f.eof());
        assert_eq!(f.getc(), EOF);
        assert_eq!(f.seek(0, SEEK_SET), 0);
        assert!(!f.eof());
        assert_eq!(f.getc(), b'a' as i32);
        assert_eq!(f.ungetc(b'z' as i32), b'z' as i32);
        assert_eq!(f.getc(), b'z' as i32);
    }
}
