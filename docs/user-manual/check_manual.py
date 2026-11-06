"""Check the user's manual of WFDB-x against the code.

Run from the repository root:

    python3 docs/user-manual/check_manual.py [--no-examples]

It reads the LaTeX sources of the manual (docs/user-manual/chapters) and
checks:

* the high-level API of each language: every public function of the code
  has one entry (\\apientry) in that language's chapter, and every entry is
  a public function; each entry lists (as \\item of its params list) every
  parameter of the function in the code, and no other. For Python, the
  signature listing of each entry must also be the exact signature of the
  function (inspect.signature), defaults included. For the other languages,
  the parameters are read from the source files (see LANGUAGES below);
* the WFDB library functions: every function of the library layer (as the
  Python reference exports it) has one entry in the chapter "The WFDB
  library functions", and every entry there is one of them;
* the command-line tools: every tool has one entry in the chapter "The
  command-line tools", and every option of an entry appears in the usage
  text of that tool;
* the examples: every Python listing of style "example" runs without error
  (each in order, in a temporary directory holding a copy of tests/data,
  which is the current directory), unless --no-examples is given.

It prints every difference, and exits with status 1 if there is one.

This file is part of WFDB-x. Copyright (C) 2026 Reza Sameni. GNU General
Public License, version 3 or later; see LICENSE.
"""

import argparse
import inspect
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
CHAPTERS = os.path.join(HERE, "chapters")
sys.path.insert(0, os.path.join(ROOT, "python", "src"))

import wfdbx  # noqa: E402

problems = []


def problem(where, msg):
    problems.append("%s: %s" % (where, msg))


# ---------------------------------------------------------------------------
# Reading the LaTeX sources


def tex(chapter):
    path = os.path.join(CHAPTERS, chapter + ".tex")
    if not os.path.exists(path):
        problem(chapter, "chapter file %s is missing" % os.path.relpath(path,
                                                                          ROOT))
        return ""
    text = open(path, encoding="ascii").read()
    # comments (an unescaped % to the end of the line), outside listings
    out = []
    in_listing = False
    for line in text.split("\n"):
        if re.match(r"\s*\\begin\{lstlisting\}", line):
            in_listing = True
        if not in_listing:
            line = re.sub(r"(?<!\\)%.*", "", line)
        if re.match(r"\s*\\end\{lstlisting\}", line):
            in_listing = False
        out.append(line)
    return "\n".join(out)


def untex(s):
    """The text of a LaTeX argument: escapes and simple macros removed."""
    s = s.replace(r"\_", "_").replace(r"\#", "#").replace(r"\%", "%")
    s = s.replace(r"\&", "&").replace(r"\{", "{").replace(r"\}", "}")
    s = s.replace(r"\textasciitilde{}", "~").replace(r"\textasciitilde", "~")
    s = s.replace(r"\allowbreak", "").replace(r"\-", "")
    s = re.sub(r"\\(code|texttt|textit|emph|opt|cmd|textbf)\{([^{}]*)\}",
               r"\2", s)
    s = s.replace("{", "").replace("}", "")
    return s.strip()


def braced(text, i):
    """The content of the brace group starting at text[i] ('{'), and the
    index after it."""
    assert text[i] == "{"
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "{" and text[j - 1] != "\\":
            depth += 1
        elif text[j] == "}" and text[j - 1] != "\\":
            depth -= 1
            if depth == 0:
                return text[i + 1:j], j + 1
    raise ValueError("unbalanced braces")


LISTING = re.compile(r"\\begin\{lstlisting\}(\[[^\]]*\])?\n(.*?)\n?\s*"
                     r"\\end\{lstlisting\}", re.S)


def listing_options(opt):
    return dict(re.findall(r"(\w+)\s*=\s*(\{[^}]*\}|[^,\]]*)", opt or ""))


