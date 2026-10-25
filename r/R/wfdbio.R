# wfdbio.R: low-level I/O of the WFDB library (port of lib/wfdbio.c): the
# WFDB path, file lookup (wfdb_open), error reporting (wfdb_error,
# wfdberror), version and configuration strings.
#
# Copyright (C) 1988-2013 George B. Moody (original C implementation,
# lib/wfdbio.c; revised 2010-2022 by Benjamin Moody).
# R implementation part of wfdb-x, Reza Sameni, Oct 2026.
# GNU Library General Public License, version 2 or later (see LICENSE.LIB).
#
# Remote files (http://, https:// path components or record names) are not
# supported, as in the C++ and MATLAB ports: wfdb_fopen() returns NULL for
# URLs, so remote files are never found.
#
# wfdb-x: wfdb_open opens an input file named by an absolute path directly
# (the C library searched for it in each directory of the WFDB path, so that
# it was found only if the path contained an empty component or the current
# directory was the root), and output files can be created in a directory
# set with wfdbx_set_output_dir; decided by Reza Sameni after a code review,
# Oct 2026.  The original behavior remains available with --legacy (see
# docs/DIVERGENCES.md).

WFDB_MAJOR <- 10
WFDB_MINOR <- 7
WFDB_RELEASE <- 0
WFDB_VERSION <- "10.7.0"
# The C library reports the date on which it was compiled; wfdb-x reports
# the date of the WFDB release it reproduces.
WFDB_BUILD_DATE <- "Jun 10 2022"

WFDB_LOCAL <- 0
WFDB_NET <- 1

WFDB_READ <- 0
WFDB_WRITE <- 1
WFDB_AHA_READ <- 2
WFDB_AHA_WRITE <- 3
WFDB_APPEND <- 4

DEFWFDB <- ". /usr/local/database http://physionet.org/physiobank/database"
DEFWFDBCAL <- "wfdbcal"
WFDB_MAXRNL <- 50

# State of this module (wfdbio_reset() restores it).
.wfdb_io <- new.env(parent = emptyenv())

wfdbio_reset <- function() {
  st <- .wfdb_io
  st$wfdbpath <- NULL          # current WFDB path (NULL: not yet read)
  st$wfdbpath_init <- NULL     # value from the first getwfdb()
  st$path_prefix <- character(0)
  st$path_type <- numeric(0)
  st$error_print <- TRUE
  st$error_flag <- FALSE
  st$error_message <- NULL     # raw
  st$wfdb_filename <- NULL
  st$irec <- ""
  st$mem_behavior <- 1
  st$stdin_file <- NULL
  st$stdout_file <- NULL
  st$driver <- NULL            # path of inst/bin/wfdbx.R (set by the driver)
  st$output_dir <- NULL        # wfdb-x: see wfdbx_set_output_dir
  invisible()
}
wfdbio_reset()

# ---------------------------------------------------------------------------
# WFDB path

#' Restore the WFDB path to the value returned by the first getwfdb().
resetwfdb <- function() {
  if (!is.null(.wfdb_io$wfdbpath_init)) .wfdb_io$wfdbpath <- .wfdb_io$wfdbpath_init
  invisible()
}

#' The WFDB path (from $WFDB, or DEFWFDB if it is not set).
getwfdb <- function() {
  st <- .wfdb_io
  if (is.null(st$wfdbpath)) {
    p <- cgetenv("WFDB")
    if (is.null(p)) p <- DEFWFDB
    p <- getiwfdb(p)
    st$wfdbpath <- p
    st$wfdbpath_init <- p
    wfdb_parse_path(p)
  }
  st$wfdbpath
}

#' Change the WFDB path (NULL: from $WFDB or the default).
setwfdb <- function(p) {
  if (is.null(p)) {
    p <- cgetenv("WFDB")
    if (is.null(p)) p <- DEFWFDB
  }
  Sys.setenv(WFDB = p)
  if (is.null(cgetenv("WFDBCAL"))) Sys.setenv(WFDBCAL = DEFWFDBCAL)
  if (is.null(cgetenv("WFDBANNSORT"))) Sys.setenv(WFDBANNSORT = "1")
  if (is.null(cgetenv("WFDBGVMODE"))) Sys.setenv(WFDBGVMODE = "0")
  p <- getiwfdb(p)
  .wfdb_io$wfdbpath <- p
  wfdb_parse_path(p)
  invisible()
}

