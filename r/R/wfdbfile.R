# wfdbfile.R: WFDB_FILE objects (open files, the standard input and the
# standard output) with the semantics of the C stdio functions used by the
# WFDB library (lib/wfdbio.c).
#
# Copyright (C) 1988-2013 George B. Moody (original C implementation,
# lib/wfdbio.c; revised 2010-2022 by Benjamin Moody).
# R implementation part of wfdb-x, Reza Sameni, Oct 2026.
# GNU Library General Public License, version 2 or later (see LICENSE.LIB).
#
# A WFDB_FILE is an environment (is_wfdb_file(); C NULL is NULL),
# created by wfdb_fopen() / wfdb_open() (wfdbio.R).  Fields: `name` (file
# name, "-" for the standard streams), `type` (WFDB_LOCAL = 0), `is_std`,
# `mode` ("r", "w" or "a").  The functions below take it as their first
# argument:
#
#   wf_read(f, n)          fread of up to n bytes (raw; fewer at end of file)
#   wf_readall(f)          the rest of the file (raw)
#   wf_getc(f)             next byte (0-255), or -1 at end of file
#   wf_getline(f)          wfdb_getline: next line with its newline (raw;
#                          raw(0) at end of file)
#   wf_write(f, b)         fwrite of a raw vector or character string;
#                          returns the number of bytes
#   wf_putc(f, c)          one byte (c modulo 256)
#   wf_printf(f, fmt, ...) fprintf (csprintf semantics)
#   wf_g16(f), wf_g32(f)   wfdb_g16/wfdb_g32 (PDP-11 byte order); missing
#                          bytes at end of file read as 0xFF
#   wf_p16(f, x), wf_p32(f, x)
#   wf_seek(f, off, whence)  fseek (whence 0 = SEEK_SET, 1 = SEEK_CUR,
#                          2 = SEEK_END); 0 or -1.  Positions beyond the end
#                          of the file are allowed (as in C): reads there
#                          find the end of the file, writes extend the file
#                          with zeros.
#   wf_tell(f)             ftell (-1 for the standard streams)
#   wf_flush(f), wf_feof(f), wf_ferror(f), wf_clearerr(f), wf_close(f)
#
# Reads are buffered as by glibc's stdio (blocks of 4096 bytes, its
# st_blksize; larger requests read whole blocks directly), so that a file is
# read when, and as far as, C reads it (this matters when a file is read
# while it is being rewritten); writes are collected and written in blocks.  The standard input ("-" for reading) is served from
# stdin_bytes(); it is seekable only if it is a regular file (as in C:
# stdin_is_file()), not a pipe.  Writes to the standard output ("-" for
# writing) go to cout().

.WF_BLOCK <- 65536L    # (writes)
.WF_RBLOCK <- 4096L    # (reads)

# The files open for writing (most recent last), flushed by wf_flush_all()
# when a tool exits, as C's exit() flushes every open stdio stream.
.wf_reg <- new.env(parent = emptyenv())
.wf_reg$files <- list()

wfdb_file_new <- function(con, type = 0, name = "", std = 0L, mode = "r") {
  # (no class attribute: `$` on an object with a class is dispatched, which
  # makes every field access several times slower)
  f <- new.env(parent = emptyenv())
  f$wfdb_file <- TRUE
  f$con <- con
  f$type <- type
  f$name <- name
  f$std <- std                 # 0 file, 1 standard input, 2 standard output
  f$is_std <- std != 0L
  f$mode <- mode
  f$err <- FALSE
  f$eof <- FALSE
  f$buf <- raw(0)              # read buffer
  f$bpos <- 1L                 # index in buf of the next byte
  f$blen <- 0L
  f$bstart <- 0                # file offset of buf[1]
  f$wparts <- vector("list", 64L)  # pending writes
  f$wn <- 0L
  f$wbytes <- 0
  f$wpos <- 0                  # file offset of the next byte written
  f$seekable <- FALSE          # (standard input only: see stdin_is_file)
  if (std == 1L) {
    f$buf <- stdin_bytes()
    f$blen <- length(f$buf)
    f$seekable <- stdin_is_file()
  }
  if (std == 0L && mode != "r" && !is.null(con))
    .wf_reg$files[[length(.wf_reg$files) + 1L]] <- f
  f
}

#' Flush every file open for writing (as C's exit() does: glibc flushes the
#' streams in the reverse order of their opening).
wf_flush_all <- function() {
  for (f in rev(.wf_reg$files)) {
    if (!is.null(f$con)) tryCatch(wf_flush(f), error = function(e) NULL)
  }
  invisible()
}

#' TRUE if x is a WFDB_FILE.
is_wfdb_file <- function(x) is.environment(x) && isTRUE(x$wfdb_file)

# Refill the read buffer; FALSE at end of file.
.wf_fill <- function(f) {
  if (f$std != 0L || is.null(f$con)) return(FALSE)
  f$bstart <- f$bstart + f$blen
  b <- tryCatch(readBin(f$con, "raw", .WF_RBLOCK), error = function(e) {
    f$err <- TRUE
    raw(0)
  })
  f$buf <- b
  f$bpos <- 1L
  f$blen <- length(b)
  f$blen > 0L
}