def entries(text):
    """The reference entries of a chapter: a list of dicts with name,
    signature (the first signature listing, or None), params (the names of
    the \\item of its params lists) and body."""
    out = []
    starts = [m.start() for m in re.finditer(r"\\apientry\{", text)]
    # an entry ends at the next entry or the next sectioning command
    ends = []
    for k, s in enumerate(starts):
        nxt = starts[k + 1] if k + 1 < len(starts) else len(text)
        m = re.compile(r"\\(part|chapter|section|subsection)\*?\{").search(
            text, s + 1, nxt)
        ends.append(m.start() if m else nxt)
    for s, e in zip(starts, ends):
        name, j = braced(text, s + len(r"\apientry"))
        body = text[j:e]
        sig = None
        for m in LISTING.finditer(body):
            if listing_options(m.group(1)).get("style") == "signature":
                sig = m.group(2)
                break
        params = []
        for m in re.finditer(r"\\begin\{params\}(.*?)\\end\{params\}", body,
                             re.S):
            for it in re.finditer(r"\\item\[", m.group(1)):
                k = it.end()
                depth = 1
                while depth:
                    c = m.group(1)[k]
                    if c == "[" and m.group(1)[k - 1] != "\\":
                        depth += 1
                    elif c == "]" and m.group(1)[k - 1] != "\\":
                        depth -= 1
                    k += 1
                params.append(untex(m.group(1)[it.end():k - 1]))
        out.append({"name": untex(name), "signature": sig, "params": params,
                    "body": body})
    return out


def examples(text, language):
    return [m.group(2) for m in LISTING.finditer(text)
            if listing_options(m.group(1)).get("style") == "example"
            and listing_options(m.group(1)).get("language", "").lower()
            == language.lower()]


def compare_sets(where, documented, actual, what):
    for n in sorted(set(actual) - set(documented)):
        problem(where, "%s %s has no entry" % (what, n))
    for n in sorted(set(documented) - set(actual)):
        problem(where, "entry %s is not a %s of the code" % (n, what))
    seen = set()
    for n in documented:
        if n in seen:
            problem(where, "%s %s has more than one entry" % (what, n))
        seen.add(n)


def compare_params(where, name, documented, actual):
    if list(documented) != list(actual) and set(documented) == set(actual):
        problem(where, "%s: parameters in the order %s, but the code has %s"
                % (name, ", ".join(documented), ", ".join(actual)))
    for p in [p for p in actual if p not in documented]:
        problem(where, "%s: parameter %s is not documented" % (name, p))
    for p in [p for p in documented if p not in actual]:
        problem(where, "%s: documented parameter %s is not in the code" %
                (name, p))


# ---------------------------------------------------------------------------
# The high-level API of each language


def python_api():
    """{name: [parameter names]} of the public high-level functions of the
    Python implementation: the functions that wfdbx exports from its
    high-level modules."""
    mods = ("wfdbx.highlevel", "wfdbx.metadata", "wfdbx.check",
            "wfdbx.resources")
    out = {}
    for n in dir(wfdbx):
        f = getattr(wfdbx, n)
        if inspect.isfunction(f) and f.__module__ in mods and \
                not n.startswith("_"):
            out[n] = list(inspect.signature(f).parameters)
    return out


def check_python():
    text = tex("python")
    api = python_api()
    es = [e for e in entries(text) if e["name"] in api or
          re.fullmatch(r"[a-z_]+", e["name"])]
    compare_sets("python", [e["name"] for e in es], api, "function")
    for e in es:
        if e["name"] not in api:
            continue
        f = getattr(wfdbx, e["name"])
        want = e["name"] + str(inspect.signature(f))
        got = re.sub(r"\s+", " ", (e["signature"] or "")).strip()
        got = got.replace("( ", "(").replace(" )", ")")
        if got != want:
            problem("python", "%s: signature listing %r, but the code has %r"
                    % (e["name"], got, want))
        compare_params("python", e["name"], e["params"], api[e["name"]])
    return text


# The other languages: how to find the public high-level functions and
# their parameters in the source files. Each entry gives a function that
# returns {name: [parameter names]}, read from the code.

def _src(*parts):
    return open(os.path.join(ROOT, *parts), encoding="utf-8").read()


def _split_params(s):
    """The top-level comma-separated items of a parameter list."""
    out, depth, cur = [], 0, ""
    for c in s:
        if c in "([{<":
            depth += 1
        elif c in ")]}>":
            depth -= 1
        if c == "," and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += c
    if cur.strip():
        out.append(cur)
    return [x.strip() for x in out if x.strip()]


LANGUAGES = {}      # filled in below, per language: name -> function


