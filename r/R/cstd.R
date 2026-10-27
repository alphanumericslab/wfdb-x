# cstd.R: emulation of the C standard library functions whose exact
# semantics the WFDB library and tools rely on (integer types, strtol,
# strtod, sscanf, strtok, fgets, glibc rand, printf), and the byte-exact
# standard input/output used by the tools.
#
# This file is part of wfdb-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
# It has no counterpart in the original package.
#
# Copyright (C) 2026 Reza Sameni.
#
# This library is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.
#
# Conventions (see DEVELOPING.md):
#   * numbers are doubles; C wrap-around is applied with cint32() etc.
#   * byte strings are raw vectors; functions that parse C strings accept a
#     character string, a raw vector or an integer vector of byte codes, and
#     stop at the first NUL byte as C does;
#   * C positions are 1-based: strtol() and strtod() return c(value, end)
#     where `end` is the index just past the number (end == pos when no
#     conversion was performed).

LONG_MAX <- 2^63     # 9223372036854775807, which rounds to 2^63 as a double
LONG_MIN <- -2^63    # (powers of two are exact; R's reading of long decimal
                     # literals is not correctly rounded on every platform)
INT_MAX <- 2147483647
INT_MIN <- -2147483648
UINT_MAX <- 4294967295
SHRT_MAX <- 32767
SHRT_MIN <- -32768
DBL_MAX <- .Machine$double.xmax
RAND_MAX <- 2147483647

# Package state of this module (output buffers, caches).
.cstd <- new.env(parent = emptyenv())
.cstd$fmt_cache <- new.env(hash = TRUE, parent = emptyenv())
.cstd$scan_cache <- new.env(hash = TRUE, parent = emptyenv())
.cstd$out_parts <- vector("list", 1024L)
.cstd$out_n <- 0L
.cstd$out_bytes <- 0
.cstd$out_con <- NULL
.cstd$err_con <- NULL
.cstd$stdout_failed <- FALSE # see .stdout_error
.cstd$write_errors <- 0      # see wfdbx_write_errors (wfdbio.R)
.cstd$stdin_data <- NULL
.cstd$stdin_path <- NULL     # file substituted for the standard input (stdin_freopen)

.LENMODS <- as.integer(charToRaw("hlLqjzt"))   # length modifiers of conversions

# ---------------------------------------------------------------------------
# Integer types (vectorized; exact for |x| < 2^53)

#' C assignment to int (32-bit wrap-around).
cint32 <- function(x) {
  x <- x %% 4294967296
  x - (x >= 2147483648) * 4294967296
}
#' C assignment to unsigned int.
cuint32 <- function(x) x %% 4294967296
#' C assignment to short.
cint16 <- function(x) {
  x <- x %% 65536
  x - (x >= 32768) * 65536
}
#' C assignment to unsigned short.
cuint16 <- function(x) x %% 65536
#' C assignment to (signed) char.
cint8 <- function(x) {
  x <- x %% 256
  x - (x >= 128) * 256
}
#' C assignment to unsigned char.
cuint8 <- function(x) x %% 256

#' C integer division (truncation toward zero).
cdiv <- function(a, b) trunc(a / b)
#' C integer remainder (sign of the dividend).
cmod <- function(a, b) a - b * trunc(a / b)

#' C conversion of double to int: truncation; INT_MIN for NaN and out of
#' range values (x86-64).
d2i <- function(x) {
  r <- trunc(x)
  bad <- is.na(x) | x >= 2147483648 | x <= -2147483649
  if (any(bad)) r[bad] <- -2147483648
  r
}
#' C conversion of double to long (64-bit): LONG_MIN when out of range.
d2l <- function(x) {
  r <- trunc(x)
  bad <- is.na(x) | x >= 2^63 | x < -2^63
  if (any(bad)) r[bad] <- -2^63
  r
}

# ---------------------------------------------------------------------------
# Byte strings

#' Byte codes (integer vector) of a C string given as a character string,
#' a raw vector or an integer vector, up to its first NUL.
cbytes <- function(s) {
  if (is.null(s)) return(integer(0))
  b <- if (is.raw(s)) as.integer(s) else if (is.character(s)) {
    if (length(s) == 0L || is.na(s[1L])) integer(0) else as.integer(charToRaw(s[1L]))
  } else as.integer(s)
  z <- match(0L, b)
  if (!is.na(z)) b <- b[seq_len(z - 1L)]
  b
}

#' Character string from a raw vector (or byte codes), up to the first NUL
#' (the C string view of a byte buffer).  NULL stays NULL.
cstr <- function(b) {
  if (is.null(b)) return(NULL)
  if (is.character(b)) return(b)
  if (!is.raw(b)) b <- as.raw(b)
  z <- match(as.raw(0L), b)
  if (!is.na(z)) b <- b[seq_len(z - 1L)]
  rawToChar(b)
}

#' Raw bytes of a string (character, raw or byte codes).
craw <- function(s) {
  if (is.raw(s)) s else if (is.character(s)) charToRaw(s) else if (is.null(s)) raw(0) else as.raw(s)
}

# ---------------------------------------------------------------------------
# strtol, strtod, atoi, atof

.digval <- local({
  d <- rep.int(99L, 256L)
  d[49:58] <- 0:9          # '0'-'9'
  d[98:123] <- 10:35       # 'a'-'z'
  d[66:91] <- 10:35        # 'A'-'Z'
  d
})

#' C strtol(s + pos - 1, &end, base).  Returns c(value, end) (end == pos if
#' no conversion).  The value is clamped to [lmin, lmax] (LONG_MIN and
#' LONG_MAX by default; values beyond 2^53 are not exact).
strtol <- function(s, base = 10, pos = 1, lmin = LONG_MIN, lmax = LONG_MAX) {
  b <- if (is.integer(s)) s else cbytes(s)
  n <- length(b)
  i <- pos
  while (i <= n && (b[i] == 32L || (b[i] >= 9L && b[i] <= 13L))) i <- i + 1L
  neg <- FALSE
  if (i <= n && (b[i] == 43L || b[i] == 45L)) {
    neg <- b[i] == 45L
    i <- i + 1L
  }
  if (base == 0 || base == 16) {
    # ("0x" or "0X")
    if (i + 2L <= n && b[i] == 48L && (b[i + 1L] == 120L || b[i + 1L] == 88L) &&
        .digval[b[i + 2L] + 1L] < 16L) {
      base <- 16
      i <- i + 2L
    } else if (base == 0) {
      base <- if (i <= n && b[i] == 48L) 8 else 10
    }
  }
  if (i > n) return(c(0, pos))
  d <- .digval[b[i:n] + 1L]
  bad <- match(TRUE, d >= base)
  cnt <- if (is.na(bad)) n - i + 1L else bad - 1L
  if (cnt == 0L) return(c(0, pos))
  d <- d[seq_len(cnt)]
  if (cnt <= 13L) {
    v <- sum(d * base^((cnt - 1L):0))
  } else {
    v <- 0
    for (k in seq_len(cnt)) v <- v * base + d[k]
  }
  if (neg) v <- -v
  if (v > lmax) v <- lmax else if (v < lmin) v <- lmin
  c(v, i + cnt)
}

#' C atoi(): strtol converted to int.
atoi <- function(s) {
  b <- cbytes(s)
  r <- strtol(b)
  v <- r[1L]
  if (abs(v) < 2^53) return(cint32(v))    # (exact in a double)
  # large values: (int)strtol(), computed exactly
  if (v >= LONG_MAX) return(-1)
  if (v <= LONG_MIN) return(0)
  i <- 1L
  while (b[i] == 32L || (b[i] >= 9L && b[i] <= 13L)) i <- i + 1L
  neg <- b[i] == 45L
  if (b[i] == 45L || b[i] == 43L) i <- i + 1L
  m <- 0
  for (k in i:(r[2L] - 1)) m <- (m * 10 + (b[k] - 48L)) %% 4294967296
  cint32(if (neg) -m else m)
}

