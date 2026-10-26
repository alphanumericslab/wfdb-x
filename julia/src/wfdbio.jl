# wfdbio.jl: low-level I/O of the WFDB library (port of lib/wfdbio.c):
# locating files (the input and output directories, wfdbx_set_input_dir,
# wfdbx_set_output_dir; the WFDB path, getwfdb, setwfdb, ..., in legacy
# mode), opening WFDB files (wfdb_open, wfdb_fopen, wfdbfile), remote files
# (wfdbx_set_network), error reporting (wfdb_error, wfdberror, wfdbquiet),
# and `WfdbFile`, the buffered file type used by the library and the tools
# (C's WFDB_FILE / FILE *).
#
# Design decision (Reza Sameni, Oct 2026): files are found by explicit names
# instead of a search of the WFDB path. A relative name is read under the
# input directory and written under the output directory (by default, the
# current directory); an absolute name, a ~ name or a URL is used as given;
# nothing else is searched. A URL is opened only if network access was
# allowed (wfdbx_set_network or WFDBX_NETWORK; read with the Downloads
# standard library). Reasons: a search can silently open the wrong file (a
# stale copy earlier in the path) and fails in ways nobody notices, it sent
# local paths and record names to physionet.org (in another port), and the
# network must not be used without being asked for. The original behavior
# remains available with --legacy (see docs/DIVERGENCES.md); it reads no
# remote files (as the reference C build, compiled without network
# support).
#
# Copyright (C) 1988-2013 George B. Moody (original C implementation,
# lib/wfdbio.c; revised 2010-2022 by Benjamin Moody).
# Julia implementation part of wfdb-x, Reza Sameni, Oct 2026.
# GNU Library General Public License, version 2 or later (see LICENSE.LIB).

# The date reported by wfdberror (that of the 10.7.0 release; the C library
# reports the date on which it was compiled).
const WFDB_BUILD_DATE = b"Jun 10 2022"

# Directory separator.
const DSEP = UInt8('/')

"Default size of a [`WfdbFile`](@ref) buffer."
const WFDB_BUFSIZE = 32768
# Size of the read buffer of a WfdbFile when the file system does not give
# one: that of glibc's stdio buffers (st_blksize, usually 4096).
const _RBUFSIZE = 4096

# ===========================================================================
# WfdbFile

const _K_FILE = 0x01     # a file (raw descriptor)
const _K_STDIN = 0x02    # the standard input
const _K_STDOUT = 0x03   # the standard output (shared buffer of cstd)
const _K_STDERR = 0x04   # the standard error (unbuffered)
const _K_MEM = 0x05      # in-memory input

"""
    WfdbFile

An open file with C stdio semantics (C's `FILE *` and the WFDB library's
`WFDB_FILE`).

* Reads and writes are buffered; [`getc`](@ref) and [`putc`](@ref) are
  inlined fast paths.
* End of file and errors set sticky flags ([`feof`](@ref), [`ferror`](@ref))
  as glibc does: after end of file, reads return `EOF` until
  [`clearerr`](@ref) or a seek.
* A file opened on the standard input ([`wfdb_stdin`](@ref), or `wfdb_open`
  of `"-"`) never closes it; bytes it buffered but did not consume are given
  back to the next reader of the standard input when it is closed.
* A file opened on the standard output writes into the shared buffered
  standard output, so its output is ordered with [`cprintf`](@ref).
* Writable files are flushed by `cexit` (as C's `exit` flushes every
  stream); [`fclose`](@ref) returns the status of C's `fclose`.

Opened with [`wfdb_fopen`](@ref) (the library's checks), [`cfopen`](@ref)
(plain `fopen`), [`wfdb_open`](@ref) (WFDB path search), or
[`wfdb_memfile`](@ref) (in memory).
"""
mutable struct WfdbFile
    kind::UInt8
    fd::Int32                   # raw descriptor (_K_FILE, _K_STDIN); -1 if none
    owns_fd::Bool               # close fd when the file is closed
    rbuf::Vector{UInt8}
    rpos::Int                   # bytes of rbuf consumed (0-based offset)
    rlen::Int                   # bytes of rbuf holding data
    wbuf::Vector{UInt8}
    wready::Bool                # ready for buffered writes
    bufsize::Int
    # read buffer size (glibc reads blocks of st_blksize bytes): so that the
    # file is read when, and as far as, C reads it (this matters when a file
    # is read while it is being rewritten)
    rbufsize::Int
    fpos::Int64                 # offset of the descriptor (-1: unknown)
    eof::Bool
    err::Bool
    can_read::Bool
    can_write::Bool
    append::Bool
    closed::Bool
    remote::Bool                # wfdb-x: the contents of a URL (read in memory)
end

function WfdbFile(kind::UInt8, can_read::Bool, can_write::Bool)
    WfdbFile(kind, Int32(-1), false, UInt8[], 0, 0, UInt8[], false, WFDB_BUFSIZE, _RBUFSIZE,
             Int64(0), false, false, can_read, can_write, false, false, false)
end

function Base.show(io::IO, f::WfdbFile)
    k = f.kind == _K_FILE ? "file" : f.kind == _K_STDIN ? "stdin" :
        f.kind == _K_STDOUT ? "stdout" : f.kind == _K_STDERR ? "stderr" : "memory"
    print(io, "WfdbFile(", k, f.closed ? ", closed" : "", ")")
end

# Raw file system calls (they return error codes: no exceptions, whose
# messages would be compiled at run time).
const _O_BINARY = Sys.iswindows() ? 0x8000 : 0

"`open(2)`: a file descriptor, or -1."
function raw_open(path::Vector{UInt8}, flags::Integer)
    (isempty(path) || 0x00 in path) && return Int32(-1)
    @static if _HAVE_POSIX_IO
        Int32(ccall(:open, Cint, (Ptr{UInt8}, Cint, Cuint...), _cpath(path), flags, 0o666))
    else
        Int32(ccall(:_wopen, Cint, (Cwstring, Cint, Cint...), bstr(path), flags | _O_BINARY, 0o666))
    end
end

"`close(2)`."
raw_close(fd::Integer) = @static _HAVE_POSIX_IO ? ccall(:close, Cint, (Cint,), fd) :
                                                ccall(:_close, Cint, (Cint,), fd)

"`mkdir(2)` with mode 0755: true on success."
function raw_mkdir(path::Vector{UInt8})
    (isempty(path) || 0x00 in path) && return false
    @static if _HAVE_POSIX_IO
        ccall(:mkdir, Cint, (Ptr{UInt8}, Cuint), _cpath(path), 0o755) == 0
    else
        ccall(:_wmkdir, Cint, (Cwstring,), bstr(path)) == 0
    end
end

# A NUL-terminated copy of a path.
_cpath(p::Vector{UInt8}) = push!(copy(p), 0x00)

function _close_fd!(f::WfdbFile)
    if f.owns_fd && f.fd >= 0
        raw_close(f.fd)
        f.owns_fd = false
    end
    nothing
end

"""
    cfopen(path, mode) -> Union{WfdbFile,Nothing}

C `fopen(path, mode)` (no WFDB path search or name checks; see
[`wfdb_fopen`](@ref) for the library's version). `mode` is a C mode string
(`"rb"`, `"wb"`, `"ab"`, `"r+b"`, ...; `b` and `t` are ignored).
"""
function cfopen(path::ByteStr, mode::ByteStr)
    m = UInt8[c for c in _bv(mode) if c != UInt8('b') && c != UInt8('t')]
    isempty(m) && return nothing
    plus = UInt8('+') in m
    FS = Base.Filesystem
    if m[1] == UInt8('r')
        flags = plus ? FS.JL_O_RDWR : FS.JL_O_RDONLY
        r, w, app = true, plus, false
    elseif m[1] == UInt8('w')
        flags = (plus ? FS.JL_O_RDWR : FS.JL_O_WRONLY) | FS.JL_O_CREAT | FS.JL_O_TRUNC
        r, w, app = plus, true, false
    elseif m[1] == UInt8('a')
        flags = (plus ? FS.JL_O_RDWR : FS.JL_O_WRONLY) | FS.JL_O_CREAT | FS.JL_O_APPEND
        r, w, app = plus, true, true
    else
        return nothing
    end
    fd = raw_open(cstr(bytes(path)), flags)
    fd < 0 && return nothing
    f = WfdbFile(_K_FILE, r, w)
    f.fd = fd
    f.owns_fd = true
    bs = try
        Int(stat(Base.RawFD(fd)).blksize)
    catch
        0
    end
    bs > 0 && (f.rbufsize = bs)
    if app
        # (glibc positions append-mode streams at the end of the file.)
        f.fpos = raw_lseek(f.fd, 0, 2)
    end
    f.append = app
    w && (cproc().open_files[f] = nothing)
    r && !w && finalizer(_finalize_file, f)
    f
end

function _finalize_file(f::WfdbFile)
    # (read-only files only: release the descriptor of a dropped file)
    if !f.closed
        f.closed = true
        _close_fd!(f)
    end
    nothing
end

