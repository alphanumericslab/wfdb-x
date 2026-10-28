"""Legacy conformance test cases: the cases of the original package.

These are the conformance cases as they were before WFDB-x removed the
built-in signal parameters of the C package (docs/DIVERGENCES.md).  The
harness runs each of them with --legacy as the first argument, and compares
the results with those of the original C tools (golden/, produced by the
unmodified C package): the legacy mode must reproduce them exactly.

Each case is a dict with keys:
  id      unique identifier (used as the golden directory name)
  tool    name of the WFDB application
  args    list of command-line arguments ("{cwd}", "{home}" and "{url}"
          as in ../cases.py)
  stdin   (optional) bytes or str supplied on the standard input
  files   (optional) {name: content} extra files created before running
  env     (optional) extra environment variables
  full    (optional) names of output files created as links to /dev/full,
          on which every write fails ("no space left on device")
  stdout_full (optional) True: the standard output is /dev/full
  wfdb    (optional) value of the WFDB environment variable (default ".")

Part of WFDB-x, Reza Sameni, Oct 2026.
This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 3 of the License, or (at your option) any later
version.
"""

import re

CASES = []
_ids = set()


def case(tool, args, cid=None, **kw):
    if isinstance(args, str):
        args = args.split()
    if cid is None:
        cid = tool + "-" + (re.sub(r"[^A-Za-z0-9.]+", "_", "_".join(args))
                            .strip("_") or "noargs")
    cid = cid[:90]
    base = cid
    n = 2
    while cid in _ids:
        cid = "%s~%d" % (base, n)
        n += 1
    _ids.add(cid)
    d = {"id": cid, "tool": tool, "args": args}
    d.update(kw)
    CASES.append(d)


RECORDS = ["100s", "fmt8", "fmt16", "fmt61", "fmt80", "fmt160", "fmt212",
           "fmt212b", "fmt310", "fmt310b", "fmt311", "fmt311b", "fmt24",
           "fmt32", "fmtblk", "mfreq", "twog", "skew", "prolog", "fms",
           "vlay", "multi", "null", "fmt16.edf", "100s.edf"]

# ---------------------------------------------------------------------------
# rdsamp
for r in RECORDS:
    case("rdsamp", ["-r", r])
    case("rdsamp", ["-r", r, "-v", "-p"])
for r in ["fmt212", "fmt310", "fmt311", "fmt212b", "fmt310b", "fmt311b",
          "mfreq", "skew", "prolog", "fms", "vlay", "multi", "100s",
          "fmt16.edf", "twog", "fmtblk", "fmt8"]:
    for f, t in [("s1", "s9"), ("s3", "s17"), ("s1499", "s1510"),
                 ("0:2", "0:2.1")]:
        case("rdsamp", ["-r", r, "-f", f, "-t", t])
for r in ["mfreq", "fmt16.edf", "vlay", "100s"]:
    case("rdsamp", ["-r", r, "-H", "-t", "s40"])
    case("rdsamp", ["-r", r, "-H", "-f", "s7", "-t", "s40", "-P"])
for opt in ["-p", "-pd", "-pe", "-ph", "-pm", "-ps", "-pS", "-P", "-Pd",
            "-Pe", "-Ph", "-Pm", "-PS"]:
    case("rdsamp", ["-r", "100s", "-t", "s25", "-v", opt])
    case("rdsamp", ["-r", "fmt16", "-t", "s25", "-v", opt])
    case("rdsamp", ["-r", "100s", "-t", "s25", "-v", "-c", opt])
    case("rdsamp", ["-r", "fmt16", "-f", "s20", "-t", "s45", "-c", opt])
    case("rdsamp", ["-r", "fmt16", "-f", "s20", "-t", "s45", "-X", opt])
case("rdsamp", "-r 100s -t s20 -c")
case("rdsamp", "-r 100s -t s20 -X")
case("rdsamp", "-r 100s -t s20 -c -v")
case("rdsamp", "-r 100s -s 1 0 1 -t s20 -v")
case("rdsamp", "-r 100s -s V5 -t s20 -v -p")
case("rdsamp", "-r 100s -s V6 -t s20")
case("rdsamp", "-r 100s -s")
case("rdsamp", "-r fmt16 -S 2 -f s0 -t s10")
case("rdsamp", "-r fmt16 -S sig2_fmt16 -t s10")
case("rdsamp", ["-r", "fmt16", "-S", "sig2 fmt16", "-t", "s10"])
case("rdsamp", "-r vlay -S 1 -f s10 -t s20")
case("rdsamp", "-r vlay -S 0 -f s1600 -l s10")
case("rdsamp", "-r 100s -l 0:1 -f 0:59.5")
case("rdsamp", "-r 100s -f 1:00")
case("rdsamp", "-r 100s -f e")
case("rdsamp", "-r 100s -f [12:00:00] -t s3")
case("rdsamp", "-r fmt16 -f [12:34:57] -t [12:34:57.1] -pd -v")
case("rdsamp", "-r fmt16 -f [12:34:57 31/12/1999] -t s300 -pd")
case("rdsamp", "-r fmt16 -f i -t s3")
case("rdsamp", "-r fmt16 -f c300 -t c310")
case("rdsamp", "-r fmt16 -f f300 -t f305")
case("rdsamp", "-r nonexistent")
case("rdsamp", "")
case("rdsamp", "-h")
case("rdsamp", "-r")
case("rdsamp", "-q")
case("rdsamp", "foo")
case("rdsamp", "-r 100s -f")
case("rdsamp", "-r 100s -t")
case("rdsamp", "-r 100s -l")
case("rdsamp", "-r 100s -S")
case("rdsamp", "-r 100s -f s30000")
case("rdsamp", "-r fmt16.hea -t s3")
case("rdsamp", "-r 8 -t s5", stdin=bytes(range(256)) * 4)
case("rdsamp", "-r 16 -t s5", stdin=bytes(range(256)) * 4)
case("rdsamp", "-r 8", stdin=bytes(range(101)))