.p10 <- 10^(0:22)     # exact powers of ten

.strtod_pat <- paste0(
  "^[+-]?(?:",
  "0[xX](?:[0-9a-fA-F]+(?:\\.[0-9a-fA-F]*)?|\\.[0-9a-fA-F]+)(?:[pP][+-]?[0-9]+)?",
  "|(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?",
  "|[iI][nN][fF](?:[iI][nN][iI][tT][yY])?",
  "|[nN][aA][nN](?:\\([0-9A-Za-z_]*\\))?)")

# Bytes that can occur in a number accepted by strtod.
.numchar <- local({
  ok <- logical(256L)
  ok[c(48:57, 65:90, 97:122, 43, 45, 46, 40, 41, 95) + 1L] <- TRUE
  ok
})

#' C strtod(s + pos - 1, &end): glibc-exact (correctly rounded, overflow to
#' +-HUGE_VAL, underflow to 0, hexadecimal floats, inf, nan).  Returns
#' c(value, end) (end == pos if no conversion).
strtod <- function(s, pos = 1) {
  b <- if (is.integer(s)) s else cbytes(s)
  n <- length(b)
  i <- pos
  while (i <= n && (b[i] == 32L || (b[i] >= 9L && b[i] <= 13L))) i <- i + 1L
  if (i > n) return(c(0, pos))
  # the candidate token: the run of bytes that can belong to a number
  w <- b[i:min(n, i + 63L)]
  e <- match(FALSE, .numchar[w + 1L])
  if (is.na(e) && i + 63L < n) {
    w <- b[i:n]
    e <- match(FALSE, .numchar[w + 1L])
  }
  if (!is.na(e)) w <- w[seq_len(e - 1L)]
  nw <- length(w)
  if (nw == 0L) return(c(0, pos))
  # fast path: [+-]digits[.digits][e[+-]digits]
  k <- 1L
  neg <- FALSE
  if (w[1L] == 45L || w[1L] == 43L) {
    neg <- w[1L] == 45L
    k <- 2L
  }
  isd <- w >= 48L & w <= 57L
  if (k <= nw && (isd[k] || w[k] == 46L)) {
    r1 <- if (k <= nw) match(FALSE, isd[k:nw]) else NA
    n1 <- if (is.na(r1)) nw - k + 1L else r1 - 1L
    d1 <- w[k:(k + n1 - 1L)]
    if (n1 == 0L) d1 <- integer(0)
    k <- k + n1
    d2 <- integer(0)
    if (k <= nw && w[k] == 46L) {
      k <- k + 1L
      if (k <= nw) {
        r2 <- match(FALSE, isd[k:nw])
        n2 <- if (is.na(r2)) nw - k + 1L else r2 - 1L
        if (n2 > 0L) d2 <- w[k:(k + n2 - 1L)]
        k <- k + n2
      }
    }
    # (digits, but not the "0" of "0x")
    if (length(d1) + length(d2) > 0L &&
        !(n1 == 1L && d1[1L] == 48L && k <= nw && (w[k] == 120L || w[k] == 88L) &&
          length(d2) == 0L)) {
      ex <- 0
      if (k < nw && (w[k] == 101L || w[k] == 69L)) {       # 'e', 'E'
        k2 <- k + 1L
        es <- 1
        if (w[k2] == 45L || w[k2] == 43L) {
          if (w[k2] == 45L) es <- -1
          k2 <- k2 + 1L
        }
        if (k2 <= nw && isd[k2]) {
          r3 <- match(FALSE, isd[k2:nw])
          n3 <- if (is.na(r3)) nw - k2 + 1L else r3 - 1L
          de <- w[k2:(k2 + n3 - 1L)] - 48L
          de <- de[cumsum(de != 0L) > 0L]
          ex <- if (length(de) > 7L) 1e7 else sum(de * 10^((length(de) - 1L):0))
          ex <- es * ex
          k <- k2 + n3
        }
      }
      v <- .dec_digits_to_double(c(d1, d2) - 48L, ex - length(d2))
      return(c(if (neg) -v else v, i + k - 1L))
    }
  }
  str <- rawToChar(as.raw(w))
  m <- regexpr(.strtod_pat, str, perl = TRUE, useBytes = TRUE)
  len <- attr(m, "match.length")
  if (len <= 0L) return(c(0, pos))
  t <- substr(str, 1L, len)
  c(.strtod_token(t), i + len)
}

# Correctly rounded value of the decimal digits d (integer vector of 0-9)
# times 10^ex.
.dec_digits_to_double <- function(d, ex) {
  nz <- which(d != 0L)
  if (length(nz) == 0L) return(0)
  f <- nz[1L]
  l <- nz[length(nz)]
  ex <- ex + (length(d) - l)
  d <- d[f:l]
  nd <- length(d)
  # (up to 15 digits and powers of ten up to 10^22 are exact in a double,
  # so that one multiplication or division rounds correctly)
  if (nd <= 15L) {
    D <- sum(d * .p10[nd:1])                 # exact
    if (ex >= 0 && ex <= 22) return(D * .p10[ex + 1])
    if (ex < 0 && ex >= -22) return(D / .p10[-ex + 1])
    if (ex > 22 && ex <= 22 + 15 - nd)      # D * 10^(ex-22) is exact
      return((D * .p10[ex - 22 + 1]) * 1e22)
  }
  # (beyond the range of doubles: DBL_MAX is about 1.8e308, and values
  # below half the smallest subnormal, about 4.9e-324, round to 0)
  lead <- ex + nd - 1
  if (lead > 309) return(Inf)
  if (lead < -325) return(0)
  .dec_to_double_exact(rawToChar(as.raw(d + 48L)), ex)
}

# Value of a token matched by .strtod_pat.
.strtod_token <- function(t) {
  c1 <- substr(t, 1L, 1L)
  neg <- c1 == "-"
  if (neg || c1 == "+") t <- substr(t, 2L, nchar(t))
  c1 <- substr(t, 1L, 1L)
  if (c1 == "i" || c1 == "I") {
    v <- Inf
  } else if (c1 == "n" || c1 == "N") {
    v <- NaN              # positive (sign bit clear), as glibc's "nan"
  } else if (nchar(t) > 1L && (substr(t, 2L, 2L) == "x" || substr(t, 2L, 2L) == "X")) {
    v <- .strtod_hex(tolower(substr(t, 3L, nchar(t))))
  } else {
    # decimal: digits and exponent
    ep <- regexpr("[eE]", t)
    ex <- 0
    if (ep > 0L) {
      es <- substr(t, ep + 1L, nchar(t))
      ex <- as.numeric(es)
      if (abs(ex) > 1e6) ex <- sign(ex) * 1e6
      t <- substr(t, 1L, ep - 1L)
    }
    dp <- regexpr(".", t, fixed = TRUE)
    if (dp > 0L) {
      frac <- substr(t, dp + 1L, nchar(t))
      t <- paste0(substr(t, 1L, dp - 1L), frac)
      ex <- ex - nchar(frac)
    }
    v <- .dec_digits_to_double(as.integer(charToRaw(t)) - 48L, ex)
  }
  if (neg) -v else v
}

