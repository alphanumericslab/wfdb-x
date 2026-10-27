//! FLAC decoder and encoder for the FLAC signal formats 508, 516 and 524
//! (port of `cpp/src/flac.cpp`).
//!
//! The C library uses libFLAC for these formats; wfdb-x implements, without
//! external libraries, a complete FLAC decoder (all subframe types, fixed and
//! LPC predictors, Rice and Rice2 partitions with escape codes, wasted bits,
//! stereo decorrelation, variable block sizes, CRC verification) and a
//! lossless encoder (fixed predictors and Rice coding). The encoder writes
//! exactly the bytes written by the Python and C++ implementations of wfdb-x
//! (standard FLAC streams; their compressed bytes differ from those written
//! by libFLAC, whose output depends on its version, but the decoded samples
//! are identical).
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It has no counterpart in the original package: it is wfdb-x's own
// implementation of the FLAC format, which the original package reads and
// writes with libFLAC.
//
// Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

/// `FLAC__MAX_CHANNELS`.
pub(crate) const MAX_CHANNELS: usize = 8;
/// Samples per channel in each frame written by the encoder.
pub(crate) const BLOCKSIZE: usize = 4096;

const VENDOR: &[u8] = b"wfdb-x";

// Constants of the FLAC stream format (RFC 9639).

/// The marker that begins a FLAC stream.
const MARKER: &[u8] = b"fLaC";
/// Size of a metadata block header (a byte holding the last-block flag and
/// the block type, then the 24-bit length of the block).
const METADATA_HEADER_LEN: usize = 4;
/// Last-block flag of a metadata block header.
const METADATA_LAST: u8 = 0x80;
/// Metadata block types.
const METADATA_STREAMINFO: u8 = 0;
const METADATA_VORBIS_COMMENT: u8 = 4;
/// Length of the body of a STREAMINFO block.
const STREAMINFO_LEN: usize = 34;
/// Offset of the MD5 signature in a STREAMINFO block body.
const STREAMINFO_MD5_POS: usize = 18;
/// Length of an MD5 signature.
pub(crate) const MD5_LEN: usize = 16;
/// Offset of the STREAMINFO block body in the streams written by
/// [`Encoder`] (after the marker and the block header).
pub(crate) const STREAMINFO_POS: i64 = (MARKER.len() + METADATA_HEADER_LEN) as i64;
/// Total number of samples written in the preliminary STREAMINFO block (the
/// largest 36-bit value; the final block gives the real total).
const TOTAL_UNKNOWN: u64 = (1 << 36) - 1;
/// Sample rate recorded by [`Encoder`] (nominal: the sampling frequency of
/// a WFDB record is given by its header), and its frame header code.
const SAMPLE_RATE: u64 = 96000;
const SAMPLE_RATE_CODE: u64 = 11;
/// The first 15 bits of a frame header: the 14-bit sync code and a
/// reserved 0 bit.
const FRAME_SYNC: u64 = 0x7FFC;
/// Frame header block size codes: the size minus 1 follows in 8 or 16
/// bits; 256 << (code - 8) samples for codes 8 to 15 (code 12: BLOCKSIZE).
const BLOCKSIZE_CODE_8BIT: i32 = 6;
const BLOCKSIZE_CODE_16BIT: i32 = 7;
const BLOCKSIZE_CODE_4096: i32 = 12;
/// Frame header channel assignments: 0 to 7 for 1 to 8 independent
/// channels; stereo decorrelation modes.
const CHANNELS_LEFT_SIDE: i32 = 8;
const CHANNELS_SIDE_RIGHT: i32 = 9;
const CHANNELS_MID_SIDE: i32 = 10;
/// Subframe types (6-bit codes): constant, verbatim, fixed predictor
/// (`SUBFRAME_FIXED + order`), LPC (`SUBFRAME_LPC + order - 1`).
const SUBFRAME_CONSTANT: i32 = 0;
const SUBFRAME_VERBATIM: i32 = 1;
const SUBFRAME_FIXED: i32 = 8;
const SUBFRAME_LPC: i32 = 32;
/// Largest fixed predictor order, and largest LPC order.
const MAX_FIXED_ORDER: usize = 4;
const MAX_LPC_ORDER: usize = 32;
/// Width of the Rice parameters of residual coding method 0 (Rice) and 1
/// (Rice2); the all-ones parameter is the escape code (the residuals then
/// follow in binary, their width in the next 5 bits).
const RICE_PARAM_BITS: i32 = 4;
const RICE2_PARAM_BITS: i32 = 5;
/// Width of the partition order of residual coding.
const PARTITION_ORDER_BITS: i32 = 4;

/// Decoding status (the libFLAC error that would have been reported).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Status {
    /// No error.
    Ok,
    /// Lost sync.
    Sync,
    /// Invalid frame header.
    Header,
    /// Frame CRC mismatch.
    Crc,
    /// Unsupported format.
    Unparseable,
    /// Unexpected end of stream.
    Eof,
    /// Error in the stream header or metadata.
    Meta,
    /// Wrong number of channels or resolution (see `error_message`).
    Wfdb,
}

/// The result of [`decode`].
#[derive(Clone, Debug)]
pub(crate) struct Decoded {
    /// Decoding status.
    pub status: Status,
    /// Number of channels, from STREAMINFO.
    pub channels: i32,
    /// Bits per sample, from STREAMINFO.
    pub bps: i32,
    /// Samples, one vector per channel (empty on error).
    pub chans: Vec<Vec<i32>>,
    /// The end of each frame (FLAC block), in samples per channel.
    pub block_ends: Vec<i64>,
    /// Is there a STREAMINFO block (with an MD5 signature)?
    pub has_md5: bool,
    /// MD5 signature from STREAMINFO.
    pub md5: [u8; MD5_LEN],
    /// With status [`Status::Wfdb`]: the message that the C library
    /// reports with `wfdb_error` (the caller prints it).
    pub error_message: Option<Vec<u8>>,
}

impl Default for Decoded {
    fn default() -> Self {
        Decoded {
            status: Status::Ok,
            channels: 0,
            bps: 0,
            chans: Vec::new(),
            block_ends: Vec::new(),
            has_md5: false,
            md5: [0; MD5_LEN],
            error_message: None,
        }
    }
}

// ---------------------------------------------------------------------------
// CRC tables

const fn make_crc8() -> [u8; 256] {
    let mut t = [0u8; 256];
    let mut i = 0;
    while i < 256 {
        let mut c = i as u32;
        let mut k = 0;
        while k < 8 {
            c = if c & 0x80 != 0 {
                ((c << 1) ^ 0x07) & 0xFF
            } else {
                (c << 1) & 0xFF
            };
            k += 1;
        }
        t[i] = c as u8;
        i += 1;
    }
    t
}

const fn make_crc16() -> [u16; 256] {
    let mut t = [0u16; 256];
    let mut i = 0;
    while i < 256 {
        let mut c = (i as u32) << 8;
        let mut k = 0;
        while k < 8 {
            c = if c & 0x8000 != 0 {
                ((c << 1) ^ 0x8005) & 0xFFFF
            } else {
                (c << 1) & 0xFFFF
            };
            k += 1;
        }
        t[i] = c as u16;
        i += 1;
    }
    t
}

static CRC8: [u8; 256] = make_crc8();
static CRC16: [u16; 256] = make_crc16();

fn crc8(p: &[u8]) -> u32 {
    let mut c = 0u32;
    for &b in p {
        c = CRC8[(c ^ b as u32) as usize] as u32;
    }
    c
}

