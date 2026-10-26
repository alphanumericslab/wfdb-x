function init_input_dir(st)
%INIT_INPUT_DIR Read the input directory from the environment, once.
%   wfdbx.internal.init_input_dir(ST) (wfdb-x), for the I/O state ST: on
%   the first call, the input directory is taken from the environment
%   variable WFDBX_INPUT_DIR (if set and not empty).  In normal mode, the
%   first call also reports, once per process, that the environment
%   variable WFDB (if set and not empty) is ignored.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

if ~st.input_dir_init
    st.input_dir_init = true;
    v = wfdbx.internal.cgetenv('WFDBX_INPUT_DIR');
    if ischar(v)
        st.env_input_dir = v;
        st.input_dir = v;
    end
end
if ~st.wfdb_warned && ~wfdbx.wfdbx_get_legacy()
    st.wfdb_warned = true;
    if ischar(wfdbx.internal.cgetenv('WFDB'))
        wfdbx.internal.wfdb_error(['wfdb-x: the WFDB environment variable ' ...
            'is ignored; set WFDBX_INPUT_DIR instead (or use legacy mode)\n']);
    end
end
end