# Slow path: start from R's (nearly correct) conversion and correct it by
# exact comparisons with the midpoints between adjacent doubles.
.dec_to_double_exact <- function(digits, ex) {
  x <- as.numeric(paste0(digits, "e", ex))
  if (is.na(x)) x <- 0
  if (x > DBL_MAX) x <- DBL_MAX
  mq <- .dbl_parts(x)
  M <- mq[1L]
  q <- mq[2L]
  D <- .big_from_digits(digits)
  repeat {
    # upper midpoint (2M+1) * 2^(q-1)
    c1 <- .cmp_dec_bin(D, ex, .big_add_small(.big_from_num(2 * M), 1), q - 1)
    if (c1 > 0 || (c1 == 0 && M %% 2 == 1)) {
      M <- M + 1
      if (M == .DBL_MLIM) {
        M <- .DBL_MMIN
        q <- q + 1
      }
      if (q > .DBL_QMAX) return(Inf)
      next
    }
    if (M == 0) break
    if (M == .DBL_MMIN && q > .DBL_QMIN) {
      c2 <- .cmp_dec_bin(D, ex, .big_add_small(.big_from_num(4 * M), -1), q - 2)
    } else {
      c2 <- .cmp_dec_bin(D, ex, .big_add_small(.big_from_num(2 * M), -1), q - 1)
    }
    if (c2 < 0 || (c2 == 0 && M %% 2 == 1)) {
      M <- M - 1
      if (M < .DBL_MMIN && q > .DBL_QMIN) {
        M <- .DBL_MLIM - 1
        q <- q - 1
      }
      next
    }
    break
  }
  M * 2^q
}

# IEEE 754 doubles are M * 2^q, with an integer significand M < 2^53 (at
# least 2^52 for normal numbers) and .DBL_QMIN <= q <= .DBL_QMAX.
.DBL_MMIN <- 2^52
.DBL_MLIM <- 2^53
.DBL_QMIN <- -1074
.DBL_QMAX <- 971

# Integer mantissa and exponent of a finite double x >= 0: x == M * 2^q.
# (Fields: 52 fraction bits, then an 11-bit exponent with a bias of 1023.)
.dbl_parts <- function(x) {
  b <- as.integer(writeBin(x, raw(), endian = "little"))
  lo <- sum(b[1:4] * c(1, 256, 65536, 16777216))
  hi <- sum(b[5:8] * c(1, 256, 65536, 16777216))
  expo <- (hi %/% 2^20) %% 2^11
  M <- (hi %% 2^20) * 2^32 + lo
  if (expo == 0) c(M, .DBL_QMIN) else c(M + .DBL_MMIN, expo - 1023 - 52)
}

# Minimal unsigned big integers: little-endian numeric vectors of base-2^20
# limbs.
.BIGB <- 1048576

.big_norm <- function(v) {
  repeat {
    cy <- floor(v / .BIGB)
    if (all(cy == 0)) break
    v <- c(v - cy * .BIGB, 0) + c(0, cy)
  }
  n <- length(v)
  while (n > 1L && v[n] == 0) n <- n - 1L
  v[seq_len(n)]
}
.big_from_num <- function(x) {      # x: an integer-valued double < 2^60
  v <- numeric(0)
  repeat {
    r <- x %% .BIGB
    v <- c(v, r)
    x <- (x - r) / .BIGB
    if (x == 0) break
  }
  v
}
.big_add_small <- function(a, s) {  # a + s (s may be -1; a > 0)
  a[1L] <- a[1L] + s
  if (a[1L] < 0) {
    k <- 1L
    while (a[k] < 0) {
      a[k] <- a[k] + .BIGB
      a[k + 1L] <- a[k + 1L] - 1
      k <- k + 1L
    }
    n <- length(a)
    while (n > 1L && a[n] == 0) n <- n - 1L
    return(a[seq_len(n)])
  }
  .big_norm(a)
}
.big_mul_small <- function(a, m) .big_norm(a * m)
.big_from_digits <- function(digits) {
  nd <- nchar(digits)
  k0 <- nd %% 6L
  v <- 0
  pos <- 1L
  if (k0 > 0L) {
    v <- as.numeric(substr(digits, 1L, k0))
    pos <- k0 + 1L
  }
  while (pos <= nd) {
    v <- .big_norm(v * 1e6 + c(as.numeric(substr(digits, pos, pos + 5L)), numeric(length(v) - 1L)))
    pos <- pos + 6L
  }
  .big_norm(v)
}
.big_mul_pow5 <- function(a, k) {
  while (k >= 13) {
    a <- .big_mul_small(a, 1220703125)   # 5^13
    k <- k - 13
  }
  if (k > 0) a <- .big_mul_small(a, 5^k)
  a
}
.big_mul_pow2 <- function(a, k) {
  if (k >= 20) {
    a <- c(numeric(k %/% 20), a)
    k <- k %% 20
  }
  if (k > 0) a <- .big_mul_small(a, 2^k)
  a
}
.big_cmp <- function(a, b) {
  na <- length(a)
  nb <- length(b)
  if (na != nb) return(if (na > nb) 1 else -1)
  d <- which(a != b)
  if (length(d) == 0L) return(0)
  k <- d[length(d)]
  if (a[k] > b[k]) 1 else -1
}
# Compare D * 10^e10 with M * 2^q2 (D, M big integers).
.cmp_dec_bin <- function(D, e10, M, q2) {
  b1 <- max(e10, 0) + max(-q2, 0)
  b2 <- max(-e10, 0) + max(q2, 0)
  cm <- min(b1, b2)
  L <- .big_mul_pow2(.big_mul_pow5(D, max(e10, 0)), b1 - cm)
  R <- .big_mul_pow2(.big_mul_pow5(M, max(-e10, 0)), b2 - cm)
  .big_cmp(L, R)
}

# Hexadecimal floating-point constant (after "0x"; lower case).
.strtod_hex <- function(h) {
  ex <- 0
  pp <- regexpr("p", h, fixed = TRUE)
  if (pp > 0L) {
    ex <- as.numeric(substr(h, pp + 1L, nchar(h)))
    h <- substr(h, 1L, pp - 1L)
  }
  dp <- regexpr(".", h, fixed = TRUE)
  if (dp > 0L) {
    frac <- substr(h, dp + 1L, nchar(h))
    h <- paste0(substr(h, 1L, dp - 1L), frac)
    ex <- ex - 4 * nchar(frac)
  }
  d <- .digval[as.integer(charToRaw(h)) + 1L]
  # bits, most significant first; value = bits * 2^ex
  bits <- as.vector(rbind(d %/% 8L, (d %/% 4L) %% 2L, (d %/% 2L) %% 2L, d %% 2L))
  f1 <- match(1L, bits)
  if (is.na(f1)) return(0)
  bits <- bits[f1:length(bits)]
  nb <- length(bits)
  # (the binary exponents of the largest and the smallest normal doubles
  # are 1023 and -1022; below that, fewer significant bits are kept)
  lead <- ex + nb - 1
  if (lead > 1023) return(Inf)
  keep <- 53
  if (lead < -1022) keep <- 53 - (-1022 - lead)
  if (keep < 0) return(0)
  M <- if (keep > 0) sum(bits[seq_len(min(keep, nb))] * 2^((keep - 1):(keep - min(keep, nb)))) else 0
  if (nb > keep) {
    guard <- bits[keep + 1] == 1L
    sticky <- nb > keep + 1 && any(bits[(keep + 2):nb] == 1L)
    if (guard && (sticky || M %% 2 == 1)) M <- M + 1
  }
  M * 2^(lead - keep + 1)
}

#' C atof().
atof <- function(s) strtod(s)[1L]

# ---------------------------------------------------------------------------
# strtok

#' strtok emulation: t <- strtok_new(s) (the string, as character or raw),
#' then strtok_next(t, delims) for strtok(s, delims) and each later
#' strtok(NULL, delims).  Tokens are returned as character strings; NULL
#' when there are no more.  strtok_rest(t) is the unscanned rest (C's
#' saved pointer), or NULL.
strtok_new <- function(s) {
  t <- new.env(parent = emptyenv())
  t$b <- cbytes(s)
  t$pos <- 1L
  t
}
strtok_next <- function(t, delims) {
  i <- t$pos
  if (is.null(i)) return(NULL)
  b <- t$b
  n <- length(b)
  dl <- if (is.character(delims)) as.integer(charToRaw(delims)) else as.integer(delims)
  if (i > n) {
    t$pos <- NULL
    return(NULL)
  }
  isd <- b[i:n] %in% dl
  s <- match(FALSE, isd)
  if (is.na(s)) {
    t$pos <- NULL
    return(NULL)
  }
  st <- i + s - 1L
  e <- match(TRUE, isd[s:length(isd)])
  if (is.na(e)) {
    j <- n + 1L
    t$pos <- NULL
  } else {
    j <- st + e - 1L
    t$pos <- j + 1L
  }
  rawToChar(as.raw(b[st:(j - 1L)]))
}
strtok_rest <- function(t) {
  if (is.null(t$pos)) return(NULL)
  n <- length(t$b)
  if (t$pos > n) "" else rawToChar(as.raw(t$b[t$pos:n]))
}