"A [`WfdbFile`](@ref) on the standard input (C's `stdin`)."
function wfdb_stdin()
    p = cproc()
    f = WfdbFile(_K_STDIN, true, false)
    if p.stdin_mem === nothing
        f.fd = p.stdin_fd
        f.fpos = isempty(p.stdin_pushback) ? raw_lseek(f.fd, 0, 1) : Int64(-1)
    else
        f.fpos = -1
    end
    f
end

"A [`WfdbFile`](@ref) on the standard output (C's `stdout`)."
function wfdb_stdout()
    f = WfdbFile(_K_STDOUT, false, true)
    f.fpos = -1
    f
end

"A [`WfdbFile`](@ref) on the standard error (C's `stderr`, unbuffered)."
function wfdb_stderr()
    f = WfdbFile(_K_STDERR, false, true)
    f.fpos = -1
    f
end

"An input [`WfdbFile`](@ref) reading from memory (seekable)."
function wfdb_memfile(data::ByteStr)
    f = WfdbFile(_K_MEM, true, false)
    f.rbuf = Vector{UInt8}(copy(_bv(data)))
    f.rlen = length(f.rbuf)
    f.fpos = f.rlen
    f
end

"Is this the standard input, output, or error?"
is_std(f::WfdbFile) = f.kind == _K_STDIN || f.kind == _K_STDOUT || f.kind == _K_STDERR

"The type of the file: `WFDB_NET` for a remote file (read from a URL), else `WFDB_LOCAL`."
file_type(f::WfdbFile) = f.remote ? WFDB_NET : WFDB_LOCAL

"Set the buffer size (C `setvbuf`, before any I/O)."
set_bufsize!(f::WfdbFile, n::Integer) = (f.bufsize = max(Int(n), 1); f)

# ------------------------------------------------------------------- input

function _raw_read!(f::WfdbFile, buf::Vector{UInt8}, n::Int)
    if f.kind == _K_FILE
        return GC.@preserve buf raw_read(f.fd, pointer(buf), n)
    elseif f.kind == _K_STDIN
        p = cproc()
        pb = p.stdin_pushback
        if !isempty(pb)
            k = min(length(pb), n)
            copyto!(buf, 1, pb, 1, k)
            deleteat!(pb, 1:k)
            return k
        end
        mem = p.stdin_mem
        if mem !== nothing
            k = min(length(mem) - p.stdin_mempos, n)
            k <= 0 && return 0
            copyto!(buf, 1, mem, p.stdin_mempos + 1, k)
            p.stdin_mempos += k
            return k
        end
        return GC.@preserve buf raw_read(f.fd, pointer(buf), n)
    end
    0
end

# Refill the read buffer; false at end of file or on error.
function _fill!(f::WfdbFile)
    (f.eof || f.err) && return false
    if !f.can_read
        f.err = true
        return false
    end
    if f.kind == _K_MEM
        f.eof = true
        return false
    end
    if !isempty(f.wbuf) && _flush_wbuf!(f) != 0
        return false
    end
    f.wready = false
    length(f.rbuf) < f.rbufsize && resize!(f.rbuf, f.rbufsize)
    r = _raw_read!(f, f.rbuf, f.rbufsize)
    if r == 0
        f.rpos = 0
        f.rlen = 0
        f.eof = true
        return false
    elseif r < 0
        f.err = true
        return false
    end
    f.rpos = 0
    f.rlen = r
    f.fpos >= 0 && (f.fpos += r)
    true
end

"C `getc`: the next byte (0:255), or `EOF` (-1)."
@inline function getc(f::WfdbFile)
    if f.rpos < f.rlen
        f.rpos += 1
        return Int32(@inbounds f.rbuf[f.rpos])
    end
    _getc_slow(f)
end

@noinline function _getc_slow(f::WfdbFile)
    if _fill!(f)
        f.rpos += 1
        return Int32(@inbounds f.rbuf[f.rpos])
    end
    EOF
end

"C `ungetc(c, f)`: push a byte back (returns `c`, or `EOF` if `c` is `EOF`)."
function ungetc(f::WfdbFile, c::Integer)
    c == EOF && return EOF
    if f.rpos > 0
        f.rbuf[f.rpos] = c % UInt8
        f.rpos -= 1
    else
        if f.rlen < length(f.rbuf)
            copyto!(f.rbuf, 2, f.rbuf, 1, f.rlen)
            f.rbuf[1] = c % UInt8
        else
            pushfirst!(f.rbuf, c % UInt8)
        end
        f.rlen += 1
    end
    f.eof = false
    Int32(c)
end

"""
    fread!(f, buf, n=length(buf)) -> Int

Read up to `n` bytes into `buf[1:n]` (C `fread(buf, 1, n, f)`); returns the
number of bytes read.
"""
function fread!(f::WfdbFile, buf::AbstractVector{UInt8}, n::Integer=length(buf))
    n = Int(n)
    done = 0
    while done < n
        avail = f.rlen - f.rpos
        if avail > 0
            k = min(avail, n - done)
            copyto!(buf, done + 1, f.rbuf, f.rpos + 1, k)
            f.rpos += k
            done += k
            continue
        end
        # As glibc: a request for less than a buffer refills the buffer, and
        # larger ones read whole blocks directly.
        want = n - done
        if want < f.rbufsize || !(f.kind == _K_FILE || f.kind == _K_STDIN)
            _fill!(f) || break
            continue
        end
        count = want - want % f.rbufsize
        tmp = Vector{UInt8}(undef, count)
        r = _read_direct!(f, tmp, count)
        r <= 0 && break
        copyto!(buf, done + 1, tmp, 1, r)
        done += r
    end
    done
end

# One read(2) of up to n bytes into buf (the read buffer being empty), as
# glibc does for large requests; the number of bytes read (0 at end of file
# or on error).
function _read_direct!(f::WfdbFile, buf::Vector{UInt8}, n::Int)
    (f.eof || f.err) && return 0
    if !f.can_read
        f.err = true
        return 0
    end
    if !isempty(f.wbuf) && _flush_wbuf!(f) != 0
        return 0
    end
    f.wready = false
    r = _raw_read!(f, buf, n)
    if r == 0
        f.eof = true
        return 0
    elseif r < 0
        f.err = true
        return 0
    end
    f.fpos >= 0 && (f.fpos += r)
    r
end

"""
    fread!(f, buf, size, nitems) -> Int

C `fread(buf, size, nitems, f)`: reads up to `nitems` items of `size` bytes
into `buf` and returns the number of complete items read.
"""
function fread!(f::WfdbFile, buf::AbstractVector{UInt8}, size::Integer, nitems::Integer)
    (size == 0 || nitems == 0) && return 0
    div(fread!(f, buf, Int(size) * Int(nitems)), Int(size))
end

"""
    getline!(f, line::Vector{UInt8}) -> Int

Read a line, including its newline if any, into `line` (which is emptied
first). Returns the number of bytes read (0 at end of file).
"""
function getline!(f::WfdbFile, line::Vector{UInt8})
    empty!(line)
    while true
        if f.rpos < f.rlen
            buf = f.rbuf
            k = _findbyte(buf, UInt8('\n'), f.rpos + 1, f.rlen)
            if k != 0
                _append!(line, buf, f.rpos + 1, k)
                f.rpos = k
                return length(line)
            end
            _append!(line, buf, f.rpos + 1, f.rlen)
            f.rpos = f.rlen
        end
        _fill!(f) || return length(line)
    end
end

"""
    fgets!(f, s::Vector{UInt8}, size) -> Bool

C `fgets(s, size, f)`: read at most `size - 1` bytes, up to and including a
newline, into `s` (emptied first). Returns false (C's `NULL`) if end of file
(or an error) occurs before any byte is read.
"""
function fgets!(f::WfdbFile, s::Vector{UInt8}, size::Integer)
    empty!(s)
    lim = Int(size) - 1
    lim <= 0 && return size == 1
    while true
        if f.rpos < f.rlen
            want = lim - length(s)
            e = min(f.rpos + want, f.rlen)
            buf = f.rbuf
            k = _findbyte(buf, UInt8('\n'), f.rpos + 1, e)
            if k != 0
                _append!(s, buf, f.rpos + 1, k)
                f.rpos = k
                return true
            end
            _append!(s, buf, f.rpos + 1, e)
            f.rpos = e
            length(s) >= lim && return true
        end
        _fill!(f) || return !isempty(s)
    end
end

"Read everything up to the end of the file."
function read_to_end(f::WfdbFile)
    v = UInt8[]
    while true
        if f.rpos < f.rlen
            _append!(v, f.rbuf, f.rpos + 1, f.rlen)
            f.rpos = f.rlen
        end
        _fill!(f) || return v
    end
end

"""
    wfdb_g16(f) -> Int32

A 16-bit integer in PDP-11 (little-endian) byte order, sign-extended. At end
of file the missing bytes read as 0xff (`EOF`).
"""
@inline function wfdb_g16(f::WfdbFile)
    x = getc(f)
    y = getc(f)
    Int32(((y << 8) | (x & Int32(0xff))) % Int16)
end

"""
    wfdb_g32(f) -> Int64

A 32-bit integer in PDP-11 byte order (high 16-bit word first, each word
little-endian), as a C `long`.
"""
@inline function wfdb_g32(f::WfdbFile)
    x = Int64(wfdb_g16(f))
    y = Int64(wfdb_g16(f))
    (x << 16) | (y & 0xffff)
