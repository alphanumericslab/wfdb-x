function oannclose(an)
%OANNCLOSE Close an output annotator.
%   wfdbx.oannclose(AN) writes the end of file marker of output annotator
%   AN and closes it; the annotators opened after it are renumbered.  If
%   annotations were written out of order, the file is rearranged in
%   canonical order (unless the environment variable WFDBANNSORT is 0;
%   the 'sort' option of wfdbx.write_annotations decides instead for the
%   file that function writes),
%   with a result identical to that of the sortann tool: wfdb-x does this
%   in the same process (wfdbx.internal.ann_sortfile), while the C library
%   (as legacy mode, wfdbx.wfdbx_set_legacy) runs sortann in a separate
%   process (in legacy mode, the sortann tool with --legacy, in the output
%   directory if one is set: wfdbx.wfdbx_set_output_dir).
%
%   See also wfdbx.annopen, wfdbx.putann, wfdbx.iannclose.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% Design decision (Reza Sameni, after a code review, Oct 2026): an
% out-of-order output annotation file is rearranged in this process, with
% a result identical to that of the sortann program, which the C library
% ran through the shell (and found only if it was in the PATH).  The
% original behavior remains available with --legacy (see
% docs/DIVERGENCES.md).
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

st = wfdbx.internal.ann_state();
if ~(an >= 0 && an < numel(st.oad) && ~isempty(st.oad{an+1}))
    return;
end
oa = st.oad{an+1};
f = oa.file;
oa = wfdbx.internal.ann_oflush(oa);
if oa.stat == 1                         % WFDB_WRITE
    f.p16(0);                           % end of file marker
elseif oa.stat == 3                     % WFDB_AHA_WRITE
    % pad with EOAF (0377) bytes to a multiple of ABLKSIZ (1024) bytes
    ABLKSIZ = 1024;
    EOAF = 255;
    p = f.tell();
    i = ABLKSIZ - mod(mod(p, 4294967296), ABLKSIZ);
    f.write(uint8(EOAF * ones(1, i)));
end
errflag = f.ferror();
if f.close()
    errflag = true;
end
if errflag
    wfdbx.internal.wfdb_error( ...
        'oannclose: write error on annotation file %s\n', oa.name);
    st.annclose_error = -7;
end
if oa.out_of_order
    dosort = 1;                         % DEFWFDBANNSORT
    p = wfdbx.internal.cgetenv('WFDBANNSORT');
    if ~isempty(st.sort_override)
        % wfdb-x: write_annotations' 'sort' option decides (this call only)
        dosort = st.sort_override;
    elseif ischar(p)
        dosort = wfdbx.internal.strtol(p);
    end
    if dosort
        wfdbx.internal.wfdb_error( ...
            'Rearranging annotations for output annotator %s ...', oa.name);
        % wfdb-x: the file is sorted in this process; the C library ran
        % the sortann program, as legacy mode does.
        if wfdbx.wfdbx_get_legacy()
            wfdbx.internal.cout();
            % wfdb-x: the child runs with --legacy (as the original), and
            % in the output directory if one is set (where the file is)
            q = @wfdbx.internal.shell_quote;
            cmd = [wfdbx.internal.tool_command('sortann') ' --legacy -r. ' ...
                q(oa.rname) ' -a ' q(oa.name)];
            if ~isempty(getenv('WFDBX_STDOUT')) || ~isempty(getenv('WFDBX_STDERR'))
                % (the child writes its own standard output and error, not
                % the files of the MATLAB driver: see std_stream)
                cmd = ['WFDBX_STDOUT= WFDBX_STDERR= ' cmd];
            end
            odir = wfdbx.wfdbx_get_output_dir();
            if ischar(odir)
                cmd = ['cd ' q(odir) ' && ' cmd];
            end
            % The output of the command (messages only) is captured and
            % copied to the standard error output: system() would print
            % it on the standard output in MATLAB, and pass it through in
            % Octave.
            [s, msg] = system([cmd ' </dev/null 2>&1']);
            wfdbx.internal.cerr(msg);
        else
            s = wfdbx.internal.ann_sortfile(oa.fname, oa.name);
        end
        if s == 0
            wfdbx.internal.wfdb_error('done!\n');
            oa.out_of_order = 0;
        else
            wfdbx.internal.wfdb_error( ...
                '\nAnnotations still need to be rearranged.\n');
        end
        if st.annclose_error == 0
            st.annclose_error = -6;
        end
    end
end
if oa.out_of_order
    wfdbx.internal.wfdb_error( ...
        'Use the command:\n  sortann -r %s -a %s\n', oa.rname, oa.name);
    wfdbx.internal.wfdb_error( ...
        'to rearrange annotations in the correct order.\n');
    if st.annclose_error == 0
        st.annclose_error = -6;
    end
end
st.oad(an+1) = [];
end
