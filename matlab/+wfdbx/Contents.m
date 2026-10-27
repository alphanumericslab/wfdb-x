% wfdb-x: read and write WFDB records in MATLAB and GNU Octave
% Version 10.7.0 (WFDB Software Package 10.7.0)
%
% Call the functions with the package name, such as wfdbx.read_record.
% Text arguments are char vectors or MATLAB strings.  Samples, times and
% counts are doubles.  Signal numbers start at 0.  Use "help wfdbx.NAME"
% for the description of a function.
%
% High-level functions
%   read_record       - Read the signals of a record into a matrix.
%   read_header       - Read the header of a record.
%   read_annotations  - Read an annotation file into arrays.
%   write_record      - Write a matrix of samples as a WFDB record.
%   write_annotations - Write an annotation file from arrays.
%   check_record      - Check a record and its annotation files.
%
% Settings
%   wfdbx_set_input_dir, wfdbx_get_input_dir
%                     - Directory from which input files are read.
%   wfdbx_set_output_dir, wfdbx_get_output_dir
%                     - Directory in which output files are created.
%   wfdbx_set_network, wfdbx_get_network
%                     - Allow or forbid network access.
%   wfdbx_set_legacy, wfdbx_get_legacy
%                     - Turn legacy mode on or off.
%   wfdbx_write_errors, wfdbx_note_write_error
%                     - Count of the output files that could not be written.
%
% Files
%   getwfdb           - The input directory (legacy mode: the WFDB path).
%   setwfdb           - Set the input directory (legacy: the WFDB path).
%   resetwfdb         - Restore the input directory set by setwfdb.
%   wfdbfile          - The pathname of a WFDB file.
%   wfdbquit          - Close all WFDB files and reset the library.
%   wfdbflush         - Write all buffered output annotations and samples.
%   wfdbinit          - Open the annotation files and input signals.
%   wfdbquiet         - Suppress WFDB library error messages.
%   wfdbverbose       - Enable WFDB library error messages (the default).
%   wfdberror         - The most recent WFDB library error message.
%   wfdbversion       - The version of the WFDB library reproduced.
%   wfdbdefwfdb       - The default WFDB path.
%   wfdbdefwfdbcal    - The default name of the calibration file.
%   wfdbcflags, wfdbldflags - C compiler and linker flags (empty).
%   wfdbmemerr, wfdb_me_fatal - Behavior on memory errors (compatibility).
%
% Signals
%   isigopen          - Open the input signals of a record.
%   getvec            - Read a sample from each input signal.
%   getframe          - Read a frame of samples from the open input signals.
%   getframes         - Read many sample vectors at once (fast).
%   isigsettime       - Skip to a given time in the input signals.
%   isgsettime        - Skip to a given time in an input signal group.
%   tnextvec          - Time of the next valid sample of a signal.
%   sample            - Random access to a sample of an input signal.
%   sample_valid      - Status of the last call of sample.
%   findsig           - Find an input signal by name or number.
%   setgvmode         - Set the getvec operating mode (getgvmode).
%   getspf            - Samples per signal returned by getvec per frame.
%   setifreq          - Set the frequency at which getvec returns samples.
%   getifreq          - Frequency at which getvec returns samples.
%   setibsize         - Set the size of the input buffers.
%   wfdbgetskew       - Skew of an input signal (wfdbsetiskew).
%   wfdbgetstart      - Byte offset of the first sample of an input signal.
%   osigopen          - Open output signals as specified by a header.
%   osigfopen         - Open output signals as specified by descriptions.
%   putvec            - Write a sample to each output signal.
%   putframes         - Write many frames of samples at once (fast).
%   setobsize         - Set the size of the output buffers.
%   wfdbsetskew       - Set the skew of an output signal.
%   wfdbsetstart      - Set the prolog length of an output signal.
%   wfdbputprolog     - Write a prolog to the file of an output signal.
%   newheader         - Create a header file for the open output signals.
%   setheader         - Create or rewrite a header file.
%   setmsheader       - Create the header of a multi-segment record.
%   getseginfo        - Segments of the open multi-segment record.
%   getinfo           - Read the info strings of a record.
%   putinfo, setinfo  - Write info strings (setinfo: to a .info file).
%   wfdb_freeinfo     - Discard the info strings read by getinfo.
%   siginfo           - A WFDB_Siginfo structure (signal information).
%   seginfo           - A WFDB_Seginfo structure (segment information).
%   adumuv, muvadu    - Convert between ADC units and microvolts.
%   aduphys, physadu  - Convert between ADC units and physical units.
%   wfdbx_legacy_args - Recognize --legacy as the first argument of a tool.
%
% Time and date
%   sampfreq          - Sampling frequency of a record (setsampfreq).
%   strtim            - Convert a time string to sample intervals.
%   wfdbx_time_needs_freq - True if strtim needs a sampling frequency.
%   timstr, mstimstr  - Convert sample intervals to a time string.
%   setbasetime       - Set the base time and date.
%   datstr, strdat    - Convert between Julian dates and date strings.
%   getcfreq          - Counter frequency (setcfreq).
%   getbasecount      - Base counter value (setbasecount).
%
% Annotations
%   annopen           - Open annotation files of a record.
%   getann            - Read the next annotation from an input annotator.
%   ungetann          - Push an annotation back into an input annotator.
%   putann            - Write an annotation to an output annotator.
%   iannsettime       - Skip input annotators to a given time.
%   iannclose         - Close an input annotator.
%   oannclose         - Close an output annotator.
%   setafreq          - Set the time resolution of output annotators.
%   getafreq          - Time resolution of output annotators.
%   setiafreq         - Set the time resolution of an input annotator.
%   getiafreq         - Time resolution of an input annotator.
%   getiaorigfreq     - Time resolution recorded in an input annotation file.
%   anninfo           - A WFDB_Anninfo structure (annotator name and mode).
%   annotation        - A WFDB_Annotation structure.
%   annstr, strann    - Convert between annotation codes and mnemonics.
%   setannstr         - Redefine the mnemonic of an annotation code.
%   anndesc           - Description of an annotation code (setanndesc).
%   ecgstr, strecg    - Fixed mnemonics of annotation codes (setecgstr).
%   ecgcodes          - All annotation codes as a structure (NORMAL, PVC...).
%   isann, isqrs      - Test annotation codes (setisqrs).
%   map1, map2        - Map codes into broad classes (setmap1, setmap2).
%   annpos            - Position code of an annotation code (setannpos).
%   ammap, mamap      - Map between AHA and MIT annotation codes.
%   wfdb_isann, ...   - The same functions under their C library names.
%
% Calibration
%   calopen           - Read a calibration file into the calibration list.
%   getcal            - Find calibration information for a signal type.
%   putcal            - Append an entry to the calibration list.
%   newcal            - Write the calibration list to a file.
%   flushcal          - Empty the calibration list.
%   calinfo           - A WFDB_Calinfo structure.
%
% Constants (functions without arguments)
%   NORMAL, PVC, ...  - Annotation codes of lib/ecgcodes.h (ACMAX: largest).
%   APUNDEF, APSTD, ... - Annotation position codes (see annpos).
%   WFDB_READ, WFDB_WRITE, WFDB_AHA_READ, WFDB_AHA_WRITE, WFDB_APPEND
%                     - File modes of lib/wfdb.h.
%   WFDB_INVALID_SAMPLE, WFDB_LOWRES, WFDB_HIGHRES, WFDB_GVPAD
%                     - Sample value and getvec modes of lib/wfdb.h.
%   WFDB_DEFFREQ, WFDB_DEFGAIN, WFDB_DEFRES, WFDB_MAXRNL, WFDB_MAXUSL,
%   WFDB_MAXDSL       - Defaults and limits of lib/wfdb.h.  WFDB_DEFFREQ,
%                       WFDB_DEFGAIN and WFDB_DEFRES are the values that
%                       the original package assumed (see
%                       wfdbx_set_legacy).
%
% Command-line tools
% STATUS = wfdbx.apps.TOOL({ARG1, ARG2, ...}) runs a tool with the given
% arguments and returns its exit status.  "help wfdbx.apps.TOOL" shows its
% usage.  From the shell, run the tools with matlab/bin/wfdbx_cli.m
% (Octave) or matlab/bin/wfdbx_matlab.sh (MATLAB).
%   rdsamp, wrsamp, rdann, wrann, sortann, ann2rr, rr2ann, sigamp, snip,
%   xform, wfdbdesc, wfdbcat, wfdbwhich, wfdbtime, time2sec, sampfreq,
%   signame, signum; converters a2m, ad2m, ahaecg2mit, edf2mit, m2a,
%   makeid, md2a, mit2edf, mit2wav, parsescp, rdedfann, readid, revise,
%   wav2mit, wfdb2mat.
%
% See matlab/README.md for installation and examples.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.
