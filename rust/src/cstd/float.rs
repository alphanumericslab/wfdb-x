//! Exact binary-to-decimal conversion of `f64` values, as used by glibc's
//! `printf` for `%e`, `%f` and `%g`.
//!
//! glibc formats a double from its *exact* binary value, rounding to the
//! requested number of digits with the current rounding mode (round to
//! nearest, ties to even, on the exact value). This module does the same:
//! a fast path computes the rounded digits with 128-bit integer arithmetic
//! when the scaled value fits, and a slow path expands the exact decimal
//! value with a small big-integer type. Both give identical results (the
//! fast path is exact, not an approximation).
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

/// Largest power of ten that fits in a `u128`.
const POW10_MAX: usize = 38;

/// Powers of ten that fit in a `u128` (`10^0 ..= 10^POW10_MAX`).
const POW10: [u128; POW10_MAX + 1] = {
    let mut t = [1u128; POW10_MAX + 1];
    let mut i = 1;
    while i <= POW10_MAX {
        t[i] = t[i - 1] * 10;
        i += 1;
    }
    t
};

/// Position of a remainder relative to half of the divisor.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Rem {
    Below,
    Half,
    Above,
}

/// The integer significand and exponent `(m, e)` of a finite `|x|`, with
/// `|x| == m * 2^e` exactly and `m < 2^53` (from the IEEE 754 fields).
#[inline]
fn raw_parts(x: f64) -> (u64, i32) {
    // IEEE 754 binary64: 52 fraction bits, 11 exponent bits (bias 1023).
    const FRAC_BITS: u32 = f64::MANTISSA_DIGITS - 1;
    const EXP_MASK: u64 = 0x7ff;
    // The unit of the integer significand of a normal number with biased
    // exponent `bexp` is 2^(bexp - EXP_OFFSET); that of subnormals is
    // 2^(1 - EXP_OFFSET).
    const EXP_OFFSET: i32 = 1023 + FRAC_BITS as i32;
    let bits = x.to_bits();
    let bexp = ((bits >> FRAC_BITS) & EXP_MASK) as i32;
    let frac = bits & ((1u64 << FRAC_BITS) - 1);
    if bexp == 0 {
        (frac, 1 - EXP_OFFSET)
    } else {
        (frac | (1u64 << FRAC_BITS), bexp - EXP_OFFSET)
    }
}

/// Decompose a finite, nonzero, non-negative `x` into `(m, e)` with
/// `x == m * 2^e` exactly and `m` odd.
fn decompose(x: f64) -> (u64, i32) {
    let (m, e) = raw_parts(x);
    let tz = m.trailing_zeros() as i32;
    (m >> tz, e + tz)
}

/// Append `printf("%<width>.<prec>f", x)` to `buf` if `x` is in the range
/// of this fast path (finite, with `prec <= 9`, and `|x| * 10^prec` below
/// 2^64): the result is glibc's (the exact binary value correctly rounded,
/// halfway cases to even). Returns false, appending nothing, otherwise
/// (use [`sprintf_into`](crate::cstd::sprintf_into) then).
#[inline]
pub fn fixed_fast(buf: &mut Vec<u8>, x: f64, width: usize, prec: u32) -> bool {
    // m * 10^MAX_PREC < 2^83; shifted by up to MAX_SHIFT bits, it fits in a
    // u128.
    const MAX_PREC: u32 = 9;
    const MAX_SHIFT: i32 = 40;
    if !x.is_finite() || prec > MAX_PREC {
        return false;
    }
    let neg = x.is_sign_negative();
    let (m, e) = raw_parts(x);
    let p10 = 10u128.pow(prec);
    let q: u128 = if e >= 0 {
        if e > MAX_SHIFT {
            return false;
        }
        (u128::from(m) << e) * p10
    } else {
        let k = (-e) as u32;
        let n = u128::from(m) * p10; // < 2^84
        if k >= 120 {
            0 // (far below 0.5)
        } else {
            let q = n >> k;
            let rem = n & ((1u128 << k) - 1);
            let half = 1u128 << (k - 1);
            if rem > half || (rem == half && (q & 1) == 1) {
                q + 1
            } else {
                q
            }
        }
    };
    let Ok(mut q) = u64::try_from(q) else {
        return false;
    };
    // Digits, least significant first: at most 20, a point, a sign, and
    // the zeros before the digits of small values (at most MAX_PREC).
    let mut tmp = [0u8; 20 + 2 + MAX_PREC as usize];
    let mut n = 0usize;
    let p = prec as usize;
    loop {
        tmp[n] = b'0' + (q % 10) as u8;
        q /= 10;
        n += 1;
        if n == p {
            tmp[n] = b'.';
            n += 1;
        }
        if q == 0 && n > p + usize::from(p > 0) {
            break;
        }
    }
    if neg {
        tmp[n] = b'-';
        n += 1;
    }
    for _ in n..width {
        buf.push(b' ');
    }
    buf.extend(tmp[..n].iter().rev());
    true
}

