# wrsamp: select fields or columns from a file and generate a WFDB record
# (port of app/wrsamp.c).
#
# Where the C program's behavior is undefined (input lines that end with a
# field separator, lines with fewer fields than the selected columns), the
# behavior described in docs/KNOWN_C_BEHAVIORS.md is used.
#
# Copyright (C) 1993-2014 George B. Moody (original C program, app/wrsamp.c;
# revised 2020 by Benjamin Moody).
# Julia implementation part of wfdb-x, Reza Sameni, Oct 2026.
# Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
# gain, ADC resolution or units. Values that the record or the user does not
# give are never assumed (the original package assumed 250 Hz, 200 adu/mV,
# 12 bits and millivolts), because a silently assumed value corrupts every
# result derived from it. See docs/DIVERGENCES.md.
# GNU General Public License, version 2 or later (see LICENSE).

"Lines of help printed before pausing (`--More--`)."
const _WRSAMP_HELP_PAGE = 23
"Size of the buffer that reads the reply to `--More--`."
const _WRSAMP_MORE_BUFLEN = 5
"Maximum length of a base time read from the first data line."
const _WRSAMP_BTIME_LEN = 23
"Escape character of the input fields."
const _WRSAMP_ESC = UInt8('\\')

# The dither generator (triangular PDF in (-1,1)).
function _wrsamp_dither(rng::GlibcRand)
    a = Float64(glibc_rand!(rng))
    b = Float64(glibc_rand!(rng))
    (a + b) / RAND_MAX - 1.0
end

# Read a line delimited by rsep (an unterminated last line is discarded).
# Returns nothing at the end of the input. As in C, the line is a C string
# (it ends at its first null character, if any).
function _wrsamp_read_line(ifile::WfdbFile, rsep::UInt8)
    buf = UInt8[]
    while true
        c = getc(ifile)
        c == rsep && break
        c == EOF && return nothing
        push!(buf, c % UInt8)
    end
    cstr(buf)
end

function _wrsamp_line_has_alpha(line::Union{Nothing,Vector{UInt8}})
    line === nothing && return false
    p = 0
    while _byte0(line, p) != 0
        c = _byte0(line, p)
        if c == UInt8('e') || c == UInt8('E')
            # might be a number in printf %f form: ignore 'e' or 'E' if
            # followed by a digit or a sign
            p += 1
            d = _byte0(line, p)
            if reinterpret(Int8, d) <= Int8('9') || d == UInt8('-') || d == UInt8('+')
                d == 0 && break
                p += 1
                continue
            end
        end
        c_isalpha(_byte0(line, p)) && return true
        p += 1
    end
    false
end

# Parse a line into tokens (as parseline() in wrsamp.c, with consecutive
# delimiters collapsed and '\\' as the escape character). Quoted tokens
# ('...', "...", or <...>) may contain delimiters.
function _wrsamp_parseline(line::AbstractVector{UInt8}, delim::Vector{UInt8})
    tokens = Vector{UInt8}[]
    n = length(line)
    p = 1
    while p <= n
        while p <= n && line[p] in delim
            p += 1
        end
        p > n && break
        q = 0x00
        if line[p] == UInt8('"') || line[p] == UInt8('\'')
            q = line[p]
            p += 1
        elseif line[p] == UInt8('<')
            p += 1
            q = UInt8('>')
        end
        tok = UInt8[]
        while p <= n && (q != 0 || !(line[p] in delim))
            c = line[p]
            if c == _WRSAMP_ESC
                p + 1 > n && break      # escape at end of line -- ignore
                push!(tok, line[p+1])
                p += 2
                continue
            end
            if c == q
                # found the closing quote
                p += 1
                break
            end
            push!(tok, c)
            p += 1
        end
        push!(tokens, tok)
    end
    tokens
end

