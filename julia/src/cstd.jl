# cstd.jl: C standard library emulation.
#
# The WFDB library and tools depend on the exact behavior of a few C library
# functions on the reference platform (x86-64 Linux, glibc). This file
# reproduces them:
#
# * printf formatting, glibc-exact for every Float64 (`cformat`, `sprintf!`,
#   `cprintf`, `ceprintf`; `cfprintf` for a `WfdbFile` is in wfdbio.jl);
# * parsing: `strtol`, `strtoul`, `strtod`, `strtof`, `atoi`, `atol`, `atof`,
#   `csscanf`, `Strtok`/`strtok`, `fgets_lines`;
# * glibc's `rand` (`GlibcRand`, `csrand`, `crand`);
# * C conversions (`d2i`, `d2l`, `cdiv`, `cmod`) and character classes
#   (`c_isspace`, `c_isdigit`, ...);
# * the process's standard streams and environment: the buffered standard
#   output (`cout_write`, `cputchar`, `cflush`), the unbuffered standard error
#   (`cerr_write`), `cexit`, `prog_name`, `cgetenv`, `csetenv`.
#
# Strings are byte strings (`Vector{UInt8}`): WFDB files are not UTF-8.
#
# Julia implementation part of wfdb-x, Reza Sameni, Oct 2026.
# GNU Library General Public License, version 2 or later (see LICENSE.LIB).

# ===========================================================================
# Basics

"C's `EOF`."
const EOF = Int32(-1)
const INT_MAX = typemax(Int32)
const INT_MIN = typemin(Int32)
const LONG_MAX = typemax(Int64)
const LONG_MIN = typemin(Int64)
"`fseek` origins."
const SEEK_SET = Int32(0)
const SEEK_CUR = Int32(1)
const SEEK_END = Int32(2)

"A byte-string argument: a `String` (its code units) or a byte vector."
const ByteStr = Union{AbstractString,AbstractVector{UInt8}}
"A byte-string argument that may be C's `NULL` (`nothing`)."
const OptByteStr = Union{Nothing,AbstractString,AbstractVector{UInt8}}

"""
    bytes(s) -> Vector{UInt8}

The bytes of a string argument (`s` itself if it is a `Vector{UInt8}`, else
a copy). `bytes(nothing)` is `nothing`.
"""
bytes(s::Vector{UInt8}) = s
bytes(s::AbstractVector{UInt8}) = Vector{UInt8}(s)
bytes(s::AbstractString) = Vector{UInt8}(codeunits(String(s)))
bytes(::Nothing) = nothing

# Indexable bytes of an argument without copying (for parsers).
@inline _bv(s::AbstractVector{UInt8}) = s
@inline _bv(s::String) = codeunits(s)
@inline _bv(s::AbstractString) = codeunits(String(s))

"""
    cstr(s) -> Vector{UInt8}

The C string held in `s`: the bytes before its first NUL (`s` itself, not a
copy, if it contains no NUL and is a `Vector{UInt8}`).
"""
function cstr(s::Vector{UInt8})
    z = findfirst(iszero, s)
    z === nothing ? s : s[1:z-1]
end
cstr(s::ByteStr) = cstr(bytes(s))
cstr(::Nothing) = nothing

"Convert bytes to a `String` (no validation: the bytes are kept as they are)."
bstr(s::AbstractVector{UInt8}) = String(copy(s))
bstr(s::AbstractString) = String(s)

# ASCII letters differ from their capital only by this bit.
const _ASCII_CASE_BIT = 0x20

"C `isspace` in the C locale (space, `\\t`, `\\n`, `\\v`, `\\f`, `\\r`)."
@inline c_isspace(c::Integer) = c == UInt8(' ') || (UInt8('\t') <= c <= UInt8('\r'))
"C `isdigit`."
@inline c_isdigit(c::Integer) = UInt8('0') <= c <= UInt8('9')
"C `isxdigit`."
@inline c_isxdigit(c::Integer) = c_isdigit(c) || (UInt8('a') <= (c | _ASCII_CASE_BIT) <= UInt8('f'))
"C `isupper` (C locale)."
@inline c_isupper(c::Integer) = UInt8('A') <= c <= UInt8('Z')
"C `islower` (C locale)."
@inline c_islower(c::Integer) = UInt8('a') <= c <= UInt8('z')
"C `isalpha` (C locale)."
@inline c_isalpha(c::Integer) = c_isupper(c) || c_islower(c)
"C `isalnum` (C locale)."
@inline c_isalnum(c::Integer) = c_isalpha(c) || c_isdigit(c)
"C `isprint` (C locale)."
@inline c_isprint(c::Integer) = UInt8(' ') <= c <= UInt8('~')
"C `toupper` (C locale)."
@inline c_toupper(c::T) where {T<:Integer} = c_islower(c) ? T(c - _ASCII_CASE_BIT) : c
"C `tolower` (C locale)."
@inline c_tolower(c::T) where {T<:Integer} = c_isupper(c) ? T(c + _ASCII_CASE_BIT) : c

"""
    d2i(x::Float64) -> Int32

C conversion of a `double` to `int` on x86 (`cvttsd2si`): truncation toward
zero; NaN and out-of-range values give `typemin(Int32)`.
"""
@inline d2i(x::Real) = (x > -2147483649.0 && x < 2147483648.0) ?
                       unsafe_trunc(Int32, Float64(x)) : typemin(Int32)

"""
    d2l(x::Float64) -> Int64

C conversion of a `double` to a 64-bit `long` on x86: truncation toward
zero; NaN and out-of-range values give `typemin(Int64)`.
"""
@inline d2l(x::Real) = (x >= -9223372036854775808.0 && x < 9223372036854775808.0) ?
                       unsafe_trunc(Int64, Float64(x)) : typemin(Int64)

"C integer division (truncation toward zero; wraps on `MIN / -1`)."
@inline cdiv(a::T, b::T) where {T<:Integer} = b == -1 ? -a : div(a, b)
@inline cdiv(a::Integer, b::Integer) = cdiv(promote(a, b)...)
"C remainder (the sign follows the dividend)."
@inline cmod(a::T, b::T) where {T<:Integer} = b == -1 ? zero(T) : rem(a, b)
@inline cmod(a::Integer, b::Integer) = cmod(promote(a, b)...)

# ===========================================================================
# printf: arguments

const ARG_NONE = 0x00   # missing argument
const ARG_INT = 0x01
const ARG_UINT = 0x02
const ARG_FLOAT = 0x03
const ARG_STR = 0x04
const ARG_NULL = 0x05   # NULL string

const _EMPTY = UInt8[]

"""
    CArg

One argument of a printf-style call (see [`carg`](@ref)). Integer conversions
accept integers (and floats, converted as a C cast would); floating-point
conversions accept floats (and integers, converted to `Float64`); `%s` takes
a string (`nothing` is C's `NULL`, printed as `(null)`); `%c` takes an
integer (or the first byte of a string).
"""
struct CArg
    kind::UInt8
    i::Int64        # integer value (bits of an unsigned value)
    f::Float64
    s::Union{Vector{UInt8},String}
end

const _NOARG = CArg(ARG_NONE, 0, 0.0, _EMPTY)

"Convert a Julia value to a printf argument ([`CArg`](@ref))."
@inline carg(x::CArg) = x
@inline carg(x::Bool) = CArg(ARG_INT, Int64(x), 0.0, _EMPTY)
@inline carg(x::Union{Int8,Int16,Int32,Int64,UInt8}) = CArg(ARG_INT, Int64(x), 0.0, _EMPTY)
@inline carg(x::Union{UInt16,UInt32,UInt64}) = CArg(ARG_UINT, reinterpret(Int64, UInt64(x)), 0.0, _EMPTY)
@inline carg(x::Signed) = CArg(ARG_INT, x % Int64, 0.0, _EMPTY)
@inline carg(x::Unsigned) = CArg(ARG_UINT, reinterpret(Int64, x % UInt64), 0.0, _EMPTY)
@inline carg(x::AbstractChar) = CArg(ARG_INT, Int64(UInt32(Char(x)) & 0xff), 0.0, _EMPTY)
@inline carg(x::AbstractFloat) = CArg(ARG_FLOAT, 0, Float64(x), _EMPTY)
@inline carg(x::Vector{UInt8}) = CArg(ARG_STR, 0, 0.0, x)
@inline carg(x::AbstractVector{UInt8}) = CArg(ARG_STR, 0, 0.0, Vector{UInt8}(x))
@inline carg(x::String) = CArg(ARG_STR, 0, 0.0, x)
@inline carg(x::AbstractString) = CArg(ARG_STR, 0, 0.0, String(x))
@inline carg(::Nothing) = CArg(ARG_NULL, 0, 0.0, _EMPTY)

# Argument list of the current call (printf is not reentrant: the argument
# values are all converted before the formatting starts).
const _ARGV = CArg[]

# (The arguments are converted by one unrolled expression: with a recursive
# definition, inference gives up on argument lists that repeat a type, e.g.
# three byte vectors, and the remaining calls are compiled at run time.)
@inline function _pushargs!(v::Vector{CArg}, args::Vararg{Any,N}) where {N}
    conv = ntuple(i -> carg(args[i]), Val(N))
    for c in conv
        push!(v, c)
    end
    v
end