def kotlin_api():
    """Kotlin: the public extension functions "fun Wfdb.NAME(...)" of the
    high-level files (each also exists as a top-level function with the
    same parameters); overloads are merged, parameters in order of first
    appearance."""
    src = "".join(_src("kotlin", "src", "commonMain", "kotlin", "wfdbx", f) +
                  "\n" for f in ("Record.kt", "Check.kt", "Metadata.kt"))
    out = {}
    for m in re.finditer(r"^fun Wfdb\.(\w+)\((.*?)\)(?::[^={\n]*)?\s*[={]",
                         src, re.S | re.M):
        names = out.setdefault(m.group(1), [])
        # ("->" of a function type would unbalance the split)
        for p in _split_params(m.group(2).replace("->", "")):
            n = p.split(":")[0].strip()
            if n not in names:
                names.append(n)
    return out


LANGUAGES["kotlin"] = kotlin_api


def matlab_api():
    """MATLAB/Octave: the functions listed under "High-level functions" and
    "Header metadata" in matlab/+wfdbx/Contents.m, named wfdbx.NAME. The
    parameters of each are the positional arguments of its function line
    (without varargin), then the names of its name-value options: the
    fields of the structure of defaults that it passes to
    wfdbx.internal.hl_options (a struct(...) given in the call, or the
    variable assigned "= struct(...)" before it), in order."""
    contents = _src("matlab", "+wfdbx", "Contents.m")
    names, group = [], False
    for line in contents.split("\n"):
        if re.match(r"%\s*(High-level functions|Header metadata)\b", line):
            group = True
            continue
        if group:
            m = re.match(r"%\s+([a-z_][a-z0-9_]*)\s+-", line)
            if m:
                names.append(m.group(1))
            elif not re.match(r"%\s+\S", line):
                group = False     # (a line with "%" alone ends the group)
    out = {}
    for n in names:
        src = _src("matlab", "+wfdbx", n + ".m")
        code = "\n".join(re.sub(r"%.*", "", l) for l in src.split("\n")
                         if not l.lstrip().startswith("%"))
        code = re.sub(r"\.\.\.[^\n]*\n", " ", code)
        m = re.search(r"^\s*function\b[^(\n]*\(([^)]*)\)", code, re.M)
        params = [p for p in _split_params(m.group(1)) if p != "varargin"]
        h = re.search(r"wfdbx\.internal\.hl_options\(\s*(struct\(|\w+)", code)
        if h:
            if h.group(1) == "struct(":
                start = h.end(1)
            else:
                start = re.search(r"\b%s\s*=\s*struct\(" % h.group(1),
                                  code).end()
            depth, k = 1, start
            while depth:
                depth += {"(": 1, ")": -1}.get(code[k], 0)
                k += 1
            items = _split_params(code[start:k - 1])
            params += [re.sub(r"^'|'$", "", f) for f in items[0::2]]
        out["wfdbx." + n] = params
    return out


LANGUAGES["matlab"] = matlab_api


def r_api():
    """R: the functions exported by r/NAMESPACE that are defined, as
    "NAME <- function(...)" at the start of a line, in the files of the
    high-level API and of the tools' R interface (cli.R); the parameters
    are the formal arguments, in order."""
    exported = set()
    for m in re.finditer(r"^export\(([^)]*)\)", _src("r", "NAMESPACE"), re.M):
        exported.update(n.strip() for n in m.group(1).split(",") if n.strip())
    src = "".join(_src("r", "R", f) + "\n" for f in
                  ("highlevel.R", "highlevel_annot.R", "metadata.R", "check.R",
                   "cli.R"))
    out = {}
    for m in re.finditer(r"^([A-Za-z][\w.]*)\s*<-\s*function\s*"
                         r"\(((?:[^()]|\([^()]*\))*)\)", src, re.M):
        if m.group(1) in exported:
            out[m.group(1)] = [p.split("=")[0].strip()
                               for p in _split_params(m.group(2))]
    return out


LANGUAGES["r"] = r_api