#' Expand indirect WFDB paths ("@file").
getiwfdb <- function(p) {
  i <- 0
  while (i < 10 && !is.null(p) && startsWith(p, "@")) {
    fn <- substr(p, 2L, nchar(p, type = "bytes"))
    d <- if (nzchar(fn) && file.exists(fn) && !dir.exists(fn))
      tryCatch(readBin(fn, "raw", file.size(fn)), error = function(e) NULL) else NULL
    if (is.null(d)) {
      p <- ""
    } else {
      n <- length(d)
      while (n > 0L && (d[n] == as.raw(13L) || d[n] == as.raw(10L))) n <- n - 1L
      p <- cstr(d[seq_len(n)])
    }
    i <- i + 1
  }
  if (!is.null(p) && startsWith(p, "@")) {
    wfdb_error("getwfdb: files nested too deeply\n")
    p <- ""
  }
  p
}

#' Split a WFDB path into its components (path_prefix, path_type).
wfdb_parse_path <- function(p) {
  st <- .wfdb_io
  st$path_prefix <- character(0)
  st$path_type <- numeric(0)
  if (is.null(p)) return(0)
  b <- as.integer(charToRaw(p))
  n <- length(b)
  pre <- character(0)
  typ <- numeric(0)
  q <- 1L
  while (q <= n) {
    while (q <= n && b[q] %in% c(32L, 9L, 10L, 13L)) q <- q + 1L
    start <- q
    q <- q - 1L
    ctype <- WFDB_LOCAL
    slashes <- 0
    repeat {
      q <- q + 1L
      c <- if (q <= n) b[q] else 0L
      if (c == 58L) {                           # ':'
        if (q + 2L <= n && b[q + 1L] == 47L && b[q + 2L] == 47L) {
          ctype <- WFDB_NET
        } else if (ctype != WFDB_NET || slashes > 2) {
          break
        }
      } else if (c %in% c(59L, 32L, 9L, 10L, 13L, 0L)) {
        break
      } else if (c == 47L) {
        slashes <- slashes + 1
      }
    }
    pre <- c(pre, if (q > start) rawToChar(as.raw(b[start:(q - 1L)])) else "")
    typ <- c(typ, ctype)
    if (q <= n) q <- q + 1L
  }
  st$path_prefix <- pre
  st$path_type <- typ
  0
}

# strncmp(a, b, n) == 0 for C strings a and b.
.strncmp_eq <- function(a, b, n) {
  if (n <= 0) return(TRUE)
  ab <- c(as.integer(charToRaw(a)), 0L)
  bb <- c(as.integer(charToRaw(b)), 0L)
  for (i in seq_len(n)) {
    ca <- if (i <= length(ab)) ab[i] else 0L
    cb <- if (i <= length(bb)) bb[i] else 0L
    if (ca != cb) return(FALSE)
    if (ca == 0L) return(TRUE)
  }
  TRUE
}

#' Add the directory of file name s to the WFDB path (see wfdbio.c).
wfdb_addtopath <- function(s) {
  if (is.null(s) || !nzchar(s)) return(invisible())
  b <- as.integer(charToRaw(s))
  seps <- which(b %in% c(47L, 92L, 58L))        # '/', '\\', ':'
  if (length(seps) == 0L) return(invisible())
  p <- seps[length(seps)] - 1L                  # 0-based index of the separator
  if (p == 0L) p <- 1L
  st <- .wfdb_io
  if (is.null(st$wfdbpath)) getwfdb()
  pre <- st$path_prefix
  typ <- st$path_type
  if (length(pre) == 0L) return(invisible())
  found <- NA_integer_
  for (k in seq_along(pre)) {
    if (.strncmp_eq(pre[k], s, p)) {
      if (k == 1L || (k == 2L && pre[1L] == ".")) return(invisible())
      found <- k
      break
    }
  }
  if (is.na(found)) {
    fp <- rawToChar(as.raw(b[seq_len(p)]))
    ft <- if (grepl("://", fp, fixed = TRUE)) WFDB_NET else WFDB_LOCAL
  } else {
    fp <- pre[found]
    ft <- typ[found]
    pre <- pre[-found]
    typ <- typ[-found]
  }
  if (length(pre) && pre[1L] == ".") {
    pre <- append(pre, fp, 1L)
    typ <- append(typ, ft, 1L)
  } else {
    pre <- c(fp, pre)
    typ <- c(ft, typ)
  }
  st$path_prefix <- pre
  st$path_type <- typ
  invisible()
}

# ---------------------------------------------------------------------------
# Errors

#' Suppress WFDB library error messages.
wfdbquiet <- function() {
  .wfdb_io$error_print <- FALSE
  invisible()
}

