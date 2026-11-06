# WFDB-x user's manual

The user's manual of WFDB-x, in LaTeX: the concepts shared by the seven
implementations, one chapter for the users of each language (Python, C++,
Rust, Julia, R, MATLAB/Octave and Kotlin), and a reference of the WFDB
library functions, the command-line tools, the storage formats and the
annotation codes.

* **PDF:** [`wfdb-x-user-manual.pdf`](wfdb-x-user-manual.pdf), in this
  directory, built from these sources.
* **Sources:** `wfdb-x-user-manual.tex` (the main file), `preamble.tex`
  (the design: fonts, colors, headings, listings and the macros of the
  manual) and `chapters/*.tex`.

## Building the PDF

With a TeX distribution that includes the fonts XCharter, Source Sans Pro
and Inconsolata (TeX Live with `texlive-fonts-extra`, MiKTeX, or Overleaf):

```sh
cd docs/user-manual
latexmk -pdf wfdb-x-user-manual.tex
```

or `pdflatex wfdb-x-user-manual.tex`, run three times (for the table of
contents and the cross-references). On Overleaf, upload this directory and
set the main document to `wfdb-x-user-manual.tex` and the compiler to
pdfLaTeX.

## Keeping the manual in step with the code

Every change to WFDB-x is reflected in the manual, in the same change (see
[`docs/porting-guide.md`](../porting-guide.md)), and the PDF is rebuilt.
`check_manual.py` compares the manual with the code:

```sh
python3 docs/user-manual/check_manual.py          # from the repository root
```

It checks that every public function of the high-level API of each
language has an entry in that language's chapter, with every parameter of
the code and no other (and, for Python, the exact signature, defaults
included), that every WFDB library function and every command-line tool
has an entry in the reference, that every option of a tool's entry is an
option of that tool, and it runs the Python examples. It reports each
difference, and exits with a nonzero status if there is one.

## Writing conventions

So that the chapters read as one manual, and so that `check_manual.py` can
read them:

* **Wording.** Plain, technical, impersonal English (no "you"); "WFDB-x"
  for the project; the C names of the WFDB functions and tools. The source
  is ASCII.
* **Markup.** `\code{...}` for identifiers and values (escape `_ # % & { }`
  as `\_ \# \% \& \{ \}`), `\cmd{...}` for command lines, `\opt{...}` for
  command-line options, `\file{...}` for files and directories. Boxes:
  `note`, `tip`, and `phibox` for patient data.
* **Reference entries.** Each function or tool of a reference section is
  one entry:

  ```latex
  \apientry{read\_metadata}{Read the metadata of a record}
  \begin{lstlisting}[language=Python,style=signature]
  read_metadata(record, *, input_dir=None, network=None)
  \end{lstlisting}
  What the function does, in a few sentences.
  \begin{params}
  \item[record] Record name: ...
  \item[input\_dir] ...
  \end{params}
  \returns{A list of (key, value) pairs ...}
  \raises{\code{IOError} if ...; \code{ValueError} if ...}
  \begin{lstlisting}[language=Python,style=example]
  ...
  \end{lstlisting}
  ```

  The name in `\apientry` is the name of the function as it is called in
  that language (`read\_metadata`, `wfdbx.read\_metadata`, `readMetadata`,
  ...), or the name of the tool. The first listing after it, of style
  `signature`, is the call syntax, copied from the code. Every parameter
  is one `\item` of `params`, named exactly as in the code; a parameter
  without a name in the code (a positional argument of a MATLAB function,
  for example) is named as in the help text of the function.
* **Examples** are listings of style `example`. The Python examples are run
  by `check_manual.py`, in a temporary directory that holds a copy of
  `tests/data` (the record `100s` among others), as the current directory
  and the input directory.
* **Chapters** begin with `\chapter{...}`, a `\label{chap:...}` and, in
  Part II, `\chapterlanguage{python}` (or `cpp`, `rust`, `julia`, `r`,
  `matlab`, `kotlin`). Labels: `chap:`, `sec:`, `tab:`, `fig:`.