def cpp_api():
    """C++: the functions declared at namespace scope (outside structures
    and classes) in the public high-level header wfdbx/record.hpp."""
    src = _src("cpp", "include", "wfdbx", "record.hpp")
    src = re.sub(r"/\*.*?\*/", " ", src, flags=re.S)
    src = re.sub(r"//[^\n]*", "", src)
    src = re.sub(r"^\s*#[^\n]*", "", src, flags=re.M)
    top, depth = [], 0
    for c in src:          # the text at the depth of the namespace
        if c == "{":
            depth += 1
            if depth == 2:
                top.append("{")
            continue
        if c == "}":
            if depth == 2:
                top.append("}")
            depth -= 1
            continue
        if depth == 1:
            top.append(c)
    top = "".join(top)
    out = {}
    for m in re.finditer(r"([A-Za-z_][\w:<>,\s\*&]*?)\b([a-z_][a-z0-9_]*)\s*"
                         r"\(([^;]*?)\)\s*;", top):
        out[m.group(2)] = [re.search(r"(\w+)$", p.split("=")[0].strip())
                           .group(1) for p in _split_params(m.group(3))]
    return out


LANGUAGES["cpp"] = cpp_api


def rust_api():
    """Rust: the public free functions "pub fn NAME(...)" at the top level
    (column 0) of the high-level modules record.rs, check.rs and
    metadata.rs (each also exists as a method of Wfdb, with the same
    parameters after &mut self); generic parameters (<...>) after the name
    are skipped, and the parameter names are the identifiers before the
    first ':' of each parameter."""
    src = "".join(_src("rust", "src", f) + "\n"
                  for f in ("record.rs", "check.rs", "metadata.rs"))
    out = {}
    for m in re.finditer(r"^pub fn (\w+)\s*(<[^(]*>)?\s*\(", src, re.M):
        # the parameter list: up to the parenthesis that closes it (the
        # types contain parentheses, as in &[(K, Option<V>)])
        depth, i = 1, m.end()
        while depth:
            depth += {"(": 1, ")": -1}.get(src[i], 0)
            i += 1
        params = src[m.end():i - 1].replace("->", "")
        out[m.group(1)] = [p.split(":")[0].strip()
                           for p in _split_params(params)]
    return out


LANGUAGES["rust"] = rust_api


def julia_api():
    """Julia: the functions exported by the module WFDBX (the export
    statements of julia/src/WFDBX.jl and of the high-level files) whose
    names begin with a lowercase letter and that are defined, at the start
    of a line, in the high-level files highlevel.jl, check.jl and
    metadata.jl, as "function NAME(...)" or "NAME(...) = ...". The
    parameters of all the methods of a name are merged, in order of first
    appearance: the positional arguments, then the keyword arguments (after
    ';'), named as in the code, without the optional first argument
    w::Wfdb (the library state) and without the splatted "kw..." of the
    methods that use the default library state."""
    files = ("highlevel.jl", "check.jl", "metadata.jl")
    srcs = [_src("julia", "src", f) for f in files]
    exported = set()
    for s in [_src("julia", "src", "WFDBX.jl")] + srcs:
        for m in re.finditer(r"^export\s+((?:[^\n]*,[ \t]*\n)*[^\n]*)", s,
                             re.M):
            exported.update(n.strip() for n in m.group(1).split(",")
                            if n.strip())
    out = {}
    for s in srcs:
        for m in re.finditer(r"^(?:function\s+)?([a-z]\w*)\(", s, re.M):
            name = m.group(1)
            if name not in exported:
                continue
            # the parameter list: up to the parenthesis that closes it
            depth, i = 1, m.end()
            while depth:
                depth += {"(": 1, ")": -1}.get(s[i], 0)
                i += 1
            if not m.group(0).startswith("function") and \
                    not re.match(r"\s*(::[^=\n]*)?=(?!=)", s[i:]):
                continue        # (a call at the start of a line, not a method)
            # (";" begins the keyword arguments; "<:" and "->" would
            # unbalance the split)
            params = s[m.end():i - 1].replace(";", ",").replace("<:", "")
            params = params.replace(">:", "").replace("->", "")
            names = out.setdefault(name, [])
            for p in _split_params(params):
                n = re.split(r"[:=]", p)[0].strip()
                if n == "w" and "Wfdb" in p or n.endswith("..."):
                    continue
                if n not in names:
                    names.append(n)
    return out


LANGUAGES["julia"] = julia_api