# ---------------------------------------------------------------------------
# sscanf

.scan_parse <- function(fmt) {
  f <- as.integer(charToRaw(fmt))
  nf <- length(f)
  kind <- integer(0); ch <- character(0); width <- integer(0)
  supp <- logical(0); lmod <- integer(0)
  pos <- 1L
  while (pos <= nf) {
    c <- f[pos]
    if (c == 37L) {                     # '%'
      p <- pos + 1L
      sup <- p <= nf && f[p] == 42L
      if (sup) p <- p + 1L
      w <- 0L
      while (p <= nf && f[p] >= 48L && f[p] <= 57L) {
        w <- w * 10L + f[p] - 48L
        p <- p + 1L
      }
      lm <- 0L
      while (p <= nf && f[p] %in% .LENMODS) {
        lm <- if (f[p] == 104L) lm + 1L else 3L      # 'h', 'hh'; long
        p <- p + 1L
      }
      cc <- if (p <= nf) rawToChar(as.raw(f[p])) else ""
      if (!nzchar(cc) || !grepl(cc, "diouxXeEfFgGaAsc%", fixed = TRUE)) {
        kind <- c(kind, 0L); ch <- c(ch, ""); width <- c(width, 0L)
        supp <- c(supp, FALSE); lmod <- c(lmod, 0L)
        break
      }
      kind <- c(kind, if (cc == "%") 4L else 1L)
      ch <- c(ch, cc); width <- c(width, w); supp <- c(supp, sup)
      lmod <- c(lmod, min(lm, 3L))
      pos <- p + 1L
    } else if (c == 32L || (c >= 9L && c <= 13L)) {
      kind <- c(kind, 2L); ch <- c(ch, ""); width <- c(width, 0L)
      supp <- c(supp, FALSE); lmod <- c(lmod, 0L)
      pos <- pos + 1L
    } else {
      kind <- c(kind, 3L); ch <- c(ch, rawToChar(as.raw(c))); width <- c(width, c)
      supp <- c(supp, FALSE); lmod <- c(lmod, 0L)
      pos <- pos + 1L
    }
  }
  list(kind = kind, ch = ch, width = width, supp = supp, lmod = lmod)
}

#' C sscanf(s, fmt) for %d %i %u %o %x %X %e %f %g %a %s %c %% (with
#' assignment suppression, widths and length modifiers).  Returns
#' list(n = C's return value (-1 for EOF before the first conversion),
#' v = list of the assigned values).  Integer conversions are converted to
#' the C type (int, unsigned, short, or long with l/ll); %s and %c give
#' character strings.  Variables not assigned keep their old values in C:
#' callers must keep them.
csscanf <- function(s, fmt) {
  it <- if (nzchar(fmt)) .cstd$scan_cache[[fmt]] else NULL
  if (is.null(it)) {
    it <- .scan_parse(fmt)
    if (nzchar(fmt)) assign(fmt, it, envir = .cstd$scan_cache)
  }
  b <- if (is.integer(s)) s else cbytes(s)
  ns <- length(b)
  vals <- list()
  nconv <- 0L
  i <- 1L
  eof_first <- FALSE
  kinds <- it$kind
  for (q in seq_along(kinds)) {
    kind <- kinds[q]
    if (kind == 2L) {
      while (i <= ns && (b[i] == 32L || (b[i] >= 9L && b[i] <= 13L))) i <- i + 1L
      next
    } else if (kind == 3L) {
      if (i <= ns && b[i] == it$width[q]) {
        i <- i + 1L
        next
      }
      if (i > ns && nconv == 0L) eof_first <- TRUE
      break
    } else if (kind == 4L) {
      while (i <= ns && (b[i] == 32L || (b[i] >= 9L && b[i] <= 13L))) i <- i + 1L
      if (i <= ns && b[i] == 37L) {
        i <- i + 1L
        next
      }
      break
    } else if (kind == 0L) {
      break
    }
    conv <- it$ch[q]
    width <- it$width[q]
    if (conv != "c") {
      while (i <= ns && (b[i] == 32L || (b[i] >= 9L && b[i] <= 13L))) i <- i + 1L
    }
    if (i > ns) {
      if (nconv == 0L) eof_first <- TRUE
      break
    }
    sub <- if (width > 0L) b[i:min(ns, i + width - 1L)] else b[i:ns]
    lm <- it$lmod[q]
    if (conv %in% c("d", "u", "i", "o", "x", "X")) {
      base <- switch(conv, d = 10, u = 10, i = 0, o = 8, 16)
      r <- strtol(sub, base)
      if (r[2L] == 1) break
      v <- r[1L]
      if (lm == 0L) {
        v <- if (conv == "d" || conv == "i") cint32(v) else cuint32(v)
      } else if (lm == 1L) {
        v <- if (conv == "d" || conv == "i") cint16(v) else cuint16(v)
      } else if (lm == 2L) {
        v <- if (conv == "d" || conv == "i") cint8(v) else cuint8(v)
      }
      i <- i + as.integer(r[2L]) - 1L
    } else if (conv == "s") {
      j <- match(TRUE, sub == 32L | (sub >= 9L & sub <= 13L))
      k <- if (is.na(j)) length(sub) else j - 1L
      v <- rawToChar(as.raw(sub[seq_len(k)]))
      i <- i + k
    } else if (conv == "c") {
      w <- max(width, 1L)
      if (length(sub) < w) break
      v <- rawToChar(as.raw(sub[1:w]))
      i <- i + w
    } else {
      r <- strtod(sub)
      if (r[2L] == 1) break
      v <- r[1L]
      i <- i + as.integer(r[2L]) - 1L
    }
    if (!it$supp[q]) {
      nconv <- nconv + 1L
      vals[[nconv]] <- v
    }
  }
  list(n = if (eof_first && nconv == 0L) -1L else nconv, v = vals)
}

# ---------------------------------------------------------------------------
# fgets

#' The successive results of fgets(buf, size, fp) over the bytes `data`
#' (raw).  Returns a character vector (each piece cut at its first NUL, as
#' C string functions see it), or with as_raw = TRUE a list of raw
#' vectors.  Pieces have at most size - 1 bytes and end with a newline
#' unless the line was longer or the input ended.
fgets_lines <- function(data, size, as_raw = FALSE) {
  if (is.character(data)) data <- charToRaw(data)
  n <- length(data)
  if (n == 0L) return(if (as_raw) list() else character(0))
  lim <- size - 1L
  ends <- which(data == as.raw(10L))
  if (length(ends) == 0L || ends[length(ends)] != n) ends <- c(ends, n)
  starts <- c(1L, ends[-length(ends)] + 1L)
  len <- ends - starts + 1L
  if (any(len > lim)) {
    np <- ceiling(len / lim)
    off <- sequence(np, from = 0L) * lim
    st <- rep(starts, np) + off
    en <- pmin(st + lim - 1L, rep(ends, np))
    starts <- st
    ends <- en
  }
  if (as_raw) return(lapply(seq_along(starts), function(k) data[starts[k]:ends[k]]))
  if (!any(data == as.raw(0L)) && length(starts) > 1L &&
      (!l10n_info()$MBCS || !any(data >= as.raw(128L)))) {
    # fast: cut one string at the piece boundaries
    txt <- rawToChar(data)
    return(substring(txt, starts, ends))
  }
  vapply(seq_along(starts), function(k) cstr(data[starts[k]:ends[k]]), "")
}

