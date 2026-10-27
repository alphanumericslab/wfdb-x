//! C string parsing functions: `strtol`, `strtoul`, `strtod`, `atoi`,
//! `atol`, `atof`, `sscanf`, `strtok`, and `fgets`-style line splitting,
//! with the exact semantics of glibc (C locale).
//!
//! Positions are byte offsets into the input slice; a function that
//! returns `(value, end)` returns `end == 0` when C's `endptr` would equal
//! the start of the string (no conversion). To parse from an offset `pos`,
//! pass `&s[pos..]` and add `pos` to `end`.
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

/// C `isspace` in the C locale (space, `\t`, `\n`, `\v`, `\f`, `\r`).
#[inline]
pub fn isspace(c: u8) -> bool {
    c == b' ' || (b'\t'..=b'\r').contains(&c)
}

/// The value of a digit in bases up to 36 (`u32::MAX`, more than any base,
/// for a character that is not a digit).
#[inline]
fn digit_value(c: u8) -> u32 {
    match c {
        b'0'..=b'9' => u32::from(c - b'0'),
        b'a'..=b'z' => u32::from(c - b'a') + 10,
        b'A'..=b'Z' => u32::from(c - b'A') + 10,
        _ => u32::MAX,
    }
}

/// Common part of strtol/strtoul: returns (negative, magnitude,
/// overflowed, end). `end == 0` if no conversion.
fn strto_int(s: &[u8], base: u32) -> (bool, u64, bool, usize) {
    let n = s.len();
    let mut i = 0;
    while i < n && isspace(s[i]) {
        i += 1;
    }
    let mut neg = false;
    if i < n && (s[i] == b'+' || s[i] == b'-') {
        neg = s[i] == b'-';
        i += 1;
    }
    let mut base = base;
    let hex_prefix = |i: usize| {
        i + 2 < n && s[i] == b'0' && (s[i + 1] | 0x20) == b'x' && s[i + 2].is_ascii_hexdigit()
    };
    if base == 0 {
        if hex_prefix(i) {
            base = 16;
            i += 2;
        } else if i < n && s[i] == b'0' {
            base = 8;
        } else {
            base = 10;
        }
    } else if base == 16 && hex_prefix(i) {
        i += 2;
    }
    if !(2..=36).contains(&base) {
        return (false, 0, false, 0);
    }
    let start = i;
    let mut v: u64 = 0;
    let mut ovf = false;
    while i < n {
        let d = digit_value(s[i]);
        if d >= base {
            break;
        }
        match v
            .checked_mul(base as u64)
            .and_then(|x| x.checked_add(d as u64))
        {
            Some(x) => v = x,
            None => ovf = true,
        }
        i += 1;
    }
    if i == start {
        return (false, 0, false, 0);
    }
    (neg, v, ovf, i)
}

/// C `strtol(s, &end, base)` (64-bit `long`): returns `(value, end)`.
/// Out-of-range values are clamped to `i64::MIN`/`i64::MAX`.
pub fn strtol(s: &[u8], base: u32) -> (i64, usize) {
    let (neg, v, ovf, end) = strto_int(s, base);
    if end == 0 {
        return (0, 0);
    }
    let val = if neg {
        if ovf || v > 1u64 << 63 {
            i64::MIN
        } else {
            (v as i64).wrapping_neg()
        }
    } else if ovf || v > i64::MAX as u64 {
        i64::MAX
    } else {
        v as i64
    };
    (val, end)
}

/// C `strtoll` (same as [`strtol`] on the reference platform).
pub fn strtoll(s: &[u8], base: u32) -> (i64, usize) {
    strtol(s, base)
}

/// C `strtoul(s, &end, base)` (64-bit `unsigned long`): negative values
/// wrap, out-of-range values give `u64::MAX`.
pub fn strtoul(s: &[u8], base: u32) -> (u64, usize) {
    let (neg, v, ovf, end) = strto_int(s, base);
    if end == 0 {
        return (0, 0);
    }
    if ovf {
        return (u64::MAX, end);
    }
    (if neg { v.wrapping_neg() } else { v }, end)
}

/// C `atoi`: `(int) strtol(s, NULL, 10)` (the `long` result is truncated
/// to 32 bits, as glibc does).
pub fn atoi(s: &[u8]) -> i32 {
    strtol(s, 10).0 as i32
}