const _WRSAMP_HELP = [
    "usage: %s [OPTIONS ...] [COLUMN ...]\n",
    "where COLUMN selects a field to be copied (leftmost field is column 0),",
    "and OPTIONS may include:",
    " -c          check that each input line contains the same number of fields",
    " -d          add dither to the input",
    " -f N        start copying with line N (default: 0)",
    " -F FREQ     specify frequency to be written to header file (required",
    "              with -o)",
    " -G GAIN     specify gain(s) to be written to header file (required with",
    "              -o; 0 means uncalibrated)",
    " -h          print this usage summary",
    " -i FILE     read input from FILE (default: standard input)",
    " -o RECORD   save output in RECORD.dat, and generate a header file for",
    "              RECORD (default: write to standard output in format 16, do",
    "              not generate a header file)",
    " -O FORMAT   save output in the specified FORMAT (default: 16)",
    " -r RSEP     interpret RSEP as the input line separator (default: linefeed)",
    " -R BITS     specify ADC resolution(s) in bits (required with -o)",
    " -s FSEP     interpret any character in FSEP as an input field separator",
    "             (default: space, tab, carriage-return, or comma)  ",
    " -t N        stop copying at line N (default: end of input file)",
    " -U UNITS    specify units (required with -o for calibrated signals, unless",
    "              the input gives them)",
    " -x SCALE    multiply inputs by SCALE factor(s) (default: 1)",
    " -z          don't copy column 0 unless explicitly specified",
    "",
    "The input is a text file with a sample of each signal on each line. Samples",
    "can be separated by tabs, spaces, commas, or any combination of these.",
    "Consecutive separators are equivalent to single separators.",
    "",
    "To specify different GAIN or SCALE values for each output signal, provide",
    "a quoted list of values, e.g., -G \"100 50\" defines the gain for signal 0",
    "as 100, and the gain for signal 1 (and any additional signals) as 50.",
    "",
    "If the first input line contains any alphabetic characters, it is assumed",
    "to contain column headings, which are copied as signal descriptions into",
    "RECORD.hea.  If the second input line also contains alphabetic characters,",
    "it is assumed to specify the physical units for each column, which are",
    "copied as units strings into RECORD.hea.  The first line containing samples",
    "is line 0.",
    "",
    "If no COLUMN is specified, all fields are copied in order; column 0 can be",
    "omitted in this case by using the '-z' option.",
]
# wfdb-x: the help text of the original program, printed in legacy mode
const _WRSAMP_LEGACY_HELP = [
    _WRSAMP_HELP[1:6];
    " -F FREQ     specify frequency to be written to header file (default: 250)";
    " -G GAIN     specify gain(s) to be written to header file (default: 200)";
    _help_without(_WRSAMP_HELP, [1:10; 18; 22:23])]

function _wrsamp_help(pname, legacy::Bool)
    help = legacy ? _WRSAMP_LEGACY_HELP : _WRSAMP_HELP
    ceprintf(help[1], pname)
    for i in 2:length(help)
        ceprintf("%s\n", help[i])
        if (i - 1) % _WRSAMP_HELP_PAGE == 0
            ceprintf("--More--")
            stdin_ = wfdb_stdin()
            fgets!(stdin_, UInt8[], _WRSAMP_MORE_BUFLEN)
            fclose(stdin_)
            ceprintf("\e[A\e[2K")    # erase "--More--"
        end
    end
end

# sscanf(s, "%lf", &x)
_wrsamp_scan_f64(s::AbstractVector{UInt8}, x::Ref{Float64}) = csscanf(s, "%lf", x)

# Does line l start with the bytes of p?
_wrsamp_prefix(l::AbstractVector{UInt8}, p) = length(l) >= length(p) && view(l, 1:length(p)) == p

# The text of a line `<tag>text</tag>` (as the C program takes it: the line
# without its first length(open) and last length(open) + 1 bytes).
function _wrsamp_xml_text(l::AbstractVector{UInt8}, open)
    a = length(open)
    length(l) >= 2 * a + 1 ? view(l, a+1:length(l)-a-1) : view(l, 1:0)
end