@inline _fmtbytes(fmt::AbstractVector{UInt8}) = fmt
@inline _fmtbytes(fmt::String) = codeunits(fmt)
@inline _fmtbytes(fmt::AbstractString) = codeunits(String(fmt))

# ===========================================================================
# printf: exact binary-to-decimal conversion of Float64 values
#
# glibc formats a double from its exact binary value, rounding to the
# requested number of digits with round-half-even on the exact value. A fast
# path computes the rounded digits with 128-bit integer arithmetic when the
# scaled value fits; a slow path expands the exact decimal value with BigInt.
# Both are exact. The digits are left in the scratch buffer `_K`.

# IEEE 754 binary64: 52 stored fraction bits (53-bit significand), 11-bit
# biased exponent; a subnormal is frac * 2^-1074.
const _F64_FRAC_BITS = 52
const _F64_EXP_MASK = 0x7ff
const _F64_EXP_BIAS = 1023
const _F64_MIN_NORMAL_EXP = -1022
const _F64_SUBNORMAL_EXP = -1074

"Largest `k` with 10^k representable in a `UInt128`."
const _MAX_POW10_U128 = 38
const _POW10 = UInt128[UInt128(10)^i for i in 0:_MAX_POW10_U128]   # _POW10[i+1] = 10^i
const _K = Vector{UInt8}(undef, 64)     # digit scratch buffer
const _B = UInt8[]                      # float body scratch buffer
const _IB = Vector{UInt8}(undef, 64)    # integer/char body scratch buffer

const _RB = Int8(-1)   # remainder below half
const _RH = Int8(0)    # exactly half
const _RA = Int8(1)    # above half

# |x| == m * 2^e exactly, m < 2^53 (x finite).
@inline function _f64_parts(x::Float64)
    bits = reinterpret(UInt64, x)
    bexp = Int((bits >> _F64_FRAC_BITS) & _F64_EXP_MASK)
    frac = bits & ((UInt64(1) << _F64_FRAC_BITS) - 1)
    bexp == 0 ? (frac, _F64_SUBNORMAL_EXP) :
        (frac | (UInt64(1) << _F64_FRAC_BITS), bexp - _F64_EXP_BIAS - _F64_FRAC_BITS)
end

# x == m * 2^e exactly, m odd (x finite, > 0).
@inline function _decompose(x::Float64)
    m, e = _f64_parts(x)
    tz = trailing_zeros(m)
    (m >> tz, e + tz)
end

# floor(m * 2^e * 10^s) and the position of the remainder, if it fits in
# 128 bits: (ok, q, rem).
function _scaled(m::UInt64, e::Int, s::Int)
    fail = (false, zero(UInt128), _RB)
    num = UInt128(m)
    if s > 0
        s > _MAX_POW10_U128 && return fail
        num, of = Base.Checked.mul_with_overflow(num, _POW10[s+1])
        of && return fail
    end
    if e >= 0
        leading_zeros(num) <= e && return fail
        num <<= e
    end
    if s >= 0
        e >= 0 && return (true, num, _RB)
        k = -e
        if k >= 128
            if k == 128
                half = UInt128(1) << 127
                return (true, zero(UInt128), num < half ? _RB : num == half ? _RH : _RA)
            end
            return (true, zero(UInt128), _RB)
        end
        q = num >> k
        r = num & ((UInt128(1) << k) - UInt128(1))
        half = UInt128(1) << (k - 1)
        return (true, q, r < half ? _RB : r == half ? _RH : _RA)
    end
    t = -s
    t > _MAX_POW10_U128 && return fail
    den = _POW10[t+1]
    if e < 0
        k = -e
        (k >= 127 || leading_zeros(den) <= k + 1) && return fail
        den <<= k
    end
    den >> 126 != 0 && return fail
    q = div(num, den)
    r2 = (num - q * den) << 1
    (true, q, r2 < den ? _RB : r2 == den ? _RH : _RA)
end

@inline _round_q(q::UInt128, rem::Int8) =
    rem == _RB ? q : rem == _RA ? q + UInt128(1) : q + (q & UInt128(1))

# Decimal digits of q (> 0) into _K[1:n]; returns n.
function _qdigits!(q::UInt128)
    n = 0
    if q <= typemax(UInt64)
        v = UInt64(q)
        while v != 0
            n += 1
            n > length(_K) && resize!(_K, 2n)
            d, r = divrem(v, UInt64(10))
            @inbounds _K[n] = UInt8(0x30 + r)
            v = d
        end
    else
        v = q
        while v != 0
            n += 1
            n > length(_K) && resize!(_K, 2n)
            d, r = divrem(v, UInt128(10))
            @inbounds _K[n] = UInt8(0x30 + r)
            v = d
        end
    end
    reverse!(_K, 1, n)
    n
end

# Exact decimal expansion of m * 2^e: (digits, point), value 0.d * 10^point.
function _exact_digits(m::UInt64, e::Int)
    b = BigInt(m)
    if e >= 0
        b <<= e
        d = Vector{UInt8}(string(b))
        return (d, length(d))
    else
        k = -e
        b *= big(5)^k
        d = Vector{UInt8}(string(b))
        return (d, length(d) - k)
    end
end

# Round digits d (value 0.d * 10^point) to n digits, ties to even.
function _round_digits(d::Vector{UInt8}, point::Int, n::Int)
    len = length(d)
    if n >= len
        k = copy(d)
        append!(k, fill(UInt8('0'), n - len))
        return (k, point)
    end
    n < 0 && return (UInt8[], point)
    kept = d[1:n]
    first = d[n+1]
    rest_nonzero = any(c -> c != UInt8('0'), @view d[n+2:end])
    last_odd = n > 0 && isodd(kept[n] - UInt8('0'))
    up = first > UInt8('5') || (first == UInt8('5') && (rest_nonzero || last_odd))
    up || return (kept, point)
    i = n
    while i > 0
        if kept[i] == UInt8('9')
            kept[i] = UInt8('0')
            i -= 1
        else
            kept[i] += 0x01
            return (kept, point)
        end
    end
    pushfirst!(kept, UInt8('1'))
    n > 0 && pop!(kept)
    (kept, point + 1)
end

function _set_k!(k::Vector{UInt8})
    length(_K) < length(k) && resize!(_K, length(k))
    copyto!(_K, 1, k, 1, length(k))
    length(k)
end

# Digits of |x| rounded to prec digits after the point (%f): (klen, point),
# value 0.K[1:klen] * 10^point; klen == 0 if the rounded value is zero.
function _digits_fixed(x::Float64, prec::Int)
    x = abs(x)
    x == 0.0 && return (0, 0)
    m, e = _decompose(x)
    if prec <= 38
        ok, q, rem = _scaled(m, e, prec)
        if ok
            q = _round_q(q, rem)
            q == 0 && return (0, 0)
            n = _qdigits!(q)
            return (n, n - prec)
        end
    end
    _fixed_slow(m, e, prec)
end

function _fixed_slow(m::UInt64, e::Int, prec::Int)
    d, point = _exact_digits(m, e)
    k, p = _round_digits(d, point, point + prec)
    all(c -> c == UInt8('0'), k) && return (0, 0)
    want = p + prec
    if length(k) < want
        append!(k, fill(UInt8('0'), want - length(k)))
    end
    (_set_k!(k), p)
end

# Digits of |x| rounded to nsig >= 1 significant digits (%e): (nsig, exp,
# carried), value K[1].K[2:nsig] * 10^exp; carried: rounding carried into a
# new decimal exponent.
function _digits_exp(x::Float64, nsig::Int)
    x = abs(x)
    if x == 0.0
        length(_K) < nsig && resize!(_K, nsig)
        fill!(view(_K, 1:nsig), UInt8('0'))
        return (nsig, 0, false)
    end
    m, e = _decompose(x)
    if nsig <= 36
        lo = _POW10[nsig]
        hi = _POW10[nsig+1]
        ex = floor(Int, log10(x))
        for _ in 1:4
            s = (nsig - 1) - ex
            ok, q, rem = _scaled(m, e, s)
            ok || break
            if q < lo
                ex -= 1
                continue
            end
            if q >= hi
                ex += 1
                continue
            end
            q = _round_q(q, rem)
            carried = q == hi
            if carried
                q = lo
                ex += 1
            end
            n = _qdigits!(q)
            return (n, ex, carried)
        end
    end
    d, point = _exact_digits(m, e)
    k, p = _round_digits(d, point, nsig)
    (_set_k!(k), p - 1, p != point)
end

# Slow-path versions (for testing that the fast paths agree): return copies.
function _slow_digits_fixed(x::Float64, prec::Int)
    x = abs(x)
    x == 0.0 && return (UInt8[], 0)
    m, e = _decompose(x)
    n, p = _fixed_slow(m, e, prec)
    (_K[1:n], p)
end
function _slow_digits_exp(x::Float64, nsig::Int)
    x = abs(x)
    x == 0.0 && return (fill(UInt8('0'), nsig), 0)
    m, e = _decompose(x)
    d, point = _exact_digits(m, e)
    k, p = _round_digits(d, point, nsig)
    (k, p - 1)
end
function _fast_digits_fixed(x::Float64, prec::Int)
    n, p = _digits_fixed(x, prec)
    (_K[1:n], p)
end
function _fast_digits_exp(x::Float64, nsig::Int)
    n, ex, _ = _digits_exp(x, nsig)
    (_K[1:n], ex)
end