/// C `atol`: `strtol(s, NULL, 10)`.
pub fn atol(s: &[u8]) -> i64 {
    strtol(s, 10).0
}

/// C `atof`: `strtod(s, NULL)`.
pub fn atof(s: &[u8]) -> f64 {
    strtod(s).0
}

/// ASCII lower case of a letter (other characters are not compared).
#[inline]
fn lower(c: u8) -> u8 {
    c | 0x20
}

// The f64 format: the exponents of the smallest and largest normal powers of
// two, of the smallest subnormal, and the significand precision (bits).
const EMIN: i32 = f64::MIN_EXP - 1; // -1022
const EMAX: i32 = f64::MAX_EXP - 1; // 1023
const ETINY: i32 = EMIN - (f64::MANTISSA_DIGITS as i32 - 1); // -1074
const PRECISION: i64 = f64::MANTISSA_DIGITS as i64; // 53
const FRAC_BITS: u32 = f64::MANTISSA_DIGITS - 1;

fn match_ci(s: &[u8], i: usize, word: &[u8]) -> bool {
    s.len() >= i + word.len()
        && s[i..i + word.len()]
            .iter()
            .zip(word)
            .all(|(&a, &b)| lower(a) == b)
}

/// `x * 2^n` for `1 <= x < 2^54` and `n >= ETINY - 53`, exact when the
/// result is representable.
fn ldexp(x: f64, n: i32) -> f64 {
    if n < EMIN {
        // x * 2^EMIN is normal (exact); the second step is exact when
        // the result is representable.
        x * pow2(EMIN) * pow2(n - EMIN)
    } else if n > EMAX {
        x * pow2(EMAX) * pow2(n - EMAX)
    } else {
        x * pow2(n)
    }
}

/// `2^n` for `ETINY <= n <= EMAX`.
fn pow2(n: i32) -> f64 {
    if n >= EMIN {
        // The biased exponent field (bias EMAX).
        f64::from_bits(((n + EMAX) as u64) << FRAC_BITS)
    } else {
        f64::from_bits(1u64 << (n - ETINY))
    }
}

/// Correctly rounded value of a hexadecimal significand `mant` (with
/// `sticky` set if nonzero digits were dropped) times `2^exp2`.
fn hex_value(mant: u64, sticky: bool, exp2: i64) -> f64 {
    if mant == 0 {
        return 0.0;
    }
    let lz = mant.leading_zeros();
    let m = mant << lz; // bit 63 set
    let e = exp2 - lz as i64 + 63; // value = 1.xxx * 2^e
    if e > i64::from(EMAX) {
        return f64::INFINITY;
    }
    // Number of significant bits to keep.
    let emin = i64::from(EMIN);
    let keep: i64 = if e >= emin {
        PRECISION
    } else {
        PRECISION - (emin - e)
    };
    if keep <= 0 {
        // Below half the smallest subnormal (or exactly, ties to even 0),
        // unless keep == 0 and the value exceeds half.
        if keep == 0 {
            let half = m == 1u64 << 63 && !sticky;
            return if half { 0.0 } else { pow2(ETINY) };
        }
        return 0.0;
    }
    let shift = 64 - keep as u32;
    let mut kept = m >> shift;
    let dropped = m & ((1u64 << shift) - 1);
    let half = 1u64 << (shift - 1);
    if dropped > half || (dropped == half && (sticky || kept & 1 == 1)) {
        kept += 1;
    }
    // value = kept * 2^(e - keep + 1)
    ldexp(kept as f64, (e - keep + 1) as i32)
}

/// The (case-insensitive) names of infinity and NaN accepted by `strtod`
/// and `scanf`.
const INF: &[u8] = b"inf";
const INFINITY: &[u8] = b"infinity";
const NAN: &[u8] = b"nan";