#' Enable WFDB library error messages.
wfdbverbose <- function() {
  .wfdb_io$error_print <- TRUE
  invisible()
}

#' The most recent WFDB library error message (character).
wfdberror <- function() {
  st <- .wfdb_io
  if (!st$error_flag) {
    st$error_message <- csprintf("WFDB library version %d.%d.%d (%s).\n",
                                 WFDB_MAJOR, WFDB_MINOR, WFDB_RELEASE, WFDB_BUILD_DATE)
  }
  cstr(st$error_message)
}

#' Report an error (printf-style): saved for wfdberror(), and printed on the
#' standard error output unless wfdbquiet() is in effect.
wfdb_error <- function(fmt, ...) {
  st <- .wfdb_io
  st$error_flag <- TRUE
  st$error_message <- csprintf(fmt, ...)
  if (st$error_print) cerr(st$error_message)
  invisible()
}

wfdbmemerr <- function(behavior) {
  .wfdb_io$mem_behavior <- behavior
  invisible()
}

#' The behavior on memory errors set by wfdbmemerr() (initially 1).
wfdb_me_fatal <- function() .wfdb_io$mem_behavior

wfdbversion <- function() WFDB_VERSION
wfdbldflags <- function() ""
wfdbcflags <- function() ""
wfdbdefwfdb <- function() DEFWFDB
wfdbdefwfdbcal <- function() DEFWFDBCAL

#' The pathname of a WFDB file of type s for a record (NULL if not found);
#' wfdbfile(NULL, NULL) returns the last file name tried.
wfdbfile <- function(s, record) {
  st <- .wfdb_io
  if (is.null(s) && is.null(record)) return(st$wfdb_filename)
  if (!is.null(record)) record <- wfdb_striphea(record)
  f <- wfdb_open(s, record, WFDB_READ)
  if (!is.null(f)) {
    wf_close(f)
    return(st$wfdb_filename)
  }
  NULL
}

# ---------------------------------------------------------------------------
# Opening files

#' Set the directory in which output files are created (a wfdb-x addition);
#' returns the previous one (NULL if none).  When it is set, wfdb_open
#' creates each output file (WFDB_WRITE or WFDB_APPEND mode) as
#' dir/name, where name is the name it would use otherwise (the record name
#' and the file type).  NULL or "" means none (the default: files are
#' created as named).  Not reset by wfdbquit.
wfdbx_set_output_dir <- function(dir) {
  previous <- .wfdb_io$output_dir
  .wfdb_io$output_dir <- if (is.null(dir) || !nzchar(dir)) NULL else dir
  previous
}

#' The directory set by wfdbx_set_output_dir, or NULL.
wfdbx_get_output_dir <- function() .wfdb_io$output_dir

# wfdb-x: TRUE if s is an absolute local path: on POSIX systems, one that
# begins with '/'; on MS-Windows, one that begins with 'X:\', 'X:/', '\\'
# or '/'.
.is_absolute_path <- function(s) {
  if (.Platform$OS.type == "windows") {
    if (startsWith(s, "\\\\")) return(TRUE)
    b <- charToRaw(s)
    if (length(b) >= 3L && grepl("[A-Za-z]", rawToChar(b[1L]), useBytes = TRUE) &&
        b[2L] == charToRaw(":") && b[3L] %in% charToRaw("\\/"))
      return(TRUE)
  }
  startsWith(s, "/")
}

.spr1 <- function(record, type) if (!nzchar(type)) record else paste0(record, ".", type)
.spr2 <- function(record, type) {
  if (!nzchar(type)) paste0(record, ".") else
    paste0(record, ".", rawToChar(charToRaw(type)[seq_len(min(3L, nchar(type, type = "bytes")))]))
}

# Expand %r and %Nr in a path component.
.expand_irec <- function(prefix, irec) {
  b <- as.integer(charToRaw(prefix))
  ir <- charToRaw(irec)
  n <- length(b)
  out <- raw(0)
  i <- 1L
  while (i <= n) {
    c <- b[i]
    if (c == 37L) {                         # '%'
      i <- i + 1L
      c <- if (i <= n) b[i] else 0L
      if (c == 114L) {                    # %r
        out <- c(out, ir)
        i <- i + 1L
      } else if (c >= 49L && c <= 57L && i + 1L <= n && b[i + 1L] == 114L) {  # %Nr
        out <- c(out, ir[seq_len(min(length(ir), c - 48L))])
        i <- i + 2L
      } else {
        if (c != 0L) out <- c(out, as.raw(c))
        i <- i + 1L
      }
    } else {
      out <- c(out, as.raw(c))
      i <- i + 1L
    }
  }
  rawToChar(out)
}