fn crc16(p: &[u8]) -> u32 {
    let mut c = 0u32;
    for &b in p {
        c = ((c << 8) & 0xFFFF) ^ CRC16[((c >> 8) ^ b as u32) as usize] as u32;
    }
    c
}

fn bit_length(x: u64) -> i32 {
    64 - x.leading_zeros() as i32
}

/// 8 bytes, big-endian.
#[inline]
fn load8(p: &[u8]) -> u64 {
    u64::from_be_bytes([p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7]])
}

// ---------------------------------------------------------------------------
// Decoder

type R<T> = Result<T, Status>;

/// MSB-first bit reader over a byte array.
struct Bits<'a> {
    d: &'a [u8],
    pos: u64,
    end: u64,
}

impl<'a> Bits<'a> {
    fn new(d: &'a [u8], bytepos: usize) -> Bits<'a> {
        Bits {
            d,
            pos: bytepos as u64 * 8,
            end: d.len() as u64 * 8,
        }
    }

    /// 8 bytes starting at b, big-endian, zero-padded beyond the end.
    #[inline]
    fn load(&self, b: usize) -> u64 {
        if b + 8 <= self.d.len() {
            return load8(&self.d[b..]);
        }
        let mut w = 0u64;
        for i in 0..8 {
            w = (w << 8) | self.d.get(b + i).copied().unwrap_or(0) as u64;
        }
        w
    }

    /// Read n bits (0 <= n <= 57) as an unsigned value.
    #[inline]
    fn read(&mut self, n: i32) -> R<u64> {
        if n <= 0 {
            if n < 0 {
                return Err(Status::Unparseable);
            }
            return Ok(0);
        }
        if self.pos + n as u64 > self.end {
            return Err(Status::Eof);
        }
        let b = (self.pos >> 3) as usize;
        let off = (self.pos & 7) as u32;
        let w = self.load(b) << off;
        self.pos += n as u64;
        Ok(w >> (64 - n))
    }

    /// Read n bits (0 <= n <= 64) as an unsigned value.
    fn read_long(&mut self, n: i32) -> R<u64> {
        if n <= 32 {
            return self.read(n);
        }
        let hi = self.read(n - 32)?;
        Ok((hi << 32) | self.read(32)?)
    }

    fn read_signed(&mut self, n: i32) -> R<i64> {
        if n > 57 {
            let mut v = self.read_long(n)?;
            if n < 64 && (v >> (n - 1)) & 1 != 0 {
                v = v.wrapping_sub(1u64 << n);
            }
            return Ok(v as i64);
        }
        let v = self.read(n)?;
        if n > 0 && (v >> (n - 1)) & 1 != 0 {
            return Ok(v as i64 - (1i64 << n));
        }
        Ok(v as i64)
    }

    /// Count zero bits up to (and consume) the next one bit.
    fn unary(&mut self) -> R<u64> {
        let mut b = (self.pos >> 3) as usize;
        let mut off = (self.pos & 7) as u32;
        let mut count = 0u64;
        loop {
            if b >= self.d.len() {
                return Err(Status::Eof);
            }
            let w = self.load(b) << off;
            if w != 0 {
                let z = w.leading_zeros() as u64;
                self.pos = ((b as u64) << 3) + off as u64 + z + 1;
                return Ok(count + z);
            }
            count += 64 - off as u64;
            b += 8;
            off = 0;
        }
    }

    /// A Rice-coded value with parameter k (0 <= k <= 30): unary quotient,
    /// then k bits.
    #[inline]
    fn rice(&mut self, k: i32) -> R<u64> {
        let b = (self.pos >> 3) as usize;
        if b + 8 <= self.d.len() {
            let off = (self.pos & 7) as u32;
            let w = load8(&self.d[b..]) << off;
            if w != 0 {
                let z = w.leading_zeros() as i32;
                if (z + 1 + k) as u32 <= 64 - off {
                    self.pos += (z + 1 + k) as u64;
                    if k == 0 {
                        return Ok(z as u64);
                    }
                    return Ok(((z as u64) << k) | ((w << (z + 1)) >> (64 - k)));
                }
            }
        }
        let q = self.unary()?;
        Ok((q << k) | self.read(k)?)
    }

    fn align(&mut self) {
        self.pos = (self.pos + 7) & !7u64;
    }

    fn byte_pos(&self) -> usize {
        (self.pos >> 3) as usize
    }
}

fn read_utf8(bits: &mut Bits) -> R<u64> {
    let x = bits.read(8)?;
    if x < 0x80 {
        return Ok(x);
    }
    let (mut v, n) = if (x & 0xE0) == 0xC0 {
        (x & 0x1F, 1)
    } else if (x & 0xF0) == 0xE0 {
        (x & 0x0F, 2)
    } else if (x & 0xF8) == 0xF0 {
        (x & 0x07, 3)
    } else if (x & 0xFC) == 0xF8 {
        (x & 0x03, 4)
    } else if (x & 0xFE) == 0xFC {
        (x & 0x01, 5)
    } else if x == 0xFE {
        (0, 6)
    } else {
        return Err(Status::Header);
    };
    for _ in 0..n {
        let y = bits.read(8)?;
        if (y & 0xC0) != 0x80 {
            return Err(Status::Header);
        }
        v = (v << 6) | (y & 0x3F);
    }
    Ok(v)
}

#[inline]
fn unfold(u: u64) -> i64 {
    if u & 1 != 0 {
        -((u >> 1) as i64) - 1
    } else {
        (u >> 1) as i64
    }
}

fn read_residual(bits: &mut Bits, blocksize: i64, order: i32, out: &mut Vec<i64>) -> R<()> {
    let method = bits.read(2)? as i32;
    if method > 1 {
        return Err(Status::Unparseable);
    }
    let pbits = if method == 0 {
        RICE_PARAM_BITS
    } else {
        RICE2_PARAM_BITS
    };
    let esc: u64 = (1 << pbits) - 1;
    let porder = bits.read(PARTITION_ORDER_BITS)? as i32;
    let nparts = 1i64 << porder;
    if blocksize % nparts != 0 {
        return Err(Status::Unparseable);
    }
    let psize = blocksize >> porder;
    if porder > 0 && psize < order as i64 {
        return Err(Status::Unparseable);
    }
    for part in 0..nparts {
        let n = if part == 0 {
            psize - order as i64
        } else {
            psize
        };
        let k = bits.read(pbits)?;
        if k == esc {
            let nb = bits.read(5)? as i32;
            for _ in 0..n {
                out.push(bits.read_signed(nb)?);
            }
        } else {
            let kk = k as i32;
            for _ in 0..n {
                out.push(unfold(bits.rice(kk)?));
            }
        }
    }
    Ok(())
}

#[inline]
fn shl(x: i64, n: i32) -> i64 {
    ((x as u64) << n) as i64
}

fn decode_subframe(bits: &mut Bits, blocksize: i64, mut bps: i32) -> R<Vec<i64>> {
    if bits.read(1)? != 0 {
        return Err(Status::Unparseable);
    }
    let t = bits.read(6)? as i32;
    let mut wasted = 0;
    if bits.read(1)? != 0 {
        wasted = bits.unary()? as i32 + 1;
        bps -= wasted;
    }
    let bs = blocksize.max(0) as usize;
    let mut s: Vec<i64>;
    if t == SUBFRAME_CONSTANT {
        let v = bits.read_signed(bps)?;
        s = vec![v; bs];
    } else if t == SUBFRAME_VERBATIM {
        s = Vec::with_capacity(bs);
        for _ in 0..blocksize {
            s.push(bits.read_signed(bps)?);
        }
    } else if (SUBFRAME_FIXED..=SUBFRAME_FIXED + MAX_FIXED_ORDER as i32).contains(&t) {
        let order = t - SUBFRAME_FIXED;
        s = Vec::with_capacity(bs.max(order as usize));
        for _ in 0..order {
            s.push(bits.read_signed(bps)?);
        }
        let mut res = Vec::with_capacity(bs);
        read_residual(bits, blocksize, order, &mut res)?;
        match order {
            0 => s.extend_from_slice(&res),
            1 => {
                let mut x = s[s.len() - 1];
                for &r in &res {
                    x = x.wrapping_add(r);
                    s.push(x);
                }
            }
            2 => {
                let (mut a, mut b) = (s[s.len() - 2], s[s.len() - 1]);
                for &r in &res {
                    let nb = b.wrapping_mul(2).wrapping_sub(a).wrapping_add(r);
                    a = b;
                    b = nb;
                    s.push(b);
                }
            }
            3 => {
                let (mut a, mut b, mut c) = (s[s.len() - 3], s[s.len() - 2], s[s.len() - 1]);
                for &r in &res {
                    let nc = c
                        .wrapping_mul(3)
                        .wrapping_sub(b.wrapping_mul(3))
                        .wrapping_add(a)
                        .wrapping_add(r);
                    a = b;
                    b = c;
                    c = nc;
                    s.push(c);
                }
            }
            _ => {
                let n = s.len();
                let (mut a, mut b, mut c, mut d) = (s[n - 4], s[n - 3], s[n - 2], s[n - 1]);
                for &r in &res {
                    let nd = d
                        .wrapping_mul(4)
                        .wrapping_sub(c.wrapping_mul(6))
                        .wrapping_add(b.wrapping_mul(4))
                        .wrapping_sub(a)
                        .wrapping_add(r);
                    a = b;
                    b = c;
                    c = d;
                    d = nd;
                    s.push(d);
                }
            }
        }
    } else if t >= SUBFRAME_LPC {
        let order = (t - SUBFRAME_LPC + 1) as usize;
        s = Vec::with_capacity(bs.max(order));
        for _ in 0..order {
            s.push(bits.read_signed(bps)?);
        }
        let prec = bits.read(4)? as i32 + 1;
        if prec == 16 {
            // (precision code 15, all ones, is invalid)
            return Err(Status::Unparseable);
        }
        let shift = bits.read_signed(5)? as i32;
        let mut coefs = [0i64; MAX_LPC_ORDER];
        for c in coefs.iter_mut().take(order) {
            *c = bits.read_signed(prec)?;
        }
        let mut res = Vec::with_capacity(bs);
        read_residual(bits, blocksize, order as i32, &mut res)?;
        if shift < 0 {
            return Err(Status::Unparseable);
        }
        for &r in &res {
            let base = s.len() - order;
            let mut acc = 0i64;
            // coefs[0] applies to the most recent sample
            for (j, &c) in coefs.iter().enumerate().take(order) {
                acc = acc.wrapping_add(c.wrapping_mul(s[base + order - 1 - j]));
            }
            s.push(r.wrapping_add(acc >> shift));
        }
    } else {
        return Err(Status::Unparseable);
    }
    if wasted != 0 {
        for x in &mut s {
            *x = shl(*x, wasted);
        }
    }
    Ok(s)
}

/// Bits per sample of the frame header sample size codes (0: as in
/// STREAMINFO; 3: reserved).
const BPS_TABLE: [i32; 8] = [0, 8, 12, 0, 16, 20, 24, 32];

/// The block size given by a frame header block size code (other than
/// 0, 6 and 7).
fn block_size_code(bsc: i32) -> i64 {
    match bsc {
        1 => 192,
        2 => 576,
        3 => 1152,
        4 => 2304,
        5 => 4608,
        _ => 256i64 << (bsc - 8), // 8 .. 15
    }
}

/// Decode one frame at byte offset pos; returns the channels, the bits per
/// sample and the offset of the next frame.
fn decode_frame(data: &[u8], pos: usize, si_bps: i32) -> R<(Vec<Vec<i64>>, i32, usize)> {
    let n = data.len();
    if pos + 2 > n || u64::from(u16::from_be_bytes([data[pos], data[pos + 1]]) >> 1) != FRAME_SYNC {
        return Err(Status::Sync);
    }
    let mut bits = Bits::new(data, pos);
    bits.read(15)?; // FRAME_SYNC
    bits.read(1)?; // blocking strategy
    let bsc = bits.read(4)? as i32;
    let src = bits.read(4)? as i32;
    let chc = bits.read(4)? as i32;
    let ssc = bits.read(3)? as usize;
    if bits.read(1)? != 0 {
        return Err(Status::Header);
    }
    read_utf8(&mut bits)?;
    let blocksize = if bsc == 0 {
        return Err(Status::Header);
    } else if bsc == BLOCKSIZE_CODE_8BIT {
        bits.read(8)? as i64 + 1
    } else if bsc == BLOCKSIZE_CODE_16BIT {
        bits.read(16)? as i64 + 1
    } else {
        block_size_code(bsc)
    };
    // Sample rate codes 12 to 14: the rate follows in 8 or 16 bits; 15 is
    // invalid.
    if src == 12 {
        bits.read(8)?;
    } else if src == 13 || src == 14 {
        bits.read(16)?;
    } else if src == 15 {
        return Err(Status::Header);
    }
    let bps = if ssc == 0 {
        si_bps
    } else if BPS_TABLE[ssc] != 0 {
        BPS_TABLE[ssc]
    } else {
        return Err(Status::Header);
    };
    let hend = bits.byte_pos();
    let crc = bits.read(8)? as u32;
    if crc8(&data[pos..hend]) != crc {
        return Err(Status::Header);
    }
    let mut chans: Vec<Vec<i64>> = Vec::new();
    if chc < CHANNELS_LEFT_SIDE {
        for _ in 0..=chc {
            chans.push(decode_subframe(&mut bits, blocksize, bps)?);
        }
    } else if chc <= CHANNELS_MID_SIDE {
        if chc == CHANNELS_LEFT_SIDE {
            // left/side
            let a = decode_subframe(&mut bits, blocksize, bps)?;
            let sd = decode_subframe(&mut bits, blocksize, bps + 1)?;
            let b: Vec<i64> = a
                .iter()
                .zip(&sd)
                .map(|(&x, &y)| x.wrapping_sub(y))
                .collect();
            chans.push(a);
            chans.push(b);
        } else if chc == CHANNELS_SIDE_RIGHT {
            // side/right
            let sd = decode_subframe(&mut bits, blocksize, bps + 1)?;
            let b = decode_subframe(&mut bits, blocksize, bps)?;
            let a: Vec<i64> = sd
                .iter()
                .zip(&b)
                .map(|(&x, &y)| x.wrapping_add(y))
                .collect();
            chans.push(a);
            chans.push(b);
        } else {
            // mid/side
            let mid = decode_subframe(&mut bits, blocksize, bps)?;
            let sd = decode_subframe(&mut bits, blocksize, bps + 1)?;
            let m = mid.len().min(sd.len());
            let mut le = Vec::with_capacity(m);
            let mut ri = Vec::with_capacity(m);
            for i in 0..m {
                let x = shl(mid[i], 1) | (sd[i] & 1);
                let y = sd[i];
                le.push(x.wrapping_add(y) >> 1);
                ri.push(x.wrapping_sub(y) >> 1);
            }
            chans.push(le);
            chans.push(ri);
        }
    } else {
        return Err(Status::Header);
    }
    bits.align();
    let fend = bits.byte_pos();
    let c16 = bits.read(16)? as u32;
    if crc16(&data[pos..fend]) != c16 {
        return Err(Status::Crc);
    }
    Ok((chans, bps, bits.byte_pos()))
}

fn decode_inner(data: &[u8], expect_nsig: i32, expect_bps: i32, result: &mut Decoded) -> R<()> {
    let n = data.len();
    // Errors in the stream header and metadata are reported by libFLAC
    // without invoking its error callback ('meta' status).
    if !data.starts_with(MARKER) {
        return Err(Status::Meta);
    }
    let mut pos = MARKER.len();
    let mut si_bps = 0;
    let mut si_ch = 0;
    loop {
        if pos + METADATA_HEADER_LEN > n {
            return Err(Status::Meta);
        }
        let hb = data[pos];
        let ln = ((data[pos + 1] as usize) << 16)
            | ((data[pos + 2] as usize) << 8)
            | data[pos + 3] as usize;
        let body = pos + METADATA_HEADER_LEN;
        if body + ln > n {
            return Err(Status::Meta);
        }
        if (hb & !METADATA_LAST) == METADATA_STREAMINFO {
            if ln < STREAMINFO_LEN {
                return Err(Status::Meta);
            }
            let mut b = Bits::new(data, body);
            b.read(16)?;
            b.read(16)?;
            b.read(24)?;
            b.read(24)?;
            b.read(20)?;
            si_ch = b.read(3)? as i32 + 1;
            si_bps = b.read(5)? as i32 + 1;
            b.read(36)?;
            result.has_md5 = true;
            let md5 = body + STREAMINFO_MD5_POS;
            result.md5.copy_from_slice(&data[md5..md5 + MD5_LEN]);
        }
        pos = body + ln;
        if hb & METADATA_LAST != 0 {
            break;
        }
    }
    result.channels = si_ch;
    result.bps = si_bps;
    result.chans = vec![Vec::new(); si_ch.max(1) as usize];
    while pos < n {
        let (fr, bps, newpos) = match decode_frame(data, pos, si_bps) {
            Ok(x) => x,
            Err(Status::Sync) if data[pos..].iter().all(|&c| c == 0) => break,
            Err(e) => return Err(e),
        };
        pos = newpos;
        if expect_nsig > 0 && fr.len() != expect_nsig as usize {
            result.error_message =
                Some(b"getvec: wrong number of signals in FLAC signal file\n".to_vec());
            return Err(Status::Wfdb);
        }
        if expect_nsig > 0 && bps > expect_bps {
            result.error_message =
                Some(b"getvec: wrong sample resolution in FLAC signal file\n".to_vec());
            return Err(Status::Wfdb);
        }
        for (dst, src) in result.chans.iter_mut().zip(fr.iter()) {
            dst.extend(src.iter().map(|&x| x as i32));
        }
        if !fr.is_empty() {
            result.block_ends.push(result.chans[0].len() as i64);
        }
    }
    Ok(())
}

/// Decode a complete FLAC stream.
///
/// If `expect_nsig > 0`, a frame with a different number of channels, or
/// with more than `expect_bps` bits per sample, ends decoding with status
/// [`Status::Wfdb`] and the message the C library reports (`getvec: wrong
/// number of signals in FLAC signal file`, `getvec: wrong sample resolution
/// in FLAC signal file`) in `error_message`; the caller reports it. Other
/// errors are not reported (the status says what happened). Trailing zero
/// bytes after the last frame are ignored.
pub(crate) fn decode(data: &[u8], expect_nsig: i32, expect_bps: i32) -> Decoded {
    let mut result = Decoded::default();
    if let Err(e) = decode_inner(data, expect_nsig, expect_bps, &mut result) {
        result.status = e;
        result.chans.clear();
    }
    result
}

// ---------------------------------------------------------------------------
// MD5 (RFC 1321)

const MD5_K: [u32; 64] = [
    0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
    0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
    0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
    0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
    0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
    0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
    0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
    0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
];

const MD5_S: [u32; 64] = [
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9,
    14, 20, 5, 9, 14, 20, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 6, 10, 15,
    21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
];

/// Size of an MD5 input block.
const MD5_BLOCK: usize = 64;

/// MD5 message digest (RFC 1321).
#[derive(Clone, Debug)]
pub(crate) struct Md5 {
    a: u32,
    b: u32,
    c: u32,
    d: u32,
    length: u64,
    buffer: [u8; MD5_BLOCK],
    buffered: usize,
}

impl Default for Md5 {
    fn default() -> Self {
        Md5::new()
    }
}

impl Md5 {
    /// A new digest computation.
    pub(crate) fn new() -> Md5 {
        Md5 {
            a: 0x67452301,
            b: 0xefcdab89,
            c: 0x98badcfe,
            d: 0x10325476,
            length: 0,
            buffer: [0; MD5_BLOCK],
            buffered: 0,
        }
    }

