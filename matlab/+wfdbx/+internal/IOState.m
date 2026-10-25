classdef IOState < handle
%IOSTATE Global state of the WFDB I/O layer (port of the statics of wfdbio.c).
%   The single instance is returned by wfdbx.internal.io_state().  Fields:
%
%     wfdbpath       the WFDB path ([] until getwfdb/setwfdb is called)
%     wfdbpath_init  the path found by the first getwfdb() (for resetwfdb)
%     path_prefix    cell row of the components of the parsed path
%     path_type      their types (0 = WFDB_LOCAL, 1 = WFDB_NET)
%     error_print    false after wfdbquiet()
%     error_flag     true once wfdb_error() has been called
%     error_message  the last error message
%     wfdb_filename  the name of the last file opened (or tried) by wfdb_open
%     irec           the current record name (for %r in the WFDB path)
%     mem_behavior   the argument of the last wfdbmemerr() call
%     stdin_file     the WFDBFile of the standard input, once opened
%     stdout_file    the WFDBFile of the standard output, once opened
%     output_dir     the directory in which output files are created ([]:
%                    none; wfdb-x, see wfdbx.wfdbx_set_output_dir)

% Copyright (C) 1988-2013 George B. Moody (original C implementation,
% lib/wfdbio.c; revised 2010-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

    properties
        wfdbpath = []
        wfdbpath_init = []
        path_prefix = cell(1, 0)
        path_type = zeros(1, 0)
        error_print = true
        error_flag = false
        error_message = []
        wfdb_filename = []
        irec = ''
        mem_behavior = 1
        stdin_file = []
        stdout_file = []
        output_dir = []
    end
end
