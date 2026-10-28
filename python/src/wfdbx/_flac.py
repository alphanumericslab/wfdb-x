"""FLAC-compressed signal files (formats 508, 516, and 524).

This module implements, without external libraries, the FLAC support that
the C WFDB library obtains from libFLAC:

* a complete FLAC decoder (all subframe types, stereo decorrelation, wasted
  bits, variable block sizes, CRC verification, and optional MD5 checking
  when WFDB_FLAC_CHECK_MD5 is set), used to read signals; and
* a lossless FLAC encoder, used to write signals.  The encoder writes
  standard FLAC streams that libFLAC (and therefore the C WFDB library)
  reads back with identical sample values.  The compressed bytes are not
  identical to those written by libFLAC, whose output depends on its
  version and on the processor it runs on.

This file is part of WFDB-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.

It is a Python translation of the FLAC support of lib/signal.c (the code that
connects FLAC to the signal functions) from the WFDB Software Package 10.7.0,
by Benjamin Moody (2020). The translation follows the logic and behavior of the
original code, but it is new code, not the original C code. Its FLAC decoder
is a Python translation of the stream decoder of libFLAC 1.4.3
(src/libFLAC/stream_decoder.c and bitreader.c, and the restore functions of
fixed.c and lpc.c), made so that damaged files are decoded, resynchronized and
reported exactly as by the C library, which uses libFLAC. Its FLAC encoder is
WFDB-x's own implementation of the FLAC format; it has no counterpart in the
original package. WFDB-x needs no external library at run time.

Changes from the original: FLAC streams are decoded by the translation of
libFLAC's stream decoder and encoded by WFDB-x's own encoder instead of by
libFLAC; the files written decode to the same samples, but their bytes differ
from libFLAC's. Each change is marked "WFDB-x:" in the code;
docs/DIVERGENCES.md gives the reasons.

Original C code: lib/signal.c (FLAC support), WFDB Software Package 10.7.0.
  Copyright (C) 1989-2013 George B. Moody; revised 2011-2022 by Benjamin Moody,
  including FLAC support (2020).
Python translation and changes: Copyright (C) 2026 Reza Sameni.

This library is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.

libFLAC is distributed under the following license, which applies to the parts
of this file translated from it (the FLAC decoder):

Copyright (C) 2000-2009  Josh Coalson
Copyright (C) 2011-2023  Xiph.Org Foundation

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

- Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.

- Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

- Neither the name of the Xiph.org Foundation nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE FOUNDATION OR
CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
"""

import os

from ._wfdbio import wfdb_error

FLAC__MAX_CHANNELS = 8      # as in libFLAC
_BLOCKSIZE = 4096           # samples per channel in each encoded frame
_STREAMINFO_LEN = 34        # length of the STREAMINFO metadata block
_SAMPLE_RATE = 96000        # nominal sample rate written (as in signal.c)
_VENDOR = b"wfdb-x"           # vendor string of the VORBIS_COMMENT block

# ---------------------------------------------------------------------------
# CRC tables

_CRC8 = []
for _i in range(256):
    _c = _i
    for _ in range(8):
        _c = ((_c << 1) ^ 0x07) & 0xFF if _c & 0x80 else (_c << 1) & 0xFF
    _CRC8.append(_c)
_CRC16 = []
for _i in range(256):
    _c = _i << 8
    for _ in range(8):
        _c = ((_c << 1) ^ 0x8005) & 0xFFFF if _c & 0x8000 else \
            (_c << 1) & 0xFFFF
    _CRC16.append(_c)


def _crc8(data):
    c = 0
    for b in data:
        c = _CRC8[c ^ b]
    return c


def _crc16(data):
    c = 0
    for b in data:
        c = ((c << 8) & 0xFFFF) ^ _CRC16[(c >> 8) ^ b]
    return c


# ---------------------------------------------------------------------------
# Decoder
#
# The decoder follows libFLAC's stream decoder (version 1.4.3) step by step:
# its states, its search for frame sync codes, its error statuses and the
# point at which it reports each one, its recovery after a damaged frame,
# and its binary search when seeking.  The C library's results on damaged
# files depend on all of these.  libFLAC reads its input through a buffer
# of _CAPACITY bytes; the buffer is modelled as far as its contents affect
# the results (the end-of-file flag, and the return to the last frame sync
# code after a damaged frame).

class FlacError(Exception):
    """A FLAC stream could not be decoded (status: 'sync', 'header',
    'crc', 'unparseable', or 'meta')."""

    def __init__(self, status):
        Exception.__init__(self, status)
        self.status = status


# Decoder states (FLAC__StreamDecoderState)
_SEARCH_FOR_METADATA = 0
_READ_METADATA = 1
_SEARCH_FOR_FRAME_SYNC = 2
_READ_FRAME = 3
_END_OF_STREAM = 4
_ABORTED = 5
_SEEK_ERROR = 6
_MEMORY_ALLOCATION_ERROR = 7

_CAPACITY = 8192        # bytes in the input buffer of libFLAC's bit reader


class _NoInput(Exception):
    """The bit reader could not get the bits it needs; self.state says why
    (as libFLAC's read callback leaves it)."""


# Block sizes given by the block size codes of a frame header (codes 0, 6
# and 7 are handled separately), and sample sizes given by the sample size
# codes (codes 0 and 3 are handled separately).
_BS_TABLE = {1: 192, 2: 576, 3: 1152, 4: 2304, 5: 4608, 8: 256, 9: 512,
             10: 1024, 11: 2048, 12: 4096, 13: 8192, 14: 16384, 15: 32768}
_BPS_TABLE = {1: 8, 2: 12, 4: 16, 5: 20, 6: 24, 7: 32}
_RATE_TABLE = {1: 88200, 2: 176400, 3: 192000, 4: 8000, 5: 16000,
               6: 22050, 7: 24000, 8: 32000, 9: 44100, 10: 48000,
               11: 96000}


def _wrap32(x):
    return ((x + 0x80000000) & 0xFFFFFFFF) - 0x80000000