# The ADC resolution of a format, in legacy mode (the C program inferred it
# from the format, or assumed WFDB_DEFRES).
function _wrsamp_legacy_adcres(format::Int32)
    (format == 508 || format == 80) ? Int32(8) :
    (format == 310 || format == 311) ? Int32(10) :
    format == 212 ? Int32(12) :
    (format == 516 || format == 16 || format == 160 || format == 61) ? Int32(16) :
    (format == 524 || format == 24) ? Int32(24) :
    format == 32 ? Int32(32) :
    # resolution for unknown future formats
    (format > 100 && format % 100 > 0 && format % 100 <= 32) ? format % Int32(100) : WFDB_DEFRES
end

function wrsamp_main(args::Vector{String})
    # wfdb-x: --legacy as the first argument selects legacy mode (the
    # behavior of the original program; see wfdbx_legacy_args)
    legacy = wfdbx_legacy_args(args) != 0
    argv = cargs(args)              # C argv[i] (i >= 1) is argv[i]
    argc = length(argv) + 1
    pname = "wrsamp"
    gain = UInt8[]
    res = UInt8[]                   # wfdb-x: -R
    uopt = nothing                  # wfdb-x: -U
    scale = UInt8[]
    record = nothing
    delim = Vector{UInt8}(b" \t\r\n,")      # defpmode.delim
    rsep = UInt8('\n')
    sflag = false
    xflag = false
    dstrings = Vector{UInt8}[]
    ustrings = Vector{UInt8}[]
    have_dstrings = false
    have_ustrings = false
    freq = legacy ? WFDB_DEFFREQ : 0.0  # wfdb-x: no default frequency (C, legacy: 250)
    dflag = false
    format = Int32(16)
    zflag = UInt32(0)
    ifile = wfdb_stdin()
    ifile_is_stdin = true
    t0 = Int64(0)
    t1 = Int64(0)
    rng = GlibcRand()
    fref = Ref{Float64}(0.0)

    i = 1
    while i < argc && !isempty(argv[i]) && argv[i][1] == UInt8('-')
        c = length(argv[i]) >= 2 ? argv[i][2] : 0x00
        if c == UInt8('c')
        elseif c == UInt8('d')
            dflag = true
            glibc_srand!(rng, 0)    # seed for dither RNG
        elseif c == UInt8('f')
            i += 1
            i < argc && (t0 = atol(argv[i]))
            if i >= argc || t0 <= 0
                ceprintf("%s: starting line # must follow -f\n", pname)
                cexit(1)
            end
        elseif c == UInt8('F')
            i += 1
            i < argc && (freq = atof(argv[i]))
            if i >= argc || freq <= 0.0
                ceprintf("%s: sampling frequency must follow -F\n", pname)
                cexit(1)
            end
        elseif c == UInt8('G')
            i += 1
            if i >= argc
                ceprintf("%s: gain(s) must follow -G\n", pname)
                cexit(1)
            end
            gain = copy(cstr(argv[i]))
        elseif c == UInt8('h')
            _wrsamp_help(pname, legacy)
            cexit(1)
        elseif c == UInt8('R') && !legacy  # wfdb-x: ADC resolution(s) in bits
            i += 1
            if i >= argc
                ceprintf("%s: ADC resolution(s) must follow -R\n", pname)
                cexit(1)
            end
            res = copy(cstr(argv[i]))
        elseif c == UInt8('U') && !legacy  # wfdb-x: units
            i += 1
            if i >= argc
                ceprintf("%s: units must follow -U\n", pname)
                cexit(1)
            end
            uopt = copy(cstr(argv[i]))
        elseif c == UInt8('i')
            i += 1
            if i >= argc
                ceprintf("%s: input file name must follow -i\n", pname)
                cexit(1)
            end
            if argv[i] == b"-"
                if !ifile_is_stdin
                    fclose(ifile)
                    ifile = wfdb_stdin()
                    ifile_is_stdin = true
                end
            else
                f = cfopen(argv[i], "r")
                if f === nothing
                    ceprintf("%s: can't read `%s'\n", pname, argv[i])
                    cexit(2)
                end
                fclose(ifile)
                ifile = f
                ifile_is_stdin = false
            end
        elseif c == UInt8('l')
            i += 1
            i >= argc && (i -= 1)
            ceprintf("%s: -l is obsolete, ignored\n", pname)
        elseif c == UInt8('o')
            i += 1
            if i >= argc
                ceprintf("%s: record name must follow -o\n", pname)
                cexit(1)
            end
            record = copy(cstr(argv[i]))
        elseif c == UInt8('O')
            i += 1
            if i >= argc
                ceprintf("%s: output format must follow -O\n", pname)
                cexit(1)
            end
            format = atoi(argv[i])
        elseif c == UInt8('r')
            i += 1
            if i >= argc
                ceprintf("%s: line separator must follow -r\n", pname)
                cexit(1)
            end
            rsep = isempty(argv[i]) ? 0x00 : argv[i][1]
        elseif c == UInt8('s')
            i += 1
            if i >= argc
                ceprintf("%s: field separator(s) must follow -s\n", pname)
                cexit(1)
            end
            sflag = true
            delim = copy(cstr(argv[i]))
        elseif c == UInt8('t')
            i += 1
            i < argc && (t1 = atol(argv[i]))
            if i >= argc || t1 <= 0
                ceprintf("%s: ending line # must follow -t\n", pname)
                cexit(1)
            end
        elseif c == UInt8('x')
            i += 1
            if i >= argc
                ceprintf("%s: scaling factor(s) must follow -x\n", pname)
                cexit(1)
            end
            scale = copy(cstr(argv[i]))
        elseif c == UInt8('z')
            zflag = UInt32(1)       # ignore column 0
        else
            ceprintf("%s: unrecognized option %s\n", pname, argv[i])
            cexit(1)
        end
        i += 1
    end

    # wfdb-x: the sampling frequency, the gains, the ADC resolutions, and the
    # units (of calibrated signals) must be specified when a header is
    # written (the C program assumed 250 Hz, 200 adu/mV, a resolution based
    # on the format, and millivolts), as legacy mode does.
    if record !== nothing && !legacy
        if freq <= 0.0
            ceprintf("%s: the sampling frequency must be specified (-F)\n", pname)
            cexit(1)
        end
        if isempty(gain) || gain[1] == 0x00
            ceprintf("%s: the gain(s) must be specified (-G)\n", pname)
            cexit(1)
        end
        if isempty(res)
            ceprintf("%s: the ADC resolution(s) must be specified (-R)\n", pname)
            cexit(1)
        end
    end

    nosig = UInt32(argc - i)    # any remaining arguments are column numbers

    # Determine the number of input columns, and (if present) the signal
    # names and the units for each signal. Start by reading the first line
    # of the input file.
    line = _wrsamp_read_line(ifile, rsep)
    if line === nothing
        if rsep != UInt8('\n')
            if record === nothing
                ceprintf("%s: use -o to specify the output record name", pname)
            else
                ceprintf("%s: no record separators in input\nTry specifying a different separator after the -r option.\n", pname)
            end
        else
            ceprintf("%s: no newlines in input\n", pname)
        end
        cexit(3)
    end
    first = line
    ncols = UInt32(0)
    # Recognize WFDB-XML format if present.
    if _wrsamp_prefix(first, b"<?xml ")
        xflag = true
        zflag = UInt32(1)       # ignore column 0
        while true
            line = _wrsamp_read_line(ifile, rsep)
            if line === nothing
                ceprintf("%s: XML input, but no <wfdbsampleset> found\n", pname)
                cexit(1)
            end
            line == b"<wfdbsampleset>" && break
        end
        while true
            line = _wrsamp_read_line(ifile, rsep)
            if line === nothing
                ceprintf("%s: empty <wfdbsampleset>\n", pname)
                cexit(1)
            end
            l = line
            if _wrsamp_prefix(l, b"<samplingfrequency>")
                fref[] = freq
                _wrsamp_scan_f64(view(l, length(b"<samplingfrequency>")+1:length(l)), fref)
                freq = fref[]
            elseif _wrsamp_prefix(l, b"<description>")
                # strip <description> and </description>
                d = _wrsamp_xml_text(l, b"<description>")
                ta = _wrsamp_parseline(d, delim)
                ncols = UInt32(length(ta))
                dstrings = ta
                have_dstrings = true
            elseif _wrsamp_prefix(l, b"<units>")
                # strip <units> and </units>
                u = _wrsamp_xml_text(l, b"<units>")
                ustrings = _wrsamp_parseline(u, delim)
                have_ustrings = true
            end
            l == b"<samplevectors>" && break
        end
        line = _wrsamp_read_line(ifile, rsep)
        if line === nothing
            ceprintf("%s: empty <wfdbsampleset>\n", pname)
            cexit(1)
        end
    else
        # non-XML input
        # Unless -s was given, note if line 0 contains any tab characters.
        (!sflag && UInt8('\t') in first) && (delim = Vector{UInt8}(b"\t"))
        ta = _wrsamp_parseline(first, delim)
        ncols = UInt32(length(ta))
        # If it contains any alphabetic characters, save the signal names.
        if _wrsamp_line_has_alpha(first)
            have_dstrings = true
            for tk in ta
                k = findfirst(!=(UInt8(' ')), tk)
                push!(dstrings, k === nothing ? UInt8[] : tk[k:end])
            end
            # Read the second line.
            line = _wrsamp_read_line(ifile, rsep)
            if line === nothing
                ceprintf("%s: no data\n", pname)
                cexit(1)
            end
            if _wrsamp_line_has_alpha(line)
                # If it has any alphabetic characters, save the unit strings.
                ta = _wrsamp_parseline(line, delim)
                have_ustrings = true
                for tk in ta
                    k = findfirst(!=(UInt8(' ')), tk)
                    u = k === nothing ? UInt8[] : tk[k:end]
                    if !isempty(u) && u[1] == UInt8('(')
                        last = u[end]
                        popfirst!(u)
                        (last == UInt8(')') && !isempty(u)) && pop!(u)
                    end
                    push!(ustrings, u)
                end
                # Read the third line.
                line = _wrsamp_read_line(ifile, rsep)
                if line === nothing
                    ceprintf("%s: no data\n", pname)
                    cexit(1)
                end
            end
        end
    end

    # read selected column numbers into fv[...]
    if nosig != 0
        fv = zeros(Int32, nosig)
        r = Ref{Int32}(0)
        for (j, k) in enumerate(argc-Int(nosig):argc-1)
            r[] = 0
            if csscanf(argv[k], "%d", r) != 1 || r[] < 0 || (r[] % UInt32) >= ncols
                ceprintf("%s: unrecognized argument %s\n", pname, argv[k])
                cexit(1)
            end
            fv[j] = r[]
        end
    else
        # copy all column numbers (or all except 0) into fv[...]
        nosig = ncols - zflag
        if nosig > typemax(Int32)
            ceprintf("WFDB: can't allocate (%lu*%lu) bytes for fv\n", UInt64(nosig), UInt64(4))
            cexit(1)
        end
        fv = Int32[k + Int32(zflag) for k in Int32(0):Int32(nosig)-Int32(1)]
    end

    n = Int(nosig)
    vout = zeros(Int32, n)
    si = [Siginfo() for _ in 1:n]
    scalef = zeros(Float64, n)

    # open the output record
    ofname = record === nothing ? Vector{UInt8}(b"-") : vcat(record, b".dat")

    gp = 1      # position in gain
    sp = 1      # position in scale
    rp = 1      # position in res
    up = 1      # position in uopt
    iref = Ref{Int32}(0)
    for k in 1:n
        s = si[k]
        s.fname = copy(ofname)
        s.desc = have_dstrings ? (fv[k] < length(dstrings) ? copy(dstrings[fv[k]+1]) : UInt8[]) :
                 cformat("col %d", fv[k])
        if uopt !== nothing         # wfdb-x: -U (the last one applies to the rest)
            while up <= length(uopt) && uopt[up] == UInt8(' ')
                up += 1
            end
            if up <= length(uopt)
                q = up
                while q <= length(uopt) && uopt[q] != UInt8(' ')
                    q += 1
                end
                s.units = uopt[up:q-1]
                up = q
            else
                s.units = k == 1 ? UInt8[] : copy(si[k-1].units)
            end
        else
            s.units = have_ustrings ?
                      (fv[k] < length(ustrings) ? copy(ustrings[fv[k]+1]) : UInt8[]) : UInt8[]
        end
        s.group = 0
        s.fmt = format
        s.spf = 1
        s.bsize = 0
        # wfdb-x: the ADC resolutions are given by -R (the last one applies
        # to the remaining signals); the C program (and legacy mode) inferred
        # them from the format or assumed WFDB_DEFRES.
        if legacy
            s.adcres = _wrsamp_legacy_adcres(format)
        else
            while rp <= length(res) && res[rp] == UInt8(' ')
                rp += 1
            end
            iref[] = 0
            if csscanf(view(res, min(rp, length(res) + 1):length(res)), "%d", iref) < 1
                s.adcres = k == 1 ? Int32(0) : si[k-1].adcres
            else
                s.adcres = iref[]
                while rp <= length(res) && res[rp] != UInt8(' ')
                    rp += 1
                end
            end
            if record !== nothing && s.adcres < 1
                ceprintf("%s: the ADC resolution(s) must be specified (-R)\n", pname)
                cexit(1)
            end
        end
        s.adczero = 0
        s.baseline = 0
        while gp <= length(gain) && gain[gp] == UInt8(' ')
            gp += 1
        end
        fref[] = 0.0
        if _wrsamp_scan_f64(view(gain, min(gp, length(gain) + 1):length(gain)), fref) < 1
            # wfdb-x: no default gain (C, legacy mode: WFDB_DEFGAIN)
            s.gain = k > 1 ? si[k-1].gain : legacy ? WFDB_DEFGAIN : 0.0
        else
            s.gain = fref[]
            while gp <= length(gain) && gain[gp] != UInt8(' ')
                gp += 1
            end
        end
        # wfdb-x: the units of a calibrated signal must be specified, by -U
        # or by the input (the C program left them out: millivolts).
        if record !== nothing && !legacy && s.gain != 0.0 && isempty(cstr(s.units))
            ceprintf("%s: the units must be specified (-U)\n", pname)
            cexit(1)
        end
        while sp <= length(scale) && scale[sp] == UInt8(' ')
            sp += 1
        end
        fref[] = 0.0
        if _wrsamp_scan_f64(view(scale, min(sp, length(scale) + 1):length(scale)), fref) < 1
            scalef[k] = k == 1 ? 1.0 : scalef[k-1]
        else
            scalef[k] = fref[]
            while sp <= length(scale) && scale[sp] != UInt8(' ')
                sp += 1
            end
        end
    end

    # discard any additional lines containing text
    while _wrsamp_line_has_alpha(line)
        line = _wrsamp_read_line(ifile, rsep)
    end

    # (As in C, the result of osigfopen is compared with an unsigned number,
    # so that errors are not detected here.)
    if (osigfopen(si, nosig) % UInt32) < nosig || setsampfreq(freq) < 0
        cexit(2)
    end

    # skip any unwanted samples at the beginning
    t = Int64(0)
    while t < t0
        line = _wrsamp_read_line(ifile, rsep)
        t += 1
    end

    # pick up base time if it's there
    if zflag != 0 && line !== nothing
        l = line
        if !isempty(l) && l[1] == UInt8('[')
            setbasetime(l[2:min(length(l), 1 + _WRSAMP_BTIME_LEN)])
        elseif length(l) >= 2 && l[2] == UInt8('[')
            setbasetime(l[3:min(length(l), 2 + _WRSAMP_BTIME_LEN)])
        end
    end

    # read and copy samples
    while line !== nothing
        if t1 != 0
            ok = t < t1
            t += 1
            ok || break
        end
        ta = _wrsamp_parseline(line, delim)

        for k in 1:n
            tok = fv[k] < length(ta) ? ta[fv[k]+1] : UInt8[]
            fref[] = 0.0
            if _wrsamp_scan_f64(tok, fref) == 1
                v = fref[] * scalef[k]
                dflag && (v += _wrsamp_dither(rng))
                vout[k] = v >= 0.0 ? d2i(v + 0.5) : d2i(v - 0.5)
            else
                vout[k] = WFDB_INVALID_SAMPLE
            end
        end
        putvec(vout) < 0 && break

        line = _wrsamp_read_line(ifile, rsep)
        if xflag && line !== nothing && _wrsamp_prefix(line, b"</samplevectors>")
            line = _wrsamp_read_line(ifile, rsep)
            if line !== nothing && line != b"</wfdbsampleset>"
                ceprintf("%s: (warning) unexpected EOF in XML input\n", pname)
            end
            break
        end
    end

    # write the header
    setsampfreq(freq)
    record === nothing || newheader(record)
    wfdbquit()
    fclose(ifile)
    cexit(0)
