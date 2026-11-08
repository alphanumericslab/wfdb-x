# metadata.R: header metadata, the "Key: value" info strings in the header
# of a record (read_metadata, get_metadata, set_metadata, remove_metadata,
# update_metadata).
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
# It has no counterpart in the original package.
#
# Copyright (C) 2026 Reza Sameni.
#
# This library is free software: you can redistribute it and/or modify it
# under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 2.1 of the License, or (at
# your option) any later version. See LICENSE.
#
# The info strings of a header are its comment lines (lines that begin with
# '#') after the record line, as the C function getinfo() reads them.  Many
# datasets store facts about the recording in them as "Key: value" pairs,
# such as "# Age: 63".  The functions of this file read and change such
# entries; read_header also returns them (its element metadata), and
# write_record writes them (its argument metadata).  The rules are those of
# the Python implementation (python/src/wfdbx/metadata.py, the reference)
# and of tests/metadata/README.md:
#
# * Reading.  An info string is an entry if the text after its '#' contains
#   a colon.  The key is the text before the first colon, and the value the
#   rest of the line; spaces, tabs, VT, FF and CR are removed at both ends
#   of each.  An info string without a colon, or whose key is then empty or
#   contains '#', is a free comment: never returned, never changed.  Comment
#   lines before the record line are not info strings.  Only the .hea file
#   is read, not the .info file that getinfo() also reads.
# * Keys are compared without regard to letter case (A-Z and a-z only).  If
#   a header has several entries for a key, reading returns the first, with
#   a warning; set and update refuse to change that key, and remove removes
#   all of them.  A key must not be empty, and must not contain ':', '#',
#   CR, LF or NUL.  A value must not contain CR, LF or NUL.
# * Writing.  An entry is written "# Key: value" ("# Key:" for an empty
#   value), with the caller's spelling of the key.  A changed entry keeps
#   its line (and its line ending); a new one is inserted after the last
#   info string, or after the last line that is not blank.  Every other
#   byte of the header is kept.  The new header is written to a temporary
#   file in the destination's directory, which then replaces the
#   destination (keeping its permission bits); nothing is written if
#   nothing changes (unless dir is given).
#
# Text is handled as bytes, as in the rest of the package: headers are read
# as raw vectors, keys and values are taken as their bytes (charToRaw of a
# character string, never re-encoded; a raw vector as given), and the
# entries returned are character strings of the bytes of the header.
#
# Errors are R errors (stop) of class "wfdbx_argument_error" (an invalid
# argument, or a change that the header does not allow: the Python
# implementation's ValueError and TypeError) or "wfdbx_file_error" (a file
# that cannot be read or written: Python's IOError), both also of class
# "error".  Warnings (several entries for a key) are R warnings, as the
# checksum warning of read_record.
#
# Metadata often holds information about patients.  WFDB-x stores it as
# plain text, exactly as given, and does not de-identify it.

.MD_TRIM <- as.raw(c(32, 9, 11, 12, 13))      # removed from both ends of keys and values
.MD_HASH <- as.raw(35)
.MD_COLON <- as.raw(58)
.MD_LF <- as.raw(10)
.MD_CR <- as.raw(13)
.MD_NUL <- as.raw(0)
.MD_CRLF <- as.raw(c(13, 10))                 # line ending of the headers written by WFDB

# Stop with an error of class wfdbx_argument_error (kind "argument") or
# wfdbx_file_error (kind "file").
.md_stop <- function(kind, ...) {
  stop(errorCondition(paste0(...), class = paste0("wfdbx_", kind, "_error"), call = NULL))
}

# ---------------------------------------------------------------------------
# Parsing

# The lines of data (raw), split after each LF: list(content = list of raw,
# eol = list of raw (CR LF, LF, or raw(0) for a last line without one)).
.md_split <- function(data) {
  n <- length(data)
  lf <- which(data == .MD_LF)
  starts <- c(1L, lf + 1L)
  ends <- c(lf, n)                    # (the index of each LF, or n)
  if (starts[length(starts)] > n) {   # (the data end with a LF, or are empty)
    starts <- starts[-length(starts)]
    ends <- ends[-length(ends)]
  }
  k <- length(starts)
  content <- vector("list", k)
  eol <- vector("list", k)
  for (i in seq_len(k)) {
    s <- starts[i]
    e <- ends[i]
    if (data[e] != .MD_LF) {
      content[[i]] <- data[s:e]
      eol[[i]] <- raw(0)
    } else if (e > s && data[e - 1L] == .MD_CR) {
      content[[i]] <- if (e - 2L >= s) data[s:(e - 2L)] else raw(0)
      eol[[i]] <- .MD_CRLF
    } else {
      content[[i]] <- if (e - 1L >= s) data[s:(e - 1L)] else raw(0)
      eol[[i]] <- .MD_LF
    }
  }
  list(content = content, eol = eol)
}

