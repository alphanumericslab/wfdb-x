//! FLAC decoder and encoder for the FLAC signal formats 508, 516 and 524
//! (port of `cpp/src/flac.cpp`).
//!
//! The C library uses libFLAC for these formats; WFDB-x implements, without
//! external libraries, a complete FLAC decoder (all subframe types, fixed and
//! LPC predictors, Rice and Rice2 partitions with escape codes, wasted bits,
//! stereo decorrelation, variable block sizes, CRC verification) and a
//! lossless encoder (fixed predictors and Rice coding). The encoder writes
//! exactly the bytes written by the Python and C++ implementations of WFDB-x
//! (standard FLAC streams; their compressed bytes differ from those written
//! by libFLAC, whose output depends on its version, but the decoded samples
//! are identical).
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// Its FLAC decoder is a Rust translation of the stream decoder of libFLAC
// 1.4.3 (src/libFLAC/stream_decoder.c and bitreader.c, and the restore
// functions of fixed.c and lpc.c), made so that damaged files are decoded,
// resynchronized and reported exactly as by the C library, which uses
// libFLAC.  Its FLAC encoder is WFDB-x's own implementation of the FLAC
// format; it has no counterpart in the original package.  WFDB-x needs no
// external library at run time.
//
// Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.
//
// libFLAC is distributed under the following license, which applies to the
// parts of this file translated from it (the stream decoder):
//
// Copyright (C) 2000-2009  Josh Coalson
// Copyright (C) 2011-2023  Xiph.Org Foundation
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
//
// - Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//
// - Redistributions in binary form must reproduce the above copyright
// notice, this list of conditions and the following disclaimer in the
// documentation and/or other materials provided with the distribution.
//
// - Neither the name of the Xiph.org Foundation nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE FOUNDATION OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
// LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
// NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

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
const METADATA_APPLICATION: u8 = 2;
const METADATA_SEEKTABLE: u8 = 3;
const METADATA_VORBIS_COMMENT: u8 = 4;
/// Length of the body of a STREAMINFO block.
const STREAMINFO_LEN: usize = 34;
/// The capacity of libFLAC's bit-reader buffer, in bytes.
const BR_CAPACITY: usize = 8192;
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

/// An error reported to [`Client::error`] (libFLAC's
/// `FLAC__StreamDecoderErrorStatus`); decoding goes on after it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum DecodeError {
    /// Lost sync.
    LostSync,
    /// Invalid frame header.
    BadHeader,
    /// Frame CRC mismatch.
    CrcMismatch,
    /// Unsupported format.
    Unparseable,
}

/// The state of a [`StreamDecoder`] (libFLAC's `FLAC__StreamDecoderState`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum State {
    SearchForMetadata,
    ReadMetadata,
    SearchForFrameSync,
    ReadFrame,
    EndOfStream,
    SeekError,
    Aborted,
    MemoryAllocationError,
}

/// The header of a decoded frame (FLAC block).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct FrameHeader {
    /// Samples per channel.
    pub blocksize: u32,
    pub sample_rate: u32,
    pub channels: u32,
    pub bits_per_sample: u32,
    /// The number of the first sample (per channel).
    pub sample_number: u64,
}

/// The receiver of the results of a [`StreamDecoder`] (the error and write
/// callbacks of libFLAC).
pub(crate) trait Client {
    /// An error in the stream (decoding goes on).
    fn error(&mut self, e: DecodeError);
    /// A decoded frame: the samples of each channel. Returns false to abort
    /// decoding.
    fn write(&mut self, h: &FrameHeader, chans: &[&[i32]]) -> bool;
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

/// Why a read within a frame stopped: the end of the stream (libFLAC's
/// read callback then sets the end-of-stream state), or an error in it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Fail {
    Eof,
    Error(DecodeError),
}

type R<T> = Result<T, Fail>;

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
                return Err(Fail::Error(DecodeError::Unparseable));
            }
            return Ok(0);
        }
        if self.pos + n as u64 > self.end {
            return Err(Fail::Eof);
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
                return Err(Fail::Eof);
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

    fn byte_pos(&self) -> usize {
        (self.pos >> 3) as usize
    }
}

/// Bits per sample of the frame header sample size codes (0: as in
/// STREAMINFO; 3: reserved).
const BPS_TABLE: [i32; 8] = [0, 8, 12, 0, 16, 20, 24, 32];

/// Sample rates of the frame header sample rate codes 1 to 11.
const SAMPLE_RATES: [u32; 12] = [
    0, 88200, 176400, 192000, 8000, 16000, 22050, 24000, 32000, 44100, 48000, 96000,
];

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

#[inline]
fn unfold(u: u64) -> i64 {
    if u & 1 != 0 {
        -((u >> 1) as i64) - 1
    } else {
        (u >> 1) as i64
    }
}

#[inline]
fn shl(x: i64, n: i32) -> i64 {
    ((x as u64) << n) as i64
}

/// The residual of a subframe (`read_residual_partitioned_rice_`), after
/// its coding method and partition order.
fn read_residual(bits: &mut Bits, blocksize: u32, order: usize, out: &mut Vec<i64>) -> R<()> {
    let method = bits.read(2)?;
    if method > 1 {
        return Err(Fail::Error(DecodeError::Unparseable));
    }
    let porder = bits.read(PARTITION_ORDER_BITS)? as u32;
    if ((blocksize >> porder) as usize) < order || blocksize % (1 << porder) > 0 {
        return Err(Fail::Error(DecodeError::LostSync));
    }
    let pbits = if method == 0 {
        RICE_PARAM_BITS
    } else {
        RICE2_PARAM_BITS
    };
    let esc: u64 = (1 << pbits) - 1;
    let psize = (blocksize >> porder) as usize;
    for part in 0..1usize << porder {
        let first = if part == 0 { order } else { 0 };
        let k = bits.read(pbits)?;
        if k < esc {
            let kk = k as i32;
            let start = bits.pos;
            for _ in first..psize {
                let v = bits.rice(kk)?;
                // (a quotient too large for a 32-bit residual is an invalid
                // symbol: libFLAC is then back at the start of the block)
                if kk > 0 && v > u32::MAX as u64 {
                    bits.pos = start;
                    return Err(Fail::Error(DecodeError::LostSync));
                }
                out.push(unfold(v & 0xffff_ffff));
            }
        } else {
            let nb = bits.read(5)? as i32;
            if nb == 0 {
                out.resize(out.len() + psize - first, 0);
            } else {
                for _ in first..psize {
                    out.push(bits.read_signed(nb)?);
                }
            }
        }
    }
    Ok(())
}