end

register_workload("wrsamp") do
    input = "col A,col B\nmV,uV\n1,2\n3,-4\n5.5,6e2\n-7,x\n"
    with_workload_data() do dir
        for fmt in ("8", "16", "61", "80", "160", "212", "310", "311", "24", "32", "516")
            workload_tool("wrsamp", "-o", "wl", "-O", fmt, "-F", "100", "-G", "100 50", "-R",
                          "16"; stdin=input)
        end
        workload_tool("wrsamp", "-o", "wl", "-F", "360", "-G", "200", "-R", "12", "-d", "-x", "2",
                      "-z", "-f", "1", "-t", "3", "1"; stdin=input)
        workload_tool("wrsamp", "-o", "wl", "-F", "360", "-G", "200", "-R", "12", "-U", "mV", "-i",
                      "100s.atr.txt", "-s", " ", "-r", "\n")
        workload_tool("wrsamp", "-o", "wl", "-F", "250", "-G", "200 0", "-R", "16 12", "-U",
                      "mV"; stdin="1 2\n3 4\n")
        workload_tool("wrsamp", "-o", "wl", "-F", "250", "-G", "200", "-R", "0", "-U", "mV";
                      stdin=input)
        workload_tool("wrsamp", "-o", "wl", "-F", "250", "-G", "200", "-R", "16";
                      stdin="1 2\n3 4\n")
        workload_tool("wrsamp", "-o", "wl", "-F", "250", "-G", "200"; stdin=input)
        workload_tool("wrsamp", "-o", "wl", "-F", "250", "-G", "0", "-R", "16"; stdin=input)
        workload_tool("wrsamp", "-o", "wl", "-F", "250"; stdin=input)
        workload_tool("wrsamp", "-o", "wl"; stdin=input)
        workload_tool("wrsamp", "-O", "16"; stdin="1 2\n3 4\n")
        workload_tool("rdsamp", "-r", "100s", "-t", "0.1", "-X")
        xml = String(run_tool("rdsamp", ["-r", "100s", "-t", "0.05", "-p", "-X"]; env=("WFDB" => ".",))[2])
        workload_tool("wrsamp", "-o", "wlx", "-F", "360", "-G", "200", "-R", "11"; stdin=xml)
        workload_tool("wrsamp", "-x")
        workload_tool("wrsamp"; stdin="")
        # wfdb-x: legacy mode (original behavior)
        for fmt in ("8", "16", "80", "212", "310", "24", "32", "516", "508")
            workload_tool("wrsamp", "--legacy", "-o", "wl", "-O", fmt; stdin=input)
        end
        workload_tool("wrsamp", "--legacy", "-o", "wl", "-G", "100 0", "-F", "100";
                      stdin="1 2\n3 4\n")
        workload_tool("wrsamp", "--legacy", "-o", "wl", "-R", "12"; stdin=input)
        workload_tool("wrsamp", "--legacy", "-h"; stdin="\n")
    end
end
