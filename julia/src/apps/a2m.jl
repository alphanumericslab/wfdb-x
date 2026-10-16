# a2m: convert an AHA format annotation file to MIT format (port of
# convert/a2m.c).
#
# This program converts four types of AHA format annotation files to MIT
# format:
#
#  Type 0: AHA-format annotation files produced by WFDB library-based
#          programs that use AHA_WRITE mode and putann (m2a is an example).
#          Time is measured in sample intervals from the beginning of the
#          record, and MIT annotation codes are included and read into the
#          chan field of the annotation by getann; if such codes are present
#          (chan non-zero), the AHA code is ignored.
#  Type 1: standard AHA annotation files from short-format AHA DB
#          distribution tapes. Time is measured in milliseconds from the
#          beginning of the test period (five minutes, or 75000 sample
#          intervals at 4 ms/sample interval, after the first sample).
#  Type 2: standard AHA annotation files from long-format AHA DB
#          distribution tapes. Time is measured as for type 1, except that
#          the test period begins 2.5 hours after the first sample.
#  Type 3: "compressed" (*.ANO) annotation files from AHA DB CD-ROMs or
#          floppy diskettes. Time is measured as for files of type 1 or 2,
#          depending on the record name (x2xx or x3xx: short format, x0xx or
#          x1xx: long format).
#
# wfdb-x: times in milliseconds (types 1-3) are converted at the sampling
# frequency of the record (or -F); the C program assumed 4 ms per sample, as
# legacy mode does.
#
# Where the C program has undefined behavior (an input file name ending in
# `/` without -r, or a directory as input file), this port uses an empty
# record name, and reports the directory as unreadable (see
# docs/KNOWN_C_BEHAVIORS.md).
#
# Copyright (C) 1983-2010 George B. Moody (original C program, convert/a2m.c).
# Julia implementation part of wfdb-x, Reza Sameni, Oct 2026.
# Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
# gain, ADC resolution or units. Values that the record or the user does not
# give are never assumed (the original package assumed 250 Hz, 200 adu/mV, 12
# bits and millivolts), because a silently assumed value corrupts every result
# derived from it. See docs/DIVERGENCES.md.
# GNU General Public License, version 2 or later (see LICENSE).

const _A2M_HELP = (
    "usage: %s -i AHAFILE [ OPTIONS ... ]\n",
    "where AHAFILE is the name of the AHA-format input annotation file,",
    "and OPTIONS may include:",
    " -a ANNOTATOR  specify the output annotator name (default: 'atr')",
    " -F FREQ       sampling frequency, if the record header does not specify",
    "                one (AHA database: 250)",
    " -h            print this usage summary",
    " -r RECORD     specify the name of the output RECORD (default: use the",
    "                input file name, less path info and extension, as RECORD)",
    " -s TIME       shift annotations by TIME",
    "                (defaults: 0 for TYPE 0,",
    "                      5:0 for TYPE 1, (or TYPE 3 if RECORD=x2xx or x3xx)",
    "                   2:30:0 for TYPE 2, (or TYPE 3 if RECORD=x0xx or x1xx)",
    " -t TYPE       specify type of file to be converted:",
    "                0 for files produced by WFDB applications in AHA format,",
    "                1 for short-format tape files,",
    "                2 for long-format tape files, or",
    "                3 for compressed files from AHA DB CD-ROMs or diskettes",
    "                (defaults: 3 if AHAFILE ends in .ANO or .ano, else 0)")

# wfdb-x: the help text of the original program, printed in legacy mode
const _A2M_LEGACY_HELP = _help_without(_A2M_HELP, 5:6)

const _A2M_CMP_SIZE = 6         # bytes per compressed (.ANO) annotation
const _A2M_SOFT_EOF = 0xff      # high time byte marking a soft end of file

# The record name implied by an input file name: its basename, less any
# extension (the first `.` after the first character).
function _aha_record_name(ifname::Vector{UInt8})
    r = prog_name(ifname)
    k = findnext(==(UInt8('.')), r, 2)
    k === nothing ? r : r[1:k-1]
end