    fn transform(&mut self, block: &[u8]) {
        let mut m = [0u32; 16];
        for (i, w) in m.iter_mut().enumerate() {
            *w = u32::from_le_bytes([
                block[4 * i],
                block[4 * i + 1],
                block[4 * i + 2],
                block[4 * i + 3],
            ]);
        }
        let (mut a, mut b, mut c, mut d) = (self.a, self.b, self.c, self.d);
        for i in 0..64 {
            let (f, g) = if i < 16 {
                ((b & c) | (!b & d), i)
            } else if i < 32 {
                ((d & b) | (!d & c), (5 * i + 1) & 15)
            } else if i < 48 {
                (b ^ c ^ d, (3 * i + 5) & 15)
            } else {
                (c ^ (b | !d), (7 * i) & 15)
            };
            let f = f.wrapping_add(a).wrapping_add(MD5_K[i]).wrapping_add(m[g]);
            a = d;
            d = c;
            c = b;
            b = b.wrapping_add(f.rotate_left(MD5_S[i]));
        }
        self.a = self.a.wrapping_add(a);
        self.b = self.b.wrapping_add(b);
        self.c = self.c.wrapping_add(c);
        self.d = self.d.wrapping_add(d);
    }

    /// Add data.
    pub(crate) fn update(&mut self, data: &[u8]) {
        let mut p = data;
        self.length = self.length.wrapping_add(p.len() as u64);
        if self.buffered > 0 {
            let k = (MD5_BLOCK - self.buffered).min(p.len());
            self.buffer[self.buffered..self.buffered + k].copy_from_slice(&p[..k]);
            self.buffered += k;
            p = &p[k..];
            if self.buffered < MD5_BLOCK {
                return;
            }
            let block = self.buffer;
            self.transform(&block);
            self.buffered = 0;
        }
        while p.len() >= MD5_BLOCK {
            self.transform(&p[..MD5_BLOCK]);
            p = &p[MD5_BLOCK..];
        }
        if !p.is_empty() {
            self.buffer[..p.len()].copy_from_slice(p);
            self.buffered = p.len();
        }
    }