end

# ------------------------------------------------------------------ output

function _flush_wbuf!(f::WfdbFile)
    isempty(f.wbuf) && return Int32(0)
    n = length(f.wbuf)
    err = f.kind == _K_FILE ? (GC.@preserve f raw_write(f.fd, pointer(f.wbuf), n)) : 0
    empty!(f.wbuf)
    if err == 0
        if f.append
            f.fpos = raw_lseek(f.fd, 0, 1)
        elseif f.fpos >= 0
            f.fpos += n
        end
        return Int32(0)
    end
    f.err = true
    EOF
end

# Prepare for writing (leave read mode); false if not writable.
function _prepare_write!(f::WfdbFile)
    if !f.can_write
        f.err = true
        return false
    end
    if f.rpos < f.rlen && f.kind == _K_FILE
        # Reposition the descriptor at the logical position.
        back = f.rlen - f.rpos
        p = raw_lseek(f.fd, -back, 1)
        if p < 0
            f.err = true
            return false
        end
        f.fpos = p
    end
    f.rpos = 0
    f.rlen = 0
    if f.kind == _K_FILE
        f.wready = true
        sizehint!(f.wbuf, f.bufsize)
    end
    true
end

"C `putc`: write a byte; returns it, or `EOF` on error."
@inline function putc(f::WfdbFile, c::Integer)
    if f.wready && length(f.wbuf) < f.bufsize
        push!(f.wbuf, c % UInt8)
        return Int32(c % UInt8)
    end
    _putc_slow(f, c % UInt8)
end

@noinline function _putc_slow(f::WfdbFile, c::UInt8)
    fwrite(f, UInt8[c]) == 1 ? Int32(c) : EOF
end

"""
    fwrite(f, b) -> Int

C `fwrite(b, 1, length(b), f)`: returns the number of bytes written.
"""
function fwrite(f::WfdbFile, b::AbstractVector{UInt8})
    if !f.wready && !_prepare_write!(f)
        return 0
    end
    n = length(b)
    if f.kind == _K_STDOUT
        cout_write(b)
        return n
    elseif f.kind == _K_STDERR
        cerr_write(b)
        return n
    end
    if length(f.wbuf) + n > f.bufsize
        _flush_wbuf!(f) != 0 && return 0
        if n >= f.bufsize
            v = b isa Vector{UInt8} ? b : Vector{UInt8}(b)
            err = f.kind == _K_FILE ? (GC.@preserve v raw_write(f.fd, pointer(v), n)) : 0
            if err != 0
                f.err = true
                return 0
            end
            if f.append
                f.fpos = raw_lseek(f.fd, 0, 1)
            elseif f.fpos >= 0
                f.fpos += n
            end
            return n
        end
    end
    append!(f.wbuf, b)
    n
end
fwrite(f::WfdbFile, s::AbstractString) = fwrite(f, codeunits(String(s)))

"""
    cfprintf(f, fmt, args...) -> Int32

C `fprintf(f, fmt, ...)`: returns the number of bytes written (or -1 on
error). See [`sprintf!`](@ref) for the format.
"""
function cfprintf(f::WfdbFile, fmt::ByteStr, args::Vararg{Any,N}) where {N}
    if f.kind == _K_STDOUT
        return cprintf(fmt, args...)
    elseif f.kind == _K_STDERR
        return ceprintf(fmt, args...)
    end
    if !f.wready && !_prepare_write!(f)
        return Int32(-1)
    end
    n = sprintf!(f.wbuf, fmt, args...)
    if length(f.wbuf) >= f.bufsize && _flush_wbuf!(f) != 0
        return Int32(-1)
    end
    Int32(n)
end

"`wfdb_p16`: write a 16-bit integer in PDP-11 byte order."
@inline function wfdb_p16(f::WfdbFile, x::Integer)
    putc(f, x % UInt8)
    putc(f, (x >> 8) % UInt8)
    nothing
end

"`wfdb_p32`: write a 32-bit integer in PDP-11 byte order (high word first)."
@inline function wfdb_p32(f::WfdbFile, x::Integer)
    x = Int64(x)
    wfdb_p16(f, x >> 16)
    wfdb_p16(f, x)
    nothing
end

"C `fflush`: returns 0, or `EOF` on error."
fflush(f::WfdbFile) = f.kind == _K_STDOUT ? cflush() : _flush_wbuf!(f)

_flush_at_exit(f::WfdbFile) = (f.closed || _flush_wbuf!(f); nothing)

# --------------------------------------------------------------- positions

"C `ftell`: the current position, or -1 if it is unknown (a pipe)."
function ftell(f::WfdbFile)
    if f.kind == _K_STDOUT
        cflush()
        cproc().out_capture === nothing || return Int64(-1)
        return raw_lseek(1, 0, 1)
    end
    f.fpos < 0 && return Int64(-1)
    f.fpos - (f.rlen - f.rpos) + length(f.wbuf)
end

"""
    fseek(f, offset, whence) -> Int32

C `fseek` (`SEEK_SET`, `SEEK_CUR`, `SEEK_END`): returns 0, or -1 on error
(e.g. on a pipe). Clears the end-of-file flag.
"""
function fseek(f::WfdbFile, offset::Integer, whence::Integer)
    (f.kind == _K_STDOUT || f.kind == _K_STDERR) && return Int32(-1)
    _flush_wbuf!(f) != 0 && return Int32(-1)
    f.wready = false
    fpos = f.fpos
    fpos < 0 && return Int32(-1)
    cur = fpos - (f.rlen - f.rpos)
    if whence == SEEK_SET
        target = Int64(offset)
    elseif whence == SEEK_CUR
        target = cur + offset
    elseif whence == SEEK_END
        if f.kind == _K_MEM
            target = Int64(length(f.rbuf) + offset)
        else
            f.fd < 0 && return Int32(-1)
            p = raw_lseek(f.fd, offset, 2)
            p < 0 && return Int32(-1)
            f.fpos = p
            f.rpos = 0
            f.rlen = 0
            f.eof = false
            return Int32(0)
        end
    else
        return Int32(-1)
    end
    target < 0 && return Int32(-1)
    if f.kind == _K_MEM
        f.rpos = Int(min(target, length(f.rbuf)))
        f.eof = false
        return Int32(0)
    end
    # Within the current read buffer: just move.
    bstart = fpos - f.rlen
    if f.rlen > 0 && bstart <= target <= fpos
        f.rpos = Int(target - bstart)
        f.eof = false
        return Int32(0)
    end
    f.fd < 0 && return Int32(-1)
    p = raw_lseek(f.fd, target, 0)
    p < 0 && return Int32(-1)
    f.fpos = p
    f.rpos = 0
    f.rlen = 0
    f.eof = false
    Int32(0)
end

"C `feof`."
feof(f::WfdbFile) = f.eof
"C `ferror`."
ferror(f::WfdbFile) = f.err || (f.kind == _K_STDOUT && cout_error())
"C `clearerr`."
clearerr(f::WfdbFile) = (f.eof = false; f.err = false; nothing)

function _release!(f::WfdbFile)
    f.closed && return Int32(0)
    f.closed = true
    status = f.err ? EOF : Int32(0)
    if f.kind == _K_STDIN
        if f.rpos < f.rlen
            pb = cproc().stdin_pushback
            prepend!(pb, view(f.rbuf, f.rpos+1:f.rlen))
        end
    elseif f.kind == _K_STDOUT
        cflush() != 0 && (status = EOF)
    else
        _flush_wbuf!(f) != 0 && (status = EOF)
    end
    f.rpos = 0
    f.rlen = 0
    if f.kind == _K_FILE
        delete!(cproc().open_files, f)
        _close_fd!(f)
    end
    status
end

"""
    fclose(f) -> Int32

C `fclose` (the standard streams are flushed, not closed): returns 0, or
`EOF` if an error occurred (including earlier write errors).
"""
fclose(f::WfdbFile) = _release!(f)
Base.close(f::WfdbFile) = (_release!(f); nothing)

# C-library-style aliases (wfdb_fclose, wfdb_getc, ...), as used in
# lib/*.c.
const wfdb_getc = getc
const wfdb_ungetc = ungetc
const wfdb_putc = putc
const wfdb_fread = fread!
const wfdb_fwrite = fwrite
const wfdb_fgets = fgets!
const wfdb_getline = getline!
const wfdb_fprintf = cfprintf
const wfdb_fflush = fflush
const wfdb_ftell = ftell
const wfdb_fseek = fseek
const wfdb_feof = feof
const wfdb_ferror = ferror
const wfdb_clearerr = clearerr
const wfdb_fclose = fclose

# ===========================================================================
# Library state of wfdbio.c

"A component of the WFDB path."
mutable struct PathComponent
    prefix::Vector{UInt8}
    ptype::Int32
end