# ===========================================================================
# printf: formatting

struct _Spec
    left::Bool
    plus::Bool
    space::Bool
    alt::Bool
    zero::Bool
    width::Int
    prec::Int       # -1: none
end

const _LEN_NONE = 0
const _LEN_H = 1
const _LEN_HH = 2
const _LEN_L = 3    # l, ll, L, q, j, z, t: 64 bits

@inline function _append!(out::Vector{UInt8}, src::AbstractVector{UInt8}, a::Int, b::Int)
    b < a && return out
    n0 = length(out)
    resize!(out, n0 + b - a + 1)
    @inbounds for j in a:b
        out[n0+j-a+1] = src[j]
    end
    out
end

@inline function _fill!(out::Vector{UInt8}, c::UInt8, n::Int)
    n <= 0 && return out
    n0 = length(out)
    resize!(out, n0 + n)
    @inbounds for j in n0+1:n0+n
        out[j] = c
    end
    out
end

# Write prefix (np bytes p1, p2) + body[1:nb] into out, padded to the field
# width; zero_ok: zero padding allowed (inserted after the prefix).
function _pad!(out::Vector{UInt8}, sp::_Spec, np::Int, p1::UInt8, p2::UInt8,
               body::AbstractVector{UInt8}, nb::Int, zero_ok::Bool)
    len = np + nb
    fill = sp.width - len
    if fill > 0 && !sp.left && !(sp.zero && zero_ok)
        _fill!(out, 0x20, fill)
    end
    np >= 1 && push!(out, p1)
    np >= 2 && push!(out, p2)
    if fill > 0 && !sp.left && sp.zero && zero_ok
        _fill!(out, UInt8('0'), fill)
    end
    _append!(out, body, 1, nb)
    if fill > 0 && sp.left
        _fill!(out, 0x20, fill)
    end
    out
end

@inline function _arg_i32(a::CArg)
    if a.kind == ARG_INT || a.kind == ARG_UINT
        return a.i % Int32
    elseif a.kind == ARG_FLOAT
        return d2i(a.f)
    end
    Int32(0)
end

# Signed value of an integer argument, as C would read it.
@inline function _arg_signed(a::CArg, len::Int)
    raw = if a.kind == ARG_INT || a.kind == ARG_UINT
        a.i
    elseif a.kind == ARG_FLOAT
        len == _LEN_L ? d2l(a.f) : Int64(d2i(a.f))
    elseif a.kind == ARG_STR
        _sfirst(a.s)
    else
        Int64(0)
    end
    len == _LEN_NONE ? Int64(raw % Int32) :
    len == _LEN_H ? Int64(raw % Int16) :
    len == _LEN_HH ? Int64(raw % Int8) : raw
end

@inline function _arg_unsigned(a::CArg, len::Int)
    raw = reinterpret(UInt64, _arg_signed(a, _LEN_L))
    if a.kind == ARG_FLOAT && len != _LEN_L
        raw = reinterpret(UInt64, Int64(d2i(a.f)))
    end
    len == _LEN_NONE ? UInt64(raw % UInt32) :
    len == _LEN_H ? UInt64(raw % UInt16) :
    len == _LEN_HH ? UInt64(raw % UInt8) : raw
end

@inline function _arg_f64(a::CArg)
    a.kind == ARG_FLOAT && return a.f
    a.kind == ARG_INT && return Float64(a.i)
    a.kind == ARG_UINT && return Float64(reinterpret(UInt64, a.i))
    0.0
end

const _LDIGITS = b"0123456789abcdef"
const _UDIGITS = b"0123456789ABCDEF"

function _fmt_int!(out::Vector{UInt8}, sp::_Spec, conv::UInt8, a::CArg, len::Int)
    signed = conv == UInt8('d') || conv == UInt8('i')
    if signed
        v = _arg_signed(a, len)
        neg = v < 0
        mag = neg ? (UInt64(0) - reinterpret(UInt64, v)) : reinterpret(UInt64, v)
    else
        neg = false
        mag = _arg_unsigned(a, len)
    end
    base = (conv == UInt8('x') || conv == UInt8('X')) ? UInt64(16) :
           conv == UInt8('o') ? UInt64(8) : UInt64(10)
    digs = conv == UInt8('X') ? _UDIGITS : _LDIGITS
    # Body: precision zeros + digits, built in _IB.
    B = _IB
    nd = 0
    v = mag
    while v != 0
        nd += 1
        d, r = divrem(v, base)
        @inbounds B[nd] = digs[r+1]
        v = d
    end
    if mag == 0 && sp.prec != 0
        nd += 1
        @inbounds B[nd] = UInt8('0')
    end
    nz = sp.prec > nd ? sp.prec - nd : 0
    # Octal '#': the first digit must be 0.
    if conv == UInt8('o') && sp.alt && nz == 0 && !(nd > 0 && B[nd] == UInt8('0'))
        nz = 1
    end
    nb = nz + nd
    nb > length(B) && resize!(B, nb + 8)
    # digits are reversed in B[1:nd]: move them to the end, then the zeros.
    reverse!(B, 1, nd)
    if nz > 0
        copyto!(B, nz + 1, B, 1, nd)
        @inbounds for j in 1:nz
            B[j] = UInt8('0')
        end
    end
    np = 0
    p1 = p2 = 0x00
    if signed
        if neg
            np, p1 = 1, UInt8('-')
        elseif sp.plus
            np, p1 = 1, UInt8('+')
        elseif sp.space
            np, p1 = 1, UInt8(' ')
        end
    elseif sp.alt && mag != 0 && (conv == UInt8('x') || conv == UInt8('X'))
        np, p1, p2 = 2, UInt8('0'), conv
    end
    _pad!(out, sp, np, p1, p2, B, nb, sp.prec < 0)
end

# Fixed notation body: digits _K[1:klen] (value 0.K * 10^point), prec digits
# after the point.
function _fixed_body!(B::Vector{UInt8}, klen::Int, point::Int, prec::Int, alt::Bool)
    if point > 0
        if klen >= point
            _append!(B, _K, 1, point)
        else
            _append!(B, _K, 1, klen)
            _fill!(B, UInt8('0'), point - klen)
        end
    else
        push!(B, UInt8('0'))
    end
    (prec > 0 || alt) && push!(B, UInt8('.'))
    # Fraction digits: positions point+1 .. point+prec of K (1-based).
    i = 0
    while i < prec
        idx = point + i     # 0-based index into K
        if idx < 0
            # leading zeros
            nzer = min(-idx, prec - i)
            _fill!(B, UInt8('0'), nzer)
            i += nzer
        elseif idx < klen
            nk = min(klen - idx, prec - i)
            _append!(B, _K, idx + 1, idx + nk)
            i += nk
        else
            _fill!(B, UInt8('0'), prec - i)
            i = prec
        end
    end
    B
end

function _exp_body!(B::Vector{UInt8}, klen::Int, ex::Int, alt::Bool, strip::Bool, upper::Bool)
    push!(B, _K[1])
    fe = klen
    if strip
        while fe >= 2 && _K[fe] == UInt8('0')
            fe -= 1
        end
    end
    if fe >= 2 || alt
        push!(B, UInt8('.'))
        _append!(B, _K, 2, fe)
    end
    push!(B, upper ? UInt8('E') : UInt8('e'))
    push!(B, ex < 0 ? UInt8('-') : UInt8('+'))
    a = abs(ex)
    a < 10 && push!(B, UInt8('0'))
    if a >= 100
        push!(B, UInt8('0' + div(a, 100)))
        a = rem(a, 100)
        push!(B, UInt8('0' + div(a, 10)))
        push!(B, UInt8('0' + rem(a, 10)))
    elseif a >= 10
        push!(B, UInt8('0' + div(a, 10)))
        push!(B, UInt8('0' + rem(a, 10)))
    else
        push!(B, UInt8('0' + a))
    end
    B
end

function _strip_zeros!(B::Vector{UInt8})
    if UInt8('.') in B
        while !isempty(B) && B[end] == UInt8('0')
            pop!(B)
        end
        !isempty(B) && B[end] == UInt8('.') && pop!(B)
    end
    B
end

function _fmt_float!(out::Vector{UInt8}, sp::_Spec, conv::UInt8, x::Float64)
    upper = UInt8('A') <= conv <= UInt8('Z')
    np = 1
    p1 = if signbit(x)
        UInt8('-')
    elseif sp.plus
        UInt8('+')
    elseif sp.space
        UInt8(' ')
    else
        np = 0
        0x00
    end
    if !isfinite(x)
        body = isnan(x) ? (upper ? b"NAN" : b"nan") : (upper ? b"INF" : b"inf")
        return _pad!(out, sp, np, p1, 0x00, body, 3, false)
    end
    prec = sp.prec < 0 ? 6 : sp.prec
    B = _B
    empty!(B)
    if conv == UInt8('f') || conv == UInt8('F')
        klen, point = _digits_fixed(x, prec)
        _fixed_body!(B, klen, point, prec, sp.alt)
    elseif conv == UInt8('e') || conv == UInt8('E')
        klen, ex, _ = _digits_exp(x, prec + 1)
        _exp_body!(B, klen, ex, sp.alt, false, upper)
    else
        # %g, %G
        p = prec == 0 ? 1 : prec
        klen, xexp, carried = _digits_exp(x, p)
        if carried && xexp == p
            # glibc chose fixed notation from the unrounded exponent (p - 1),
            # with no fraction digits; when rounding carries into exponent p
            # it switches to exponential notation but keeps zero fraction
            # digits: "%#g" of 999999.5 is "1.e+06", not "1.00000e+06".
            _exp_body!(B, 1, xexp, sp.alt, true, upper)
        elseif xexp < p && xexp >= -4
            _fixed_body!(B, klen, xexp + 1, p - 1 - xexp, sp.alt)
            sp.alt || _strip_zeros!(B)
        else
            _exp_body!(B, klen, xexp, sp.alt, !sp.alt, upper)
        end
    end
    _pad!(out, sp, np, p1, 0x00, B, length(B), true)
