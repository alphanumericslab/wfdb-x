//! glibc-exact `printf` formatting.
//!
//! [`sprintf`] formats a C format string (a byte string) with a slice of
//! [`Arg`] values, producing exactly the bytes glibc's `printf` produces on
//! x86-64 Linux. Supported: the conversions `d i u x X o c s e E f F g G %`,
//! the flags `- + space # 0`, field width and precision (also given as `*`),
//! and the length modifiers `hh h l ll L q j z t` (integer arguments are
//! converted to the C type the conversion reads: `int` without a modifier,
//! `short`/`char` with `h`/`hh`, 64 bits with `l`, `ll`, `j`, `z`, `t`).
//!
//! The usual way to call it is through the macros [`cformat!`](crate::cformat),
//! [`cprintf!`](crate::cprintf), [`ceprintf!`](crate::ceprintf) and
//! [`cfprintf!`](crate::cfprintf), which convert each argument with
//! [`ToArg`].
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

use super::float::{digits_exp, digits_exp_carry, digits_fixed};

/// One argument of a `printf`-style call.
///
/// Integer conversions accept `Int` and `Uint` (and `Float`, converted as
/// a C cast would); floating-point conversions accept `Float` (and
/// integers, converted to `f64`); `%s` takes `Str` (`None` is C's `NULL`,
/// printed as `(null)` as glibc does); `%c` takes an integer (or the first
/// byte of a `Str`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Arg<'a> {
    /// A signed integer (any C integer type up to 64 bits).
    Int(i64),
    /// An unsigned integer.
    Uint(u64),
    /// A `double`.
    Float(f64),
    /// A string (`None` is a C `NULL` pointer).
    Str(Option<&'a [u8]>),
}

/// Conversion of a Rust value to a printf [`Arg`].
///
/// Implemented for the integer types, `f32`, `f64`, `bool`, `char`, byte
/// strings (`[u8]`, `[u8; N]`, `Vec<u8>`), `str`, `String`,
/// `Option<Vec<u8>>`, `Option<&[u8]>`, `Option<&str>`, `Option<String>`,
/// and references to any of these.
pub trait ToArg {
    /// The argument for this value.
    fn to_arg(&self) -> Arg<'_>;
}

macro_rules! toarg_int {
    ($($t:ty),*) => {$(
        impl ToArg for $t {
            #[inline]
            fn to_arg(&self) -> Arg<'_> { Arg::Int(*self as i64) }
        }
    )*};
}
macro_rules! toarg_uint {
    ($($t:ty),*) => {$(
        impl ToArg for $t {
            #[inline]
            fn to_arg(&self) -> Arg<'_> { Arg::Uint(*self as u64) }
        }
    )*};
}
toarg_int!(i8, i16, i32, i64, isize);
toarg_uint!(u16, u32, u64, usize);