/// A subframe of `blocksize` samples of `bps` bits (`read_subframe_`).
fn read_subframe(bits: &mut Bits, blocksize: u32, bps: u32) -> R<Vec<i64>> {
    let x = bits.read(8)? as u32;
    let mut bps = bps as i32;
    let mut wasted = 0;
    if x & 1 != 0 {
        let u = bits.unary()?;
        if u + 1 >= bps as u64 {
            return Err(Fail::Error(DecodeError::LostSync));
        }
        wasted = u as i32 + 1;
        bps -= wasted;
    }
    let t = x & 0xfe;
    let bs = blocksize as usize;
    let mut s: Vec<i64>;
    if t & 0x80 != 0 {
        // (the zero bit before the subframe type)
        return Err(Fail::Error(DecodeError::LostSync));
    } else if t == (SUBFRAME_CONSTANT as u32) << 1 {
        let v = bits.read_signed(bps)?;
        s = vec![v; bs];
    } else if t == (SUBFRAME_VERBATIM as u32) << 1 {
        s = Vec::with_capacity(bs);
        for _ in 0..bs {
            s.push(bits.read_signed(bps)?);
        }
    } else if t < (SUBFRAME_FIXED as u32) << 1 {
        return Err(Fail::Error(DecodeError::Unparseable));
    } else if t <= ((SUBFRAME_FIXED + MAX_FIXED_ORDER as i32) as u32) << 1 {
        let order = ((t >> 1) & 7) as usize;
        if bs <= order {
            return Err(Fail::Error(DecodeError::LostSync));
        }
        s = Vec::with_capacity(bs);
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
    } else if t < (SUBFRAME_LPC as u32) << 1 {
        return Err(Fail::Error(DecodeError::Unparseable));
    } else {
        let order = (((t >> 1) & 31) + 1) as usize;
        if bs <= order {
            return Err(Fail::Error(DecodeError::LostSync));
        }
        s = Vec::with_capacity(bs);
        for _ in 0..order {
            s.push(bits.read_signed(bps)?);
        }
        let prec = bits.read(4)? as i32;
        if prec == 15 {
            // (precision code 15, all ones, is invalid)
            return Err(Fail::Error(DecodeError::LostSync));
        }
        let prec = prec + 1;
        let shift = bits.read_signed(5)? as i32;
        if shift < 0 {
            return Err(Fail::Error(DecodeError::LostSync));
        }
        let mut coefs = [0i64; MAX_LPC_ORDER];
        for c in coefs.iter_mut().take(order) {
            *c = bits.read_signed(prec)?;
        }
        let mut res = Vec::with_capacity(bs);
        read_residual(bits, blocksize, order, &mut res)?;
        for &r in &res {
            let base = s.len() - order;
            let mut acc = 0i64;
            // coefs[0] applies to the most recent sample
            for (j, &c) in coefs.iter().enumerate().take(order) {
                acc = acc.wrapping_add(c.wrapping_mul(s[base + order - 1 - j]));
            }
            s.push(r.wrapping_add(acc >> shift));
        }
    }
    if wasted != 0 {
        for x in &mut s {
            *x = shl(*x, wasted);
        }
    }
    Ok(s)
}

/// The body of a frame read by [`frame_body`].
struct FrameBody {
    /// The errors found, in order.
    errors: Vec<DecodeError>,
    /// Did the data end within the frame?
    eof: bool,
    /// The samples of each channel (None if the frame is not valid).
    chans: Option<Vec<Vec<i32>>>,
    /// The offset of the end of the frame (if valid).
    end: usize,
    /// The offset of the end of the bytes read (the end of the data if
    /// they end within the frame).
    reached: usize,
}

/// The subframes and footer of a frame that starts at `start`, from `pos`
/// (after its header), as `read_frame_` reads them.
fn frame_body(
    data: &[u8],
    start: usize,
    pos: usize,
    h: &FrameHeader,
    assignment: i32,
) -> FrameBody {
    let mut body = FrameBody {
        errors: Vec::new(),
        eof: false,
        chans: None,
        end: pos,
        reached: data.len(),
    };
    let mut bits = Bits::new(data, pos);
    let mut subframes: Vec<Vec<i64>> = Vec::with_capacity(h.channels as usize);
    let mut ok = true;
    for c in 0..h.channels {
        // (the side channel has one bit more)
        let side = match assignment {
            CHANNELS_LEFT_SIDE | CHANNELS_MID_SIDE => c == 1,
            CHANNELS_SIDE_RIGHT => c == 0,
            _ => false,
        };
        match read_subframe(&mut bits, h.blocksize, h.bits_per_sample + side as u32) {
            Ok(s) => subframes.push(s),
            Err(Fail::Eof) => {
                body.eof = true;
                return body;
            }
            Err(Fail::Error(e)) => {
                body.errors.push(e);
                ok = false;
                break;
            }
        }
    }
    // The zero padding to a byte boundary.
    let n = ((8 - bits.pos % 8) % 8) as i32;
    let padding = if n > 0 { bits.read(n) } else { Ok(0) };
    if padding != Err(Fail::Eof) {
        body.reached = ((bits.pos + 7) / 8) as usize;
    }
    if padding != Ok(0) {
        body.errors.push(DecodeError::LostSync);
        return body;
    }
    if !ok {
        return body;
    }
    let fend = bits.byte_pos();
    let Ok(c16) = bits.read(16) else {
        body.eof = true;
        return body;
    };
    body.reached = bits.byte_pos();
    if crc16(&data[start..fend]) != c16 as u32 {
        body.errors.push(DecodeError::CrcMismatch);
        return body;
    }
    // Undo the stereo decorrelation.
    let bs = h.blocksize as usize;
    let mut chans: Vec<Vec<i32>> = Vec::with_capacity(subframes.len());
    match assignment {
        CHANNELS_LEFT_SIDE => {
            let (a, sd) = (&subframes[0], &subframes[1]);
            chans.push(a.iter().map(|&x| x as i32).collect());
            chans.push((0..bs).map(|i| a[i].wrapping_sub(sd[i]) as i32).collect());
        }
        CHANNELS_SIDE_RIGHT => {
            let (sd, b) = (&subframes[0], &subframes[1]);
            chans.push((0..bs).map(|i| sd[i].wrapping_add(b[i]) as i32).collect());
            chans.push(b.iter().map(|&x| x as i32).collect());
        }
        CHANNELS_MID_SIDE => {
            let (mid, sd) = (&subframes[0], &subframes[1]);
            let mut le = Vec::with_capacity(bs);
            let mut ri = Vec::with_capacity(bs);
            for i in 0..bs {
                let x = shl(mid[i], 1) | (sd[i] & 1);
                le.push((x.wrapping_add(sd[i]) >> 1) as i32);
                ri.push((x.wrapping_sub(sd[i]) >> 1) as i32);
            }
            chans.push(le);
            chans.push(ri);
        }
        _ => {
            for s in &subframes {
                chans.push(s.iter().map(|&x| x as i32).collect());
            }
        }
    }
    // The decoded samples must fit in bits_per_sample bits.
    let shift = 32 - h.bits_per_sample;
    let (lo, hi) = (i32::MIN >> shift, i32::MAX >> shift);
    if chans.iter().any(|c| c.iter().any(|&v| v < lo || v > hi)) {
        body.errors.push(DecodeError::CrcMismatch);
        return body;
    }
    body.chans = Some(chans);
    body.end = bits.byte_pos();
    body
}