"The state of wfdbio.c (the `io` field of a `Wfdb`)."
mutable struct IoState
    wfdbpath::Union{Nothing,Vector{UInt8}}
    wfdbpath_init::Union{Nothing,Vector{UInt8}}
    path_list::Vector{PathComponent}
    error_print::Bool
    error_flag::Bool
    error_message::Vector{UInt8}
    filename::Vector{UInt8}     # name of the file most recently opened by wfdb_open
    irec::Vector{UInt8}         # current record name (for %r in the WFDB path)
    mem_behavior::Int32
    # wfdb-x: the settings that locate files (see wfdbx_set_input_dir,
    # wfdbx_set_output_dir, wfdbx_set_network); each is read from its
    # environment variable when first needed
    input_dir::Union{Nothing,Vector{UInt8}}
    env_input_dir::Union{Nothing,Vector{UInt8}}
    input_dir_init::Bool
    setwfdb_called::Bool                        # the input directory set by setwfdb:
    setwfdb_input_dir::Union{Nothing,Vector{UInt8}}
    output_dir::Union{Nothing,Vector{UInt8}}
    env_output_dir::Union{Nothing,Vector{UInt8}}
    output_dir_init::Bool
    network::Int8                               # 1, 0, or -1: not read yet
    env_network::Bool
    wfdb_warned::Bool                           # (messages printed once)
    network_warned::Bool
    fetched::Dict{Vector{UInt8},Union{Nothing,Vector{UInt8}}}  # URL -> contents
end
IoState() = IoState(nothing, nothing, PathComponent[], true, false, UInt8[], UInt8[], UInt8[],
                    Int32(1), nothing, nothing, false, false, nothing, nothing, nothing, false,
                    Int8(-1), false, false, false,
                    Dict{Vector{UInt8},Union{Nothing,Vector{UInt8}}}())

_legacy(w::Wfdb) = wfdbx_get_legacy(w) != 0

function _spr1(record::Vector{UInt8}, ftype::Vector{UInt8})
    v = copy(record)
    if !isempty(ftype)
        push!(v, UInt8('.'))
        append!(v, ftype)
    end
    v
end

function _spr2(record::Vector{UInt8}, ftype::Vector{UInt8})
    v = copy(record)
    push!(v, UInt8('.'))
    append!(v, @view ftype[1:min(3, length(ftype))])
    v
end

"""
    freopen_stdin(name) -> Bool

C `freopen(name, "rb", stdin)`: attach the file `name` to the standard
input, so that later readers of the standard input ([`wfdb_stdin`](@ref),
`wfdb_open` of `"-"`) read it from its beginning. Bytes of the previous
standard input that were buffered but not consumed are discarded. Returns
false (and leaves the standard input unchanged) if the file cannot be
opened.
"""
function freopen_stdin(name::ByteStr)
    f = cfopen(name, "rb")
    f === nothing && return false
    p = cproc()
    p.stdin_fd = f.fd
    f.owns_fd = false   # keep the descriptor open (it is now the standard input)
    f.closed = true
    p.stdin_mem = nothing
    empty!(p.stdin_pushback)
    true
end

_is_directory(name::Vector{UInt8}) = !isempty(name) && !(0x00 in name) && isdir(bstr(name))

function _contains(hay::AbstractVector{UInt8}, needle::AbstractVector{UInt8})
    m = length(needle)
    for i in 1:length(hay)-m+1
        view(hay, i:i+m-1) == needle && return true
    end
    false
end

# Index of the first byte c in buf[a:b], or 0.
@inline function _findbyte(buf::Vector{UInt8}, c::UInt8, a::Int, b::Int)
    b < a && return 0
    p = GC.@preserve buf ccall(:memchr, Ptr{UInt8}, (Ptr{UInt8}, Cint, Csize_t),
                               pointer(buf, a), c, b - a + 1)
    p == C_NULL ? 0 : Int(p - pointer(buf)) + 1
end

_mkdir(d::Vector{UInt8}) = raw_mkdir(d)

"""
    wfdb_fopen([w], fname, mode) -> Union{WfdbFile,Nothing}

Open a file as the WFDB library does. A directory cannot be opened for
reading; when a file cannot be created (`"wb"` or `"ab"`), the missing
directories in its path are created and the file is opened again. wfdb-x:
an `http://` or `https://` URL can only be read, and only if network access
is allowed (see [`wfdbx_set_network`](@ref)). In legacy mode, names
containing `..` or `://` are refused (as by the reference C library, built
without network support).
"""
function wfdb_fopen(w::Wfdb, fname::ByteStr, mode::ByteStr)
    fname = cstr(bytes(fname))
    mode = bytes(mode)
    if _legacy(w)
        (_contains(fname, b"..") || _contains(fname, b"://")) && return nothing
    elseif _is_url(fname)
        return (!isempty(mode) && mode[1] == UInt8('r')) ? _fetch_open(w, fname) : nothing
    end
    (!isempty(mode) && mode[1] == UInt8('r') && _is_directory(fname)) && return nothing
    f = cfopen(fname, mode)
    f !== nothing && return f
    if mode == b"wb" || mode == b"ab"
        # Try to create any missing directories in the path.
        ok = false
        tried = false
        for (i, c) in enumerate(fname)
            if c == UInt8('/')
                tried = true
                ok = _mkdir(fname[1:i-1])
            end
        end
        (tried && ok) && return cfopen(fname, mode)
    end
    nothing
end

"`wfdb_striphea(record)`: the record name without a trailing `.hea`."
function wfdb_striphea(record::ByteStr)
    r = cstr(bytes(record))
    (length(r) > 4 && r[end-3:end] == b".hea") ? r[1:end-4] : copy(r)
end

const _PKGROOT = dirname(@__DIR__)