    /// Finish the computation and return the digest.
    pub(crate) fn digest(&mut self) -> [u8; MD5_LEN] {
        // Pad with a 1 bit and 0 bits up to 8 bytes before the end of a
        // block, then append the 64-bit message length in bits.
        const LEN_POS: usize = MD5_BLOCK - 8;
        let bits = self.length.wrapping_mul(8);
        let mut pad = [0u8; MD5_BLOCK + 8];
        pad[0] = 0x80;
        let padlen = if self.buffered < LEN_POS {
            LEN_POS - self.buffered
        } else {
            MD5_BLOCK + LEN_POS - self.buffered
        };
        self.update(&pad[..padlen]);
        self.update(&bits.to_le_bytes());
        let mut out = [0u8; MD5_LEN];
        for (i, v) in [self.a, self.b, self.c, self.d].iter().enumerate() {
            out[4 * i..4 * i + 4].copy_from_slice(&v.to_le_bytes());
        }
        out
    }
}

/// The MD5 signature of decoded samples, as computed by libFLAC: the
/// samples interleaved, each stored in `(bps+7)/8` little-endian bytes.
pub(crate) fn samples_md5(chans: &[Vec<i32>], bps: i32) -> [u8; MD5_LEN] {
    const CHUNK: usize = 1 << 16; // bytes passed to the digest at a time
    let mut md5 = Md5::new();
    let nb = ((bps + 7) / 8) as usize;
    let n = chans.first().map_or(0, Vec::len);
    let mut buf: Vec<u8> = Vec::with_capacity(CHUNK + nb * chans.len());
    for i in 0..n {
        for c in chans {
            let v = c[i] as u32;
            for k in 0..nb {
                buf.push((v >> (8 * k)) as u8);
            }
        }
        if buf.len() >= CHUNK {
            md5.update(&buf);
            buf.clear();
        }
    }
    md5.update(&buf);
    md5.digest()
}

// ---------------------------------------------------------------------------
// Encoder

struct BitWriter<'a> {
    out: &'a mut Vec<u8>,
    acc: u64,
    nbits: i32,
}

