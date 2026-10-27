classdef WFDBFile < handle
%WFDBFILE A WFDB_FILE: an open file, or the standard input or output.
%   Objects of this class are returned by wfdbx.internal.wfdb_open and
%   wfdbx.internal.wfdb_fopen ([] stands for a C NULL pointer).  Their
%   methods emulate the C stdio functions used by the WFDB library:
%
%     B = f.read(N)       fread of up to N bytes (uint8 row; fewer at EOF)
%     B = f.readall()     the rest of the file (uint8 row)
%     C = f.getc()        next byte (0-255), or -1 at end of file
%     N = f.write(B)      fwrite of a uint8 or char vector; returns N
%     f.putc(C)           write one byte (C taken modulo 256)
%     N = f.printf(FMT, ...)  fprintf with C semantics (wfdbx.internal.csprintf)
%     S = f.getline()     wfdb_getline: the next line with its newline
%                         (char); '' at end of file
%     X = f.g16()         16-bit little-endian signed integer (wfdb_g16)
%     X = f.g32()         32-bit integer, high word first (wfdb_g32)
%     f.p16(X), f.p32(X)  write them (wfdb_p16, wfdb_p32)
%     S = f.seek(OFF, WHENCE)  fseek (WHENCE 0 = SEEK_SET, 1 = SEEK_CUR,
%                         2 = SEEK_END); returns 0, or -1 on error
%     P = f.tell()        ftell (-1 if not seekable)
%     S = f.flush()       fflush: 0, or -1 if the file could not be written
%     OK = f.sync()       flush an output file; false if that failed
%     TF = f.feof(), TF = f.ferror(), f.clearerr()
%     S = f.close()       fclose (for the standard streams, only flushes)
%
%   Properties: fp (the MATLAB file identifier, -1 for the standard
%   streams), type (0 = WFDB_LOCAL, 1 = WFDB_NET), name (file name, or '-'),
%   is_std (true for the standard input and output) and out (true for an
%   output file, and for the standard output).
%
%   wfdb-x: closing an output file that could not be written, flushed or
%   closed counts as a write error (see wfdbx.wfdbx_write_errors).  As
%   Octave's fflush does not report a failure, an output file is flushed
%   by fseek(fp, 0, 'cof') where it is seekable.
%
%   The standard input ('-' opened for reading) is read from the bytes of
%   wfdbx.internal.stdin_bytes(); it is not seekable (as a pipe).  The
%   standard output ('-' opened for writing) writes with
%   wfdbx.internal.cout.
%
%   Method calls are relatively slow (tens of microseconds in Octave):
%   decode data read in bulk with read()/readall() rather than byte by
%   byte with getc() wherever possible.
%
%   Part of the translation of lib/wfdbio.c (WFDB 10.7.0).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/wfdbio.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: a field names the temporary file that holds the
% contents of a remote file; write errors are counted. Each change is marked
% "wfdb-x:" in the code; docs/DIVERGENCES.md gives the reasons.
%
% Original C code: lib/wfdbio.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1988-2013 George B. Moody; revised 2010-2022 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

    properties
        fp = -1         % file identifier (-1 for the standard streams)
        type = 0        % WFDB_LOCAL (0) or WFDB_NET (1)
        name = ''       % file name ('-' for the standard streams)
        is_std = false  % standard input or output
        out = false     % wfdb-x: an output file (see close)
        temp = ''       % wfdb-x: a temporary file deleted by close() (the
                        % contents of a remote file; see fetch_open)
    end

    properties (Access = private)
        err = false
        eof = false
        std = 0         % 0 = file, 1 = standard input, 2 = standard output
        data = []       % standard input: its bytes
        pos = 0         % standard input: number of bytes consumed
        beyond = -1     % position set by seek() beyond the end of the file
        check = false   % output file flushed by fseek (see sync)
    end

    methods
        function obj = WFDBFile(fid, ftype, name, std, out)
            %WFDBFILE Wrap a file identifier (STD = 1 or 2: stdin, stdout;
            %OUT true for a file opened for writing or appending).
            if nargin < 4
                std = 0;
            end
            if nargin < 5
                out = std == 2;
            end
            obj.fp = fid;
            obj.type = ftype;
            obj.name = name;
            obj.std = std;
            obj.is_std = std ~= 0;
            obj.out = out;
            if std == 1
                obj.data = wfdbx.internal.stdin_bytes();
            elseif out && std == 0 && fid >= 0
                obj.check = fseek(fid, 0, 'cof') == 0;
            end
        end

        function b = read(obj, n)
            %READ Read up to N bytes (uint8 row vector).
            if obj.std == 1
                k = min(n, numel(obj.data) - obj.pos);
                b = obj.data(obj.pos+1:obj.pos+k);
                obj.pos = obj.pos + k;
            elseif obj.std == 2 || obj.fp < 0
                obj.err = true;
                b = zeros(1, 0, 'uint8');
                return;
            elseif obj.beyond >= 0
                b = zeros(1, 0, 'uint8');
                k = 0;
            else
                [b, k] = fread(obj.fp, n, 'uint8=>uint8');
                b = b';
            end
            if k < n
                obj.eof = true;
            end
        end

        function b = readall(obj)
            %READALL Read everything up to the end of the file.
            if obj.std == 1
                b = obj.data(obj.pos+1:end);
                obj.pos = numel(obj.data);
            elseif obj.std == 2 || obj.fp < 0
                obj.err = true;
                b = zeros(1, 0, 'uint8');
                return;
            elseif obj.beyond >= 0
                b = zeros(1, 0, 'uint8');
            else
                b = fread(obj.fp, Inf, 'uint8=>uint8')';
            end
            obj.eof = true;
        end

        function c = getc(obj)
            %GETC Next byte (0-255) as a double, or -1 at end of file.
            if obj.std == 1
                if obj.pos < numel(obj.data)
                    obj.pos = obj.pos + 1;
                    c = double(obj.data(obj.pos));
                else
                    obj.eof = true;
                    c = -1;
                end
                return;
            end
            b = obj.read(1);
            if isempty(b)
                c = -1;
            else
                c = double(b);
            end
        end

        function n = write(obj, b)
            %WRITE Write a uint8 or char vector; returns its length.
            n = numel(b);
            if obj.std == 2
                wfdbx.internal.cout(b);
            elseif obj.std == 1 || obj.fp < 0
                obj.err = true;
                n = 0;
            elseif n > 0
                if obj.beyond >= 0
                    % C extends the file with zeros up to the position
                    fseek(obj.fp, 0, 'eof');
                    fwrite(obj.fp, zeros(1, obj.beyond - ftell(obj.fp)), 'uint8');
                    obj.beyond = -1;
                end
                k = fwrite(obj.fp, b, 'uint8');
                if k < n
                    obj.err = true;
                    n = max(k, 0);
                end
            end
        end

        function putc(obj, c)
            %PUTC Write one byte (C is taken modulo 256).
            obj.write(uint8(mod(double(c), 256)));
        end

        function n = printf(obj, fmt, varargin)
            %PRINTF Formatted output (C fprintf semantics).
            s = wfdbx.internal.csprintf(fmt, varargin{:});
            obj.write(s);
            n = numel(s);
        end

        function st = seek(obj, offset, whence)
            %SEEK fseek(): WHENCE is 0 (SEEK_SET), 1 (SEEK_CUR) or 2 (SEEK_END).
            if nargin < 3
                whence = 0;
            end
            if obj.std ~= 0 || obj.fp < 0
                st = -1;
                return;
            end
            if obj.check && ~obj.sync()
                obj.err = true;
            end
            % As C, positions beyond the end of the file are allowed
            % (MATLAB and Octave refuse them): reads there find the end
            % of the file, and writes extend the file with zeros.
            if whence == 1 && obj.beyond >= 0
                offset = obj.beyond + offset;
                whence = 0;
            end
            origins = {'bof', 'cof', 'eof'};
            here = ftell(obj.fp);
            st = fseek(obj.fp, offset, origins{whence + 1});
            if st == 0
                obj.beyond = -1;
                obj.eof = false;
                return;
            end
            if whence == 0
                target = offset;
            elseif whence == 1
                target = here + offset;
            else
                fseek(obj.fp, 0, 'eof');
                target = ftell(obj.fp) + offset;
            end
            fseek(obj.fp, 0, 'eof');
            if target >= ftell(obj.fp)
                obj.beyond = target;
                obj.eof = false;
                st = 0;
            else
                fseek(obj.fp, here, 'bof');
                st = -1;
            end
        end

        function p = tell(obj)
            %TELL ftell(), or -1 if the file is not seekable.
            if obj.std ~= 0 || obj.fp < 0
                p = -1;
            elseif obj.beyond >= 0
                p = obj.beyond;
            else
                p = ftell(obj.fp);
            end
        end

        function st = flush(obj)
            %FLUSH fflush().
            st = 0;
            if obj.std == 2
                wfdbx.internal.cout();
            elseif obj.std == 0 && obj.fp >= 0 && ~obj.sync()
                obj.err = true;
                st = -1;
            end
        end

        function tf = feof(obj)
            %FEOF True after a read reached the end of the file.
            tf = obj.eof;
        end

        function tf = ferror(obj)
            %FERROR True after a read or write error.
            tf = obj.err;
        end

        function clearerr(obj)
            %CLEARERR Reset the end-of-file and error indicators.
            obj.err = false;
            obj.eof = false;
        end

        function st = close(obj)
            %CLOSE fclose() (the standard streams are only flushed).
            % wfdb-x: an output file that could not be written, flushed
            % or closed counts as a write error (see
            % wfdbx.wfdbx_write_errors)
            st = 0;
            if obj.std == 2
                wfdbx.internal.cout();
                io = wfdbx.internal.io_state();
                if io.stdout_failed
                    io.write_errors = io.write_errors + 1;
                end
            elseif obj.std == 0 && obj.fp >= 0
                if obj.out && ~obj.sync()
                    st = -1;
                end
                if fclose(obj.fp) ~= 0
                    st = -1;
                end
                obj.fp = -1;
                if ~isempty(obj.temp)
                    delete(obj.temp);
                    obj.temp = '';
                end
                if obj.out && (obj.err || st ~= 0)
                    io = wfdbx.internal.io_state();
                    io.write_errors = io.write_errors + 1;
                end
            end
        end

        function s = getline(obj)
            %GETLINE Read one line, including its newline (char); '' at EOF.
            if obj.std == 1
                d = obj.data;
                i = obj.pos + 1;
                k = find(d(i:end) == 10, 1);
                if isempty(k)
                    s = char(d(i:end));
                    obj.pos = numel(d);
                    obj.eof = true;
                else
                    s = char(d(i:i+k-1));
                    obj.pos = i + k - 1;
                end
                return;
            end
            if obj.std == 2 || obj.fp < 0
                obj.err = true;
                s = '';
                return;
            end
            s = '';
            chunk = 128;
            while true
                p0 = ftell(obj.fp);
                [b, k] = fread(obj.fp, chunk, 'uint8=>uint8');
                j = find(b == 10, 1);
                if ~isempty(j)
                    s = [s char(b(1:j)')]; %#ok<AGROW>
                    if j < k
                        fseek(obj.fp, p0 + j, 'bof');
                    end
                    return;
                end
                s = [s char(b')]; %#ok<AGROW>
                if k < chunk
                    obj.eof = true;
                    return;
                end
                chunk = min(2 * chunk, 65536);
            end
        end

        function ok = sync(obj)
            %SYNC Flush an output file; false if that failed.
            ok = true;
            if obj.check
                % (fseek flushes the file and reports a failure, Octave's
                % fflush does not)
                ok = fseek(obj.fp, 0, 'cof') == 0;
            elseif wfdbx.internal.is_octave()
                fflush(obj.fp);
            end
        end

        function x = g16(obj)
            %G16 Read a 16-bit integer in PDP-11 (little-endian) format.
            b = double(obj.read(2));
            if numel(b) < 2
                b(end+1:2) = 255;
            end
            x = b(2) * 256 + b(1);
            if x >= 32768
                x = x - 65536;
            end
        end

        function x = g32(obj)
            %G32 Read a 32-bit integer in PDP-11 format (high word first).
            % As in the Python port, the result is x * 65536 + (y & 0xFFFF)
            % with x and y the signed 16-bit words read.
            x = obj.g16();
            y = obj.g16();
            x = x * 65536 + mod(y, 65536);
        end

        function p16(obj, x)
            %P16 Write a 16-bit integer in PDP-11 (little-endian) format.
            x = mod(x, 65536);
            obj.write(uint8([mod(x, 256), floor(x / 256)]));
        end

        function p32(obj, x)
            %P32 Write a 32-bit integer in PDP-11 format (high word first).
            x = mod(x, 4294967296);
            obj.p16(floor(x / 65536));
            obj.p16(mod(x, 65536));
        end
    end
end