/// `floor(m * 2^e * 10^s)` and the position of the remainder, if the
/// computation fits in 128 bits.
fn scaled(m: u64, e: i32, s: i32) -> Option<(u128, Rem)> {
    let mut num = m as u128;
    if s > 0 {
        if s > POW10_MAX as i32 {
            return None;
        }
        num = num.checked_mul(POW10[s as usize])?;
    }
    if e >= 0 {
        if num.leading_zeros() as i32 <= e {
            return None;
        }
        num <<= e;
    }
    if s >= 0 {
        if e >= 0 {
            return Some((num, Rem::Below));
        }
        // Divide by a power of two.
        let k = -e;
        if k >= 128 {
            // The quotient is 0; num < 2^128 <= 2^(k-1) unless k == 128.
            if k == 128 {
                let half = 1u128 << 127;
                let rem = if num < half {
                    Rem::Below
                } else if num == half {
                    Rem::Half
                } else {
                    Rem::Above
                };
                return Some((0, rem));
            }
            return Some((0, Rem::Below));
        }
        let q = num >> k;
        let r = num & ((1u128 << k) - 1);
        let half = 1u128 << (k - 1);
        let rem = if r < half {
            Rem::Below
        } else if r == half {
            Rem::Half
        } else {
            Rem::Above
        };
        return Some((q, rem));
    }
    // s < 0: divide by 10^-s (and by 2^-e if e < 0).
    let t = -s;
    if t > POW10_MAX as i32 {
        return None;
    }
    let mut den = POW10[t as usize];
    if e < 0 {
        let k = -e;
        if k >= 127 || den.leading_zeros() as i32 <= k + 1 {
            return None;
        }
        den <<= k;
    }
    if den >> 126 != 0 {
        return None;
    }
    let q = num / den;
    let r = num - q * den;
    let r2 = r << 1;
    let rem = if r2 < den {
        Rem::Below
    } else if r2 == den {
        Rem::Half
    } else {
        Rem::Above
    };
    Some((q, rem))
}

#[inline]
fn round_q(q: u128, rem: Rem) -> u128 {
    match rem {
        Rem::Below => q,
        Rem::Above => q + 1,
        Rem::Half => q + (q & 1),
    }
}

/// Decimal digits (ASCII) of a `u128`, without leading zeros ("" for 0).
fn u128_digits(mut q: u128, out: &mut Vec<u8>) {
    let start = out.len();
    while q != 0 {
        out.push(b'0' + (q % 10) as u8);
        q /= 10;
    }
    out[start..].reverse();
}

// ---------------------------------------------------------------------------
// Slow path: a minimal big unsigned integer (little-endian 32-bit limbs).

struct Big {
    limbs: Vec<u32>,
}

impl Big {
    fn from_u64(v: u64) -> Big {
        let mut limbs = vec![v as u32, (v >> 32) as u32];
        while limbs.last() == Some(&0) {
            limbs.pop();
        }
        Big { limbs }
    }

    fn mul_small(&mut self, f: u32) {
        let mut carry = 0u64;
        for l in &mut self.limbs {
            let v = (*l as u64) * (f as u64) + carry;
            *l = v as u32;
            carry = v >> 32;
        }
        if carry != 0 {
            self.limbs.push(carry as u32);
        }
    }

    fn shl(&mut self, bits: u32) {
        let words = (bits / 32) as usize;
        let b = bits % 32;
        if b != 0 {
            let mut carry = 0u32;
            for l in &mut self.limbs {
                let v = *l;
                *l = (v << b) | carry;
                carry = v >> (32 - b);
            }
            if carry != 0 {
                self.limbs.push(carry);
            }
        }
        if words > 0 {
            let mut v = vec![0u32; words];
            v.extend_from_slice(&self.limbs);
            self.limbs = v;
        }
    }

    /// Decimal digits (ASCII), without leading zeros ("" for 0).
    fn to_decimal(&self) -> Vec<u8> {
        // Divide repeatedly by 10^9, the largest power of 10 in a limb.
        const CHUNK: u64 = 1_000_000_000;
        const CHUNK_DIGITS: usize = 9;
        let mut limbs = self.limbs.clone();
        let mut chunks: Vec<u32> = Vec::new();
        while !limbs.is_empty() {
            let mut rem = 0u64;
            for l in limbs.iter_mut().rev() {
                let v = (rem << 32) | (*l as u64);
                *l = (v / CHUNK) as u32;
                rem = v % CHUNK;
            }
            chunks.push(rem as u32);
            while limbs.last() == Some(&0) {
                limbs.pop();
            }
        }
        let mut out = Vec::with_capacity(chunks.len() * CHUNK_DIGITS);
        for (i, c) in chunks.iter().rev().enumerate() {
            let s = c.to_string();
            if i > 0 {
                out.extend(std::iter::repeat(b'0').take(CHUNK_DIGITS - s.len()));
            }
            out.extend_from_slice(s.as_bytes());
        }
        if out == b"0" {
            out.clear();
        }
        out
    }
}

