# wfdbio.R: low-level I/O of the WFDB library (port of lib/wfdbio.c): file
# lookup (wfdb_open: the input and output directories, and the WFDB path in
# legacy mode), access to remote files, error reporting (wfdb_error,
# wfdberror), version and configuration strings.
#
# This file is part of wfdb-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is an R translation of lib/wfdbio.c from the WFDB Software Package 10.7.0,
# by George B. Moody. The translation follows the logic and behavior of the
# original code, but it is new code, not the original C code.
#
# Changes from the original: files are found only where they are named, not by
# a search of the WFDB path: a relative name is read under the input directory
# and written under the output directory (by default, the current directory),
# and an absolute name, a ~ name or a URL is used as given; setwfdb, getwfdb
# and resetwfdb set and return the input directory, and the WFDB environment
# variable is ignored; a URL is opened only if network access is turned on
# (wfdbx_set_network or WFDBX_NETWORK), and is then read in full by the curl
# program or R's url(); the original's HTTP and FTP code (NETFILES) is not
# translated; ".." is accepted in names, and only the last component of a
# record name is checked; write errors are counted (wfdbx_write_errors);
# additions: wfdbx_set_input_dir, wfdbx_get_input_dir, wfdbx_set_output_dir,
# wfdbx_get_output_dir, wfdbx_set_network, wfdbx_get_network,
# wfdbx_write_errors and wfdbx_note_write_error; legacy mode (wfdbx_set_legacy) restores the original
# behavior (the WFDB path, without network access). Each change is marked
# "wfdb-x:" in the code; docs/DIVERGENCES.md gives the reasons.
#
# Original C code: lib/wfdbio.c, WFDB Software Package 10.7.0.
#   Copyright (C) 1988-2013 George B. Moody; revised 2010-2022 by
#   Benjamin Moody.
# R translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This library is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

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

# The default WFDB path (wfdbdefwfdb; used in legacy mode only, which opens
# no URLs: there is no default URL anywhere in wfdb-x)
DEFWFDB <- ". /usr/local/database http://physionet.org/physiobank/database"
DEFWFDBCAL <- "wfdbcal"
WFDB_MAXRNL <- 50
WFDBX_NET_TIMEOUT <- 30   # (seconds to connect, or without receiving data)

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
  # wfdb-x: the settings that locate files (see wfdbx_set_input_dir,
  # wfdbx_set_output_dir and wfdbx_set_network); each is read from its
  # environment variable when first needed
  st$input_dir <- NULL
  st$env_input_dir <- NULL
  st$input_dir_init <- FALSE
  st$wfdb_warned <- FALSE
  st$setwfdb_called <- FALSE   # the input directory set by setwfdb:
  st$setwfdb_input_dir <- NULL
  st$output_dir <- NULL
  st$env_output_dir <- NULL
  st$output_dir_init <- FALSE
  st$network <- NULL           # (NULL: not read yet)
  st$env_network <- FALSE
  st$network_warned <- FALSE
  st$fetched <- new.env(parent = emptyenv())  # URL -> contents (raw), or FALSE
  invisible()
}
wfdbio_reset()

# ---------------------------------------------------------------------------
# WFDB path

#' Restore the WFDB path to the value returned by the first getwfdb().
#' wfdb-x: in normal mode, restore the input directory set by the last
#' setwfdb(), if any (wfdbquit() does not call resetwfdb in normal mode).
resetwfdb <- function() {
  st <- .wfdb_io
  if (!wfdbx_get_legacy()) {
    if (st$setwfdb_called) .put_input_dir(st$setwfdb_input_dir)
    return(invisible())
  }
  if (!is.null(st$wfdbpath_init)) st$wfdbpath <- st$wfdbpath_init
  invisible()
}

