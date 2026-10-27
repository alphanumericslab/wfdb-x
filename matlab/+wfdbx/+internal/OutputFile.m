classdef OutputFile < handle
%OUTPUTFILE A file that a tool writes itself, without the library.
%   F = wfdbx.internal.OutputFile(NAME, PNAME) creates the file NAME for
%   binary writing, as C's fopen(NAME, "wb"); F.fid is -1 if it cannot be
%   created.  PNAME is the program name, for the message of close().
%   F = wfdbx.internal.OutputFile(NAME, PNAME, MACHINEFMT) opens it with
%   the machine format MACHINEFMT (e.g. 'ieee-le').
%
%     F.write(DATA, ...)  fwrite(F.fid, DATA, ...); a failed write is
%                         remembered (the file's error flag, as C's ferror)
%     ST = F.close()      fclose: 0, or -1 if the file could not be flushed
%                         or closed
%
%   wfdb-x: in normal mode, close() prints "PNAME: write error on NAME" and
%   counts a write error (wfdbx.wfdbx_note_write_error) if a write, the
%   final flush or the close failed (as C's wfdbx_fclose_output).  Legacy
%   mode: silent.
%
%   See also wfdbx.wfdbx_write_errors, wfdbx.internal.WFDBFile.
%
%   Translation of the C function wfdbx_fclose_output() (WFDB-x's
%   lib/wfdbio.c).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

    properties
        fid = -1        % file identifier (-1 if the file was not created)
        name = ''       % file name, as given
        pname = ''      % program name
        err = false     % a write failed
    end

    properties (Access = private)
        check = false   % flushed by fseek (see wfdbx.internal.WFDBFile)
    end

    methods
        function obj = OutputFile(name, pname, machinefmt)
            %OUTPUTFILE Create the file NAME for writing.
            if nargin < 3
                obj.fid = fopen(name, 'wb');
            else
                obj.fid = fopen(name, 'wb', machinefmt);
            end
            obj.name = name;
            obj.pname = pname;
            if obj.fid >= 0
                obj.check = fseek(obj.fid, 0, 'cof') == 0;
            end
        end

        function write(obj, data, varargin)
            %WRITE fwrite(F.fid, DATA, ...); a failure sets the error flag.
            if ~obj.err && fwrite(obj.fid, data, varargin{:}) < numel(data)
                obj.err = true;
            end
        end

        function st = close(obj)
            %CLOSE fclose(); reports a write error (normal mode).
            st = 0;
            if obj.fid < 0
                return;
            end
            % (fseek flushes the file and reports a failure, Octave's
            % fflush does not)
            if obj.check && fseek(obj.fid, 0, 'cof') ~= 0
                st = -1;
            end
            if fclose(obj.fid) ~= 0
                st = -1;
            end
            obj.fid = -1;
            if (obj.err || st ~= 0) && ~wfdbx.wfdbx_get_legacy()
                wfdbx.internal.ceprintf('%s: write error on %s\n', ...
                    obj.pname, obj.name);
                wfdbx.wfdbx_note_write_error();
            end
        end
    end
end
