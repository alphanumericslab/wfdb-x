function [D, ok] = flac_decoder(op, D, arg)
%FLAC_DECODER libFLAC's stream decoder (frame by frame).
%   D = wfdbx.internal.flac_decoder('new', DATA, OPT) creates a decoder
%   (a structure) for the FLAC stream DATA (a uint8 vector: the whole
%   file).  OPT has the fields seekable (false if the file cannot be
%   positioned), md5 (true to compute the MD5 signature of the samples)
%   and ig: the input group (wfdbx.internal.IGData) that receives the
%   decoded samples (through wfdbx.internal.flac_samples) and whose
%   status the errors set (with a message), or [] to collect the samples
%   in D.out (a cell row of channels-by-samples blocks) and to throw each
%   error (identifier wfdbx:flac:STATUS, STATUS being 'sync', 'header',
%   'crc' or 'unparseable').
%
%   [D, OK] = wfdbx.internal.flac_decoder('process', D) decodes the next
%   metadata block or frame (FLAC__stream_decoder_process_single).
%   [D, OK] = wfdbx.internal.flac_decoder('seek', D, SAMPLE) positions the
%   decoder at a sample (FLAC__stream_decoder_seek_absolute); the frame
%   that holds it is decoded, from that sample on.
%   D = wfdbx.internal.flac_decoder('flush', D) empties the decoder's
%   input (FLAC__stream_decoder_flush).
%   [D, OK] = wfdbx.internal.flac_decoder('finish', D) checks the MD5
%   signature (FLAC__stream_decoder_finish): OK is false if it does not
%   match the samples decoded.
%
%   The decoder follows libFLAC's stream decoder (version 1.4.3) step by
%   step: its states (D.state: 0 search for metadata, 1 read metadata, 2
%   search for frame sync, 3 read frame, 4 end of stream, 5 aborted, 6
%   seek error, 7 memory allocation error), its search for frame sync
%   codes, its error statuses and the point at which it reports each one,
%   its recovery after a damaged frame (the return to just after the last
%   sync code), its binary search when seeking, the number of channels of
%   each frame, and the skipping of an ID3v2 tag.  The C library's
%   results on damaged files depend on all of these.  libFLAC reads its
%   input through a buffer of 8192 bytes; the buffer is modelled as far
%   as its contents affect the results.  Subframes are decoded with vector
%   operations (Rice codes by pointer doubling over the positions of the
%   one bits), and the refills of the buffer that their reads cause are
%   then replayed.
%
%   Part of WFDB-x; not in the original WFDB package.  A port of the
%   decoder of the Python implementation (python/src/wfdbx/_flac.py).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It is a MATLAB/Octave translation of the stream decoder of libFLAC 1.4.3
% (src/libFLAC/stream_decoder.c and bitreader.c, and the restore functions of
% fixed.c and lpc.c), made so that damaged files are decoded, resynchronized
% and reported exactly as by the C library, which uses libFLAC. The FLAC
% encoder (wfdbx.internal.flac_encode_frame) is WFDB-x's own. WFDB-x needs no
% external library at run time.
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.
%
% libFLAC is distributed under the following license, which applies to this
% file, a translation of it:
%
% Copyright (C) 2000-2009  Josh Coalson
% Copyright (C) 2011-2023  Xiph.Org Foundation
%
% Redistribution and use in source and binary forms, with or without
% modification, are permitted provided that the following conditions
% are met:
%
% - Redistributions of source code must retain the above copyright
% notice, this list of conditions and the following disclaimer.
%
% - Redistributions in binary form must reproduce the above copyright
% notice, this list of conditions and the following disclaimer in the
% documentation and/or other materials provided with the distribution.
%
% - Neither the name of the Xiph.org Foundation nor the names of its
% contributors may be used to endorse or promote products derived from
% this software without specific prior written permission.
%
% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
% ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
% LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
% A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE FOUNDATION OR
% CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
% EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
% PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
% PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
% LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
% NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
% SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

ok = true;
switch op
    case 'process'
        [D, ok] = process_single(D);
    case 'seek'
        [D, ok] = seek_absolute(D, arg);
    case 'flush'
        D = flush(D);
    case 'finish'
        ok = finish(D);
    case 'new'
        D = new_decoder(D, arg);
    otherwise
        error('wfdbx:flac:op', 'flac_decoder: unknown operation %s', op);
end
end