"""
    run_sortann(record, annotator; dir=nothing) -> Int

Run `sortann --legacy -r. RECORD -a ANNOTATOR` to sort an annotation file
(used by `oannclose` in legacy mode), as the C library runs the `sortann`
program, in the directory `dir` if given (wfdb-x: the output directory,
where the file is; `--legacy` makes the child behave as the original
program): in a separate
Julia process (the same `julia` binary and project, `bin/wfdbx.jl
sortann`), after flushing the standard output. Returns its exit status (-1
if it could not be run). When the output is captured (`run_tool`, during
precompilation), `sortann` runs in-process with a fresh library state
instead, and its output is captured too.
"""
function run_sortann(record::ByteStr, annotator::ByteStr; dir::OptByteStr=nothing)
    rec = bstr(cstr(bytes(record)))
    ann = bstr(cstr(bytes(annotator)))
    args = String["--legacy", "-r.", rec, "-a", ann]
    wd = dir === nothing ? pwd() : bstr(cstr(bytes(dir)))
    cflush()
    p = cproc()
    if p.out_capture !== nothing
        isdefined(@__MODULE__, :sortann_main) || return -1
        out = p.out_capture
        err = p.err_capture
        st, o, e = run_tool("sortann", args; dir=wd)
        append!(out, o)
        err === nothing ? cerr_write(e) : append!(err, e)
        return Int(st)
    end
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(_PKGROOT) $(joinpath(_PKGROOT, "bin", "wfdbx.jl")) sortann $args`
    try
        pr = run(ignorestatus(Cmd(cmd; dir=wd)))
        return pr.exitcode == 0 && pr.termsignal != 0 ? -1 : Int(pr.exitcode)
    catch e
        e isa Base.IOError || rethrow()
        return -1
    end
end

"""
    wfdbversion() -> Vector{UInt8}

C `wfdbversion`: the version of the WFDB library implemented, `"10.7.0"`.
"""
wfdbversion() = Vector{UInt8}(b"10.7.0")
"""
    wfdbldflags() -> Vector{UInt8}

C `wfdbldflags`: the linker flags needed to use the C library. Empty, since
there are none in Julia.
"""
wfdbldflags() = UInt8[]
"""
    wfdbcflags() -> Vector{UInt8}

C `wfdbcflags`: the compiler flags needed to use the C library. Empty, since
there are none in Julia.
"""
wfdbcflags() = UInt8[]
"""
    wfdbdefwfdb() -> Vector{UInt8}

C `wfdbdefwfdb`: the default WFDB path ([`DEFWFDB`](@ref)), used when the
environment variable `WFDB` is not set.
"""
wfdbdefwfdb() = Vector{UInt8}(DEFWFDB)
"""
    wfdbdefwfdbcal() -> Vector{UInt8}

C `wfdbdefwfdbcal`: the default calibration file name, `"wfdbcal"`, used
when the environment variable `WFDBCAL` is not set.
"""
wfdbdefwfdbcal() = Vector{UInt8}(DEFWFDBCAL)
wfdbversion(w::Wfdb) = wfdbversion()

function _export_config(p::Vector{UInt8})
    csetenv("WFDB", p, true)
    csetenv("WFDBCAL", DEFWFDBCAL, false)
    csetenv("WFDBANNSORT", "1", false)
    csetenv("WFDBGVMODE", "0", false)
end

"Maximum nesting of indirect (`@FILE`) WFDB paths (C `getiwfdb`)."
const _MAX_INDIRECT_WFDB = 10

# If p begins with '@', read the WFDB path from the named file.
function _getiwfdb(w::Wfdb, p::Vector{UInt8})
    i = 0
    while i < _MAX_INDIRECT_WFDB && !isempty(p) && p[1] == UInt8('@')
        pf = cfopen(p[2:end], "rb")
        data = pf === nothing ? nothing : read_to_end(pf)
        pf === nothing || fclose(pf)
        if data === nothing
            p = UInt8[]
        else
            while !isempty(data) && (data[end] == UInt8('\r') || data[end] == UInt8('\n'))
                pop!(data)
            end
            p = data
        end
        i += 1
    end
    if !isempty(p) && p[1] == UInt8('@')
        wfdb_error(w, "getwfdb: files nested too deeply\n")
        p = UInt8[]
    end
    p
end

"""
    getwfdb([w]) -> Vector{UInt8}

C `getwfdb()`. wfdb-x: the input directory (see
[`wfdbx_set_input_dir`](@ref)), or `"."` if none is set: files are not
searched for. In legacy mode, the WFDB path, the list of places searched
for WFDB files (initialized from the `WFDB` environment variable, or
[`DEFWFDB`](@ref), on first use).
"""
function getwfdb(w::Wfdb)
    io = w.io
    if !_legacy(w)
        _init_input_dir!(w)
        return io.input_dir === nothing ? Vector{UInt8}(b".") : copy(io.input_dir)
    end
    if io.wfdbpath === nothing
        p = cgetenv("WFDB")
        p === nothing && (p = Vector{UInt8}(DEFWFDB))
        path = _getiwfdb(w, p)
        io.wfdbpath = copy(path)
        io.wfdbpath_init = copy(path)
        wfdb_parse_path(w, path)
    end
    copy(something(io.wfdbpath, UInt8[]))
end

"""
    setwfdb([w], path)

C `setwfdb(path)`. wfdb-x: set the input directory (a C-compatible form of
[`wfdbx_set_input_dir`](@ref)). `path` is split into components as the WFDB
path is (at spaces, semicolons, and colons other than in URLs); it must
contain at most one non-empty component, which becomes the input directory
(none, e.g. `""`, `";"` or `nothing`: the default). With more than one, an
error is reported (`setwfdb: wfdb-x reads from a single input directory;
...`) and nothing changes. [`resetwfdb`](@ref) restores the value set by the
last `setwfdb`.

In legacy mode, set the WFDB path as C does (`nothing`: from the
environment or the default), and export `WFDB` (and defaults of `WFDBCAL`,
`WFDBANNSORT`, `WFDBGVMODE`) to the environment.
"""
function setwfdb(w::Wfdb, p::OptByteStr)
    if !_legacy(w)
        _setwfdb_normal(w, p)
        return nothing
    end
    value = if p === nothing
        v = cgetenv("WFDB")
        v === nothing ? Vector{UInt8}(DEFWFDB) : v
    else
        copy(cstr(bytes(p)))
    end
    _export_config(value)
    path = _getiwfdb(w, value)
    w.io.wfdbpath = copy(path)
    wfdb_parse_path(w, path)
    nothing
end

"""
    resetwfdb([w])

C `resetwfdb()`. wfdb-x: restore the input directory set by the last
[`setwfdb`](@ref), if any ([`wfdbquit`](@ref) does not call it, except in
legacy mode). In legacy mode, restore the WFDB path to its initial value
(only if `getwfdb` was called before any `setwfdb`).
"""
function resetwfdb(w::Wfdb)
    if !_legacy(w)
        w.io.setwfdb_called && _put_input_dir!(w, w.io.setwfdb_input_dir)
        return nothing
    end
    init = w.io.wfdbpath_init
    init !== nothing && (w.io.wfdbpath = copy(init))
    nothing
end

"""
    wfdbquiet([w])

C `wfdbquiet()`: stop printing the library's error messages on the
standard error. The latest message is still available from
[`wfdberror`](@ref).
"""
wfdbquiet(w::Wfdb) = (w.io.error_print = false; nothing)
"""
    wfdbverbose([w])

C `wfdbverbose()`: print the library's error messages on the standard
error (the default; undoes [`wfdbquiet`](@ref)).
"""
wfdbverbose(w::Wfdb) = (w.io.error_print = true; nothing)

"""
    wfdberror([w]) -> Vector{UInt8}

C `wfdberror()`: the most recent error message (or, before any error, the
library version string).
"""
function wfdberror(w::Wfdb)
    io = w.io
    if !io.error_flag
        io.error_message = cformat("WFDB library version %d.%d.%d (%s).\n",
                                   WFDB_MAJOR, WFDB_MINOR, WFDB_RELEASE, WFDB_BUILD_DATE)
    end
    copy(io.error_message)
end

"""
    wfdb_error([w], fmt, args...)

C `wfdb_error(format, ...)`: format the message (see [`sprintf!`](@ref)),
record it as the latest error, and print it on the standard error unless
`wfdbquiet()` was called. (A message that is already formatted can be
recorded with [`wfdb_error_msg`](@ref).)
"""
function wfdb_error(w::Wfdb, fmt::ByteStr, args::Vararg{Any,N}) where {N}
    wfdb_error_msg(w, cformat(fmt, args...))
end

"Record (and print, unless quiet) an already formatted error message."
function wfdb_error_msg(w::Wfdb, msg::ByteStr)
    io = w.io
    io.error_flag = true
    io.error_message = Vector{UInt8}(copy(_bv(msg)))
    io.error_print && cerr_write(io.error_message)
    nothing
end

"""
    wfdbmemerr([w], behavior)

C `wfdbmemerr(behavior)`: set whether memory allocation errors are fatal.
The setting is stored (see `wfdb_me_fatal`) but has no other effect: in
Julia, allocation failures are thrown as `OutOfMemoryError`.
"""
wfdbmemerr(w::Wfdb, behavior::Integer) = (w.io.mem_behavior = Int32(behavior); nothing)
"C `wfdb_me_fatal()`."
wfdb_me_fatal(w::Wfdb) = w.io.mem_behavior

"The name of the file most recently opened by `wfdb_open` (C's `wfdb_filename`)."
wfdb_filename(w::Wfdb) = copy(w.io.filename)

# ---------------------------------------------------------------------------
# wfdb-x: the settings that locate files

_startswith(a::AbstractVector{UInt8}, p::AbstractVector{UInt8}) =
    length(a) >= length(p) && view(a, 1:length(p)) == p

# True if name is an http:// or https:// URL.
_is_url(name::AbstractVector{UInt8}) = _startswith(name, b"http://") || _startswith(name, b"https://")

# True if c is a directory separator ('/', and on Windows '\').
_is_dsep(c::UInt8) = c == UInt8('/') || (Sys.iswindows() && c == UInt8('\\'))

_dirarg(d::OptByteStr) = d === nothing ? UInt8[] : copy(cstr(bytes(d)))
_nonempty_env(name) = (v = cgetenv(name); (v === nothing || isempty(v)) ? nothing : v)

function _init_input_dir!(w::Wfdb)
    io = w.io
    if !io.input_dir_init
        io.input_dir_init = true
        io.env_input_dir = _nonempty_env("WFDBX_INPUT_DIR")
        io.input_dir = io.env_input_dir
    end
    if !io.wfdb_warned && !_legacy(w)
        io.wfdb_warned = true
        _nonempty_env("WFDB") === nothing ||
            wfdb_error(w, "wfdb-x: the WFDB environment variable is ignored; set WFDBX_INPUT_DIR instead (or use legacy mode)\n")
    end
    nothing
end

function _put_input_dir!(w::Wfdb, d::Union{Nothing,Vector{UInt8}})
    _init_input_dir!(w)
    w.io.input_dir = (d === nothing || isempty(d)) ? w.io.env_input_dir : copy(d)
    nothing
end

"""
    wfdbx_set_input_dir([w], dir) -> Union{Vector{UInt8},Nothing}

wfdb-x addition: set the input directory; return the previous one
(`nothing` if none). A file named by a relative name (a record name, an
annotation file, a file named on a command line, ...) is read as
`dir/NAME`. `dir` may be a local directory (relative to the current
directory, or a `~` name) or the URL of a directory (e.g.
`"https://physionet.org/files/mitdb/1.0.0/"`; see
[`wfdbx_set_network`](@ref)). Names given as absolute paths, `~` names or
URLs are used as given; nothing else is searched. `nothing` or `""`
restores the default: the value of the environment variable
`WFDBX_INPUT_DIR` if it is set, otherwise none (names are used as given,
relative to the current directory). The setting belongs to the library
state `w`; it is not reset by `wfdbquit`, and not used in legacy mode
(which searches the WFDB path).
"""
function wfdbx_set_input_dir(w::Wfdb, dir::OptByteStr)
    _init_input_dir!(w)
    previous = w.io.input_dir
    _put_input_dir!(w, _dirarg(dir))
    previous
end

"""
    wfdbx_get_input_dir([w]) -> Union{Vector{UInt8},Nothing}

wfdb-x addition: the input directory (see [`wfdbx_set_input_dir`](@ref)),
or `nothing`.
"""
function wfdbx_get_input_dir(w::Wfdb)
    _init_input_dir!(w)
    w.io.input_dir === nothing ? nothing : copy(w.io.input_dir)
end

const _OUTPUT_URL_ERROR = "wfdbx_set_output_dir: the output directory must be a local directory\n"

function _init_output_dir!(w::Wfdb)
    io = w.io
    io.output_dir_init && return nothing
    io.output_dir_init = true
    v = _nonempty_env("WFDBX_OUTPUT_DIR")
    if v !== nothing && _is_url(v)
        wfdb_error(w, _OUTPUT_URL_ERROR)
    else
        io.env_output_dir = v
        io.output_dir = v
    end
    nothing
end

"""
    wfdbx_set_output_dir([w], dir) -> Union{Vector{UInt8},Nothing}

wfdb-x addition: set the output directory; return the previous one
(`nothing` if none). Output files (`WFDB_WRITE` and `WFDB_APPEND` modes of
[`wfdb_open`](@ref)) named by a relative name (the record name and the file
type; the record name may itself contain directories) are created as
`dir/NAME` (in legacy mode, any name); `dir` may be relative to the current
directory or a `~` name. `nothing` or `""` restores the default: the value
of the environment variable `WFDBX_OUTPUT_DIR` if it is set, otherwise none
(files are created as named). A URL is refused: an error is reported
(`wfdbx_set_output_dir: the output directory must be a local directory`),
the setting is unchanged, and its current value is returned. The directory
is not checked: as for any output file, missing directories are created.
The setting belongs to the library state `w`, is not reset by `wfdbquit`,
and applies in legacy mode too. Header and signal file names recorded in
headers are not changed.
"""
function wfdbx_set_output_dir(w::Wfdb, dir::OptByteStr)
    _init_output_dir!(w)
    d = _dirarg(dir)
    if _is_url(d)
        wfdb_error(w, _OUTPUT_URL_ERROR)
        return wfdbx_get_output_dir(w)
    end
    previous = w.io.output_dir
    w.io.output_dir = isempty(d) ? w.io.env_output_dir : d
    previous
end

"""
    wfdbx_get_output_dir([w]) -> Union{Vector{UInt8},Nothing}

wfdb-x addition: the output directory (see [`wfdbx_set_output_dir`](@ref)),
or `nothing`.
"""
function wfdbx_get_output_dir(w::Wfdb)
    _init_output_dir!(w)
    w.io.output_dir === nothing ? nothing : copy(w.io.output_dir)
end

"""
    wfdbx_set_network([w], on) -> Int32

wfdb-x addition: allow (`on` true or > 0) or forbid (`on` false or 0)
network access, i.e., opening `http://` and `https://` URLs; return the
previous setting (1 or 0). `nothing` or a negative number restores the
default: allowed if the environment variable `WFDBX_NETWORK` is set to a
non-zero number, otherwise forbidden. Remote files are read in full (with
the Downloads standard library; redirects are followed, an HTTP status of
400 or more is a failure; it gives up if connecting takes 30 s or no data
arrives for 30 s, with no limit on the total time) and kept for the rest of the
process (each URL is requested at most once). Never in legacy mode, which
reads no remote files. The setting belongs to the library state `w`.
"""
function wfdbx_set_network(w::Wfdb, on::Union{Nothing,Bool,Integer})
    previous = wfdbx_get_network(w)
    w.io.network = (on === nothing || (!(on isa Bool) && on < 0)) ? Int8(w.io.env_network) :
                   Int8(on != 0)
    previous
end

"""
    wfdbx_get_network([w]) -> Int32