impl<'a> BitWriter<'a> {
    fn new(out: &'a mut Vec<u8>) -> BitWriter<'a> {
        BitWriter {
            out,
            acc: 0,
            nbits: 0,
        }
    }

    /// Write the n (0 <= n <= 32) low bits of v.
    #[inline]
    fn write(&mut self, v: u64, n: i32) {
        if n == 0 {
            return;
        }
        self.acc = (self.acc << n) | (v & ((1u64 << n) - 1));
        self.nbits += n;
        while self.nbits >= 8 {
            self.nbits -= 8;
            self.out.push((self.acc >> self.nbits) as u8);
        }
    }

    /// Write q zero bits followed by a one bit.
    fn unary(&mut self, mut q: u64) {
        while q >= 32 {
            self.write(0, 32);
            q -= 32;
        }
        self.write(1, q as i32 + 1);
    }

    fn align(&mut self) {
        if self.nbits & 7 != 0 {
            self.write(0, 8 - (self.nbits & 7));
        }
    }
}

fn put_utf8(out: &mut Vec<u8>, mut v: u64) {
    if v < 0x80 {
        out.push(v as u8);
        return;
    }
    const TBL: [(usize, u64, u64); 6] = [
        (1, 0xC0, 0x7FF),
        (2, 0xE0, 0xFFFF),
        (3, 0xF0, 0x1FFFFF),
        (4, 0xF8, 0x3FFFFFF),
        (5, 0xFC, 0x7FFFFFFF),
        (6, 0xFE, 0xFFFFFFFFF),
    ];
    for &(n, lead, mx) in &TBL {
        if v <= mx {
            let mut b = [0u8; 7];
            for i in (1..=n).rev() {
                b[i] = (0x80 | (v & 0x3F)) as u8;
                v >>= 6;
            }
            b[0] = (lead | v) as u8;
            out.extend_from_slice(&b[..=n]);
            return;
        }
    }
}

#[derive(Default)]
struct Partition {
    cost: u64,
    porder: i32,
    params: Vec<i32>,
}

/// Choose a partition order and Rice parameters for folded residuals (as
/// `_best_partition()` in `_flac.py`). For each partition order, and each
/// partition, the parameter k is chosen among those near log2 of the mean,
/// with the cost (in bits) sum(u >> k) + n * (k + 1). The sums of u >> k
/// are computed once for the partitions of the highest partition order and
/// added up for the lower orders.
fn best_partition(u: &[u64], order: i32, blocksize: i64, maxk: i32) -> Partition {
    // The highest valid partition order
    let mut maxorder = 0;
    for porder in 1..7 {
        let nparts = 1i64 << porder;
        if blocksize % nparts != 0 {
            break;
        }
        if (blocksize >> porder) <= order as i64 {
            break;
        }
        maxorder = porder;
    }
    const NK: usize = 32; // k = 0 .. maxk (<= 30)
    let nfine = 1usize << maxorder;
    let fsize = blocksize >> maxorder;
    let mut sums = vec![0u64; nfine * NK];
    let mut counts = vec![0i64; nfine];
    let mut start = 0usize;
    for p in 0..nfine {
        let mut n = if p == 0 { fsize - order as i64 } else { fsize };
        if n < 0 {
            n = 0;
        }
        let sp = &mut sums[p * NK..(p + 1) * NK];
        for &x in &u[start..start + n as usize] {
            let mut v = x;
            let mut k = 0;
            while v != 0 && k <= maxk {
                sp[k as usize] = sp[k as usize].wrapping_add(v);
                k += 1;
                v >>= 1;
            }
        }
        counts[p] = n;
        start += n as usize;
    }

    let mut best = Partition::default();
    let mut have = false;
    let mut acc = [0u64; NK];
    for porder in 0..=maxorder {
        let nparts = 1usize << porder;
        let group = 1usize << (maxorder - porder); // fine partitions per part
        let mut cost: u64 = 6;
        let mut params = Vec::with_capacity(nparts);
        for p in 0..nparts {
            let mut n = 0i64;
            acc.fill(0);
            for q in p * group..(p + 1) * group {
                n += counts[q];
                let sp = &sums[q * NK..(q + 1) * NK];
                for k in 0..=maxk as usize {
                    acc[k] = acc[k].wrapping_add(sp[k]);
                }
            }
            if n == 0 {
                params.push(0);
                cost += 4;
                continue;
            }
            let mean = acc[0] / n as u64;
            let k0 = if mean > 0 { bit_length(mean) - 1 } else { 0 };
            let lo = (k0 - 1).max(0).min(maxk);
            let hi = (k0 + 2).min(maxk);
            let mut bk = -1;
            let mut bc = 0u64;
            for k in lo..=hi {
                let c = acc[k as usize].wrapping_add((n as u64).wrapping_mul((k + 1) as u64));
                if bk < 0 || c < bc {
                    bk = k;
                    bc = c;
                }
            }
            params.push(bk);
            cost = cost.wrapping_add(4).wrapping_add(bc);
        }
        if !have || cost < best.cost {
            best = Partition {
                cost,
                porder,
                params,
            };
            have = true;
        }
    }
    best
}

fn encode_subframe(bw: &mut BitWriter, x: &[i32], bps: i32) {
    let n = x.len();
    let constant = x.iter().all(|&v| v == x[0]);
    // Each subframe header: a zero bit, the 6-bit type, the wasted-bits flag
    // (0).
    if constant {
        bw.write(0, 1);
        bw.write(SUBFRAME_CONSTANT as u64, 6);
        bw.write(0, 1);
        bw.write(x[0] as i64 as u64, bps);
        return;
    }
    let maxk = (1 << RICE2_PARAM_BITS) - 2; // the largest non-escape parameter
    let mut have = false;
    let mut best_cost = 0u64;
    let mut best_order = 0usize;
    let mut best_u: Vec<u64> = Vec::new();
    let mut u: Vec<u64> = Vec::with_capacity(n);
    let mut best_bp = Partition::default();
    let maxorder = (n - 1).min(MAX_FIXED_ORDER);
    for order in 0..=maxorder {
        u.clear();
        for i in order..n {
            let xi = |k: usize| x[i - k] as i64;
            let r: i64 = match order {
                0 => xi(0),
                1 => xi(0) - xi(1),
                2 => xi(0) - 2 * xi(1) + xi(2),
                3 => xi(0) - 3 * xi(1) + 3 * xi(2) - xi(3),
                _ => xi(0) - 4 * xi(1) + 6 * xi(2) - 4 * xi(3) + xi(4),
            };
            u.push(if r >= 0 {
                (r as u64) << 1
            } else {
                (r.wrapping_neg() as u64).wrapping_shl(1).wrapping_sub(1)
            });
        }
        let bp = best_partition(&u, order as i32, n as i64, maxk);
        let cost = (order as u64)
            .wrapping_mul(bps as u64)
            .wrapping_add(2)
            .wrapping_add(bp.cost);
        if !have || cost < best_cost {
            have = true;
            best_cost = cost;
            best_order = order;
            std::mem::swap(&mut best_u, &mut u);
            best_bp = bp;
        }
    }
    if !have || best_cost >= n as u64 * bps as u64 {
        bw.write(0, 1);
        bw.write(SUBFRAME_VERBATIM as u64, 6);
        bw.write(0, 1);
        for &v in x {
            bw.write(v as i64 as u64, bps);
        }
        return;
    }
    let order = best_order;
    bw.write(0, 1);
    bw.write((SUBFRAME_FIXED as usize + order) as u64, 6);
    bw.write(0, 1);
    for &v in &x[..order] {
        bw.write(v as i64 as u64, bps);
    }
    let maxparam = best_bp.params.iter().copied().max().unwrap_or(0).max(0);
    let (method, pbits) = if maxparam < (1 << RICE_PARAM_BITS) - 1 {
        (0, RICE_PARAM_BITS)
    } else {
        (1, RICE2_PARAM_BITS)
    };
    bw.write(method as u64, 2);
    bw.write(best_bp.porder as u64, PARTITION_ORDER_BITS);
    let psize = (n as i64) >> best_bp.porder;
    let mut start = 0usize;
    for (p, &k) in best_bp.params.iter().enumerate() {
        let cnt = if p == 0 { psize - order as i64 } else { psize };
        bw.write(k as u64, pbits);
        for i in 0..cnt.max(0) as usize {
            let v = best_u[start + i];
            bw.unary(v >> k);
            if k != 0 {
                bw.write(v, k);
            }
        }
        if cnt > 0 {
            start += cnt as usize;
        }
    }
}

fn make_streaminfo(
    minfs: u32,
    maxfs: u32,
    nsig: i32,
    bps: i32,
    total: u64,
    md5: &[u8; MD5_LEN],
) -> Vec<u8> {
    let mut out = Vec::with_capacity(STREAMINFO_LEN);
    {
        let mut bw = BitWriter::new(&mut out);
        bw.write(BLOCKSIZE as u64, 16);
        bw.write(BLOCKSIZE as u64, 16);
        bw.write(minfs as u64, 24);
        bw.write(maxfs as u64, 24);
        bw.write(SAMPLE_RATE, 20);
        bw.write((nsig - 1) as u64, 3);
        bw.write((bps - 1) as u64, 5);
        bw.write(total >> 32, 4);
        bw.write(total & 0xFFFF_FFFF, 32);
    }
    out.extend_from_slice(md5);
    out
}

/// Encoder for a signal group of `nsig` signals with `spf` samples per
/// frame and `bps` (8, 16 or 24) bits per sample.
#[derive(Clone, Debug)]
pub(crate) struct Encoder {
    nsig: i32,
    bps: i32,
    spf: i32,
    chans: Vec<Vec<i32>>,
    pending: Vec<i32>,
    frame_no: u64,
    total: u64,
    minfs: u32,
    maxfs: u32,
    have_minfs: bool,
    md5: Md5,
}

impl Encoder {
    /// A new encoder.
    pub(crate) fn new(nsig: i32, bps: i32, spf: i32) -> Encoder {
        Encoder {
            nsig,
            bps,
            spf,
            chans: vec![Vec::new(); nsig.max(0) as usize],
            pending: Vec::with_capacity(nsig.max(0) as usize * spf.max(0) as usize),
            frame_no: 0,
            total: 0,
            minfs: 0,
            maxfs: 0,
            have_minfs: false,
            md5: Md5::new(),
        }
    }