end

const _NULLSTR = b"(null)"

@inline _sfirst(s::Vector{UInt8}) = isempty(s) ? Int64(0) : Int64(s[1])
@inline _sfirst(s::String) = ncodeunits(s) == 0 ? Int64(0) : Int64(codeunit(s, 1))

# %s: a C string ends at its first NUL; the precision limits its length.
function _fmt_str!(out::Vector{UInt8}, sp::_Spec, s::AbstractVector{UInt8}, prec::Int)
    n = length(s)
    lim = (prec >= 0 && prec < n) ? prec : n
    sl = lim
    @inbounds for j in 1:lim
        if s[j] == 0x00
            sl = j - 1
            break
        end
    end
    _pad!(out, sp, 0, 0x00, 0x00, s, sl, false)
end

# The core: format fmt with args[1:nargs], appending to out; returns the
# number of bytes appended.
function _sprintf!(out::Vector{UInt8}, fmt::AbstractVector{UInt8}, args::Vector{CArg})
    start = length(out)
    n = length(fmt)
    nargs = length(args)
    i = 1
    ai = 1
    @inbounds while i <= n
        lit = i
        while i <= n && fmt[i] != UInt8('%')
            i += 1
        end
        i > lit && _append!(out, fmt, lit, i - 1)
        i > n && break
        spec_start = i
        i += 1
        left = plus = space = alt = zero = false
        while i <= n
            c = fmt[i]
            if c == UInt8('-')
                left = true
            elseif c == UInt8('+')
                plus = true
            elseif c == UInt8(' ')
                space = true
            elseif c == UInt8('#')
                alt = true
            elseif c == UInt8('0')
                zero = true
            elseif c == UInt8('\'') || c == UInt8('I')
            else
                break
            end
            i += 1
        end
        width = 0
        if i <= n && fmt[i] == UInt8('*')
            w = _arg_i32(ai <= nargs ? args[ai] : _NOARG)
            ai += 1
            w < 0 && (left = true)
            width = Int(abs(Int64(w)))
            i += 1
        else
            while i <= n && c_isdigit(fmt[i])
                width = min(width * 10 + Int(fmt[i] - UInt8('0')), typemax(Int32))
                i += 1
            end
        end
        prec = -1
        if i <= n && fmt[i] == UInt8('.')
            i += 1
            if i <= n && fmt[i] == UInt8('*')
                p = _arg_i32(ai <= nargs ? args[ai] : _NOARG)
                ai += 1
                prec = p < 0 ? -1 : Int(p)
                i += 1
            else
                p = 0
                while i <= n && c_isdigit(fmt[i])
                    p = min(p * 10 + Int(fmt[i] - UInt8('0')), typemax(Int32))
                    i += 1
                end
                prec = p
            end
        end
        len = _LEN_NONE
        while i <= n
            c = fmt[i]
            if c == UInt8('h')
                len = len == _LEN_H ? _LEN_HH : _LEN_H
            elseif c == UInt8('l') || c == UInt8('L') || c == UInt8('q') ||
                   c == UInt8('j') || c == UInt8('z') || c == UInt8('t')
                len = _LEN_L
            else
                break
            end
            i += 1
        end
        if i > n
            _append!(out, fmt, spec_start, n)
            break
        end
        conv = fmt[i]
        i += 1
        sp = _Spec(left, plus, space, alt, zero, width, prec)
        if conv == UInt8('d') || conv == UInt8('i') || conv == UInt8('u') ||
           conv == UInt8('x') || conv == UInt8('X') || conv == UInt8('o')
            a = ai <= nargs ? args[ai] : _NOARG
            ai += 1
            _fmt_int!(out, sp, conv, a, len)
        elseif conv == UInt8('e') || conv == UInt8('E') || conv == UInt8('f') ||
               conv == UInt8('F') || conv == UInt8('g') || conv == UInt8('G')
            a = ai <= nargs ? args[ai] : _NOARG
            ai += 1
            _fmt_float!(out, sp, conv, _arg_f64(a))
        elseif conv == UInt8('c')
            a = ai <= nargs ? args[ai] : _NOARG
            ai += 1
            ch = if a.kind == ARG_STR
                _sfirst(a.s) % UInt8
            else
                _arg_signed(a, _LEN_L) % UInt8
            end
            _IB[1] = ch
            _pad!(out, sp, 0, 0x00, 0x00, _IB, 1, false)
        elseif conv == UInt8('s')
            a = ai <= nargs ? args[ai] : _NOARG
            ai += 1
            if a.kind == ARG_STR
                sv = a.s
                if sv isa String
                    _fmt_str!(out, sp, codeunits(sv), prec)
                else
                    _fmt_str!(out, sp, sv, prec)
                end
            else
                sl = (prec >= 0 && prec < 6) ? 0 : 6
                _pad!(out, sp, 0, 0x00, 0x00, _NULLSTR, sl, false)
            end
        elseif conv == UInt8('%')
            push!(out, UInt8('%'))
        else
            _append!(out, fmt, spec_start, i - 1)
        end
    end
    length(out) - start
end

# The printf-like functions (here and `cfprintf`, `wfdb_error` in wfdbio.jl)
# take `args::Vararg{Any,N} where {N}`: this forces Julia to specialize them
# on the argument types. With a plain `args...`, a call that repeats a type
# (e.g. two `Int32`s) is compiled for a generic `Vararg` signature and
# formats through a run-time dispatch, i.e. it is compiled at run time.

"""
    sprintf!(out::Vector{UInt8}, fmt, args...) -> Int

Format the C format string `fmt` (a `String` or bytes) with `args` as glibc's
`sprintf` does, appending the result to `out`. Returns the number of bytes
appended. Arguments are converted with [`carg`](@ref): integers, floats, byte
strings, `String`s, `nothing` (C's `NULL`). As in C, `%d` prints the low 32
bits of its argument (`%ld` all 64), `%hd`/`%hhd` 16/8 bits, `%u`/`%x` the
unsigned value. Supported: the conversions `d i u x X o c s e E f F g G %`,
the flags `- + space # 0`, field width and precision (also `*`), and the
length modifiers `hh h l ll L q j z t`. Missing arguments are taken as 0 (or
`NULL` for `%s`); unknown conversions are copied to the output unchanged.

`sprintf!(out, fmt, args::Vector{CArg})` takes an argument list built at run
time.
"""
@inline function sprintf!(out::Vector{UInt8}, fmt::ByteStr, args::Vararg{Any,N}) where {N}
    v = _ARGV
    empty!(v)
    _pushargs!(v, args...)
    _sprintf!(out, _fmtbytes(fmt), v)
end
function sprintf!(out::Vector{UInt8}, fmt::ByteStr, args::Vector{CArg})
    _sprintf!(out, _fmtbytes(fmt), args)
end

"""
    cformat(fmt, args...) -> Vector{UInt8}

C `sprintf`: return the bytes of the C format string `fmt` formatted with
`args`, exactly as glibc's `sprintf` formats them (see
[`sprintf!`](@ref) for the supported conversions and arguments).

# Examples
```julia-repl
julia> String(WFDBX.cformat("%5d|%-4s|%.3f", 42, "ab", 2.0005))
"   42|ab  |2.001"
```
"""
@inline function cformat(fmt::ByteStr, args::Vararg{Any,N}) where {N}
    out = Vector{UInt8}(undef, 0)
    sizehint!(out, length(fmt) + 16)
    sprintf!(out, fmt, args...)
    out
end

"`cformat` returning a `String` (for messages and tests)."
cformat_str(fmt, args::Vararg{Any,N}) where {N} = String(cformat(fmt, args...))

# ===========================================================================
# Parsing: strtol, strtoul, strtod, atoi, atof
#
# Positions: a function that returns (value, n) returns the number n of
# bytes consumed (0 when C's endptr would equal the start of the string: no
# conversion). To parse from an offset, pass a view (`@view s[pos:end]`).

# The value of a digit in bases up to 36 (letters are 10 to 35), or a value
# larger than any base.
@inline function _digit_value(c::UInt8)
    c_isdigit(c) && return Int(c - UInt8('0'))
    c_islower(c) && return Int(c - UInt8('a')) + 10
    c_isupper(c) && return Int(c - UInt8('A')) + 10
    99
end