wfdb-x addition: 1 if network access is allowed (see
[`wfdbx_set_network`](@ref)), otherwise 0.
"""
function wfdbx_get_network(w::Wfdb)
    io = w.io
    if io.network < 0
        v = cgetenv("WFDBX_NETWORK")
        io.env_network = v !== nothing && strtol(v, 10)[1] != 0
        io.network = Int8(io.env_network)
    end
    Int32(io.network)
end

function _setwfdb_normal(w::Wfdb, p::OptByteStr)
    dirs = [c.prefix for c in _path_components(_dirarg(p)) if !isempty(c.prefix)]
    if length(dirs) > 1
        wfdb_error(w, "setwfdb: wfdb-x reads from a single input directory; use wfdbx_set_input_dir (or legacy mode for the WFDB search path)\n")
        return Int32(-1)
    end
    d = isempty(dirs) ? nothing : dirs[1]
    _put_input_dir!(w, d)
    w.io.setwfdb_input_dir = d
    w.io.setwfdb_called = true
    Int32(0)
end

# True if name is an absolute local path: one that begins with '/' (on
# Windows also 'X:\', 'X:/' or '\\').
function _is_absolute_path(name::AbstractVector{UInt8})
    if Sys.iswindows()
        bs = UInt8('\\')
        length(name) > 2 && UInt8('a') <= (name[1] | 0x20) <= UInt8('z') &&
            name[2] == UInt8(':') && (name[3] == bs || name[3] == UInt8('/')) && return true
        length(name) > 1 && name[1] == bs && name[2] == bs && return true
    end
    !isempty(name) && name[1] == UInt8('/')
end

# The home directory of a user (POSIX: the password database), or nothing.
function _user_home(user::Vector{UInt8})
    (Sys.iswindows() || 0x00 in user) && return nothing
    pw = ccall(:getpwnam, Ptr{Ptr{UInt8}}, (Cstring,), String(copy(user)))
    pw == C_NULL && return nothing
    # struct passwd, in pointer-sized words: pw_dir is the 5th (Linux: name,
    # passwd, uid and gid, gecos, dir), the 7th on BSD and macOS (which
    # have pw_change and pw_class before pw_gecos)
    dir = unsafe_load(pw, Sys.isbsd() ? 7 : 5)
    dir == C_NULL ? nothing : Vector{UInt8}(codeunits(unsafe_string(dir)))
end

# name with a leading "~" or "~/" replaced by the home directory ($HOME, or
# that of the current user if HOME is not set; on Windows %USERPROFILE%),
# and, on POSIX systems, "~user" by the home directory of that user
# (unchanged if there is no such user).
function _expand_home(name::Vector{UInt8})
    (isempty(name) || name[1] != UInt8('~')) && return name
    i = 2           # (the first separator, or the end)
    while i <= length(name) && !_is_dsep(name[i])
        i += 1
    end
    home = if i > 2
        _user_home(name[2:i-1])
    elseif Sys.iswindows()
        cgetenv("USERPROFILE")
    else
        h = cgetenv("HOME")
        h === nothing ? (try Vector{UInt8}(codeunits(Libc.getpwuid(Libc.getuid()).homedir))
                         catch; nothing; end) : h
    end
    home === nothing && return name
    home = copy(home)
    while !isempty(home) && _is_dsep(home[end])
        pop!(home)
    end
    r = UInt8[home; name[i:end]]
    isempty(r) ? UInt8[DSEP] : r
end

# d + sep + name, with exactly one separator ('/' in a URL).
function _join(d::Vector{UInt8}, name::Vector{UInt8}, sep::UInt8)
    _is_url(d) && (sep = UInt8('/'))
    (isempty(d) || d[end] == sep || _is_dsep(d[end])) && return UInt8[d; name]
    UInt8[d; sep; name]
end

# The location of the file named name (normal mode): an absolute name or a
# URL as given, a ~ name expanded, and a relative name under the input
# directory (for reading) or the output directory (for writing), if set.
function _resolve(w::Wfdb, name::Vector{UInt8}, output::Bool)
    !isempty(name) && name[1] == UInt8('~') && return _expand_home(name)
    (_is_absolute_path(name) || _is_url(name)) && return name
    if output
        _init_output_dir!(w)
        d = w.io.output_dir
    else
        _init_input_dir!(w)
        d = w.io.input_dir
    end
    d === nothing && return name
    _join(_expand_home(d), name, output ? DSEP : UInt8('/'))
end

# True if a file name found in a header names a file in the header's
# directory or below it: a relative name that does not begin with '~' and
# has no ".." component (on Windows, no drive letter either).
function _in_header_dir(name::Vector{UInt8})
    (_is_absolute_path(name) || _is_url(name) || (!isempty(name) && name[1] == UInt8('~'))) &&
        return false
    if Sys.iswindows()
        length(name) > 1 && name[2] == UInt8(':') && return false
        name = replace(name, UInt8('\\') => UInt8('/'))
    end
    i = 1           # (the start of the current component)
    for j in 1:length(name)+1
        if j > length(name) || name[j] == UInt8('/')
            j - i == 2 && name[i] == UInt8('.') && name[i+1] == UInt8('.') && return false
            i = j + 1
        end
    end
    true
end

# The directory part of a file name or URL, including its final separator
# ("" if it has none).
function wfdbx_dirname(name::Vector{UInt8})
    i = length(name)
    while i > 0 && !_is_dsep(name[i])
        i -= 1
    end
    name[1:i]
end

"""
    wfdb_open([w], type, record, mode) -> Union{WfdbFile,Nothing}

