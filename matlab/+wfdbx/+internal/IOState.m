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
%   wfdb-x: write errors (see wfdbx.wfdbx_write_errors):
%     write_errors   the number of write errors since the program started
%     stdout_failed  true once the standard output could not be written
%                    (see wfdbx.internal.cout)
%
%   Part of the translation of lib/wfdbio.c (WFDB 10.7.0).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/wfdbio.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: fields hold the settings that locate files
% (input directory, output directory, network access), the remote files
% fetched, and the write errors. Each change is marked "wfdb-x:" in the
% code; docs/DIVERGENCES.md gives the reasons.
%
% Original C code: lib/wfdbio.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1988-2013 George B. Moody; revised 2010-2022 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

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
        write_errors = 0
        stdout_failed = false
    end
end
