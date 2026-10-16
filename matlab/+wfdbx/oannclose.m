function oannclose(an)
%OANNCLOSE Close an output annotator.
%   wfdbx.oannclose(AN) writes the end of file marker of output annotator
%   AN and closes it; the annotators opened after it are renumbered.  If
%   annotations were written out of order, the file is sorted by running
%   the sortann tool in a separate process (unless the environment
%   variable WFDBANNSORT is 0), as the C library does.
%
%   See also wfdbx.annopen, wfdbx.putann, wfdbx.iannclose.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

st = wfdbx.internal.annstate();
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
    if ischar(p)
        dosort = wfdbx.internal.strtol(p);
    end
    if dosort
        wfdbx.internal.wfdb_error( ...
            'Rearranging annotations for output annotator %s ...', oa.name);
        wfdbx.internal.cout();
        q = @wfdbx.internal.shell_quote;
        cmd = [wfdbx.internal.tool_command('sortann') ' -r. ' q(oa.rname) ...
            ' -a ' q(oa.name)];
        % The output of the command (messages only) is captured and
        % copied to the standard error output: system() would print it on
        % the standard output in MATLAB, and pass it through in Octave.
        [s, msg] = system([cmd ' </dev/null 2>&1']);
        wfdbx.internal.cerr(msg);
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