# Common part of strtol/strtoul: (negative, magnitude, overflowed, end).
function _strto_int(s::AbstractVector{UInt8}, base::Integer)
    n = length(s)
    i = 1
    @inbounds while i <= n && c_isspace(s[i])
        i += 1
    end
    neg = false
    if i <= n && (s[i] == UInt8('+') || s[i] == UInt8('-'))
        neg = s[i] == UInt8('-')
        i += 1
    end
    b = Int(base)
    hexpre(i) = i + 2 <= n && s[i] == UInt8('0') && (s[i+1] | _ASCII_CASE_BIT) == UInt8('x') && c_isxdigit(s[i+2])
    if b == 0
        if hexpre(i)
            b = 16
            i += 2
        elseif i <= n && s[i] == UInt8('0')
            b = 8
        else
            b = 10
        end
    elseif b == 16 && hexpre(i)
        i += 2
    end
    (2 <= b <= 36) || return (false, UInt64(0), false, 0)
    start = i
    v = UInt64(0)
    ovf = false
    @inbounds while i <= n
        d = _digit_value(s[i])
        d >= b && break
        v1, o1 = Base.Checked.mul_with_overflow(v, UInt64(b))
        v2, o2 = Base.Checked.add_with_overflow(v1, UInt64(d))
        if o1 || o2
            ovf = true
        else
            v = v2
        end
        i += 1
    end
    i == start && return (false, UInt64(0), false, 0)
    (neg, v, ovf, i - 1)
end

"""
    strtol(s, base=10) -> (value::Int64, n::Int)

C `strtol` (64-bit `long`): `n` is the number of bytes consumed (0 if no
conversion). Out-of-range values are clamped to `typemin`/`typemax(Int64)`.
"""
function strtol(s::ByteStr, base::Integer=10)
    neg, v, ovf, e = _strto_int(_bv(s), base)
    e == 0 && return (Int64(0), 0)
    val = if neg
        (ovf || v > (UInt64(1) << 63)) ? typemin(Int64) : -reinterpret(Int64, v)
    else
        (ovf || v > UInt64(typemax(Int64))) ? typemax(Int64) : reinterpret(Int64, v)
    end
    (val, e)
end

"C `strtoll` (same as [`strtol`](@ref) on the reference platform)."
strtoll(s::ByteStr, base::Integer=10) = strtol(s, base)

"""
    strtoul(s, base=10) -> (value::UInt64, n::Int)

C `strtoul` (64-bit): negative values wrap, out-of-range values give
`typemax(UInt64)`.
"""
function strtoul(s::ByteStr, base::Integer=10)
    neg, v, ovf, e = _strto_int(_bv(s), base)
    e == 0 && return (UInt64(0), 0)
    ovf && return (typemax(UInt64), e)
    (neg ? UInt64(0) - v : v, e)
end

"C `atoi`: `(int) strtol(s, NULL, 10)` (truncated to 32 bits, as glibc)."
atoi(s::ByteStr) = strtol(s, 10)[1] % Int32
"C `atol`."
atol(s::ByteStr) = strtol(s, 10)[1]
"C `atof`: `strtod(s, NULL)`."
atof(s::ByteStr) = strtod(s)[1]

@inline _lower(c::UInt8) = c | _ASCII_CASE_BIT

function _match_ci(s::AbstractVector{UInt8}, i::Int, word::AbstractVector{UInt8})
    length(s) - i + 1 >= length(word) || return false
    @inbounds for k in 1:length(word)
        _lower(s[i+k-1]) == word[k] || return false
    end
    true
end

# 2^n, for n in _F64_SUBNORMAL_EXP:_F64_EXP_BIAS.
@inline function _pow2(n::Int)
    n >= _F64_MIN_NORMAL_EXP ? reinterpret(Float64, UInt64(n + _F64_EXP_BIAS) << _F64_FRAC_BITS) :
    reinterpret(Float64, UInt64(1) << (n - _F64_SUBNORMAL_EXP))
end

# x * 2^n (in two steps where 2^n is not a finite double).
function _ldexp(x::Float64, n::Int)
    if n < _F64_MIN_NORMAL_EXP
        x * _pow2(_F64_MIN_NORMAL_EXP) * _pow2(n - _F64_MIN_NORMAL_EXP)
    elseif n > _F64_EXP_BIAS
        x * _pow2(_F64_EXP_BIAS) * _pow2(n - _F64_EXP_BIAS)
    else
        x * _pow2(n)
    end
end

# Correctly rounded value of a hexadecimal significand times 2^exp2.
function _hex_value(mant::UInt64, sticky::Bool, exp2::Int64)
    mant == 0 && return 0.0
    lz = leading_zeros(mant)
    m = mant << lz
    e = exp2 - lz + 63                  # value = 1.xxx * 2^e
    e > _F64_EXP_BIAS && return Inf
    sig = _F64_FRAC_BITS + 1            # significand bits kept
    keep = e >= _F64_MIN_NORMAL_EXP ? sig : sig - (_F64_MIN_NORMAL_EXP - e)
    if keep <= 0
        if keep == 0
            half = m == (UInt64(1) << 63) && !sticky
            return half ? 0.0 : _pow2(_F64_SUBNORMAL_EXP)
        end
        return 0.0
    end
    shift = 64 - keep
    kept = m >> shift
    dropped = m & ((UInt64(1) << shift) - 1)
    half = UInt64(1) << (shift - 1)
    if dropped > half || (dropped == half && (sticky || isodd(kept)))
        kept += 1
    end
    _ldexp(Float64(kept), Int(e - keep + 1))
end

function _parse_hex(s::AbstractVector{UInt8}, j::Int)
    n = length(s)
    mant = UInt64(0)
    sticky = false
    exp2 = Int64(0)
    seen_point = false
    while true
        if j <= n && c_isxdigit(s[j])
            d = UInt64(_digit_value(s[j]))
            if mant >> 60 == 0
                mant = (mant << 4) | d
                seen_point && (exp2 -= 4)
            else
                d != 0 && (sticky = true)
                seen_point || (exp2 += 4)
            end
            j += 1
        elseif j <= n && s[j] == UInt8('.') && !seen_point
            seen_point = true
            j += 1
        else
            break
        end
    end
    if j <= n && _lower(s[j]) == UInt8('p')
        k = j + 1
        eneg = false
        if k <= n && (s[k] == UInt8('+') || s[k] == UInt8('-'))
            eneg = s[k] == UInt8('-')
            k += 1
        end
        if k <= n && c_isdigit(s[k])
            ev = Int64(0)
            while k <= n && c_isdigit(s[k])
                # (clamped: any larger exponent overflows or underflows)
                ev = min(ev * 10 + (s[k] - UInt8('0')), Int64(1_000_000_000))
                k += 1
            end
            exp2 += eneg ? -ev : ev
            j = k
        end
    end
    (_hex_value(mant, sticky, exp2), j)   # j: index after the number
end

# Correctly rounded value of a decimal mantissa (digits and an optional
# point) s[a:b] and an exponent part s[c:d] (`e[+-]digits`, or empty).
function _parse_decimal(::Type{T}, s::AbstractVector{UInt8}, a::Int, b::Int, c::Int, d::Int) where {T}
    t = Vector{UInt8}(undef, 0)
    sizehint!(t, b - a + 26)
    _append!(t, s, a, b)
    if d >= c
        k = c + 1
        eneg = false
        if s[k] == UInt8('-')
            eneg = true
            k += 1
        elseif s[k] == UInt8('+')
            k += 1
        end
        ev = Int64(0)
        # Clamp the exponent: beyond 10^5 plus the number of digits, the
        # value is 0 or Inf whatever the digits.
        for q in k:d
            ev = min(ev * 10 + (s[q] - UInt8('0')), Int64(1_000_000_000_000))
        end
        ev = min(ev, Int64(100_000 + (b - a + 1)))
        push!(t, UInt8('e'))
        eneg && push!(t, UInt8('-'))
        append!(t, codeunits(string(ev)))
    end
    str = String(t)
    v = tryparse(T, str)
    v === nothing || return v
    # Out of range (the C library returns +-HUGE_VAL or 0 with ERANGE, which
    # Julia reports as a failure): decide which with an exact BigFloat.
    big = tryparse(BigFloat, str)
    (big !== nothing && abs(big) > 1) ? T(Inf) : zero(T)
end

function _strtod(::Type{T}, s::AbstractVector{UInt8}) where {T}
    n = length(s)
    i = 1
    while i <= n && c_isspace(s[i])
        i += 1
    end
    neg = false
    if i <= n && (s[i] == UInt8('+') || s[i] == UInt8('-'))
        neg = s[i] == UInt8('-')
        i += 1
    end
    sgn(v) = neg ? -v : v
    # Hexadecimal
    if i + 1 <= n && s[i] == UInt8('0') && _lower(s[i+1]) == UInt8('x')
        j = i + 2
        has = (j <= n && c_isxdigit(s[j])) ||
              (j + 1 <= n && s[j] == UInt8('.') && c_isxdigit(s[j+1]))
        if has
            v, e = _parse_hex(s, j)
            return (sgn(T(v)), e - 1)
        end
        return (sgn(zero(T)), i)
    end
    # Decimal
    start = i
    j = i
    ndig = 0
    while j <= n && c_isdigit(s[j])
        j += 1
        ndig += 1
    end
    if j <= n && s[j] == UInt8('.')
        j += 1
        while j <= n && c_isdigit(s[j])
            j += 1
            ndig += 1
        end
    end
    if ndig > 0
        mant_end = j - 1
        if j <= n && _lower(s[j]) == UInt8('e')
            k = j + 1
            if k <= n && (s[k] == UInt8('+') || s[k] == UInt8('-'))
                k += 1
            end
            if k <= n && c_isdigit(s[k])
                while k <= n && c_isdigit(s[k])
                    k += 1
                end
                j = k
            end
        end
        v = _parse_decimal(T, s, start, mant_end, mant_end + 1, j - 1)
        return (sgn(v), j - 1)
    end
    if _match_ci(s, i, b"inf")
        e = _match_ci(s, i, b"infinity") ? i + 7 : i + 2
        return (sgn(T(Inf)), e)
    end
    if _match_ci(s, i, b"nan")
        e = i + 2
        if e + 1 <= n && s[e+1] == UInt8('(')
            k = e + 2
            while k <= n && (c_isalnum(s[k]) || s[k] == UInt8('_'))
                k += 1
            end
            if k <= n && s[k] == UInt8(')')
                e = k
            end
        end
        return (sgn(T(NaN)), e)
    end
    (zero(T), 0)