    /// The stream header: `fLaC`, a STREAMINFO block with an unknown total
    /// number of samples, and a `VORBIS_COMMENT` block (vendor `wfdb-x
    /// <version>`). The final STREAMINFO ([`Encoder::streaminfo`]) is
    /// written later at offset [`STREAMINFO_POS`].
    pub(crate) fn header(&mut self) -> Vec<u8> {
        let vlen = VENDOR.len();
        let mut vc: Vec<u8> = (0..4).map(|i| (vlen >> (8 * i)) as u8).collect();
        vc.extend_from_slice(VENDOR);
        vc.extend_from_slice(&[0, 0, 0, 0]);
        let mut hdr = MARKER.to_vec();
        hdr.extend_from_slice(&[METADATA_STREAMINFO, 0, 0, STREAMINFO_LEN as u8]);
        hdr.extend(make_streaminfo(
            if self.have_minfs { self.minfs } else { 0 },
            self.maxfs,
            self.nsig,
            self.bps,
            TOTAL_UNKNOWN,
            &[0; MD5_LEN],
        ));
        hdr.push(METADATA_LAST | METADATA_VORBIS_COMMENT);
        hdr.push(((vc.len() >> 16) & 0xFF) as u8);
        hdr.push(((vc.len() >> 8) & 0xFF) as u8);
        hdr.push((vc.len() & 0xFF) as u8);
        hdr.extend(vc);
        hdr
    }

    /// Append one sample (in WFDB frame order: `spf` samples of signal 0,
    /// then `spf` samples of signal 1, ...), wrapped to `bps` bits.
    /// Encoded frames, if any, are appended to `out`.
    pub(crate) fn put(&mut self, v: i32, out: &mut Vec<u8>) {
        let (mask, half) = if self.bps >= 32 {
            (0xFFFF_FFFFu32, 0x8000_0000u32)
        } else {
            ((1u32 << self.bps) - 1, 1u32 << (self.bps - 1))
        };
        let w = (((v as u32).wrapping_add(half) & mask) as i64 - half as i64) as i32;
        self.pending.push(w);
        let spf = self.spf as usize;
        if self.pending.len() == self.nsig as usize * spf {
            for (c, ch) in self.chans.iter_mut().enumerate() {
                ch.extend_from_slice(&self.pending[c * spf..(c + 1) * spf]);
            }
            self.pending.clear();
            if self.chans[0].len() >= BLOCKSIZE {
                self.write_block(BLOCKSIZE, out);
            }
        }
    }