/// A seek point of a SEEKTABLE metadata block.
#[derive(Clone, Copy, Debug)]
struct SeekPoint {
    sample_number: u64,
    stream_offset: u64,
    frame_samples: u32,
}

/// The first bytes of an ID3v2 tag, and the marker of a FLAC stream.
const ID3V2_TAG: &[u8] = b"ID3";
/// Value of a placeholder seek point.
const SEEKPOINT_PLACEHOLDER: u64 = u64::MAX;
/// Length of the ID of an APPLICATION metadata block.
const APPLICATION_ID_LEN: usize = 4;
/// Length of a seek point.
const SEEKPOINT_LEN: usize = 18;

/// A FLAC stream decoder that decodes as libFLAC's stream decoder does,
/// frame by frame, with the same results, errors and states, from a stream
/// held in memory: it finds the metadata (after an ID3v2 tag, if any),
/// reads STREAMINFO and SEEKTABLE, then decodes one frame (FLAC block) at a
/// time; a damaged frame is reported to the client and skipped (decoding
/// goes on at the next frame sync code), and [`StreamDecoder::seek_absolute`]
/// seeks as libFLAC does (a bisection on the stream). The client receives
/// the errors and the decoded frames ([`Client`]).
pub(crate) struct StreamDecoder {
    data: Vec<u8>,
    /// The offset of the next byte to read.
    pos: usize,
    /// Can the stream seek (C: the signal group's `seek`)?
    seekable: bool,
    state: State,
    /// The two bytes of the frame sync code of the frame being read, and
    /// the offset that follows them.
    warmup: [u8; 2],
    framesync: usize,
    /// libFLAC's bit-reader buffer: it holds the bytes of the stream from
    /// offset `bstart` up to `bend` (excluded; `bend` is the position of
    /// the client). `fsloc`: does it still hold the frame sync code found
    /// by `frame_sync_` (C: the bit reader's `last_seen_framesync`)?
    bstart: usize,
    bend: usize,
    fsloc: bool,
    /// The position after the last frame sync code found by `frame_sync_`
    /// (0 if none, or if the stream cannot seek).
    last_seen_framesync: u64,
    has_stream_info: bool,
    min_blocksize: u32,
    max_blocksize: u32,
    min_framesize: u32,
    max_framesize: u32,
    si_sample_rate: u32,
    si_channels: u32,
    si_bps: u32,
    total_samples: u64,
    md5sum: [u8; MD5_LEN],
    seek_table: Option<Vec<SeekPoint>>,
    first_frame_offset: u64,
    fixed_block_size: u32,
    next_fixed_block_size: u32,
    samples_decoded: u64,
    /// Channels and bits per sample of the last frame decoded (0: none).
    channels: u32,
    bps: u32,
    last_frame: FrameHeader,
    last_frame_is_set: bool,
    is_seeking: bool,
    target_sample: u64,
    do_md5_checking: bool,
    md5ctx: Md5,
}

impl StreamDecoder {
    /// A decoder of the stream `data`, at its start (`FLAC__stream_decoder_init_stream`).
    pub(crate) fn new(data: Vec<u8>, seekable: bool, md5_checking: bool) -> StreamDecoder {
        StreamDecoder {
            data,
            pos: 0,
            seekable,
            state: State::SearchForMetadata,
            warmup: [0; 2],
            framesync: 0,
            bstart: 0,
            bend: 0,
            fsloc: false,
            last_seen_framesync: 0,
            has_stream_info: false,
            min_blocksize: 0,
            max_blocksize: 0,
            min_framesize: 0,
            max_framesize: 0,
            si_sample_rate: 0,
            si_channels: 0,
            si_bps: 0,
            total_samples: 0,
            md5sum: [0; MD5_LEN],
            seek_table: None,
            first_frame_offset: 0,
            fixed_block_size: 0,
            next_fixed_block_size: 0,
            samples_decoded: 0,
            channels: 0,
            bps: 0,
            last_frame: FrameHeader::default(),
            last_frame_is_set: false,
            is_seeking: false,
            target_sample: 0,
            do_md5_checking: md5_checking,
            md5ctx: Md5::new(),
        }
    }

    pub(crate) fn state(&self) -> State {
        self.state
    }

    /// The total number of samples (per channel) given by STREAMINFO (0 if
    /// unknown).
    pub(crate) fn total_samples(&self) -> u64 {
        if self.has_stream_info {
            self.total_samples
        } else {
            0
        }
    }