impl ToArg for u8 {
    #[inline]
    fn to_arg(&self) -> Arg<'_> {
        Arg::Int(*self as i64)
    }
}
impl ToArg for bool {
    #[inline]
    fn to_arg(&self) -> Arg<'_> {
        Arg::Int(*self as i64)
    }
}
impl ToArg for char {
    #[inline]
    fn to_arg(&self) -> Arg<'_> {
        Arg::Int(*self as i64)
    }
}
impl ToArg for f64 {
    #[inline]
    fn to_arg(&self) -> Arg<'_> {
        Arg::Float(*self)
    }
}
impl ToArg for f32 {
    #[inline]
    fn to_arg(&self) -> Arg<'_> {
        Arg::Float(*self as f64)
    }
}
impl ToArg for [u8] {
    #[inline]
    fn to_arg(&self) -> Arg<'_> {
        Arg::Str(Some(self))
    }
}
impl<const N: usize> ToArg for [u8; N] {
    #[inline]
    fn to_arg(&self) -> Arg<'_> {
        Arg::Str(Some(&self[..]))
    }
}
impl ToArg for Vec<u8> {
    #[inline]
    fn to_arg(&self) -> Arg<'_> {
        Arg::Str(Some(self.as_slice()))
    }
}
impl ToArg for str {
    #[inline]
    fn to_arg(&self) -> Arg<'_> {
        Arg::Str(Some(self.as_bytes()))
    }
}
impl ToArg for String {
    #[inline]
    fn to_arg(&self) -> Arg<'_> {
        Arg::Str(Some(self.as_bytes()))
    }
}
impl ToArg for Option<Vec<u8>> {
    #[inline]
    fn to_arg(&self) -> Arg<'_> {
        Arg::Str(self.as_deref())
    }
}
impl ToArg for Option<&[u8]> {
    #[inline]
    fn to_arg(&self) -> Arg<'_> {
        Arg::Str(*self)
    }
}
impl ToArg for Option<&str> {
    #[inline]
    fn to_arg(&self) -> Arg<'_> {
        Arg::Str(self.map(str::as_bytes))
    }
}
impl ToArg for Option<String> {
    #[inline]
    fn to_arg(&self) -> Arg<'_> {
        Arg::Str(self.as_deref().map(str::as_bytes))
    }
}
impl ToArg for Arg<'_> {
    #[inline]
    fn to_arg(&self) -> Arg<'_> {
        *self
    }
}
impl<T: ToArg + ?Sized> ToArg for &T {
    #[inline]
    fn to_arg(&self) -> Arg<'_> {
        (**self).to_arg()
    }
}
impl<T: ToArg + ?Sized> ToArg for &mut T {
    #[inline]
    fn to_arg(&self) -> Arg<'_> {
        (**self).to_arg()
    }
}

/// C conversion of a `double` to a 32-bit `int` on x86 (`cvttsd2si`):
/// truncation toward zero; NaN and out-of-range values give `i32::MIN`.
#[inline]
pub fn d2i(x: f64) -> i32 {
    if x > -2147483649.0 && x < 2147483648.0 {
        x as i32
    } else {
        i32::MIN
    }
}

