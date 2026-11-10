# Tests of the header metadata functions (metadata.R: read_metadata,
# get_metadata, set_metadata, remove_metadata, update_metadata) and of the
# metadata of read_header and write_record (port of
# python/tests/test_metadata.py).
#
# The shared cases (tests/metadata/cases.tsv, with the expected headers in
# tests/metadata/expected/) are run by every implementation of WFDB-x, which
# must give the same results and write byte-identical headers.  A URL is
# served by a local HTTP server (127.0.0.1; a small Python script, skipped
# if python3 is not available): no test contacts another host.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
# It tests WFDB-x; it has no counterpart in the original package.
#
# Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 2.1 of the License, or (at
# your option) any later version. See LICENSE.

meta <- if (nzchar(.rdir)) file.path(dirname(dirname(.rdir)), "tests", "metadata") else ""
if (!nzchar(meta) || !dir.exists(meta)) {
  cat("(tests/metadata not found: metadata tests skipped)\n")
} else {
envs <- c("WFDB", "WFDBX_INPUT_DIR", "WFDBX_OUTPUT_DIR", "WFDBX_NETWORK", "no_proxy", "NO_PROXY")
oldenv <- Sys.getenv(envs, unset = NA)
old <- getwd()
base <- tempfile("wfdbx-meta")
dir.create(base)
srv <- NULL
on.exit({
  wfdbquit()
  wfdbverbose()
  if (!is.null(srv)) tools::pskill(srv$pid)
  setwd(old)
  for (k in envs) if (is.na(oldenv[[k]])) Sys.unsetenv(k) else do.call(Sys.setenv, as.list(oldenv[k]))
  unlink(base, recursive = TRUE)
  wfdbio_reset()
}, add = TRUE)

# A new, empty current directory, with the default settings (no input or
# output directory, network off, no remote file fetched).
ndir <- 0
fresh <- function() {
  ndir <<- ndir + 1
  d <- file.path(base, paste0("d", ndir))
  dir.create(d)
  setwd(d)
  Sys.unsetenv(envs[1:4])
  Sys.setenv(no_proxy = "127.0.0.1,localhost", NO_PROXY = "127.0.0.1,localhost")
  wfdbio_reset()
  normalizePath(".")
}
rf <- function(name) readBin(name, "raw", file.size(name))
copyh <- function(name, d = ".") {
  file.copy(file.path(meta, "headers", paste0(name, ".hea")), file.path(d, paste0(name, ".hea")))
  file.path(d, name)
}
# The kind of error of expr: "argument", "file", "other" ("" if none).
errkind <- function(expr) tryCatch({
  expr
  ""
}, wfdbx_argument_error = function(e) "argument", wfdbx_file_error = function(e) "file",
error = function(e) "other")
# list(value, warnings): the value of expr and the number of warnings
# (muffled), or the kind of error (value list(error = kind)).
run <- function(expr) {
  n <- 0
  v <- tryCatch(withCallingHandlers(list(ok = expr), warning = function(w) {
    n <<- n + 1
    invokeRestart("muffleWarning")
  }), wfdbx_argument_error = function(e) list(error = "argument"),
  wfdbx_file_error = function(e) list(error = "file"), error = function(e) list(error = "other"))
  list(v = v, warnings = n)
}

# ---------------------------------------------------------------------------
# The shared cases

hex <- function(s) {
  if (s == "-") return(NULL)
  s <- substring(s, 2L)
  if (!nzchar(s)) return(raw(0))
  as.raw(strtoi(substring(s, seq(1L, nchar(s), 2L), seq(2L, nchar(s), 2L)), 16L))
}
# a list of KEY:VALUE pairs: list(list(key, value (NULL for "-")), ...)
pairs <- function(s) {
  if (!nzchar(s)) return(list())
  lapply(strsplit(s, ",", fixed = TRUE)[[1L]], function(p) {
    kv <- strsplit(p, ":", fixed = TRUE)[[1L]]
    list(key = hex(kv[1L]), value = hex(kv[2L]))
  })
}
lines <- readLines(file.path(meta, "cases.tsv"), warn = FALSE)
lines <- lines[!startsWith(lines, "#") & nzchar(lines)]
check(length(lines) == 56L, "56 shared cases")
for (ln in lines) {
  f <- strsplit(ln, "\t", fixed = TRUE)[[1L]]
  if (length(f) < 10L) f <- c(f, rep("", 10L - length(f)))
  name <- f[1L]
  op <- f[3L]
  d <- fresh()
  rec <- copyh(f[2L], d)
  hea <- paste0(rec, ".hea")
  before <- rf(hea)
  key <- hex(f[4L])
  value <- hex(f[5L])
  r <- run(switch(op,
    read = read_metadata(rec),
    get = get_metadata(rec, key),
    set = set_metadata(rec, key, value),
    remove = remove_metadata(rec, key),
    update = {
      ch <- pairs(f[6L])
      changes <- lapply(ch, function(p) p$value)
      names(changes) <- vapply(ch, function(p) rawToChar(p$key), "")
      update_metadata(rec, changes)
    }))
  if (f[7L] != "-") {
    expect_equal(r$v$error, f[7L], paste(name, "error"))
  } else {
    check(is.null(r$v$error), paste(name, "no error"))
    got <- r$v$ok
    if (op == "read") {
      exp <- pairs(f[9L])
      expect_equal(unname(lapply(got, charToRaw)), lapply(exp, function(p) p$value),
                   paste(name, "values"))
      expect_equal(lapply(names(got), charToRaw), lapply(exp, function(p) p$key),
                   paste(name, "keys"))
      check(is.character(got) && !is.null(names(got)), paste(name, "a named character vector"))
    } else if (op == "get") {
      exp <- hex(f[9L])
      if (is.null(exp)) check(is.null(got), paste(name, "NULL")) else
        expect_equal(charToRaw(got), exp, paste(name, "value"))
    } else if (op == "remove") {
      expect_equal(got, as.numeric(f[9L]), paste(name, "count"))
    }
  }
  expect_equal(r$warnings, as.numeric(f[8L]), paste(name, "warnings"))
  if (f[10L] != "-") {
    expect_equal(rf(hea), rf(file.path(meta, f[10L])), paste(name, "header"))
  } else {
    expect_equal(rf(hea), before, paste(name, "header unchanged"))
  }
  expect_equal(list.files(d, all.files = TRUE, no.. = TRUE), paste0(f[2L], ".hea"),
               paste(name, "no other file"))
}

# ---------------------------------------------------------------------------
# read_header and write_record

fresh()
x <- matrix(0, 10, 1)
write_record("w", x, fs = 100, gains = 200, adcres = 12, units = "mV",
             comments = c("a comment", "Site: B"), metadata = list(Age = " 63 ", Notes = ""))
data <- rf("w.hea")
tail <- charToRaw("#a comment\r\n#Site: B\r\n# Age: 63\r\n# Notes:\r\n")
expect_equal(data[(length(data) - length(tail) + 1L):length(data)], tail,
             "write_record: metadata after the comments")
h <- read_header("w")
expect_equal(h$metadata, c(Site = "B", Age = "63", Notes = ""), "read_header: metadata")
expect_equal(h$comments, c("a comment", "Site: B", " Age: 63", " Notes:"),
             "read_header: comments")
write_record("v", x, fs = 100, gains = 200, adcres = 12, units = "mV",
             metadata = c(Dx = "426783006"))
expect_equal(read_metadata("v"), c(Dx = "426783006"), "write_record: character vector")
# (round trip of the entries returned)
write_record("u", x, fs = 100, gains = 200, adcres = 12, units = "mV", metadata = read_metadata("w"))
expect_equal(read_metadata("u"), read_metadata("w"), "write_record: round trip")
# a record read from an EDF file has no .hea file: no metadata
data_dir <- file.path(dirname(meta), "data")
if (file.exists(file.path(data_dir, "fmt16.edf"))) {
  expect_equal(read_header(file.path(data_dir, "fmt16.edf"))$metadata,
               structure(character(0), names = character(0)), "read_header: EDF")
}

# write_record: invalid metadata, nothing written
d <- fresh()
for (md in list(list("a:b" = "1"), list(Age = "1\n2"), c(Age = "1", AGE = "2"), list(Age = NULL),
                c(Age = NA), list(" " = "x"), list(Age = 1), list("1"), "1")) {
  expect_equal(errkind(write_record("e", x, fs = 100, gains = 200, adcres = 12, units = "mV",
                                    metadata = md)),
               "argument", paste("write_record: invalid metadata", deparse(md)))
}
expect_equal(errkind(write_record("e", x, fs = 100, gains = 200, adcres = 12, units = "mV",
                                  comments = "age: 1", metadata = list(Age = "2"))),
             "argument", "write_record: metadata key also in comments")
expect_equal(list.files(d, all.files = TRUE, no.. = TRUE), character(0),
             "write_record: nothing written")

# the .info file is ignored
d <- fresh()
rec <- copyh("lf")
writeBin(charToRaw("#Age: 1\n"), paste0(rec, ".info"))
expect_equal(read_metadata(rec), structure(character(0), names = character(0)), ".info ignored")

# ---------------------------------------------------------------------------
# input_dir and dir

fresh()
dir.create("in")
dir.create("out")
copyh("basic", "in")
original <- rf("in/basic.hea")
expect_equal(get_metadata("basic", "Sex", input_dir = "in"), "F", "input_dir")
check(is.null(wfdbx_get_input_dir()), "input_dir: for the call only")
wfdbx_set_input_dir("in")
expect_equal(get_metadata("basic.hea", "sex"), "F", "the input directory, .hea")
set_metadata("basic", "Age", "64", dir = "out")
expect_equal(rf("in/basic.hea"), original, "dir: the original is unchanged")
expect_equal(get_metadata("out/basic", "Age", input_dir = ""), "64", "dir: written")
# an unchanged header is still written to dir
expect_equal(remove_metadata("basic", "Weight", dir = "out"), 0, "dir: remove nothing")
expect_equal(rf("out/basic.hea"), original, "dir: unchanged header written")
expect_equal(errkind(set_metadata("basic", "Age", "1", dir = "none")), "file",
             "dir: a missing directory")
expect_equal(list.files("out", all.files = TRUE, no.. = TRUE), "basic.hea",
             "dir: no temporary file")
wfdbx_set_input_dir(NULL)
# the header is changed where it was read, not in the output directory
wfdbx_set_output_dir("out")
set_metadata("in/basic", "Age", "65")
expect_equal(get_metadata("in/basic", "Age"), "65", "changed where it was read")
expect_equal(get_metadata("out/basic", "Age"), "63", "not in the output directory")
wfdbx_set_output_dir(NULL)
update_metadata("in/basic", list(Age = "66", Sex = NA, Weight = "70", Dx = NULL))
expect_equal(read_metadata("in/basic"),
             c(Age = "66", Notes = "", "Recorded by" = "Holter monitor, model X", Weight = "70"),
             "update_metadata: NA and NULL remove")
update_metadata("in/basic", c(Weight = NA, Age = "67"))
expect_equal(read_metadata("in/basic")[["Age"]], "67", "update_metadata: character vector")
check(is.null(get_metadata("in/basic", "Weight")), "update_metadata: NA_character_ removes")

# ---------------------------------------------------------------------------
# Missing and invalid arguments

fresh()
expect_equal(errkind(read_metadata("none")), "file", "missing header: read")
expect_equal(errkind(set_metadata("none", "Age", "1")), "file", "missing header: set")
expect_equal(errkind(read_metadata("")), "argument", "empty record name")
expect_equal(errkind(read_metadata("-")), "argument", "standard input")
expect_equal(errkind(read_metadata(NA_character_)), "argument", "NA record name")
copyh("basic")
before <- rf("basic.hea")
expect_equal(errkind(set_metadata("basic", "Age", 63)), "argument", "a number as value")
expect_equal(errkind(set_metadata("basic", "Age", NA)), "argument", "NA as value")
expect_equal(errkind(set_metadata("basic", "Age", c("1", "2"))), "argument", "two values")
expect_equal(errkind(set_metadata("basic", 1, "1")), "argument", "a number as key")
expect_equal(errkind(get_metadata("basic", "a#b")), "argument", "get: invalid key")
expect_equal(errkind(update_metadata("basic", NULL)), "argument", "update: NULL")
expect_equal(errkind(update_metadata("basic", c("1", "2"))), "argument", "update: no names")
expect_equal(errkind(update_metadata("basic", list(Age = 5))), "argument", "update: a number")
expect_equal(rf("basic.hea"), before, "invalid arguments: unchanged")
msg <- tryCatch(set_metadata("basic", "a:b", "1"), error = function(e) conditionMessage(e))
expect_equal(msg, "metadata key 'a:b' must not contain ':'", "message of an invalid key")
msg <- tryCatch(read_metadata("none"), error = function(e) conditionMessage(e))
expect_equal(msg, "can't read header for record none", "message of a missing header")
check(inherits(tryCatch(read_metadata("none"), error = function(e) e), "error"),
      "file errors are errors")
# bytes: raw keys and values, taken as given
set_metadata("basic", charToRaw("Name"), as.raw(c(0x5a, 0xc3, 0xbc, 0x72, 0x69, 0x63, 0x68)))
expect_equal(charToRaw(get_metadata("basic", "Name")), as.raw(c(0x5a, 0xc3, 0xbc, 0x72, 0x69, 0x63, 0x68)),
             "bytes")
set_metadata("basic", "City", rawToChar(as.raw(c(0x4a, 0x6f, 0x73, 0xe9))))
expect_equal(charToRaw(get_metadata("basic", "city")), as.raw(c(0x4a, 0x6f, 0x73, 0xe9)),
             "a string of bytes")
# the message of a warning
w <- tryCatch(read_metadata(copyh("dups")), warning = function(w) conditionMessage(w))
expect_equal(w, "header of record ./dups has more than one entry for key age (lines 4, 6); the first is used",
             "the message of a warning")
writeBin(charToRaw("# only a comment\n"), "norec.hea")
expect_equal(read_metadata("norec"), structure(character(0), names = character(0)),
             "no record line: no entries")
expect_equal(errkind(set_metadata("norec", "Age", "1")), "argument", "no record line: set")
expect_equal(remove_metadata("basic", "Name"), 1, "remove: a count")
check(is.double(remove_metadata("basic", "Name")), "remove: a double")

# ---------------------------------------------------------------------------
# Permissions

if (.Platform$OS.type != "windows") {
  fresh()
  rec <- copyh("basic")
  Sys.chmod("basic.hea", "640", use_umask = FALSE)
  set_metadata(rec, "Age", "64")
  expect_equal(format(file.info("basic.hea")$mode), "640", "permissions kept")
  expect_equal(list.files(".", all.files = TRUE, no.. = TRUE), "basic.hea", "no temporary file")
  # a destination that cannot be replaced (a directory of that name): a
  # file error, and no temporary file left
  dir.create("blocked")
  dir.create("blocked/basic.hea")
  writeBin(as.raw(1), "blocked/basic.hea/x")
  expect_equal(errkind(set_metadata(rec, "Age", "1", dir = "blocked")), "file",
               "a destination that cannot be replaced")
  expect_equal(list.files("blocked", all.files = TRUE, no.. = TRUE), "basic.hea",
               "failed write: no temporary file")
  unlink("blocked", recursive = TRUE)
  # a directory that cannot be written: a file error, the header unchanged
  if (Sys.info()[["user"]] != "root") {
    before <- rf("basic.hea")
    Sys.chmod(".", "555", use_umask = FALSE)
    k <- errkind(set_metadata(rec, "Age", "1"))
    Sys.chmod(".", "755", use_umask = FALSE)
    expect_equal(k, "file", "a directory that cannot be written")
    expect_equal(rf("basic.hea"), before, "unwritable directory: unchanged")
  }
}

# ---------------------------------------------------------------------------
# A URL (a local server)

py <- Sys.which("python3")
if (!nzchar(py)) {
  cat("(python3 not found: metadata URL tests skipped)\n")
} else {
  cwd <- fresh()
  copyh("basic")
  writeLines(c(
    "import functools, http.server, sys",
    "d, portfile = sys.argv[1:3]",
    "class H(http.server.SimpleHTTPRequestHandler):",
    "    def log_message(self, *a): pass",
    "s = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(H, directory=d))",
    "open(portfile + '.tmp', 'w').write(str(s.server_address[1]))",
    "import os; os.rename(portfile + '.tmp', portfile)",
    "s.serve_forever()"), file.path(base, "server.py"))
  portf <- file.path(base, "port")
  pidf <- file.path(base, "pid")
  system(paste("exec", shell_quote(py), shell_quote(file.path(base, "server.py")), shell_quote(cwd),
               shell_quote(portf), ">/dev/null 2>&1 & echo $! >", shell_quote(pidf)))
  for (i in 1:100) if (file.exists(portf)) break else Sys.sleep(0.1)
  srv <- list(pid = as.integer(readLines(pidf)))
  url <- sprintf("http://127.0.0.1:%s/basic", readLines(portf, warn = FALSE))
  wfdbquiet()
  expect_equal(errkind(read_metadata(url)), "file", "URL: network off")
  wfdbverbose()
  expect_equal(get_metadata(url, "Age", network = TRUE), "63", "URL: read")
  check(wfdbx_get_network() == 0, "URL: network for the call only")
  expect_equal(errkind(set_metadata(url, "Age", "1", network = TRUE)), "argument",
               "URL: cannot be changed")
  dir.create("copy")
  set_metadata(url, "Age", "1", network = TRUE, dir = "copy")
  expect_equal(get_metadata("copy/basic", "Age"), "1", "URL: written to dir")
  expect_equal(get_metadata("basic", "Age"), "63", "URL: the original is unchanged")
}
}