# Read a compressed AHA annotation (6 bytes); -1 at end of file.
function _a2m_getcann(input::WfdbFile, buf::Vector{UInt8}, ap::Annotation)
    fread!(input, buf, 1, _A2M_CMP_SIZE) != _A2M_CMP_SIZE && return -1  # hard EOF
    # Compressed AHA format:
    #  buf[1]  AHA label (`N', `V', `F', `R', `E', `P', `Q', `[', `]', or `U')
    #  buf[2]  high byte of ahatime, or 0xff if at soft EOF
    #  buf[3]  middle byte of ahatime
    #  buf[4]  low byte of ahatime
    #  buf[5]  high byte of annotation serial number (ignored here)
    #  buf[6]  low byte of serial number
    buf[2] == _A2M_SOFT_EOF && return -1                      # soft EOF
    ap.anntyp = ammap(buf[1] % Int8) % Int8   # convert AHA label to annotation code
    ap.anntyp == 0 && return -1     # alternate soft EOF, used in a few AHA DB CD-ROM files
    # AHA `U' (unreadable data) label: decode as NOISE, subtype -1
    ap.subtyp = buf[1] == UInt8('U') ? Int8(-1) : Int8(0)
    # time in milliseconds from the start of the annotated segment
    ap.time = (Int64(buf[2]) << 16) | (Int64(buf[3]) << 8) | Int64(buf[4])
    0
end

# A time in milliseconds in sample intervals at the sampling frequency in
# use (C `(WFDB_Time)(t * sampfreq(NULL) / 1000.)`).
_a2m_ms2samp(t::Int64) = unsafe_trunc(Int64, t * sampfreq(nothing) / 1000.0)
# wfdb-x: legacy mode (original behavior): 4 msec/sample, whatever the
# record's frequency.
_a2m_ms2samp(t::Int64, legacy::Bool) = legacy ? t >> 2 : _a2m_ms2samp(t)

function a2m_main(args::Vector{String})
    # wfdb-x: --legacy as the first argument selects legacy mode (the
    # behavior of the original program; see wfdbx_legacy_args)
    legacy = wfdbx_legacy_args(args) != 0
    argv = cargs(args)              # C argv[i] (i >= 1) is argv[i]
    argc = length(argv) + 1
    pname = "a2m"
    ifname = nothing
    record = nothing
    oann = b"atr"
    ftype = Int32(-1)
    offset_arg = 0
    annot = Annotation()
    ffreq = Ref{Float64}(0.0)       # wfdb-x: -F

    # Read and interpret command-line arguments.
    i = 1
    while i < argc
        a = argv[i]
        if _annapp_c0(a) == UInt8('-')
            c = _annapp_c1(a)
            if c == UInt8('a')          # annotator name follows
                i += 1
                if i >= argc
                    ceprintf("%s: output annotator name must follow -a\n", pname)
                    cexit(1)
                end
                oann = argv[i]
            elseif c == UInt8('F') && !legacy   # sampling frequency follows (wfdb-x)
                i += 1
                if i >= argc || csscanf(argv[i], "%lf", ffreq) != 1 || ffreq[] <= 0.0
                    ceprintf("%s: sampling frequency (> 0) must follow -F\n", pname)
                    cexit(1)
                end
            elseif c == UInt8('h')      # help requested
                _annapp_help(pname, legacy ? _A2M_LEGACY_HELP : _A2M_HELP)
                cexit(1)
            elseif c == UInt8('i')      # input file name follows
                i += 1
                if i >= argc
                    ceprintf("%s: name of AHA-format input file must follow -i\n", pname)
                    cexit(1)
                end
                ifname = argv[i]
                if ftype < 0 && length(ifname) > 4
                    ext = @view ifname[end-3:end]
                    (ext == b".ANO" || ext == b".ano") && (ftype = Int32(3))
                end
            elseif c == UInt8('r')      # record name follows
                i += 1
                if i >= argc
                    ceprintf("%s: record name must follow -a\n", pname)
                    cexit(1)
                end
                record = argv[i]
            elseif c == UInt8('s')      # time shift follows
                i += 1
                if i >= argc
                    ceprintf("%s: time shift must follow -s\n", pname)
                    cexit(1)
                end
                # save position in arg list, convert to time later when
                # sampling frequency is known
                offset_arg = i
            elseif c == UInt8('t')      # file type follows
                i += 1
                i < argc && (ftype = atoi(argv[i]))
                if i >= argc || !(0 <= ftype <= 3)
                    ceprintf("%s: file type (0-3) must follow -t\n", pname)
                    cexit(1)
                end
            else
                ceprintf("%s: unrecognized option %s\n", pname, a)
                cexit(1)
            end
        else
            ceprintf("%s: unrecognized argument %s\n", pname, a)
            cexit(1)
        end
        i += 1
    end

    # Quit if input filename was not specified.
    if ifname === nothing
        _annapp_help(pname, legacy ? _A2M_LEGACY_HELP : _A2M_HELP)
        cexit(1)
    end

    # Attach the input file to the standard input. (C reads a directory
    # forever; wfdb-x reports it as unreadable.)
    if ifname != b"-" && (_is_directory(ifname) || !freopen_stdin(ifname))
        ceprintf("%s: can't read input file `%s'\n", pname, ifname)
        cexit(2)
    end

    # If no output record name was specified, use the basename of the input
    # file, less any extension.
    record === nothing && (record = _aha_record_name(ifname))

    ftype < 0 && (ftype = Int32(0))

    # Open the annotation files.
    afarray = [Anninfo(oann, WFDB_WRITE)]
    ftype != 3 && push!(afarray, Anninfo(b"-", WFDB_AHA_READ))
    annopen(record, afarray, length(afarray)) < 0 && cexit(2)

    # Set the time shift.
    # wfdb-x: if the record header does not give the sampling frequency, -F
    # must give it. (The C program assumed the rate of the AHA database,
    # 250 Hz, if a header without a frequency existed, and 1 sample per
    # second if there was no header, as legacy mode does.)
    if legacy
        sampfreq(record) == 0.0 && setsampfreq(WFDB_DEFFREQ)
    elseif sampfreq(record) <= 0.0
        if ffreq[] > 0.0
            setsampfreq(ffreq[])
        else
            ceprintf("%s: sampling frequency of record %s is not specified (use -F)\n", pname,
                     record)
            cexit(1)
        end
    end
    offset = Int64(0)
    if offset_arg != 0
        offset = strtim(argv[offset_arg])
    elseif ftype == 1
        offset = strtim("5:0")
    elseif ftype == 2
        offset = strtim("2:30:0")
    elseif ftype == 3
        if length(record) == 4 && (record[2] == UInt8('0') || record[2] == UInt8('1'))
            offset = strtim("2:30:0")   # long format
        elseif length(record) == 4 && (record[2] == UInt8('2') || record[2] == UInt8('3'))
            offset = strtim("5:0")      # short format
        end
        # otherwise, leave offset at zero (unrecognized format)
    end

    # Reformat the annotations.
    if ftype == 0
        while getann(0, annot) >= 0
            if annot.chan != 0          # MIT annotation code present
                annot.anntyp = annot.chan % Int8
                annot.chan = 0
            end
            annot.time += offset
            putann(0, annot) < 0 && break
        end
    # Times in milliseconds are converted at the sampling frequency of the
    # record (wfdb-x; the C program assumed 4 ms per sample, i.e., 250 Hz,
    # whatever the record's frequency).
    elseif ftype == 1 || ftype == 2
        while getann(0, annot) >= 0
            annot.time = _a2m_ms2samp(annot.time, legacy) + offset
            putann(0, annot)
        end
    else
        input = wfdb_stdin()
        buf = Vector{UInt8}(undef, _A2M_CMP_SIZE)
        while _a2m_getcann(input, buf, annot) >= 0
            annot.time = _a2m_ms2samp(annot.time, legacy) + offset
            putann(0, annot)
        end
    end

    wfdbquit()
    cexit(0)