/// The exact decimal expansion of `m * 2^e`: digits `d` (no leading
/// zeros) and `point`, with value `0.d * 10^point`.
fn exact_digits(m: u64, e: i32) -> (Vec<u8>, i32) {
    let mut b = Big::from_u64(m);
    if e >= 0 {
        b.shl(e as u32);
        let d = b.to_decimal();
        let p = d.len() as i32;
        (d, p)
    } else {
        let k = -e;
        let mut i = k;
        while i >= 13 {
            b.mul_small(1_220_703_125); // 5^13, the largest power of 5 in a limb
            i -= 13;
        }
        if i > 0 {
            b.mul_small(5u32.pow(i as u32));
        }
        let d = b.to_decimal();
        let p = d.len() as i32 - k;
        (d, p)
    }
}

/// Round the digits `d` (value `0.d * 10^point`) to `n` digits, ties to
/// even. Returns the kept digits and the new point (the result may have
/// fewer than `n` digits only if `n <= 0`, when it is "" or "1").
fn round_digits(d: &[u8], point: i32, n: i64) -> (Vec<u8>, i32) {
    let len = d.len() as i64;
    if n >= len {
        let mut k = d.to_vec();
        k.extend(std::iter::repeat(b'0').take((n - len) as usize));
        return (k, point);
    }
    if n < 0 {
        return (Vec::new(), point);
    }
    let n = n as usize;
    let mut kept = d[..n].to_vec();
    let first = d[n];
    let rest_nonzero = d[n + 1..].iter().any(|&c| c != b'0');
    let last_odd = n > 0 && (kept[n - 1] - b'0') & 1 == 1;
    let up = first > b'5' || (first == b'5' && (rest_nonzero || last_odd));
    if !up {
        return (kept, point);
    }
    let mut i = n;
    while i > 0 {
        i -= 1;
        if kept[i] == b'9' {
            kept[i] = b'0';
        } else {
            kept[i] += 1;
            return (kept, point);
        }
    }
    // All nines (or n == 0): the result is 10^point.
    kept.insert(0, b'1');
    if n > 0 {
        kept.pop();
    }
    (kept, point + 1)
}

/// Digits of `|x|` rounded to `prec` digits after the decimal point
/// (`%f`): returns `(k, point)` with value `0.k * 10^point`, where `k`
/// holds all the digits down to the 10^-prec position (`k` is empty if
/// the rounded value is zero). `x` must be finite.
pub(crate) fn digits_fixed(x: f64, prec: usize) -> (Vec<u8>, i32) {
    let x = x.abs();
    if x == 0.0 {
        return (Vec::new(), 0);
    }
    let (m, e) = decompose(x);
    if prec <= POW10_MAX {
        if let Some((q, rem)) = scaled(m, e, prec as i32) {
            let q = round_q(q, rem);
            if q == 0 {
                return (Vec::new(), 0);
            }
            let mut k = Vec::with_capacity(POW10_MAX + 1); // digits of a u128
            u128_digits(q, &mut k);
            let p = k.len() as i32 - prec as i32;
            return (k, p);
        }
    }
    fixed_slow(m, e, prec)
}

fn fixed_slow(m: u64, e: i32, prec: usize) -> (Vec<u8>, i32) {
    let (d, point) = exact_digits(m, e);
    let n = point as i64 + prec as i64;
    let (mut k, p) = round_digits(&d, point, n);
    // Represent zero as "".
    if k.iter().all(|&c| c == b'0') {
        return (Vec::new(), 0);
    }
    // Keep all the digits down to the 10^-prec position (after a carry,
    // round_digits keeps the number of digits).
    let want = p as i64 + prec as i64;
    if (k.len() as i64) < want {
        k.resize(want as usize, b'0');
    }
    (k, p)
}

/// Digits of `|x|` rounded to `nsig >= 1` significant digits (`%e`):
/// returns `(k, exp)` with `k.len() == nsig` and value `k[0].k[1..] *
/// 10^exp`. For zero, `k` is all zeros and `exp` is 0. `x` must be finite.
pub(crate) fn digits_exp(x: f64, nsig: usize) -> (Vec<u8>, i32) {
    let (k, e, _) = digits_exp_carry(x, nsig);
    (k, e)
}