/// C `strtod(s, &end)` as glibc implements it (correctly rounded decimal
/// and hexadecimal input, `inf`, `infinity`, `nan`, `nan(...)`): returns
/// `(value, end)`, with `end == 0` if no conversion was performed.
pub fn strtod(s: &[u8]) -> (f64, usize) {
    let n = s.len();
    let mut i = 0;
    while i < n && isspace(s[i]) {
        i += 1;
    }
    let mut neg = false;
    if i < n && (s[i] == b'+' || s[i] == b'-') {
        neg = s[i] == b'-';
        i += 1;
    }
    let sign = |v: f64| if neg { -v } else { v };
    // Hexadecimal
    if i + 1 < n && s[i] == b'0' && lower(s[i + 1]) == b'x' {
        let j = i + 2;
        let has_digits = (j < n && s[j].is_ascii_hexdigit())
            || (j + 1 < n && s[j] == b'.' && s[j + 1].is_ascii_hexdigit());
        if has_digits {
            let (v, end) = parse_hex(s, j);
            return (sign(v), end);
        }
        // "0x" alone: the "0" is the number.
        return (sign(0.0), i + 1);
    }
    // Decimal
    let start = i;
    let mut j = i;
    let mut ndig = 0;
    while j < n && s[j].is_ascii_digit() {
        j += 1;
        ndig += 1;
    }
    if j < n && s[j] == b'.' {
        j += 1;
        while j < n && s[j].is_ascii_digit() {
            j += 1;
            ndig += 1;
        }
    }
    if ndig > 0 {
        let mant_end = j;
        if j < n && lower(s[j]) == b'e' {
            let mut k = j + 1;
            if k < n && (s[k] == b'+' || s[k] == b'-') {
                k += 1;
            }
            if k < n && s[k].is_ascii_digit() {
                while k < n && s[k].is_ascii_digit() {
                    k += 1;
                }
                j = k;
            }
        }
        let v = parse_decimal(&s[start..mant_end], &s[mant_end..j]);
        return (sign(v), j);
    }
    if match_ci(s, i, INF) {
        let end = if match_ci(s, i, INFINITY) {
            i + INFINITY.len()
        } else {
            i + INF.len()
        };
        return (sign(f64::INFINITY), end);
    }
    if match_ci(s, i, NAN) {
        let mut end = i + NAN.len();
        if end < n && s[end] == b'(' {
            let mut k = end + 1;
            while k < n && (s[k].is_ascii_alphanumeric() || s[k] == b'_') {
                k += 1;
            }
            if k < n && s[k] == b')' {
                end = k + 1;
            }
        }
        return (sign(f64::NAN), end);
    }
    (0.0, 0)
}

/// Correctly rounded value of a decimal mantissa (digits and an optional
/// point) and exponent part (`e[+-]digits`, or empty).
fn parse_decimal(mant: &[u8], exp: &[u8]) -> f64 {
    // Rust's f64 parser is correctly rounded (as glibc's strtod). Very long
    // exponents are clamped first (the result is then 0 or infinity, or
    // determined by the clamped exponent).
    let mut t = String::with_capacity(mant.len() + 24);
    for &c in mant {
        t.push(c as char);
    }
    if !exp.is_empty() {
        let (eneg, digits) = match exp[1] {
            b'-' => (true, &exp[2..]),
            b'+' => (false, &exp[2..]),
            _ => (false, &exp[1..]),
        };
        let mut e: i64 = 0;
        for &c in digits {
            e = (e * 10 + (c - b'0') as i64).min(1_000_000_000_000);
        }
        // Bound the exponent so that the mantissa length cannot bring it
        // back into range.
        let bound = 100_000 + mant.len() as i64;
        let e = e.min(bound);
        t.push('e');
        if eneg {
            t.push('-');
        }
        t.push_str(&e.to_string());
    }
    t.parse::<f64>().unwrap_or(0.0)
}

fn parse_hex(s: &[u8], mut j: usize) -> (f64, usize) {
    let n = s.len();
    let mut mant: u64 = 0;
    let mut sticky = false;
    let mut exp2: i64 = 0;
    let mut seen_point = false;
    loop {
        if j < n && s[j].is_ascii_hexdigit() {
            let d = digit_value(s[j]) as u64;
            if mant >> 60 == 0 {
                // room for another hexadecimal digit
                mant = (mant << 4) | d;
                if seen_point {
                    exp2 -= 4;
                }
            } else {
                if d != 0 {
                    sticky = true;
                }
                if !seen_point {
                    exp2 += 4;
                }
            }
            j += 1;
        } else if j < n && s[j] == b'.' && !seen_point {
            seen_point = true;
            j += 1;
        } else {
            break;
        }
    }
    if j < n && lower(s[j]) == b'p' {
        let mut k = j + 1;
        let mut eneg = false;
        if k < n && (s[k] == b'+' || s[k] == b'-') {
            eneg = s[k] == b'-';
            k += 1;
        }
        if k < n && s[k].is_ascii_digit() {
            let mut e: i64 = 0;
            while k < n && s[k].is_ascii_digit() {
                e = (e * 10 + (s[k] - b'0') as i64).min(1_000_000_000);
                k += 1;
            }
            exp2 += if eneg { -e } else { e };
            j = k;
        }
    }
    (hex_value(mant, sticky, exp2), j)
}