    /// Encode the remaining samples (appended to `out`).
    pub(crate) fn finish(&mut self, out: &mut Vec<u8>) {
        while !self.chans.is_empty() && !self.chans[0].is_empty() {
            let n = self.chans[0].len().min(BLOCKSIZE);
            self.write_block(n, out);
        }
    }

    /// The final 34-byte STREAMINFO block body (after [`Encoder::finish`]).
    pub(crate) fn streaminfo(&self) -> Vec<u8> {
        let mut m = self.md5.clone();
        let digest = m.digest();
        make_streaminfo(
            if self.have_minfs { self.minfs } else { 0 },
            self.maxfs,
            self.nsig,
            self.bps,
            self.total,
            &digest,
        )
    }

    fn write_block(&mut self, n: usize, out: &mut Vec<u8>) {
        let block: Vec<Vec<i32>> = self
            .chans
            .iter_mut()
            .map(|c| c.drain(..n).collect())
            .collect();
        // MD5 of the interleaved samples
        let nb = ((self.bps + 7) / 8) as usize;
        let mut inter: Vec<u8> = Vec::with_capacity(n * nb * block.len());
        for i in 0..n {
            for c in &block {
                let v = c[i] as u32;
                for k in 0..nb {
                    inter.push((v >> (8 * k)) as u8);
                }
            }
        }
        self.md5.update(&inter);

        let mut frame: Vec<u8> = Vec::new();
        let bsc = if n == BLOCKSIZE {
            BLOCKSIZE_CODE_4096
        } else if n <= 256 {
            BLOCKSIZE_CODE_8BIT
        } else {
            BLOCKSIZE_CODE_16BIT
        };
        {
            let mut hb = BitWriter::new(&mut frame);
            hb.write(FRAME_SYNC, 15);
            hb.write(0, 1); // fixed block size
            hb.write(bsc as u64, 4);
            hb.write(SAMPLE_RATE_CODE, 4);
            hb.write((self.nsig - 1) as u64, 4); // independent channels
            let ssc = match self.bps {
                // index in BPS_TABLE
                8 => 1,
                16 => 4,
                24 => 6,
                _ => 0,
            };
            hb.write(ssc, 3);
            hb.write(0, 1);
        }
        put_utf8(&mut frame, self.frame_no);
        if bsc == BLOCKSIZE_CODE_8BIT {
            frame.push((n - 1) as u8);
        } else if bsc == BLOCKSIZE_CODE_16BIT {
            frame.push((((n - 1) >> 8) & 0xFF) as u8);
            frame.push(((n - 1) & 0xFF) as u8);
        }
        let c8 = crc8(&frame) as u8;
        frame.push(c8);
        {
            let mut bw = BitWriter::new(&mut frame);
            for c in &block {
                encode_subframe(&mut bw, c, self.bps);
            }
            bw.align();
        }
        let c16 = crc16(&frame);
        frame.push((c16 >> 8) as u8);
        frame.push((c16 & 0xFF) as u8);
        out.extend_from_slice(&frame);
        self.frame_no += 1;
        self.total += n as u64;
        let fs = frame.len() as u32;
        if !self.have_minfs || fs < self.minfs {
            self.minfs = fs;
        }
        self.have_minfs = true;
        if fs > self.maxfs {
            self.maxfs = fs;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(d: &[u8; 16]) -> String {
        d.iter().map(|b| format!("{b:02x}")).collect()
    }

    fn md5_hex(data: &[u8]) -> String {
        let mut m = Md5::new();
        m.update(data);
        hex(&m.digest())
    }

    fn data_dir() -> std::path::PathBuf {
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../tests/data")
    }

    /// MD5 of the samples interleaved, each as a 32-bit little-endian integer.
    fn samples_digest(chans: &[Vec<i32>]) -> String {
        let mut m = Md5::new();
        let n = chans.first().map_or(0, std::vec::Vec::len);
        for i in 0..n {
            for c in chans {
                m.update(&(c[i] as u32).to_le_bytes());
            }
        }
        hex(&m.digest())
    }

    struct RecordCase {
        name: &'static str,
        channels: i32,
        bps: i32,
        nsamp: usize,
        digest: &'static str,
        first: [i32; 3],
        last: i32,
    }

    const RECORDS: [RecordCase; 4] = [
        RecordCase {
            name: "flac8",
            channels: 2,
            bps: 8,
            nsamp: 5000,
            digest: "505da209b1473fbc46a21feb7833b00d",
            first: [-31, -42, -13],
            last: -86,
        },
        RecordCase {
            name: "flac16",
            channels: 3,
            bps: 16,
            nsamp: 9000,
            digest: "c7031b07326efeaf5de0938839eccfd4",
            first: [-31, -58, -28],
            last: 1335,
        },
        RecordCase {
            name: "flac24",
            channels: 1,
            bps: 24,
            nsamp: 4500,
            digest: "009556de1b80833f7f1d21d99c817729",
            first: [-17, -4, 29],
            last: 8388435,
        },
        RecordCase {
            name: "flacmf",
            channels: 2,
            bps: 16,
            nsamp: 8642,
            digest: "76ee297c139a1538a9fd7f43d5398659",
            first: [-300, 700, -297],
            last: 2979,
        },
    ];

    /// Test signals for the encoder (the same as those of the Python script
    /// that computed the expected digests).
    fn gen(vid: i32, nsig: i32, bps: i32, spf: i32, nframes: i32, kinds: &[i32]) -> Vec<i32> {
        let mut state: u32 = 12345u32.wrapping_add(vid as u32);
        let mut out = Vec::new();
        let half: i64 = 1i64 << (bps - 1);
        for f in 0..nframes {
            for s in 0..nsig {
                for k in 0..spf {
                    state = state.wrapping_mul(1664525).wrapping_add(1013904223);
                    let t = f as i64 * spf as i64 + k as i64;
                    let v: i64 = match kinds[s as usize] {
                        0 => {
                            const P: i64 = 397;
                            let m = t % P - P / 2;
                            let tri = m.abs();
                            tri * (half / 256) - half / 2 + ((state >> 20) % 7) as i64 - 3
                        }
                        1 => ((state >> 8) & ((1u32 << bps) - 1)) as i64 - half,
                        2 => {
                            if t < 5000 {
                                17
                            } else {
                                (t - 5000) * 3 - 100
                            }
                        }
                        _ => state as i32 as i64,
                    };
                    out.push(v as u32 as i32);
                }
            }
        }
        out
    }

    struct EncoderCase {
        vid: i32,
        nsig: i32,
        bps: i32,
        spf: i32,
        nframes: i32,
        kinds: &'static [i32],
        size: usize,
        digest: &'static str,
        sum: u32,
    }

    const ENCODER_CASES: [EncoderCase; 6] = [
        EncoderCase {
            vid: 0,
            nsig: 2,
            bps: 16,
            spf: 1,
            nframes: 10000,
            kinds: &[0, 1],
            size: 26203,
            digest: "5495badb24f7c490c5484be5441c2f76",
            sum: 4257896572,
        },
        EncoderCase {
            vid: 1,
            nsig: 1,
            bps: 24,
            spf: 2,
            nframes: 6000,
            kinds: &[0],
            size: 11846,
            digest: "40596f848ca112518ce4d7c573aa9622",
            sum: 1739685865,
        },
        EncoderCase {
            vid: 2,
            nsig: 3,
            bps: 8,
            spf: 1,
            nframes: 7000,
            kinds: &[2, 0, 1],
            size: 11704,
            digest: "0efb1695c22420deb64837c433e39c61",
            sum: 5422484,
        },
        EncoderCase {
            vid: 3,
            nsig: 1,
            bps: 16,
            spf: 1,
            nframes: 100,
            kinds: &[0],
            size: 130,
            digest: "109b65398fce5e82b3817c267a879467",
            sum: 262406,
        },
        EncoderCase {
            vid: 4,
            nsig: 1,
            bps: 16,
            spf: 1,
            nframes: 300,
            kinds: &[3],
            size: 671,
            digest: "459bc9a342c66d4d1c720002dd7670e2",
            sum: 3379252398,
        },
        EncoderCase {
            vid: 5,
            nsig: 2,
            bps: 24,
            spf: 3,
            nframes: 3000,
            kinds: &[1, 2],
            size: 27782,
            digest: "25779b07efedeaadef4350bbb5148b01",
            sum: 4163323067,
        },
    ];

    /// Encode a complete stream as the WFDB library writes it (the final
    /// STREAMINFO block replaces the provisional one at offset 8).
    fn encode(nsig: i32, bps: i32, spf: i32, x: &[i32]) -> Vec<u8> {
        let mut enc = Encoder::new(nsig, bps, spf);
        let mut out = enc.header();
        for &v in x {
            enc.put(v, &mut out);
        }
        enc.finish(&mut out);
        let si = enc.streaminfo();
        out[8..8 + si.len()].copy_from_slice(&si);
        out
    }

    fn wrap(v: i32, bps: i32) -> i32 {
        let mask = (1u32 << bps) - 1;
        let half = 1u32 << (bps - 1);
        (((v as u32).wrapping_add(half) & mask) as i64 - half as i64) as i32
    }

    #[test]
    fn md5_vectors() {
        assert_eq!(md5_hex(b""), "d41d8cd98f00b204e9800998ecf8427e");
        assert_eq!(md5_hex(b"abc"), "900150983cd24fb0d6963f7d28e17f72");
        let v: Vec<u8> = (0..5).flat_map(|_| 0..=255u8).collect();
        assert_eq!(md5_hex(&v), "82829f1f3f2bb0f18b25f278e5bba8bd");
        // the same data in pieces of various sizes
        let mut m = Md5::new();
        let (mut pos, mut step) = (0, 1);
        while pos < v.len() {
            let k = step.min(v.len() - pos);
            m.update(&v[pos..pos + k]);
            pos += k;
            step = step * 3 + 1;
        }
        assert_eq!(hex(&m.digest()), "82829f1f3f2bb0f18b25f278e5bba8bd");
    }

    #[test]
    fn flac_decode_records() {
        for rc in &RECORDS {
            let data = std::fs::read(data_dir().join(format!("{}.dat", rc.name))).unwrap();
            let d = decode(&data, 0, 0);
            assert_eq!(d.status, Status::Ok, "{}", rc.name);
            assert_eq!(d.channels, rc.channels);
            assert_eq!(d.bps, rc.bps);
            assert_eq!(d.chans.len(), rc.channels as usize);
            assert_eq!(d.chans[0].len(), rc.nsamp);
            assert_eq!(samples_digest(&d.chans), rc.digest);
            assert_eq!(&d.chans[0][..3], &rc.first);
            assert_eq!(*d.chans.last().unwrap().last().unwrap(), rc.last);
            // The MD5 signature in STREAMINFO matches the decoded samples.
            assert!(d.has_md5);
            assert_eq!(samples_md5(&d.chans, d.bps), d.md5);
            // Decoding with the expected numbers of signals and bits
            let d2 = decode(&data, rc.channels, rc.bps);
            assert_eq!(d2.status, Status::Ok);
            assert_eq!(d2.chans, d.chans);
            // Trailing zero bytes are ignored.
            let mut padded = data.clone();
            padded.resize(padded.len() + 100, 0);
            let d3 = decode(&padded, 0, 0);
            assert_eq!(d3.status, Status::Ok);
            assert_eq!(d3.chans, d.chans);
            // A truncated stream cannot be decoded.
            assert_ne!(decode(&data[..data.len() - 3], 0, 0).status, Status::Ok);
            // Neither can a stream with a corrupted frame.
            let mut bad = data.clone();
            let mid = bad.len() / 2;
            bad[mid] ^= 0x10;
            assert_ne!(decode(&bad, 0, 0).status, Status::Ok);
            // nor something that is not a FLAC stream.
            assert_eq!(decode(&data[1..], 0, 0).status, Status::Meta);
        }
    }

    #[test]
    fn flac_encoder_matches_python() {
        for ec in &ENCODER_CASES {
            let x = gen(ec.vid, ec.nsig, ec.bps, ec.spf, ec.nframes, ec.kinds);
            let sum = x.iter().fold(0u32, |a, &v| a.wrapping_add(v as u32));
            assert_eq!(sum, ec.sum);
            let bytes = encode(ec.nsig, ec.bps, ec.spf, &x);
            assert_eq!(bytes.len(), ec.size, "case {}", ec.vid);
            assert_eq!(md5_hex(&bytes), ec.digest, "case {}", ec.vid);
            assert!(bytes.windows(6).any(|w| w == b"wfdb-x"));

            // Round trip
            let d = decode(&bytes, ec.nsig, ec.bps);
            assert_eq!(d.status, Status::Ok);
            assert_eq!(d.channels, ec.nsig);
            assert_eq!(d.bps, ec.bps);
            assert_eq!(d.chans.len(), ec.nsig as usize);
            let nper = (ec.nframes * ec.spf) as usize;
            let (nsig, spf) = (ec.nsig as usize, ec.spf as usize);
            for s in 0..nsig {
                assert_eq!(d.chans[s].len(), nper);
                for f in 0..ec.nframes as usize {
                    for k in 0..spf {
                        let i = (f * nsig + s) * spf + k;
                        assert_eq!(d.chans[s][f * spf + k], wrap(x[i], ec.bps));
                    }
                }
            }
            assert!(d.has_md5);
            assert_eq!(samples_md5(&d.chans, d.bps), d.md5);
        }
    }

    #[test]
    fn flac_encoder_incomplete_frame() {
        // Samples of an incomplete frame (fewer than nsig*spf) are not
        // written.
        let mut enc = Encoder::new(2, 16, 1);
        let mut out = enc.header();
        for i in 0..9 {
            enc.put(i * 100, &mut out);
        }
        enc.finish(&mut out);
        let si = enc.streaminfo();
        out[8..8 + si.len()].copy_from_slice(&si);
        let d = decode(&out, 0, 0);
        assert_eq!(d.status, Status::Ok);
        assert_eq!(d.chans.len(), 2);
        assert_eq!(d.chans[0].len(), 4);
        assert_eq!(d.chans[1][3], 700);
        // The wrong number of signals is detected when expected.
        let d2 = decode(&out, 3, 16);
        assert_eq!(d2.status, Status::Wfdb);
        assert_eq!(
            d2.error_message.as_deref(),
            Some(&b"getvec: wrong number of signals in FLAC signal file\n"[..])
        );
        let d3 = decode(&out, 2, 8);
        assert_eq!(d3.status, Status::Wfdb);
        assert_eq!(
            d3.error_message.as_deref(),
            Some(&b"getvec: wrong sample resolution in FLAC signal file\n"[..])
        );
    }
}