# ---------------------------------------------------------------------------
# glibc rand()

#' glibc srand()/rand() (TYPE_3 additive feedback generator):
#' g <- glibc_rand_new(seed); glibc_rand(g) (or glibc_rand(g, n) for n
#' successive values); glibc_srand(g, seed).  RAND_MAX is 2147483647.
glibc_rand_new <- function(seed = 1) {
  g <- new.env(parent = emptyenv())
  glibc_srand(g, seed)
  g
}
glibc_srand <- function(g, seed) {
  seed <- seed %% 4294967296
  if (seed == 0) seed <- 1
  # the 31 words of the state (r[i] = 16807 * r[i-1] mod (2^31 - 1), by
  # Schrage's method: 127773 = (2^31 - 1) %/% 16807, 2836 = (2^31 - 1) %%
  # 16807), followed by the first 3 again (r[k] = r[k-31] + r[k-3])
  r <- numeric(34)
  r[1] <- if (seed >= 2147483648) seed - 4294967296 else seed
  for (i in 2:31) {
    hi <- trunc(r[i - 1] / 127773)
    lo <- r[i - 1] - hi * 127773
    word <- 16807 * lo - 2836 * hi
    if (word < 0) word <- word + 2147483647
    r[i] <- word
  }
  r[32:34] <- r[1:3]
  g$r <- r %% 4294967296
  glibc_rand(g, 10 * 31)      # (srandom discards the first 10 * 31 values)
  invisible(g)
}
glibc_rand <- function(g, n = 1) {
  buf <- c(g$r, numeric(n))
  k <- 35L
  last <- 34L + n
  # r[k] = r[k-31] + r[k-3]: blocks of 3 values are independent
  while (k <= last) {
    k2 <- min(k + 2L, last)
    buf[k:k2] <- (buf[(k - 31L):(k2 - 31L)] + buf[(k - 3L):(k2 - 3L)]) %% 4294967296
    k <- k2 + 1L
  }
  g$r <- buf[(last - 33L):last]
  floor(buf[35:last] / 2)
}

# ---------------------------------------------------------------------------
# printf

# Parse a printf format into literal pieces and conversion specifications.
.fmt_parse <- function(fmt) {
  f <- charToRaw(fmt)
  fi <- as.integer(f)
  nf <- length(fi)
  lits <- list()
  conv <- character(0); flags <- character(0)
  width <- numeric(0); prec <- numeric(0); lmod <- integer(0)
  ffmt <- character(0)          # pieces of the format of the fast path
  kinds <- integer(0)           # per argument (see below)
  fast <- TRUE
  lit <- raw(0)
  flit <- character(0)
  pos <- 1L
  addlit <- function(bytes) {
    lit <<- c(lit, bytes)
    ffmt <<- c(ffmt, gsub("%", "%%", rawToChar(bytes), fixed = TRUE))
  }
  while (pos <= nf) {
    j <- match(37L, fi[pos:nf])
    if (is.na(j)) {
      addlit(f[pos:nf])
      break
    }
    j <- pos + j - 1L
    if (j > pos) addlit(f[pos:(j - 1L)])
    q <- j + 1L
    f0 <- q
    while (q <= nf && fi[q] %in% c(45L, 43L, 32L, 35L, 48L)) q <- q + 1L
    fl <- if (q > f0) rawToChar(f[f0:(q - 1L)]) else ""
    w <- -1
    if (q <= nf && fi[q] == 42L) {
      w <- -2
      q <- q + 1L
    } else if (q <= nf && fi[q] >= 48L && fi[q] <= 57L) {
      w <- 0
      while (q <= nf && fi[q] >= 48L && fi[q] <= 57L) {
        w <- w * 10 + fi[q] - 48
        q <- q + 1L
      }
    }
    pr <- -1
    if (q <= nf && fi[q] == 46L) {
      q <- q + 1L
      if (q <= nf && fi[q] == 42L) {
        pr <- -2
        q <- q + 1L
      } else {
        pr <- 0
        while (q <= nf && fi[q] >= 48L && fi[q] <= 57L) {
          pr <- pr * 10 + fi[q] - 48
          q <- q + 1L
        }
      }
    }
    lm <- 0L
    while (q <= nf && fi[q] %in% .LENMODS) {
      lm <- if (fi[q] == 104L) lm + 1L else 3L       # 'h', 'hh'; long
      q <- q + 1L
    }
    lm <- min(lm, 3L)
    cc <- if (q <= nf) rawToChar(f[q]) else ""
    if (cc == "%") {                    # "%%" (glibc ignores flags/width)
      addlit(charToRaw("%"))
      pos <- q + 1L
      next
    }
    if (!nzchar(cc) || !grepl(cc, "diuxXoceEfFgGaAs", fixed = TRUE)) {
      # not a supported conversion: printed literally (as glibc)
      addlit(f[j:min(q, nf)])
      pos <- q + 1L
      next
    }
    lits[[length(lits) + 1L]] <- lit
    lit <- raw(0)
    conv <- c(conv, cc); flags <- c(flags, fl)
    width <- c(width, w); prec <- c(prec, pr); lmod <- c(lmod, lm)
    if (w == -2) kinds <- c(kinds, 0L)
    if (pr == -2) kinds <- c(kinds, 0L)
    if (w == -2 || pr == -2 || lm == 1L || lm == 2L) fast <- FALSE
    sp <- paste0("%", if (cc == "u") gsub("[+ ]", "", fl) else fl,
                 if (w >= 0) w else "", if (pr >= 0) paste0(".", pr) else "")
    k <- switch(cc, d = , i = 1L, u = , x = , X = , o = 2L, s = 5L, c = 6L, 4L)
    kinds <- c(kinds, k)
    if (k == 6L) fast <- FALSE
    rc <- switch(cc, i = "d", u = "d", F = "f", cc)
    ffmt <- c(ffmt, paste0(sp, rc))
    pos <- q + 1L
  }
  lits[[length(lits) + 1L]] <- lit
  specs <- paste0("%", flags, ifelse(width >= 0, width, ""),
                  ifelse(prec >= 0, paste0(".", prec), ""),
                  ifelse(conv == "F", "f", conv))
  numsel <- kinds >= 1L & kinds <= 4L
  p <- list(lits = lits, conv = conv, flags = flags, width = width,
            prec = prec, lmod = lmod, specs = specs, n = length(conv),
            nargs = length(kinds), kinds = kinds, fast = fast,
            ffmt = paste(ffmt, collapse = ""),
            numidx = which(numsel), stridx = which(kinds == 5L))
  nk <- kinds[numsel]
  p$intsel <- nk == 1L | nk == 2L
  p$unssel <- nk == 2L
  p$hasint <- any(p$intsel)
  p$hasuns <- any(p$unssel)
  p$strwp <- any(conv == "s" & (width >= 0 | prec >= 0))
  p$allnum <- all(numsel)
  p$nolits <- all(lengths(lits) == 0L)
  p$litstr <- vapply(lits, function(l) if (length(l) == 0L) "" else
    if (any(l == as.raw(0L))) NA_character_ else rawToChar(l), "")
  p
}

.fmt_get <- function(fmt) {
  if (!nzchar(fmt)) return(.fmt_parse(fmt))   # ("" cannot be a cache key)
  p <- .cstd$fmt_cache[[fmt]]
  if (is.null(p)) {
    p <- .fmt_parse(fmt)
    assign(fmt, p, envir = .cstd$fmt_cache)
  }
  p
}

