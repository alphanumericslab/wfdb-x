function tf = is_input_file(fname)
%IS_INPUT_FILE True if an output signal file is one of the input files.
%   TF = wfdbx.internal.is_input_file(FNAME) (wfdb-x) is true if the output
%   signal file FNAME (as named in an output signal specification, created
%   by wfdb_open(FNAME, [], WFDB_WRITE)) exists and is a signal file of the
%   open input record: a signal file open for input, or a signal file of
%   any segment of the open multi-segment record (read from the segment's
%   header, located as isigopen locates it; segments are opened later, as
%   they are reached).  "The same file" is decided by the files, not by
%   their names: device and inode numbers (Octave's stat; on MS-Windows,
%   the canonical names, compared case-insensitively), or, in MATLAB,
%   java.nio.file.Files.isSameFile (which also recognizes links and hard
%   links).  A file at a URL, or the standard input or output, is never
%   one.  No message is printed.  openosig calls it in normal mode only.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% Design decision (Reza Sameni, Oct 2026): an output signal file is never
% one of the input files.  E.g., "xform -i vlay -o fmt16", fmt16 being a
% segment of vlay, truncated fmt16.dat while reading it, with a
% platform-dependent result and the input destroyed.  The original
% behavior remains available with --legacy (see docs/DIVERGENCES.md).
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

tf = false;
path = wfdbx.internal.output_file(fname);
if ~ischar(path) || ~isfile(path)
    return;         % (it does not exist: it is not an input file)
end
id = file_id(path);
if isempty(id)
    return;
end
S = wfdbx.internal.sig_state();
for g = 1:min(S.nigroup, numel(S.igd))
    if same_file(id, S.igd{g}.fp)
        tf = true;
        return;
    end
end
if S.in_msrec && ~isempty(S.segarray)
    seg = S.segarray;
    for k = 1:min(S.segend + 1, numel(seg))
        if segment_has_file(S, seg(k).recname, id)
            tf = true;
            return;
        end
    end
end
end

function id = file_id(x)
% The identity of the local file named x (a char vector) or of the open
% local WFDBFile x (not the standard input or output, not a URL), or [].
id = [];
if isa(x, 'wfdbx.internal.WFDBFile')
    if x.type ~= 0 || x.is_std || x.fp < 0      % (WFDB_LOCAL only)
        return;
    end
    if wfdbx.internal.is_octave() && ~ispc()
        [st, err] = stat(x.fp);         % (fstat of the open file)
        if err == 0
            id = [st.dev, st.ino];
        end
        return;
    end
    x = fopen(x.fp);                    % (the name of the open file)
end
if wfdbx.internal.is_octave()
    if ispc()
        p = canonicalize_file_name(x);
        if ~isempty(p)
            id = lower(p);
        end
    else
        [st, err] = stat(x);
        if err == 0
            id = [st.dev, st.ino];
        end
    end
else
    % MATLAB: no inode numbers; a Java path compared with isSameFile (made
    % absolute here: Java's current directory is not MATLAB's)
    if ~wfdbx.internal.is_absolute_path(x)
        x = fullfile(pwd(), x);
    end
    try
        id = java.io.File(x).toPath();
    catch
        id = [];
    end
end
end

function tf = same_file(id, f)
% True if the open WFDBFile (or file name) f is the file of identity id.
tf = false;
if isempty(f)
    return;
end
fid = file_id(f);
if isempty(fid)
    return;
end
if wfdbx.internal.is_octave()
    tf = isequal(id, fid);
else
    try
        tf = java.nio.file.Files.isSameFile(id, fid);
    catch
        tf = false;
    end
end
end

function found = segment_has_file(S, seg, id)
% True if one of the signal files named in the header of segment seg (of
% the open multi-segment record) is the file id.  The header and the
% signal files are located as isigopen locates them in normal mode; one
% that cannot be found (or is at a URL) is not id.  No message.
found = false;
if strcmp(seg, '~') || ~wfdbx.internal.in_header_dir(seg) || ...
        (ischar(S.msrec_dir) && wfdbx.internal.is_url(S.msrec_dir))
    return;
end
if ischar(S.msrec_name)
    hf = wfdbx.internal.open_in(S.msrec_dir, 'hea', seg, S.msrec_name);
else
    hf = wfdbx.internal.wfdb_open('hea', seg, 0);       % WFDB_READ
end
if isempty(hf)
    return;
end
d = [];
if hf.type == 0 && ~hf.is_std
    d = wfdbx.internal.wfdb_dirname(wfdbx.wfdbfile([], []));
end
nsig = -1;
while ~found && nsig ~= 0
    line = hf.getline();
    if isempty(line)
        break;
    end
    tok = regexp(line, '[ \t\n\r]+', 'split');
    tok = tok(~cellfun('isempty', tok));
    if isempty(tok) || tok{1}(1) == '#'
        continue;
    end
    if nsig < 0                         % the record line
        if any(tok{1} == '/') || numel(tok) < 2
            break;
        end
        nsig = wfdbx.internal.strtol(tok{2});
        if nsig <= 0
            break;
        end
        continue;
    end
    nsig = nsig - 1;                    % a signal line: file name, format
    name = tok{1};
    if numel(tok) < 2 || wfdbx.internal.strtol(tok{2}) == 0 || ...
            strcmp(name, '-') || ~wfdbx.internal.in_header_dir(name) || ...
            ~ischar(d) || wfdbx.internal.is_url(d)
        continue;
    end
    sf = wfdbx.internal.open_in(d, [], name, seg);
    if ~isempty(sf)
        found = same_file(id, sf);
        sf.close();
    end
end
hf.close();
end
