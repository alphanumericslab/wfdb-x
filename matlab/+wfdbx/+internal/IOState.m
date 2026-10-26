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
%   wfdb-x: the settings that locate files (each is read from its
%   environment variable when first needed; see wfdbx.wfdbx_set_input_dir,
%   wfdbx.wfdbx_set_output_dir, wfdbx.wfdbx_set_network):
%     input_dir      the input directory ([]: none)
%     env_input_dir  the value of WFDBX_INPUT_DIR ([] if unset or empty)
%     input_dir_init true once WFDBX_INPUT_DIR has been read
%     wfdb_warned    true once the "WFDB is ignored" message was considered
%     setwfdb_called, setwfdb_input_dir   whether setwfdb was called in
%                    normal mode, and the input directory it set (resetwfdb)
%     output_dir     the directory in which output files are created ([]:
%                    none)
%     env_output_dir, output_dir_init     the same for WFDBX_OUTPUT_DIR
%     network        1 if URLs may be opened, 0 if not ([]: not read yet)
%     env_network    the default from WFDBX_NETWORK (0 or 1)
%     network_warned true once the "network access is disabled" message
%                    was printed
%     fetched_urls, fetched_data   the URLs fetched (cell row) and their
%                    contents (uint8 rows; [] for a failure)

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
        input_dir = []
        env_input_dir = []
        input_dir_init = false
        wfdb_warned = false
        setwfdb_called = false
        setwfdb_input_dir = []
        output_dir = []
        env_output_dir = []
        output_dir_init = false
        network = []
        env_network = 0
        network_warned = false
        fetched_urls = cell(1, 0)
        fetched_data = cell(1, 0)
    end
end