# ---------------------------------------------------------------------------
# rdann
ANN = [("100s", "atr"), ("100a", "atr"), ("fmt16", "tst"), ("fmt16", "mod")]
for r, a in ANN:
    for opts in [[], ["-v"], ["-e"], ["-x"], ["-e", "-v"], ["-x", "-v"],
                 ["-f", "0:5", "-t", "0:10"], ["-f", "a3", "-t", "a10"],
                 ["-f", "b2", "-t", "b5"], ["-f", "#4", "-t", "#3"]]:
        case("rdann", ["-r", r, "-a", a] + opts)
case("rdann", "-r 100s -a atr -p N")
case("rdann", "-r 100s -a atr -p V A")
case("rdann", "-r 100s -a atr -p Z")
case("rdann", "-r 100s -a atr -p")
case("rdann", "-r fmt16 -a tst -c 1")
case("rdann", "-r fmt16 -a tst -c 2 -v")
case("rdann", "-r fmt16 -a tst -n 2")
case("rdann", "-r fmt16 -a tst -n -1")
case("rdann", "-r fmt16 -a tst -s -1")
case("rdann", "-r fmt16 -a tst -s 3 -x")
case("rdann", "-r fmt16 -a tst -p N V -s 0 -c 0")
case("rdann", "-r fmt16 -a tst -f [12:40:00] -t [12:45:00]")
case("rdann", "-r fmt16 -a tst -t e")
case("rdann", "-r fmt16 -a mod -p Q!")
case("rdann", "-r 100a -a atr -f 0:30 -t 1:00 -v")
case("rdann", "atr 100s")
case("rdann", "atr 100s 0:10")
case("rdann", "atr 100s 0:10 0:20")
case("rdann", "atr 100s 0:10 0:20 N V")
case("rdann", "-r 100s -a nosuch")
case("rdann", "-r nosuch -a atr")
case("rdann", "-r 100s")
case("rdann", "-h")
case("rdann", "-r 100s -a atr -q")
case("rdann", "-r 100s -a")
case("rdann", "-r 100s -a atr -f a1000")
case("rdann", "-r 100s -a atr -f b1000")
# A file that is not an annotation file (the aux buffer reuse of getann)
case("rdann", "-r fmt16 -a edf")


# ---------------------------------------------------------------------------
# wrann (the output is checked as a file and by reading it back)
def _rd(name):
    with open(__import__("os").path.join(
            __import__("os").path.dirname(__file__), "..", "..", "data",
            name),
            "rb") as f:
        return f.read()


case("wrann", "-r 100s -a cpy", stdin=_rd("100s.atr.txt"))
case("wrann", "-r fmt16 -a cpy", stdin=_rd("tst.txt"))
case("wrann", "-r 100s -a ooo", stdin=_rd("ooo.txt"))
case("wrann", "-r 100s -a ooo", stdin=_rd("ooo.txt"), cid="wrann-nosort",
     env={"WFDBANNSORT": "0"})
case("wrann", "-r 100s -a el", stdin=_rd("elapsed.txt"))
case("wrann", "-r nohdr -a x", stdin=_rd("100s.atr.txt"))
case("wrann", "-r 100s -a long",
     stdin="    0:00.050       18     N    0    0    0\t" + "x" * 300 + "\n"
     + "    0:00.100       36     Z    0    0    0\t" + "y" * 260 + "\n"
     + "    0:00.200       72     V\n"
     + "    0:00.300      108     V    1\n")
case("wrann", "-r 100s -a nomn", cid="wrann-no-mnemonic",
     stdin="    0:00.050       18     V    0    0    0\n"
     "    0:00.100       36\n    0:00.200       72     N\n"
     "    0:00.300      108  \n    0:00.400      144\tnote\n")
case("wrann", "-r 100s -a bad*name", stdin="")
case("wrann", "-r 100s")
case("wrann", "-h")

# ---------------------------------------------------------------------------
# sortann
case("sortann", "-r 100s -a atr")
case("sortann", "-r 100s -a atr -o srt")
case("sortann", "-r 100s -a atr -o srt -f 0:10 -t 0:20")
case("sortann", "-r 100s -a atr -f 0:10")
case("sortann", "-r 100s -a atr -o atr")
case("sortann", "-r fmt16 -a mod -o srt")
case("sortann", "-r 100a -a atr -o srt")
case("sortann", "-r. 100s -a atr -o srt")
case("sortann", "-r 100s -a nosuch")
case("sortann", "-h")
case("sortann", "-r 100s")
case("sortann", "-r 100s -a ooo", cid="sortann-ooo-inplace",
     files={"100s.ooo": _rd("100s.ooo")})

# ---------------------------------------------------------------------------
# ann2rr
for r, a in ANN:
    case("ann2rr", ["-r", r, "-a", a])
    case("ann2rr", ["-r", r, "-a", a, "-A", "-V", "-v", "-w", "-W"])
for opts in ["-i s", "-i s8", "-i m", "-i h5", "-i t", "-i s20", "-V T -v T",
             "-V t -v t", "-V s4 -v m", "-V h -v", "-c", "-c -p N",
             "-p V", "-P V", "-p N V -P N", "-A -c", "-f 0:10 -t 0:20",
             "-t 0:20 -f 0:30", "-W -w -i s3 -V -v s3", "-i x", "-v -V"]:
    case("ann2rr", ["-r", "100s", "-a", "atr"] + opts.split())
case("ann2rr", "-r fmt16 -a tst -A -i t -v T -V t -W -w")
case("ann2rr", "-r 100s -a atr -i")
case("ann2rr", "-r 100s -a atr -i -s")
case("ann2rr", "-r 100s -a atr -p Z")
case("ann2rr", "-r 100s -a atr -P")
case("ann2rr", "-r 100s")
case("ann2rr", "-h", stdin="\n")
case("ann2rr", "-r 100s -a nosuch")

# ---------------------------------------------------------------------------
# rr2ann
case("rr2ann", "-r 100s -a rr", stdin=_rd("rr.txt"))
case("rr2ann", "-r newrec -a rr", stdin=_rd("rr.txt"))
case("rr2ann", "-r newrec -a rr -F 128", stdin=_rd("rr.txt"))
case("rr2ann", "-r 100s -a rr -F 128", stdin=_rd("rr.txt"))
case("rr2ann", "-r newrec -a rr -T", stdin="100\n50\n300\n200\n")
case("rr2ann", "-r newrec -a rr -x 0.5", stdin=_rd("rr.txt"))
case("rr2ann", "-r newrec -a rr -w", stdin=_rd("rrw.txt"))
case("rr2ann", "-r newrec -a rr -F 0")
case("rr2ann", "-r newrec -a rr -x -1")
case("rr2ann", "-r newrec")
case("rr2ann", "-h")