// ---------------------------------------------------------------------------
// sscanf

/// A destination of an [`sscanf`] conversion (the C pointer argument).
///
/// Integer conversions store into any integer variant (truncated to its
/// width, as C stores into an `int`, `short`, ...); floating conversions
/// into `F64`/`F32`; `%s`, `%[` and `%Nc` into `Bytes` (replacing its
/// contents); `%c` into `Byte` (or `Bytes`).
#[derive(Debug)]
pub enum ScanArg<'a> {
    /// `int *`
    I32(&'a mut i32),
    /// `long *` / `long long *`
    I64(&'a mut i64),
    /// `unsigned *`
    U32(&'a mut u32),
    /// `unsigned long *`
    U64(&'a mut u64),
    /// `short *`
    I16(&'a mut i16),
    /// `signed char *` (for `%hhd`)
    I8(&'a mut i8),
    /// `double *`
    F64(&'a mut f64),
    /// `float *`
    F32(&'a mut f32),
    /// `char *` buffer (`%s`, `%[...]`, `%Nc`)
    Bytes(&'a mut Vec<u8>),
    /// `char *` (single `%c`)
    Byte(&'a mut u8),
}

macro_rules! scanarg_from {
    ($($t:ty => $v:ident),*) => {$(
        impl<'a> From<&'a mut $t> for ScanArg<'a> {
            fn from(p: &'a mut $t) -> ScanArg<'a> { ScanArg::$v(p) }
        }
    )*};
}
scanarg_from!(i32 => I32, i64 => I64, u32 => U32, u64 => U64, i16 => I16, i8 => I8,
              f64 => F64, f32 => F32, Vec<u8> => Bytes, u8 => Byte);

impl ScanArg<'_> {
    fn store_int(&mut self, v: i64) {
        match self {
            ScanArg::I32(p) => **p = v as i32,
            ScanArg::I64(p) => **p = v,
            ScanArg::U32(p) => **p = v as u32,
            ScanArg::U64(p) => **p = v as u64,
            ScanArg::I16(p) => **p = v as i16,
            ScanArg::I8(p) => **p = v as i8,
            ScanArg::F64(p) => **p = v as f64,
            ScanArg::F32(p) => **p = v as f32,
            ScanArg::Byte(p) => **p = v as u8,
            ScanArg::Bytes(_) => {}
        }
    }
    fn store_float(&mut self, text: &[u8]) {
        match self {
            ScanArg::F64(p) => **p = strtod(text).0,
            ScanArg::F32(p) => **p = strtof(text).0,
            _ => {}
        }
    }
    fn store_bytes(&mut self, v: &[u8]) {
        match self {
            ScanArg::Bytes(p) => {
                p.clear();
                p.extend_from_slice(v);
            }
            ScanArg::Byte(p) => {
                if let Some(&c) = v.first() {
                    **p = c;
                }
            }
            _ => {}
        }
    }
}

/// Scan an integer as glibc's scanf does (`base` 0 for `%i`); returns
/// (value, chars consumed) or None on a matching failure.
fn scan_int(s: &[u8], base: u32, unsigned: bool) -> Option<(i64, usize)> {
    let n = s.len();
    let mut i = 0;
    let mut text: Vec<u8> = Vec::with_capacity(24);
    if i < n && (s[i] == b'+' || s[i] == b'-') {
        text.push(s[i]);
        i += 1;
    }
    let mut base = base;
    let mut got_digit = false;
    if (base == 0 || base == 16) && i < n && s[i] == b'0' {
        text.push(b'0');
        i += 1;
        got_digit = true;
        if i < n && lower(s[i]) == b'x' {
            i += 1;
            base = 16;
        } else if base == 0 {
            base = 8;
        }
    }
    if base == 0 {
        base = 10;
    }
    while i < n && digit_value(s[i]) < base {
        text.push(s[i]);
        i += 1;
        got_digit = true;
    }
    if !got_digit {
        return None;
    }
    let v = if unsigned {
        strtoul(&text, base).0 as i64
    } else {
        strtol(&text, base).0
    };
    Some((v, i))
}

/// Scan a floating-point number as glibc's scanf does (it consumes an
/// exponent marker and sign even if no digit follows); returns (value,
/// chars consumed) or None on a matching failure. `width_end`: `s` ends
/// where the field width is exhausted (glibc then takes a final `0x` as the
/// number 0 followed by `x`).
fn scan_float(s: &[u8], width_end: bool) -> Option<(&[u8], usize)> {
    let n = s.len();
    let mut i = 0;
    if i < n && (s[i] == b'+' || s[i] == b'-') {
        i += 1;
    }
    if match_ci(s, i, NAN) {
        i += NAN.len();
        return Some((&s[..i], i));
    }
    if i < n && lower(s[i]) == b'i' {
        if !match_ci(s, i, INF) {
            return None;
        }
        // scanf commits to "infinity" once its fourth letter is read.
        let rest = &INFINITY[INF.len()..];
        i += INF.len();
        if i < n && lower(s[i]) == rest[0] {
            if !match_ci(s, i, rest) {
                return None;
            }
            i += rest.len();
        }
        return Some((&s[..i], i));
    }
    let mut hex = false;
    let mut ndig = 0;
    if i + 1 < n && s[i] == b'0' && lower(s[i + 1]) == b'x' {
        if width_end && i + 2 == n {
            // The width ends at the 'x': the number is "0".
            return Some((&s[..=i], i + 1));
        }
        hex = true;
        i += 2;
    }
    let isdig = |c: u8| {
        if hex {
            c.is_ascii_hexdigit()
        } else {
            c.is_ascii_digit()
        }
    };
    while i < n && isdig(s[i]) {
        i += 1;
        ndig += 1;
    }
    if i < n && s[i] == b'.' {
        i += 1;
        if hex {
            ndig += 1; // "0x." is accepted (as 0), "0x" alone is not
        }
        while i < n && isdig(s[i]) {
            i += 1;
            ndig += 1;
        }
    }
    if ndig == 0 {
        return None;
    }
    let expc = if hex { b'p' } else { b'e' };
    if i < n && lower(s[i]) == expc {
        i += 1;
        if i < n && (s[i] == b'+' || s[i] == b'-') {
            i += 1;
        }
        while i < n && s[i].is_ascii_digit() {
            i += 1;
        }
    }
    Some((&s[..i], i))
}

/// C `strtof`: like [`strtod`], correctly rounded to `f32` (decimal input
/// is rounded once, directly to `f32`, as glibc does).
pub fn strtof(s: &[u8]) -> (f32, usize) {
    let (d, end) = strtod(s);
    if end == 0 || !d.is_finite() || d == 0.0 {
        return (d as f32, end);
    }
    let t = &s[..end];
    let body: Vec<u8> = t.iter().copied().skip_while(|&c| isspace(c)).collect();
    let neg = body.first() == Some(&b'-');
    let digits = body
        .strip_prefix(b"-")
        .or_else(|| body.strip_prefix(b"+"))
        .unwrap_or(&body);
    if digits.len() > 1 && (digits[1] | 0x20) == b'x' {
        return (d as f32, end); // hexadecimal: rounded through f64
    }
    match std::str::from_utf8(digits)
        .ok()
        .and_then(|x| x.parse::<f32>().ok())
    {
        Some(v) => (if neg { -v } else { v }, end),
        None => (d as f32, end),
    }
}

/// Parse the scan set of a `%[` conversion whose body starts at `fmt[f]`
/// (just after the `[`), as glibc's `vfscanf` does: a leading `^` negates
/// the set; a `]` or `-` that comes first (after any `^`) is a member, not
/// the terminator or a range; `a-z` is a range when `a <= z` and `-` is not
/// last; otherwise `-` is a member. Returns the membership table and the
/// format position after the closing `]`, or `None` if the set has no
/// closing `]`.
fn parse_scanset(fmt: &[u8], mut f: usize) -> Option<([bool; 256], usize)> {
    let at = |k: usize| fmt.get(k).copied().unwrap_or(0); // a C string ends at NUL
    let mut set = [false; 256];
    let negate = at(f) == b'^';
    if negate {
        f += 1;
    }
    if matches!(at(f), b']' | b'-') {
        set[usize::from(at(f))] = true;
        f += 1;
    }
    loop {
        let c = at(f);
        f += 1;
        match c {
            0 => return None,
            b']' => break,
            // A range `lo-hi` (`lo` was already added as a member; `hi` is
            // added as a member by the next iteration).
            b'-' if !matches!(at(f), 0 | b']') && fmt[f - 2] <= at(f) => {
                for m in fmt[f - 2]..at(f) {
                    set[usize::from(m)] = true;
                }
            }
            _ => set[usize::from(c)] = true,
        }
    }
    if negate {
        for m in &mut set {
            *m = !*m;
        }
    }
    Some((set, f))
}

/// C `sscanf(input, fmt, ...)` with glibc's semantics.
///
/// Returns the number of assigned conversions, or -1 (`EOF`) if the input
/// ended before the first assignment. Destinations of conversions that
/// were not reached are left unchanged (C programs rely on such stale
/// values). Supports `%d %i %u %x %X %o %e %f %g %E %G %a %s %c %[...] %n
/// %%`, assignment suppression (`*`), field widths, and the length
/// modifiers (which are ignored: the [`ScanArg`] variant gives the
/// destination type).
pub fn sscanf(input: &[u8], fmt: &[u8], args: &mut [ScanArg]) -> i32 {
    // A C string ends at its first NUL.
    let input = match input.iter().position(|&c| c == 0) {
        Some(z) => &input[..z],
        None => input,
    };
    let n = input.len();
    let mut i = 0; // input position
    let mut f = 0; // format position
    let mut ai = 0; // next argument
    let mut done = 0i32;
    let fl = fmt.len();
    // Returns from the function: input failure gives EOF if no assignment.
    macro_rules! input_failure {
        () => {
            return if done == 0 { -1 } else { done }
        };
    }
    while f < fl {
        let c = fmt[f];
        if c == 0 {
            break;
        }
        if isspace(c) {
            while f < fl && isspace(fmt[f]) {
                f += 1;
            }
            while i < n && isspace(input[i]) {
                i += 1;
            }
            continue;
        }
        if c != b'%' {
            if i >= n {
                input_failure!();
            }
            if input[i] != c {
                return done;
            }
            i += 1;
            f += 1;
            continue;
        }
        // Conversion specification
        f += 1;
        let mut suppress = false;
        if f < fl && fmt[f] == b'*' {
            suppress = true;
            f += 1;
        }
        let mut width = 0usize;
        while f < fl && fmt[f].is_ascii_digit() {
            width = width * 10 + (fmt[f] - b'0') as usize;
            f += 1;
        }
        while f < fl && matches!(fmt[f], b'h' | b'l' | b'L' | b'q' | b'j' | b'z' | b't') {
            f += 1;
        }
        if f >= fl {
            return done;
        }
        let conv = fmt[f];
        f += 1;
        if conv == b'%' {
            while i < n && isspace(input[i]) {
                i += 1;
            }
            if i >= n {
                input_failure!();
            }
            if input[i] != b'%' {
                return done;
            }
            i += 1;
            continue;
        }
        if conv == b'n' {
            if !suppress {
                if let Some(a) = args.get_mut(ai) {
                    a.store_int(i as i64);
                }
                ai += 1;
            }
            continue;
        }
        if conv != b'c' && conv != b'[' {
            while i < n && isspace(input[i]) {
                i += 1;
            }
        }
        // glibc parses a scan set before reading the input.
        let scanset = if conv == b'[' {
            let Some((set, next)) = parse_scanset(fmt, f) else {
                return done; // no closing ']': matching failure
            };
            f = next;
            Some(set)
        } else {
            None
        };
        if i >= n {
            input_failure!();
        }
        let lim = if width > 0 { (i + width).min(n) } else { n };
        let field = &input[i..lim];
        match conv {
            b'd' | b'i' | b'u' | b'x' | b'X' | b'o' => {
                let base = match conv {
                    b'd' | b'u' => 10,
                    b'i' => 0,
                    b'o' => 8,
                    _ => 16,
                };
                match scan_int(field, base, !matches!(conv, b'd' | b'i')) {
                    None => return done,
                    Some((v, used)) => {
                        i += used;
                        if !suppress {
                            if let Some(a) = args.get_mut(ai) {
                                a.store_int(v);
                            }
                            ai += 1;
                            done += 1;
                        }
                    }
                }
            }
            b'e' | b'E' | b'f' | b'F' | b'g' | b'G' | b'a' | b'A' => {
                match scan_float(field, width > 0 && i + width <= n) {
                    None => return done,
                    Some((text, used)) => {
                        i += used;
                        if !suppress {
                            if let Some(a) = args.get_mut(ai) {
                                a.store_float(text);
                            }
                            ai += 1;
                            done += 1;
                        }
                    }
                }
            }
            b's' => {
                let mut j = 0;
                while j < field.len() && !isspace(field[j]) {
                    j += 1;
                }
                if !suppress {
                    if let Some(a) = args.get_mut(ai) {
                        a.store_bytes(&field[..j]);
                    }
                    ai += 1;
                    done += 1;
                }
                i += j;
            }
            b'c' => {
                let w = if width > 0 { width } else { 1 };
                let take = w.min(n - i);
                if !suppress {
                    if let Some(a) = args.get_mut(ai) {
                        a.store_bytes(&input[i..i + take]);
                    }
                    ai += 1;
                    done += 1;
                }
                i += take;
            }
            b'[' => {
                let Some(set) = &scanset else { unreachable!() }; // parsed above
                let j = field.iter().take_while(|&&ch| set[usize::from(ch)]).count();
                if j == 0 {
                    return done;
                }
                if !suppress {
                    if let Some(a) = args.get_mut(ai) {
                        a.store_bytes(&field[..j]);
                    }
                    ai += 1;
                    done += 1;
                }
                i += j;
            }
            _ => return done,
        }
    }
    done
}

// ---------------------------------------------------------------------------
// strtok

/// The C `strtok` function over one string.
///
/// `Strtok::new(s)` followed by `next(delims)` corresponds to
/// `strtok(s, delims)`; each further `next(delims)` corresponds to
/// `strtok(NULL, delims)`. Tokens are returned as slices of the original
/// string (C writes a NUL over the delimiter that ends each token; callers
/// that depend on that modification must reproduce it themselves).
#[derive(Clone, Debug)]
pub struct Strtok<'a> {
    s: &'a [u8],
    pos: Option<usize>,
}

impl<'a> Strtok<'a> {
    /// Start tokenizing `s` (which ends at its first NUL, if any).
    pub fn new(s: &'a [u8]) -> Strtok<'a> {
        let s = match s.iter().position(|&c| c == 0) {
            Some(z) => &s[..z],
            None => s,
        };
        Strtok { s, pos: Some(0) }
    }

    /// The next token, or `None` (C's `NULL`).
    #[allow(clippy::should_implement_trait)]
    pub fn next(&mut self, delims: &[u8]) -> Option<&'a [u8]> {
        let s = self.s;
        let n = s.len();
        let mut i = self.pos?;
        while i < n && delims.contains(&s[i]) {
            i += 1;
        }
        if i >= n {
            self.pos = None;
            return None;
        }
        let mut j = i;
        while j < n && !delims.contains(&s[j]) {
            j += 1;
        }
        self.pos = if j < n { Some(j + 1) } else { None };
        Some(&s[i..j])
    }

    /// The position (in the string) where the next call will start, or
    /// `None` if the string is exhausted.
    pub fn position(&self) -> Option<usize> {
        self.pos
    }

    /// The rest of the string from the current position (empty if
    /// exhausted).
    pub fn rest(&self) -> &'a [u8] {
        match self.pos {
            Some(p) if p <= self.s.len() => &self.s[p..],
            _ => b"",
        }
    }
}

// ---------------------------------------------------------------------------
// fgets

/// Split `data` into the successive results of `fgets(buf, size, fp)`:
/// pieces of at most `size - 1` bytes, each ending with a newline unless
/// the line was longer or the input ended.
pub fn fgets_lines(data: &[u8], size: usize) -> FgetsLines<'_> {
    FgetsLines {
        data,
        pos: 0,
        lim: size.saturating_sub(1).max(1),
    }
}

/// Iterator returned by [`fgets_lines`].
#[derive(Clone, Debug)]
pub struct FgetsLines<'a> {
    data: &'a [u8],
    pos: usize,
    lim: usize,
}

impl<'a> Iterator for FgetsLines<'a> {
    type Item = &'a [u8];
    fn next(&mut self) -> Option<&'a [u8]> {
        let n = self.data.len();
        let i = self.pos;
        if i >= n {
            return None;
        }
        let end = (i + self.lim).min(n);
        let j = match self.data[i..end].iter().position(|&c| c == b'\n') {
            Some(k) => i + k + 1,
            None => end,
        };
        self.pos = j;
        Some(&self.data[i..j])
    }
}