Open a WFDB file of type `type` for a record. `mode` is `WFDB_READ`,
`WFDB_WRITE` (create the file) or `WFDB_APPEND`. The file name is the
record name and the type, joined by a `.` (if `record` is empty or
`nothing`, `type` is the file name); `record` `"-"` is the standard input
or output. wfdb-x: a relative name is read under the input directory
([`wfdbx_set_input_dir`](@ref)) and written under the output directory
([`wfdbx_set_output_dir`](@ref)); an absolute name, a `~` name or a URL is
used as given (a URL can only be read, and only if network access is
allowed: [`wfdbx_set_network`](@ref)). Nothing is searched; at that one
location, the name with the type truncated to 3 characters is tried too.
In legacy mode, an input file is searched for in each directory of the WFDB
path (with `%r` in a path component replaced by the current record name,
`%Nr` by its first N characters), and an output file is created as named
(in the output directory, if one is set).
"""
function wfdb_open(w::Wfdb, s::OptByteStr, record::OptByteStr, mode::Integer)
    io = w.io
    sb = s === nothing ? UInt8[] : cstr(bytes(s))
    rb = record === nothing ? UInt8[] : cstr(bytes(record))
    if isempty(rb)
        isempty(sb) && return nothing
        rb, sb = sb, UInt8[]
    end
    if rb == b"-"
        return mode == WFDB_READ ? wfdb_stdin() : wfdb_stdout()
    end
    r = _expand_record(rb)

    if mode == WFDB_WRITE || mode == WFDB_APPEND
        io.filename = _spr1(r, sb)
        _init_output_dir!(w)
        if !_legacy(w)
            # wfdb-x: a relative name in the output directory, if one is
            # set; a URL cannot be written
            _is_url(io.filename) && return nothing
            io.filename = _resolve(w, io.filename, true)
        elseif io.output_dir !== nothing    # wfdb-x: legacy mode: any name
            io.filename = UInt8[io.output_dir; DSEP; io.filename]
        end
        return wfdb_fopen(w, io.filename, mode == WFDB_WRITE ? "wb" : "ab")
    end
    # wfdb-x: the one location that the name designates
    _legacy(w) || return _open_at(w, _resolve(w, r, false), sb)

    isempty(io.path_list) && getwfdb(w)
    plist = [PathComponent(copy(c.prefix), c.ptype) for c in io.path_list]
    for c in plist
        # Substitute the record name for %r (or its first N characters for
        # %Nr) in the path component.
        b = UInt8[]
        pr = c.prefix
        n = length(pr)
        i = 1
        while i <= n
            ch = pr[i]
            if ch == UInt8('%')
                i += 1
                ch = i <= n ? pr[i] : 0x00
                if ch == UInt8('r')
                    append!(b, io.irec)
                    i += 1
                elseif UInt8('1') <= ch <= UInt8('9') && i + 1 <= n && pr[i+1] == UInt8('r')
                    k = min(Int(ch - UInt8('0')), length(io.irec))
                    append!(b, @view io.irec[1:k])
                    i += 2
                else
                    ch != 0 && push!(b, ch)
                    i += 1
                end
            else
                push!(b, ch)
                i += 1
            end
        end
        c.ptype == WFDB_NET && continue     # remote files: not supported
        (!isempty(b) && b[end] != DSEP) && push!(b, DSEP)
        append!(b, r)
        io.filename = _spr1(b, sb)
        f = wfdb_fopen(w, io.filename, "rb")
        if f !== nothing
            wfdb_addtopath(w, io.filename)
            return f
        end
        long_filename = io.filename
        io.filename = _spr2(b, sb)
        if io.filename != long_filename
            f = wfdb_fopen(w, io.filename, "rb")
            if f !== nothing
                wfdb_addtopath(w, io.filename)
                return f
            end
        end
    end
    nothing
end

# If the record name ends with '/', append the last component of the
# directory name ("foo/bar/" becomes "foo/bar/bar"), as wfdb_open does.
function _expand_record(rb::Vector{UInt8})
    r = copy(rb)
    rlen = length(rb)
    if rlen > 1 && rb[rlen] == UInt8('/')
        p = rlen        # 1-based index of the final '/'
        q = p - 1
        while q > 1
            if rb[q] == UInt8('/')
                q += 1
                break
            end
            q -= 1
        end
        q < p && append!(r, @view rb[q:p-1])
    end
    r
end

# wfdb-x: the name of the local file that wfdb_open(name, nothing,
# WFDB_WRITE) creates in normal mode, or nothing if it creates none (the
# standard output, or a URL).
function wfdbx_output_file(w::Wfdb, name::OptByteStr)
    n = name === nothing ? UInt8[] : cstr(bytes(name))
    (isempty(n) || n == b"-") && return nothing
    r = _expand_record(n)
    _is_url(r) ? nothing : _resolve(w, r, true)
end

# Open the file at location p for reading, trying both forms of its name
# (_spr1 and _spr2) there (wfdb-x).
function _open_at(w::Wfdb, p::Vector{UInt8}, s::Vector{UInt8})
    io = w.io
    io.filename = _spr1(p, s)
    f = wfdb_fopen(w, io.filename, "rb")
    f !== nothing && return f
    long_filename = io.filename
    io.filename = _spr2(p, s)
    io.filename != long_filename && return wfdb_fopen(w, io.filename, "rb")
    nothing
end

# Open, for reading, a file named in the header of a record (a signal file,
# or a segment of type s): name, in the directory d of that header (as
# given by wfdbx_dirname; nothing if unknown, for a header read from the
# standard input: name is then resolved as any relative name). The name must
# be in that directory or below it; the signal file name "-" (the standard
# input) is also accepted (wfdb-x).
function wfdbx_open_in(w::Wfdb, d::Union{Nothing,Vector{UInt8}}, s::OptByteStr,
                       name::Vector{UInt8}, record::Vector{UInt8})
    name == b"-" && return wfdb_open(w, s, name, WFDB_READ)
    if !_in_header_dir(name)
        wfdb_error(w, "init: file %s named in the header of record %s is not in the header's directory\n",
                   name, record)
        return nothing
    end
    d === nothing && return wfdb_open(w, s, name, WFDB_READ)
    _open_at(w, UInt8[d; name], s === nothing ? UInt8[] : cstr(bytes(s)))
end

# wfdb-x: remote files. The Downloads standard library is loaded only when
# a URL is first read (it takes a while to load).
const _DOWNLOADS = Base.PkgId(Base.UUID("f43a241f-c20a-4ad4-852c-f6b1247861c6"), "Downloads")
const NET_TIMEOUT = 30      # seconds to connect, or without receiving data
const _DOWNLOADER = Ref{Any}(nothing)

# The downloader used for remote files: it gives up if connecting takes
# NET_TIMEOUT seconds or no data arrives for NET_TIMEOUT seconds, with no
# limit on the total time (record files can be large), as wfdb-x's other
# implementations do.
function _downloader(downloads)
    _DOWNLOADER[] === nothing || return _DOWNLOADER[]
    curl = downloads.Curl
    dl = downloads.Downloader()
    dl.easy_hook = (easy, info) -> begin
        curl.setopt(easy, curl.CURLOPT_CONNECTTIMEOUT, NET_TIMEOUT)
        curl.setopt(easy, curl.CURLOPT_LOW_SPEED_LIMIT, 1)
        curl.setopt(easy, curl.CURLOPT_LOW_SPEED_TIME, NET_TIMEOUT)
    end
    _DOWNLOADER[] = dl
end

# The contents of a URL (read once per library state; failures are
# remembered too), or nothing.
function _fetch(w::Wfdb, url::Vector{UInt8})
    haskey(w.io.fetched, url) && return w.io.fetched[url]
    data = try
        downloads = Base.require(_DOWNLOADS)
        buf = IOBuffer()
        dl = Base.invokelatest(_downloader, downloads)
        Base.invokelatest(downloads.download, String(copy(url)), buf; timeout=Inf,
                          downloader=dl,
                          headers=["User-Agent" => "wfdb-x/" * String(wfdbversion())])
        take!(buf)
    catch e
        e isa InterruptException && rethrow()
        nothing
    end
    w.io.fetched[copy(url)] = data
    data
end

# Open a remote file for reading (normal mode), if network access is
# allowed; the first time it is not, print a message.
function _fetch_open(w::Wfdb, url::Vector{UInt8})
    if wfdbx_get_network(w) == 0
        if !w.io.network_warned
            w.io.network_warned = true
            wfdb_error(w, "wfdb-x: network access is disabled; set WFDBX_NETWORK=1 or call wfdbx_set_network(1) to open %s\n",
                       url)
        end
        return nothing
    end
    data = _fetch(w, url)
    data === nothing && return nothing
    f = wfdb_memfile(data)
    f.remote = true
    f
end

"""
    wfdb_checkname([w], name, description) -> Int32

0 if `name` contains only letters, digits, `_`, `~`, `-` and `/`;
otherwise prints `init: illegal character N in DESCRIPTION name` and
returns -1.
"""
function wfdb_checkname(w::Wfdb, name::ByteStr, desc::ByteStr)
    nm = cstr(bytes(name))
    i = 1
    while true
        c = i <= length(nm) ? nm[i] : 0x00
        if c_isalnum(c) || c == UInt8('_') || c == UInt8('~') || c == UInt8('-') || c == DSEP
            i += 1
        else
            wfdb_error(w, "init: illegal character %d in %s name\n", reinterpret(Int8, c), desc)
            return Int32(-1)
        end
        i > length(nm) && return Int32(0)
    end
end

"""
    wfdb_setirec([w], record)

Set the current record name (its last path component, at most
`WFDB_MAXRNL` bytes), used for `%r` in the WFDB path. `"-"` is ignored.
"""
function wfdb_setirec(w::Wfdb, p::ByteStr)
    pb = cstr(bytes(p))
    k = findlast(==(DSEP), pb)
    r = k === nothing ? pb : pb[k+1:end]
    if r != b"-"
        w.io.irec = r[1:min(length(r), WFDB_MAXRNL)]
    end
    nothing
end

"`wfdb_getirec()`: the current record name (`nothing` if not set)."
wfdb_getirec(w::Wfdb) = isempty(w.io.irec) ? nothing : copy(w.io.irec)

"""
    wfdb_parse_path([w], path)