# ---------------------------------------------------------------------------
# wrsamp
_TXT = "".join("%d %d %d\n" % (i, (i * 37) % 200 - 100, (i * i) % 1000)
               for i in range(300))
_HDRTXT = "time sigA sigB\nsec mV mmHg\n" + _TXT
_TABTXT = "".join("%d\t%d\t%.3f\n" % (i, -i * 3, i / 7.0) for i in range(120))
_FLT = "".join("%.4f,%.4f\n" % (i * 0.37 - 20, (i % 17) * 1.13 - 9)
               for i in range(200))
for args in ["-o w1", "-o w1 -z", "-o w1 1 2", "-o w1 2 0", "-o w1 -O 212",
             "-o w1 -O 8", "-o w1 -O 80", "-o w1 -O 310", "-o w1 -O 311",
             "-o w1 -O 24", "-o w1 -O 32", "-o w1 -O 61", "-o w1 -O 160",
             "-o w1 -F 500 -G 100", "-o w1 -G 100_50", "-o w1 -x 2",
             "-o w1 -f 10 -t 50", "-o w1 -t 5", "-o w1 -d -x 0.3",
             "-o w1 -c -l 7", ""]:
    case("wrsamp", args.replace("_", " ").split() if "_" not in args else
         args.replace("-G 100_50", "-G|100 50").replace(" ", "|")
         .replace("|", " ", 0).split("|") if False else
         [x.replace("_", " ") for x in args.split()], stdin=_TXT)
case("wrsamp", ["-o", "w2", "-G", "100 50", "-x", "1.5 0.5"], stdin=_TXT)
case("wrsamp", "-o w3", stdin=_HDRTXT)
case("wrsamp", "-o my.data/w1", stdin=_TXT, cid="wrsamp-dotdir")
case("wrsamp", "-o w3 -z", stdin=_HDRTXT)
case("wrsamp", "-o w4", stdin=_TABTXT)
case("wrsamp", "-o w4 -x 1000", stdin=_TABTXT)
case("wrsamp", "-o w5 -x 100", stdin=_FLT)
case("wrsamp", ["-o", "w5", "-s", ","], stdin=_FLT)
case("wrsamp", "-o w6 -r ;", stdin=_TXT.replace("\n", ";"))
case("wrsamp", "-r ;", stdin=_TXT)
case("wrsamp", "-o w6 -r ;", stdin=_TXT, cid="wrsamp-noseparator")
case("wrsamp", "-o w7", stdin="")
case("wrsamp", "-o w7", stdin="1 2 3")
case("wrsamp", "-o w7", stdin="a b\n")
case("wrsamp", "-o w7", stdin="'quoted 1' \"q 2\" <x y>\n1 2 3\n4 5 6\n")
case("wrsamp", "-o w7", stdin="e1 E2 x\n1e3 2.5e-1 -3e+2\n4 5 6\n")
case("wrsamp", "-o w8 -i 100s.atr.txt")
case("wrsamp", "-o w8 -i nosuchfile")
case("wrsamp", "-o w9 5", stdin=_TXT)
case("wrsamp", "-o w9 x", stdin=_TXT)
case("wrsamp", "-o w9 -q", stdin=_TXT)
case("wrsamp", "-h", stdin="\n")
case("wrsamp", "-o w10 -i rdsamp_x.xml")
for f in ["-f", "-F", "-G", "-i", "-o", "-O", "-r", "-s", "-t", "-x"]:
    case("wrsamp", [f])

# ---------------------------------------------------------------------------
# wfdbdesc
for r in RECORDS + ["100a", "8", "16"]:
    case("wfdbdesc", [r])
case("wfdbdesc", "100s -readable")
case("wfdbdesc", "twog -r")
case("wfdbdesc", "fms -readable")
case("wfdbdesc", "vlay -readable")
case("wfdbdesc", "nosuch")
case("wfdbdesc", "")
case("wfdbdesc", "nohdrlen", files={"nohdrlen.hea": "nohdrlen 2 250\r\n"
                                    "100s.dat 212 200 11 1024 995 0 0 a\r\n"
                                    "100s.dat 212 200 11 1024 1011 0 0 b\r\n"})

# ---------------------------------------------------------------------------
# wfdbtime, sampfreq, signame, signum, time2sec, wfdbwhich, wfdbcat
case("wfdbtime", "-r 100s 0 1 360 s360 1:0 e [00:00:10] 0:0.5")
case("wfdbtime", "-r fmt16 0 1 2500 [12:35:00] [12:34:56.889] [12:35:00 31/12/1999] [0:0:1 1] e")
case("wfdbtime", "-r mfreq 0 s7 1 e")
case("wfdbtime", "-r 100s 10 -r fmt16 10")
case("wfdbtime", "-r nosuch 10")
case("wfdbtime", "")
case("wfdbtime", "-r")
for r in ["100s", "mfreq", "fmt16.edf", "vlay", "multi"]:
    case("sampfreq", [r])
    case("sampfreq", ["-a", r])
    case("sampfreq", ["-H", r])
case("sampfreq", "")
case("sampfreq", "-h")
case("sampfreq", "-x 100s")
case("sampfreq", "a b c")
case("sampfreq", "nosuch")
case("signame", "-r 100s")
case("signame", "-r fmt16")
case("signame", "-r vlay")
case("signame", "-r 100s -s 1 0 1 -1 7")
case("signame", "-r 100s -s")
case("signame", "-r nosuch")
case("signame", "")
case("signame", "-h")
case("signame", "-x")
case("signum", "-r 100s -s V5 MLII x")
case("signum", "-r skew -s", )
case("signum", "-r 100s")
case("signum", "-h")
case("signum", ["-r", "fmt16", "-s", "sig1 fmt16", "sig0 fmt16"])
case("signum", ["-r", "16l", "-s", "data0"],
     files={"16l.hea": "16l 2\ndata0 16\ndata0 16\n"})
for tm in ["1:0", "0:0:1.5", "90", "s7", "[1:0:0]", "e"]:
    case("time2sec", [tm])
    case("time2sec", ["-r", "100s", tm])
    case("time2sec", ["-r", "fmt16", tm])