    /// `FLAC__stream_decoder_finish`: false if the MD5 signature of the
    /// decoded samples was checked and differs from that of STREAMINFO.
    pub(crate) fn finish(&mut self) -> bool {
        let computed = self.md5ctx.digest();
        !(self.do_md5_checking && computed != self.md5sum)
    }

    /// `FLAC__stream_decoder_flush`.
    pub(crate) fn flush(&mut self) {
        self.samples_decoded = 0;
        self.do_md5_checking = false;
        self.last_seen_framesync = 0;
        self.last_frame_is_set = false;
        self.br_clear();
        self.state = State::SearchForFrameSync;
    }

    /// `FLAC__bitreader_clear`: empties the bit-reader buffer (the next byte
    /// read is that at the position of the client, `pos`).
    fn br_clear(&mut self) {
        self.bstart = self.pos;
        self.bend = self.pos;
        self.fsloc = false;
    }

    /// `bitreader_read_from_client_`, as often as libFLAC calls it to read
    /// up to the offset `end`, when the reader is at the offset `p`: the
    /// whole words before `p` leave the buffer, and it is filled up.
    fn br_fill(&mut self, p: usize, end: usize) {
        let end = end.min(self.data.len());
        while self.bend < end {
            let words = p.min(self.bend).saturating_sub(self.bstart) / 8;
            if words > 0 {
                self.fsloc = false;
                self.bstart += 8 * words;
            }
            let room = BR_CAPACITY - (self.bend - self.bstart);
            if room == 0 {
                break;
            }
            self.bend += room.min(self.data.len() - self.bend);
        }
    }

    fn send_error(&self, client: &mut dyn Client, e: DecodeError) {
        // (not reported while seeking)
        if !self.is_seeking {
            client.error(e);
        }
    }

    /// The next byte (None at the end of the stream, which ends decoding).
    fn byte(&mut self) -> Option<u8> {
        self.br_fill(self.pos, self.pos + 1);
        match self.data.get(self.pos) {
            Some(&b) => {
                self.pos += 1;
                Some(b)
            }
            None => {
                self.state = State::EndOfStream;
                None
            }
        }
    }

    /// Skips `n` bytes (false at the end of the stream).
    fn skip(&mut self, n: usize) -> bool {
        // (libFLAC skips whole words of its buffer at a time)
        self.br_fill(usize::MAX, self.pos.saturating_add(n));
        if n > self.data.len() - self.pos {
            self.pos = self.data.len();
            self.state = State::EndOfStream;
            return false;
        }
        self.pos += n;
        true
    }

    /// The big-endian value of the next `n` bytes.
    fn bytes(&mut self, n: usize) -> Option<u64> {
        // (libFLAC reads them at once)
        self.br_fill(self.pos, self.pos + n);
        let mut v = 0u64;
        for _ in 0..n {
            v = (v << 8) | self.byte()? as u64;
        }
        Some(v)
    }

    /// `FLAC__stream_decoder_get_decode_position`.
    fn decode_position(&self) -> Option<u64> {
        self.seekable.then_some(self.pos as u64)
    }

    /// `FLAC__stream_decoder_process_single`: decodes one metadata block or
    /// one frame; false on a fatal error (the state tells which).
    pub(crate) fn process_single(&mut self, client: &mut dyn Client) -> bool {
        loop {
            match self.state {
                State::SearchForMetadata => {
                    if !self.find_metadata(client) {
                        return false;
                    }
                }
                State::ReadMetadata => return self.read_metadata(),
                State::SearchForFrameSync => {
                    if !self.frame_sync(client) {
                        return true;
                    }
                }
                State::ReadFrame => match self.read_frame(client) {
                    Err(()) => return false,
                    Ok(true) => return true,
                    Ok(false) => {}
                },
                State::EndOfStream | State::Aborted => return true,
                State::SeekError | State::MemoryAllocationError => return false,
            }
        }
    }

    /// `FLAC__stream_decoder_process_until_end_of_metadata`.
    fn process_until_end_of_metadata(&mut self, client: &mut dyn Client) -> bool {
        loop {
            match self.state {
                State::SearchForMetadata => {
                    if !self.find_metadata(client) {
                        return false;
                    }
                }
                State::ReadMetadata => {
                    if !self.read_metadata() {
                        return false;
                    }
                }
                State::SearchForFrameSync
                | State::ReadFrame
                | State::EndOfStream
                | State::Aborted => return true,
                State::SeekError | State::MemoryAllocationError => return false,
            }
        }
    }

    /// `find_metadata_`: the `fLaC` marker (after an ID3v2 tag, if any),
    /// or a frame sync code.
    fn find_metadata(&mut self, client: &mut dyn Client) -> bool {
        let (mut i, mut id, mut first) = (0, 0, true);
        while i < MARKER.len() {
            let Some(x) = self.byte() else {
                return false;
            };
            if x == MARKER[i] {
                first = true;
                i += 1;
                id = 0;
                continue;
            }
            if id >= ID3V2_TAG.len() {
                return false;
            }
            if x == ID3V2_TAG[id] {
                id += 1;
                i = 0;
                if id == ID3V2_TAG.len() && !self.skip_id3v2_tag() {
                    return false;
                }
                continue;
            }
            id = 0;
            if x == 0xff {
                self.warmup[0] = x;
                let Some(y) = self.byte() else {
                    return false;
                };
                if y == 0xff {
                    self.pos -= 1; // (it may begin a sync code)
                } else if y >> 1 == 0x7c {
                    self.warmup[1] = y;
                    self.framesync = self.pos;
                    self.state = State::ReadFrame;
                    return true;
                }
            }
            i = 0;
            if first {
                self.send_error(client, DecodeError::LostSync);
                first = false;
            }
        }
        self.state = State::ReadMetadata;
        true
    }

    /// `skip_id3v2_tag_`.
    fn skip_id3v2_tag(&mut self) -> bool {
        // the version and flags, then the size (7 bits per byte)
        if self.bytes(3).is_none() {
            return false;
        }
        let mut n = 0usize;
        for _ in 0..4 {
            let Some(x) = self.byte() else {
                return false;
            };
            n = (n << 7) | (x & 0x7f) as usize;
        }
        self.skip(n)
    }