#' Find and open the WFDB file of type s (e.g. "hea", or "" for a file
#' named by record) for a record; mode WFDB_READ (search the WFDB path; an
#' absolute name is opened directly first, except in legacy mode),
#' WFDB_WRITE or WFDB_APPEND (create the file as named, within the output
#' directory if one is set).  Returns a WFDB_FILE (see wfdbfile.R) or NULL.
#' The record "-" is the standard input (reading) or output (writing).
wfdb_open <- function(s, record, mode) {
  if (is.null(s)) s <- ""
  st <- .wfdb_io
  if (is.null(record) || !nzchar(record)) {
    if (nzchar(s)) {
      record <- s
      s <- ""
    } else {
      return(NULL)
    }
  }
  if (record == "-") {
    if (mode == WFDB_READ) {
      if (is.null(st$stdin_file)) {
        p <- .cstd$stdin_path
        st$stdin_file <- if (is.null(p)) {
          wfdb_file_new(NULL, WFDB_LOCAL, "-", 1L, "r")
        } else {
          # a standard input redirected to a file (stdin_freopen) can seek
          con <- tryCatch(file(p, "rb"), error = function(e) NULL)
          wfdb_file_new(con, WFDB_LOCAL, "-", 0L, "r")
        }
      }
      return(st$stdin_file)
    }
    if (is.null(st$stdout_file)) st$stdout_file <- wfdb_file_new(NULL, WFDB_LOCAL, "-", 2L, "w")
    return(st$stdout_file)
  }
  r <- record
  rb <- charToRaw(record)
  rlen <- length(rb)
  if (rlen > 1L && rb[rlen] == as.raw(47L)) {
    # "dir/" stands for "dir/dir"
    p <- rlen
    q <- p - 1L
    while (q > 1L) {
      if (rb[q] == as.raw(47L)) {
        q <- q + 1L
        break
      }
      q <- q - 1L
    }
    if (q < p) r <- paste0(record, rawToChar(rb[q:(p - 1L)]))
  }
  if (mode == WFDB_WRITE || mode == WFDB_APPEND) {
    st$wfdb_filename <- .spr1(r, s)
    # wfdb-x: in the output directory, if one was set
    if (!is.null(st$output_dir)) st$wfdb_filename <- paste0(st$output_dir, "/", st$wfdb_filename)
    return(wfdb_fopen(st$wfdb_filename, if (mode == WFDB_WRITE) "wb" else "ab"))
  }
  if (length(st$path_prefix) == 0L) getwfdb()
  if (startsWith(r, "http://") || startsWith(r, "https://")) {
    st$wfdb_filename <- .spr1(r, s)
    f <- wfdb_fopen(st$wfdb_filename, "rb")
    if (!is.null(f)) {
      wfdb_addtopath(st$wfdb_filename)
      return(f)
    }
  }
  # wfdb-x: an absolute local path is opened directly (and, as for a URL,
  # its directory is added to the WFDB path); if it cannot be, the WFDB path
  # is searched as in the C library (and in legacy mode).
  if (.is_absolute_path(r) && !wfdbx_get_legacy()) {
    st$wfdb_filename <- .spr1(r, s)
    f <- wfdb_fopen(st$wfdb_filename, "rb")
    if (!is.null(f)) {
      wfdb_addtopath(st$wfdb_filename)
      return(f)
    }
  }
  irec <- st$irec
  pre <- st$path_prefix                 # (a copy: wfdb_addtopath may change it)
  typ <- st$path_type
  for (k in seq_along(pre)) {
    b <- pre[k]
    if (grepl("%", b, fixed = TRUE)) b <- .expand_irec(b, irec)
    if (nzchar(b) && !endsWith(b, "/")) b <- paste0(b, "/")
    b <- paste0(b, r)
    st$wfdb_filename <- .spr1(b, s)
    f <- wfdb_fopen(st$wfdb_filename, "rb")
    if (!is.null(f)) {
      wfdb_addtopath(st$wfdb_filename)
      return(f)
    }
    long_filename <- st$wfdb_filename
    st$wfdb_filename <- .spr2(b, s)
    if (st$wfdb_filename != long_filename) {
      f <- wfdb_fopen(st$wfdb_filename, "rb")
      if (!is.null(f)) {
        wfdb_addtopath(st$wfdb_filename)
        return(f)
      }
    }
  }
  NULL
}

# Names that R's file() would not treat as plain file names.
.rfile_name <- function(fname) {
  if (fname %in% c("stdin", "clipboard") || startsWith(fname, "~")) paste0("./", fname) else fname
}