end

register_workload("a2m") do
    with_workload_data() do dir
        workload_tool("a2m", "-i", "100s.aha", "-r", "100s", "-a", "cpy")
        workload_tool("a2m", "-i", "100s.aha", "-r", "100s", "-a", "cpy", "-t", "1")
        workload_tool("a2m", "-i", "100s.aha", "-r", "100s", "-a", "cpy", "-t", "2", "-s", "0:1")
        workload_tool("a2m", "-i", "1201.ANO")
        workload_tool("a2m", "-i", "1201.ANO", "-a", "x", "-s", "10", "-F", "250")
        workload_tool("a2m", "-i", "1201.ANO", "-r", "1001", "-a", "x", "-s", "10", "-F", "250")
        workload_tool("a2m", "-i", "1201.ANO", "-F", "0")
        workload_tool("a2m", "-i", "1201.ANO", "-F", "500")
        # wfdb-x: legacy mode (original behavior)
        workload_tool("a2m", "--legacy", "-i", "1201.ANO", "-r", "1001", "-a", "x", "-s", "10")
        workload_tool("a2m", "--legacy", "-i", "100s.aha", "-r", "100s", "-a", "cpy", "-t", "1")
        workload_tool("a2m", "--legacy", "-i", "1201.ANO", "-F", "500")
        workload_tool("a2m", "--legacy", "-h")
        workload_tool("a2m", "-i", "nosuch.ano")
        workload_tool("a2m", "-i", ".")
        workload_tool("a2m", "-i", "100s.aha", "-t", "4")
        workload_tool("a2m", "-h")
        workload_tool("a2m", "-q")
        workload_tool("a2m", "x")
    end
end