    /// `read_metadata_`: one metadata block. Blocks other than STREAMINFO
    /// and SEEKTABLE are skipped.
    fn read_metadata(&mut self) -> bool {
        // (libFLAC reads the last-block flag and the type, then the length)
        self.br_fill(self.pos, self.pos + 1);
        self.br_fill(self.pos + 1, self.pos + METADATA_HEADER_LEN);
        let Some(hdr) = self.bytes(METADATA_HEADER_LEN) else {
            return false;
        };
        let is_last = hdr & 0x8000_0000 != 0;
        let kind = ((hdr >> 24) & 0x7f) as u8;
        let length = (hdr & 0xff_ffff) as usize;
        if kind == METADATA_STREAMINFO {
            // (libFLAC reads the fields one at a time, then the MD5
            // signature as a block)
            let p = self.pos;
            for (from, to) in [
                (0, 2),
                (2, 4),
                (4, 7),
                (7, 10),
                (10, 13),
                (12, 13),
                (12, 14),
                (13, 18),
            ] {
                self.br_fill(p + from, p + to);
            }
            self.br_fill(usize::MAX, p + STREAMINFO_LEN);
            let Some(b) = self.data.get(self.pos..self.pos + STREAMINFO_LEN) else {
                self.skip(STREAMINFO_LEN);
                return false;
            };
            let mut r = Bits::new(b, 0);
            let mut f = |n: i32| r.read_long(n).unwrap_or(0);
            self.min_blocksize = f(16) as u32;
            self.max_blocksize = f(16) as u32;
            self.min_framesize = f(24) as u32;
            self.max_framesize = f(24) as u32;
            self.si_sample_rate = f(20) as u32;
            self.si_channels = f(3) as u32 + 1;
            self.si_bps = f(5) as u32 + 1;
            self.total_samples = f(36);
            self.md5sum
                .copy_from_slice(&b[STREAMINFO_MD5_POS..STREAMINFO_MD5_POS + MD5_LEN]);
            self.pos += STREAMINFO_LEN;
            if length < STREAMINFO_LEN || !self.skip(length - STREAMINFO_LEN) {
                return false;
            }
            self.has_stream_info = true;
            if self.md5sum == [0; MD5_LEN] {
                self.do_md5_checking = false;
            }
        } else if kind == METADATA_SEEKTABLE {
            self.seek_table = None;
            if length > 0 {
                if length % SEEKPOINT_LEN != 0 {
                    return false;
                }
                let mut points = Vec::with_capacity(length / SEEKPOINT_LEN);
                for _ in 0..length / SEEKPOINT_LEN {
                    let (Some(sample_number), Some(stream_offset), Some(frame_samples)) =
                        (self.bytes(8), self.bytes(8), self.bytes(2))
                    else {
                        return false;
                    };
                    points.push(SeekPoint {
                        sample_number,
                        stream_offset,
                        frame_samples: frame_samples as u32,
                    });
                }
                self.seek_table = Some(points);
            }
        } else {
            // (an APPLICATION block begins with its 4-byte ID, which
            // libFLAC reads first: a shorter block is an error)
            let mut length = length;
            if kind == METADATA_APPLICATION {
                if !self.skip(APPLICATION_ID_LEN) {
                    return false;
                }
                if length < APPLICATION_ID_LEN {
                    self.state = State::MemoryAllocationError;
                    return false;
                }
                length -= APPLICATION_ID_LEN;
            }
            if !self.skip(length) {
                return false;
            }
        }
        if is_last {
            self.first_frame_offset = self.decode_position().unwrap_or(0);
            self.state = State::SearchForFrameSync;
        }
        true
    }

    /// `frame_sync_`: finds the next frame sync code (false at the end of
    /// the stream).
    fn frame_sync(&mut self, client: &mut dyn Client) -> bool {
        let mut first = true;
        loop {
            let Some(x) = self.byte() else {
                return false;
            };
            if x == 0xff {
                self.warmup[0] = x;
                let Some(y) = self.byte() else {
                    return false;
                };
                if y == 0xff {
                    self.pos -= 1; // (it may begin a sync code)
                } else if y >> 1 == 0x7c {
                    self.warmup[1] = y;
                    self.framesync = self.pos;
                    self.fsloc = true;
                    self.last_seen_framesync = self.decode_position().unwrap_or(0);
                    self.state = State::ReadFrame;
                    return true;
                }
            }
            if first {
                self.send_error(client, DecodeError::LostSync);
                first = false;
            }
        }
    }

    /// `FLAC__bitreader_read_utf8_uint32` (`wide`: `_uint64`): the frame or
    /// sample number of a frame header (None at the end of the stream;
    /// u64::MAX if the coding is invalid). The bytes read go into `raw`.
    fn read_utf8(&mut self, raw: &mut Vec<u8>, wide: bool) -> Option<u64> {
        let x = self.byte()?;
        raw.push(x);
        let (mut v, n) = if x & 0x80 == 0 {
            (x as u64, 0)
        } else if x & 0xc0 != 0 && x & 0x20 == 0 {
            ((x & 0x1f) as u64, 1)
        } else if x & 0xe0 != 0 && x & 0x10 == 0 {
            ((x & 0x0f) as u64, 2)
        } else if x & 0xf0 != 0 && x & 0x08 == 0 {
            ((x & 0x07) as u64, 3)
        } else if x & 0xf8 != 0 && x & 0x04 == 0 {
            ((x & 0x03) as u64, 4)
        } else if x & 0xfc != 0 && x & 0x02 == 0 {
            ((x & 0x01) as u64, 5)
        } else if wide && x & 0xfe != 0 && x & 0x01 == 0 {
            (0, 6)
        } else {
            return Some(u64::MAX);
        };
        for _ in 0..n {
            let y = self.byte()?;
            raw.push(y);
            if y & 0x80 == 0 || y & 0x40 != 0 {
                return Some(u64::MAX);
            }
            v = (v << 6) | (y & 0x3f) as u64;
        }
        Some(v)
    }

    /// A bad frame header: `undo` puts back the last byte read (libFLAC's
    /// lookahead byte).
    fn bad_header(
        &mut self,
        client: &mut dyn Client,
        undo: bool,
    ) -> Result<Option<(FrameHeader, i32)>, ()> {
        if undo {
            self.pos -= 1;
        }
        self.send_error(client, DecodeError::BadHeader);
        self.state = State::SearchForFrameSync;
        Ok(None)
    }