# b (raw) without spaces, tabs, VT, FF and CR at either end.
.md_trim <- function(b) {
  k <- which(!(b %in% .MD_TRIM))
  if (!length(k)) return(raw(0))
  b[k[1L]:k[length(k)]]
}

# b (raw) with the letters A-Z changed to a-z (no other byte is changed).
.md_fold <- function(b) {
  u <- b >= as.raw(65) & b <= as.raw(90)
  if (any(u)) b[u] <- as.raw(as.integer(b[u]) + 32L)
  b
}

.md_starts_hash <- function(b) length(b) > 0L && b[1L] == .MD_HASH

# list(key, value) (raw) of an info string (raw, beginning with '#'), or
# NULL if it is a free comment.
.md_entry <- function(content) {
  text <- content[-1L]
  i <- match(.MD_COLON, text)
  if (is.na(i)) return(NULL)
  key <- .md_trim(text[seq_len(i - 1L)])
  if (!length(key) || .MD_HASH %in% key) return(NULL)
  list(key = key, value = .md_trim(text[-seq_len(i)]))
}

# A parsed header: its lines (content, eol), rec (the index of the record
# line: the first line that does not begin with '#'; NA if there is none),
# info (the indices of the info strings) and entries (a list of
# list(line, key, value), in file order).
.md_parse <- function(data) {
  h <- .md_split(data)
  h$data <- data
  starts <- vapply(h$content, .md_starts_hash, NA)
  rec <- match(FALSE, starts)
  h$rec <- rec
  h$info <- integer(0)
  h$entries <- list()
  if (is.na(rec)) return(h)
  info <- which(starts & seq_along(starts) > rec)
  h$info <- info
  for (i in info) {
    e <- .md_entry(h$content[[i]])
    if (!is.null(e)) h$entries[[length(h$entries) + 1L]] <- list(line = i, key = e$key, value = e$value)
  }
  h
}

# The bytes of the lines of h.
.md_bytes <- function(h) {
  n <- length(h$content)
  if (!n) return(raw(0))
  parts <- vector("list", 2L * n)
  parts[seq.int(1L, by = 2L, length.out = n)] <- h$content
  parts[seq.int(2L, by = 2L, length.out = n)] <- h$eol
  unlist(parts, use.names = FALSE) %||% raw(0)
}

# The line indices of the entries of h whose key is key (raw), ignoring
# letter case.
.md_matches <- function(h, key) {
  f <- .md_fold(key)
  idx <- integer(0)
  for (e in h$entries) if (identical(.md_fold(e$key), f)) idx <- c(idx, e$line)
  idx
}

# The line ending of new lines: that of the record line, or of the first
# line that has one, or CR LF.
.md_eol <- function(h) {
  if (!is.na(h$rec) && length(h$eol[[h$rec]])) return(h$eol[[h$rec]])
  for (e in h$eol) if (length(e)) return(e)
  .MD_CRLF
}

# The number of lines after which new entries are inserted: up to the last
# info string, or the last line that is not blank.
.md_insertion_point <- function(h) {
  if (length(h$info)) return(h$info[length(h$info)])
  for (i in rev(seq_along(h$content))) if (length(.md_trim(h$content[[i]]))) return(i)
  length(h$content)
}

# The index of the raw vector b in the list l (0 if it is not there).
.md_index <- function(b, l) {
  for (i in seq_along(l)) if (identical(l[[i]], b)) return(i)
  0L
}

# A character string of the bytes b (up to the first NUL, which an R string
# cannot hold).
.md_text <- function(b) cstr(b)

