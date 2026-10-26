# Tests of finding files (wfdb-x): the input directory, the output
# directory, network access, files named in headers, and legacy mode (port
# of python/tests/test_files.py).
#
# Remote files are served by a local HTTP server (127.0.0.1; a small Python
# script, skipped if python3 is not available): no test contacts another
# host.  The environment variables are read lazily, so their tests reset
# the module state (wfdbio_reset) instead of starting new processes.
#
# Part of wfdb-x, Reza Sameni, Oct 2026.
# GNU General Public License, version 2 or later (see LICENSE).

data <- if (nzchar(.rdir)) file.path(dirname(dirname(.rdir)), "tests", "data") else ""
if (!nzchar(data) || !dir.exists(data)) {
  cat("(tests/data not found: file tests skipped)\n")
} else {
envs <- c("WFDB", "WFDBX_INPUT_DIR", "WFDBX_OUTPUT_DIR", "WFDBX_NETWORK", "HOME", "no_proxy",
          "NO_PROXY")
oldenv <- Sys.getenv(envs, unset = NA)
old <- getwd()
d <- tempfile("wfdbx-files")
dir.create(d)
file.copy(file.path(data, c("100s.hea", "100s.dat", "100s.atr", "fmt16.hea", "fmt16.dat")), d)
setwd(d)
cwd <- normalizePath(".")
dir.create("home")
srv <- NULL
on.exit({
  wfdbquit()
  wfdbx_set_legacy(FALSE)
  if (!is.null(srv)) tools::pskill(srv$pid)
  setwd(old)
  for (k in envs) if (is.na(oldenv[[k]])) Sys.unsetenv(k) else do.call(Sys.setenv, as.list(oldenv[k]))
  unlink(d, recursive = TRUE)
  wfdbio_reset()
  wfdbverbose()
}, add = TRUE)
# the default settings (no input or output directory, network off, messages
# not yet printed); HOME is the subdirectory home
defaults <- function() {
  Sys.unsetenv(envs[1:4])
  # (the local server is reached directly, never through a proxy)
  Sys.setenv(HOME = file.path(cwd, "home"), no_proxy = "127.0.0.1,localhost",
             NO_PROXY = "127.0.0.1,localhost")
  wfdbio_reset()
}
defaults()
rf <- function(name) readBin(name, "raw", file.size(name))
putfile <- function(name, text) {
  dir.create(dirname(name), recursive = TRUE, showWarnings = FALSE)
  writeBin(charToRaw(text), name)
}
make_sr <- function(dir) {               # record sr (a copy of 100s) in dir
  putfile(file.path(dir, "sr.hea"), paste0("sr 2 360 21600\n",
                                           "sr.dat 212 200 11 1024 995 21537 0 MLII\n",
                                           "sr.dat 212 200 11 1024 1011 -3962 0 V5\n"))
  file.copy("100s.dat", file.path(dir, "sr.dat"))
  file.copy("100s.atr", file.path(dir, "sr.atr"))
}
nsig <- function(record) isigopen(record, 0)$nsig
errmsg <- function(expr) tryCatch({
  expr
  ""
}, error = function(e) conditionMessage(e))
NET_OFF <- paste0("wfdb-x: network access is disabled; set WFDBX_NETWORK=1 or call ",
                  "wfdbx_set_network(1) to open %s\n")
WFDB_IGNORED <- paste0("wfdb-x: the WFDB environment variable is ignored; set ",
                       "WFDBX_INPUT_DIR instead (or use legacy mode)\n")

# ---------------------------------------------------------------------------
# Settings

expect_equal(list(wfdbx_get_input_dir(), wfdbx_get_output_dir(), wfdbx_get_network()),
             list(NULL, NULL, 0), "settings: defaults")
expect_equal(wfdbx_set_input_dir("a"), NULL, "input dir: set")
expect_equal(wfdbx_set_input_dir("b"), "a", "input dir: previous")
expect_equal(wfdbx_set_input_dir(""), "b", "input dir: reset")
expect_equal(wfdbx_get_input_dir(), NULL, "input dir: '' is the default")
expect_equal(wfdbx_set_output_dir("o"), NULL, "output dir: set")
expect_equal(wfdbx_set_output_dir(NULL), "o", "output dir: reset")
expect_equal(c(wfdbx_set_network(1), wfdbx_set_network(TRUE), wfdbx_set_network(0),
               wfdbx_set_network(NULL), wfdbx_set_network(-1), wfdbx_get_network()),
             c(0, 1, 1, 0, 0, 0), "network: set and previous")
# environment variables (read when first needed; the functions override them)
Sys.setenv(WFDBX_INPUT_DIR = "in", WFDBX_OUTPUT_DIR = "out", WFDBX_NETWORK = "1")
wfdbio_reset()
expect_equal(list(wfdbx_get_input_dir(), wfdbx_get_output_dir(), wfdbx_get_network()),
             list("in", "out", 1), "settings: environment")
expect_equal(list(wfdbx_set_input_dir("x"), wfdbx_set_input_dir(NULL)), list("in", "x"),
             "input dir: reset to the environment")
expect_equal(list(wfdbx_set_output_dir("y"), wfdbx_set_output_dir("")), list("out", "y"),
             "output dir: reset to the environment")
expect_equal(c(wfdbx_set_network(0), wfdbx_set_network(-1)), c(1, 0),
             "network: reset to the environment")
expect_equal(list(wfdbx_get_input_dir(), wfdbx_get_output_dir(), wfdbx_get_network()),
             list("in", "out", 1), "settings: environment again")
ok <- TRUE
for (v in list(c("0", 0), c("", 0), c("x", 0), c(" 2", 1), c("-1", 1), c("0x1", 0),
               c("1abc", 1))) {
  Sys.setenv(WFDBX_NETWORK = v[1L])
  wfdbio_reset()
  ok <- ok && wfdbx_get_network() == as.numeric(v[2L])
}
check(ok, "WFDBX_NETWORK: strtol(value) != 0")
Sys.setenv(WFDBX_INPUT_DIR = "")
wfdbio_reset()
expect_equal(wfdbx_get_input_dir(), NULL, "WFDBX_INPUT_DIR empty")
# an output directory URL is refused
defaults()
Sys.setenv(WFDBX_OUTPUT_DIR = "http://127.0.0.1:1/")
wfdbio_reset()
wfdbquiet()
expect_equal(wfdbx_get_output_dir(), NULL, "WFDBX_OUTPUT_DIR URL refused")
expect_equal(wfdberror(), "wfdbx_set_output_dir: the output directory must be a local directory\n",
             "WFDBX_OUTPUT_DIR URL message")
wfdbx_set_output_dir("o")
expect_equal(wfdbx_set_output_dir("https://127.0.0.1:1/"), "o",
             "output dir URL refused: the current value is returned")
expect_equal(wfdbx_get_output_dir(), "o", "output dir URL refused: unchanged")
wfdbverbose()
# the settings survive wfdbquit
defaults()
wfdbx_set_input_dir("a")
wfdbx_set_output_dir("b")
wfdbx_set_network(1)
wfdbquit()
expect_equal(list(wfdbx_get_input_dir(), wfdbx_get_output_dir(), wfdbx_get_network()),
             list("a", "b", 1), "settings survive wfdbquit")

# setwfdb, getwfdb, resetwfdb (normal mode)
defaults()
wfdbquiet()
expect_equal(getwfdb(), ".", "getwfdb: none")
ok <- TRUE
for (pd in list(list("sub", "sub"), list("  sub  ", "sub"), list(";sub;", "sub"),
                list("http://h:80/a", "http://h:80/a"), list("~/x", "~/x"),
                list("@file", "@file"), list("%r", "%r"), list("", NULL), list(";", NULL),
                list(NULL, NULL))) {
  setwfdb("old")
  setwfdb(pd[[1L]])
  ok <- ok && identical(wfdbx_get_input_dir(), pd[[2L]]) &&
    identical(getwfdb(), if (is.null(pd[[2L]])) "." else pd[[2L]])
}
check(ok, "setwfdb: one directory")
setwfdb("keep")
ok <- TRUE
for (p in c("a b", "a;b", "a:b", ". http://h/x", "http://h/x:/y")) {
  setwfdb(p)
  ok <- ok && identical(wfdbx_get_input_dir(), "keep") &&
    startsWith(wfdberror(), "setwfdb: wfdb-x reads from a single input directory; use ")
}
check(ok, "setwfdb: more than one directory is an error")
wfdbx_set_input_dir("other")
resetwfdb()
expect_equal(wfdbx_get_input_dir(), "keep", "resetwfdb: the last setwfdb")
wfdbverbose()

# the WFDB variable is ignored in normal mode (one message)
defaults()
make_sr("sub")
Sys.setenv(WFDB = "sub")
wfdbquiet()
expect_equal(nsig("100s"), 2, "WFDB ignored: 100s found")
expect_equal(wfdberror(), WFDB_IGNORED, "WFDB ignored: message")
wfdb_error("x\n")
expect_equal(nsig("100s"), 2, "WFDB ignored: again")
expect_equal(wfdberror(), "x\n", "WFDB ignored: message once")
expect_equal(nsig("sr"), -1, "WFDB ignored: sr not found")
# not needed for an absolute name; not printed in legacy mode
wfdbio_reset()
wfdbquiet()
wfdb_error("y\n")
expect_equal(nsig(file.path(cwd, "100s")), 2, "WFDB ignored: absolute name")
expect_equal(wfdberror(), "y\n", "WFDB ignored: no message for an absolute name")
wfdbio_reset()
wfdbquiet()
wfdb_error("y\n")
wfdbx_set_legacy(TRUE)
expect_equal(nsig("sr"), 2, "legacy: WFDB is the path")
expect_equal(wfdberror(), "y\n", "legacy: no message")
wfdbx_set_legacy(FALSE)
Sys.setenv(WFDB = "")
wfdbio_reset()
wfdbquiet()
wfdb_error("y\n")
expect_equal(getwfdb(), ".", "WFDB empty: no message")
expect_equal(wfdberror(), "y\n", "WFDB empty: no message (2)")
wfdbverbose()
wfdbquit()

# ---------------------------------------------------------------------------
# Names

defaults()
make_sr("home/hr")
dir.create("sub/deeper")
f <- wfdbfile
expect_equal(f("hea", "100s"), "100s.hea", "name: plain")
expect_equal(f("hea", "sub/sr"), "sub/sr.hea", "name: subdirectory")
expect_equal(f("hea", "sub/deeper/../sr"), "sub/deeper/../sr.hea", "name: .. inside")
expect_equal(f("hea", "sub/../100s"), "sub/../100s.hea", "name: .. allowed")
expect_equal(f("hea", file.path(cwd, "sub/sr")), file.path(cwd, "sub/sr.hea"), "name: absolute")
expect_equal(f("hea", "~/hr/sr"), file.path(cwd, "home/hr/sr.hea"), "name: ~")
expect_equal(f("hea", "~nosuchuser-wfdbx/hr/sr"), NULL, "name: ~unknown user")
expect_equal(f("hea", "sr"), NULL, "name: nothing is searched")
wfdbx_set_input_dir("sub")
expect_equal(f("hea", "sr"), "sub/sr.hea", "input dir: relative")
expect_equal(f("hea", "100s"), NULL, "input dir: nothing is searched")
expect_equal(f("hea", "../100s"), "sub/../100s.hea", "input dir: ..")
expect_equal(f("hea", file.path(cwd, "100s")), file.path(cwd, "100s.hea"), "input dir: absolute name")
wfdbx_set_input_dir("sub/")
expect_equal(f("hea", "sr"), "sub/sr.hea", "input dir: one separator")
wfdbx_set_input_dir(file.path(cwd, "sub"))
expect_equal(f("hea", "sr"), file.path(cwd, "sub/sr.hea"), "input dir: absolute")
wfdbx_set_input_dir("~/hr")
expect_equal(f("hea", "sr"), file.path(cwd, "home/hr/sr.hea"), "input dir: ~/hr")
wfdbx_set_input_dir("~")
expect_equal(f("hea", "hr/sr"), file.path(cwd, "home/hr/sr.hea"), "input dir: ~")
wfdbx_set_input_dir(NULL)
dir.create("sr")
file.copy("sub/sr.hea", "sr/sr.hea")
expect_equal(f("hea", "sr/"), "sr/sr.hea", "name: trailing / expansion")
putfile("sub/x.abc", "")
expect_equal(f("abcdef", "sub/x"), "sub/x.abc", "name: 8.3 form")
# ~ expansion
Sys.setenv(HOME = "/h/")
check(identical(c(.expand_home("~"), .expand_home("~/a"), .expand_home("a~"), .expand_home("x")),
                c("/h", "/h/a", "a~", "x")), "~ expansion")
Sys.setenv(HOME = "")
check(identical(c(.expand_home("~/a"), .expand_home("~")), c("/a", "/")), "~ expansion, HOME empty")
expect_equal(.expand_home("~nosuchuser-wfdbx/a"), "~nosuchuser-wfdbx/a", "~unknown user")
if (file.exists("/etc/passwd")) {
  me <- Sys.info()[["user"]]
  pw <- strsplit(grep(paste0("^", me, ":"), readLines("/etc/passwd"), value = TRUE), ":")
  if (length(pw))
    expect_equal(.expand_home(paste0("~", me, "/a")), paste0(sub("/+$", "", pw[[1L]][6L]), "/a"),
                 "~user expansion")
}
Sys.setenv(HOME = file.path(cwd, "home"))

# output names
a0 <- annotation(0, NORMAL)
write1 <- function(record, name = "x") {
  st <- annopen(record, list(anninfo(name, WFDB_WRITE)), 1)
  if (st == 0) putann(0, a0)
  wfdbquit()
  st
}
wfdbx_set_output_dir("out")
check(write1("r") == 0 && file.exists("out/r.x"), "output: relative")
check(write1("sub/r") == 0 && file.exists("out/sub/r.x"), "output: subdirectory")
check(write1("../up") == 0 && file.exists("up.x"), "output: ..")
check(write1(file.path(cwd, "abs")) == 0 && file.exists("abs.x"), "output: absolute")
check(write1("~/hm") == 0 && file.exists("home/hm.x"), "output: ~")
wfdbx_set_output_dir("~/o2")
check(write1("r") == 0 && file.exists("home/o2/r.x"), "output dir: ~")
wfdbx_set_output_dir("out/")
check(write1("r", "y") == 0 && file.exists("out/r.y"), "output dir: one separator")
wfdbx_set_output_dir(NULL)
wfdbquiet()
expect_equal(write1("http://127.0.0.1:1/r"), -4, "output: a URL cannot be written")
wfdbverbose()
# legacy mode: any name in the output directory (as in round 1)
wfdbx_set_legacy(TRUE)
wfdbx_set_output_dir("lout")
check(write1(file.path(cwd, "labs")) == 0 && file.exists(paste0("lout", cwd, "/labs.x")),
      "output: legacy, any name in the output directory")
wfdbx_set_output_dir(NULL)
wfdbx_set_legacy(FALSE)

# ---------------------------------------------------------------------------
# Files named in headers

defaults()
putfile("sub/dd.hea", "dd 1 360 10\ndata/a.dat 16 200 12 0 0 0 0 s\n")
dir.create("sub/data")
file.copy("fmt16.dat", "sub/data/a.dat")
r <- read_record("sub/sr", sampto = 2)
check(identical(unname(r$signals), matrix(c(995, 995, 1011, 1011), 2)) &&
        r$siginfo[[1]]$fname == "sr.dat", "header: signal file next to the header")
dd <- read_record("sub/dd", sampto = 9)$signals[, 1]
expect_equal(dd[1:2], c(-7, 32), "header: data/a.dat")
# (no checksum: a wrong one is a read_record error at the end of the record)
putfile("sub/sib.hea", "sib 1 360 10\n100s.dat 212 200 11 1024\n")
wfdbquiet()
check(nzchar(errmsg(read_record("sub/sib"))), "header: nothing is searched")
check(nrow(read_record("sub/sib", legacy = TRUE)$signals) > 0,
      "header: legacy mode searches the WFDB path")
ok <- TRUE
file.copy("fmt16.dat", "sub/ok.dat")
for (name in c("../100s.dat", "/100s.dat", "~/100s.dat", "~", "http://127.0.0.1:1/a.dat",
               "https://127.0.0.1:1/a.dat", "data/../../100s.dat", "..", "a/../b.dat")) {
  putfile("sub/bad.hea", sprintf("bad 2 360 10\n%s 16\nok.dat 16\n", name))
  n <- isigopen("sub/bad", 2)$nsig      # (the second file opens)
  ok <- ok && n == 1 && identical(wfdberror(), sprintf(paste0(
    "init: file %s named in the header of record sub/bad is not in the header's ",
    "directory\n"), name))
  wfdbquit()
}
check(ok, "header: containment")
dir.create("sub/a..b")
putfile("sub/ok3.hea", "ok3 3 360 10\nx..y.dat 16\na..b/c.dat 16\n./d.dat 16\n")
for (n in c("x..y.dat", "a..b/c.dat", "d.dat")) file.copy("fmt16.dat", file.path("sub", n))
expect_equal(isigopen("sub/ok3", 3)$nsig, 3, "header: names that stay in the directory")
wfdbquit()
wfdbverbose()

# segments: a null segment (~), a layout header, a segment in a subdirectory
dir.create("sub/seg")
putfile("sub/seg/dd.hea", "dd 1 360 10\nx.dat 16 200 12 0 0 0 0 s\n")
file.copy("fmt16.dat", "sub/seg/x.dat")
putfile("sub/ms.hea", "ms/4 1 360 30\nms_0 0\n~ 10\ndd 10\nseg/dd 10\n")
putfile("sub/ms_0.hea", "ms_0 1 360 0\n~ 0 200 12 0 0 0 0 s\n")
expect_equal(read_record("sub/ms", sampto = 19)$signals[, 1], c(rep(-32768, 10), dd),
             "segments: null segment and segment next to the header")
expect_equal(read_record("sub/ms", sampfrom = 20, sampto = 29)$signals[, 1], dd,
             "segments: segment in a subdirectory")
wfdbquiet()
ok <- TRUE
for (seg in c("../sub/dd", "/x", "~/dd", "http://127.0.0.1:1/dd")) {
  putfile("sub/ms2.hea", sprintf("ms2/2 1 360 20\ndd 10\n%s 10\n", seg))
  ok <- ok && isigopen("sub/ms2", 1)$nsig == 1 && isigsettime(10) == -1
  wfdbquit()
}
check(ok, "segments outside the directory are refused")
wfdbverbose()
expect_equal(setmsheader("msw", c("sub/dd", "sub/seg/dd")), 0, "setmsheader: names as given")
wfdbquit()
expect_equal(readLines("msw.hea")[2:3], c("sub/dd 10", "sub/seg/dd 10"), "setmsheader header")

# legacy mode unchanged
defaults()
wfdbquiet()
wfdbx_set_legacy(TRUE)
wfdbx_set_input_dir("sub")               # (not used in legacy mode)
expect_equal(nsig("sr"), -1, "legacy: the input directory is not used")
setwfdb("sub .")
expect_equal(nsig("sr"), 2, "legacy: the WFDB path")
expect_equal(wfdbfile("atr", "sr"), "sub/sr.atr", "legacy: wfdbfile")
expect_equal(getwfdb(), "sub .", "legacy: getwfdb")
expect_equal(nsig("sub/../100s"), -1, "legacy: .. refused")
expect_equal(wfdbfile("hea", "~/x"), NULL, "legacy: ~ not expanded")
setwfdb(".")
wfdbquit()
wfdbx_set_legacy(FALSE)
wfdbverbose()

# ---------------------------------------------------------------------------
# High-level options (local)

defaults()
wfdbx_set_input_dir("elsewhere")
expect_equal(length(read_header("sr", input_dir = "sub")), 2L, "read_header input_dir")
expect_equal(nrow(read_annotations("sr", "atr", input_dir = "sub")), 75L,
             "read_annotations input_dir")
expect_equal(wfdbx_get_input_dir(), "elsewhere", "input_dir restored")
wfdbquiet()
check(nzchar(errmsg(read_record("nosuch", input_dir = "sub", network = TRUE))),
      "read_record error")
expect_equal(list(wfdbx_get_input_dir(), wfdbx_get_network()), list("elsewhere", 0),
             "input_dir and network restored after an error")
wfdbverbose()
wfdbx_set_input_dir(NULL)
write_annotations("w1", "q", c(1, 2), symbol = c("N", "N"), dir = "sub")
check(file.exists("sub/w1.q"), "write_annotations dir")
wfdbquiet()
expect_equal(nrow(read_annotations("w1", "q", input_dir = "sub", fs = 100)), 2L,
             "output and input directories are independent")
wfdbverbose()

# ---------------------------------------------------------------------------
# Network access (a local server: python3 -m http.server, with a request
# log and a redirect)

py <- Sys.which("python3")
if (!nzchar(py)) {
  cat("(python3 not found: network tests skipped)\n")
} else {
  writeLines(c(
    "import functools, http.server, sys",
    "d, log, portfile = sys.argv[1:4]",
    "class H(http.server.SimpleHTTPRequestHandler):",
    "    def log_message(self, *a): pass",
    "    def do_GET(self):",
    "        open(log, 'a').write(self.path + '\\n')",
    "        if self.path.startswith('/redirect/'):",
    "            self.send_response(302)",
    "            self.send_header('Location', '/www/' + self.path[10:])",
    "            self.end_headers()",
    "            return",
    "        super().do_GET()",
    "s = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(H, directory=d))",
    "open(portfile + '.tmp', 'w').write(str(s.server_address[1]))",
    "import os; os.rename(portfile + '.tmp', portfile)",
    "s.serve_forever()"), "../server.py")
  logf <- file.path(dirname(cwd), "requests.log")
  portf <- file.path(dirname(cwd), "port")
  pidf <- file.path(dirname(cwd), "pid")
  system(paste("cd", shell_quote(cwd), "&& exec", shell_quote(py), "../server.py .",
               shell_quote(logf), shell_quote(portf), ">/dev/null 2>&1 & echo $! >",
               shell_quote(pidf)))
  for (i in 1:100) if (file.exists(portf)) break else Sys.sleep(0.1)
  srv <- list(pid = as.integer(readLines(pidf)))
  url <- sprintf("http://127.0.0.1:%s/", readLines(portf, warn = FALSE))
  reqs <- function() if (file.exists(logf)) readLines(logf) else character(0)

  # network off: the message once, nothing requested
  defaults()
  wfdbquiet()
  expect_equal(nsig(paste0(url, "100s")), -1, "network off: not opened")
  expect_equal(wfdberror(), sprintf("init: can't open header for record %s100s\n", url),
               "network off: the usual message")
  wfdbverbose()
  wfdbio_reset()
  wfdbquiet()
  wfdb_error("z\n")
  wfdbfile("hea", paste0(url, "100s"))
  expect_equal(wfdberror(), sprintf(NET_OFF, paste0(url, "100s.hea")), "network off: message")
  wfdb_error("z\n")
  wfdbfile("atr", paste0(url, "100s"))
  expect_equal(wfdberror(), "z\n", "network off: message once")
  wfdbverbose()
  expect_equal(reqs(), character(0), "network off: no request")

  # network on
  defaults()
  wfdbx_set_network(1)
  r <- read_record(paste0(url, "100s"), sampto = 3)
  expect_equal(unname(r$signals), matrix(rep(c(995, 1011), each = 3), 3), "network: read_record")
  expect_equal(nrow(read_annotations(paste0(url, "100s"), "atr")), 75L, "network: read_annotations")
  # each URL is requested once
  expect_equal(reqs(), c("/100s.hea", "/100s.dat", "/100s.info", "/100s.inf", "/100s.atr"),
               "network: requests")
  wfdbx_set_input_dir(url)
  expect_equal(unname(read_record("100s", sampto = 1)$signals), matrix(c(995, 1011), 1),
               "network: URL input dir")
  expect_equal(length(reqs()), 5L, "network: cached")
  expect_equal(wfdbfile("hea", "100s"), paste0(url, "100s.hea"), "network: wfdbfile")
  wfdbx_set_input_dir(sub("/$", "", url))
  expect_equal(wfdbfile("hea", "100s"), paste0(url, "100s.hea"), "network: one separator")

  # subdirectories, errors, redirects
  dir.create("www/data", recursive = TRUE)
  putfile("www/rec.hea", "rec 1 360 10\ndata/a.dat 16\n")
  file.copy("fmt16.dat", "www/data/a.dat")
  putfile("www/nodat.hea", "nodat 1 360 10\nnodat.dat 16\n")
  putfile("www/bad.hea", "bad 1 360 10\n../100s.dat 16\n")
  make_sr("www")
  wfdbx_set_input_dir(paste0(url, "www"))
  expect_equal(read_record("rec", sampto = 2)$signals[, 1], c(-7, 32), "network: data/a.dat")
  check("/www/data/a.dat" %in% reqs(), "network: data/a.dat requested")
  wfdbquiet()
  check(nzchar(errmsg(read_record("nodat"))), "network: missing signal file")
  check(nzchar(errmsg(read_record("nosuch"))), "network: 404")
  check(nzchar(errmsg(read_record("bad"))), "network: containment")
  check(startsWith(wfdberror(), "isigopen: none of the signals"), "network: containment message")
  n <- length(reqs())
  check(nzchar(errmsg(read_record("nosuch"))), "network: 404 again")
  expect_equal(length(reqs()), n, "network: failures are cached")
  check(!any(c("/100s.dat", "/www/../100s.dat") %in% reqs()[-(1:5)]), "network: nothing outside")
  wfdbverbose()
  wfdbx_set_input_dir(NULL)
  expect_equal(unname(read_record(paste0(url, "redirect/sr"), sampto = 1)$signals),
               matrix(c(995, 1011), 1), "network: redirect followed")
  wfdbquiet()
  expect_equal(annopen(paste0(url, "x"), list(anninfo("a", WFDB_WRITE)), 1), -4,
               "network: a URL cannot be written")
  expect_equal(wfdbx_set_output_dir(url), NULL, "network: output dir URL refused")
  wfdbverbose()

  # high-level options with the network
  defaults()
  r <- read_record("100s", input_dir = url, network = TRUE, sampto = 1)
  expect_equal(unname(r$signals), matrix(c(995, 1011), 1), "read_record input_dir URL, network")
  expect_equal(list(wfdbx_get_input_dir(), wfdbx_get_network()), list(NULL, 0),
               "input_dir and network restored")
  wfdbx_set_network(1)
  wfdbquiet()
  check(nzchar(errmsg(read_header(paste0(url, "100s"), network = FALSE))),
        "network = FALSE forbids for the call")
  wfdbverbose()
  expect_equal(wfdbx_get_network(), 1, "network restored")
  expect_equal(length(read_header(paste0(url, "100s"))), 2L, "network = NULL keeps the setting")

  # legacy mode reads no remote files, even with network access on
  defaults()
  n <- length(reqs())
  wfdbx_set_network(1)
  wfdbx_set_legacy(TRUE)
  wfdbquiet()
  expect_equal(nsig(paste0(url, "100s")), -1, "legacy: no URL")
  setwfdb(url)
  expect_equal(nsig("100s"), -1, "legacy: no URL path entry")
  setwfdb(".")
  wfdbquit()
  wfdbx_set_legacy(FALSE)
  wfdbverbose()
  expect_equal(length(reqs()), n, "legacy: no request")
}
defaults()
}