def check_other(lang):
    text = tex(lang)
    if lang not in LANGUAGES:
        problem(lang, "no rule to read the API of this language from the code")
        return text
    api = LANGUAGES[lang]()
    es = entries(text)
    compare_sets(lang, [e["name"] for e in es], api, "function")
    for e in es:
        if e["name"] in api:
            compare_params(lang, e["name"], e["params"], api[e["name"]])
            if not e["signature"]:
                problem(lang, "%s: no signature listing" % e["name"])
    return text


# ---------------------------------------------------------------------------
# The library functions and the tools


LIBRARY_MODULES = ("wfdbx._wfdbio", "wfdbx._signal", "wfdbx._annot",
                   "wfdbx._calib", "wfdbx._wfdbinit", "wfdbx._ecgcodes")


def library_functions():
    out = set()
    for n in dir(wfdbx):
        f = getattr(wfdbx, n)
        if inspect.isfunction(f) and f.__module__ in LIBRARY_MODULES and \
                not n.startswith("_"):
            out.add(n)
    return out


def check_library():
    es = entries(tex("library"))
    compare_sets("library", [e["name"] for e in es], library_functions(),
                 "library function")


def tools():
    d = os.path.join(ROOT, "python", "src", "wfdbx", "apps")
    return sorted(f[:-3] for f in os.listdir(d)
                  if f.endswith(".py") and not f.startswith("_"))


def usage(tool):
    env = dict(os.environ, PYTHONPATH=os.path.join(ROOT, "python", "src"))
    out = ""
    # (some tools, as in C, print their usage only without arguments, and
    # take -h as a record name)
    for args in (["-h"], []):
        p = subprocess.run([sys.executable, "-m", "wfdbx.cli", tool] + args,
                           capture_output=True, text=True, env=env,
                           stdin=subprocess.DEVNULL, timeout=60)
        out += p.stdout + p.stderr
    return out


# options that every tool accepts, which the usage texts do not list
COMMON_OPTIONS = {"--legacy"}


def check_tools():
    es = entries(tex("tools"))
    compare_sets("tools", [e["name"] for e in es], tools(), "tool")
    for e in es:
        if e["name"] not in tools():
            continue
        text = usage(e["name"])
        for p in e["params"]:
            for opt in re.findall(r"(?<![\w-])(--?[A-Za-z0-9][\w-]*)", p):
                if opt in COMMON_OPTIONS:
                    continue
                if not re.search(r"(?<![\w-])%s(?![\w-])" % re.escape(opt),
                                 text):
                    problem("tools", "%s: option %s is not in its usage text"
                            % (e["name"], opt))


# ---------------------------------------------------------------------------
# Examples


def run_python_examples(chapter, text):
    exs = examples(text, "Python")
    d = tempfile.mkdtemp()
    try:
        data = os.path.join(d, "data")
        shutil.copytree(os.path.join(ROOT, "tests", "data"), data)
        env = dict(os.environ, PYTHONPATH=os.path.join(ROOT, "python", "src"))
        for k in ("WFDB", "WFDBX_INPUT_DIR", "WFDBX_OUTPUT_DIR",
                  "WFDBX_NETWORK"):
            env.pop(k, None)
        for i, code in enumerate(exs):
            p = subprocess.run([sys.executable, "-c", code], cwd=data,
                               capture_output=True, text=True, env=env,
                               stdin=subprocess.DEVNULL, timeout=300)
            if p.returncode != 0:
                problem(chapter, "Python example %d fails:\n%s\n%s" %
                        (i + 1, code, p.stderr[-2000:]))
    finally:
        shutil.rmtree(d)
    return len(exs)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--no-examples", action="store_true",
                    help="do not run the examples")
    a = ap.parse_args()
    texts = {"python": check_python()}
    for lang in ("cpp", "rust", "julia", "r", "matlab", "kotlin"):
        texts[lang] = check_other(lang)
    check_library()
    check_tools()
    n = 0
    if not a.no_examples:
        for f in sorted(os.listdir(CHAPTERS)):
            if f.endswith(".tex"):
                n += run_python_examples(f[:-4], tex(f[:-4]))
    for p in problems:
        print(p)
    print("%d difference%s between the manual and the code%s" %
          (len(problems), "" if len(problems) == 1 else "s",
           "" if a.no_examples else "; %d Python examples run" % n))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
