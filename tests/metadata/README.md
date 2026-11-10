# Metadata tests

Tests of the header metadata functions of WFDB-x (an addition, with no
counterpart in the WFDB Software Package): `read_metadata`, `get_metadata`,
`set_metadata`, `remove_metadata` and `update_metadata`, the `metadata` of
`read_header` and the `metadata` argument of `write_record`. Every
implementation runs the same cases and must give the same results and write
byte-identical headers.

| File | Contents |
|---|---|
| `headers/` | The input headers. They name the signal file `100s.dat` of the test record 100s (`tests/data`), and `multi.hea` is a copy of the multi-segment header `tests/data/multi.hea`. |
| `cases.json` | The cases: a header, an operation (`read`, `get`, `set`, `remove` or `update`) and its arguments. |
| `expected.json` | The result of each case: `entries` (read), `value` (get; `null` for none), `count` (remove), `error` (`"argument"` for an invalid argument, `"file"` for a file that cannot be read or written), `warnings` (the number of warnings), and `output`, the header after a change that succeeds. |
| `expected/` | The headers after each change that succeeds. After a case that fails, the header must be unchanged. |
| `cases.tsv` | The same cases and results in plain text, for the languages that have no JSON parser in their standard library (see below). |
| `make_expected.py` | Writes `expected.json` and `expected/` with the Python implementation. |
| `check_c.py` | Checks every header of `headers/` and `expected/` with the original C programs (see below). |

In the JSON files, a string stands for bytes: each character from U+0000 to
U+00FF is one byte (so `"José"` is the bytes `4a 6f 73 e9`). Each
implementation compares them as it compares the text of a header elsewhere
(as bytes, or as one character per byte).

`cases.tsv` has one line per case (after a first line, beginning with `#`,
that names the columns), with ten columns separated by tabs: `name`,
`header`, `op`, `key`, `value`, `changes`, `error` (`-`, `argument` or
`file`), `warnings`, `result` and `output` (`-` if none). Every string is
written as `x` followed by its bytes in hexadecimal (so `x` alone is the
empty string), and `-` means none. `changes` (update) and `result` (read)
are lists of `KEY:VALUE` pairs separated by commas (empty for an empty
list); `result` is the value for get, the count for remove, and `-` for the
others.

To run a case: copy `headers/H.hea` into an empty directory, call the
function on the record named by that path (without `.hea`), and compare the
result and the header with `expected.json` and `expected/`. No other file
may be left in the directory (the temporary file of a change is renamed or
removed).

## The rules

These are the rules that every implementation follows; the expected results
were produced by the Python implementation (`python/src/wfdbx/metadata.py`)
and checked by hand.

**Lines.** A header is split after each line feed (LF). Each line has a
line ending: CR LF, LF, or none (the last line of a file that does not end
with a line feed). The content of a line is the line without its ending.

**Info strings.** The record line is the first line whose content has a
first token (a run of bytes other than space, tab, CR and LF, before any
NUL byte) that does not begin with `#`, as the header parser of the C library
(`readheader`) finds it: empty lines, blank lines (spaces, tabs and CRs
only) and comment lines before it (a `#` after leading spaces or tabs
included) are skipped. The lines before it are not info strings, and are
never read or changed. Every line after the record line whose content
begins with `#` (in its first byte) is an info string, so a comment
between two signal lines is an info string too. This is how the function
`getinfo()` of WFDB-x reads a header (since version 1.2.2), in every mode
for the metadata functions. The original C `getinfo()`, and WFDB-x's
`getinfo()` in legacy mode, take the first line that does not begin with
`#` for the record line: for a header whose first line is empty
(`headers/leading.hea`: an empty line, `# Age: preamble`, the record line,
the signal lines and `# Age: actual`), they also return `Age: preamble`,
which the metadata functions never read or change (read gives
`[("Age", "actual")]`, and set replaces the `# Age: actual` line). Only the header file (`.hea`) is read, never the `.info`
file that `getinfo()` also reads. A header with no record line has no info
strings; changing its metadata is an argument error.

