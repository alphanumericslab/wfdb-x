//! The process's standard streams and environment, as a C program sees
//! them: a buffered standard output shared by everything that writes to it
//! ([`out`], [`printf`], [`crate::WfdbFile::stdout`]), an unbuffered
//! standard error, `exit` (which flushes), `argv` and environment variables
//! as byte strings.
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It has no counterpart in the original package.
//
// Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

use std::io::{IsTerminal, Write};
use std::sync::{Mutex, MutexGuard};

use super::printf::{sprintf_into, Arg};

/// Size at which the standard output buffer is written out.
const STDOUT_BUFSIZE: usize = 1 << 16;

/// The buffered standard output (see [`out`]).
#[derive(Debug)]
pub struct Stdout {
    buf: Vec<u8>,
    error: bool,
    tty: Option<bool>,
}

static STDOUT: Mutex<Stdout> = Mutex::new(Stdout {
    buf: Vec::new(),
    error: false,
    tty: None,
});

/// Bytes read from the standard input by a [`crate::WfdbFile`] that was
/// closed before they were consumed; the next reader of the standard input
/// gets them first (C's `stdin` is a single shared stream).
pub(crate) static STDIN_PUSHBACK: Mutex<Vec<u8>> = Mutex::new(Vec::new());

/// Exclusive access to the buffered standard output (C's `stdout`).
///
/// Obtained with [`out`]; the lock is held until the value is dropped, so
/// keep it only for the duration of a few writes (and never while calling
/// a function that may itself write to the standard output).
pub struct OutLock(MutexGuard<'static, Stdout>);

/// Lock the buffered standard output.
///
/// All output to the standard output (from [`printf`], [`crate::cprintf!`],
/// and [`crate::WfdbFile`]s opened on `-`) goes through
/// this buffer, which is written out when it is full, by [`flush_stdout`],
/// and by [`exit`]. If the standard output is a terminal, it is written out
/// after each call (C line-buffers it).
pub fn out() -> OutLock {
    OutLock(
        STDOUT
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner),
    )
}

impl OutLock {
    /// Write bytes (C `fwrite(p, 1, n, stdout)`).
    #[inline]
    pub fn write(&mut self, b: &[u8]) {
        self.0.buf.extend_from_slice(b);
        self.after_write();
    }

    /// Write one byte (C `putchar`).
    #[inline]
    pub fn putc(&mut self, c: u8) {
        self.0.buf.push(c);
        if self.0.buf.len() >= STDOUT_BUFSIZE {
            self.flush();
        }
    }

    /// C `printf`: returns the number of bytes written.
    pub fn printf(&mut self, fmt: &[u8], args: &[Arg]) -> i32 {
        let n = sprintf_into(&mut self.0.buf, fmt, args);
        self.after_write();
        n as i32
    }

    #[inline]
    fn after_write(&mut self) {
        if self.0.buf.len() >= STDOUT_BUFSIZE || self.is_tty() {
            self.flush();
        }
    }

    fn is_tty(&mut self) -> bool {
        match self.0.tty {
            Some(t) => t,
            None => {
                let t = std::io::stdout().is_terminal();
                self.0.tty = Some(t);
                t
            }
        }
    }

    /// Write out the buffer (C `fflush(stdout)`): returns 0, or -1 (`EOF`)
    /// on a write error.
    ///
    /// If the reader of a pipe has gone away (`EPIPE`), the process exits
    /// with status 141, as a C program killed by `SIGPIPE` appears to the
    /// shell.
    ///
    /// wfdb-x: after a write error, the output is discarded (as if the
    /// standard output were the null device), so that later writes and
    /// flushes do nothing; [`error`](OutLock::error) stays true.
    pub fn flush(&mut self) -> i32 {
        if self.0.error {
            self.0.buf.clear();
            return -1;
        }
        if self.0.buf.is_empty() {
            return 0;
        }
        let mut so = std::io::stdout().lock();
        let r = so.write_all(&self.0.buf).and_then(|_| so.flush());
        self.0.buf.clear();
        match r {
            Ok(()) => 0,
            Err(e) => {
                if e.kind() == std::io::ErrorKind::BrokenPipe {
                    // As a C program killed by SIGPIPE (13) would be seen
                    // by the shell: exit status 128 + 13.
                    std::process::exit(128 + 13);
                }
                self.0.error = true;
                -1
            }
        }
    }

    /// C `ferror(stdout)`.
    pub fn error(&self) -> bool {
        self.0.error
    }
}

impl Write for OutLock {
    fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
        OutLock::write(self, b);
        Ok(b.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        if OutLock::flush(self) == 0 {
            Ok(())
        } else {
            Err(std::io::Error::new(
                std::io::ErrorKind::Other,
                "write error on standard output",
            ))
        }
    }
}

/// C `printf` (to the buffered standard output); returns the number of
/// bytes written. See also [`cprintf!`](crate::cprintf).
pub fn printf(fmt: &[u8], args: &[Arg]) -> i32 {
    out().printf(fmt, args)
}