#' C sprintf(fmt, ...) with glibc semantics; returns a raw vector.
#'
#' Conversions: %d %i %u %x %X %o %c %s %e %E %f %F %g %G %a %A %%, with
#' flags (- + space # 0), field width and precision (either may be *), and
#' length modifiers (hh h l ll L q j z t).  Arguments: numbers (doubles,
#' integers, logicals) for the numeric conversions and %c, character
#' strings or raw vectors (byte strings; printed up to the first NUL) for
#' %s, NULL for a C NULL pointer ("(null)").  As in C:
#'   * integer conversions print integer values (non-integers are
#'     truncated toward zero; NaN prints INT_MIN, or LONG_MIN with l);
#'   * %u, %x, %o print the unsigned value (negative numbers are taken
#'     modulo 2^32, 2^64 with l/ll, 2^16 with h, 2^8 with hh); %hd and
#'     %hhd wrap to short and char;
#'   * %c prints one byte (a number modulo 256, or the first byte of a
#'     string);
#'   * infinities and NaNs print inf, -inf, nan, -nan (INF, NAN), the sign
#'     of a NaN being its sign bit (0/0 is -nan, R's NaN constant is nan).
#' The format is the C format with R escapes already interpreted ("\n" is
#' a newline); data must be passed as arguments, never in the format.
csprintf <- function(fmt, ...) {
  p <- if (nzchar(fmt)) .cstd$fmt_cache[[fmt]]
  if (is.null(p)) p <- .fmt_get(fmt)
  na <- ...length()
  if (p$fast && na == p$nargs) {
    ok <- TRUE
    if (p$allnum) {
      # all conversions numeric: one vector of the arguments
      if (na > 0L) {
        x <- c(...)
        ok <- is.numeric(x) && length(x) == na && all(is.finite(x))
        if (ok && p$hasint) {
          xi <- x[p$intsel]
          ok <- all(xi == trunc(xi)) && all(abs(xi) < 2147483648)
          if (ok && p$hasuns) ok <- all(x[p$unssel] >= 0)
        }
      }
    } else if (na > 0L) {
      args <- list(...)
      if (length(p$numidx)) {
        x <- unlist(args[p$numidx], use.names = FALSE)
        ok <- is.numeric(x) && length(x) == length(p$numidx) && all(is.finite(x))
        if (ok && p$hasint) {
          xi <- x[p$intsel]
          ok <- all(xi == trunc(xi)) && all(abs(xi) < 2147483648)
          if (ok && p$hasuns) ok <- all(x[p$unssel] >= 0)
        }
      }
      if (ok && length(p$stridx)) {
        for (k in p$stridx) {
          a <- args[[k]]
          if (!is.character(a) || length(a) != 1L || is.na(a) ||
              (p$strwp && grepl("[^ -~]", a, useBytes = TRUE))) {
            ok <- FALSE
            break
          }
        }
      }
    }
    if (ok) {
      s <- if (na) sprintf(p$ffmt, ...) else sprintf(p$ffmt)
      return(charToRaw(s))
    }
  }
  args <- list(...)
  out <- vector("list", 2L * p$n + 1L)
  out[[1L]] <- p$lits[[1L]]
  ai <- 0L
  for (k in seq_len(p$n)) {
    fl <- p$flags[k]
    w <- p$width[k]
    pr <- p$prec[k]
    if (w == -2) {
      ai <- ai + 1L
      w <- if (ai <= na) trunc(as.numeric(args[[ai]])[1L]) else 0
      if (w < 0) {
        fl <- paste0(fl, "-")
        w <- -w
      }
    }
    if (pr == -2) {
      ai <- ai + 1L
      pr <- if (ai <= na) trunc(as.numeric(args[[ai]])[1L]) else 0
      if (pr < 0) pr <- -1
    }
    ai <- ai + 1L
    x <- if (ai <= na) args[[ai]] else 0
    cv <- p$conv[k]
    out[[2L * k]] <- if (cv == "s") {
      .cfmt_s(fl, w, pr, x)
    } else if (cv == "c") {
      .cfmt_c(fl, w, x)
    } else {
      charToRaw(.cfmt_num(cv, fl, w, pr, p$lmod[k], x[1L]))
    }
    out[[2L * k + 1L]] <- p$lits[[k + 1L]]
  }
  unlist(out, use.names = FALSE)
}

#' Vectorized C formatting: like csprintf() but the arguments are vectors
#' (recycled to a common length) and the result is a character vector, one
#' element per row (no `*` widths; %s takes character vectors; %c numeric
#' codes 1-255).  For large tables (e.g. rdsamp): paste the result with
#' collapse = "" and write it with cout().
csprintf_v <- function(fmt, ...) {
  p <- .fmt_get(fmt)
  args <- list(...)
  if (any(p$width == -2 | p$prec == -2))
    stop("csprintf_v: '*' widths are not supported")
  if (anyNA(p$litstr)) stop("csprintf_v: NUL in format")
  n <- if (length(args)) max(lengths(args)) else 1L
  if (length(args) && min(lengths(args)) == 0L) return(character(0))
  pieces <- vector("list", 2L * p$n + 1L)
  pieces[[1L]] <- p$litstr[1L]
  for (k in seq_len(p$n)) {
    x <- if (k <= length(args)) args[[k]] else 0
    cv <- p$conv[k]
    pieces[[2L * k]] <- if (cv == "s") {
      x <- as.character(x)
      if (p$width[k] >= 0 || p$prec[k] >= 0) {
        vapply(x, function(s) rawToChar(.cfmt_s(p$flags[k], p$width[k], p$prec[k], s)), "",
               USE.NAMES = FALSE)
      } else x
    } else if (cv == "c") {
      vapply(x, function(s) cstr(.cfmt_c(p$flags[k], p$width[k], s)), "", USE.NAMES = FALSE)
    } else {
      .cfmt_num(cv, p$flags[k], p$width[k], p$prec[k], p$lmod[k], x)
    }
    pieces[[2L * k + 1L]] <- p$litstr[k + 1L]
  }
  r <- do.call(paste0, pieces)
  if (length(r) < n) r <- rep_len(r, n)
  r
}

# Sign bit of NaN values (vectorized).
.nan_neg <- function(x) {
  b <- writeBin(as.double(x), raw(), endian = "little")
  b[seq.int(8L, by = 8L, length.out = length(x))] >= as.raw(0x80)
}

.pad <- function(s, flags, width) {
  if (width <= 0) return(s)
  n <- width - nchar(s, type = "bytes")
  k <- n > 0
  if (!any(k)) return(s)
  sp <- strrep(" ", pmax(n, 0))
  if (grepl("-", flags, fixed = TRUE)) paste0(s, sp) else paste0(sp, s)
}

# Format numbers with a numeric conversion (vectorized over x); returns a
# character vector.
.cfmt_num <- function(conv, flags, width, prec, lmod, x) {
  if (is.character(x)) x <- as.numeric(vapply(x, function(s) {
    b <- charToRaw(s)
    if (length(b)) as.integer(b[1L]) else 0L
  }, 0L))
  if (is.raw(x)) x <- as.numeric(x)
  x <- as.double(x)
  if (length(x) == 0L) x <- 0
  if (conv %in% c("d", "i")) return(.cfmt_int(conv, flags, width, prec, lmod, x, TRUE))
  if (conv %in% c("u", "x", "X", "o")) return(.cfmt_int(conv, flags, width, prec, lmod, x, FALSE))
  spec <- paste0("%", flags, if (width >= 0) width else "",
                 if (prec >= 0) paste0(".", prec) else "",
                 if (conv == "F") "f" else conv)
  fin <- is.finite(x)
  if (all(fin)) return(sprintf(spec, x))
  out <- character(length(x))
  if (any(fin)) out[fin] <- sprintf(spec, x[fin])
  y <- x[!fin]
  isn <- is.na(y)
  neg <- ifelse(isn, .nan_neg(y), y < 0)
  txt <- ifelse(isn, "nan", "inf")
  if (conv %in% c("E", "F", "G", "A")) txt <- toupper(txt)
  sg <- if (grepl("+", flags, fixed = TRUE)) "+" else if (grepl(" ", flags, fixed = TRUE)) " " else ""
  txt <- paste0(ifelse(neg, "-", sg), txt)
  out[!fin] <- .pad(txt, flags, width)
  out
}