case("time2sec", "")
case("time2sec", "-x")
case("wfdbwhich", "100s.hea")
case("wfdbwhich", "nosuch.hea")
case("wfdbwhich", "hea 100s")
case("wfdbwhich", "atr 100s")
case("wfdbwhich", "dat nosuch")
case("wfdbwhich", "-r 100s 100s.dat")
case("wfdbwhich", "-r 100s nosuch")
case("wfdbwhich", "")
case("wfdbwhich", "-h")
case("wfdbwhich", "a b c d")
case("wfdbcat", "100s.hea 100s.atr nosuch fmt16.hea")
case("wfdbcat", "")
case("wfdbcat", "-h")
case("wfdbcat", "100s.dat")

# ---------------------------------------------------------------------------
# sigamp
for r in ["100s", "fmt16", "fmt8", "mfreq", "fmt212"]:
    case("sigamp", ["-r", r])
    case("sigamp", ["-r", r, "-v"])
    case("sigamp", ["-r", r, "-q", "-p"])
case("sigamp", "-r 100s -a atr -v")
case("sigamp", "-r 100s -a atr -p -v")
case("sigamp", "-r 100s -a atr -d 0.1 0.2 -q -pS")
case("sigamp", "-r 100s -a atr -d -0.1 0.02 -v -pe")
case("sigamp", "-r 100s -a atr -d 0.05 -0.02 -v")
case("sigamp", "-r 100s -a atr -w 2 -n 5 -v")
case("sigamp", "-r fmt16 -a tst -v -pd")
case("sigamp", "-r 100s -w 0.5 -n 20 -v -pm")
case("sigamp", "-r 100s -w 5 -f 10 -t 50 -v -ph")
case("sigamp", "-r 100s -d 1 2")
case("sigamp", "-r 100s -f 100 -v")
case("sigamp", "-r mfreq -H -v")
case("sigamp", "-r 100s -n 0 -w s100 -q")
case("sigamp", "-r nosuch")
case("sigamp", "")
case("sigamp", "-h")
case("sigamp", "-r 100s -d 1")

# ---------------------------------------------------------------------------
# snip
for r in ["100s", "fmt16", "fmt212", "fmt310", "fmt8", "mfreq", "skew",
          "twog", "prolog", "fmtblk"]:
    case("snip", ["-i", r, "-n", "snp", "-f", "s3", "-t", "s1203"])
case("snip", "-i 100s -n snp -f 0:10 -l 0:5 -a atr")
case("snip", "-i 100s -n snp -a atr")
case("snip", "-i 100s -n snp -s -O 16 -t 20")
case("snip", "-i fmt16 -n snp -a tst mod -f 1 -t 300")
case("snip", "-i fms -n snp -f s1000 -t s2000")
case("snip", "-i fms -n snp -m -f s1000 -t s2000")
case("snip", "-i vlay -n snp -m -f s1000 -t s3000")
case("snip", "-i vlay -n snp -f s1000 -t s1800")
case("snip", "-i multi -n snp -m -f 50 -t 100")
case("snip", "-i 100s -n snp -f 30 -t 20")
case("snip", "-i 100s -n snp -f 70")
case("snip", "-i nosuch -n snp")
case("snip", "-i 100s -n bad*name")
case("snip", "-i 100s")
case("snip", "-h")
case("snip", "-r 100s -n snp -O 80 -t 1")

# ---------------------------------------------------------------------------
# xform
for r in ["100s", "fmt16", "fmt212", "fmt8", "skew"]:
    case("xform", ["-i", r, "-o", "fmt16", "-n", "xf", "-t", "s500"])
case("xform", "-i 100s -o fmt212 -n xf -t 5")
case("xform", "-i fmt16 -o 100s -n xf -t 2")
case("xform", "-i fmt16 -o 100s -n xf -t 2 -c")
case("xform", "-i fmt16 -o 100s -n xf -t 2 -d")
case("xform", "-i 100s -o fmt16 -n xf -s 1 0 -t 1")
case("xform", "-i 100s -o fmt16 -n xf -s 1 x 0 -t 1 -a atr")
case("xform", "-i 100s -o fmt16 -N xf -a atr -u -t 10")
case("xform", "-i 100s -o fmt16 -n xf -f 10 -t 20 -a atr")
case("xform", "-i mfreq -o mfreq -n xf -M")
case("xform", "-i mfreq -o fmt16 -n xf -M")
case("xform", "-i mfreq -o fmt16 -n xf -H -t 2")
case("xform", "-i 100s -o 100s -n 100s")
case("xform", "-i 100s -S xs1.txt -t 30")
case("xform", "-i 100s -S xs1.txt -t 30 -d")
case("xform", "-i fmt16 -S xs2.txt -t 3")
# (the script as it was: an output frequency of 0, i.e. the default)
case("xform", "-i 100s -S xs3.txt -a atr -t 5",
     files={"xs3.txt": b"out3\n1\n0\n\n8\n\n\n\n"})
case("xform", "-i 100s -S xs4.txt -t 5 -N out4")
case("xform", "-i 100s -S xs5.txt -t 5")
case("xform", "-i 100s -S nosuch -t 5")
case("xform", "-i 100s -t 5", stdin="out6\n1\n\n\n16\n\n\n\n")
case("xform", "-i 100s -o fmt16 -f 10 -t 5")
case("xform", "-i nosuch -o fmt16")
case("xform", "-i 100s -o nosuch -n xf")
case("xform", "-o fmt16")
case("xform", "-h")

# ---------------------------------------------------------------------------
# convert/: EDF
for f in ["fmt16.edf", "100s.edf", "edfp.edf"]:
    case("edf2mit", ["-i", f])
    case("edf2mit", ["-i", f, "-r", "e2m", "-v"])