Split a WFDB path into its components (separated by `;`, spaces, tabs or
newlines; `:` also separates local components, but not the `://` of URLs).
"""
function wfdb_parse_path(w::Wfdb, p::OptByteStr)
    pl = w.io.path_list
    empty!(pl)
    p === nothing && return Int32(0)
    append!(pl, _path_components(cstr(bytes(p))))
    Int32(0)
end

# The components of a WFDB path string (wfdb-x: also used by setwfdb in
# normal mode).
function _path_components(s::AbstractVector{UInt8})
    pl = PathComponent[]
    n = length(s)
    q = 1
    while q <= n
        while q <= n && s[q] in b" \t\n\r"
            q += 1
        end
        start = q
        ptype = WFDB_LOCAL
        slashes = 0
        while true
            c = q <= n ? s[q] : 0x00
            if c == UInt8(':')
                if q + 2 <= n && s[q+1] == UInt8('/') && s[q+2] == UInt8('/')
                    ptype = WFDB_NET
                elseif ptype != WFDB_NET || slashes > 2
                    break
                end
            elseif c in b"; \t\n\r" || c == 0x00
                break
            elseif c == UInt8('/')
                slashes += 1
            end
            q += 1
        end
        push!(pl, PathComponent(s[start:q-1], ptype))
        q <= n && (q += 1)
    end
    pl
end

"""
    wfdb_addtopath([w], pathname)

Move (or add) the directory of `pathname` to the front of the WFDB path
(after `.`, if `.` is first), so that other files of the same record are
found quickly (used in legacy mode only).
"""
function wfdb_addtopath(w::Wfdb, s0::ByteStr)
    s = cstr(bytes(s0))
    isempty(s) && return nothing
    issep(c) = c == UInt8('/') || c == UInt8('\\') || c == UInt8(':')
    p = length(s)       # 1-based; p == 0: none
    while p >= 1 && !issep(s[p])
        p -= 1
    end
    # C: p is a 0-based index; here plen = number of prefix bytes = p - 1.
    p == 0 && return nothing
    plen = p - 1
    (plen == 0 && issep(s[1])) && (plen = 1)
    w.io.wfdbpath === nothing && getwfdb(w)
    plist = w.io.path_list
    isempty(plist) && return nothing
    found = nothing
    for idx in 1:length(plist)
        pre = plist[idx].prefix
        if length(pre) >= plen && view(pre, 1:plen) == view(s, 1:plen)
            (idx == 1 || (idx == 2 && plist[1].prefix == b".")) && return nothing
            found = plist[idx]
            deleteat!(plist, idx)
            break
        end
    end
    c = if found === nothing
        prefix = s[1:plen]
        PathComponent(prefix, _contains(prefix, b"://") ? WFDB_NET : WFDB_LOCAL)
    else
        found
    end
    if plist[1].prefix == b"."
        insert!(plist, 2, c)
    else
        pushfirst!(plist, c)
    end
    nothing
end

"""
    wfdbfile([w], type, record) -> Union{Vector{UInt8},Nothing}

C `wfdbfile(type, record)`: the pathname (or URL) of a WFDB file (found as
[`wfdb_open`](@ref) finds it: wfdb-x: under the input directory, for a
relative name; in legacy mode, in the WFDB path), or `nothing`. With both arguments `nothing`,
the name of the file most recently opened.
"""
function wfdbfile(w::Wfdb, s::OptByteStr, record::OptByteStr)
    (s === nothing && record === nothing) && return copy(w.io.filename)
    rec = record === nothing ? nothing : wfdb_striphea(record)
    f = wfdb_open(w, s, rec, WFDB_READ)
    f === nothing && return nothing
    fclose(f)
    copy(w.io.filename)
end

# ---------------------------------------------------------------------------
# The same functions on the default instance.

getwfdb() = getwfdb(lib())
setwfdb(p::OptByteStr) = setwfdb(lib(), p)
resetwfdb() = resetwfdb(lib())
wfdbquiet() = wfdbquiet(lib())
wfdbverbose() = wfdbverbose(lib())
wfdberror() = wfdberror(lib())
wfdb_error(fmt::ByteStr, args::Vararg{Any,N}) where {N} = wfdb_error(lib(), fmt, args...)
wfdb_error_msg(msg::ByteStr) = wfdb_error_msg(lib(), msg)
wfdbmemerr(behavior::Integer) = wfdbmemerr(lib(), behavior)
wfdb_me_fatal() = wfdb_me_fatal(lib())
wfdb_filename() = wfdb_filename(lib())
wfdb_open(s::OptByteStr, record::OptByteStr, mode::Integer) = wfdb_open(lib(), s, record, mode)
wfdb_checkname(name::ByteStr, desc::ByteStr) = wfdb_checkname(lib(), name, desc)
wfdb_setirec(p::ByteStr) = wfdb_setirec(lib(), p)
wfdb_getirec() = wfdb_getirec(lib())
wfdb_parse_path(p::OptByteStr) = wfdb_parse_path(lib(), p)
wfdb_addtopath(s::ByteStr) = wfdb_addtopath(lib(), s)
wfdbfile(s::OptByteStr, record::OptByteStr) = wfdbfile(lib(), s, record)
wfdb_fopen(fname::ByteStr, mode::ByteStr) = wfdb_fopen(lib(), fname, mode)
wfdbx_set_input_dir(dir::OptByteStr) = wfdbx_set_input_dir(lib(), dir)
wfdbx_get_input_dir() = wfdbx_get_input_dir(lib())
wfdbx_set_output_dir(dir::OptByteStr) = wfdbx_set_output_dir(lib(), dir)
wfdbx_get_output_dir() = wfdbx_get_output_dir(lib())
wfdbx_set_network(on::Union{Nothing,Bool,Integer}) = wfdbx_set_network(lib(), on)
wfdbx_get_network() = wfdbx_get_network(lib())

export wfdbx_set_input_dir, wfdbx_get_input_dir, wfdbx_set_output_dir, wfdbx_get_output_dir,
       wfdbx_set_network, wfdbx_get_network

# ---------------------------------------------------------------------------
# Precompilation workload: file I/O and the WFDB path.

register_workload("wfdbio") do
    mktempdir() do dir
        cd(dir) do
            w = Wfdb()
            wfdbquiet(w)
            setwfdb(w, dir)
            f = wfdb_open(w, "txt", "sub/rec", WFDB_WRITE)
            if f !== nothing
                cfprintf(f, "%s %d %g\n", "rec", Int32(2), 360.0)
                fwrite(f, b"line 2\r\n")
                wfdb_p16(f, 0x1234); wfdb_p32(f, -2); putc(f, 0x41)
                ftell(f); fflush(f); fclose(f)
            end
            f = wfdb_open(w, "txt", "sub/rec", WFDB_APPEND)
            f === nothing || (fwrite(f, "x"); fclose(f))
            f = wfdb_open(w, "txt", "sub/rec", WFDB_READ)
            if f !== nothing
                line = UInt8[]
                getline!(f, line); fgets!(f, line, 4); getc(f); ungetc(f, 0x41)
                wfdb_g16(f); wfdb_g32(f); fread!(f, zeros(UInt8, 4), 1, 4); fread!(f, zeros(UInt8, 4))
                fseek(f, 0, SEEK_SET); fseek(f, 2, SEEK_CUR); fseek(f, -1, SEEK_END)
                ftell(f); feof(f); ferror(f); clearerr(f); read_to_end(f); fclose(f)
            end
            wfdbfile(w, "txt", "sub/rec"); wfdbfile(w, "hea", "nosuch"); wfdbfile(w, nothing, nothing)
            wfdb_checkname(w, "rec", "record"); wfdb_checkname(w, "r.c", "record")
            wfdb_setirec(w, "sub/rec"); wfdb_getirec(w); wfdb_addtopath(w, "sub/rec.txt")
            wfdb_error(w, "x %s %d\n", "y", 1); wfdberror(w); getwfdb(w); resetwfdb(w)
            m = wfdb_memfile(b"ab\ncd"); getc(m); fclose(m)
            wfdb_fopen("nosuch/x", "rb"); cfopen("nosuch", "rb")
            # wfdb-x: the settings that locate files (no network access)
            wfdbx_set_input_dir(w, "~/x"); wfdbx_get_input_dir(w); wfdbfile(w, "hea", "r")
            wfdbx_set_input_dir(w, nothing); wfdbfile(w, "hea", "~nosuchuser/r")
            wfdbx_set_output_dir(w, "out"); wfdbx_get_output_dir(w); wfdbx_set_output_dir(w, nothing)
            wfdbx_set_network(w, false); wfdbx_get_network(w); wfdbfile(w, "hea", "http://127.0.0.1/r")
            wfdbx_set_network(w, nothing); setwfdb(w, "a b"); setwfdb(w, ";"); resetwfdb(w)
            _in_header_dir(Vector{UInt8}("a/../b")); wfdbx_dirname(Vector{UInt8}("a/b"))
        end
    end
end
