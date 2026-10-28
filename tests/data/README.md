# Test records and input files

The inputs of the conformance suite and of the unit tests. Each conformance
case runs in a fresh copy of this directory.

* **Records written by the original C library**, by
  [`tests/reference/gen_records.c`](../reference/gen_records.c): one record
  for each storage format (`fmt8`, `fmt16`, `fmt24`, `fmt32`, `fmt61`,
  `fmt80`, `fmt160`, `fmt212`, `fmt310`, `fmt311`, the FLAC formats `flac8`,
  `flac16`, `flac24`, `flacmf`, ...), multi-frequency records (`mfreq`),
  multi-segment records of fixed and variable layout (`multi`, `vlay`,
  `twog`), skewed signals (`skew`), byte offsets and block-structured files
  (`fmtblk`), null signals (`null`), EDF files, and annotation files that
  use every feature of the annotation format.
* **`100s`**: the first minute of record 100 of the MIT-BIH Arrhythmia
  Database, as distributed with the original package (its `data/`
  directory), with its annotations.
* **Inputs of the format converters**, made by
  [`make_inputs.py`](make_inputs.py) (run from this directory): WAV files,
  EDF+ files, AHA-format files (`1201.ANO`, `1201.CMP`), and headers in the
  old format.
* **SCP-ECG files** for `parsescp`: `example.scp`, a standard 12-lead
  record, and `scp62.scp` and `scp63.scp`, two non-standard files that
  `parsescp` rejects.

Do not change these files without regenerating the golden results of the
conformance suite with the C programs (see
[`docs/conformance.md`](../../docs/conformance.md)).
