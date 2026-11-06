function M = read_metadata(record, varargin)
%READ_METADATA Read the metadata of a record: the "Key: value" entries.
%   M = wfdbx.read_metadata(RECORD) returns the "Key: value" entries of
%   the header of the record RECORD as an N-by-2 cell array of char row
%   vectors, one entry per row (key, value), in file order (cell(0, 2) if
%   there is none).  RECORD is the record name,
%   without the .hea extension (a trailing '.hea' is also accepted): a full
%   path, absolute ('/data/mitdb/100') or in the home directory
%   ('~/Documents/100s'), used as given; a relative path ('100s',
%   'data/100s'), read from the input directory if one is set (see
%   wfdbx.wfdbx_set_input_dir), otherwise from the current folder; or a URL
%   ('https://physionet.org/files/mitdb/1.0.0/100'), read only if network
%   access is on (see wfdbx.wfdbx_set_network).
%
%   M = wfdbx.read_metadata(RECORD, NAME, VALUE, ...) takes the options
%
%     'input_dir'   input directory for this call only (optional): a
%                   local directory, a ~ path or a URL, under which
%                   relative record names are read.  It does not apply to
%                   full paths or URLs.  Default: the current setting (see
%                   wfdbx.wfdbx_set_input_dir).
%     'network'     true to allow reading URLs for this call only, false
%                   to forbid it (default: the current setting)
%
%   Many datasets store facts about a recording in the header, as comment
%   lines such as "# Age: 63" or "# Dx: 164889003".  The rules:
%
%   * An entry is an info string (a line beginning with '#' after the
%     record line, as the C function getinfo() reads it) that contains a
%     colon.  The key is the text between the '#' and the first colon, the
%     value the rest of the line; spaces, tabs, VT, FF and CR at either end
%     of each are removed, so '#Age:45', '# Age: 45' and '#  Age : 45' all
%     give {'Age', '45'}.  An info string without a colon, or whose key is
%     empty or contains '#', is a free comment: it is not returned, and it
%     is never changed.  Comment lines before the record line are not info
%     strings.  Only the header file (.hea) is read, not the .info file
%     that wfdbx.getinfo also reads.
%   * Keys are compared without regard to letter case (A-Z and a-z only).
%     If a header has more than one entry for a key (a file written by
%     other software), the first is returned, and the warning
%     'wfdbx:duplicate_key' is issued for that key: "header of record
%     RECORD has more than one entry for key KEY (lines L1, L2); the first
%     is used".
%   * Text is handled as bytes: each character of a key or value is one
%     byte of the header (codes 0-255), as elsewhere in WFDB-x.
%   * The header is found as wfdbx.read_header finds it.  For a
%     multi-segment record, the master header is read, unless the name of
%     a segment is given.
%
%   Metadata often holds information about patients.  WFDB-x stores it as
%   plain text, exactly as given, and does not de-identify it.
%
%   Errors: an error is thrown if RECORD is empty or '-' (the standard
%   input), or an option is not valid (identifier 'wfdbx:read_metadata'),
%   or if the header cannot be found or read (identifier
%   'wfdbx:read_metadata:file': "can't read header for record RECORD").
%
%   Example:
%       M = wfdbx.read_metadata('rec');     % {'Age', '63'; 'Sex', 'F'}
%       for k = 1:size(M, 1)
%           fprintf('%s = %s\n', M{k, 1}, M{k, 2});
%       end
%
%   See also wfdbx.get_metadata, wfdbx.set_metadata,
%   wfdbx.remove_metadata, wfdbx.update_metadata, wfdbx.read_header.
%
%   Part of WFDB-x; not in the original WFDB package.

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

id = wfdbx.internal.meta_id('read_metadata');
record = wfdbx.internal.strarg(record);
opt = wfdbx.internal.hl_options(struct('input_dir', [], 'network', []), ...
    varargin, id.fname);
data = wfdbx.internal.meta_read(record, opt.input_dir, opt.network, id);
M = wfdbx.internal.meta_entries(data, record);
end