.hexword <- function(w, upper = FALSE, pad8 = FALSE) {
  big <- w == 2147483648
  wi <- as.integer(ifelse(big, 0, ifelse(w > 2147483648, w - 4294967296, w)))
  r <- sprintf(if (pad8) "%08x" else "%x", wi)
  if (any(big)) r[big] <- "80000000"
  if (upper) toupper(r) else r
}

# Digits of unsigned 64-bit values given as 32-bit words (vectorized).
.u64_digits <- function(hi, lo, conv) {
  if (conv == "x" || conv == "X") {
    up <- conv == "X"
    return(ifelse(hi > 0, paste0(.hexword(hi, up), .hexword(lo, up, TRUE)), .hexword(lo, up)))
  }
  if (conv == "o") {
    # (in groups of 30 bits: 10 octal digits)
    lo30 <- lo %% 2^30
    top <- hi * 4 + (lo - lo30) / 2^30
    th <- floor(top / 2^30)
    tl <- top - th * 2^30
    tops <- ifelse(th > 0, paste0(sprintf("%o", as.integer(th)), sprintf("%010o", as.integer(tl))),
                   sprintf("%o", as.integer(tl)))
    return(ifelse(top > 0, paste0(tops, sprintf("%010o", as.integer(lo30))),
                  sprintf("%o", as.integer(lo30))))
  }
  # decimal
  .u64_dec(hi, lo)
}

# Decimal digits of hi * 2^32 + lo (hi, lo: whole numbers in [0, 2^32),
# vectorized), computed exactly in base-1e5 limbs so that no number of
# more than 5 digits is formatted by sprintf.
.u64_dec <- function(hi, lo) {
  h1 <- floor(hi / 1e5)
  h0 <- hi - h1 * 1e5
  l1 <- floor(lo / 1e5)
  l0 <- lo - l1 * 1e5
  # 2^32 = 42949 * 1e5 + 67296
  t0 <- h0 * 67296 + l0
  t1 <- h0 * 42949 + h1 * 67296 + l1 + floor(t0 / 1e5)
  t2 <- h1 * 42949 + floor(t1 / 1e5)
  d3 <- floor(t2 / 1e5)
  r <- paste0(sprintf("%.0f", d3), sprintf("%05.0f", t2 %% 1e5), sprintf("%05.0f", t1 %% 1e5),
              sprintf("%05.0f", t0 %% 1e5))
  sub("^0+(?=[0-9])", "", r, perl = TRUE)
}

# Integer conversions (vectorized).
.cfmt_int <- function(conv, flags, width, prec, lmod, x, signed) {
  bad <- !is.finite(x)
  if (signed) {
    if (any(bad)) x[bad] <- if (lmod == 3L) LONG_MIN else -2^31
    x <- trunc(x)
    if (lmod == 1L) x <- cint16(x) else if (lmod == 2L) x <- cint8(x)
    small <- abs(x) < 2147483648
  } else {
    if (any(bad)) x[bad] <- 0
    x <- trunc(x)
    if (lmod == 0L) x <- x %% 4294967296
    else if (lmod == 1L) x <- x %% 65536
    else if (lmod == 2L) x <- x %% 256
    small <- x >= 0 & x < 2147483648
  }
  if (conv == "u") flags <- gsub("[+ ]", "", flags)
  spec <- paste0("%", flags, if (width >= 0) width else "",
                 if (prec >= 0) paste0(".", prec) else "",
                 switch(conv, i = "d", u = "d", conv))
  if (all(small)) return(sprintf(spec, as.integer(x)))
  out <- character(length(x))
  if (any(small)) out[small] <- sprintf(spec, as.integer(x[small]))
  y <- x[!small]
  if (signed) {
    a <- abs(y)
    digits <- sprintf("%.0f", a)
    u <- a < 2^64
    if (any(u)) {
      hi <- floor(a[u] / 4294967296)
      digits[u] <- .u64_dec(hi, a[u] - hi * 4294967296)
    }
    sg <- ifelse(y < 0, "-", if (grepl("+", flags, fixed = TRUE)) "+"
                 else if (grepl(" ", flags, fixed = TRUE)) " " else "")
    pre <- ""
  } else {
    hi <- floor(x[!small] / 4294967296)
    lo <- x[!small] - hi * 4294967296
    hi <- hi %% 4294967296
    digits <- .u64_digits(hi, lo, conv)
    sg <- ""
    pre <- ""
    if (grepl("#", flags, fixed = TRUE)) {
      if (conv == "x") pre <- "0x" else if (conv == "X") pre <- "0X"
    }
  }
  if (prec >= 0) {
    nd <- nchar(digits)
    digits <- ifelse(nd < prec, paste0(strrep("0", pmax(prec - nd, 0)), digits), digits)
  }
  if (!signed && conv == "o" && grepl("#", flags, fixed = TRUE))
    digits <- ifelse(substr(digits, 1L, 1L) == "0", digits, paste0("0", digits))
  body <- paste0(sg, pre, digits)
  if (width > 0) {
    n <- width - nchar(body)
    if (grepl("-", flags, fixed = TRUE)) {
      body <- paste0(body, strrep(" ", pmax(n, 0)))
    } else if (grepl("0", flags, fixed = TRUE) && prec < 0) {
      body <- paste0(sg, pre, strrep("0", pmax(n, 0)), digits)
    } else {
      body <- paste0(strrep(" ", pmax(n, 0)), body)
    }
  }
  out[!small] <- body
  out
}

# %c: one byte, padded with spaces.
.cfmt_c <- function(flags, width, x) {
  b <- if (is.character(x)) {
    r <- charToRaw(x[1L])
    if (length(r)) r[1L] else as.raw(0L)
  } else if (is.raw(x)) {
    if (length(x)) x[1L] else as.raw(0L)
  } else if (length(x) == 0L || !is.finite(x[1L])) {
    as.raw(0L)
  } else as.raw(trunc(x[1L]) %% 256)
  .padraw(b, flags, width)
}

# %s: a byte string (up to its first NUL), NULL as "(null)".
.cfmt_s <- function(flags, width, prec, x) {
  if (is.null(x)) {
    b <- if (prec >= 0 && prec < 6) raw(0) else charToRaw("(null)")
  } else {
    b <- if (is.raw(x)) x else if (is.character(x)) {
      if (length(x) == 0L || is.na(x[1L])) raw(0) else charToRaw(x[1L])
    } else charToRaw(as.character(x[1L]))
    z <- match(as.raw(0L), b)
    if (!is.na(z)) b <- b[seq_len(z - 1L)]
    if (prec >= 0 && prec < length(b)) b <- b[seq_len(prec)]
  }
  .padraw(b, flags, width)
}

.padraw <- function(b, flags, width) {
  n <- width - length(b)
  if (n <= 0) return(b)
  sp <- rep(as.raw(32L), n)
  if (grepl("-", flags, fixed = TRUE)) c(b, sp) else c(sp, b)
}

# ---------------------------------------------------------------------------
# Standard input and output

.open_std <- function(which) {
  path <- if (which == 1L) "/dev/stdout" else "/dev/stderr"
  con <- NULL
  if (.Platform$OS.type == "unix") {
    con <- tryCatch(suppressWarnings(file(path, open = "ab", raw = TRUE)),
                    error = function(e) NULL)
  }
  if (is.null(con)) con <- FALSE        # fall back to the R console streams
  con
}

.write_std <- function(which, b) {
  if (which == 1L) return(.write_stdout(b))
  con <- .cstd$err_con
  if (is.null(con)) {
    con <- .open_std(2L)
    .cstd$err_con <- con
  }
  if (isFALSE(con)) {
    # (no binary access to the standard streams: NUL bytes are lost)
    cat(rawToChar(b[b != as.raw(0L)]), file = stderr())
    return(invisible())
  }
  writeBin(b, con)
  flush(con)
  invisible()
}