% States (FLAC__StreamDecoderState):
%   0 SEARCH_FOR_METADATA, 1 READ_METADATA, 2 SEARCH_FOR_FRAME_SYNC,
%   3 READ_FRAME, 4 END_OF_STREAM, 5 ABORTED, 6 SEEK_ERROR,
%   7 MEMORY_ALLOCATION_ERROR.
%
% A read that cannot get its bits (libFLAC's read callback fails) sets
% D.ni ("no input"): the reads that follow do nothing, and the function
% that catches the condition (where libFLAC returns false) clears it.

function D = new_decoder(data, opt)
D = struct();
D.data = reshape(uint8(data), 1, []);
D.nbytes = numel(D.data);
D.seekable = logical(opt.seekable);
D.ig = opt.ig;
D.out = {};
% Bit reader: the buffer holds bytes bstart to bend - 1 of the file (bend
% is the file position), endb = 8 * bend, and pos is the position (in
% bits) of the next bit to be read.  fsloc is the location (from bstart)
% of the last frame sync code seen, while it remains in the buffer ([]
% otherwise).
D.bstart = 0;
D.bend = 0;
D.endb = 0;
D.pos = 0;
D.fsloc = [];
D.feof = false;
D.ni = false;
D.state = 0;
D.cached = [];          % a byte read ahead while looking for sync
D.warmup = 0;           % the second byte of the frame sync code
D.has_stream_info = false;
D.min_blocksize = 0;
D.max_blocksize = 0;
D.min_framesize = 0;
D.max_framesize = 0;
D.si_rate = 0;
D.si_channels = 0;
D.si_bps = 0;
D.total_samples = 0;
D.si_md5 = zeros(1, 16, 'uint8');
D.seek_table = zeros(0, 3);     % sample (Inf: placeholder), offset, samples
D.fixed_block_size = 0;
D.next_fixed_block_size = 0;
D.samples_decoded = 0;
D.last_seen_framesync = 0;
% the last frame passed to the client: [sample number, block size, sample
% rate, channels, bits per sample], or []
D.last_frame = [];
D.channels = 0;         % of the last frame decoded
D.bps = 0;
D.is_seeking = false;
D.target_sample = 0;
D.unparseable_frame_count = 0;
D.first_frame_offset = 0;
D.do_md5_checking = logical(opt.md5);
D.md5parts = {};
% the header of the current frame
D.f_blocksize = 0;
D.f_rate = 0;
D.f_channels = 0;
D.f_assign = 0;
D.f_bps = 0;
D.f_sample = 0;
D.wsize = 4096;         % bytes in the bit window of a frame (see window)
end

% ---------------------------------------------------------------------------
% Bit reader

function D = fill(D)
% Read more input into the buffer (bitreader_read_from_client_,
% read_callback_ and the C library's iflac_read).
CAPACITY = 8192;        % bytes in the input buffer of libFLAC's bit reader
consumed = floor((D.pos - 8 * D.bstart) / 64);  % whole 8-byte words
if consumed > 0
    D.fsloc = [];
    D.bstart = D.bstart + 8 * consumed;
end
request = CAPACITY - (D.bend - D.bstart);
if request <= 0
    D.ni = true;
    return;
end
if D.feof
    D.state = 4;        % END_OF_STREAM
    D.ni = true;
    return;
end
if D.is_seeking && D.unparseable_frame_count > 20
    D.state = 5;        % ABORTED
    D.ni = true;
    return;
end
got = min(request, D.nbytes - D.bend);
if got < request
    D.feof = true;
end
if got <= 0
    D.state = 4;        % END_OF_STREAM
    D.ni = true;
    return;
end
D.bend = D.bend + got;
D.endb = 8 * D.bend;
end

function D = need(D, e)
% Refill the buffer (from the current position) until it holds the bits
% before position E.
while e > D.endb && ~D.ni
    D = fill(D);
end
end

function [v, D] = rd(D, n)
% Read an unsigned value of N bits (N <= 48).
v = 0;
if D.ni
    return;
end
p = D.pos;
e = p + n;
if e > D.endb
    D = need(D, e);
    if D.ni
        return;
    end
end
if n == 0
    return;
end
b0 = floor(p / 8);
b1 = ceil(e / 8);
x = double(D.data(b0+1:b1)) * (256 .^ (b1-b0-1:-1:0))';
v = mod(floor(x / 2^(8 * b1 - e)), 2^n);
D.pos = e;
end

function [v, D] = rds(D, n)
% Read a signed value of N bits.
[v, D] = rd(D, n);
if n > 0 && v >= 2^(n - 1)
    v = v - 2^n;
end
end

function [b, D] = rdbytes(D, n)
% Read N bytes (as one read of 8 * N bits), whatever the alignment.
b = zeros(1, n);
if D.ni
    return;
end
p = D.pos;
e = p + 8 * n;
if e > D.endb
    D = need(D, e);
    if D.ni
        return;
    end
end
B = tobits(D.data(floor(p / 8)+1:ceil(e / 8)));
B = B(mod(p, 8)+1:mod(p, 8)+8*n);
b = (2 .^ (7:-1:0)) * reshape(B, 8, n);
D.pos = e;
end

function [u, D] = unary(D)
% Count the zero bits up to (and consume) the next one bit.
u = 0;
if D.ni
    return;
end
p0 = D.pos;
p = p0;
while true
    bi = floor(p / 8);
    eb = D.bend;
    if bi < eb
        % the first byte (from bit p), then the next nonzero byte
        x = mod(double(D.data(bi+1)), 2^(8 - mod(p, 8)));
        if x == 0
            k = find(D.data(bi+2:eb), 1);
            if ~isempty(k)
                bi = bi + k;
                x = double(D.data(bi+1));
            end
        end
        if x ~= 0
            q = 8 * bi + 7 - floor(log2(x));    % the one bit
            D.pos = q + 1;
            u = q - p0;
            return;
        end
    end
    p = D.endb;
    D.pos = p;
    D = fill(D);
    if D.ni
        return;
    end
end
end

function D = skip_bytes(D, n)
target = D.pos + 8 * n;
while true
    D.pos = min(target, D.endb);
    if D.pos >= target
        return;
    end
    D = fill(D);
    if D.ni
        return;
    end
end
end

function D = clear_buffer(D)
% Empty the buffer (FLAC__bitreader_clear).
D.bstart = D.bend;
D.pos = 8 * D.bend;
D.endb = D.pos;
D.fsloc = [];
end

function [ok, D] = seek_file(D, pos)
% Move the file position (the C library's iflac_seek).
ok = D.seekable;
if ~ok
    return;
end
D.bend = pos;
D.endb = 8 * pos;
D.feof = false;
end

function p = decode_position(D)
% FLAC__stream_decoder_get_decode_position: the position in the file of
% the next byte to be decoded ([] if it is not known).
if ~D.seekable || mod(D.pos, 8)
    p = [];
else
    p = D.pos / 8;
end
end

function D = touch_reg(D, p0, cnt, w)
% The refills caused by CNT reads of W bits each, from bit P0: the
% position at a refill is the start of the read that needs it.
if w > 0 && cnt > 0
    while ~D.ni
        e = p0 + cnt * w;
        if e <= D.endb
            D.pos = e;
            return;
        end
        D.pos = p0 + floor((D.endb - p0) / w) * w;
        D = need(D, D.pos + w);
    end
else
    D.pos = p0;
end
end

function D = touch_rice(D, T, k, last)
% The refills caused by reading Rice codes (unary quotient, then K bits),
% whose one bits are at the positions T, from the current position; the
% K bits of the last code are not read if LAST is false.  A refill during
% a unary quotient is made at the end of the buffer, one during the K
% bits at their start.
m = numel(T);
E = T + 1 + k;
if ~last
    E(m) = T(m) + 1;
end
j = 1;
while ~D.ni && m > 0
    i = find(E(j:m) > D.endb, 1);
    if isempty(i)
        D.pos = E(m);
        return;
    end
    j = j + i - 1;
    while T(j) >= D.endb && ~D.ni
        D.pos = D.endb;
        D = fill(D);
    end
    if ~D.ni && E(j) > D.endb
        D.pos = T(j) + 1;
        D = need(D, E(j));
    end
end
end

function D = on_error(D, status)
% send_error_to_client_
if D.is_seeking
    if strcmp(status, 'unparseable')
        D.unparseable_frame_count = D.unparseable_frame_count + 1;
    end
    return;
end
if isempty(D.ig)
    error(['wfdbx:flac:' status], 'FLAC decoding error: %s', status);
end
switch status
    case 'sync'
        wfdbx.internal.wfdb_error('getvec: unable to decode FLAC (lost sync)\n');
    case 'header'
        wfdbx.internal.wfdb_error('getvec: unable to decode FLAC (invalid header)\n');
    case 'crc'
        wfdbx.internal.wfdb_error('getvec: unable to decode FLAC (CRC mismatch)\n');
    otherwise
        wfdbx.internal.wfdb_error('getvec: unable to decode FLAC (unsupported format)\n');
end
D.ig.stat = -2;
end

% ---------------------------------------------------------------------------
% Stream

function [D, ok] = process_single(D)
% FLAC__stream_decoder_process_single
while true
    switch D.state
        case 0
            [D, f] = find_metadata(D);
            if ~f
                ok = false;
                return;
            end
        case 1
            [D, ok] = read_metadata(D);
            return;
        case 2
            [D, f] = frame_sync(D);
            if ~f
                ok = true;
                return;
            end
        case 3
            [D, ok, got] = read_frame(D);
            if ~ok || got
                return;
            end
        case {4, 5}
            ok = true;
            return;
        otherwise
            ok = false;
            return;
    end
end
end

function [D, ok] = process_until_end_of_metadata(D)
while true
    switch D.state
        case 0
            [D, f] = find_metadata(D);
            if ~f
                ok = false;
                return;
            end
        case 1
            [D, f] = read_metadata(D);
            if ~f
                ok = false;
                return;
            end
        case {2, 3, 4, 5}
            ok = true;
            return;
        otherwise
            ok = false;
            return;
    end
end
end

function [D, f] = find_metadata(D)
% Look for the stream marker 'fLaC', skipping an ID3v2 tag.
FLAC = [102 76 97 67];      % 'fLaC'
ID3 = [73 68 51];           % 'ID3'
f = false;
i = 0;
id3 = 0;
first = true;
while i < 4
    if ~isempty(D.cached)
        x = D.cached;
        D.cached = [];
    else
        [x, D] = rd(D, 8);
        if D.ni
            D.ni = false;
            return;
        end
    end
    if x == FLAC(i + 1)
        first = true;
        i = i + 1;
        id3 = 0;
        continue;
    end
    if id3 >= 3
        return;
    end
    if x == ID3(id3 + 1)
        id3 = id3 + 1;
        i = 0;
        if id3 == 3
            [~, D] = rd(D, 24);         % version and flags
            skip = 0;
            for k = 1:4
                [y, D] = rd(D, 8);
                skip = 128 * skip + mod(y, 128);
            end
            D = skip_bytes(D, skip);
            if D.ni
                D.ni = false;
                return;
            end
        end
        continue;
    end
    id3 = 0;
    if x == 255
        [x, D] = rd(D, 8);
        if D.ni
            D.ni = false;
            return;
        end
        if x == 255
            D.cached = x;
        elseif floor(x / 2) == 124
            D.warmup = x;
            D.state = 3;
            f = true;
            return;
        end
    end
    i = 0;
    if first
        D = on_error(D, 'sync');
        first = false;
    end
end
D.state = 1;
f = true;
end

function [D, ok] = read_metadata(D)
% Read one metadata block.  Only STREAMINFO and SEEKTABLE are examined;
% libFLAC skips the others (as the C library does not ask for them).
ok = false;
[is_last, D] = rd(D, 1);
[typ, D] = rd(D, 7);
[len, D] = rd(D, 24);
if D.ni
    D.ni = false;
    return;
end
if typ == 0                 % STREAMINFO
    names = {'min_blocksize', 16; 'max_blocksize', 16; ...
        'min_framesize', 24; 'max_framesize', 24; 'si_rate', 20; ...
        'si_channels', 3; 'si_bps', 5; 'total_samples', 36};
    for k = 1:size(names, 1)
        [v, D] = rd(D, names{k, 2});
        if D.ni
            D.ni = false;
            return;
        end
        if k == 6 || k == 7
            v = v + 1;
        end
        D.(names{k, 1}) = v;
    end
    [b, D] = rdbytes(D, 16);
    if D.ni
        D.ni = false;
        return;
    end
    D.si_md5 = uint8(b);
    if len < 34
        return;
    end
    D = skip_bytes(D, len - 34);
    if D.ni
        D.ni = false;
        return;
    end
    D.has_stream_info = true;
    if ~any(D.si_md5)
        D.do_md5_checking = false;
    end
elseif typ == 3             % SEEKTABLE
    D.seek_table = zeros(0, 3);
    if len > 0
        if mod(len, 18)
            return;
        end
        np = len / 18;
        points = zeros(np, 3);
        for k = 1:np
            [b, D] = rdbytes(D, 8);
            [o, D] = rdbytes(D, 8);
            [ns, D] = rd(D, 16);
            if D.ni
                D.ni = false;
                return;
            end
            if all(b == 255)
                points(k, 1) = Inf;     % a placeholder point
            else
                points(k, 1) = b * (256 .^ (7:-1:0))';
            end
            points(k, 2) = o * (256 .^ (7:-1:0))';
            points(k, 3) = ns;
        end
        D.seek_table = points;
    end
else
    if typ == 2             % APPLICATION: an identifier first
        [~, D] = rd(D, 32);
        if D.ni
            D.ni = false;
            return;
        end
        if len < 4
            D.state = 7;    % MEMORY_ALLOCATION_ERROR
            return;
        end
        len = len - 4;
    end
    D = skip_bytes(D, len);
    if D.ni
        D.ni = false;
        return;
    end
end
if is_last
    p = decode_position(D);
    if isempty(p)
        p = 0;
    end
    D.first_frame_offset = p;
    D.state = 2;
end
ok = true;
end

function [D, f] = frame_sync(D)
% Look for the next frame sync code.
f = false;
first = true;
if mod(D.pos, 8)
    [~, D] = rd(D, 8 - mod(D.pos, 8));
    if D.ni
        D.ni = false;
        return;
    end
end
while true
    if ~isempty(D.cached)
        x = D.cached;
        D.cached = [];
    else
        % (skip quickly to the next 0xFF byte in the buffer)
        p = D.pos / 8;
        if p >= D.bend
            D = fill(D);
            if D.ni
                D.ni = false;
                return;
            end
            continue;
        end
        q = find(D.data(p+1:D.bend) == 255, 1);
        if isempty(q) || q > 1
            if first
                D = on_error(D, 'sync');
                first = false;
            end
            if isempty(q)
                D.pos = D.endb;
                D = fill(D);
                if D.ni
                    D.ni = false;
                    return;
                end
                continue;
            end
            D.pos = 8 * (p + q - 1);
        end
        [x, D] = rd(D, 8);
    end
    if x == 255
        [x, D] = rd(D, 8);
        if D.ni
            D.ni = false;
            return;
        end
        if x == 255
            D.cached = x;
        elseif floor(x / 2) == 124
            D.warmup = x;
            D.state = 3;
            D.fsloc = D.pos / 8 - D.bstart;
            p = decode_position(D);
            if isempty(p)
                p = 0;
            end
            D.last_seen_framesync = p;
            f = true;
            return;
        end
    end
    if first
        D = on_error(D, 'sync');
        first = false;
    end
end
end

% ---------------------------------------------------------------------------
% Frames

function [D, ok, got] = read_frame(D)
% Read one frame.
ok = false;
got = false;
start = D.pos / 8 - 2;      % (the frame sync code)
D = read_frame_header(D);
if D.ni
    D.ni = false;
    return;
end
if D.state == 2
    ok = true;
    return;
end
nch = D.f_channels;
bs = D.f_blocksize;
assign = D.f_assign;
chans = zeros(nch, bs);
% the bits of the frame (a window from its start, enlarged as needed)
W.p0 = 8 * start;
W.B = [];
W.atend = false;
for ch = 0:nch-1
    bps = D.f_bps;
    if (assign == 8 && ch == 1) || (assign == 9 && ch == 0) || ...
            (assign == 10 && ch == 1)
        bps = bps + 1;              % the side channel
    end
    [D, out, W] = read_subframe(D, bps, bs, W);
    if D.ni
        D.ni = false;
        if D.state == 4
            break;
        end
        return;
    end
    if D.state ~= 3
        break;
    end
    chans(ch + 1, :) = out;
end
if D.state ~= 4
    % zero padding to the end of the byte
    if mod(D.pos, 8)
        [x, D] = rd(D, 8 - mod(D.pos, 8));
        if D.ni
            D.ni = false;
            return;
        end
        if x
            D = on_error(D, 'sync');
            D.state = 2;
        end
    end
end
if D.state == 3
    crc = wfdbx.internal.flac_crc(D.data(start+1:D.pos/8), 16);
    [x, D] = rd(D, 16);
    if D.ni
        D.ni = false;
        if D.state ~= 4
            return;
        end
    end
    if D.state == 3
        if crc == x
            [chans, good] = undo_channel_coding(chans, assign, D.f_bps);
            if ~good
                D = on_error(D, 'crc');
                D.state = 2;
            end
        else
            D = on_error(D, 'crc');
            D.state = 2;
        end
    end
end
sn = D.f_sample;
if ~isempty(D.last_frame) && D.state == 3 && ~D.is_seeking
    [D, good] = pad_missing_samples(D, sn);
    if ~good
        return;
    end
end
if D.state == 2 || D.state == 4
    % a damaged frame: go back to just after its sync code
    if ~isempty(D.fsloc)
        D.pos = 8 * (D.bstart + D.fsloc + 1);
    else
        D.pos = 8 * D.bstart;
        if D.last_seen_framesync
            [good, D] = seek_file(D, D.last_seen_framesync);
            if ~good
                D.state = 6;        % SEEK_ERROR
                return;
            end
            D = clear_buffer(D);
        end
    end
    D.state = 2;
    ok = true;
    return;
end
if D.next_fixed_block_size
    D.fixed_block_size = D.next_fixed_block_size;
end
D.wsize = max(4096, 2 * (D.pos / 8 - start) + 64);   % (for the next frame)
D.channels = nch;
D.bps = D.f_bps;
D.samples_decoded = sn + bs;
[D, good] = write_frame(D, sn, bs, D.f_rate, nch, D.f_bps, chans);
if ~good
    D.state = 5;        % ABORTED
    return;
end
D.state = 2;
ok = true;
got = true;
end

function D = bad_header(D, back)
D.cached = back;
D = on_error(D, 'header');
D.state = 2;
end

function [v, raw, D] = read_utf8(D, raw, wide)
% A frame or sample number ([] if its coding is invalid).
v = [];
[x, D] = rd(D, 8);
if D.ni
    return;
end
raw(end + 1) = x;
if x < 128
    v = x;
    return;
end
if ~bitand(x, 32)
    v = mod(x, 32);
    n = 1;
elseif ~bitand(x, 16)
    v = mod(x, 16);
    n = 2;
elseif ~bitand(x, 8)
    v = mod(x, 8);
    n = 3;
elseif ~bitand(x, 4)
    v = mod(x, 4);
    n = 4;
elseif ~bitand(x, 2)
    v = mod(x, 2);
    n = 5;
elseif wide && ~bitand(x, 1)
    v = 0;
    n = 6;
else
    return;
end
for k = 1:n
    [x, D] = rd(D, 8);
    if D.ni
        v = [];
        return;
    end
    raw(end + 1) = x; %#ok<AGROW>
    if bitand(x, 192) ~= 128
        v = [];
        return;
    end
    v = 64 * v + mod(x, 64);
end
end

function D = read_frame_header(D)
BS_TABLE = [192 576 1152 2304 4608 0 0 256 512 1024 2048 4096 8192 ...
    16384 32768];
BPS_TABLE = [8 12 0 16 20 24 32];
RATE_TABLE = [88200 176400 192000 8000 16000 22050 24000 32000 44100 ...
    48000 96000];
raw = [255, D.warmup];
unparseable = bitand(raw(2), 2) ~= 0;
for k = 1:2
    [x, D] = rd(D, 8);
    if D.ni
        return;
    end
    if x == 255
        % (a sync code cannot occur in a frame header)
        D = bad_header(D, x);
        return;
    end
    raw(end + 1) = x; %#ok<AGROW>
end
bsc = floor(raw(3) / 16);
blocksize_hint = 0;
if bsc == 0
    unparseable = true;
elseif bsc == 6 || bsc == 7
    blocksize_hint = bsc;
else
    D.f_blocksize = BS_TABLE(bsc);
end
src = mod(raw(3), 16);
rate_hint = 0;
if src == 0
    if D.has_stream_info
        D.f_rate = D.si_rate;
    else
        unparseable = true;
    end
elseif src <= 11
    D.f_rate = RATE_TABLE(src);
elseif src <= 14
    rate_hint = src;
else
    D = bad_header(D, []);
    return;
end
x = floor(raw(4) / 16);
if x >= 8
    D.f_channels = 2;
    if mod(x, 8) <= 2
        D.f_assign = x;
    else
        unparseable = true;
    end
else
    D.f_channels = x + 1;
    D.f_assign = 0;
end
ssc = floor(mod(raw(4), 16) / 2);
if ssc == 0
    if D.has_stream_info
        D.f_bps = D.si_bps;
    else
        unparseable = true;
    end
elseif ssc == 3
    unparseable = true;
else
    D.f_bps = BPS_TABLE(ssc);
end
if mod(raw(4), 2)
    unparseable = true;
end
is_sample = mod(raw(2), 2) || (D.has_stream_info && ...
    D.min_blocksize ~= D.max_blocksize);
[number, raw, D] = read_utf8(D, raw, is_sample);
if D.ni
    return;
end
if isempty(number)
    D = bad_header(D, raw(end));
    return;
end
if blocksize_hint
    [x, D] = rd(D, 8);
    if D.ni
        return;
    end
    raw(end + 1) = x;
    if blocksize_hint == 7
        [y, D] = rd(D, 8);
        if D.ni
            return;
        end
        raw(end + 1) = y;
        x = 256 * x + y;
    end
    D.f_blocksize = x + 1;
    if D.f_blocksize > 65535
        D = bad_header(D, raw(end));
        return;
    end
end
if rate_hint
    [x, D] = rd(D, 8);
    if D.ni
        return;
    end
    raw(end + 1) = x;
    if rate_hint ~= 12
        [y, D] = rd(D, 8);
        if D.ni
            return;
        end
        raw(end + 1) = y;
        x = 256 * x + y;
    end
    if rate_hint == 12
        D.f_rate = 1000 * x;
    elseif rate_hint == 13
        D.f_rate = x;
    else
        D.f_rate = 10 * x;
    end
end
[crc, D] = rd(D, 8);
if D.ni
    return;
end
if wfdbx.internal.flac_crc(raw, 8) ~= crc
    D = bad_header(D, []);
    return;
end
D.next_fixed_block_size = 0;
if ~is_sample
    if D.fixed_block_size
        number = number * D.fixed_block_size;
    elseif D.has_stream_info
        if D.min_blocksize == D.max_blocksize
            number = number * D.min_blocksize;
            D.next_fixed_block_size = D.max_blocksize;
        else
            unparseable = true;
        end
    elseif number == 0
        D.next_fixed_block_size = D.f_blocksize;
    else
        number = number * D.f_blocksize;
    end
end
D.f_sample = number;
if unparseable
    D = on_error(D, 'unparseable');
    D.state = 2;
end
end

% ---------------------------------------------------------------------------
% Subframes
%
% A subframe's fields are decoded from W.B, the bits of the frame from bit
% W.p0 (enlarged when needed); the refills of the buffer that libFLAC
% makes while reading them are then replayed (touch_reg, touch_rice).  A
% decoding error (lost sync, unsupported format) sets D.state; an error
% that libFLAC finds only after reading the end of the input is not
% reported (the end of the stream comes first).

function [D, out, W] = read_subframe(D, bps, bs, W)
out = [];
[x, D] = rd(D, 8);
if D.ni
    return;
end
wasted = 0;
if mod(x, 2)
    [u, D] = unary(D);
    if D.ni
        return;
    end
    wasted = u + 1;
    if wasted >= bps
        D = lost_sync(D);
        return;
    end
    bps = bps - wasted;
end
x = x - mod(x, 2);
if x >= 128
    D = lost_sync(D);
    return;
end
if x == 0                           % CONSTANT
    [v, D] = rds(D, bps);
    if D.ni
        return;
    end
    out = v + zeros(1, bs);
elseif x == 2                       % VERBATIM
    [out, D, W] = rdvec(D, W, bs, bps);
elseif x < 16
    D = unparseable_format(D);
    return;
elseif x <= 24                      % FIXED
    order = mod(x / 2, 8);
    if bs <= order
        D = lost_sync(D);
        return;
    end
    [out, D, W] = read_fixed(D, W, bps, bs, order);
elseif x < 64
    D = unparseable_format(D);
    return;
else                                % LPC
    order = mod(x / 2, 32) + 1;
    if bs <= order
        D = lost_sync(D);
        return;
    end
    [out, D, W] = read_lpc(D, W, bps, bs, order);
end
if D.ni || isempty(out)
    out = [];
    return;
end
if wasted
    out = out * 2^wasted;
end
end

function D = lost_sync(D)
D = on_error(D, 'sync');
D.state = 2;
end

function D = unparseable_format(D)
D = on_error(D, 'unparseable');
D.state = 2;
end

function [W, ok] = window(D, W, p, nbits)
% W, holding the bits P to P + NBITS - 1 if the file has them (OK false
% if it does not: W then reaches the end of the file).
ok = true;
if ~isempty(W.B) && p >= W.p0 && p + nbits <= W.p0 + numel(W.B)
    return;
end
if W.atend && p >= W.p0
    ok = false;
    return;
end
b0 = floor(min(p, W.p0) / 8);
if ~isempty(W.B)
    have = numel(W.B) / 8;
else
    have = 0;
end
nb = max([D.wsize, 2 * have, ceil((p + nbits) / 8) - b0 + 1024]);
b1 = min(D.nbytes, b0 + nb);
W.p0 = 8 * b0;
W.B = tobits(D.data(b0+1:b1));
W.atend = b1 == D.nbytes;
ok = p + nbits <= W.p0 + numel(W.B);
end

function [v, D, W] = rdvec(D, W, cnt, n)
% Read CNT signed values of N bits.
v = zeros(1, cnt);
if D.ni
    return;
end
p0 = D.pos;
if cnt == 0 || n == 0
    D = touch_reg(D, p0, cnt, n);
    return;
end
[W, ok] = window(D, W, p0, cnt * n);
if ~ok
    % (the file ends before them: the reads find the end of the input)
    D = touch_reg(D, p0, cnt, n);
    if ~D.ni
        D = need(D, 8 * D.nbytes + 1);
    end
    return;
end
o = p0 - W.p0;
M = reshape(W.B(o+1:o+cnt*n), n, cnt);
v = pow2(n-1:-1:0) * M;
v = v - (v >= 2^(n-1)) * 2^n;
D = touch_reg(D, p0, cnt, n);
end

function [s, D, W] = read_fixed(D, W, bps, bs, order)
[w, D, W] = rdvec(D, W, order, bps);
s = [];
if D.ni
    return;
end
[r, D, W] = read_coding(D, W, bs, order);
if isempty(r) && bs > order
    return;
end
if order == 0
    s = r;
    return;
end
s = [w, zeros(1, bs - order)];
% s = order-fold cumulative sums of the residuals, starting from the
% differences of the warm-up samples
d = w;
last = zeros(1, order);
for m = 0:order-1
    last(m+1) = d(end);
    d = diff(d);
end
x = r;
for m = order-1:-1:0
    x = last(m+1) + cumsum(x);
end
s(order+1:end) = x;
end

function [s, D, W] = read_lpc(D, W, bps, bs, order)
s = [];
[w, D, W] = rdvec(D, W, order, bps);
[prec, D] = rd(D, 4);           % coefficient precision - 1
if D.ni
    return;
end
if prec == 15
    D = lost_sync(D);
    return;
end
prec = prec + 1;
[shift, D] = rds(D, 5);
if D.ni
    return;
end
if shift < 0
    D = lost_sync(D);
    return;
end
[coefs, D, W] = rdvec(D, W, order, prec);
if D.ni
    return;
end
[r, D, W] = read_coding(D, W, bs, order);
if isempty(r) && bs > order
    return;
end
% s(i) = r(i) + floor(sum(c .* s(i-order:i-1)) / 2^shift)
c = fliplr(coefs)';
n = bs;
s = zeros(1, n);
s(1:order) = w;
d = 2^shift;
for i = order+1:n
    s(i) = r(i-order) + floor(s(i-order:i-1) * c / d);
end
end

function [out, D, W] = read_coding(D, W, bs, order)
% The entropy coding method and partition order, then the residual ([]
% after an error).
out = [];
[method, D] = rd(D, 2);
if D.ni
    return;
end
if method > 1
    D = unparseable_format(D);
    return;
end
[porder, D] = rd(D, 4);
if D.ni
    return;
end
if floor(bs / 2^porder) < order || mod(bs, 2^porder)
    D = lost_sync(D);
    return;
end
[out, D, W] = read_residual(D, W, bs, order, porder, method);
end

function [out, D, W] = read_residual(D, W, bs, order, porder, method)
% Rice parameters have 4 bits (method 0) or 5 bits (method 1); the
% all-ones parameter is an escape code for unencoded residuals.
if method == 0
    pbits = 4;
    esc = 15;
else
    pbits = 5;
    esc = 31;
end
psize = bs / 2^porder;
out = zeros(1, bs - order);
o = 0;
for part = 1:2^porder
    if part == 1
        n = psize - order;
    else
        n = psize;
    end
    [k, D] = rd(D, pbits);
    if D.ni
        out = [];
        return;
    end
    if k == esc
        [nb, D] = rd(D, 5);         % bits per unencoded residual
        if D.ni
            out = [];
            return;
        end
        if nb == 0
            v = zeros(1, n);
        else
            [v, D, W] = rdvec(D, W, n, nb);
        end
    else
        [v, D, W] = rice_codes(D, W, n, k);
    end
    if D.ni || D.state ~= 3
        out = [];
        return;
    end
    out(o+1:o+n) = v;
    o = o + n;
end
end

function [v, D, W] = rice_codes(D, W, n, k)
% Read N Rice codes with parameter K.  libFLAC rejects a quotient too
% large for 32 bits (its position is then that of the first code).
v = zeros(1, n);
if n == 0
    return;
end
p0 = D.pos;
win = n * (k + 4) + 256;
while true
    o = p0 - W.p0;
    if isempty(W.B) || o < 0 || o + win > numel(W.B)
        W = window(D, W, p0, win);
        o = p0 - W.p0;
    end
    e = min(numel(W.B), o + win);
    seg = W.B(o+1:e);
    [T, m] = rice_ones(seg, n, k);  % one bits (relative to p0), complete codes
    if m == n || (e == numel(W.B) && W.atend)
        break;
    end
    win = 4 * win;
end
T = p0 + T;
q = T - [p0, T(1:end-1) + 1 + k];      % the quotients
if k > 0
    limit = floor(4294967295 / 2^k);
    bad = find(q > limit, 1);
    if ~isempty(bad)
        D = touch_rice(D, T(1:bad), k, false);
        if ~D.ni
            D.pos = p0;
            D = lost_sync(D);
        end
        return;
    end
end
if m < n
    % (the file ends within code m + 1: its reads find the end of the
    % input)
    D = touch_rice(D, T(1:m), k, true);
    if ~D.ni
        [~, D] = unary(D);
        [~, D] = rd(D, k);
        if ~D.ni
            D = need(D, 8 * D.nbytes + 1);
        end
    end
    return;
end
if T(n) + 1 + k <= D.endb
    D.pos = T(n) + 1 + k;       % (no refill)
else
    D = touch_rice(D, T, k, true);
    if D.ni
        return;
    end
end
% the values: the quotient, then k bits, folded (zigzag)
u = q * 2^k;
if k > 0
    lo = zeros(1, n);
    o = T - p0;
    for j = 1:k
        lo = 2 * lo + seg(o + 1 + j);
    end
    u = u + lo;
end
h = floor(u / 2);
v = h;
odd = u - 2 * h == 1;
v(odd) = -h(odd) - 1;
end

function [T, m] = rice_ones(seg, n, k)
% The positions (0-based, in the bits SEG) of the one bits ending the
% unary quotients of N consecutive Rice codes with parameter K from the
% start of SEG; M is the number of codes complete in SEG (T has M
% elements, or M + 1 if the quotient of code M + 1 ends in SEG).
O = find(seg) - 1;                  % positions of the ones
M = numel(O);
len = numel(seg);
if k == 0
    m = min(n, M);
    T = O(1:m);
    return;
end
if M == 0
    T = zeros(1, 0);
    m = 0;
    return;
end
% index (into O) of the first one at or after the start of the next code
cnt = [0, cumsum(seg)];             % cnt(p + 1) = ones before position p
q = O + 1 + k;                      % start of the next code
J = (M + 1) * ones(1, M + 1);
inside = q < len;
J(inside) = cnt(q(inside) + 1) + 1;
J(J > M) = M + 1;
% the n codes: idx(i) = J^(i-1)(1), by pointer doubling (idx holds the
% first codes, and P = J^numel(idx) gives the next ones)
idx = 1;
P = J;
while numel(idx) < n
    idx = [idx, P(idx)]; %#ok<AGROW>
    if numel(idx) >= n
        break;
    end
    P = P(P);
end
idx = idx(1:n);
% complete codes: their one bit and their k bits in SEG
good = idx <= M;
good(good) = O(idx(good)) + k < len;
m = find(~good, 1) - 1;
if isempty(m)
    m = n;
end
if m < n && idx(m + 1) <= M
    T = O(idx(1:m + 1));
else
    T = O(idx(1:m));
end
end

function [chans, ok] = undo_channel_coding(chans, assign, fbps)
% Restore left and right channels from side channels, and check that the
% samples fit the sample size (OK false if they do not).
ok = true;
if assign == 8                      % left/side
    chans(2, :) = chans(1, :) - chans(2, :);
elseif assign == 9                  % side/right
    chans(1, :) = chans(1, :) + chans(2, :);
elseif assign == 10                 % mid/side
    m = 2 * chans(1, :) + mod(chans(2, :), 2);
    sd = chans(2, :);
    chans = [floor((m + sd) / 2); floor((m - sd) / 2)];
end
lo = -2^(fbps - 1);
hi = -lo - 1;
for i = 1:size(chans, 1)
    c = chans(i, :);
    if ~isempty(c) && ~all(c >= lo & c <= hi)
        c = mod(c + 2147483648, 4294967296) - 2147483648;
        chans(i, :) = c;
        if ~all(c >= lo & c <= hi)
            ok = false;
            return;
        end
    end
end
end

function [D, ok] = pad_missing_samples(D, sn)
% Fill a gap between the previous frame and this one with silence, as
% libFLAC does for missing frames (OK false if decoding is aborted).
ok = true;
lf = D.last_frame;
lsn = lf(1);
lbs = lf(2);
lrate = lf(3);
lch = lf(4);
lbps = lf(5);
if lsn + lbs >= sn
    return;
end
need = mod(sn - (lsn + lbs), 4294967296);
if lrate ~= D.f_rate || lch ~= D.f_channels || lbps ~= D.f_bps || lbs < 16
    return;
end
need = min([need, mod(5 * lrate, 4294967296), 50 * lbs]);
while need
    lsn = lsn + lbs;
    if need < lbs
        lbs = need;
    end
    need = need - lbs;
    D.samples_decoded = lsn + lbs;
    [D, ok] = write_frame(D, lsn, lbs, lrate, lch, lbps, zeros(lch, lbs));
    if ~ok
        D.state = 5;        % ABORTED
        return;
    end
end
end

function [D, ok] = write_frame(D, sn, bs, rate, nch, bps, chans)
% write_audio_frame_to_client_
D.last_frame = [sn, bs, rate, nch, bps];
if D.is_seeking
    target = D.target_sample;
    if sn <= target && target < sn + bs     % the target frame
        delta = target - sn;
        D.is_seeking = false;
        if delta
            chans = chans(:, delta+1:end);
            D.last_frame = [sn + delta, bs - delta, rate, nch, bps];
        end
        [D, ok] = client_write(D, chans);
        return;
    end
    ok = true;
    return;
end
if ~D.has_stream_info
    D.do_md5_checking = false;
end
if D.do_md5_checking
    % (each sample in nb bytes, little-endian, the channels interleaved)
    nb = floor((bps + 7) / 8);
    b = reshape(typecast(int32(reshape(chans, 1, [])), 'uint8'), 4, []);
    b = b(1:nb, :);
    D.md5parts{end + 1} = reshape(b, 1, []);
end
[D, ok] = client_write(D, chans);
end

function [D, ok] = client_write(D, chans)
% The write callback: the samples go to the input group, or to D.out.
if isempty(D.ig)
    if ~isempty(D.out) && size(chans, 1) ~= size(D.out{1}, 1)
        error('wfdbx:flac:unparseable', 'FLAC decoding error: unparseable');
    end
    D.out{end + 1} = chans;
    ok = true;
else
    ok = wfdbx.internal.flac_samples(D.ig, chans, D.f_bps);
end
end

% ---------------------------------------------------------------------------
% Seeking

function D = flush(D)
% FLAC__stream_decoder_flush
D.samples_decoded = 0;
D.do_md5_checking = false;
D.last_seen_framesync = 0;
D.last_frame = [];
D = clear_buffer(D);
D.state = 2;
end

function [D, ok] = seek_absolute(D, sample)
% FLAC__stream_decoder_seek_absolute
ok = false;
if D.state > 4
    return;
end
if D.has_stream_info
    total = D.total_samples;
else
    total = 0;
end
if total > 0 && sample >= total
    return;
end
D.is_seeking = true;
D.do_md5_checking = false;
if ~D.seekable                  % (the length is not known)
    D.is_seeking = false;
    return;
end
D.feof = false;                 % (finding the length seeks)
if D.state == 0 || D.state == 1
    [D, good] = process_until_end_of_metadata(D);
    if ~good
        D.is_seeking = false;
        return;
    end
    if D.has_stream_info
        total = D.total_samples;
    else
        total = 0;
    end
    if total > 0 && sample >= total
        D.is_seeking = false;
        return;
    end
end
[D, ok] = seek_to_absolute_sample(D, D.nbytes, sample);
D.is_seeking = false;
end

function [D, ok] = seek_to_absolute_sample(D, stream_length, target)
% seek_to_absolute_sample_: a binary search for the frame that holds the
% target sample.
ok = false;
U32 = 4294967296;
if D.has_stream_info
    total = D.total_samples;
else
    total = 0;
end
channels = D.channels;
if channels == 0
    channels = D.si_channels;
end
bps = D.bps;
if bps == 0
    bps = D.si_bps;
end
if D.max_framesize > 0
    approx = floor((D.max_framesize + D.min_framesize) / 2) + 1;
elseif D.min_blocksize == D.max_blocksize && D.min_blocksize > 0
    approx = floor(mod(D.min_blocksize * channels * bps, U32) / 8) + 64;
else
    approx = floor(mod(4096 * channels * bps, U32) / 8) + 64;
end
approx = mod(approx, U32);
lower = D.first_frame_offset;
lower_sample = 0;
upper = stream_length;
if total > 0
    upper_sample = total;
else
    upper_sample = target;
end
if D.state == 2 && D.samples_decoded
    p = decode_position(D);
    if target < D.samples_decoded
        if ~isempty(p)
            upper = p;
            upper_sample = D.samples_decoded;
        end
    elseif ~isempty(p)
        lower = p;
        lower_sample = D.samples_decoded;
    end
end
if ~isempty(D.seek_table)
    st = D.seek_table;
    usable = st(:, 1) ~= Inf & st(:, 3) > 0;
    if total > 0
        usable = usable & st(:, 1) < total;
    end
    new_lower = lower;
    new_upper = upper;
    new_lower_sample = lower_sample;
    new_upper_sample = upper_sample;
    k = find(usable & st(:, 1) <= target, 1, 'last');
    if ~isempty(k)
        new_lower = D.first_frame_offset + st(k, 2);
        new_lower_sample = st(k, 1);
    end
    k = find(usable & st(:, 1) > target, 1);
    if ~isempty(k)
        new_upper = D.first_frame_offset + st(k, 2);
        new_upper_sample = st(k, 1);
    end
    if new_upper >= new_lower
        lower = new_lower;
        upper = new_upper;
        lower_sample = new_lower_sample;
        upper_sample = new_upper_sample;
    end
end
if upper_sample == lower_sample
    upper_sample = upper_sample + 1;
end
D.target_sample = target;
first_seek = true;
from_lower = false;
while true
    if D.state == 7 || D.state == 5
        return;
    end
    if lower_sample >= upper_sample || lower > upper || upper >= 2^63 - 1
        D.state = 6;        % SEEK_ERROR
        return;
    end
    if from_lower
        pos = lower;
    else
        pos = lower + fix(u64(target - lower_sample) / ...
            u64(upper_sample - lower_sample) * (upper - lower)) - approx;
    end
    if pos >= upper
        pos = upper - 1;
    end
    if pos < lower
        pos = lower;
    end
    [good, D] = seek_file(D, pos);
    if ~good
        D.state = 6;
        return;
    end
    D = flush(D);
    D.unparseable_frame_count = 0;
    [D, good] = process_single(D);
    if ~good || D.state == 5 || D.samples_decoded == 0
        % no frame could be decoded
        if D.state ~= 5 && D.feof && ~from_lower
            from_lower = true;
            continue;
        end
        D.state = 6;
        return;
    end
    from_lower = false;
    if ~D.is_seeking
        break;
    end
    this_sample = D.last_frame(1);
    this_bs = D.last_frame(2);
    if this_sample + this_bs >= upper_sample && ~first_seek
        if pos == lower
            D.state = 6;
            return;
        end
        if approx
            approx = mod(2 * approx, U32);
        else
            approx = 16;
        end
        continue;
    end
    first_seek = false;
    if this_sample < lower_sample
        D.state = 6;
        return;
    end
    p = decode_position(D);
    if isempty(p)
        D.state = 6;
        return;
    end
    if target < this_sample
        upper_sample = this_sample + this_bs;
        upper = p;
        approx = mod(floor(u64(upper - pos) * 2 / 3) + 16, U32);
    else
        lower_sample = this_sample + this_bs;
        lower = p;
        approx = mod(floor(u64(lower - pos) * 2 / 3) + 16, U32);
    end
end
ok = true;
end

function x = u64(x)
% x & 0xFFFFFFFFFFFFFFFF (as a double)
if x < 0
    x = x + 2^64;
end
end

function ok = finish(D)
% FLAC__stream_decoder_finish: false if the MD5 signature does not match
% the samples decoded.
ok = true;
if D.do_md5_checking
    ok = isequal(wfdbx.internal.md5([D.md5parts{:}]), D.si_md5);
end
end

function B = tobits(bytes)
B = reshape(mod(floor(double(bytes) ./ [128; 64; 32; 16; 8; 4; 2; 1]), 2), 1, []);
end