/// C conversion of a `double` to a 64-bit `long` on x86: truncation
/// toward zero; NaN and out-of-range values give `i64::MIN`.
#[inline]
pub fn d2l(x: f64) -> i64 {
    if (-9223372036854775808.0..9223372036854775808.0).contains(&x) {
        x as i64
    } else {
        i64::MIN
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Len {
    None,
    H,
    HH,
    L, // l, ll, L, q, j, z, t: 64 bits
}

#[derive(Default, Clone, Copy)]
struct Spec {
    left: bool,
    plus: bool,
    space: bool,
    alt: bool,
    zero: bool,
    width: usize,
    prec: Option<usize>,
}

fn arg_i32(a: Option<&Arg>) -> i32 {
    match a {
        Some(Arg::Int(v)) => *v as i32,
        Some(Arg::Uint(v)) => *v as i32,
        Some(Arg::Float(f)) => d2i(*f),
        _ => 0,
    }
}

/// Signed value of an integer argument, as C would read it.
fn arg_signed(a: Option<&Arg>, len: Len) -> i64 {
    let raw = match a {
        Some(Arg::Int(v)) => *v,
        Some(Arg::Uint(v)) => *v as i64,
        Some(Arg::Float(f)) => {
            if len == Len::L {
                d2l(*f)
            } else {
                d2i(*f) as i64
            }
        }
        Some(Arg::Str(Some(s))) => s.first().copied().unwrap_or(0) as i64,
        _ => 0,
    };
    match len {
        Len::None => raw as i32 as i64,
        Len::H => raw as i16 as i64,
        Len::HH => raw as i8 as i64,
        Len::L => raw,
    }
}

fn arg_unsigned(a: Option<&Arg>, len: Len) -> u64 {
    let raw = arg_signed(a, Len::L) as u64;
    let raw = match a {
        Some(Arg::Float(f)) if len != Len::L => d2i(*f) as i64 as u64,
        _ => raw,
    };
    match len {
        Len::None => raw as u32 as u64,
        Len::H => raw as u16 as u64,
        Len::HH => raw as u8 as u64,
        Len::L => raw,
    }
}

fn arg_f64(a: Option<&Arg>) -> f64 {
    match a {
        Some(Arg::Float(f)) => *f,
        Some(Arg::Int(v)) => *v as f64,
        Some(Arg::Uint(v)) => *v as f64,
        _ => 0.0,
    }
}

/// Write `prefix` + `body` into `out`, padded to the field width.
/// `zero_ok`: zero padding is allowed (inserted after the prefix).
#[inline]
fn pad(out: &mut Vec<u8>, sp: &Spec, prefix: &[u8], body: &[u8], zero_ok: bool) {
    let len = prefix.len() + body.len();
    if sp.width <= len {
        out.extend_from_slice(prefix);
        out.extend_from_slice(body);
        return;
    }
    let fill = sp.width - len;
    if sp.left {
        out.extend_from_slice(prefix);
        out.extend_from_slice(body);
        out.resize(out.len() + fill, b' ');
    } else if sp.zero && zero_ok {
        out.extend_from_slice(prefix);
        out.resize(out.len() + fill, b'0');
        out.extend_from_slice(body);
    } else {
        out.resize(out.len() + fill, b' ');
        out.extend_from_slice(prefix);
        out.extend_from_slice(body);
    }
}

fn fmt_int(out: &mut Vec<u8>, sp: &Spec, conv: u8, arg: Option<&Arg>, len: Len) {
    let mut buf = [0u8; 24]; // room for the 22 octal digits of a u64
    let mut i = buf.len();
    let (neg, mag) = if conv == b'd' || conv == b'i' {
        let v = arg_signed(arg, len);
        (v < 0, v.unsigned_abs())
    } else {
        (false, arg_unsigned(arg, len))
    };
    let base: u64 = match conv {
        b'x' | b'X' => 16,
        b'o' => 8,
        _ => 10,
    };
    let digits: &[u8; 16] = if conv == b'X' {
        b"0123456789ABCDEF"
    } else {
        b"0123456789abcdef"
    };
    let mut v = mag;
    while v != 0 {
        i -= 1;
        buf[i] = digits[(v % base) as usize];
        v /= base;
    }
    if mag == 0 && sp.prec != Some(0) {
        i -= 1;
        buf[i] = b'0';
    }
    let num = &buf[i..];
    let mut body: Vec<u8> = Vec::with_capacity(24);
    if let Some(p) = sp.prec {
        if p > num.len() {
            body.resize(p - num.len(), b'0');
        }
    }
    body.extend_from_slice(num);
    let mut prefix: &[u8] = b"";
    match conv {
        b'd' | b'i' => {
            if neg {
                prefix = b"-";
            } else if sp.plus {
                prefix = b"+";
            } else if sp.space {
                prefix = b" ";
            }
        }
        b'o' if sp.alt && body.first() != Some(&b'0') => body.insert(0, b'0'),
        b'x' if sp.alt && mag != 0 => prefix = b"0x",
        b'X' if sp.alt && mag != 0 => prefix = b"0X",
        _ => {}
    }
    pad(out, sp, prefix, &body, sp.prec.is_none());
}

/// Fixed-notation digits: `k` holds digits with value `0.k * 10^point`;
/// `prec` digits are written after the decimal point.
fn fixed_body(body: &mut Vec<u8>, k: &[u8], point: i32, prec: usize, alt: bool) {
    if point > 0 {
        let p = point as usize;
        if k.len() >= p {
            body.extend_from_slice(&k[..p]);
        } else {
            body.extend_from_slice(k);
            body.resize(body.len() + p - k.len(), b'0');
        }
    } else {
        body.push(b'0');
    }
    if prec > 0 || alt {
        body.push(b'.');
    }
    for i in 0..prec as i64 {
        let idx = point as i64 + i;
        let c = if idx < 0 {
            b'0'
        } else {
            k.get(idx as usize).copied().unwrap_or(b'0')
        };
        body.push(c);
    }
}

fn exp_body(body: &mut Vec<u8>, k: &[u8], exp: i32, alt: bool, strip: bool, upper: bool) {
    body.push(k[0]);
    let mut frac = &k[1..];
    if strip {
        while let Some((&b'0', rest)) = frac.split_last() {
            frac = rest;
        }
    }
    if !frac.is_empty() || alt {
        body.push(b'.');
        body.extend_from_slice(frac);
    }
    body.push(if upper { b'E' } else { b'e' });
    body.push(if exp < 0 { b'-' } else { b'+' });
    let a = exp.unsigned_abs();
    if a < 10 {
        body.push(b'0');
    }
    body.extend_from_slice(a.to_string().as_bytes());
}

fn strip_zeros(body: &mut Vec<u8>) {
    if body.contains(&b'.') {
        while body.last() == Some(&b'0') {
            body.pop();
        }
        if body.last() == Some(&b'.') {
            body.pop();
        }
    }
}

fn fmt_float(out: &mut Vec<u8>, sp: &Spec, conv: u8, x: f64) {
    let upper = conv.is_ascii_uppercase();
    let prefix: &[u8] = if x.is_sign_negative() {
        b"-"
    } else if sp.plus {
        b"+"
    } else if sp.space {
        b" "
    } else {
        b""
    };
    if !x.is_finite() {
        let body: &[u8] = match (x.is_nan(), upper) {
            (true, false) => b"nan",
            (true, true) => b"NAN",
            (false, false) => b"inf",
            (false, true) => b"INF",
        };
        pad(out, sp, prefix, body, false);
        return;
    }
    let prec = sp.prec.unwrap_or(6); // the C default precision
    let mut body = Vec::with_capacity(32);
    match conv {
        b'f' | b'F' => {
            let (k, point) = digits_fixed(x, prec);
            fixed_body(&mut body, &k, point, prec, sp.alt);
        }
        b'e' | b'E' => {
            let (k, exp) = digits_exp(x, prec + 1);
            exp_body(&mut body, &k, exp, sp.alt, false, upper);
        }
        _ => {
            // %g, %G
            let p = if prec == 0 { 1 } else { prec };
            let (k, xexp, carried) = digits_exp_carry(x, p);
            if carried && xexp == p as i32 {
                // glibc chose fixed notation from the unrounded exponent
                // (p - 1), with no fraction digits; when rounding carries
                // into exponent p it switches to exponential notation but
                // keeps zero fraction digits: "%#g" of 999999.5 is
                // "1.e+06", not "1.00000e+06".
                exp_body(&mut body, &k[..1], xexp, sp.alt, true, upper);
            } else if xexp < p as i32 && xexp >= -4 {
                // C: %g uses %e style if the exponent is < -4 or >= P
                fixed_body(
                    &mut body,
                    &k,
                    xexp + 1,
                    (p as i32 - 1 - xexp) as usize,
                    sp.alt,
                );
                if !sp.alt {
                    strip_zeros(&mut body);
                }
            } else {
                exp_body(&mut body, &k, xexp, sp.alt, !sp.alt, upper);
            }
        }
    }
    pad(out, sp, prefix, &body, true);
}

/// Format `fmt` with `args` as glibc's `sprintf` does, appending the result
/// to `out`. Returns the number of bytes appended.
///
/// Missing arguments are taken as 0 (or `NULL` for `%s`); unknown
/// conversions are copied to the output unchanged.
pub fn sprintf_into(out: &mut Vec<u8>, fmt: &[u8], args: &[Arg]) -> usize {
    let start = out.len();
    let n = fmt.len();
    let mut i = 0;
    let mut ai = 0;
    while i < n {
        // Copy literal text up to the next '%'.
        let lit_start = i;
        while i < n && fmt[i] != b'%' {
            i += 1;
        }
        if i > lit_start {
            out.extend_from_slice(&fmt[lit_start..i]);
        }
        if i >= n {
            break;
        }
        let spec_start = i;
        i += 1;
        let mut sp = Spec::default();
        // Flags
        while i < n {
            match fmt[i] {
                b'-' => sp.left = true,
                b'+' => sp.plus = true,
                b' ' => sp.space = true,
                b'#' => sp.alt = true,
                b'0' => sp.zero = true,
                b'\'' | b'I' => {}
                _ => break,
            }
            i += 1;
        }
        // Width
        if i < n && fmt[i] == b'*' {
            let w = arg_i32(args.get(ai));
            ai += 1;
            if w < 0 {
                sp.left = true;
            }
            sp.width = w.unsigned_abs() as usize;
            i += 1;
        } else {
            while i < n && fmt[i].is_ascii_digit() {
                sp.width = sp
                    .width
                    .saturating_mul(10)
                    .saturating_add((fmt[i] - b'0') as usize);
                i += 1;
            }
        }
        // Precision
        if i < n && fmt[i] == b'.' {
            i += 1;
            if i < n && fmt[i] == b'*' {
                let p = arg_i32(args.get(ai));
                ai += 1;
                sp.prec = if p < 0 { None } else { Some(p as usize) };
                i += 1;
            } else {
                let mut p = 0usize;
                while i < n && fmt[i].is_ascii_digit() {
                    p = p
                        .saturating_mul(10)
                        .saturating_add((fmt[i] - b'0') as usize);
                    i += 1;
                }
                sp.prec = Some(p);
            }
        }
        // Length modifier
        let mut len = Len::None;
        while i < n {
            match fmt[i] {
                b'h' => {
                    len = if len == Len::H { Len::HH } else { Len::H };
                }
                b'l' | b'L' | b'q' | b'j' | b'z' | b't' => len = Len::L,
                _ => break,
            }
            i += 1;
        }
        if i >= n {
            out.extend_from_slice(&fmt[spec_start..]);
            break;
        }
        let conv = fmt[i];
        i += 1;
        match conv {
            b'd' | b'i' | b'u' | b'x' | b'X' | b'o' => {
                let a = args.get(ai);
                ai += 1;
                fmt_int(out, &sp, conv, a, len);
            }
            b'e' | b'E' | b'f' | b'F' | b'g' | b'G' => {
                let x = arg_f64(args.get(ai));
                ai += 1;
                fmt_float(out, &sp, conv, x);
            }
            b'c' => {
                let a = args.get(ai);
                ai += 1;
                let c = match a {
                    Some(Arg::Str(Some(s))) => s.first().copied().unwrap_or(0),
                    other => arg_signed(other, Len::L) as u8,
                };
                pad(out, &sp, b"", &[c], false);
            }
            b's' => {
                let a = args.get(ai);
                ai += 1;
                let s: &[u8] = match a {
                    Some(Arg::Str(Some(s))) => {
                        // A C string ends at its first NUL.
                        match s.iter().position(|&c| c == 0) {
                            Some(z) => &s[..z],
                            None => s,
                        }
                    }
                    _ => {
                        // glibc prints "(null)", or nothing if the
                        // precision would truncate it.
                        const NULL_STR: &[u8] = b"(null)";
                        if matches!(sp.prec, Some(p) if p < NULL_STR.len()) {
                            b""
                        } else {
                            NULL_STR
                        }
                    }
                };
                let s = match sp.prec {
                    Some(p) if p < s.len() => &s[..p],
                    _ => s,
                };
                pad(out, &sp, b"", s, false);
            }
            b'%' => out.push(b'%'),
            _ => out.extend_from_slice(&fmt[spec_start..i]),
        }
    }
    out.len() - start
}

/// Format `fmt` with `args` as glibc's `sprintf` does.
pub fn sprintf(fmt: &[u8], args: &[Arg]) -> Vec<u8> {
    let mut out = Vec::with_capacity(fmt.len() + 16);
    sprintf_into(&mut out, fmt, args);
    out
}