# The entries of h as a named character vector (one entry per key, the
# first; a warning for each key that has more than one).
.md_unique <- function(h, record) {
  keys <- list()
  folded <- list()
  values <- list()
  lines <- list()
  for (e in h$entries) {
    f <- .md_fold(e$key)
    j <- .md_index(f, folded)
    if (j > 0L) {
      lines[[j]] <- c(lines[[j]], e$line)
      next
    }
    folded[[length(folded) + 1L]] <- f
    keys[[length(keys) + 1L]] <- e$key
    values[[length(values) + 1L]] <- e$value
    lines[[length(lines) + 1L]] <- e$line
  }
  for (j in seq_along(lines)) {
    if (length(lines[[j]]) > 1L)
      warning("header of record ", record, " has more than one entry for key ",
              .md_text(keys[[j]]), " (lines ", paste(lines[[j]], collapse = ", "),
              "); the first is used", call. = FALSE)
  }
  v <- vapply(values, .md_text, "")
  names(v) <- vapply(keys, .md_text, "")
  v
}

# ---------------------------------------------------------------------------
# Arguments

# s (a string, or a raw vector) as raw; what names it in the message.
.md_as_raw <- function(s, what) {
  if (is.raw(s)) return(s)
  if (!is.character(s) || length(s) != 1L || is.na(s))
    .md_stop("argument", what, " must be a string")
  charToRaw(s)
}

.md_shown <- function(s) if (is.raw(s)) .md_text(s) else s

.MD_NAMES <- c("3a" = "':'", "23" = "'#'", "0d" = "a line break", "0a" = "a line break",
               "00" = "a NUL character")

# key (a string or raw vector) as raw, without spaces at either end,
# checked.
.md_check_key <- function(key) {
  k <- .md_trim(.md_as_raw(key, "metadata key"))
  if (!length(k)) .md_stop("argument", "metadata key must not be empty")
  for (c in as.raw(c(58, 35, 13, 10, 0))) {
    if (c %in% k)
      .md_stop("argument", "metadata key '", .md_shown(key), "' must not contain ",
               .MD_NAMES[[as.character(c)]])
  }
  k
}

# value (a string or raw vector) as raw, without spaces at either end,
# checked.
.md_check_value <- function(key, value) {
  v <- .md_trim(.md_as_raw(value, "metadata value"))
  for (c in as.raw(c(13, 10, 0))) {
    if (c %in% v)
      .md_stop("argument", "value of metadata key '", .md_shown(key), "' must not contain ",
               .MD_NAMES[[as.character(c)]])
  }
  v
}

# The info string of an entry, as written: "# Key: value" (raw).
.md_line <- function(key, value) {
  c(charToRaw("# "), key, .MD_COLON, if (length(value)) c(as.raw(32), value))
}

# TRUE for a value that means "remove" in update_metadata: NULL or NA.
.md_is_none <- function(v) is.null(v) || (length(v) == 1L && !is.raw(v) && is.na(v))

# changes (a named list or a named character vector) as a list of
# list(key, value) (raw; value NULL for "remove"), checked: valid keys and
# values, and no two keys that differ only in letter case.
.md_check_changes <- function(changes) {
  ok <- (is.list(changes) && !is.data.frame(changes)) || is.character(changes)
  if (ok && length(changes) && is.null(names(changes))) ok <- FALSE
  if (!ok) .md_stop("argument", "metadata must be a named list or a named character vector")
  keys <- names(changes)
  out <- vector("list", length(changes))
  seen <- list()
  for (i in seq_along(changes)) {
    key <- keys[i]
    if (is.na(key)) key <- ""
    k <- .md_check_key(key)
    f <- .md_fold(k)
    if (.md_index(f, seen) > 0L)
      .md_stop("argument", "metadata key '", key, "' is given more than once ",
               "(keys are compared without regard to letter case)")
    seen[[length(seen) + 1L]] <- f
    v <- changes[[i]]
    out[[i]] <- list(key = k, value = if (.md_is_none(v)) NULL else .md_check_value(key, v))
  }
  out
}