    /// `read_frame_header_`: the header and channel assignment of a frame
    /// (None if the header is not valid; Err at the end of the stream).
    fn read_frame_header(
        &mut self,
        client: &mut dyn Client,
    ) -> Result<Option<(FrameHeader, i32)>, ()> {
        let mut raw: Vec<u8> = self.warmup.to_vec();
        let mut h = FrameHeader::default();
        // (the reserved bit after the sync code)
        let mut unparseable = raw[1] & 0x02 != 0;
        for _ in 0..2 {
            let x = self.byte().ok_or(())?;
            if x == 0xff {
                // (a sync code cannot appear in a header)
                return self.bad_header(client, true);
            }
            raw.push(x);
        }
        let bsc = (raw[2] >> 4) as i32;
        let mut blocksize_hint = 0;
        match bsc {
            0 => unparseable = true,
            BLOCKSIZE_CODE_8BIT | BLOCKSIZE_CODE_16BIT => blocksize_hint = bsc,
            _ => h.blocksize = block_size_code(bsc) as u32,
        }
        let src = (raw[2] & 0x0f) as i32;
        let mut sample_rate_hint = 0;
        match src {
            0 => {
                if self.has_stream_info {
                    h.sample_rate = self.si_sample_rate;
                } else {
                    unparseable = true;
                }
            }
            1..=11 => h.sample_rate = SAMPLE_RATES[src as usize],
            12..=14 => sample_rate_hint = src,
            _ => return self.bad_header(client, false),
        }
        let chc = (raw[3] >> 4) as i32;
        let assignment = chc;
        if chc & 8 != 0 {
            h.channels = 2;
            if chc > CHANNELS_MID_SIDE {
                unparseable = true;
            }
        } else {
            h.channels = chc as u32 + 1;
        }
        let ssc = ((raw[3] & 0x0e) >> 1) as usize;
        if ssc == 0 {
            if self.has_stream_info {
                h.bits_per_sample = self.si_bps;
            } else {
                unparseable = true;
            }
        } else if BPS_TABLE[ssc] != 0 {
            h.bits_per_sample = BPS_TABLE[ssc] as u32;
        } else {
            unparseable = true;
        }
        if raw[3] & 0x01 != 0 {
            unparseable = true;
        }
        // The frame number, or the sample number (variable block size).
        let variable = raw[1] & 0x01 != 0
            || (self.has_stream_info && self.min_blocksize != self.max_blocksize);
        let number = self.read_utf8(&mut raw, variable).ok_or(())?;
        if number == u64::MAX || (!variable && number == u32::MAX as u64) {
            return self.bad_header(client, true);
        }
        if blocksize_hint != 0 {
            let mut x = self.byte().ok_or(())? as u32;
            raw.push(x as u8);
            if blocksize_hint == BLOCKSIZE_CODE_16BIT {
                let y = self.byte().ok_or(())?;
                raw.push(y);
                x = (x << 8) | y as u32;
            }
            h.blocksize = x + 1;
            if h.blocksize > 65535 {
                return self.bad_header(client, true);
            }
        }
        if sample_rate_hint != 0 {
            let mut x = self.byte().ok_or(())? as u32;
            raw.push(x as u8);
            if sample_rate_hint != 12 {
                let y = self.byte().ok_or(())?;
                raw.push(y);
                x = (x << 8) | y as u32;
            }
            h.sample_rate = match sample_rate_hint {
                12 => x * 1000,
                13 => x,
                _ => x * 10,
            };
        }
        let crc = self.byte().ok_or(())?;
        if crc8(&raw) != crc as u32 {
            return self.bad_header(client, false);
        }
        self.next_fixed_block_size = 0;
        if variable {
            h.sample_number = number;
        } else if self.fixed_block_size != 0 {
            h.sample_number = self.fixed_block_size as u64 * number;
        } else if self.has_stream_info {
            if self.min_blocksize == self.max_blocksize {
                h.sample_number = self.min_blocksize as u64 * number;
                self.next_fixed_block_size = self.max_blocksize;
            } else {
                unparseable = true;
            }
        } else if number == 0 {
            h.sample_number = 0;
            self.next_fixed_block_size = h.blocksize;
        } else {
            h.sample_number = h.blocksize as u64 * number;
        }
        if unparseable {
            self.send_error(client, DecodeError::Unparseable);
            self.state = State::SearchForFrameSync;
            return Ok(None);
        }
        Ok(Some((h, assignment)))
    }

    /// `read_frame_`: one frame, after its sync code. Ok(true) if a frame was
    /// decoded (and given to the client), Ok(false) if not (the decoder
    /// searches for the next frame), Err on a fatal error.
    fn read_frame(&mut self, client: &mut dyn Client) -> Result<bool, ()> {
        let start = self.framesync - 2;
        let Some((h, assignment)) = self.read_frame_header(client)? else {
            return Ok(false);
        };
        let body = frame_body(&self.data, start, self.pos, &h, assignment);
        // (the bytes libFLAC reads into its buffer to decode it)
        self.br_fill(usize::MAX, body.reached);
        for &e in &body.errors {
            self.send_error(client, e);
        }
        let mut got = false;
        if body.eof {
            self.state = State::EndOfStream;
        } else if let Some(chans) = body.chans {
            self.pos = body.end;
            // Missing frames are replaced by silence.
            if self.last_frame_is_set && !self.is_seeking {
                let last = self.last_frame;
                let end = last.sample_number + last.blocksize as u64;
                if end < h.sample_number
                    && last.sample_rate == h.sample_rate
                    && last.channels == h.channels
                    && last.bits_per_sample == h.bits_per_sample
                    && last.blocksize >= 16
                {
                    let mut need = h.sample_number - end;
                    need = need
                        .min(5 * last.sample_rate as u64)
                        .min(50 * last.blocksize as u64);
                    let mut e = last;
                    let zeros = vec![0i32; last.blocksize as usize];
                    while need > 0 {
                        e.sample_number += e.blocksize as u64;
                        if need < e.blocksize as u64 {
                            e.blocksize = need as u32;
                        }
                        need -= e.blocksize as u64;
                        self.samples_decoded = e.sample_number + e.blocksize as u64;
                        let z: Vec<&[i32]> = (0..e.channels)
                            .map(|_| &zeros[..e.blocksize as usize])
                            .collect();
                        if !self.write_frame(client, &e, &z) {
                            self.state = State::Aborted;
                            return Err(());
                        }
                    }
                }
            }
            got = true;
            if self.next_fixed_block_size != 0 {
                self.fixed_block_size = self.next_fixed_block_size;
            }
            self.channels = h.channels;
            self.bps = h.bits_per_sample;
            self.samples_decoded = h.sample_number + h.blocksize as u64;
            let refs: Vec<&[i32]> = chans.iter().map(|c| &c[..]).collect();
            if !self.write_frame(client, &h, &refs) {
                self.state = State::Aborted;
                return Err(());
            }
        }
        if !got {
            // Damaged frame: go back to just after its sync code, if the
            // bit-reader buffer still holds it; if not (or if the frame was
            // found while looking for the metadata), to the start of the
            // buffer, or to the last sync code found by frame_sync_.
            if self.fsloc {
                self.pos = self.framesync + 1;
            } else if self.last_seen_framesync != 0 {
                self.pos = self.last_seen_framesync as usize;
                self.br_clear();
            } else {
                self.pos = self.bstart;
            }
        }
        self.state = State::SearchForFrameSync;
        Ok(got)
    }

