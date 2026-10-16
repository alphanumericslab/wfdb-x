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
%     f.flush()           fflush
%     TF = f.feof(), TF = f.ferror(), f.clearerr()
%     S = f.close()       fclose (for the standard streams, only flushes)
%
%   Properties: fp (the MATLAB file identifier, -1 for the standard
%   streams), type (0 = WFDB_LOCAL, 1 = WFDB_NET), name (file name, or '-')
%   and is_std (true for the standard input and output).
%
%   The standard input ('-' opened for reading) is read from the bytes of
%   wfdbx.internal.stdin_bytes(); it is not seekable (as a pipe).  The
%   standard output ('-' opened for writing) writes with
%   wfdbx.internal.cout.
%
%   Method calls are relatively slow (tens of microseconds in Octave):
%   decode data read in bulk with read()/readall() rather than byte by
%   byte with getc() wherever possible.

% Copyright (C) 1988-2013 George B. Moody (original C implementation of the
% WFDB_FILE functions, lib/wfdbio.c; revised 2010-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

    properties
        fp = -1         % file identifier (-1 for the standard streams)
        type = 0        % WFDB_LOCAL (0) or WFDB_NET (1)
        name = ''       % file name ('-' for the standard streams)
        is_std = false  % standard input or output
    end

    properties (Access = private)
        err = false
        eof = false
        std = 0         % 0 = file, 1 = standard input, 2 = standard output
        data = []       % standard input: its bytes
        pos = 0         % standard input: number of bytes consumed
        beyond = -1     % position set by seek() beyond the end of the file
    end

    methods
        function obj = WFDBFile(fid, ftype, name, std)
            %WFDBFILE Wrap a file identifier (STD = 1 or 2: stdin, stdout).
            if nargin < 4
                std = 0;
            end
            obj.fp = fid;
            obj.type = ftype;
            obj.name = name;
            obj.std = std;
            obj.is_std = std ~= 0;
            if std == 1
                obj.data = wfdbx.internal.stdin_bytes();
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
                    n = k;
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
            elseif obj.std == 0 && obj.fp >= 0 && wfdbx.internal.is_octave()
                fflush(obj.fp);
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
            st = 0;
            if obj.std == 2
                wfdbx.internal.cout();
            elseif obj.std == 0 && obj.fp >= 0
                if fclose(obj.fp) ~= 0
                    st = -1;
                end
                obj.fp = -1;
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