end

"""
    strtod(s) -> (value::Float64, n::Int)

C `strtod` as glibc implements it (correctly rounded decimal and
hexadecimal input, `inf`, `infinity`, `nan`, `nan(...)`): `n` is the number
of bytes consumed (0 if no conversion).
"""
strtod(s::ByteStr) = _strtod(Float64, _bv(s))

"""
    strtof(s) -> (value::Float32, n::Int)

C `strtof` (decimal input is rounded once, directly to `Float32`, as glibc
does; hexadecimal input is rounded through `Float64`).
"""
strtof(s::ByteStr) = _strtod(Float32, _bv(s))

# ===========================================================================
# sscanf

# Results of a scan: one entry per assigned conversion (and %n), applied to
# the destinations in order after the scan.
const _SC_INT = 0x01
const _SC_FLOAT = 0x02
const _SC_BYTES = 0x03

mutable struct _ScanResults
    kind::Vector{UInt8}
    ival::Vector{Int64}
    a::Vector{Int}      # byte range in the input (float text, bytes)
    b::Vector{Int}
    tmp::Vector{UInt8}
end
const _SCAN = _ScanResults(UInt8[], Int64[], Int[], Int[], UInt8[])

@inline function _scan_push!(r::_ScanResults, kind::UInt8, v::Int64, a::Int, b::Int)
    push!(r.kind, kind)
    push!(r.ival, v)
    push!(r.a, a)
    push!(r.b, b)
end

# Integer field input[i:lim]: (ok, value, next index).
function _scan_int(r::_ScanResults, s::AbstractVector{UInt8}, i::Int, lim::Int, base::Int, unsigned::Bool)
    t = r.tmp
    empty!(t)
    if i <= lim && (s[i] == UInt8('+') || s[i] == UInt8('-'))
        push!(t, s[i])
        i += 1
    end
    got = false
    if (base == 0 || base == 16) && i <= lim && s[i] == UInt8('0')
        push!(t, UInt8('0'))
        i += 1
        got = true
        if i <= lim && _lower(s[i]) == UInt8('x')
            i += 1
            base = 16
        elseif base == 0
            base = 8
        end
    end
    base == 0 && (base = 10)
    while i <= lim && _digit_value(s[i]) < base
        push!(t, s[i])
        i += 1
        got = true
    end
    got || return (false, Int64(0), i)
    v = unsigned ? reinterpret(Int64, strtoul(t, base)[1]) : strtol(t, base)[1]
    (true, v, i)
end

# Float field input[i:lim]: (ok, end of the text (inclusive)).
function _scan_float(s::AbstractVector{UInt8}, i::Int, lim::Int, width_end::Bool)
    st = i
    if i <= lim && (s[i] == UInt8('+') || s[i] == UInt8('-'))
        i += 1
    end
    fld = @view s[1:lim]
    if _match_ci(fld, i, b"nan")
        return (true, i + 2)
    end
    if i <= lim && _lower(s[i]) == UInt8('i')
        _match_ci(fld, i, b"inf") || return (false, 0)
        i += 3
        if i <= lim && _lower(s[i]) == UInt8('i')
            _match_ci(fld, i, b"inity") || return (false, 0)
            i += 5
        end
        return (true, i - 1)
    end
    hex = false
    ndig = 0
    if i + 1 <= lim && s[i] == UInt8('0') && _lower(s[i+1]) == UInt8('x')
        if width_end && i + 1 == lim
            return (true, i)    # the width ends at the 'x': the number is "0"
        end
        hex = true
        i += 2
    end
    isdig(c) = hex ? c_isxdigit(c) : c_isdigit(c)
    while i <= lim && isdig(s[i])
        i += 1
        ndig += 1
    end
    if i <= lim && s[i] == UInt8('.')
        i += 1
        hex && (ndig += 1)    # "0x." is accepted (as 0), "0x" alone is not
        while i <= lim && isdig(s[i])
            i += 1
            ndig += 1
        end
    end
    ndig == 0 && return (false, 0)
    expc = hex ? UInt8('p') : UInt8('e')
    if i <= lim && _lower(s[i]) == expc
        i += 1
        if i <= lim && (s[i] == UInt8('+') || s[i] == UInt8('-'))
            i += 1
        end
        while i <= lim && c_isdigit(s[i])
            i += 1
        end
    end
    (true, i - 1)
end

# Build the table of a scan set (the bytes between `[`/`[^` and the closing
# `]`), as glibc does: a leading `]` or `-` is literal; `a-b` is a range when
# `a <= b` (and `-` is not last); otherwise `-` is literal.
function _build_scanset!(tab::Vector{Bool}, set::AbstractVector{UInt8})
    fill!(tab, false)
    ns = length(set)
    k = 1
    if ns >= 1 && (set[1] == UInt8(']') || set[1] == UInt8('-'))
        tab[set[1]+1] = true
        k = 2
    end
    while k <= ns
        c = set[k]
        if c == UInt8('-') && k + 1 <= ns && k >= 2 && set[k-1] <= set[k+1]
            for x in set[k-1]:(set[k+1]-0x01)
                tab[x+1] = true
            end
        else
            tab[c+1] = true
        end
        k += 1
    end
    tab
end
const _SCANSET = fill(false, 256)

# The scan itself: fills r, returns the C return value.
function _sscanf_core!(r::_ScanResults, input::AbstractVector{UInt8}, fmt::AbstractVector{UInt8})
    empty!(r.kind); empty!(r.ival); empty!(r.a); empty!(r.b)
    z = findfirst(iszero, input)
    n = z === nothing ? length(input) : z - 1
    i = 1           # input position
    f = 1           # format position
    done = Int32(0)
    fl = length(fmt)
    while f <= fl
        c = fmt[f]
        c == 0 && break
        if c_isspace(c)
            while f <= fl && c_isspace(fmt[f])
                f += 1
            end
            while i <= n && c_isspace(input[i])
                i += 1
            end
            continue
        end
        if c != UInt8('%')
            i > n && return done == 0 ? Int32(-1) : done
            input[i] != c && return done
            i += 1
            f += 1
            continue
        end
        f += 1
        suppress = false
        if f <= fl && fmt[f] == UInt8('*')
            suppress = true
            f += 1
        end
        width = 0
        while f <= fl && c_isdigit(fmt[f])
            width = width * 10 + Int(fmt[f] - UInt8('0'))
            f += 1
        end
        while f <= fl && fmt[f] in b"hlLqjzt"
            f += 1
        end
        f > fl && return done
        conv = fmt[f]
        f += 1
        if conv == UInt8('%')
            while i <= n && c_isspace(input[i])
                i += 1
            end
            i > n && return done == 0 ? Int32(-1) : done
            input[i] != UInt8('%') && return done
            i += 1
            continue
        end
        if conv == UInt8('n')
            suppress || _scan_push!(r, _SC_INT, Int64(i - 1), 0, -1)
            continue
        end
        if conv != UInt8('c') && conv != UInt8('[')
            while i <= n && c_isspace(input[i])
                i += 1
            end
        end
        i > n && return done == 0 ? Int32(-1) : done
        lim = width > 0 ? min(i + width - 1, n) : n
        if conv in b"diuxXo"
            base = (conv == UInt8('d') || conv == UInt8('u')) ? 10 :
                   conv == UInt8('i') ? 0 : conv == UInt8('o') ? 8 : 16
            ok, v, ni = _scan_int(r, input, i, lim, base, !(conv == UInt8('d') || conv == UInt8('i')))
            ok || return done
            if !suppress
                _scan_push!(r, _SC_INT, v, 0, -1)
                done += Int32(1)
            end
            i = ni
        elseif conv in b"eEfFgGaA"
            ok, e = _scan_float(input, i, lim, width > 0 && i + width - 1 <= n)
            ok || return done
            if !suppress
                _scan_push!(r, _SC_FLOAT, Int64(0), i, e)
                done += Int32(1)
            end
            i = e + 1
        elseif conv == UInt8('s')
            j = i
            while j <= lim && !c_isspace(input[j])
                j += 1
            end
            if !suppress
                _scan_push!(r, _SC_BYTES, Int64(0), i, j - 1)
                done += Int32(1)
            end
            i = j
        elseif conv == UInt8('c')
            w = width > 0 ? width : 1
            take = min(w, n - i + 1)
            if !suppress
                _scan_push!(r, _SC_BYTES, Int64(0), i, i + take - 1)
                done += Int32(1)
            end
            i += take
        elseif conv == UInt8('[')
            negate = false
            if f <= fl && fmt[f] == UInt8('^')
                negate = true
                f += 1
            end
            set_start = f
            f <= fl && fmt[f] == UInt8(']') && (f += 1)
            while f <= fl && fmt[f] != UInt8(']')
                f += 1
            end
            set = @view fmt[set_start:min(f, fl + 1)-1]
            f <= fl && (f += 1)
            tab = _build_scanset!(_SCANSET, set)
            j = i
            while j <= lim && (@inbounds tab[input[j]+1]) != negate
                j += 1
            end
            j == i && return done
            if !suppress
                _scan_push!(r, _SC_BYTES, Int64(0), i, j - 1)
                done += Int32(1)
            end
            i = j
        else
            return done
        end
    end
    done