    /// `write_audio_frame_to_client_`.
    fn write_frame(&mut self, client: &mut dyn Client, h: &FrameHeader, chans: &[&[i32]]) -> bool {
        self.last_frame = *h;
        self.last_frame_is_set = true;
        if self.is_seeking {
            let this = h.sample_number;
            let next = this + h.blocksize as u64;
            let target = self.target_sample;
            if this <= target && target < next {
                // the target frame: from the target sample on
                let delta = (target - this) as usize;
                self.is_seeking = false;
                let mut h2 = *h;
                h2.blocksize -= delta as u32;
                h2.sample_number += delta as u64;
                if delta > 0 {
                    self.last_frame = h2;
                }
                let refs: Vec<&[i32]> = chans.iter().map(|c| &c[delta..]).collect();
                return client.write(&h2, &refs);
            }
            return true;
        }
        if !self.has_stream_info {
            self.do_md5_checking = false;
        }
        if self.do_md5_checking {
            let nb = ((h.bits_per_sample + 7) / 8) as usize;
            let mut buf = Vec::with_capacity(h.blocksize as usize * chans.len() * nb);
            for i in 0..h.blocksize as usize {
                for c in chans {
                    buf.extend_from_slice(&c[i].to_le_bytes()[..nb]);
                }
            }
            self.md5ctx.update(&buf);
        }
        client.write(h, chans)
    }

    /// `FLAC__stream_decoder_seek_absolute`: seeks to sample `sample`; the
    /// client then receives the frame that holds it, from that sample on.
    pub(crate) fn seek_absolute(&mut self, sample: u64, client: &mut dyn Client) -> bool {
        if !matches!(
            self.state,
            State::SearchForMetadata
                | State::ReadMetadata
                | State::SearchForFrameSync
                | State::ReadFrame
                | State::EndOfStream
        ) {
            return false;
        }
        if self.total_samples() > 0 && sample >= self.total_samples() {
            return false;
        }
        self.is_seeking = true;
        self.do_md5_checking = false;
        if !self.seekable {
            self.is_seeking = false;
            return false;
        }
        if matches!(self.state, State::SearchForMetadata | State::ReadMetadata) {
            if !self.process_until_end_of_metadata(client) {
                self.is_seeking = false;
                return false;
            }
            if self.total_samples() > 0 && sample >= self.total_samples() {
                self.is_seeking = false;
                return false;
            }
        }
        let ok = self.seek_to_sample(sample, client);
        self.is_seeking = false;
        ok
    }