.wf_rcheck <- function(f) {
  if (f$std == 2L || f$mode != "r" || (f$std == 0L && is.null(f$con))) {
    f$err <- TRUE
    return(FALSE)
  }
  TRUE
}

wf_read <- function(f, n) {
  if (!.wf_rcheck(f)) return(raw(0))
  n <- as.integer(n)
  if (n <= 0L) return(raw(0))
  avail <- f$blen - f$bpos + 1L
  if (avail >= n) {
    b <- f$buf[f$bpos:(f$bpos + n - 1L)]
    f$bpos <- f$bpos + n
    return(b)
  }
  head <- if (avail > 0L) f$buf[f$bpos:f$blen] else raw(0)
  f$bpos <- f$blen + 1L
  need <- n - avail
  if (f$std != 0L) {
    f$eof <- TRUE
    return(head)
  }
  if (need >= .WF_RBLOCK) {
    # large read: whole blocks directly from the connection (as glibc)
    f$bstart <- f$bstart + f$blen
    f$buf <- raw(0)
    f$blen <- 0L
    f$bpos <- 1L
    count <- need - need %% .WF_RBLOCK
    rest <- tryCatch(readBin(f$con, "raw", count), error = function(e) {
      f$err <- TRUE
      raw(0)
    })
    f$bstart <- f$bstart + length(rest)
    if (length(rest) < count) {
      f$eof <- TRUE
      return(c(head, rest))
    }
    if (count == need) return(c(head, rest))
    return(c(head, rest, wf_read(f, need - count)))
  }
  if (!.wf_fill(f)) {
    f$eof <- TRUE
    return(head)
  }
  k <- min(need, f$blen)
  b <- c(head, f$buf[seq_len(k)])
  f$bpos <- k + 1L
  if (k < need) f$eof <- TRUE
  b
}

wf_readall <- function(f) {
  if (!.wf_rcheck(f)) return(raw(0))
  head <- if (f$bpos <= f$blen) f$buf[f$bpos:f$blen] else raw(0)
  f$bpos <- f$blen + 1L
  f$eof <- TRUE
  if (f$std != 0L) return(head)
  parts <- list(head)
  f$bstart <- f$bstart + f$blen
  f$buf <- raw(0)
  f$blen <- 0L
  f$bpos <- 1L
  repeat {
    sz <- suppressWarnings(file.size(f$name))
    want <- if (is.na(sz)) 1048576 else max(sz - f$bstart, 0) + 1   # (1 MiB, or the rest)
    x <- tryCatch(readBin(f$con, "raw", want), error = function(e) raw(0))
    if (length(x) == 0L) break
    parts[[length(parts) + 1L]] <- x
    f$bstart <- f$bstart + length(x)
  }
  unlist(parts, use.names = FALSE)
}

wf_getc <- function(f) {
  if (f$bpos > f$blen) {
    if (!.wf_rcheck(f) || !.wf_fill(f)) {
      f$eof <- TRUE
      return(-1L)
    }
  }
  p <- f$bpos
  f$bpos <- p + 1L
  as.integer(f$buf[p])
}

wf_getline <- function(f) {
  if (!.wf_rcheck(f)) return(raw(0))
  parts <- list()
  repeat {
    if (f$bpos > f$blen && !.wf_fill(f)) {
      f$eof <- TRUE
      break
    }
    seg <- f$buf[f$bpos:f$blen]
    k <- match(as.raw(10L), seg)
    if (!is.na(k)) {
      parts[[length(parts) + 1L]] <- seg[seq_len(k)]
      f$bpos <- f$bpos + k
      break
    }
    parts[[length(parts) + 1L]] <- seg
    f$bpos <- f$blen + 1L
    if (f$std != 0L) {
      f$eof <- TRUE
      break
    }
  }
  unlist(parts, use.names = FALSE) %||% raw(0)
}

`%||%` <- function(a, b) if (is.null(a)) b else a

# Write the pending output to the connection.
.wf_wflush <- function(f) {
  if (f$wn > 0L) {
    b <- unlist(f$wparts[seq_len(f$wn)], use.names = FALSE)
    f$wparts <- vector("list", 64L)
    f$wn <- 0L
    f$wbytes <- 0
    ok <- tryCatch({
      writeBin(b, f$con)
      TRUE
    }, error = function(e) FALSE)
    if (!ok) f$err <- TRUE
  }
  invisible()
}

wf_write <- function(f, b) {
  if (is.character(b)) b <- charToRaw(paste(b, collapse = ""))
  n <- length(b)
  if (f$std == 2L) {
    cout(b)
    return(n)
  }
  if (f$std == 1L || f$mode == "r" || is.null(f$con)) {
    f$err <- TRUE
    return(0L)
  }
  if (n == 0L) return(0L)
  k <- f$wn + 1L
  parts <- f$wparts              # (unbound while modified: no copy)
  f$wparts <- NULL
  parts[[k]] <- b
  f$wparts <- parts
  f$wn <- k
  f$wbytes <- f$wbytes + n
  f$wpos <- f$wpos + n
  if (k == 64L || f$wbytes >= .WF_BLOCK) .wf_wflush(f)
  n
}

