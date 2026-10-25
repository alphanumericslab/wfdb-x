function c = hl_outdir(d, record, fname)
%HL_OUTDIR Set the library's output directory for one high-level call.
%   C = wfdbx.internal.hl_outdir(D, RECORD, FNAME), where D is the 'dir'
%   option of the high-level writer FNAME and RECORD the record name: if D
%   is [] or '', nothing is done (C = []).  Otherwise D must be the name of
%   an existing directory, and RECORD must not contain a directory (an
%   error is thrown otherwise, before anything is written); the library's
%   output directory (wfdbx.wfdbx_set_output_dir) is then set to D, and
%   the onCleanup object C restores the previous one when it is cleared,
%   i.e. when the calling function returns or throws an error.  (wfdb-x;
%   see wfdbx.write_record.)

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

c = [];
if isempty(d)
    return;
end
if ~ischar(d)
    error(['wfdbx:' fname], '%s: dir must be a directory name', fname);
end
if any(record == '/' | record == filesep())
    error(['wfdbx:' fname], ...
        'record name must not contain a directory when dir is given');
end
if ~isfolder(d)
    error(['wfdbx:' fname], 'directory %s does not exist', d);
end
previous = wfdbx.wfdbx_set_output_dir(d);
c = onCleanup(@() wfdbx.wfdbx_set_output_dir(previous));
end
