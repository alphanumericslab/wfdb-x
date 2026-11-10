# Planned work

Work accepted for future versions of WFDB-x, with the decisions already
made, so that it is added together in a few releases rather than in many
small changes. No version is assigned to any item: the items may be
combined or delayed, and their priorities are set when each version is
planned. Each item is implemented in all seven languages, checked by the
conformance suite against the C reference, and documented in the READMEs,
`docs/DIVERGENCES.md`, the user's manual and `CHANGELOG.md`, as every change
is; each release that adds one ends with a review of the whole user's manual
(every chapter, against the code), so that its claims stay accurate and its
chapters consistent with one another. Sections 1 and 2 come from an external
specification (November 2026) reviewed against the WFDB 10.7.0 sources; the
parts of it not listed here were left out deliberately (see the end of this
file).

## 1. Four more command-line tools

Translations of `skewedit`, `wfdbcollate`, `mrgann` and `sumann` of WFDB
10.7.0 (`app/*.c` in `third_party/wfdb-main.zip`), which bring the tools to
37. The C sources decide every option, message, format and exit status; the
expected results are produced by the C reference, and each tool accepts
`--legacy` (the original behavior). The new tools are under the GPL, like
the other tools.

* **`skewedit record skew0 [skew1 ...]`**: change the skews in a header
  without touching the signal files; omitted values reset the remaining
  signals to 0, as in C; multi-segment records as in C (`~` segments
  skipped). Corrections in normal mode, each recorded in
  `docs/DIVERGENCES.md`:
  * the byte offset is kept when an existing skew is changed
    (`16x2:3+512` becomes `16x2:4+512`; C writes `16x2:4`, dropping the
    offset);
  * a skew added to a field with an offset goes before it (`16:4+512`; C
    writes `16+512:4`, which its own header parser then ignores);
  * record names longer than 15 characters (C overflows a 20-byte buffer),
    header lines longer than 255 bytes (C splits them), and a header without
    a record line (C loops forever);
  * the edited header is written next to the header it replaces (or in the
    output directory), through a temporary file, not in the current
    directory;
  * the values (whole numbers, not negative, no more than the signals of
    the record) and every segment header are checked before anything is
    written.
* **`wfdbcollate`**, all three forms: `-i rec ... -o out [-a ann]` (join
  records as a multi-segment record, copying no samples), `out first last`
  (the original numbered segment names), `-s rec -o out [-l len]` (split a
  record into numbered segments: 10 minutes by default, 15 seconds at
  least). With `-a`, the annotation files are combined with the right time
  offsets (a segment may have none, as in C). Records of different sampling
  frequencies or numbers of signals, nested multi-segment records and
  unknown lengths are refused. Outputs go through temporary files; after a
  failure, the files already written are named. The segment names of a new
  master header must lead to the segments from where it is written (also
  with distinct input and output directories), or it is not written.
* **`mrgann -r rec -i ann1 ann2 -o ann3`**, with `-c`, `-C`, `-m0` to `-m3`,
  `-v` and `-h` as in C: merge two annotation files of the same record,
  keeping the first file's annotation where both have one at the same time
  and channel, with C's switching between the files, channel mappings and
  verbose messages. Normal mode refuses invalid channel mappings and an
  output that is one of the inputs (also through another path). `-i`, not
  the `-a` of some examples in the original manual.
* **`sumann -r rec -a ann [-f t] [-t t] [-q] [-o beats.csv rhythms.csv]`**,
  and C's positional form and `-h`: C's summary of annotation counts and of
  rhythm and signal-quality episodes and durations; `-o` appends C's CSV
  rows (and header rows where C writes them, never truncating a file). A
  damaged annotation file is an error, not a summary of what was read.
* **`-F FREQ`** for `mrgann` and `sumann`, as in the other annotation tools:
  for records whose header gives no frequency; it never overrides the
  frequency of a header (an addition, documented as such).

## 2. Partial reads of remote files

Reading a part of a remote file downloads only that part, with HTTP range
requests, below the decoders of the signal and annotation formats, so that
the C-style functions, the high-level functions and the tools all use it,
and remote results are identical to local ones for every format. (The C
library read remote files in pages too, with libcurl, when built with
network support.)

* **Blocks.** Files are read in aligned blocks of 256 KiB, by a single-range
  `GET` (no `HEAD` request first; `Accept-Ranges` is not required), with
  `Accept-Encoding: identity`, so that offsets refer to the file as stored.
  Offsets beyond 4 GiB are exact. A valid `206` response is checked (its
  `Content-Range` and length; one cut short at the end of the file is valid);
  a wrong one is an error, never data. A `416` response gives the end of the
  file. At most 5 redirects; `401`, `403` and `404` give specific errors.
  Two retries for `429`, `503` and interrupted transfers, after a fixed wait.
  The 30-second connection and idle timeouts stay.
* **Cache.** At most 16 MiB of downloaded data in total by default, shared by
  every open URL, least recently used blocks dropped first. A new function
  `wfdbx_clear_network_cache` (with an idiomatic name in each language)
  empties it, and refuses while remote files are open.
* **Settings** (a function in each language, and an environment variable
  for the tools; invalid values refused before any request; network access
  off still sends nothing): `remote_mode` (`auto`, the default; `range`;
  `download`), `remote_block_bytes` (256 KiB), `remote_cache_bytes`
  (16 MiB), `remote_fallback_bytes` (no limit by default).
* **Servers without range requests.** `auto` saves the whole file to a
  temporary file (not in memory), with no size limit by default, so that
  version 1.x stays compatible (decided: not the 64 MiB limit proposed in
  the specification, which would be a change of behavior, so 2.0.0);
  `range` fails without reading the response; `download` always downloads
  the whole file. Temporary files are removed when the file is closed,
  including after an error.
* **A file that changes on the server.** The `ETag` or `Last-Modified` of
  the first response is recorded; if a later block reports another, reading
  that file fails rather than mixing versions. Without either, the file is
  assumed not to change (documented).
* **Transports.** C++ and Rust keep the system `curl` program, one process
  per request, so a connection is not reused between blocks (decided:
  accepted and documented, rather than linking libcurl). R's `url()` and
  MATLAB's `webread`/`websave` fallbacks, where they cannot send a range
  request, read whole files (documented).
* **Tests.** A local HTTP server (127.0.0.1 only) that counts requests and
  bytes, run through each language's own HTTP client: one sample of 1 GiB
  and of 4 GiB+ files within the byte budget, servers that ignore ranges,
  end of file and `416`, damaged responses, redirects, retries and recovery,
  the cache limit, and remote reads equal to local reads for every format
  (format 8 and FLAC may need earlier bytes: documented, not promised).

## Left out deliberately

* FTP and SFTP (since 1.2.2, such names are refused, and mounting the
  server as a local folder is documented).
* Concurrent reads from several threads (the libraries keep global state).
* Conditional range requests (`If-Range`) and validators beyond the check
  above; credentials and their cross-origin rules (WFDB-x sends none);
  waits requested by `Retry-After` beyond the fixed wait.