wf_putc <- function(f, c) {
  wf_write(f, as.raw(trunc(c) %% 256))
  invisible()
}

wf_printf <- function(f, fmt, ...) {
  s <- csprintf(fmt, ...)
  wf_write(f, s)
  length(s)
}

wf_g16 <- function(f) {
  b <- as.integer(wf_read(f, 2L))
  if (length(b) < 2L) b <- c(b, 255L, 255L)[1:2]     # (EOF bytes)
  x <- b[2L] * 256 + b[1L]
  if (x >= 32768) x - 65536 else x
}

# As in the other ports: x * 65536 + (y & 0xFFFF), x and y the signed
# 16-bit words read.
wf_g32 <- function(f) {
  x <- wf_g16(f)
  y <- wf_g16(f)
  x * 65536 + y %% 65536
}

wf_p16 <- function(f, x) {
  x <- x %% 65536
  wf_write(f, as.raw(c(x %% 256, x %/% 256)))
  invisible()
}

wf_p32 <- function(f, x) {
  x <- x %% 4294967296
  wf_p16(f, x %/% 65536)
  wf_p16(f, x %% 65536)
  invisible()
}

wf_seek <- function(f, offset, whence = 0) {
  if (f$std == 1L && f$seekable) {
    # a standard input held in memory (from its start): positions beyond
    # its end read as the end of the file
    target <- if (whence == 0) offset else if (whence == 1) f$bpos - 1 + offset else
      f$blen + offset
    if (target < 0) return(-1)
    f$bpos <- as.integer(min(target, f$blen)) + 1L
    f$eof <- FALSE
    return(0)
  }
  if (f$std != 0L || is.null(f$con)) return(-1)
  if (f$mode == "r") {
    cur <- f$bstart + f$bpos - 1
    target <- if (whence == 0) offset else if (whence == 1) cur + offset else {
      sz <- suppressWarnings(file.size(f$name))
      if (is.na(sz)) return(-1)
      sz + offset
    }
    if (target < 0) return(-1)
    f$eof <- FALSE
    if (target >= f$bstart && target <= f$bstart + f$blen) {
      f$bpos <- as.integer(target - f$bstart) + 1L
      return(0)
    }
    ok <- tryCatch({
      seek(f$con, target, origin = "start", rw = "read")
      # (a failed seek, e.g. past the largest file size of the file system,
      # leaves the position unchanged without an error)
      isTRUE(seek(f$con, NA, rw = "read") == target)
    }, error = function(e) FALSE)
    if (!ok) return(-1)
    f$bstart <- target
    f$buf <- raw(0)
    f$blen <- 0L
    f$bpos <- 1L
    return(0)
  }
  # output files
  .wf_wflush(f)
  if (f$mode == "a") {
    flush(f$con)
    return(0)
  }
  target <- if (whence == 0) offset else if (whence == 1) f$wpos + offset else {
    flush(f$con)
    sz <- suppressWarnings(file.size(f$name))
    if (is.na(sz)) return(-1)
    sz + offset
  }
  if (target < 0) return(-1)
  ok <- tryCatch({
    flush(f$con)
    seek(f$con, target, origin = "start", rw = "write")
    TRUE
  }, error = function(e) FALSE)
  if (!ok) return(-1)
  f$wpos <- target
  f$eof <- FALSE
  0
}

wf_tell <- function(f) {
  if (f$std == 1L && f$seekable) return(f$bpos - 1)
  if (f$std != 0L || is.null(f$con)) return(-1)
  if (f$mode == "r") return(f$bstart + f$bpos - 1)
  if (f$mode == "a") {
    .wf_wflush(f)
    flush(f$con)
    sz <- suppressWarnings(file.size(f$name))
    return(if (is.na(sz)) -1 else sz)
  }
  f$wpos
}

wf_flush <- function(f) {
  if (f$std == 2L) {
    cout()
  } else if (f$std == 0L && !is.null(f$con) && f$mode != "r") {
    .wf_wflush(f)
    flush(f$con)
  }
  0
}

wf_feof <- function(f) f$eof
wf_ferror <- function(f) f$err
wf_clearerr <- function(f) {
  f$err <- FALSE
  f$eof <- FALSE
  invisible()
}

wf_close <- function(f) {
  if (f$std == 2L) {
    cout()
    return(0)
  }
  if (f$std != 0L || is.null(f$con)) return(0)
  st <- 0
  if (f$mode != "r") {
    .wf_wflush(f)
    keep <- !vapply(.wf_reg$files, identical, NA, f)
    .wf_reg$files <- .wf_reg$files[keep]
  }
  if (f$err) st <- -1
  tryCatch(close(f$con), error = function(e) st <<- -1)
  f$con <- NULL
  st
}