case("edf2mit", "-i fmt16.edf -r e2m -s 2 0")
case("edf2mit", "-i fmt16.edf -r e2m -s 5")
case("edf2mit", "-i edfp.edf -r e2m -s 0")
case("edf2mit", "-i fmt16.edf -r e2m -b")
case("edf2mit", "-i 100s.hea -r e2m")
case("edf2mit", "-i nosuch.edf")
case("edf2mit", "-i fmt16.edf -r bad*name")
case("edf2mit", "")
case("edf2mit", "-h")
case("edf2mit", "-r")
# (mit2edf uses the current date for records without a base time, so the
# multi-frequency and two-group records are given base times here.)
for r in ["fmt16", "fmt212", "fmt24", "skew", "fmt16.edf", "edfp.edf"]:
    case("mit2edf", ["-r", r])
case("mit2edf", "-r mfreqt -v", files={"mfreqt.hea": _rd("mfreq.hea").replace(
    b"mfreq 3 100 600", b"mfreqt 3 100 600 1:2:3 4/5/1906")})
case("mit2edf", "-r twogt", files={"twogt.hea": _rd("twog.hea").replace(
    b"twog 3 360 1001", b"twogt 3 360 1001 23:59:59.5 31/12/2099")})
case("mit2edf", "-r fmt16 -o out.edf -v")
case("mit2edf", "-r fmt16 -o out.edf -p")
case("mit2edf", "-r fmt16 -o out.EDF -p -v")
case("mit2edf", "-r fmt16 -o out.dat -p")
case("mit2edf", "-r nosuch")
case("mit2edf", "")
case("mit2edf", "-h")
case("mit2edf", "-r fmt16 -o")
for opts in ["", "-v", "-x", "-x -v", "-F 100", "-F 0"]:
    case("rdedfann", ["-r", "edfp.edf"] + opts.split())
case("rdedfann", "-r fmt16.edf")
case("rdedfann", "-r nosuch.edf")
case("rdedfann", "")
case("rdedfann", "-h")
case("rdedfann", "-r edfp.edf -q")

# ---------------------------------------------------------------------------
# convert/: WAV and MAT
case("wav2mit", "-i t16.wav -r w16")
case("wav2mit", "-i t8.wav -r w8")
case("wav2mit", "-i 100s.dat -r w8")
case("wav2mit", "-i nosuch.wav -r w8")
case("wav2mit", "-i fake.wav -r w8", files={"fake.wav": "RIFF1234WAVE"})
case("wav2mit", "-h")
case("wav2mit", "-i t16.wav -x")
for r in ["100s", "fmt16", "fmt80", "mfreq", "fmt8"]:
    case("mit2wav", ["-r", r, "-o", "out.wav", "-n", "outw"])
case("mit2wav", "-r 100s -o out.wav")
case("mit2wav", "-r 100s -o out.wav -n 100s")
case("mit2wav", "-r 100s -o out.dat")
case("mit2wav", "-r nosuch -o out.wav")
case("mit2wav", "-h")
for r in ["100s", "fmt16", "fmt80", "fmt24", "fmt32", "mfreq", "fmt212b",
          "fmt16.edf", "skew", "vlay"]:
    case("wfdb2mat", ["-r", r])
case("wfdb2mat", "-r 100s -f 10 -t 20")
case("wfdb2mat", "-r 100s -f 10 -l 0:3 -s 1")
case("wfdb2mat", "-r 100s -s V5 MLII -t s21")
case("wfdb2mat", "-r 100s -s V6")
case("wfdb2mat", "-r fmt16 -S 2 -t s50")
case("wfdb2mat", "-r mfreq -H")
case("wfdb2mat", "-r 100s -f 70")
case("wfdb2mat", "-r 100s -t 100")
case("wfdb2mat", "-r nolen", files={"nolen.hea": "nolen 2 360\r\n"
                                    "100s.dat 212 200 11 1024 995 0 0 a\r\n"
                                    "100s.dat 212 200 11 1024 1011 0 0 b\r\n"})
case("wfdb2mat", "-r data/100s", files={"data/100s.hea":
                                        _rd("100s.hea"),
                                        "data/100s.dat": _rd("100s.dat")})
case("wfdb2mat", "-r nosuch")
case("wfdb2mat", "")
case("wfdb2mat", "-h")

# ---------------------------------------------------------------------------
# convert/: AHA formats
case("m2a", "-r 100s -a atr aha2")
case("m2a", "-r fmt16 -a tst aha2")
case("m2a", "-r 100s -a atr aha2 -s 0:5")
case("m2a", "-r 100s -a atr")
case("m2a", "-r 100s -a nosuch aha2")
case("m2a", "-h")
case("a2m", "-i 100s.aha -r 100s -a cpy")
case("a2m", "-i 100s.aha -r 100s -a cpy -t 0")
case("a2m", "-i 100s.aha -r 100s -a cpy -t 1")
case("a2m", "-i 100s.aha -r 100s -a cpy -t 2 -s 0:1")
case("a2m", "-i 100s.atr -r 100s -a cpy")
case("a2m", "-i 1201.ANO")
case("a2m", "-i 1201.ANO -a x -s 10")
case("a2m", "-i 1201.ANO -r 1301")
case("a2m", "-i 1201.ANO -r 1001")
case("a2m", "-i nosuch.ano")
case("a2m", "-i 100s.aha -t 4")
case("a2m", "-h")
case("md2a", "-r 100s -o out.aha -n outaha")
case("md2a", "-r fmt16 -o out.aha")
case("md2a", "-r nosuch -o out.aha")
case("md2a", "-h")
case("ad2m", "-i 100s.aha.dat -r adm")
case("ad2m", "-i 100s.aha.dat -r adm -f 10 -t 20")
case("ad2m", "-i 1201.CMP")
case("ad2m", "-i 1201.CMP -r adm -f s100 -t s300")
case("ad2m", "-i 1201.CMP -r adm -c")
case("ad2m", "-i 100s.aha.dat -r 1301")
case("ad2m", "-i 100s.aha.dat -r adm -f 20 -t 10")
case("ad2m", "-i nosuch -r adm")
case("ad2m", "-h")
case("ahaecg2mit", "1001.ecg")
case("ahaecg2mit", "-s 1001.ecg")
case("ahaecg2mit", "1001.ecg x.dat nosuch.txt")
case("ahaecg2mit", "")
case("ahaecg2mit", "-h")
case("makeid", "atr 100s")
case("makeid", "atr fmt16_too_long")
case("makeid", "atr nosuch")
case("makeid", "")
case("readid", "512 512", stdin=b"100s\0\0\0\0" + bytes(range(1, 60)))
case("readid", "100 0", stdin=b"x" * 50)
case("readid", "")
case("revise", "old")
case("revise", "header.old")
case("revise", "nosuch")
case("revise", "100s", files={"100s.header": _rd("100s.hea")})
case("revise", "")
# Old-style headers with 31, 32 and 33 signals (C rejects a record with
# exactly 32 signals: see KNOWN_C_BEHAVIORS.md)
for nsig in (31, 32, 33):
    case("revise", ["o%d" % nsig], files={
        "o%d.header" % nsig: "o%d\n1\n100s.dat\n200\n360\n212 %d 11 1024\n"
        "995 21600 0\n" % (nsig, nsig)})