class _Decoder:
    """libFLAC's stream decoder, reading the bytes data.

    on_error(status) is called for each error that libFLAC reports to its
    error callback; on_write(channels) is called for each block of decoded
    samples (one list per channel), and returns False to abort decoding."""

    def __init__(self, data, seekable, on_error, on_write, md5_checking):
        self.data = data
        self.nbytes = len(data)
        self.seekable = seekable
        self.on_error = on_error
        self.on_write = on_write
        # Bit reader: the buffer holds bytes bstart to bend - 1 of the file
        # (bend is the file position), and pos is the position (in bits) of
        # the next bit to be read.  fsloc is the location of the last frame
        # sync code seen, while it remains in the buffer.
        self.bstart = self.bend = self.end = self.pos = 0
        self.fsloc = None
        self.feof = False
        self.state = _SEARCH_FOR_METADATA
        self.cached = None      # a byte read ahead while looking for sync
        self.warmup = 0         # the second byte of the frame sync code
        self.has_stream_info = False
        self.min_blocksize = self.max_blocksize = 0
        self.min_framesize = self.max_framesize = 0
        self.si_rate = self.si_channels = self.si_bps = 0
        self.total_samples = 0
        self.si_md5 = bytes(16)
        self.seek_table = None
        self.fixed_block_size = self.next_fixed_block_size = 0
        self.samples_decoded = 0
        self.last_seen_framesync = 0
        # the last frame passed to on_write: (sample number, block size,
        # sample rate, channels, bits per sample), or None
        self.last_frame = None
        self.channels = self.bps = 0    # of the last frame decoded
        self.is_seeking = False
        self.target_sample = 0
        self.unparseable_frame_count = 0
        self.first_frame_offset = 0
        self.do_md5_checking = md5_checking
        self.md5 = None
        if md5_checking:
            import hashlib      # (imported only when needed: it is slow)
            self.md5 = hashlib.md5()

    # -- bit reader ------------------------------------------------------

    def _fill(self):
        """Read more input into the buffer (bitreader_read_from_client_,
        read_callback_ and the C library's iflac_read)."""
        consumed = (self.pos - self.bstart * 8) >> 6    # whole 8-byte words
        if consumed > 0:
            self.fsloc = None
            self.bstart += consumed * 8
        request = _CAPACITY - (self.bend - self.bstart)
        if request <= 0:
            raise _NoInput
        if self.feof:
            self.state = _END_OF_STREAM
            raise _NoInput
        if self.is_seeking and self.unparseable_frame_count > 20:
            self.state = _ABORTED
            raise _NoInput
        got = min(request, self.nbytes - self.bend)
        if got < request:
            self.feof = True
        if got <= 0:
            self.state = _END_OF_STREAM
            raise _NoInput
        self.bend += got
        self.end = self.bend * 8

    def read(self, n):
        p = self.pos
        e = p + n
        while e > self.end:
            self._fill()
        b0 = p >> 3
        b1 = (e + 7) >> 3
        v = int.from_bytes(self.data[b0:b1], "big") >> ((b1 << 3) - e)
        self.pos = e
        return v & ((1 << n) - 1)

    def read_signed(self, n):
        v = self.read(n)
        if v >> (n - 1):
            v -= 1 << n
        return v

    def unary(self):
        """Count zero bits up to (and consume) the next one bit."""
        data = self.data
        p = self.pos
        n = 0
        while True:
            eb = self.end >> 3
            bi = p >> 3
            if bi < eb:
                byte = (data[bi] << (p & 7)) & 0xFF
                if byte:
                    z = 8 - byte.bit_length()
                    self.pos = p + z + 1
                    return n + z
                n += 8 - (p & 7)
                bi += 1
                while bi < eb and not data[bi]:
                    bi += 1
                n += (bi - (p >> 3) - 1) * 8
                p = bi << 3
                if bi < eb:
                    continue
            self.pos = p
            self._fill()

    def _skip_bytes(self, n):
        target = self.pos + 8 * n
        while True:
            self.pos = min(target, self.end)
            if self.pos >= target:
                return
            self._fill()

    def _clear(self):
        """Empty the buffer (FLAC__bitreader_clear)."""
        self.bstart = self.bend
        self.pos = self.end = self.bend * 8
        self.fsloc = None

    def _seek_file(self, pos):
        """Move the file position (the C library's iflac_seek)."""
        if not self.seekable:
            return False
        self.bend = pos
        self.end = pos * 8
        self.feof = False
        return True

    def _decode_position(self):
        """FLAC__stream_decoder_get_decode_position: the position in the file
        of the next byte to be decoded (None if it is not known)."""
        if not self.seekable or self.pos & 7:
            return None
        return self.pos >> 3

    def _error(self, status):
        """send_error_to_client_"""
        if not self.is_seeking:
            self.on_error(status)
        elif status == "unparseable":
            self.unparseable_frame_count += 1

    # -- stream ----------------------------------------------------------

    def process_single(self):
        """FLAC__stream_decoder_process_single"""
        while True:
            st = self.state
            if st == _SEARCH_FOR_METADATA:
                if not self._find_metadata():
                    return False
            elif st == _READ_METADATA:
                return self._read_metadata()
            elif st == _SEARCH_FOR_FRAME_SYNC:
                if not self._frame_sync():
                    return True
            elif st == _READ_FRAME:
                ok, got = self._read_frame()
                if not ok:
                    return False
                if got:
                    return True
            elif st in (_END_OF_STREAM, _ABORTED):
                return True
            else:
                return False

    def _process_until_end_of_metadata(self):
        while True:
            st = self.state
            if st == _SEARCH_FOR_METADATA:
                if not self._find_metadata():
                    return False
            elif st == _READ_METADATA:
                if not self._read_metadata():
                    return False
            elif st in (_SEARCH_FOR_FRAME_SYNC, _READ_FRAME, _END_OF_STREAM,
                        _ABORTED):
                return True
            else:
                return False

    def _find_metadata(self):
        """Look for the stream marker 'fLaC', skipping an ID3v2 tag."""
        i = id3 = 0
        first = True
        try:
            while i < 4:
                if self.cached is not None:
                    x = self.cached
                    self.cached = None
                else:
                    x = self.read(8)
                if x == b"fLaC"[i]:
                    first = True
                    i += 1
                    id3 = 0
                    continue
                if id3 >= 3:
                    return False
                if x == b"ID3"[id3]:
                    id3 += 1
                    i = 0
                    if id3 == 3:
                        self.read(24)   # version and flags
                        skip = 0
                        for _ in range(4):
                            skip = (skip << 7) | (self.read(8) & 0x7F)
                        self._skip_bytes(skip)
                    continue
                id3 = 0
                if x == 0xFF:
                    x = self.read(8)
                    if x == 0xFF:
                        self.cached = x
                    elif x >> 1 == 0x7C:
                        self.warmup = x
                        self.state = _READ_FRAME
                        return True
                i = 0
                if first:
                    self._error("sync")
                    first = False
        except _NoInput:
            return False
        self.state = _READ_METADATA
        return True

    def _read_metadata(self):
        """Read one metadata block.  Only STREAMINFO and SEEKTABLE are
        examined; libFLAC skips the others (as the C library does not ask for
        them)."""
        try:
            is_last = self.read(1)
            typ = self.read(7)
            length = self.read(24)
            if typ == 0:            # STREAMINFO
                self.min_blocksize = self.read(16)
                self.max_blocksize = self.read(16)
                self.min_framesize = self.read(24)
                self.max_framesize = self.read(24)
                self.si_rate = self.read(20)
                self.si_channels = self.read(3) + 1
                self.si_bps = self.read(5) + 1
                self.total_samples = self.read(36)
                self.si_md5 = self.read(128).to_bytes(16, "big")
                if length < 34:
                    return False
                self._skip_bytes(length - 34)
                self.has_stream_info = True
                if not any(self.si_md5):
                    self.do_md5_checking = False
            elif typ == 3:          # SEEKTABLE
                self.seek_table = None
                if length > 0:
                    if length % 18:
                        return False
                    points = []
                    for _ in range(length // 18):
                        points.append((self.read(64), self.read(64),
                                       self.read(16)))
                    self.seek_table = points
            else:
                if typ == 2:        # APPLICATION: an identifier first
                    self.read(32)
                    if length < 4:
                        self.state = _MEMORY_ALLOCATION_ERROR
                        return False
                    length -= 4
                self._skip_bytes(length)
        except _NoInput:
            return False
        if is_last:
            p = self._decode_position()
            self.first_frame_offset = p if p is not None else 0
            self.state = _SEARCH_FOR_FRAME_SYNC
        return True

    def _frame_sync(self):
        """Look for the next frame sync code."""
        data = self.data
        first = True
        try:
            if self.pos & 7:
                self.read(8 - (self.pos & 7))
            while True:
                if self.cached is not None:
                    x = self.cached
                    self.cached = None
                else:
                    # (skip quickly to the next 0xFF byte in the buffer)
                    p = self.pos >> 3
                    if p >= self.bend:
                        self._fill()
                        continue
                    q = data.find(b"\xff", p, self.bend)
                    if q != p:
                        if first:
                            self._error("sync")
                            first = False
                        if q < 0:
                            self.pos = self.end
                            self._fill()
                            continue
                        self.pos = q << 3
                    x = self.read(8)
                if x == 0xFF:
                    x = self.read(8)
                    if x == 0xFF:
                        self.cached = x
                    elif x >> 1 == 0x7C:
                        self.warmup = x
                        self.state = _READ_FRAME
                        self.fsloc = (self.pos >> 3) - self.bstart
                        p = self._decode_position()
                        self.last_seen_framesync = p if p is not None else 0
                        return True
                if first:
                    self._error("sync")
                    first = False
        except _NoInput:
            return False

    # -- frames ----------------------------------------------------------

    def _read_frame(self):
        """Read one frame; returns (ok, got_a_frame)."""
        start = (self.pos >> 3) - 2         # (the frame sync code)
        try:
            if not self._read_frame_header():
                return False, False
        except _NoInput:
            return False, False
        if self.state == _SEARCH_FOR_FRAME_SYNC:
            return True, False
        nch = self.f_channels
        bs = self.f_blocksize
        assign = self.f_assign
        chans = []
        for ch in range(nch):
            bps = self.f_bps
            if (assign == 8 and ch == 1) or (assign == 9 and ch == 0) or \
                    (assign == 10 and ch == 1):
                bps += 1                    # the side channel
            try:
                out = self._read_subframe(bps, bs)
            except _NoInput:
                if self.state == _END_OF_STREAM:
                    break
                return False, False
            if self.state != _READ_FRAME:
                break
            chans.append(out)
        if self.state != _END_OF_STREAM:
            # zero padding to the end of the byte
            try:
                if self.pos & 7 and self.read(8 - (self.pos & 7)):
                    self._error("sync")
                    self.state = _SEARCH_FOR_FRAME_SYNC
            except _NoInput:
                return False, False
        if self.state == _READ_FRAME:
            crc = _crc16(self.data[start:self.pos >> 3])
            x = None
            try:
                x = self.read(16)
            except _NoInput:
                if self.state != _END_OF_STREAM:
                    return False, False
            if self.state == _READ_FRAME:
                if crc == x:
                    chans = self._undo_channel_coding(chans, assign)
                    if chans is None:
                        self._error("crc")
                        self.state = _SEARCH_FOR_FRAME_SYNC
                else:
                    self._error("crc")
                    self.state = _SEARCH_FOR_FRAME_SYNC
        sn = self.f_sample
        if self.last_frame is not None and self.state == _READ_FRAME and \
                not self.is_seeking:
            if not self._pad_missing_samples(sn):
                return False, False
        if self.state in (_SEARCH_FOR_FRAME_SYNC, _END_OF_STREAM):
            # a damaged frame: go back to just after its sync code
            if self.fsloc is not None:
                self.pos = (self.bstart + self.fsloc + 1) * 8
            else:
                self.pos = self.bstart * 8
                if self.last_seen_framesync:
                    if not self._seek_file(self.last_seen_framesync):
                        self.state = _SEEK_ERROR
                        return False, False
                    self._clear()
            self.state = _SEARCH_FOR_FRAME_SYNC
            return True, False
        if self.next_fixed_block_size:
            self.fixed_block_size = self.next_fixed_block_size
        self.channels = nch
        self.bps = self.f_bps
        self.samples_decoded = sn + bs
        if not self._write(sn, bs, self.f_rate, nch, self.f_bps, chans):
            self.state = _ABORTED
            return False, False
        self.state = _SEARCH_FOR_FRAME_SYNC
        return True, True

    def _bad_header(self, back=None):
        if back is not None:
            self.cached = back
        self._error("header")
        self.state = _SEARCH_FOR_FRAME_SYNC
        return True

    def _read_utf8(self, raw, wide):
        """A frame or sample number (None if its coding is invalid)."""
        x = self.read(8)
        raw.append(x)
        if not x & 0x80:
            return x
        if not x & 0x20:
            v, n = x & 0x1F, 1
        elif not x & 0x10:
            v, n = x & 0x0F, 2
        elif not x & 0x08:
            v, n = x & 0x07, 3
        elif not x & 0x04:
            v, n = x & 0x03, 4
        elif not x & 0x02:
            v, n = x & 0x01, 5
        elif wide and not x & 0x01:
            v, n = 0, 6
        else:
            return None
        for _ in range(n):
            x = self.read(8)
            raw.append(x)
            if x & 0xC0 != 0x80:
                return None
            v = (v << 6) | (x & 0x3F)
        return v

    def _read_frame_header(self):
        raw = [0xFF, self.warmup]
        unparseable = bool(raw[1] & 0x02)
        for _ in range(2):
            x = self.read(8)
            if x == 0xFF:
                # (a sync code cannot occur in a frame header)
                return self._bad_header(x)
            raw.append(x)
        bsc = raw[2] >> 4
        blocksize_hint = 0
        if bsc == 0:
            unparseable = True
        elif bsc in (6, 7):
            blocksize_hint = bsc
        else:
            self.f_blocksize = _BS_TABLE[bsc]
        src = raw[2] & 0x0F
        rate_hint = 0
        if src == 0:
            if self.has_stream_info:
                self.f_rate = self.si_rate
            else:
                unparseable = True
        elif src <= 11:
            self.f_rate = _RATE_TABLE[src]
        elif src <= 14:
            rate_hint = src
        else:
            return self._bad_header()
        x = raw[3] >> 4
        if x & 8:
            self.f_channels = 2
            if x & 7 <= 2:
                self.f_assign = x
            else:
                unparseable = True
        else:
            self.f_channels = x + 1
            self.f_assign = 0
        ssc = (raw[3] & 0x0E) >> 1
        if ssc == 0:
            if self.has_stream_info:
                self.f_bps = self.si_bps
            else:
                unparseable = True
        elif ssc == 3:
            unparseable = True
        else:
            self.f_bps = _BPS_TABLE[ssc]
        if raw[3] & 0x01:
            unparseable = True
        if raw[1] & 0x01 or (self.has_stream_info and
                             self.min_blocksize != self.max_blocksize):
            number = self._read_utf8(raw, True)     # sample number
            if number is None:
                return self._bad_header(raw[-1])
            is_sample = True
        else:
            number = self._read_utf8(raw, False)    # frame number
            if number is None:
                return self._bad_header(raw[-1])
            is_sample = False
        if blocksize_hint:
            x = self.read(8)
            raw.append(x)
            if blocksize_hint == 7:
                y = self.read(8)
                raw.append(y)
                x = (x << 8) | y
            self.f_blocksize = x + 1
            if self.f_blocksize > 65535:
                return self._bad_header(raw[-1])
        if rate_hint:
            x = self.read(8)
            raw.append(x)
            if rate_hint != 12:
                y = self.read(8)
                raw.append(y)
                x = (x << 8) | y
            self.f_rate = x * 1000 if rate_hint == 12 else \
                x if rate_hint == 13 else x * 10
        crc = self.read(8)
        if _crc8(raw) != crc:
            return self._bad_header()
        self.next_fixed_block_size = 0
        if not is_sample:
            if self.fixed_block_size:
                number *= self.fixed_block_size
            elif self.has_stream_info:
                if self.min_blocksize == self.max_blocksize:
                    number *= self.min_blocksize
                    self.next_fixed_block_size = self.max_blocksize
                else:
                    unparseable = True
            elif number == 0:
                self.next_fixed_block_size = self.f_blocksize
            else:
                number *= self.f_blocksize
        self.f_sample = number
        if unparseable:
            self._error("unparseable")
            self.state = _SEARCH_FOR_FRAME_SYNC
        return True

    def _lost_sync(self):
        self._error("sync")
        self.state = _SEARCH_FOR_FRAME_SYNC

    def _unparseable(self):
        self._error("unparseable")
        self.state = _SEARCH_FOR_FRAME_SYNC

    def _read_subframe(self, bps, bs):
        """Read one subframe; returns its samples (None after an error, which
        leaves the state changed)."""
        x = self.read(8)
        wasted = 0
        if x & 1:
            wasted = self.unary() + 1
            if wasted >= bps:
                return self._lost_sync()
            bps -= wasted
        x &= 0xFE
        if x & 0x80:
            return self._lost_sync()
        if x == 0:                          # CONSTANT
            out = [self.read_signed(bps)] * bs
        elif x == 2:                        # VERBATIM
            rs = self.read_signed
            out = [rs(bps) for _ in range(bs)]
        elif x < 16:
            return self._unparseable()
        elif x <= 24:                       # FIXED
            order = (x >> 1) & 7
            if bs <= order:
                return self._lost_sync()
            out = self._read_fixed(bps, bs, order)
        elif x < 64:
            return self._unparseable()
        else:                               # LPC
            order = ((x >> 1) & 31) + 1
            if bs <= order:
                return self._lost_sync()
            out = self._read_lpc(bps, bs, order)
        if out is None:
            return None
        if wasted:
            out = [v << wasted for v in out]
        return out

    def _read_coding(self, bs, order):
        """The entropy coding method and partition order, then the residual
        (None after an error)."""
        method = self.read(2)
        if method > 1:
            return self._unparseable()
        porder = self.read(4)
        if bs >> porder < order or bs % (1 << porder):
            return self._lost_sync()
        return self._read_residual(bs, order, porder, method)

    def _read_fixed(self, bps, bs, order):
        rs = self.read_signed
        s = [rs(bps) for _ in range(order)]
        res = self._read_coding(bs, order)
        if res is None:
            return None
        if order == 0:
            s.extend(res)
        elif order == 1:
            x = s[-1]
            for r in res:
                x += r
                s.append(x)
        elif order == 2:
            a, b = s[-2], s[-1]
            for r in res:
                a, b = b, 2 * b - a + r
                s.append(b)
        elif order == 3:
            a, b, c = s[-3], s[-2], s[-1]
            for r in res:
                a, b, c = b, c, 3 * c - 3 * b + a + r
                s.append(c)
        else:
            a, b, c, d = s[-4], s[-3], s[-2], s[-1]
            for r in res:
                a, b, c, d = b, c, d, 4 * d - 6 * c + 4 * b - a + r
                s.append(d)
        return s

    def _read_lpc(self, bps, bs, order):
        rs = self.read_signed
        s = [rs(bps) for _ in range(order)]
        prec = self.read(4)         # coefficient precision - 1
        if prec == 15:
            return self._lost_sync()
        prec += 1
        shift = self.read_signed(5)
        if shift < 0:
            return self._lost_sync()
        coefs = [rs(prec) for _ in range(order)]
        res = self._read_coding(bs, order)
        if res is None:
            return None
        rc = coefs[::-1]
        for r in res:
            acc = 0
            for cf, x in zip(rc, s[-order:]):
                acc += cf * x
            s.append(r + (acc >> shift))
        return s

    def _read_residual(self, bs, order, porder, method):
        # Rice parameters have 4 bits (method 0) or 5 bits (method 1); the
        # all-ones parameter is an escape code for unencoded residuals.
        pbits, esc = (4, 15) if method == 0 else (5, 31)
        psize = bs >> porder
        out = []
        append = out.append
        unary = self.unary
        read = self.read
        for part in range(1 << porder):
            n = psize - order if part == 0 else psize
            k = read(pbits)
            if k == esc:
                nb = read(5)        # bits per unencoded residual
                if nb == 0:
                    out.extend([0] * n)
                else:
                    rs = self.read_signed
                    for _ in range(n):
                        append(rs(nb))
            elif k == 0:
                for _ in range(n):
                    u = unary()
                    append((u >> 1) ^ -(u & 1))
            else:
                # (libFLAC rejects a quotient too large for 32 bits; its
                # position is then that of the start of the partition)
                limit = 0xFFFFFFFF >> k
                start = self.pos
                for _ in range(n):
                    q = unary()
                    if q > limit:
                        self.pos = start
                        return self._lost_sync()
                    u = (q << k) | read(k)
                    append((u >> 1) ^ -(u & 1))
        return out

    def _undo_channel_coding(self, chans, assign):
        """Restore left and right channels from side channels, and check that
        the samples fit the sample size (None if they do not)."""
        if assign == 8:             # left/side
            a, sd = chans
            chans = [a, [x - y for x, y in zip(a, sd)]]
        elif assign == 9:           # side/right
            sd, b = chans
            chans = [[x + y for x, y in zip(sd, b)], b]
        elif assign == 10:          # mid/side
            m, sd = chans
            le = []
            ri = []
            for x, y in zip(m, sd):
                x = (x << 1) | (y & 1)
                le.append((x + y) >> 1)
                ri.append((x - y) >> 1)
            chans = [le, ri]
        lo = -1 << (self.f_bps - 1)
        hi = -lo - 1
        for i, c in enumerate(chans):
            if c and (min(c) < lo or max(c) > hi):
                c = chans[i] = [_wrap32(x) for x in c]
                if min(c) < lo or max(c) > hi:
                    return None
        return chans

    def _pad_missing_samples(self, sn):
        """Fill a gap between the previous frame and this one with silence,
        as libFLAC does for missing frames (False if decoding is aborted)."""
        lsn, lbs, lrate, lch, lbps = self.last_frame
        if lsn + lbs >= sn:
            return True
        need = (sn - (lsn + lbs)) & 0xFFFFFFFF
        if lrate != self.f_rate or lch != self.f_channels or \
                lbps != self.f_bps or lbs < 16:
            return True
        need = min(need, (5 * lrate) & 0xFFFFFFFF, 50 * lbs)
        while need:
            lsn += lbs
            if need < lbs:
                lbs = need
            need -= lbs
            self.samples_decoded = lsn + lbs
            if not self._write(lsn, lbs, lrate, lch, lbps,
                               [[0] * lbs for _ in range(lch)]):
                self.state = _ABORTED
                return False
        return True

    def _write(self, sn, bs, rate, nch, bps, chans):
        """write_audio_frame_to_client_"""
        self.last_frame = (sn, bs, rate, nch, bps)
        if self.is_seeking:
            target = self.target_sample
            if sn <= target < sn + bs:      # the target frame
                delta = target - sn
                self.is_seeking = False
                if delta:
                    chans = [c[delta:] for c in chans]
                    self.last_frame = (sn + delta, bs - delta, rate, nch, bps)
                return self.on_write(chans)
            return True
        if not self.has_stream_info:
            self.do_md5_checking = False
        if self.do_md5_checking:
            nb = (bps + 7) // 8
            mask = (1 << (8 * nb)) - 1
            self.md5.update(b"".join(
                (x & mask).to_bytes(nb, "little")
                for f in zip(*chans) for x in f))
        return self.on_write(chans)

    # -- seeking ---------------------------------------------------------

    def flush(self):
        """FLAC__stream_decoder_flush"""
        self.samples_decoded = 0
        self.do_md5_checking = False
        self.last_seen_framesync = 0
        self.last_frame = None
        self._clear()
        self.state = _SEARCH_FOR_FRAME_SYNC

    def seek_absolute(self, sample):
        """FLAC__stream_decoder_seek_absolute"""
        if self.state not in (_SEARCH_FOR_METADATA, _READ_METADATA,
                              _SEARCH_FOR_FRAME_SYNC, _READ_FRAME,
                              _END_OF_STREAM):
            return False
        total = self.total_samples if self.has_stream_info else 0
        if total > 0 and sample >= total:
            return False
        self.is_seeking = True
        self.do_md5_checking = False
        if not self.seekable:           # (the length is not known)
            self.is_seeking = False
            return False
        self.feof = False               # (finding the length seeks)
        if self.state in (_SEARCH_FOR_METADATA, _READ_METADATA):
            if not self._process_until_end_of_metadata():
                self.is_seeking = False
                return False
            total = self.total_samples if self.has_stream_info else 0
            if total > 0 and sample >= total:
                self.is_seeking = False
                return False
        ok = self._seek_to_absolute_sample(self.nbytes, sample)
        self.is_seeking = False
        return ok

    def _seek_to_absolute_sample(self, stream_length, target):
        """seek_to_absolute_sample_: a binary search for the frame that
        holds the target sample."""
        u32 = 0xFFFFFFFF
        u64 = 0xFFFFFFFFFFFFFFFF
        total = self.total_samples if self.has_stream_info else 0
        channels = self.channels or self.si_channels
        bps = self.bps or self.si_bps
        if self.max_framesize > 0:
            approx = (self.max_framesize + self.min_framesize) // 2 + 1
        elif self.min_blocksize == self.max_blocksize and \
                self.min_blocksize > 0:
            approx = ((self.min_blocksize * channels * bps) & u32) // 8 + 64
        else:
            approx = ((4096 * channels * bps) & u32) // 8 + 64
        approx &= u32
        lower = self.first_frame_offset
        lower_sample = 0
        upper = stream_length
        upper_sample = total if total > 0 else target
        if self.state == _SEARCH_FOR_FRAME_SYNC and self.samples_decoded:
            p = self._decode_position()
            if target < self.samples_decoded:
                if p is not None:
                    upper = p
                    upper_sample = self.samples_decoded
            elif p is not None:
                lower = p
                lower_sample = self.samples_decoded
        if self.seek_table:
            new_lower, new_upper = lower, upper
            new_lower_sample, new_upper_sample = lower_sample, upper_sample

            def usable(pt):
                return pt[0] != u64 and pt[2] > 0 and \
                    (total <= 0 or pt[0] < total)
            below = [pt for pt in self.seek_table
                     if usable(pt) and pt[0] <= target]
            if below:
                new_lower = self.first_frame_offset + below[-1][1]
                new_lower_sample = below[-1][0]
            above = [pt for pt in self.seek_table
                     if usable(pt) and pt[0] > target]
            if above:
                new_upper = self.first_frame_offset + above[0][1]
                new_upper_sample = above[0][0]
            if new_upper >= new_lower:
                lower, upper = new_lower, new_upper
                lower_sample, upper_sample = new_lower_sample, \
                    new_upper_sample
        if upper_sample == lower_sample:
            upper_sample += 1
        self.target_sample = target
        first_seek = True
        from_lower = False
        while True:
            if self.state in (_MEMORY_ALLOCATION_ERROR, _ABORTED):
                return False
            if lower_sample >= upper_sample or lower > upper or \
                    upper >= (1 << 63) - 1:
                self.state = _SEEK_ERROR
                return False
            if from_lower:
                pos = lower
            else:
                pos = lower + int(
                    float((target - lower_sample) & u64) /
                    float((upper_sample - lower_sample) & u64) *
                    float(upper - lower)) - approx
            if pos >= upper:
                pos = upper - 1
            if pos < lower:
                pos = lower
            if not self._seek_file(pos):
                self.state = _SEEK_ERROR
                return False
            self.flush()
            self.unparseable_frame_count = 0
            if not self.process_single() or self.state == _ABORTED or \
                    self.samples_decoded == 0:
                # no frame could be decoded
                if self.state != _ABORTED and self.feof and not from_lower:
                    from_lower = True
                    continue
                self.state = _SEEK_ERROR
                return False
            from_lower = False
            if not self.is_seeking:
                break
            this_sample, this_bs = self.last_frame[0], self.last_frame[1]
            if this_sample + this_bs >= upper_sample and not first_seek:
                if pos == lower:
                    self.state = _SEEK_ERROR
                    return False
                approx = (approx * 2) & u32 if approx else 16
                continue
            first_seek = False
            if this_sample < lower_sample:
                self.state = _SEEK_ERROR
                return False
            p = self._decode_position()
            if p is None:
                self.state = _SEEK_ERROR
                return False
            if target < this_sample:
                upper_sample = this_sample + this_bs
                upper = p
                approx = ((((upper - pos) & u64) * 2 // 3) + 16) & u32
            else:
                lower_sample = this_sample + this_bs
                lower = p
                approx = ((((lower - pos) & u64) * 2 // 3) + 16) & u32
        return True

    def finish(self):
        """FLAC__stream_decoder_finish: False if the MD5 signature does not
        match the samples decoded."""
        if self.do_md5_checking:
            import hashlib
            computed = (self.md5 or hashlib.md5()).digest()
            return computed == self.si_md5
        return True


def decode_bytes(data):
    """Decode a complete FLAC stream (bytes).

    Returns ``(channels, bits_per_sample)``, where ``channels`` is a list of
    lists of samples (one per channel).  Raises FlacError on invalid input.
    """
    chans = []

    def on_error(status):
        raise FlacError(status)

    def on_write(fr):
        if not chans:
            chans.extend([] for _ in fr)
        if len(fr) != len(chans):
            raise FlacError("unparseable")
        for c, f in zip(chans, fr):
            c.extend(f)
        return True

    dec = _Decoder(bytes(data), True, on_error, on_write, False)
    while dec.state != _END_OF_STREAM:
        if not dec.process_single():
            raise FlacError("meta")
    if not chans:
        chans = [[] for _ in range(max(dec.si_channels, 1))]
    return chans, dec.si_bps


_MESSAGES = {
    "sync": "getvec: unable to decode FLAC (lost sync)\n",
    "header": "getvec: unable to decode FLAC (invalid header)\n",
    "crc": "getvec: unable to decode FLAC (CRC mismatch)\n",
    "unparseable": "getvec: unable to decode FLAC (unsupported format)\n",
}


class _FlacInput:
    """State of a FLAC signal group (one WFDB input group): libFLAC's
    decoder, and the samples it has decoded, in frame order, as the C
    library's iflac_samples() stores them."""

    def __init__(self, nsig, datb, spf):
        self.nsig = nsig
        self.datb = datb        # resolution of the group (8, 16, or 24)
        self.spf = spf
        self.dec = None         # (created when the file is first read)
        self.samples = []       # complete frames, in frame order
        self.pos = 0            # index of the next sample to be returned
        self.partial = None     # an incomplete frame: one list per signal
        self.skip = 0           # samples to discard after a seek


def _decoder(ig):
    fi = ig.flac
    if fi.dec is None:

        def on_error(status):
            wfdb_error(_MESSAGES.get(status,
                                     "getvec: unable to decode FLAC\n"))
            ig.stat = -2

        def on_write(chans):
            return _samples(ig, chans)

        fi.dec = _Decoder(ig.fp.readall(), bool(ig.seek), on_error, on_write,
                          bool(os.environ.get("WFDB_FLAC_CHECK_MD5")))
    return fi.dec


def _samples(ig, chans):
    """Store a block of decoded samples (iflac_samples): False to abort
    decoding."""
    fi = ig.flac
    if len(chans) != fi.nsig:
        wfdb_error("getvec: wrong number of signals in FLAC signal file\n")
        ig.stat = -2
    if fi.dec.f_bps > fi.datb:
        wfdb_error("getvec: wrong sample resolution in FLAC signal file\n")
        ig.stat = -2
    if ig.stat < 0:
        return False
    n = len(chans[0]) if chans else 0
    if fi.skip > n:
        fi.skip -= n
        return True
    if fi.skip:
        chans = [c[fi.skip:] for c in chans]
        fi.skip = 0
    if fi.pos:
        del fi.samples[:fi.pos]
        fi.pos = 0
    spf = fi.spf
    out = fi.samples
    if spf == 1 and fi.partial is None:
        if len(chans) == 1:
            out.extend(chans[0])
        else:
            for f in zip(*chans):
                out.extend(f)
        return True
    if fi.partial is not None:
        chans = [p + c for p, c in zip(fi.partial, chans)]
        fi.partial = None
    n = len(chans[0]) if chans else 0
    nfr = n // spf
    for f in range(0, nfr * spf, spf):
        for c in chans:
            out.extend(c[f:f + spf])
    if n > nfr * spf:
        fi.partial = [c[nfr * spf:] for c in chans]
    return True


def isopen(ig, hs, ns):
    """Prepare to read a FLAC signal group (flac_isopen)."""
    if ns > FLAC__MAX_CHANNELS:
        wfdb_error("isigopen: cannot store %u signals in a single FLAC file\n",
                   ns)
        return -1
    for i in range(1, ns):
        if hs[i].info.spf != hs[0].info.spf:
            wfdb_error("isigopen: every signal in a FLAC file must have\n"
                       "  the same sampling frequency\n")
            return -1
    ig.flac = _FlacInput(ns, hs[0].info.fmt - 500, hs[0].info.spf)
    ig.count = 0
    return 0


def getsamp(ig):
    """Return the next sample from a FLAC signal group (flac_getsamp)."""
    fi = ig.flac
    p = fi.pos
    if p < len(fi.samples):
        fi.pos = p + 1
        return fi.samples[p]
    dec = _decoder(ig)
    while fi.pos >= len(fi.samples):
        oldcount = len(fi.partial[0]) if fi.partial else 0
        if not dec.process_single():
            if ig.stat != -2:
                wfdb_error("getvec: unexpected FLAC decoding error\n")
                ig.stat = -2
            return 0
        if ig.stat <= 0:
            return 0
        count = len(fi.partial[0]) if fi.partial else 0
        if fi.pos >= len(fi.samples) and count == oldcount:
            st = dec.state
            if st == _END_OF_STREAM:
                if count:
                    wfdb_error("getvec: warning: %d samples left over at end"
                               " of file\n", count)
                fi.partial = None
                ig.stat = 0
                return 0
            if st not in (_SEARCH_FOR_METADATA, _READ_METADATA,
                          _SEARCH_FOR_FRAME_SYNC):
                wfdb_error("getvec: unknown FLAC decoding state\n")
                ig.stat = -2
                return 0
    p = fi.pos
    fi.pos = p + 1
    return fi.samples[p]


def isseek(ig, t):
    """Seek to frame t of a FLAC signal group (flac_isseek)."""
    fi = ig.flac
    dec = _decoder(ig)
    if dec.state == _SEEK_ERROR:
        dec.flush()
    fi.samples = []
    fi.pos = 0
    fi.partial = None
    ig.stat = 1
    ig.count = 0
    fi.skip = 0
    # (seeking to the sample before the target, then discarding it, allows
    # a seek to the end of the stream)
    tt = t * fi.spf + ig.start
    if tt != 0:
        tt -= 1
        fi.skip = 1
    if not dec.seek_absolute(tt):
        ig.stat = -1
    return ig.stat


def isclose(ig):
    """Close the decoder, checking the MD5 signature if requested
    (flac_isclose)."""
    fi = ig.flac
    if fi is None:
        return 0
    dec = fi.dec
    if dec is None:     # (nothing was read: libFLAC compares the signature
        # of no samples with that of a STREAMINFO block it has not read)
        if os.environ.get("WFDB_FLAC_CHECK_MD5"):
            wfdb_error("isigclose: warning: incorrect MD5 hash in FLAC "
                       "input\n")
            return -1
        return 0
    if not dec.finish():
        wfdb_error("isigclose: warning: incorrect MD5 hash in FLAC input\n")
        return -1
    return 0


# ---------------------------------------------------------------------------
# Encoder

class _BitWriter:
    """MSB-first bit writer."""

    __slots__ = ("acc", "n", "out")

    def __init__(self):
        self.acc = 0
        self.n = 0
        self.out = bytearray()

    def write(self, v, n):
        self.acc = (self.acc << n) | (v & ((1 << n) - 1))
        self.n += n
        if self.n >= 4096:      # keep the accumulator small
            self._flush_whole()

    def _flush_whole(self):
        k = self.n >> 3
        r = self.n & 7
        self.out += (self.acc >> r).to_bytes(k, "big")
        self.acc &= (1 << r) - 1
        self.n = r

    def align(self):
        if self.n & 7:
            self.write(0, 8 - (self.n & 7))

    def getbytes(self):
        self._flush_whole()
        assert self.n == 0
        return bytes(self.out)


def _utf8(v):
    """Code a frame number as in UTF-8 (extended to 36 bits, as in FLAC)."""
    if v < 0x80:
        return bytes((v,))
    for n, lead, mx in ((1, 0xC0, 0x7FF), (2, 0xE0, 0xFFFF),
                        (3, 0xF0, 0x1FFFFF), (4, 0xF8, 0x3FFFFFF),
                        (5, 0xFC, 0x7FFFFFFF), (6, 0xFE, 0xFFFFFFFFF)):
        if v <= mx:
            out = []
            for _ in range(n):
                out.append(0x80 | (v & 0x3F))
                v >>= 6
            out.append(lead | v)
            return bytes(reversed(out))
    raise ValueError(v)


def _rice_cost(u, k):
    """Bits needed to code the folded residuals u with Rice parameter k."""
    return sum((x >> k) for x in u) + len(u) * (k + 1)


def _best_partition(u, order, blocksize, maxk):
    """Choose a partition order and Rice parameters for folded residuals."""
    best = None
    for porder in range(0, 7):      # partition orders 0-6, as libFLAC
        nparts = 1 << porder
        if blocksize % nparts:
            break
        psize = blocksize >> porder
        if porder > 0 and psize <= order:
            break
        cost = 6                    # coding method and partition order
        params = []
        start = 0
        for p in range(nparts):
            n = psize - order if p == 0 else psize
            part = u[start:start + n]
            start += n
            if n == 0:
                params.append(0)
                cost += 4
                continue
            mean = sum(part) // n
            k0 = max(mean.bit_length() - 1, 0) if mean > 0 else 0
            bk, bc = None, None
            lo = min(max(k0 - 1, 0), maxk)
            for k in range(lo, min(k0 + 2, maxk) + 1):
                c = _rice_cost(part, k)
                if bc is None or c < bc:
                    bk, bc = k, c
            params.append(bk)
            cost += 4 + bc
        if best is None or cost < best[0]:
            best = (cost, porder, params)
    return best


def _encode_subframe(bw, x, bps):
    """Encode one channel as a constant, fixed-predictor or verbatim
    subframe, whichever is smallest.  A subframe header is a zero bit, the
    6-bit type (0 constant, 1 verbatim, 8 + order fixed) and a zero
    wasted-bits flag."""
    n = len(x)
    if all(v == x[0] for v in x):
        bw.write(0, 1)
        bw.write(0, 6)
        bw.write(0, 1)
        bw.write(x[0], bps)
        return
    maxk = 30           # largest Rice parameter (5-bit parameters, escape 31)
    best = None
    for order in range(0, min(4, n - 1) + 1):
        if order == 0:
            r = x
        elif order == 1:
            r = [x[i] - x[i - 1] for i in range(1, n)]
        elif order == 2:
            r = [x[i] - 2 * x[i - 1] + x[i - 2] for i in range(2, n)]
        elif order == 3:
            r = [x[i] - 3 * x[i - 1] + 3 * x[i - 2] - x[i - 3]
                 for i in range(3, n)]
        else:
            r = [x[i] - 4 * x[i - 1] + 6 * x[i - 2] - 4 * x[i - 3] + x[i - 4]
                 for i in range(4, n)]
        u = [(v << 1) if v >= 0 else ((-v) << 1) - 1 for v in r]
        bp = _best_partition(u, order, n, maxk)
        if bp is None:
            continue
        cost = order * bps + 2 + bp[0]
        if best is None or cost < best[0]:
            best = (cost, order, u, bp)
    if best is None or best[0] >= n * bps:
        bw.write(0, 1)
        bw.write(1, 6)
        bw.write(0, 1)
        for v in x:
            bw.write(v, bps)
        return
    cost, order, u, (pc, porder, params) = best
    bw.write(0, 1)
    bw.write(8 + order, 6)
    bw.write(0, 1)
    for v in x[:order]:
        bw.write(v, bps)
    method = 0 if max(params) < 15 else 1   # 4-bit parameters if possible
    pbits = 4 if method == 0 else 5
    bw.write(method, 2)
    bw.write(porder, 4)
    psize = n >> porder
    start = 0
    for p, k in enumerate(params):
        cnt = psize - order if p == 0 else psize
        bw.write(k, pbits)
        for v in u[start:start + cnt]:
            q = v >> k
            # unary quotient (q zeros then a one), then k low bits
            bw.write(1, q + 1)
            if k:
                bw.write(v, k)
        start += cnt


class _FlacOutput:
    """Encoder state of a FLAC signal file (one WFDB output group)."""

    def __init__(self, nsig, bps, spf):
        self.nsig = nsig
        self.bps = bps
        self.spf = spf
        self.chans = [[] for _ in range(nsig)]
        self.frame_no = 0
        self.total = 0
        self.minfs = None
        self.maxfs = 0
        import hashlib
        self.md5 = hashlib.md5()
        self.header_pos = 0
        self.pending = []       # samples of the current (incomplete) frame


def osinit(og, si, ns):
    """Prepare to write a FLAC signal group (flac_osinit)."""
    if ns > FLAC__MAX_CHANNELS:
        wfdb_error("osigfopen: cannot store %u signals in a single FLAC "
                   "file\n", ns)
        return -1
    for i in range(1, ns):
        if si[i].spf != si[0].spf:
            wfdb_error("osigfopen: every signal in a FLAC file must have\n"
                       "  the same sampling frequency\n")
            return -1
    og.flac = _FlacOutput(ns, si[0].fmt - 500, si[0].spf)
    og.bsize = ns * si[0].spf * 4   # one frame of 32-bit samples, as in C
    return 0


def _streaminfo(fo, total, md5):
    """The contents of the STREAMINFO metadata block."""
    bw = _BitWriter()
    bw.write(_BLOCKSIZE, 16)    # minimum block size
    bw.write(_BLOCKSIZE, 16)    # maximum block size
    bw.write(fo.minfs or 0, 24)
    bw.write(fo.maxfs, 24)
    bw.write(_SAMPLE_RATE, 20)
    bw.write(fo.nsig - 1, 3)
    bw.write(fo.bps - 1, 5)
    bw.write(total, 36)
    return bw.getbytes() + md5


def osopen(og):
    """Write the stream header (flac_osopen)."""
    fo = og.flac
    # A STREAMINFO block (rewritten by osclose; until then the total number
    # of samples is the largest possible value, as in signal.c), and a
    # VORBIS_COMMENT block (type 4, the last one) with no comments.
    vc = len(_VENDOR).to_bytes(4, "little") + _VENDOR + b"\0\0\0\0"
    hdr = b"fLaC" + bytes((0,)) + _STREAMINFO_LEN.to_bytes(3, "big") + \
        _streaminfo(fo, (1 << 36) - 1, b"\0" * 16) + \
        bytes((0x80 | 4,)) + len(vc).to_bytes(3, "big") + vc
    fo.header_pos = og.fp.tell() if og.fp is not None else 0
    if og.fp is not None:
        og.fp.write(hdr)
    return 0


def putsamp(v, fmt, og):
    """Append a sample to a FLAC output group (flac_putsamp)."""
    fo = og.flac
    # Wrap the sample to the resolution of the format.
    if fmt == 508:
        v = ((v + 0x80) & 0xFF) - 0x80
    elif fmt == 516:
        v = ((v + 0x8000) & 0xFFFF) - 0x8000
    elif fmt == 524:
        v = ((v + 0x800000) & 0xFFFFFF) - 0x800000
    pend = fo.pending
    pend.append(v)
    if len(pend) == fo.nsig * fo.spf:
        spf = fo.spf
        for c in range(fo.nsig):
            fo.chans[c].extend(pend[c * spf:(c + 1) * spf])
        del pend[:]
        if len(fo.chans[0]) >= _BLOCKSIZE:
            _write_block(og, _BLOCKSIZE)
    return 0


def _write_block(og, n):
    fo = og.flac
    block = [c[:n] for c in fo.chans]
    for c in fo.chans:
        del c[:n]
    nb = (fo.bps + 7) // 8
    inter = bytearray()
    for i in range(n):
        for c in block:
            inter += (c[i] & ((1 << (8 * nb)) - 1)).to_bytes(nb, "little")
    fo.md5.update(bytes(inter))
    # Frame header (see _read_frame_header).
    hb = _BitWriter()
    hb.write(0xFFF8 >> 1, 15)       # sync code and reserved bit
    hb.write(0, 1)                  # fixed block size
    if n == _BLOCKSIZE:
        bsc = 12                    # 4096
    elif n <= 256:
        bsc = 6                     # n - 1 in 8 bits
    else:
        bsc = 7                     # n - 1 in 16 bits
    hb.write(bsc, 4)
    hb.write(11, 4)                 # 96 kHz
    hb.write(fo.nsig - 1, 4)        # independent channels
    hb.write({8: 1, 16: 4, 24: 6}.get(fo.bps, 0), 3)
    hb.write(0, 1)
    head = hb.getbytes() + _utf8(fo.frame_no)
    if bsc == 6:
        head += bytes((n - 1,))
    elif bsc == 7:
        head += (n - 1).to_bytes(2, "big")
    head += bytes((_crc8(head),))
    bw = _BitWriter()
    for c in block:
        _encode_subframe(bw, c, fo.bps)
    bw.align()
    frame = head + bw.getbytes()
    frame += _crc16(frame).to_bytes(2, "big")
    if og.fp is not None:
        og.fp.write(frame)
    fo.frame_no += 1
    fo.total += n
    fs = len(frame)
    fo.minfs = fs if fo.minfs is None else min(fo.minfs, fs)
    fo.maxfs = max(fo.maxfs, fs)


def osclose(og):
    """Encode any remaining samples and finish the stream (flac_osclose)."""
    fo = og.flac
    while fo.chans and len(fo.chans[0]) > 0:
        _write_block(og, min(len(fo.chans[0]), _BLOCKSIZE))
    # Rewrite STREAMINFO, after "fLaC" and its 4-byte block header.
    if og.fp is not None and og.fp.seek(fo.header_pos + 8, 0) == 0:
        og.fp.write(_streaminfo(fo, fo.total, fo.md5.digest()))
        og.fp.seek(0, 2)
    og.flac = None
    og.buf = bytearray()
    return 0
