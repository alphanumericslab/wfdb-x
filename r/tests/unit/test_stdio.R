# Tests of the standard input and output emulation and of the tool runner.
#
# This file is part of wfdb-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
# It tests wfdb-x; it has no counterpart in the original package.
#
# Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

name <- tempfile(fileext = ".in")
writeBin(c(charToRaw("line 1\nline 2\n"), as.raw(c(200, 0, 10)), charToRaw("x")), name)
oldin <- Sys.getenv("WFDBX_STDIN", unset = NA)
Sys.setenv(WFDBX_STDIN = name)
.cstd$stdin_data <- NULL
wfdbio_reset()
b <- stdin_bytes()
expect_equal(length(b), 18L, "stdin size")
check(is.raw(b), "stdin class")
f <- wfdb_open(NULL, "-", WFDB_READ)
check(f$is_std, "stdin is_std")
expect_equal(rawToChar(wf_getline(f)), "line 1\n", "stdin getline")
expect_equal(wf_getc(f), 108L, "stdin getc")
expect_equal(wf_read(f, 6), charToRaw("ine 2\n"), "stdin read")
expect_equal(wf_seek(f, 0, 0), -1, "stdin not seekable")
expect_equal(wf_tell(f), -1, "stdin tell")
expect_equal(wf_getline(f), as.raw(c(200, 0, 10)), "stdin getline bytes")
expect_equal(wf_getline(f), charToRaw("x"), "stdin last line")
check(wf_feof(f), "stdin eof")
expect_equal(wf_getc(f), -1L, "stdin getc eof")
f2 <- wfdb_open("hea", "-", WFDB_READ)
check(identical(f, f2) && wf_feof(f2), "same stdin object")
# a standard input that is a regular file (stdin_is_file()) can seek
check(!stdin_is_file(), "WFDBX_STDIN stands for a pipe")
f$seekable <- TRUE
expect_equal(wf_seek(f, 2, 0), 0, "seekable stdin: seek")
expect_equal(c(wf_getc(f), wf_tell(f)), c(110, 3), "seekable stdin: getc, tell")
expect_equal(wf_seek(f, -1, 2), 0, "seekable stdin: seek from the end")
expect_equal(rawToChar(wf_read(f, 5)), "x", "seekable stdin: read at the end")
expect_equal(wf_seek(f, 100, 0), 0, "seekable stdin: seek beyond the end")
expect_equal(wf_getc(f), -1L, "seekable stdin: end of file")
f$seekable <- FALSE
expect_equal(length(fgets_lines(stdin_bytes(), 1024)), 4L, "fgets_lines of stdin")
if (is.na(oldin)) Sys.unsetenv("WFDBX_STDIN") else Sys.setenv(WFDBX_STDIN = oldin)
.cstd$stdin_data <- NULL

# freopen(name, "rb", stdin): a seekable standard input
check(!stdin_freopen(tempdir()), "freopen of a directory fails")
check(!stdin_freopen(paste0(name, ".nosuch")), "freopen of a missing file fails")
check(stdin_freopen(name), "freopen")
expect_equal(length(stdin_bytes()), 18L, "freopen: stdin_bytes")
f <- wfdb_open(NULL, "-", WFDB_READ)
check(!f$is_std, "freopen: a regular file")
expect_equal(rawToChar(wf_getline(f)), "line 1\n", "freopen: getline")
expect_equal(wf_seek(f, 2, 0), 0, "freopen: seek")
expect_equal(wf_getc(f), 110L, "freopen: getc after seek")
wf_close(f)
.cstd$stdin_path <- NULL
.cstd$stdin_data <- NULL
unlink(name)
wfdbio_reset()

# tool runner
expect_equal(app_run(function(argv) { cexit(3); 0 }, "x"), 3, "cexit")
expect_equal(app_run(function(argv) length(argv), c("x", "y")), 2L, "return status")
expect_equal(app_run(function(argv) NULL, "x"), 0, "NULL status")
expect_error(app_run(function(argv) stop("boom"), "x"), "errors are passed on")
check(tryCatch(app_run(function(argv) tryCatch(cexit(4), error = function(e) 99), "x") == 4,
               error = function(e) FALSE), "cexit is not an error")

# standard streams of a separate process: binary input and output
rscript <- file.path(R.home("bin"), "Rscript")
loader <- if (.mode == "source") {
  sprintf("e <- new.env(); for (f in sort(list.files('%s', '[.]R$', full.names = TRUE))) sys.source(f, e)", .rdir)
} else "e <- asNamespace('wfdbx')"
script <- tempfile(fileext = ".R")
writeLines(c(loader,
             "b <- e$stdin_bytes()",
             "e$cout(rev(b)); e$cout('|'); e$cprintf('%d', length(b)); e$cout()",
             "e$cerr(as.raw(c(0, 255, 10)))"), script)
inp <- tempfile()
outp <- tempfile()
errp <- tempfile()
writeBin(as.raw(c(0x61, 0, 0xff, 0x0a, 0x80)), inp)
system(paste(shQuote(rscript), shQuote(script), "<", shQuote(inp), ">", shQuote(outp),
             "2>", shQuote(errp)))
expect_equal(readBin(outp, "raw", 100), c(as.raw(c(0x80, 0x0a, 0xff, 0, 0x61)), charToRaw("|5")),
             "binary stdin and stdout of a process")
expect_equal(readBin(errp, "raw", 100), as.raw(c(0, 255, 10)), "binary stderr")
system(paste(shQuote(rscript), shQuote(script), "< /dev/null >", shQuote(outp), "2>", shQuote(errp)))
expect_equal(readBin(outp, "raw", 100), charToRaw("|0"), "empty stdin")
unlink(c(script, inp, outp, errp))

# tool_command
if (.mode == "source") .wfdb_io$driver <- file.path(dirname(.rdir), "inst", "bin", "wfdbx.R")
check(grepl("Rscript' '.*wfdbx[.]R' 'sortann'$", tool_command("sortann")), "tool_command")
expect_equal(shell_quote("a'b"), "'a'\\''b'", "shell_quote")