# wfdb-x: the standard output is opened for each write and closed after it,
# since R's flush() does not report a failed write and close() does.  A
# failed write or close is noted (.stdout_error); the output is then
# dropped.  A broken pipe raises R's error "ignoring SIGPIPE signal".
.write_stdout <- function(b) {
  st <- .cstd
  if (st$stdout_failed) return(invisible())
  con <- if (isFALSE(st$out_con)) FALSE else .open_std(1L)
  if (isFALSE(con)) {
    st$out_con <- FALSE
    # (no binary access to the standard streams: NUL bytes are lost)
    cat(rawToChar(b[b != as.raw(0L)]))
    return(invisible())
  }
  if (!.con_write_close(con, b)) .stdout_error()
  invisible()
}

# Write the bytes b to the connection con and close it; FALSE if the write
# or the close failed (R reports these as warnings, which are not shown).
.con_write_close <- function(con, b) {
  ok <- TRUE
  muffle <- function(w) {
    ok <<- FALSE
    invokeRestart("muffleWarning")
  }
  withCallingHandlers({
    writeBin(b, con)
    st <- close(con)
    if (is.numeric(st) && !identical(as.numeric(st), 0)) ok <- FALSE
  }, warning = muffle)
  ok
}

# wfdb-x: note that the standard output could not be written; what is left
# of the output is dropped (see app_run).
.stdout_error <- function() {
  .cstd$stdout_failed <- TRUE
  .cstd$out_parts <- vector("list", 1024L)
  .cstd$out_n <- 0L
  .cstd$out_bytes <- 0
  invisible()
}

#' Write bytes (raw) or text (character) to the standard output
#' (buffered).  cout() without argument flushes the buffer.
cout <- function(s) {
  st <- .cstd
  if (missing(s)) {
    if (st$out_n > 0L) {
      parts <- st$out_parts[seq_len(st$out_n)]
      st$out_parts <- vector("list", 1024L)
      st$out_n <- 0L
      st$out_bytes <- 0
      .write_std(1L, unlist(lapply(parts, function(p) if (is.raw(p)) p else charToRaw(p)),
                            use.names = FALSE))
    }
    return(invisible())
  }
  if (is.character(s)) {
    if (length(s) != 1L) s <- paste(s, collapse = "")
    nb <- nchar(s, type = "bytes")
  } else {
    nb <- length(s)
  }
  if (nb == 0L) return(invisible())
  n <- st$out_n + 1L
  parts <- st$out_parts          # (unbound while modified: no copy)
  st$out_parts <- NULL
  parts[[n]] <- s
  st$out_parts <- parts
  st$out_n <- n
  st$out_bytes <- st$out_bytes + nb
  if (n == 1024L || st$out_bytes >= 65536) cout()
  invisible()
}

#' Write bytes or text to the standard error output (unbuffered; the
#' standard output is flushed first).
cerr <- function(s) {
  cout()
  if (is.character(s)) s <- charToRaw(paste(s, collapse = ""))
  if (length(s)) .write_std(2L, s)
  invisible()
}

#' printf(fmt, ...) and fprintf(stderr, fmt, ...).
cprintf <- function(fmt, ...) cout(csprintf(fmt, ...))
ceprintf <- function(fmt, ...) cerr(csprintf(fmt, ...))

#' The whole standard input as a raw vector (read once; binary).  If the
#' standard input was redirected to a file (stdin_freopen), or the
#' environment variable WFDBX_STDIN names a file (for tests), that file is
#' read instead.
stdin_bytes <- function() {
  d <- .cstd$stdin_data
  if (is.null(d)) {
    name <- .cstd$stdin_path
    if (is.null(name)) name <- Sys.getenv("WFDBX_STDIN")
    if (nzchar(name)) {
      d <- tryCatch(readBin(name, "raw", file.info(name)$size), error = function(e) raw(0))
    } else {
      con <- file("stdin", open = "rb")
      parts <- list()
      repeat {
        x <- readBin(con, "raw", 1048576L)    # (1 MiB at a time)
        if (length(x) == 0L) break
        parts[[length(parts) + 1L]] <- x
      }
      close(con)
      d <- unlist(parts, use.names = FALSE)
      if (is.null(d)) d <- raw(0)
    }
    .cstd$stdin_data <- d
  }
  d
}

#' TRUE if the standard input is a regular file (as with "< file"), in
#' which C can seek; FALSE for a pipe, a terminal, or WFDBX_STDIN (which
#' stands for a pipe).  Detected through /proc/self/fd (Linux); elsewhere
#' the standard input is taken to be a pipe.
stdin_is_file <- function() {
  if (nzchar(Sys.getenv("WFDBX_STDIN"))) return(FALSE)
  p <- Sys.readlink("/proc/self/fd/0")
  if (is.na(p) || !startsWith(p, "/") || startsWith(p, "/dev/")) return(FALSE)
  isFALSE(file.info(p, extra_cols = FALSE)$isdir)
}

#' C freopen(name, "rb", stdin): the file `name` becomes the standard
#' input.  Returns FALSE (nothing changed) if it cannot be read; a
#' directory counts as unreadable (C would read it forever).  The file is
#' read when the standard input is first read (stdin_bytes()), as C reads
#' it: output files created before then may truncate it.  The WFDB_FILE of
#' the standard input ("-", wfdbio.R) is dropped, so that the library
#' reads the new one.
stdin_freopen <- function(name) {
  if (name == "-") return(TRUE)
  if (file.access(name, 4L) != 0L || dir.exists(name)) return(FALSE)
  .cstd$stdin_path <- name
  .cstd$stdin_data <- NULL
  .wfdb_io$stdin_file <- NULL
  TRUE
}

#' C getenv(): the value, or NULL if the variable is not set.
cgetenv <- function(name) {
  v <- Sys.getenv(name, unset = NA)
  if (is.na(v)) NULL else v
}

# ---------------------------------------------------------------------------
# Running tools

#' exit(status) inside a tool run by app_run(): unwinds to app_run.
cexit <- function(status = 0) {
  cond <- structure(class = c("wfdbx_exit", "condition"),
                    list(message = paste("exit", status), call = NULL, status = status))
  stop(cond)
}

#' Run a tool's main function: status <- app_run(main, argv), where argv[1]
#' is the program name and main(argv) returns the exit status (NULL counts
#' as 0) or calls cexit().  At the end, the files still open for writing
#' and the standard output are flushed (as by C's exit()).  R errors are
#' passed on (cli_main reports them).  As the C tools do first, "--legacy" as
#' the first argument is handled by wfdbx_legacy_args() (legacy mode is
#' turned on for the run, and restored to its previous setting afterwards).
#'
#' wfdb-x: at the end, in normal mode, a standard output that could not be
#' written is reported ("PROGRAM: write error on standard output"), and the
#' exit status 0 becomes 1 if the standard output or another output file
#' could not be written (see wfdbx_write_errors), as for the standard
#' tools.  Legacy mode keeps the original exit status.
app_run <- function(main, argv) {
  legacy <- wfdbx_get_legacy()
  errors <- .cstd$write_errors
  mode <- legacy
  status <- tryCatch({
                       argv <- wfdbx_legacy_args(argv)$argv
                       main(argv)
                     },
                     wfdbx_exit = function(e) e$status,
                     finally = {
                       wf_flush_all()
                       cout()
                       mode <- wfdbx_get_legacy()
                       wfdbx_set_legacy(legacy)
                     })
  if (is.null(status) || length(status) == 0L) status <- 0
  if (!mode) {
    failed <- .cstd$stdout_failed
    if (failed)
      ceprintf("%s: write error on standard output\n", basename(argv[1L]))
    if (status == 0 && (failed || .cstd$write_errors > errors)) status <- 1
  }
  status
}