# The info strings (as putinfo() takes them: without the '#'; raw) of the
# entries of metadata, for write_record: " Key: value".  Stops (argument
# error) if an entry is invalid, if two keys differ only in letter case, if
# a value is NULL or NA, or if one of comments (the other info strings) is
# already an entry for one of these keys.
.md_info_lines <- function(metadata, comments = character(0)) {
  entries <- .md_check_changes(metadata)
  folded <- lapply(entries, function(e) .md_fold(e$key))
  for (e in entries) {
    if (is.null(e$value))
      .md_stop("argument", "value of metadata key '", .md_text(e$key), "' must not be NULL or NA")
  }
  for (c in comments) {
    e <- .md_entry(c(.MD_HASH, craw(c)))
    if (!is.null(e) && .md_index(.md_fold(e$key), folded) > 0L)
      .md_stop("argument", "metadata key '", .md_text(e$key), "' is also given in comments")
  }
  lapply(entries, function(e) .md_line(e$key, e$value)[-1L])
}

# ---------------------------------------------------------------------------
# Files

# The record name checked, without a trailing ".hea".
.md_record_name <- function(record) {
  if (!is.character(record) || length(record) != 1L || is.na(record) || !nzchar(record))
    .md_stop("argument", "record name must not be empty")
  if (record == "-")
    .md_stop("argument", "the metadata of a header read from the standard input cannot ",
             "be read or changed")
  wfdb_striphea(record)
}

# list(data (raw), path (the name of the file it was read from), is_url)
# of the header of record, opened as the library opens a header
# (wfdb_open), with the current input settings.  Stops (file error) if it
# cannot be read.
.md_read <- function(record) {
  name <- .md_record_name(record)
  f <- wfdb_open("hea", name, WFDB_READ)
  if (is.null(f)) .md_stop("file", "can't read header for record ", record)
  path <- f$name
  data <- tryCatch(wf_readall(f), error = function(e) NULL, finally = wf_close(f))
  if (is.null(data)) .md_stop("file", "can't read header for record ", record)
  list(data = data, path = path, is_url = .is_url(path))
}

# The file to which a changed header is written: the header itself, or the
# file of the same name in dir.
.md_destination <- function(record, path, is_url, dir) {
  if (is.null(dir)) {
    if (is_url)
      .md_stop("argument", "header of record ", record, " was read from a URL, and cannot ",
               "be changed (give dir to write the changed header to a local directory)")
    return(path)
  }
  d <- .expand_home(dir)
  if (!dir.exists(d)) .md_stop("file", "directory ", dir, " does not exist")
  b <- charToRaw(path)
  sep <- which(b == as.raw(47L) | b == as.raw(92L))
  base <- if (length(sep)) rawToChar(b[-seq_len(sep[length(sep)])]) else path
  .join(d, base, "/")
}

# Write data (raw) to dest through a temporary file in the same directory,
# which then replaces dest (rename), keeping its permission bits.  The
# temporary file is removed on any failure (file error).
.md_write <- function(dest, data, record) {
  tmp <- tempfile(paste0(".", basename(dest), "."), tmpdir = dirname(dest), fileext = ".tmp")
  done <- FALSE
  on.exit(if (!done && file.exists(tmp)) unlink(tmp))
  fail <- function(e) FALSE
  ok <- tryCatch({
    con <- file(tmp, open = "wb", raw = TRUE)
    w <- tryCatch({
      writeBin(data, con)
      TRUE
    }, finally = close(con))
    # (a file written by file() has the permissions 0666 without the umask,
    # as a new header written by the library; an existing one keeps its own)
    if (w && file.exists(dest)) {
      mode <- file.info(dest)$mode
      w <- !is.na(mode) && isTRUE(Sys.chmod(tmp, mode, use_umask = FALSE))
    }
    w && isTRUE(file.rename(tmp, dest))
  }, error = fail, warning = fail)
  if (!ok) .md_stop("file", "can't write header for record ", record)
  done <- TRUE
  invisible()
}