end

# Store one result into a destination.
@inline function _scan_store!(d::Ref{T}, kind::UInt8, v::Int64, inp, a::Int, b::Int) where {T<:Integer}
    if kind == _SC_INT
        d[] = v % T
    elseif kind == _SC_BYTES && (T === UInt8 || T === Int8) && b >= a
        d[] = reinterpret(T, inp[a])
    end
    nothing
end
@inline function _scan_store!(d::Ref{T}, kind::UInt8, v::Int64, inp, a::Int, b::Int) where {T<:AbstractFloat}
    if kind == _SC_INT
        d[] = T(v)
    elseif kind == _SC_FLOAT
        d[] = T === Float32 ? strtof(@view inp[a:b])[1] : T(strtod(@view inp[a:b])[1])
    end
    nothing
end
@inline function _scan_store!(d::Vector{UInt8}, kind::UInt8, v::Int64, inp, a::Int, b::Int)
    if kind == _SC_BYTES
        empty!(d)
        _append!(d, inp, a, b)
    end
    nothing
end
@inline _scan_store!(::Nothing, kind::UInt8, v::Int64, inp, a::Int, b::Int) = nothing

@inline _scan_apply!(r::_ScanResults, inp, j::Int) = nothing
@inline function _scan_apply!(r::_ScanResults, inp, j::Int, d, rest...)
    j > length(r.kind) && return nothing
    @inbounds _scan_store!(d, r.kind[j], r.ival[j], inp, r.a[j], r.b[j])
    _scan_apply!(r, inp, j + 1, rest...)
end

"""
    csscanf(input, fmt, dests...) -> Int32

C `sscanf(input, fmt, ...)` with glibc's semantics. Each destination is a
`Ref{T}` for a numeric conversion (`Ref{Int32}` for `%d`, `Ref{Int64}` for
`%ld`, `Ref{Float64}` for `%lf`, `Ref{UInt8}` for `%c`, ...; integer values
are truncated to `T` as C stores into an `int`, `short`, ...), a
`Vector{UInt8}` for `%s`, `%[...]` and `%Nc` (its contents are replaced), or
`nothing` (ignored). Length modifiers in `fmt` are ignored: the destination
type decides.

Returns the number of assigned conversions, or -1 (`EOF`) if the input ended
before the first assignment. Destinations of conversions that were not
reached are left unchanged (C programs rely on such stale values).

```julia
d, m, y = Ref{Int32}(0), Ref{Int32}(0), Ref{Int32}(0)
csscanf("01.02.85", "%d%*c%d%*c%d", d, m, y) == 3   # d[] == 1, m[] == 2
```
"""
function csscanf(input::ByteStr, fmt::ByteStr, dests...)
    r = _SCAN
    inp = _bv(input)
    ret = _sscanf_core!(r, inp, _bv(fmt))
    _scan_apply!(r, inp, 1, dests...)
    ret
end

# ===========================================================================
# strtok

"""
    Strtok(s)

The C `strtok` function over one string (which ends at its first NUL):
`t = Strtok(s); strtok(t, delims)` corresponds to `strtok(s, delims)`, and
each further `strtok(t, delims)` to `strtok(NULL, delims)`. Tokens are
returned as new byte vectors (`nothing` is C's `NULL`). C writes a NUL over
the delimiter that ends each token; callers that depend on that must
reproduce it themselves. [`strtok_pos`](@ref) and [`strtok_rest`](@ref)
give the position where the next call starts and the rest of the string.
"""
mutable struct Strtok
    s::Vector{UInt8}
    pos::Int    # 1-based index of the next start; 0 when exhausted
end
Strtok(s::ByteStr) = Strtok(cstr(bytes(s)), 1)

@inline _isdelim(c::UInt8, d::AbstractVector{UInt8}) = c in d

"Next token of a [`Strtok`](@ref), or `nothing`."
function strtok(t::Strtok, delims::ByteStr)
    d = _bv(delims)
    s = t.s
    n = length(s)
    i = t.pos
    i == 0 && return nothing
    while i <= n && _isdelim(s[i], d)
        i += 1
    end
    if i > n
        t.pos = 0
        return nothing
    end
    j = i
    while j <= n && !_isdelim(s[j], d)
        j += 1
    end
    t.pos = j <= n ? j + 1 : 0
    s[i:j-1]
end

"Index (1-based) where the next `strtok` call starts, or `nothing`."
strtok_pos(t::Strtok) = t.pos == 0 ? nothing : t.pos
"The rest of the string from the current position (empty if exhausted)."
strtok_rest(t::Strtok) = (t.pos == 0 || t.pos > length(t.s)) ? UInt8[] : t.s[t.pos:end]

# ===========================================================================
# fgets

"""
    fgets_lines(data, size)

Iterator over the successive results of `fgets(buf, size, fp)` reading
`data`: pieces of at most `size - 1` bytes (views of `data`), each ending
with a newline unless the line was longer or the input ended.
"""
struct FgetsLines{V<:AbstractVector{UInt8}}
    data::V
    lim::Int
end
fgets_lines(data::ByteStr, size::Integer) = FgetsLines(_bv(data), max(Int(size) - 1, 1))
Base.IteratorSize(::Type{<:FgetsLines}) = Base.SizeUnknown()
function Base.iterate(it::FgetsLines, i::Int=1)
    n = length(it.data)
    i > n && return nothing
    e = min(i + it.lim - 1, n)
    j = e
    @inbounds for k in i:e
        if it.data[k] == UInt8('\n')
            j = k
            break
        end
    end
    (view(it.data, i:j), j + 1)
end

# ===========================================================================
# glibc rand

"glibc's `RAND_MAX`."
const RAND_MAX = Int32(2147483647)

"""
    GlibcRand(seed=1)

The state of glibc's `rand()` generator (`random`, TYPE_3 additive feedback
with 31 words of state), seeded as `srand(seed)`. [`glibc_rand!`](@ref)
gives the next value; [`glibc_srand!`](@ref) reseeds.
"""
mutable struct GlibcRand
    state::Vector{UInt32}
    f::Int      # 0-based
    r::Int
end

# glibc random_r.c, TYPE_3: DEG_3 words of state, SEP_3 between the front
# and rear pointers; srand seeds with the "minimal standard" generator
# 16807 * x mod (2^31 - 1), by Schrage's method (127773 = (2^31 - 1) / 16807,
# 2836 = (2^31 - 1) % 16807), then discards 10 * DEG_3 outputs.
const _DEG_3 = 31
const _SEP_3 = 3

function GlibcRand(seed::Integer=1)
    g = GlibcRand(zeros(UInt32, _DEG_3), _SEP_3, 0)
    glibc_srand!(g, seed)
    g
end

"C `srand(seed)` on a [`GlibcRand`](@ref) (a seed of 0 is the same as 1)."
function glibc_srand!(g::GlibcRand, seed::Integer)
    seed = UInt32(seed % UInt32)
    seed == 0 && (seed = UInt32(1))
    g.state[1] = seed
    word = Int64(reinterpret(Int32, seed))
    for i in 2:_DEG_3
        hi = div(word, 127773)
        lo = rem(word, 127773)
        word = 16807 * lo - 2836 * hi
        word < 0 && (word += 2147483647)
        g.state[i] = word % UInt32
    end
    g.f = _SEP_3
    g.r = 0
    for _ in 1:10*_DEG_3
        glibc_rand!(g)
    end
    g
end

"C `rand()` on a [`GlibcRand`](@ref): the next value, in `0:RAND_MAX`."
@inline function glibc_rand!(g::GlibcRand)
    st = g.state
    @inbounds v = st[g.f+1] + st[g.r+1]
    @inbounds st[g.f+1] = v
    g.f = g.f == _DEG_3 - 1 ? 0 : g.f + 1
    g.r = g.r == _DEG_3 - 1 ? 0 : g.r + 1
    (v >> 1) % Int32
end

# ===========================================================================
# The process: standard streams, exit, environment

# Size at which the standard output buffer is written out.
const STDOUT_BUFSIZE = 1 << 16

"""
State of the emulated C process (one per process; replaced while a tool runs
in-process, see `run_tool`): the buffered standard output, capture buffers,
the standard input, the open files flushed by `cexit`, the `rand` generator.
"""
mutable struct CProc
    outbuf::Vector{UInt8}
    out_error::Bool
    tty::Int8                               # -1: unknown
    out_capture::Union{Nothing,Vector{UInt8}}
    err_capture::Union{Nothing,Vector{UInt8}}
    stdin_fd::Int32                         # raw fd of the standard input
    stdin_mem::Union{Nothing,Vector{UInt8}} # in-memory standard input
    stdin_mempos::Int
    stdin_pushback::Vector{UInt8}           # bytes given back by closed readers
    open_files::IdDict{Any,Nothing}         # writable files (flushed at exit)
    rng::GlibcRand