    /// `seek_to_absolute_sample_`: a bisection on the stream.
    fn seek_to_sample(&mut self, target: u64, client: &mut dyn Client) -> bool {
        let stream_length = self.data.len() as u64;
        let total = self.total_samples();
        let (min_bs, max_bs) = (self.min_blocksize, self.max_blocksize);
        let (min_fs, max_fs) = (self.min_framesize, self.max_framesize);
        let channels = if self.channels == 0 {
            self.si_channels
        } else {
            self.channels
        };
        let bps = if self.bps == 0 { self.si_bps } else { self.bps };
        let mut approx: u32 = if max_fs > 0 {
            (max_fs.wrapping_add(min_fs)) / 2 + 1
        } else if min_bs == max_bs && min_bs > 0 {
            min_bs.wrapping_mul(channels).wrapping_mul(bps) / 8 + 64
        } else {
            (4096u32.wrapping_mul(channels).wrapping_mul(bps)) / 8 + 64
        };
        let mut lower_bound = self.first_frame_offset;
        let mut lower_bound_sample = 0u64;
        let mut upper_bound = stream_length;
        let mut upper_bound_sample = if total > 0 { total } else { target };
        if self.state == State::SearchForFrameSync && self.samples_decoded != 0 {
            if target < self.samples_decoded {
                if let Some(p) = self.decode_position() {
                    upper_bound = p;
                    upper_bound_sample = self.samples_decoded;
                }
            } else if let Some(p) = self.decode_position() {
                lower_bound = p;
                lower_bound_sample = self.samples_decoded;
            }
        }
        if let Some(table) = &self.seek_table {
            let usable = |p: &SeekPoint| {
                p.sample_number != SEEKPOINT_PLACEHOLDER
                    && p.frame_samples > 0
                    && (total == 0 || p.sample_number < total)
            };
            let (mut nlb, mut nub, mut nlbs, mut nubs) = (
                lower_bound,
                upper_bound,
                lower_bound_sample,
                upper_bound_sample,
            );
            if let Some(p) = table
                .iter()
                .rev()
                .find(|p| usable(p) && p.sample_number <= target)
            {
                nlb = self.first_frame_offset.wrapping_add(p.stream_offset);
                nlbs = p.sample_number;
            }
            if let Some(p) = table.iter().find(|p| usable(p) && p.sample_number > target) {
                nub = self.first_frame_offset.wrapping_add(p.stream_offset);
                nubs = p.sample_number;
            }
            if nub >= nlb {
                lower_bound = nlb;
                upper_bound = nub;
                lower_bound_sample = nlbs;
                upper_bound_sample = nubs;
            }
        }
        if upper_bound_sample == lower_bound_sample {
            upper_bound_sample += 1;
        }
        self.target_sample = target;
        let (mut first_seek, mut seek_from_lower_bound) = (true, false);
        loop {
            if matches!(self.state, State::Aborted | State::MemoryAllocationError) {
                return false;
            }
            if lower_bound_sample >= upper_bound_sample
                || lower_bound > upper_bound
                || upper_bound >= i64::MAX as u64
            {
                self.state = State::SeekError;
                return false;
            }
            let mut pos: i64 = if seek_from_lower_bound {
                lower_bound as i64
            } else {
                lower_bound as i64
                    + ((target - lower_bound_sample) as f64
                        / (upper_bound_sample - lower_bound_sample) as f64
                        * (upper_bound - lower_bound) as f64) as i64
                    - approx as i64
            };
            if pos >= upper_bound as i64 {
                pos = upper_bound as i64 - 1;
            }
            if pos < lower_bound as i64 {
                pos = lower_bound as i64;
            }
            self.pos = (pos as u64).min(stream_length) as usize;
            self.flush();
            if !self.process_single(client)
                || self.state == State::Aborted
                || self.samples_decoded == 0
            {
                // No frame could be decoded: at the end of the stream, try
                // once from the lower bound.
                if self.state != State::Aborted && !seek_from_lower_bound {
                    seek_from_lower_bound = true;
                    continue;
                }
                self.state = State::SeekError;
                return false;
            }
            seek_from_lower_bound = false;
            if !self.is_seeking {
                return true;
            }
            let this = self.last_frame.sample_number;
            let bs = self.last_frame.blocksize as u64;
            if this + bs >= upper_bound_sample && !first_seek {
                if pos == lower_bound as i64 {
                    self.state = State::SeekError;
                    return false;
                }
                approx = if approx != 0 {
                    approx.wrapping_mul(2)
                } else {
                    16
                };
                continue;
            }
            first_seek = false;
            if this < lower_bound_sample {
                self.state = State::SeekError;
                return false;
            }
            let p = self.pos as u64;
            if target < this {
                upper_bound_sample = this + bs;
                upper_bound = p;
                approx = (2 * (upper_bound as i64 - pos) / 3 + 16) as u32;
            } else {
                lower_bound_sample = this + bs;
                lower_bound = p;
                approx = (2 * (lower_bound as i64 - pos) / 3 + 16) as u32;
            }
        }
    }
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
#[cfg(test)]
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

    /// A whole stream decoded frame by frame (as the C library would read it,
    /// but going on after errors).
    #[derive(Default)]
    struct Decoded {
        errors: Vec<DecodeError>,
        chans: Vec<Vec<i32>>,
        /// The channels and bits per sample of each frame.
        shapes: Vec<(u32, u32)>,
        /// Channels and bits per sample, from STREAMINFO.
        channels: i32,
        bps: i32,
        has_md5: bool,
        md5: [u8; MD5_LEN],
        end: Option<State>,
    }

    impl Client for Decoded {
        fn error(&mut self, e: DecodeError) {
            self.errors.push(e);
        }
        fn write(&mut self, h: &FrameHeader, chans: &[&[i32]]) -> bool {
            self.shapes.push((h.channels, h.bits_per_sample));
            self.chans
                .resize(self.chans.len().max(chans.len()), Vec::new());
            for (d, c) in self.chans.iter_mut().zip(chans) {
                d.extend_from_slice(c);
            }
            true
        }
    }

    fn decode(data: &[u8]) -> Decoded {
        let mut dec = StreamDecoder::new(data.to_vec(), true, false);
        let mut d = Decoded::default();
        while dec.process_single(&mut d) && dec.state() != State::EndOfStream {}
        d.end = Some(dec.state());
        d.channels = dec.si_channels as i32;
        d.bps = dec.si_bps as i32;
        d.has_md5 = dec.has_stream_info;
        d.md5 = dec.md5sum;
        d
    }

    #[test]
    fn flac_decode_records() {
        for rc in &RECORDS {
            let data = std::fs::read(data_dir().join(format!("{}.dat", rc.name))).unwrap();
            let d = decode(&data);
            assert!(d.errors.is_empty(), "{}", rc.name);
            assert_eq!(d.end, Some(State::EndOfStream));
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
            // Every frame has the channels and resolution of STREAMINFO.
            assert!(d
                .shapes
                .iter()
                .all(|&(c, b)| (c as i32, b as i32) == (rc.channels, rc.bps)));
            // Trailing zero bytes: all the samples, then lost sync.
            let mut padded = data.clone();
            padded.resize(padded.len() + 100, 0);
            let d3 = decode(&padded);
            assert_eq!(d3.errors, [DecodeError::LostSync]);
            assert_eq!(d3.chans, d.chans);
            // A truncated stream: all the frames but the last.
            let d4 = decode(&data[..data.len() - 3]);
            assert_eq!(d4.errors, [DecodeError::LostSync]);
            assert!(d4.chans[0].len() < rc.nsamp);
            assert_eq!(d4.chans[0][..], d.chans[0][..d4.chans[0].len()]);
            // A stream with a corrupted frame.
            let mut bad = data.clone();
            let mid = bad.len() / 2;
            bad[mid] ^= 0x10;
            assert!(!decode(&bad).errors.is_empty());
            // Something that is not a FLAC stream.
            assert_eq!(
                decode(&data[1..]).errors.first(),
                Some(&DecodeError::LostSync)
            );
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
            let d = decode(&bytes);
            assert!(d.errors.is_empty());
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
        let d = decode(&out);
        assert!(d.errors.is_empty());
        assert_eq!(d.chans.len(), 2);
        assert_eq!(d.chans[0].len(), 4);
        assert_eq!(d.chans[1][3], 700);
        assert_eq!(d.shapes, [(2, 16)]);
    }
}
