function set_metadata(record, key, value, varargin)
%SET_METADATA Set the value of a metadata entry in the header of a record.
%   wfdbx.set_metadata(RECORD, KEY, VALUE) sets the "Key: value" entry for
%   KEY in the header of the record RECORD (see wfdbx.read_metadata for
%   RECORD and the rules of reading).  If the header has an entry for KEY
%   (ignoring letter case), its line is replaced by "# KEY: VALUE", at the
%   same position and with the same line ending, with the spelling of KEY
%   given here (even if the value is the same).  Otherwise the entry is
%   added after the last info string of the header (or, if it has none,
%   after its last line that is not blank), with the line ending of the
%   record line.  Every other byte of the header is kept: the record and
%   signal lines, the free comments and the line endings.
%
%     KEY     the key, such as 'Age' or 'Date of birth' (a char row vector,
%             a MATLAB string, or a uint8 vector of bytes).  Spaces, tabs,
%             VT, FF and CR at either end are removed.  It must not be
%             empty, and must not contain ':', '#', a line break (CR or LF)
%             or a NUL character.
%     VALUE   the value: text, which may be a whole sentence (a char row
%             vector, a MATLAB string, or a uint8 vector).  Spaces, tabs,
%             VT, FF and CR at either end are removed.  It must not contain
%             a line break or a NUL character; it may be empty (written as
%             "# KEY:").
%
%   wfdbx.set_metadata(RECORD, KEY, VALUE, NAME, VALUE, ...) takes the
%   options
%
%     'input_dir', 'network'
%             input directory and network access for reading the header,
%             for this call only (see wfdbx.read_metadata)
%     'dir'   directory (which must exist) in which to write the changed
%             header, under the same file name, instead of changing the
%             header that was read (which is then unchanged).  The signal
%             files are not copied.  An unchanged header is also written
%             there.  Default: none ([] or '').
%
%   The header is changed where it was read (not in the output directory),
%   unless 'dir' is given.  A header read from a URL can only be written
%   elsewhere, with 'dir'.  The new header is written to a temporary file
%   in the directory of the destination, which then replaces it (rename),
%   keeping its permissions where the system allows; all the arguments are
%   checked first, so that an error leaves the header unchanged.
%
%   Metadata often holds information about patients.  WFDB-x stores it as
%   plain text, exactly as given, and does not de-identify it.
%
%   Errors: an argument error (identifier 'wfdbx:set_metadata') is thrown
%   if KEY or VALUE is not valid, if the header has more than one entry for
%   KEY ("... remove them first"), if it has no record line, if it was
%   read from a URL and 'dir' is not given, if RECORD is empty or '-', or
%   if an option is not valid; a file error (identifier
%   'wfdbx:set_metadata:file') if the header cannot be read or the
%   changed header cannot be written ("can't write header for record
%   RECORD"), or if 'dir' does not exist ("directory DIR does not exist").
%
%   Example:
%       wfdbx.set_metadata('rec', 'Age', '63');     % writes "# Age: 63"
%
%   See also wfdbx.read_metadata, wfdbx.update_metadata,
%   wfdbx.remove_metadata.
%
%   Part of WFDB-x; not in the original WFDB package.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU Lesser General Public License as published by
% the Free Software Foundation, either version 2.1 of the License, or (at
% your option) any later version. See LICENSE.

id = wfdbx.internal.meta_id('set_metadata');
if nargin < 3
    error(id.arg, 'set_metadata: RECORD, KEY and VALUE are required');
end
record = wfdbx.internal.strarg(record);
opt = wfdbx.internal.hl_options(struct('input_dir', [], 'network', [], ...
    'dir', []), varargin, id.fname);
k = wfdbx.internal.meta_key(key, id);
v = wfdbx.internal.meta_value(key, value, id);
wfdbx.internal.meta_change(record, {k}, {v}, opt, id);
end