#' Open a file by name ("rb", "wb" or "ab"); returns a WFDB_FILE or NULL.
#' Names containing ".." and URLs are refused.  For output, missing
#' directories are created (as C does).
wfdb_fopen <- function(fname, mode) {
  if (is.null(fname) || grepl("..", fname, fixed = TRUE) ||
      grepl("://", fname, fixed = TRUE) || !nzchar(fname))
    return(NULL)
  m <- substr(mode, 1L, 1L)
  rn <- .rfile_name(fname)
  if (m == "r") {
    if (!file.exists(rn) || dir.exists(rn)) return(NULL)
    con <- tryCatch(suppressWarnings(file(rn, open = "rb", raw = TRUE)),
                    error = function(e) NULL)
    if (is.null(con)) return(NULL)
    return(wfdb_file_new(con, WFDB_LOCAL, fname, 0L, "r"))
  }
  rmode <- if (m == "a") "ab" else "wb"
  open1 <- function() tryCatch(suppressWarnings(file(rn, open = rmode, raw = TRUE)),
                               error = function(e) NULL)
  con <- if (!dir.exists(rn)) open1() else NULL
  if (is.null(con)) {
    # create the missing directories (the status is that of the last mkdir)
    stat <- 1
    b <- charToRaw(fname)
    for (k in which(b == as.raw(47L))) {
      d <- if (k > 1L) rawToChar(b[seq_len(k - 1L)]) else ""
      stat <- if (nzchar(d) && !file.exists(d) &&
                  suppressWarnings(dir.create(d, showWarnings = FALSE, mode = "0755"))) 0 else 1
    }
    if (stat == 0) con <- open1()
  }
  if (is.null(con)) return(NULL)
  f <- wfdb_file_new(con, WFDB_LOCAL, fname, 0L, if (m == "a") "a" else "w")
  if (m == "a") f$wpos <- suppressWarnings(file.size(rn))
  f
}

#' Check that a record or annotator name contains only legal characters
#' (letters, digits, _ ~ - /); 0 if so, -1 (with an error message)
#' otherwise.
wfdb_checkname <- function(p, s) {
  b <- if (is.null(p)) integer(0) else as.integer(charToRaw(p))
  if (length(b) == 0L) {
    wfdb_error("init: illegal character %d in %s name\n", 0, s)
    return(-1)
  }
  # (digits, '_', '~', '-', '/', letters)
  ok <- (b >= 48L & b <= 57L) | b == 95L | b == 126L | b == 45L | b == 47L |
    (b >= 97L & b <= 122L) | (b >= 65L & b <= 90L)
  k <- match(FALSE, ok)
  if (is.na(k)) return(0)
  o <- b[k]
  if (o > 127L) o <- o - 256L
  wfdb_error("init: illegal character %d in %s name\n", o, s)
  -1
}

#' Save the current record name (for %r substitution in the WFDB path).
wfdb_setirec <- function(p) {
  b <- charToRaw(p)
  k <- which(b == as.raw(47L))
  if (length(k)) b <- b[-seq_len(k[length(k)])]
  if (!identical(b, charToRaw("-"))) {
    .wfdb_io$irec <- rawToChar(b[seq_len(min(length(b), WFDB_MAXRNL))])
  }
  invisible()
}

wfdb_getirec <- function() {
  if (nzchar(.wfdb_io$irec)) .wfdb_io$irec else NULL
}

#' p without a trailing ".hea" (if present).
wfdb_striphea <- function(p) {
  if (!is.null(p) && nchar(p, type = "bytes") > 4L && endsWith(p, ".hea"))
    rawToChar(charToRaw(p)[seq_len(nchar(p, type = "bytes") - 4L)]) else p
}

# ---------------------------------------------------------------------------
# Running another tool in a separate process

#' Quote a string for a POSIX shell.
shell_quote <- function(s) paste0("'", gsub("'", "'\\''", s, fixed = TRUE), "'")

#' The shell command that runs the wfdb-x tool `tool` (followed by its
#' arguments, to be appended by the caller) in a new process; used (in
#' legacy mode) to run sortann when an annotation file is closed, as the C
#' library does.
tool_command <- function(tool) {
  driver <- .wfdb_io$driver
  if (is.null(driver) || !file.exists(driver)) {
    driver <- system.file("bin", "wfdbx.R", package = "wfdbx")
  }
  rscript <- file.path(R.home("bin"), "Rscript")
  if (!file.exists(rscript)) rscript <- "Rscript"
  paste(shell_quote(rscript), shell_quote(driver), shell_quote(tool))
}