end

CProc() = CProc(sizehint!(UInt8[], STDOUT_BUFSIZE), false, Int8(-1), nothing, nothing,
                Int32(0), nothing, 0, UInt8[], IdDict{Any,Nothing}(), GlibcRand(1))

const _PROC = Ref{CProc}()
"The current emulated C process state."
@inline cproc() = _PROC[]

"C `srand(seed)` on the process generator."
csrand(seed::Integer) = (glibc_srand!(cproc().rng, seed); nothing)
"C `rand()` on the process generator."
crand() = glibc_rand!(cproc().rng)

"""
    CExit(status)

Thrown by [`cexit`](@ref): C's `exit(status)`. The command-line driver (and
`run_tool`) catch it; library code must never catch it (use specific
exception types in `catch` clauses, or rethrow it).
"""
struct CExit <: Exception
    status::Int32
end

const _HAVE_POSIX_IO = !Sys.iswindows()

# Wait until fd is ready (after EAGAIN on a non-blocking descriptor).
function _poll_fd(fd::Integer, events::Int16)
    pfd = Ref((Int32(fd), events, Int16(0)))
    ccall(:poll, Cint, (Ptr{Cvoid}, Culong, Cint), pfd, 1, -1)
    nothing
end

const _EAGAIN = Base.Libc.EAGAIN
const _EWOULDBLOCK = @static isdefined(Base.Libc, :EWOULDBLOCK) ? Base.Libc.EWOULDBLOCK : Base.Libc.EAGAIN
const _EINTR = Base.Libc.EINTR
const _EPIPE = Base.Libc.EPIPE
"Exit status of a process killed by `SIGPIPE`, as the shell reports it (128 + 13)."
const _SIGPIPE_STATUS = 141
"Largest byte count passed to one Windows `_read`/`_write` call (its count is 32-bit)."
const _WIN_IO_CHUNK = 1 << 30

"""
    raw_write(fd, p::Ptr{UInt8}, n) -> Int

Write n bytes to a file descriptor (all of them, retrying after partial
writes, `EINTR` and `EAGAIN`). Returns 0, or the `errno` value of an error.
"""
function raw_write(fd::Integer, p::Ptr{UInt8}, n::Integer)
    done = 0
    while done < n
        @static if _HAVE_POSIX_IO
            r = ccall(:write, Cssize_t, (Cint, Ptr{UInt8}, Csize_t), fd, p + done, n - done)
        else
            r = ccall(:_write, Cint, (Cint, Ptr{UInt8}, Cuint), fd, p + done, min(n - done, _WIN_IO_CHUNK))
        end
        if r < 0
            err = Base.Libc.errno()
            if err == _EINTR
                continue
            elseif err == _EAGAIN || err == _EWOULDBLOCK
                _poll_fd(fd, Int16(4))   # POLLOUT
                continue
            end
            return Int(err)
        end
        done += r
    end
    0
end

"""
    raw_read(fd, p::Ptr{UInt8}, n) -> Int

Read at most n bytes from a file descriptor (retrying after `EINTR` and
`EAGAIN`): the number of bytes read, 0 at end of file, -1 on error.
"""
function raw_read(fd::Integer, p::Ptr{UInt8}, n::Integer)
    while true
        @static if _HAVE_POSIX_IO
            r = ccall(:read, Cssize_t, (Cint, Ptr{UInt8}, Csize_t), fd, p, n)
        else
            r = ccall(:_read, Cint, (Cint, Ptr{UInt8}, Cuint), fd, p, min(n, _WIN_IO_CHUNK))
        end
        if r < 0
            err = Base.Libc.errno()
            if err == _EINTR
                continue
            elseif err == _EAGAIN || err == _EWOULDBLOCK
                _poll_fd(fd, Int16(1))   # POLLIN
                continue
            end
            return -1
        end
        return Int(r)
    end
end

"`lseek` on a file descriptor: the new offset, or -1 on error."
function raw_lseek(fd::Integer, off::Integer, whence::Integer)
    @static if _HAVE_POSIX_IO
        Int64(ccall(:lseek, Int64, (Cint, Int64, Cint), fd, off, whence))
    else
        Int64(ccall(:_lseeki64, Int64, (Cint, Int64, Cint), fd, off, whence))
    end
end

function _stdout_is_tty(p::CProc)
    if p.tty < 0
        p.tty = (p.out_capture === nothing && stdout isa Base.TTY) ? Int8(1) : Int8(0)
    end
    p.tty == 1
end

"""
    cflush() -> Int32

C `fflush(stdout)`: write out the buffered standard output. Returns 0, or
-1 (`EOF`) on a write error. If the reader of a pipe has gone away
(`EPIPE`), the process exits with status 141, as a C program killed by
`SIGPIPE` appears to the shell.
"""
function cflush()
    p = cproc()
    buf = p.outbuf
    if isempty(buf)
        return p.out_error ? EOF : Int32(0)
    end
    cap = p.out_capture
    if cap !== nothing
        append!(cap, buf)
        empty!(buf)
        return Int32(0)
    end
    err = GC.@preserve buf raw_write(1, pointer(buf), length(buf))
    empty!(buf)
    if err != 0
        err == _EPIPE && exit(_SIGPIPE_STATUS)
        p.out_error = true
        return EOF
    end
    Int32(0)
end

@inline function _after_write(p::CProc)
    if length(p.outbuf) >= STDOUT_BUFSIZE || _stdout_is_tty(p)
        cflush()
    end
    nothing
end

"Write bytes to the buffered standard output (C `fwrite(p, 1, n, stdout)`)."
@inline function cout_write(b::AbstractVector{UInt8})
    p = cproc()
    append!(p.outbuf, b)
    _after_write(p)
    nothing
end
cout_write(s::AbstractString) = cout_write(codeunits(String(s)))

"Write one byte to the buffered standard output (C `putchar`)."
@inline function cputchar(c::Integer)
    p = cproc()
    push!(p.outbuf, c % UInt8)
    length(p.outbuf) >= STDOUT_BUFSIZE && cflush()
    nothing
end

"C `ferror(stdout)`."
cout_error() = cproc().out_error

"""
    cprintf(fmt, args...) -> Int32

C `printf` to the buffered standard output (see [`sprintf!`](@ref) for the
format); returns the number of bytes written.
"""
@inline function cprintf(fmt::ByteStr, args::Vararg{Any,N}) where {N}
    p = cproc()
    n = sprintf!(p.outbuf, fmt, args...)
    _after_write(p)
    Int32(n)
end

"Write bytes to the standard error (unbuffered, as C's `stderr`)."
function cerr_write(b::AbstractVector{UInt8})
    p = cproc()
    cap = p.err_capture
    if cap !== nothing
        append!(cap, b)
        return nothing
    end
    v = b isa Vector{UInt8} ? b : Vector{UInt8}(b)
    GC.@preserve v raw_write(2, pointer(v), length(v))
    nothing
end
cerr_write(s::AbstractString) = cerr_write(codeunits(String(s)))

"""
    ceprintf(fmt, args...) -> Int32

C `fprintf(stderr, ...)`; returns the number of bytes written.
"""
function ceprintf(fmt::ByteStr, args::Vararg{Any,N}) where {N}
    v = cformat(fmt, args...)
    cerr_write(v)
    Int32(length(v))
end

"""
    flush_all()

Flush every open output file and the standard output, as C's `exit` does
(without closing records or annotators).
"""
function flush_all()
    p = cproc()
    for f in collect(keys(p.open_files))
        _flush_at_exit(f)
    end
    cflush()
    nothing
end
# (defined for WfdbFile in wfdbio.jl)
_flush_at_exit(f) = nothing

"""
    cexit(status)

C `exit(status)`: throws [`CExit`](@ref), caught by the driver, which
flushes the open files and the standard output (as C's `exit` does) and
ends the process (or `run_tool`, which returns the status).
"""
cexit(status::Integer) = throw(CExit(status % Int32))

"""
    prog_name(argv0)

The last component of a program path (`argv[0]`), as the C tools compute
their name for messages (everything after the last `/`).
"""
function prog_name(argv0::ByteStr)
    a = bytes(argv0)
    k = findlast(==(UInt8('/')), a)
    k === nothing ? copy(a) : a[k+1:end]
end

"""
    cargs(args::Vector{String}) -> Vector{Vector{UInt8}}

Command-line arguments as byte strings.
"""
cargs(args::AbstractVector{<:AbstractString}) = Vector{UInt8}[bytes(a) for a in args]

"C `getenv(name)`: the value of an environment variable as bytes, or `nothing`."
function cgetenv(name::AbstractString)
    v = get(ENV, name, nothing)
    v === nothing ? nothing : Vector{UInt8}(codeunits(v))
end
"Same as [`cgetenv`](@ref)."
const getenv = cgetenv

"C `setenv(name, value, overwrite)`."
function csetenv(name::AbstractString, value::ByteStr, overwrite::Bool=true)
    (!overwrite && haskey(ENV, name)) && return nothing
    ENV[name] = bstr(cstr(bytes(value)))
    nothing
end

# Reset the process state (at module load, and for each in-process tool run).
function _reset_cproc!()
    _PROC[] = CProc()
    empty!(_ARGV)
    nothing
end