**Entries.** An info string is an entry if the text after its `#` contains
a colon. The key is the text before the first colon, and the value is the
text after it; spaces, tabs, VT, FF and CR are removed at both ends of each.
If the key is then empty, or contains `#`, the info string is a free
comment. Free comments are never returned and never changed.

**Keys** are compared without regard to letter case, with A-Z and a-z only
(no other character is changed: `É` and `é` differ). Entries are returned
in file order. If two or more entries have the same key, read and get
return the first, and give one warning for each such key, naming its line
numbers (from 1); set and update refuse to change that key (argument
error); remove removes all of them.

**Arguments.** Before a key or value is checked, the spaces, tabs, VT, FF
and CR at both ends are removed. A key must then not be empty, and must not
contain `:`, `#`, CR, LF or NUL. A value must not contain CR, LF or NUL; it
may be empty. In `update`, no two keys may be equal (ignoring letter case);
a value of none/null/missing means "remove". get with an invalid key is an
argument error. Every argument is checked before the header is read, and
every change before anything is written: after an error, the header is
unchanged.

**Writing.** An entry is written as `# Key: value`: `#`, a space, the key
as the caller spelled it, `:`, and, if the value is not empty, a space and
the value. So an empty value is written `# Key:`, with no trailing space.

* set: if the header has one entry for the key, its line is replaced (its
  line ending is kept), even if the value is the same (the line is then
  rewritten in the form above). Otherwise a new line is inserted.
* remove: every line of an entry for the key is deleted, with its line
  ending. It returns the number of lines deleted.
* update: the changes are applied in the order given, as set or remove.
* A new line is inserted after the last info string, or, if the header has
  none, after its last line whose content is not blank (not only spaces,
  tabs, VT, FF and CR). Its line ending is that of the record line, or, if
  the record line has none, that of the first line that has one, or CR LF.
  If the line before it has no line ending, that line gets the same ending.
* Every other byte of the header is kept.
* If nothing changes (and `dir` is not given), nothing is written.
* The new header is written to a temporary file in the directory of the
  destination, which then replaces the destination (rename), keeping its
  permissions.

**Which file.** The header is opened as the library opens the header of a
record (`wfdb_open` with type `hea`, after removing a trailing `.hea` from
the name): under the input directory, or as given for an absolute path, a
`~` path or a URL (a URL only if network access is on). The record name
`-` (standard input) is an argument error; a header that cannot be opened
is a file error. A change is written to the file that was read, unless the
call gives `dir`: then it is written to the file of the same name in the
directory `dir` (which must exist, else a file error), and the header that
was read is unchanged. A header read from a URL cannot be changed without
`dir` (argument error).

**read_header and write_record.** `read_header` returns the entries as
`read_metadata` does (from the `.hea` file only); for an EDF record (which
has no `.hea` file) and for a header read from the standard input (`-`), it
returns no entries. `write_record` writes the
entries given in its `metadata` argument (a mapping or a list of pairs; a
value of none is an argument error) after its comments, through `putinfo`,
as `# Key: value`. Its keys must be unique (ignoring letter case), and none
may be the key of an entry in `comments`; this is checked before any file is
created.

## Checks with the C programs

`check_c.py` runs the C programs `rdsamp` and `wfdbdesc` on every header
of `headers/` and `expected/`, with the signal files of the test record
100s. It checks that `wfdbdesc` prints exactly the info strings of the
header, and that `rdsamp` reads the same samples as with the unchanged
input header, with nothing printed on its standard error output (so no
checksum error). By default, the programs are those of the C reference of
WFDB-x (built by `tests/reference/build_reference.sh`, with
`divergences.patch`), whose `getinfo()` finds the record line by the rule
above. With `--original`, they are those of the unmodified package
(`WFDBX_ORIGINAL=1`, as `benchmarks/c/build.sh` builds them), and the
expected info strings are those of the original `getinfo()` (for the
headers made from `leading` and `leadingblank`, the comment before the
record line too). From the repository root:

```sh
python3 tests/metadata/check_c.py --c-bin build/wfdb-ref/bin
python3 tests/metadata/check_c.py --original --c-bin benchmarks/build/c/wfdb/bin
```