/// [`digits_exp`], also telling whether rounding carried into a new
/// decimal exponent (e.g. 9.96 rounded to 2 digits gives 10).
pub(crate) fn digits_exp_carry(x: f64, nsig: usize) -> (Vec<u8>, i32, bool) {
    let x = x.abs();
    if x == 0.0 {
        return (vec![b'0'; nsig], 0, false);
    }
    let (m, e) = decompose(x);
    // Fast path: the decimal exponent is estimated from log10 (it may be
    // off by one, hence a few retries), and the scaled value, which may
    // then reach 10^(nsig + 1), must fit in a u128 (with a digit to spare).
    if nsig <= POW10_MAX - 2 {
        let lo = POW10[nsig - 1];
        let hi = POW10[nsig];
        let mut ex = x.log10().floor() as i32;
        for _ in 0..4 {
            let s = (nsig as i32 - 1) - ex;
            match scaled(m, e, s) {
                None => break,
                Some((q, rem)) => {
                    if q < lo {
                        ex -= 1;
                        continue;
                    }
                    if q >= hi {
                        ex += 1;
                        continue;
                    }
                    let mut q = round_q(q, rem);
                    let carried = q == hi;
                    if carried {
                        q = lo;
                        ex += 1;
                    }
                    let mut k = Vec::with_capacity(nsig);
                    u128_digits(q, &mut k);
                    return (k, ex, carried);
                }
            }
        }
    }
    exp_slow(m, e, nsig)
}

fn exp_slow(m: u64, e: i32, nsig: usize) -> (Vec<u8>, i32, bool) {
    let (d, point) = exact_digits(m, e);
    let (k, p) = round_digits(&d, point, nsig as i64);
    (k, p - 1, p != point)
}

/// Slow-path versions (for testing that the fast paths agree).
#[doc(hidden)]
pub fn slow_digits_fixed(x: f64, prec: usize) -> (Vec<u8>, i32) {
    let x = x.abs();
    if x == 0.0 {
        return (Vec::new(), 0);
    }
    let (m, e) = decompose(x);
    fixed_slow(m, e, prec)
}

/// Slow-path version of [`digits_exp`] (for testing).
#[doc(hidden)]
pub fn slow_digits_exp(x: f64, nsig: usize) -> (Vec<u8>, i32) {
    let x = x.abs();
    if x == 0.0 {
        return (vec![b'0'; nsig], 0);
    }
    let (m, e) = decompose(x);
    let (k, p, _) = exp_slow(m, e, nsig);
    (k, p)
}

/// Fast-path entry points (for testing).
#[doc(hidden)]
pub fn fast_digits_fixed(x: f64, prec: usize) -> (Vec<u8>, i32) {
    digits_fixed(x, prec)
}

/// Fast-path entry point of [`digits_exp`] (for testing).
#[doc(hidden)]
pub fn fast_digits_exp(x: f64, nsig: usize) -> (Vec<u8>, i32) {
    digits_exp(x, nsig)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exact_small() {
        assert_eq!(exact_digits(1, -1), (b"5".to_vec(), 0));
        assert_eq!(exact_digits(1, -3), (b"125".to_vec(), 0));
        assert_eq!(exact_digits(5, 1), (b"10".to_vec(), 2));
    }

    #[test]
    fn rounding() {
        assert_eq!(digits_fixed(0.5, 0), (b"".to_vec(), 0));
        assert_eq!(digits_fixed(1.5, 0), (b"2".to_vec(), 1));
        assert_eq!(digits_fixed(2.5, 0), (b"2".to_vec(), 1));
        assert_eq!(digits_fixed(0.125, 2), (b"12".to_vec(), 0));
        assert_eq!(digits_exp(99999.96, 6), (b"100000".to_vec(), 5));
        assert_eq!(slow_digits_exp(99999.96, 6), (b"100000".to_vec(), 5));
        assert_eq!(slow_digits_fixed(0.5, 0), (b"".to_vec(), 0));
        assert_eq!(slow_digits_fixed(1.5, 0), (b"2".to_vec(), 1));
        assert_eq!(slow_digits_fixed(9.5, 0), (b"10".to_vec(), 2));
    }

    #[test]
    fn fast_equals_slow() {
        let mut s = 0x1234_5678_9abc_def0u64;
        for _ in 0..200_000 {
            s ^= s << 13;
            s ^= s >> 7;
            s ^= s << 17;
            let x = f64::from_bits(s & 0x7fff_ffff_ffff_ffff);
            if !x.is_finite() {
                continue;
            }
            let p = (s >> 58) as usize % 25;
            assert_eq!(digits_exp(x, p + 1), slow_digits_exp(x, p + 1), "{x:e} {p}");
            assert_eq!(digits_fixed(x, p), slow_digits_fixed(x, p), "{x:e} {p}");
        }
    }
}