#' The input directory, or "." if none is set (wfdb-x: files are not
#' searched for; see wfdbx_set_input_dir).  In legacy mode, the WFDB path
#' (from $WFDB, or DEFWFDB if it is not set).
getwfdb <- function() {
  st <- .wfdb_io
  if (!wfdbx_get_legacy()) {
    .init_input_dir()
    return(if (is.null(st$input_dir)) "." else st$input_dir)
  }
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

#' Set the input directory (a C-compatible form of wfdbx_set_input_dir).
#' wfdb-x: p is split into components as the WFDB path is (at spaces,
#' semicolons, and colons other than in URLs); it must contain at most one
#' non-empty component, which becomes the input directory (none, e.g. "" or
#' ";", or NULL: the default).  With more than one, an error is reported
#' and nothing changes.  In legacy mode, change the WFDB path (NULL: from
#' $WFDB or the default), as the C library does.
setwfdb <- function(p) {
  if (!wfdbx_get_legacy()) {
    .setwfdb_normal(p)
    return(invisible())
  }
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

# wfdb-x: setwfdb in normal mode (0, or -1 for more than one directory).
.setwfdb_normal <- function(p) {
  dirs <- .path_components(if (is.null(p)) "" else p)$prefix
  dirs <- dirs[nzchar(dirs)]
  if (length(dirs) > 1L) {
    wfdb_error(paste0("setwfdb: wfdb-x reads from a single input directory; use ",
                      "wfdbx_set_input_dir (or legacy mode for the WFDB search path)\n"))
    return(-1)
  }
  d <- if (length(dirs)) dirs else NULL
  .put_input_dir(d)
  st <- .wfdb_io
  st$setwfdb_input_dir <- d
  st$setwfdb_called <- TRUE
  0
}

#' Split a WFDB path into its components (path_prefix, path_type; legacy
#' mode).
wfdb_parse_path <- function(p) {
  st <- .wfdb_io
  st$path_prefix <- character(0)
  st$path_type <- numeric(0)
  if (is.null(p)) return(0)
  pc <- .path_components(p)
  st$path_prefix <- pc$prefix
  st$path_type <- pc$type
  0
}

# The components of a WFDB path string: list(prefix, type), type being
# WFDB_LOCAL or WFDB_NET.
.path_components <- function(p) {
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
  list(prefix = pre, type = typ)
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

#' Add the directory of file name s to the WFDB path (see wfdbio.c; used in
#' legacy mode only).
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

#' The pathname (or URL) of a WFDB file of type s for a record (NULL if not
#' found), looked up as by wfdb_open (wfdb-x: under the input directory, for
#' a relative name; in legacy mode, in the WFDB path); wfdbfile(NULL, NULL)
#' returns the last file name tried.
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

# wfdb-x: TRUE if s is an http:// or https:// URL.
.is_url <- function(s) startsWith(s, "http://") || startsWith(s, "https://")

# wfdb-x: TRUE for the bytes (integer codes) that are directory separators
# ('/', and on MS-Windows '\\').
.is_dsep <- function(c) c == 47L | (.Platform$OS.type == "windows" & c == 92L)

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

# The input directory: read WFDBX_INPUT_DIR when first needed, and warn
# (once, in normal mode) that WFDB is ignored.
.init_input_dir <- function() {
  st <- .wfdb_io
  if (!st$input_dir_init) {
    st$input_dir_init <- TRUE
    v <- cgetenv("WFDBX_INPUT_DIR")
    if (!is.null(v) && nzchar(v)) st$env_input_dir <- st$input_dir <- v
  }
  if (!st$wfdb_warned && !wfdbx_get_legacy()) {
    st$wfdb_warned <- TRUE
    w <- cgetenv("WFDB")
    if (!is.null(w) && nzchar(w))
      wfdb_error(paste0("wfdb-x: the WFDB environment variable is ignored; set ",
                        "WFDBX_INPUT_DIR instead (or use legacy mode)\n"))
  }
  invisible()
}

.put_input_dir <- function(d) {
  .init_input_dir()
  st <- .wfdb_io
  st$input_dir <- if (is.null(d) || !nzchar(d)) st$env_input_dir else d
  invisible()
}

#' Set the input directory (a wfdb-x addition); returns the previous one
#' (NULL if none).  A file named by a relative name (a record name, an
#' annotation file, ...) is read as dir/name; dir may be a local directory
#' (relative to the current directory, or a ~ name) or the URL of a
#' directory (see wfdbx_set_network).  Names given as absolute paths, ~
#' names or URLs are used as given; nothing else is searched.  NULL or ""
#' restores the default: the value of the environment variable
#' WFDBX_INPUT_DIR if it is set, otherwise none (names are used as given,
#' relative to the current directory).  Not used in legacy mode (which
#' searches the WFDB path).
wfdbx_set_input_dir <- function(dir) {
  .init_input_dir()
  previous <- .wfdb_io$input_dir
  .put_input_dir(dir)
  previous
}

#' The input directory (see wfdbx_set_input_dir), or NULL.
wfdbx_get_input_dir <- function() {
  .init_input_dir()
  .wfdb_io$input_dir
}

.OUTPUT_URL_ERROR <- "wfdbx_set_output_dir: the output directory must be a local directory\n"

.init_output_dir <- function() {
  st <- .wfdb_io
  if (!st$output_dir_init) {
    st$output_dir_init <- TRUE
    v <- cgetenv("WFDBX_OUTPUT_DIR")
    if (!is.null(v) && nzchar(v)) {
      if (.is_url(v)) wfdb_error(.OUTPUT_URL_ERROR) else st$env_output_dir <- st$output_dir <- v
    }
  }
  invisible()
}

#' Set the output directory (a wfdb-x addition); returns the previous one
#' (NULL if none).  Output files (WFDB_WRITE or WFDB_APPEND mode) named by a
#' relative name (the record name and the file type) are created as
#' dir/name (in legacy mode, any name); dir may be relative to the current
#' directory or a ~ name.  NULL or "" restores the default: the value of
#' the environment variable WFDBX_OUTPUT_DIR if it is set, otherwise none
#' (files are created as named).  A URL is refused: an error is reported,
#' the setting is unchanged, and its current value is returned.  Not reset
#' by wfdbquit.
wfdbx_set_output_dir <- function(dir) {
  .init_output_dir()
  st <- .wfdb_io
  if (!is.null(dir) && nzchar(dir) && .is_url(dir)) {
    wfdb_error(.OUTPUT_URL_ERROR)
    return(st$output_dir)
  }
  previous <- st$output_dir
  st$output_dir <- if (is.null(dir) || !nzchar(dir)) st$env_output_dir else dir
  previous
}

#' The output directory (see wfdbx_set_output_dir), or NULL.
wfdbx_get_output_dir <- function() {
  .init_output_dir()
  .wfdb_io$output_dir
}

#' Allow (on TRUE or > 0) or forbid (FALSE or 0) network access, i.e.
#' opening URLs (a wfdb-x addition); returns the previous setting (1 or 0).
#' NULL or a negative number restores the default: allowed if the
#' environment variable WFDBX_NETWORK is set to a non-zero number,
#' otherwise forbidden.  Remote files are read in full (by the system
#' program curl, or base R's url() without it: redirects are followed, an
#' HTTP status of 400 or more is a failure, and reading gives up if
#' connecting takes 30 s or no data arrives for 30 s) and kept for the rest of the process (each URL
#' is requested at most once).  Never in legacy mode, which reads no remote
#' files.
wfdbx_set_network <- function(on) {
  previous <- wfdbx_get_network()
  st <- .wfdb_io
  st$network <- if (is.null(on) || (!is.logical(on) && on < 0)) st$env_network else
    isTRUE(as.logical(on))
  previous
}

#' 1 if network access is allowed (see wfdbx_set_network), else 0.
wfdbx_get_network <- function() {
  st <- .wfdb_io
  if (is.null(st$network)) {
    v <- cgetenv("WFDBX_NETWORK")
    st$env_network <- !is.null(v) && strtol(v)[1L] != 0
    st$network <- st$env_network
  }
  if (st$network) 1 else 0
}

# wfdb-x: write errors.  Decided by Reza Sameni, Oct 2026: a program must not
# report success when its output was not written.

#' The number of write errors since the program started: the output files
#' that the library could not write, flush or close (found when they are
#' closed, as by wfdbquit()), and the errors reported with
#' wfdbx_note_write_error().  The high-level writers stop with an error when
#' they meet one, and the command-line tools then exit with status 1.
wfdbx_write_errors <- function() .cstd$write_errors

#' Count a write error (see wfdbx_write_errors()): for an application that
#' writes a file itself.
wfdbx_note_write_error <- function() {
  .cstd$write_errors <- .cstd$write_errors + 1
  invisible()
}

# wfdb-x: name with a leading "~" or "~/" replaced by the home directory
# ($HOME, or that of the current user if HOME is not set; on MS-Windows,
# %USERPROFILE%), and, on POSIX systems, "~user" by the home directory of
# that user (unchanged if there is no such user).
.expand_home <- function(name) {
  if (!startsWith(name, "~")) return(name)
  b <- as.integer(charToRaw(name))
  i <- 2L
  while (i <= length(b) && !.is_dsep(b[i])) i <- i + 1L   # (first separator)
  home <- NULL
  if (i == 2L) {
    if (.Platform$OS.type == "windows") {
      home <- cgetenv("USERPROFILE")
    } else {
      home <- cgetenv("HOME")
      if (is.null(home)) home <- .user_home(NULL)
    }
  } else if (.Platform$OS.type != "windows") {
    home <- .user_home(rawToChar(as.raw(b[2:(i - 1L)])))
  }
  if (is.null(home)) return(name)
  hb <- as.integer(charToRaw(home))
  while (length(hb) && .is_dsep(hb[length(hb)])) hb <- hb[-length(hb)]
  r <- c(hb, if (i <= length(b)) b[i:length(b)] else integer(0))
  if (length(r)) rawToChar(as.raw(r)) else "/"
}

# The home directory of user (NULL: the current user) from the password
# database (POSIX: /etc/passwd), or NULL if there is no such user.
.user_home <- function(user) {
  if (is.null(user)) {
    h <- path.expand("~")       # (R's own expansion: the current user)
    return(if (identical(h, "~")) NULL else h)
  }
  pw <- tryCatch(suppressWarnings(readLines("/etc/passwd")), error = function(e) character(0))
  f <- strsplit(pw[startsWith(pw, paste0(user, ":"))], ":", fixed = TRUE)
  if (length(f) && length(f[[1L]]) >= 6L) f[[1L]][6L] else NULL
}

# wfdb-x: d + sep + name, with exactly one separator ('/' in a URL).
.join <- function(d, name, sep) {
  if (.is_url(d)) sep <- "/"
  if (!nzchar(d)) return(name)
  db <- charToRaw(d)
  last <- as.integer(db[length(db)])
  if (last == utf8ToInt(sep) || .is_dsep(last)) paste0(d, name) else paste0(d, sep, name)
}

# wfdb-x: the location of the file named name (normal mode): an absolute
# name or a URL as given, a ~ name expanded, and a relative name under the
# input directory (for reading) or the output directory (for writing), if
# one is set.
.resolve <- function(name, output) {
  if (startsWith(name, "~")) return(.expand_home(name))
  if (.is_absolute_path(name) || .is_url(name)) return(name)
  if (output) {
    .init_output_dir()
    d <- .wfdb_io$output_dir
  } else {
    .init_input_dir()
    d <- .wfdb_io$input_dir
  }
  if (is.null(d)) return(name)
  .join(.expand_home(d), name, "/")
}

# wfdb-x: TRUE if a file name found in a header names a file in the
# header's directory or below it: a relative name that does not begin with
# '~' and has no ".." component (on MS-Windows, no drive letter either).
.in_header_dir <- function(name) {
  if (.is_absolute_path(name) || .is_url(name) || startsWith(name, "~")) return(FALSE)
  if (.Platform$OS.type == "windows") {
    if (substr(name, 2L, 2L) == ":") return(FALSE)
    name <- gsub("\\\\", "/", name, useBytes = TRUE)
  }
  !(".." %in% strsplit(name, "/", fixed = TRUE)[[1L]])
}

# wfdb-x: the directory part of a file name or URL, including its final
# separator ("" if it has none).
.dirname <- function(name) {
  b <- as.integer(charToRaw(name))
  i <- length(b)
  while (i > 0L && !.is_dsep(b[i])) i <- i - 1L
  if (i == 0L) "" else rawToChar(as.raw(b[seq_len(i)]))
}

# wfdb-x: open the file at location p for reading, trying both forms of its
# name (.spr1 and .spr2) there.
.open_at <- function(p, s) {
  if (is.null(s)) s <- ""
  st <- .wfdb_io
  st$wfdb_filename <- .spr1(p, s)
  f <- wfdb_fopen(st$wfdb_filename, "rb")
  if (!is.null(f)) return(f)
  long_filename <- st$wfdb_filename
  st$wfdb_filename <- .spr2(p, s)
  if (st$wfdb_filename != long_filename) return(wfdb_fopen(st$wfdb_filename, "rb"))
  NULL
}

# wfdb-x: open, for reading, a file named in the header of a record (a
# signal file, or a segment of type s): name, in the directory d of that
# header (as given by .dirname; NULL if unknown, for a header read from the
# standard input: then name is resolved as any relative name).  The name
# must be in that directory or below it; the signal file name "-" (the
# standard input) is also accepted.
.open_in <- function(d, s, name, record) {
  if (identical(name, "-")) return(wfdb_open(s, name, WFDB_READ))
  if (!.in_header_dir(name)) {
    wfdb_error("init: file %s named in the header of record %s is not in the header's directory\n",
               name, record)
    return(NULL)
  }
  if (is.null(d)) return(wfdb_open(s, name, WFDB_READ))
  .open_at(paste0(d, name), s)
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

# The record name as wfdb_open uses it: a name ending with '/' gets another
# copy of its final element ("abc/123/" -> "abc/123/123").
.expand_record <- function(record) {
  r <- record
  rb <- charToRaw(record)
  rlen <- length(rb)
  if (rlen > 1L && rb[rlen] == as.raw(47L)) {
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
  r
}

# wfdb-x: the name of the local file that wfdb_open(name, NULL, WFDB_WRITE)
# creates in normal mode, or NULL if it creates none (the standard output,
# or a URL).
.output_file <- function(name) {
  if (is.null(name) || !nzchar(name) || name == "-") return(NULL)
  r <- .expand_record(name)
  if (.is_url(r)) return(NULL)
  .resolve(r, TRUE)
}

#' Open the WFDB file of type s (e.g. "hea", or "" for a file named by
#' record) for a record; mode WFDB_READ, WFDB_WRITE or WFDB_APPEND.  The
#' file name is the record name and the type, joined by a '.'.  The record
#' "-" is the standard input (reading) or output (writing).  wfdb-x: a
#' relative name is read under the input directory (wfdbx_set_input_dir)
#' and written under the output directory (wfdbx_set_output_dir); an
#' absolute name, a ~ name or a URL is used as given (a URL can only be
#' read, and only if network access is allowed: wfdbx_set_network).
#' Nothing is searched.  In legacy mode, an input file is searched for in
#' the WFDB path (see getwfdb), and an output file is created as named (in
#' the output directory, if one is set).  Returns a WFDB_FILE (see
#' wfdbfile.R) or NULL.
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
  r <- .expand_record(record)
  if (mode == WFDB_WRITE || mode == WFDB_APPEND) {
    st$wfdb_filename <- .spr1(r, s)
    .init_output_dir()
    if (!wfdbx_get_legacy()) {
      # wfdb-x: a relative name in the output directory, if one is set; a
      # URL cannot be written
      if (.is_url(st$wfdb_filename)) return(NULL)
      st$wfdb_filename <- .resolve(st$wfdb_filename, TRUE)
    } else if (!is.null(st$output_dir)) {   # wfdb-x: legacy mode: any name
      st$wfdb_filename <- paste0(st$output_dir, "/", st$wfdb_filename)
    }
    return(wfdb_fopen(st$wfdb_filename, if (mode == WFDB_WRITE) "wb" else "ab"))
  }
  # wfdb-x: the one location that the name designates
  if (!wfdbx_get_legacy()) return(.open_at(.resolve(r, FALSE), s))
  if (length(st$path_prefix) == 0L) getwfdb()
  if (startsWith(r, "http://") || startsWith(r, "https://")) {
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

# wfdb-x: read a remote file in full (once per process; failures are
# remembered too): its contents (raw), or NULL.  As in wfdb-x's other
# implementations, the system program curl reads it, following redirects,
# failing for an HTTP status >= 400, and giving up if connecting takes
# WFDBX_NET_TIMEOUT seconds or no data arrives for WFDBX_NET_TIMEOUT seconds,
# with no limit on the total time (record files can be large).  base R can
# run programs only through a shell, so the arguments are quoted.  Without
# curl, base R's url() (libcurl method) reads it; its timeout limits the
# whole transfer, so none is set then.
.fetch <- function(u) {
  cache <- .wfdb_io$fetched
  if (exists(u, envir = cache, inherits = FALSE)) {
    v <- get(u, envir = cache, inherits = FALSE)
    return(if (is.raw(v)) v else NULL)
  }
  data <- if (nzchar(Sys.which("curl"))) .fetch_curl(u) else .fetch_url(u)
  assign(u, if (is.null(data)) FALSE else data, envir = cache)
  data
}

.fetch_curl <- function(u) {
  tmp <- tempfile("wfdbx-")
  on.exit(unlink(tmp))
  t <- as.character(WFDBX_NET_TIMEOUT)
  args <- c("--silent", "--fail", "--location", "--connect-timeout", t,
            "--speed-limit", "1", "--speed-time", t, "--output", tmp, u)
  status <- suppressWarnings(system2("curl", shell_quote(args),
                                     stdout = FALSE, stderr = FALSE))
  if (status != 0L || !file.exists(tmp)) return(NULL)
  readBin(tmp, "raw", file.size(tmp))
}

.fetch_url <- function(u) {
  old <- options(timeout = .Machine$integer.max)
  on.exit(options(old))
  readall <- function() {
    con <- url(u, open = "rb", method = "libcurl")
    on.exit(close(con))
    parts <- list()
    repeat {
      x <- readBin(con, "raw", 1048576L)
      if (length(x) == 0L) break
      parts[[length(parts) + 1L]] <- x
    }
    b <- unlist(parts, use.names = FALSE)
    if (is.null(b)) raw(0) else b
  }
  tryCatch(suppressWarnings(readall()), error = function(e) NULL)
}

# wfdb-x: open a remote file for reading (normal mode), if network access is
# allowed; the first time it is not, print a message.
.fetch_open <- function(u) {
  st <- .wfdb_io
  if (!wfdbx_get_network()) {
    if (!st$network_warned) {
      st$network_warned <- TRUE
      wfdb_error(paste0("wfdb-x: network access is disabled; set WFDBX_NETWORK=1 or ",
                        "call wfdbx_set_network(1) to open %s\n"), u)
    }
    return(NULL)
  }
  data <- .fetch(u)
  if (is.null(data)) return(NULL)
  f <- wfdb_file_new(rawConnection(data), WFDB_NET, u, 0L, "r")
  f$size <- length(data)
  f
}

#' Open a file by name ("rb", "wb" or "ab"); returns a WFDB_FILE or NULL.
#' An http:// or https:// URL can only be read, if network access is
#' allowed (wfdb-x; see wfdbx_set_network).  For output, missing
#' directories are created (as C does).  In legacy mode, names containing
#' ".." or "://" are refused (as by the reference C library, built without
#' network support).
wfdb_fopen <- function(fname, mode) {
  if (is.null(fname) || !nzchar(fname)) return(NULL)
  m <- substr(mode, 1L, 1L)
  if (wfdbx_get_legacy()) {
    if (grepl("..", fname, fixed = TRUE) || grepl("://", fname, fixed = TRUE)) return(NULL)
  } else if (.is_url(fname)) {
    return(if (m == "r") .fetch_open(fname) else NULL)
  }
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
  f <- wfdb_file_new(con, WFDB_LOCAL, fname, 0L, if (m == "a") "a" else "w",
                     if (.is_absolute_path(rn)) rn else file.path(getwd(), rn))
  if (m == "a") f$wpos <- suppressWarnings(file.size(rn))
  f
}

#' Check that a record or annotator name contains only legal characters
#' (letters, digits, _ ~ - /); 0 if so, -1 (with an error message)
#' otherwise.  s is the kind of name ("record", "annotator", ...); for a
#' record name, outside legacy mode, only the last component is checked.
wfdb_checkname <- function(p, s) {
  b <- if (is.null(p)) integer(0) else as.integer(charToRaw(p))
  # wfdb-x: a record name may be a path; outside legacy mode only its last
  # component (the record's own name) is checked, so that directories with
  # other characters (such as "my.data/rec") can be written.
  if (s == "record" && !wfdbx_get_legacy()) {
    k <- which(b == 47L)
    if (length(k)) b <- b[-seq_len(k[length(k)])]
  }
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