/// C `fflush(stdout)`.
pub fn flush_stdout() -> i32 {
    out().flush()
}

/// Write bytes to the standard error (unbuffered, as C's `stderr`).
pub fn ewrite(b: &[u8]) {
    let mut e = std::io::stderr().lock();
    let _ = e.write_all(b);
}

/// C `fprintf(stderr, ...)`; returns the number of bytes written. See also
/// [`ceprintf!`](crate::ceprintf).
pub fn eprintf(fmt: &[u8], args: &[Arg]) -> i32 {
    let mut v = Vec::with_capacity(fmt.len() + 32);
    let n = sprintf_into(&mut v, fmt, args);
    ewrite(&v);
    n as i32
}

/// The program name for the message of [`exit`] (set by
/// [`exit_check_init`]).
static EXIT_PNAME: Mutex<Option<Vec<u8>>> = Mutex::new(None);

/// wfdb-x: enable the check of write errors at [`exit`] (called by
/// `wfdbx_legacy_args`, as the tools call it first); `argv0` gives the
/// program name of its message. Only the first call counts.
pub(crate) fn exit_check_init(argv0: &[u8]) {
    let mut p = EXIT_PNAME
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if p.is_none() {
        *p = Some(prog_name(argv0).to_vec());
    }
}

/// wfdb-x: the exit status of the tools. In normal mode (of the default
/// instance), the standard output is flushed; if it could not be written,
/// `PROGRAM: write error on standard output` is printed. Then, if `status`
/// is 0 and the standard output or another output file could not be
/// written (see [`crate::wfdbx_write_errors`]), the status is 1. Legacy
/// mode keeps the status.
fn exit_check(status: i32) -> i32 {
    let pname = EXIT_PNAME
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .clone();
    let Some(pname) = pname else {
        return status;
    };
    if crate::wfdb::default_legacy() {
        return status;
    }
    let failed = {
        let mut o = out();
        o.flush();
        o.error()
    };
    if failed {
        eprintf(
            b"%s: write error on standard output\n",
            &[super::printf::ToArg::to_arg(&pname)],
        );
    }
    if status == 0 && (failed || crate::wfdbx_write_errors() > 0) {
        1
    } else {
        status
    }
}

/// C `exit(status)`: flushes the files of the default [`crate::Wfdb`]
/// instance (as C's `exit` flushes every open stream, without closing
/// records or annotators), then the standard output, and exits.
///
/// wfdb-x: after `wfdbx_legacy_args`, in normal mode, a standard output
/// that could not be written is reported (`PROGRAM: write error on
/// standard output`), and the status 0 becomes 1 if the standard output or
/// another output file could not be written (see
/// [`crate::wfdbx_write_errors`]).
///
/// Files opened by the caller itself (outside the library state) are not
/// flushed (Rust does not run destructors at exit): close them first.
pub fn exit(status: i32) -> ! {
    let status = exit_check(status);
    crate::wfdb::release_default_at_exit();
    flush_stdout();
    std::process::exit(status)
}

/// The command-line arguments (`argv`) as byte strings.
pub fn args() -> Vec<Vec<u8>> {
    std::env::args_os().map(os_to_bytes).collect()
}

/// The last component of a program path (`argv[0]`), as the C tools
/// compute their name for messages (everything after the last `/`).
pub fn prog_name(argv0: &[u8]) -> &[u8] {
    match argv0.iter().rposition(|&c| c == b'/') {
        Some(p) => &argv0[p + 1..],
        None => argv0,
    }
}

/// Convert an OS string to bytes (exactly on Unix; lossily elsewhere).
pub fn os_to_bytes(s: std::ffi::OsString) -> Vec<u8> {
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStringExt;
        s.into_vec()
    }
    #[cfg(not(unix))]
    {
        s.to_string_lossy().into_owned().into_bytes()
    }
}

/// Convert bytes to an OS string (exactly on Unix; lossily elsewhere).
pub fn bytes_to_os(b: &[u8]) -> std::ffi::OsString {
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;
        std::ffi::OsStr::from_bytes(b).to_os_string()
    }
    #[cfg(not(unix))]
    {
        String::from_utf8_lossy(b).into_owned().into()
    }
}

/// A file system path from bytes.
pub fn bytes_to_path(b: &[u8]) -> std::path::PathBuf {
    std::path::PathBuf::from(bytes_to_os(b))
}

/// C `getenv(name)`: the value of an environment variable, as bytes.
pub fn getenv(name: &str) -> Option<Vec<u8>> {
    std::env::var_os(name).map(os_to_bytes)
}

/// C `setenv(name, value, overwrite)`.
pub fn setenv(name: &str, value: &[u8], overwrite: bool) {
    if !overwrite && std::env::var_os(name).is_some() {
        return;
    }
    std::env::set_var(name, bytes_to_os(value));
}
