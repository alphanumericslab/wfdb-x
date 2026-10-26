function init_output_dir(st)
%INIT_OUTPUT_DIR Read the output directory from the environment, once.
%   wfdbx.internal.init_output_dir(ST) (wfdb-x), for the I/O state ST: on
%   the first call, the output directory is taken from the environment
%   variable WFDBX_OUTPUT_DIR (if set and not empty; a URL is refused with
%   an error message and ignored).

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

if ~st.output_dir_init
    st.output_dir_init = true;
    v = wfdbx.internal.cgetenv('WFDBX_OUTPUT_DIR');
    if ischar(v)
        if wfdbx.internal.is_url(v)
            wfdbx.internal.wfdb_error(['wfdbx_set_output_dir: the output ' ...
                'directory must be a local directory\n']);
        else
            st.env_output_dir = v;
            st.output_dir = v;
        end
    end
end
end