case("revise", ["o2g"], files={
    "o2g.header": "o2g\n2\n100s.dat\n200\n360\n212 16 11 1024\n995 21600 0\n"
    "100s.dat\n200\n360\n212 16 11 1024\n995 21600 0\n"})


# ---------------------------------------------------------------------------
# FLAC-compressed signals (formats 508, 516, 524).  Files written in FLAC
# format are compared by their decoded contents (see harness.py).
FLAC = ["flac8", "flac16", "flac24", "flacmf"]
for r in FLAC:
    case("rdsamp", ["-r", r])
    case("rdsamp", ["-r", r, "-f", "s4090", "-t", "s4110", "-v", "-p"])
    case("rdsamp", ["-r", r, "-f", "s4999", "-H"])
    case("wfdbdesc", [r])
    case("sigamp", ["-r", r, "-q"])
    case("snip", ["-i", r, "-n", "snp", "-f", "s100", "-t", "s4200",
                  "-O", "16"])
case("rdsamp", "-r flac16 -f e")
case("rdsamp", "-r flac16 -f s9001")
case("rdsamp", "-r flacmf -H -f s3 -t s9")
case("rdsamp", "-r badflac", files={
    "badflac.hea": "badflac 1 250 100\r\nbadflac.dat 516 200 16 0 0 0 0 x\r\n",
    "badflac.dat": b"fLaC" + bytes(60)})
case("rdsamp", "-r wrongch", files={
    "wrongch.hea": _rd("flac8.hea").replace(b"flac8 2", b"wrongch 1")
    .split(b"\r\nflac8.dat 508 150")[0].replace(b"flac8.dat", b"flac8.dat")
    + b"\r\n"})
case("rdsamp", "-r leftover", files={
    "leftover.hea": b"leftover 2 200 2161\r\nflacmf.dat 516x2 200 16 0 0 0 0 a\r\n"
    b"flacmf.dat 516x2 200 16 0 0 0 0 b\r\n"})
for fmt in ["508", "516", "524"]:
    case("xform", ["-i", "fmt16", "-S", "xsf%s.txt" % fmt, "-t", "s5000"],
         files={"xsf%s.txt" % fmt: "xf\n\n\n\n%s\n\n\n\n\n\n\n\n\n\n\n" % fmt},
         flac_files=["xf.dat"])
case("xform", "-i flac16 -o fmt16 -n xf")
case("xform", "-i fmt16 -o flac16 -n xf -t s5000", flac_files=["flac16.dat"])
case("xform", "-i 100s -o flac16 -n xf -t s5000", flac_files=["flac16.dat"])
case("snip", "-i flac16 -n snp -f s100 -t s4200", flac_files=["snp.dat"])
case("snip", "-i flacmf -n snp -t s2000", flac_files=["snp.dat"])
case("wrsamp", "-o wfl -O 516", stdin=_TXT, flac_files=["wfl.dat"])
case("wrsamp", "-o wfl -O 524 -x 1000", stdin=_TXT, flac_files=["wfl.dat"])
case("wrsamp", "-o wfl -O 508", stdin=_TXT, flac_files=["wfl.dat"])
case("wfdb2mat", "-r flac16 -t s3000")
case("mit2edf", "-r flac16")

# ---------------------------------------------------------------------------
# parsescp (SCP-ECG).  example.scp is a standard 12-lead SCP-ECG record;
# scp62.scp and scp63.scp do not follow the standard (their record length
# field is not little-endian), so parsescp rejects them.  parsescp -v and -x
# read one byte past the end of section 7 of example.scp (undefined
# behavior), so they are tested with section 7 skipped.
for opts in ["-w -o ex", "-w", "-o ex", "", "-l -w -o ex", "-z -w -o ex",
             "-b -w -o ex", "-t -w -o ex", "-s 3 -w -o ex", "-s -2 -t -w -o ex",
             "-S 5 -w -o ex", "-S 6 -w -o ex", "-S 3 -w -o ex",
             "-f -w -o ex", "-a", "-v -S 7", "-x -S 7", "-v -w -o ex -S 7",
             "-l -z -w -o ex"]:
    case("parsescp", opts.split(), cid=("parsescp-" + opts.replace(" ", "_")
                                        .replace("-", "")) if opts else
         "parsescp-default", stdin=_rd("example.scp"))
for f in ["scp62.scp", "scp63.scp"]:
    case("parsescp", "-w -o x", cid="parsescp-" + f, stdin=_rd(f))
    case("parsescp", "-a", cid="parsescp-a-" + f, stdin=_rd(f))
case("parsescp", "-w -o x", cid="parsescp-short", stdin=b"\x01\x02\x03")
case("parsescp", "-w -o x", cid="parsescp-truncated",
     stdin=_rd("example.scp")[:20000])
case("parsescp", "-w -o x", cid="parsescp-crcerror",
     stdin=_rd("example.scp")[:300] + b"\x55" + _rd("example.scp")[301:])
case("parsescp", "-f -w -o x", cid="parsescp-crcerror-force",
     stdin=_rd("example.scp")[:300] + b"\x55" + _rd("example.scp")[301:])
case("parsescp", "-h")
case("parsescp", "-q")
case("parsescp", "extra")

# ---------------------------------------------------------------------------
# Cases added by the cross-language differential review (each locks in the
# fix of a class of discrepancies found by random differential testing).


def _xs(*answers):
    """An xform -S script: the answers, then empty lines."""
    return "\n".join(answers) + "\n" * 20


