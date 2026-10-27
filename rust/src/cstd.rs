//! C standard library emulation.
//!
//! The WFDB library and tools depend on the exact behavior of a few C
//! library functions on the reference platform (x86-64 Linux, glibc).
//! This module reproduces them:
//!
//! * `printf` formatting, glibc-exact for every `f64` ([`sprintf`],
//!   [`sprintf_into`], and the macros [`cformat!`](crate::cformat),
//!   [`cprintf!`](crate::cprintf), [`ceprintf!`](crate::ceprintf),
//!   [`cfprintf!`](crate::cfprintf));
//! * parsing: [`strtol`], [`strtoul`], [`strtod`], [`atoi`], [`atol`],
//!   [`atof`], [`sscanf`] (and [`csscanf!`](crate::csscanf)), [`Strtok`],
//!   [`fgets_lines`];
//! * glibc's `rand` ([`GlibcRand`], [`srand`], [`rand`]);
//! * integer conversions with C semantics ([`d2i`], [`d2l`]);
//! * the standard streams and the environment: the buffered standard
//!   output [`out`], [`printf`], [`eprintf`], [`exit`], [`args`],
//!   [`getenv`], [`setenv`].
//!
//! Strings are byte strings (`&[u8]`): WFDB files are not UTF-8.
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

mod float;
mod parse;
mod printf;
mod rand;
mod stdio;

pub use float::fixed_fast;
#[doc(hidden)]
pub use float::{fast_digits_exp, fast_digits_fixed, slow_digits_exp, slow_digits_fixed};
pub use parse::{
    atof, atoi, atol, fgets_lines, isspace, sscanf, strtod, strtof, strtol, strtoll, strtoul,
    FgetsLines, ScanArg, Strtok,
};
pub use printf::{d2i, d2l, sprintf, sprintf_into, Arg, ToArg};
pub use rand::{rand, srand, GlibcRand, RAND_MAX};
pub(crate) use stdio::STDIN_PUSHBACK;
pub use stdio::{
    args, bytes_to_os, bytes_to_path, eprintf, ewrite, exit, flush_stdout, getenv, os_to_bytes,
    out, printf, prog_name, setenv, OutLock, Stdout,
};

/// C's `EOF`.
pub const EOF: i32 = -1;
/// C's `INT_MAX`.
pub const INT_MAX: i32 = i32::MAX;
/// C's `INT_MIN`.
pub const INT_MIN: i32 = i32::MIN;
/// C's `LONG_MAX` (64-bit `long`).
pub const LONG_MAX: i64 = i64::MAX;
/// C's `LONG_MIN`.
pub const LONG_MIN: i64 = i64::MIN;
/// `fseek` origin: start of file.
pub const SEEK_SET: i32 = 0;
/// `fseek` origin: current position.
pub const SEEK_CUR: i32 = 1;
/// `fseek` origin: end of file.
pub const SEEK_END: i32 = 2;

/// C integer division of `long`s (truncation toward zero; Rust's `/` does
/// the same, but this documents intent and wraps on `MIN / -1`).
#[inline]
pub fn cdiv(a: i64, b: i64) -> i64 {
    a.wrapping_div(b)
}

/// C remainder (the sign follows the dividend; same as Rust's `%`).
#[inline]
pub fn cmod(a: i64, b: i64) -> i64 {
    a.wrapping_rem(b)
}

/// The C string held in `s`: the bytes before the first NUL (all of `s` if
/// there is none).
#[inline]
pub fn cstr(s: &[u8]) -> &[u8] {
    match s.iter().position(|&c| c == 0) {
        Some(z) => &s[..z],
        None => s,
    }
}

/// Format a C format string with arguments, as glibc's `sprintf`, giving a
/// `Vec<u8>`.
///
/// ```
/// use wfdbx::cformat;
/// assert_eq!(cformat!(b"%5d|%-4s|%.3f", 42, "ab", 2.0005), b"   42|ab  |2.001");
/// ```
///
/// Each argument is converted with [`ToArg`]: integers, floats, byte
/// strings, `&str`, `Option<Vec<u8>>` (`None` is `NULL`), ...
#[macro_export]
macro_rules! cformat {
    ($fmt:expr $(, $a:expr)* $(,)?) => {
        $crate::cstd::sprintf($fmt, &[$($crate::cstd::ToArg::to_arg(&$a)),*])
    };
}

/// C `printf` to the buffered standard output ([`out`]); evaluates to the
/// number of bytes written (`i32`).
#[macro_export]
macro_rules! cprintf {
    ($fmt:expr $(, $a:expr)* $(,)?) => {
        $crate::cstd::printf($fmt, &[$($crate::cstd::ToArg::to_arg(&$a)),*])
    };
}

/// C `fprintf(stderr, ...)`; evaluates to the number of bytes written.
#[macro_export]
macro_rules! ceprintf {
    ($fmt:expr $(, $a:expr)* $(,)?) => {
        $crate::cstd::eprintf($fmt, &[$($crate::cstd::ToArg::to_arg(&$a)),*])
    };
}

/// C `fprintf(fp, ...)` on anything with a
/// `printf(&mut self, &[u8], &[Arg]) -> i32` method (a
/// [`WfdbFile`](crate::WfdbFile), an [`OutLock`]).
#[macro_export]
macro_rules! cfprintf {
    ($f:expr, $fmt:expr $(, $a:expr)* $(,)?) => {
        $f.printf($fmt, &[$($crate::cstd::ToArg::to_arg(&$a)),*])
    };
}

/// C `sscanf(input, fmt, &a, &b, ...)`: each destination is a `&mut`
/// reference (`&mut i32`, `&mut f64`, `&mut Vec<u8>`, ...; see
/// [`ScanArg`]). Evaluates to the C return value.
///
/// ```
/// use wfdbx::csscanf;
/// let (mut d, mut m, mut y) = (0i32, 0i32, 0i32);
/// assert_eq!(csscanf!(b"01.02.85", b"%d%*c%d%*c%d", &mut d, &mut m, &mut y), 3);
/// assert_eq!((d, m, y), (1, 2, 85));
/// ```
#[macro_export]
macro_rules! csscanf {
    ($input:expr, $fmt:expr $(, $a:expr)* $(,)?) => {
        $crate::cstd::sscanf($input, $fmt, &mut [$($crate::cstd::ScanArg::from($a)),*])
    };
}