# Apply changes (a checked list of list(key, value or NULL)) to the header
# of record; returns the number of lines removed.  input_dir and network
# apply to the reading of the header; dir (NULL or "": none) is the
# directory in which to write the changed header.
.md_change <- function(record, changes, input_dir, network, dir) {
  if (!is.null(dir) && !nzchar(dir)) dir <- NULL
  r <- .hl_input(input_dir, network, .md_read(record))
  dest <- .md_destination(record, r$path, r$is_url, dir)
  h <- .md_parse(r$data)
  if (is.na(h$rec)) .md_stop("argument", "header of record ", record, " has no record line")
  # (every change is checked before the header is changed)
  for (ch in changes) {
    idx <- .md_matches(h, ch$key)
    if (!is.null(ch$value) && length(idx) > 1L)
      .md_stop("argument", "header of record ", record, " has more than one entry for key ",
               .md_text(ch$key), " (lines ", paste(idx, collapse = ", "), "); remove them first")
  }
  removed <- 0
  for (ch in changes) {
    idx <- .md_matches(h, ch$key)
    if (is.null(ch$value)) {
      if (length(idx)) {
        h$content <- h$content[-idx]
        h$eol <- h$eol[-idx]
        h <- .md_parse(.md_bytes(h))
      }
      removed <- removed + length(idx)
    } else if (length(idx)) {
      h$content[[idx[1L]]] <- .md_line(ch$key, ch$value)
      h <- .md_parse(.md_bytes(h))
    } else {
      eol <- .md_eol(h)
      at <- .md_insertion_point(h)
      if (at > 0L && !length(h$eol[[at]])) h$eol[[at]] <- eol
      h$content <- append(h$content, list(.md_line(ch$key, ch$value)), at)
      h$eol <- append(h$eol, list(eol), at)
      h <- .md_parse(.md_bytes(h))
    }
  }
  out <- .md_bytes(h)
  if (!identical(out, r$data) || !is.null(dir)) .md_write(dest, out, record)
  removed
}

# The entries of the header of record, as read_metadata returns them, with
# the library's current input settings (for read_header).
.md_header_metadata <- function(record) .md_unique(.md_parse(.md_read(record)$data), record)

# ---------------------------------------------------------------------------
# The public functions

#' The metadata of a record: the "Key: value" entries of its header, as a
#' named character vector (names: the keys; values: the values), in file
#' order, with the spelling of the file; a key that appears more than once
#' (ignoring letter case) is returned once, with its first value, and a
#' warning.
#' record: the record name, without the .hea extension (a trailing ".hea"
#' is also accepted): a full path, absolute ("/data/mitdb/100") or in the
#' home directory ("~/Documents/100s"), used as given; a relative path
#' ("100s", "data/100s"), read from the input directory if one is set,
#' otherwise from the current directory; or a URL
#' ("https://physionet.org/files/mitdb/1.0.0/100"), read only if network
#' access is on (WFDB-x).
#' input_dir: the input directory for this call only (optional): a local
#' directory, a ~ path or a URL, under which relative record names are
#' read.  It does not apply to full paths or URLs.  Default: the current
#' setting (see wfdbx_set_input_dir).
#' network: for this call only, as in read_header.
read_metadata <- function(record, input_dir = NULL, network = NULL) {
  .hl_input(input_dir, network, .md_header_metadata(record))
}

#' The value of the entry for key (ignoring letter case and spaces at
#' either end), or NULL if the header has none.
get_metadata <- function(record, key, input_dir = NULL, network = NULL) {
  f <- .md_fold(.md_check_key(key))
  md <- read_metadata(record, input_dir = input_dir, network = network)
  for (i in seq_along(md)) {
    if (identical(.md_fold(charToRaw(names(md)[i])), f)) return(md[[i]])
  }
  NULL
}

#' Set the value of the entry for key (replacing its line, or adding
#' "# Key: value" after the last info string).  record: as for
#' read_metadata; the header is changed where it was read, unless dir is
#' given; a header read from a URL can only be written elsewhere, with dir.
#' dir: write the changed header to the directory dir instead.
set_metadata <- function(record, key, value, input_dir = NULL, network = NULL, dir = NULL) {
  k <- .md_check_key(key)
  .md_change(record, list(list(key = k, value = .md_check_value(key, value))),
             input_dir, network, dir)
  invisible()
}

#' Remove every entry for key; returns the number of lines removed.
remove_metadata <- function(record, key, input_dir = NULL, network = NULL, dir = NULL) {
  .md_change(record, list(list(key = .md_check_key(key), value = NULL)), input_dir,
             network, dir)
}

#' Several changes in one write: changes is a named list or named character
#' vector (key = value; NULL or NA removes the entry), applied in order.
update_metadata <- function(record, changes, input_dir = NULL, network = NULL, dir = NULL) {
  .md_change(record, .md_check_changes(changes), input_dir, network, dir)
  invisible()
}