# In a variable-layout record, getvec returns a positive value smaller than
# the number of signals in a gap segment ("~"): loops that stop when getvec
# returns less than the number of signals stop there.
case("mit2wav", "-r vlay -o out.wav -n outw")
case("md2a", "-r vlay -o out.aha -n outaha")
case("sigamp", "-r vlay -H -t 7.586")
case("sigamp", "-r vlay -v -f 5 -t 8")
# xform -d (dither): one output signal; resampling with gain changes (the
# order of the rand() calls, and inputs rounded to WFDB_INVALID_SAMPLE);
# an interpolated output equal to WFDB_INVALID_SAMPLE is range-checked
case("xform", "-i 100s -S xs.txt -s 0 -f s1 -t 34 -d", cid="xform-dither-1sig",
     files={"xs.txt": _xs("xs", "", "50", "", "160", "", "", "", "100", "12",
                          "-50")})
case("xform", "-i twog -n xf -S xs.txt -f 1 -t 1.242 -d",
     cid="xform-dither-1sig-24",
     files={"xs.txt": _xs("1", "0", "", "24", "n", "100", "24", "", "50.5",
                          "10", "0", "200", "12", "100")})
case("xform", "-i prolog -n xf -S xs.txt -t 1.695 -d",
     cid="xform-dither-resample-3sig",
     files={"xs.txt": _xs("3", "125", "", "8", "y", "100", "16", "0", "1000",
                          "24", "", "100", "24", "100")})
case("xform", "-i prolog -n xf -S xs.txt -t 1.695 -d",
     cid="xform-dither-resample-invalid",
     files={"xs.txt": _xs("1", "125", "", "16", "y", "", "", "")})
# xform writing a signal file that it is reading (through a segment of a
# multi-segment record): the input file is read in blocks as by glibc
case("xform", "-i vlay -o fmt16 -n xf -f s1320")
# snip -a given more than once: the count of annotators is not reset, and
# the names are those that follow the last -a (here, mod and -t: an error)
case("snip", "-i fmt16 -n snp -a tst -a mod -t 5")
case("snip", "-i 100s -n snp -a atr -f 0:10 -a ooo atr -t 0:20")
# A tool that exits (here, snip at an improper -f time) with an output file
# still open: the buffered bytes (here, the header of a FLAC signal file)
# are written, as C's exit() flushes all stdio streams.
case("snip", "-i fms -n snp -m -O 516 -f e", flac_files=["snp_0001.dat"])

# ---------------------------------------------------------------------------
# Absolute record names ({cwd} is the absolute work directory).  WFDB-x opens
# an input file named by an absolute path directly (and finds the signal and
# annotation files next to its header); the C library searched the WFDB path
# for it ("./" + the name), as legacy mode does, unless the WFDB path has an
# empty component (";").  sub/sr: a record in a subdirectory.
_SR = {"sub/sr.hea": _rd("100s.hea").replace(b"100s", b"sr"),
       "sub/sr.dat": _rd("100s.dat"), "sub/sr.atr": _rd("100s.atr")}
for tool, args, cid in [
        ("rdsamp", "-r {cwd}/100s -t s5", "abspath-rdsamp"),
        ("rdsamp", "-r {cwd}/sub/sr -t s5 -v", "abspath-rdsamp-subdir"),
        ("rdsamp", "-r {cwd}/nosuch -t s5", "abspath-rdsamp-missing"),
        ("rdann", "-r {cwd}/100s -a atr -t s1000", "abspath-rdann"),
        ("rdann", "-r {cwd}/sub/sr -a atr -t s1000", "abspath-rdann-subdir"),
        ("wfdbdesc", "{cwd}/100s", "abspath-wfdbdesc"),
        ("wfdbdesc", "{cwd}/sub/sr", "abspath-wfdbdesc-subdir")]:
    case(tool, args, cid=cid, files=_SR)
case("rdsamp", "-r {cwd}/sub/sr -t s5", cid="abspath-rdsamp-wfdb-empty",
     files=_SR, wfdb=";")

# ---------------------------------------------------------------------------
# Out-of-order annotations written by wrann, rearranged when the file is
# closed (WFDB-x: in the same process; the C library ran sortann): ties in
# time, num and chan, duplicates (the last one is kept), aux strings, an
# unknown mnemonic (a NOTE), the time resolution of the record (360 Hz for
# 100s; 1000.5 Hz for hr; none without a header), and a record in a
# subdirectory.  (Annotations at time 0 are avoided: see sortann in
# docs/KNOWN_C_BEHAVIORS.md.)
def _ann_lines(rows):
    return "".join("    0:00.000 %8d %5s %4d %4d %4d%s\n" %
                   (t, m, s, c, n, "\t" + a if a else "")
                   for t, m, s, c, n, a in rows)


_SORT = _ann_lines([
    (100, "N", 0, 0, 0, ""), (50, "V", 0, 0, 0, "(VT"),
    (100, "A", 0, 1, 0, ""), (100, "N", 0, 0, 1, "num 1"),
    (100, "V", 0, 0, 0, "replaces N"), (75, "N", 1, 2, 0, "odd"),
    (75, "J", 0, 2, 0, ""), (200, "+", 0, 0, 0, "(AFIB"),
    (150, "~", 0, 3, 0, ""), (150, "~", 0, 3, -1, ""),
    (10, "Q", 0, 0, 0, ""), (300, "XYZ", 0, 0, 0, "note"),
    (20, "N", 0, 0, 0, "x" * 101), (20, "|", 2, 1, 2, ""),
    (5000, "N", 0, 0, 0, ""), (1, "N", 0, 0, 0, "")])
_seed = [12345]


def _rand(n):    # a small deterministic pseudo-random generator
    _seed[0] = (_seed[0] * 1103515245 + 12345) % 2 ** 31
    return _seed[0] % n


_SORT_LONG = _ann_lines(
    (1 + _rand(300), "NVA+~"[_rand(5)], _rand(3) - 1, _rand(3), _rand(3),
     ["", "", "(N", "aux"][_rand(4)]) for _ in range(2000))
_HR = {"hr.hea": "hr 1 1000.5 10\nhr.dat 16\n"}
_SUB = {"sub/s.hea": "s 1 360 10\ns.dat 16\n"}
for args, cid, kw in [
        ("-r 100s -a srt", "annsort-ties", {}),
        ("-r 100s -a srt", "annsort-ties-nosort",
         {"env": {"WFDBANNSORT": "0"}}),
        ("-r nohdr -a srt", "annsort-nohdr", {}),
        ("-r hr -a srt", "annsort-hires", {"files": _HR}),
        ("-r sub/s -a srt", "annsort-subdir", {"files": _SUB})]:
    case("wrann", args, cid=cid, stdin=_SORT, **kw)
case("wrann", "-r 100s -a srt", cid="annsort-long", stdin=_SORT_LONG)

# ---------------------------------------------------------------------------
# An out-of-order annotation at time 0 (num 0, chan 0), after later ones:
# sortann lost it, and those inserted after it (5, 0, 3 -> 5), as legacy mode
# does; WFDB-x keeps them (5, 0, 3 -> 0, 3, 5).  With aux strings, and with
# several channels (a later time-0, chan 0 annotation replaces the first).
# sortann on such a file (written with WFDBANNSORT=0): with -o, and in place.
_T0 = _ann_lines([(5, "N", 0, 0, 0, ""), (0, "V", 0, 0, 0, ""),
                  (3, "A", 0, 0, 0, "")])
_T0_AUX = _ann_lines([
    (100, "N", 0, 0, 0, ""), (50, "V", 0, 0, 0, "(VT"),
    (0, "+", 0, 0, 0, "(N"), (20, "N", 0, 0, 0, ""),
    (10, "A", 0, 0, 0, "note"), (200, "N", 0, 0, 0, "")])
_T0_CHAN = _ann_lines([
    (50, "N", 0, 0, 0, ""), (0, "V", 0, 0, 0, ""), (0, "A", 0, 2, 0, ""),
    (0, "N", 0, 1, 0, ""), (25, "N", 0, 1, 0, ""), (0, "J", 0, 0, 0, "x"),
    (60, "N", 0, 3, 0, "")])
# (_T0_AUX as written by wrann with WFDBANNSORT=0)
_T0_FILE = {"100s.t0": bytes.fromhex(
    "005817fc23232074696d65207265736f6c7574696f6e3a203336300000ecffffffff"
    "0100640400ecffffceff001403fc2856540000ecffffceff007002fc284e140400ec"
    "fffff6ff002004fc6e6f7465be040000")}
case("wrann", "-r 100s -a t0", cid="annsort-time0", stdin=_T0)
case("wrann", "-r 100s -a t0", cid="annsort-time0-aux", stdin=_T0_AUX)
case("wrann", "-r 100s -a t0", cid="annsort-time0-chan", stdin=_T0_CHAN)
case("sortann", "-r 100s -a t0 -o srt", cid="sortann-time0", files=_T0_FILE)
case("sortann", "-r 100s -a t0", cid="sortann-time0-inplace",
     files=_T0_FILE)
# An absolute record name (the original sortann, run by the library, does not
# find the file)
case("wrann", "-r {cwd}/100s -a srt", cid="annsort-abspath", stdin=_SORT)

# ---------------------------------------------------------------------------
# Finding files in legacy mode: the WFDB path is searched (several entries;
# the first ones are the directories of the files opened before), names
# containing ".." are refused, ~ is not expanded, a header's signal file is
# found anywhere in the path, and nothing is read from the network (URL
# names and URL path entries; WFDBX_NETWORK and WFDBX_INPUT_DIR are
# ignored).  (Compare the files-* cases of the modern suite.)
_HOME_SR = {"home/hr/" + k[4:]: v for k, v in _SR.items()}
_NET = {"WFDBX_NETWORK": "1"}
_SIB = {"sub/sib.hea": "sib 2 360 21600\n100s.dat 212 200 11 1024 995 21537 0 "
        "MLII\n100s.dat 212 200 11 1024 1011 -3962 0 V5\n"}
for tool, args, cid, kw in [
        ("rdsamp", "-r sr -t s3", "files-wfdb-search",
         {"files": _SR, "wfdb": "sub ."}),
        ("wfdbwhich", "hea sr", "files-wfdb-search-wfdbwhich",
         {"files": _SR, "wfdb": "sub ."}),
        ("wfdbwhich", "-r sub/sr sr.atr", "files-wfdbwhich-addtopath",
         {"files": _SR}),
        ("rdsamp", "-r sub/../100s -t s3", "files-rel-dotdot", {"files": _SR}),
        ("rdsamp", "-r ~/hr/sr -t s3", "files-home-rdsamp",
         {"files": _HOME_SR}),
        ("rdsamp", "-r sr -t s3", "files-inputdir-ignored",
         {"files": _SR, "env": {"WFDBX_INPUT_DIR": "sub"}}),
        ("rdsamp", "-r sub/sib -t s3", "files-hdr-sibling", {"files": _SIB}),
        ("rdsamp", "-r {url}100s -t s3", "files-url-rdsamp", {"env": _NET}),
        ("rdsamp", "-r 100s -t s3", "files-url-path",
         {"env": dict(_NET, WFDB="{url}")}),
        ("wfdbcat", "{url}100s.hea fmt16.hea", "files-url-wfdbcat",
         {"env": _NET})]:
    case(tool, args, cid=cid, **kw)

# ---------------------------------------------------------------------------
# Write errors (output files that are links to /dev/full, and the standard
# output sent there): the original reports the errors of the library and
# exits with status 0.
case("wrsamp", "-o wf", cid="wrerr-wrsamp-dat", stdin=_TXT, full=["wf.dat"])
case("wrsamp", "-o wf", cid="wrerr-wrsamp-hea", stdin=_TXT, full=["wf.hea"])
case("wrann", "-r 100s -a cpy", cid="wrerr-wrann", stdin=_rd("100s.atr.txt"),
     full=["100s.cpy"])
case("snip", "-i 100s -n sf -t s5", cid="wrerr-snip-dat", full=["sf.dat"])
case("mit2edf", "-r fmt16 -o fe.edf", cid="wrerr-mit2edf", full=["fe.edf"])
case("parsescp", "-w -o ex", cid="wrerr-parsescp-des", full=["ex.des"],
     stdin=_rd("example.scp"))
case("rdsamp", "-r 100s", cid="wrerr-stdout-rdsamp", stdout_full=True)
case("rdann", "-r 100s -a atr", cid="wrerr-stdout-rdann", stdout_full=True)
