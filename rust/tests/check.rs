//! Tests of `check_record` (`wfdbx::check`), ports of
//! python/tests/test_check.py. The corpus (one broken record for each issue
//! code, a clean record, records of tests/data, annotation files) is made
//! by python/tests/check_corpus.py in a temporary directory; the report of
//! each case must be the lines of its `expected.txt` (Python's reports).
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It tests WFDB-x; it has no counterpart in the original package.
//
// Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

use std::path::PathBuf;
use std::process::Command;
use std::sync::Mutex;

use wfdbx::*;

/// The tests change library settings of the process: one at a time.
static LOCK: Mutex<()> = Mutex::new(());

fn repo() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..")
}

/// A corpus made by check_corpus.py in a new temporary directory, removed
/// when the value is dropped.
struct Corpus {
    dir: PathBuf,
    _guard: std::sync::MutexGuard<'static, ()>,
}

impl Corpus {
    fn new(name: &str) -> Corpus {
        let guard = LOCK
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let dir =
            std::env::temp_dir().join(format!("wfdbx-rust-check-{}-{}", name, std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let python = std::env::var("PYTHON").unwrap_or_else(|_| "python3".into());
        let st = Command::new(python)
            .arg(repo().join("python/tests/check_corpus.py"))
            .arg(&dir)
            .arg(repo().join("tests/data"))
            .env("PYTHONPATH", repo().join("python/src"))
            .stdout(std::process::Stdio::null())
            .status()
            .expect("python3 (with NumPy) is needed to make the check_record corpus");
        assert!(st.success(), "check_corpus.py failed");
        Corpus { dir, _guard: guard }
    }

    fn opt(&self) -> ReadOptions {
        ReadOptions {
            input_dir: Some(self.dir.to_string_lossy().into_owned()),
            ..Default::default()
        }
    }

    fn check(&self, w: &mut Wfdb, record: &str, anns: &[&str]) -> CheckReport {
        w.check_record_with(record, anns, &self.opt()).unwrap()
    }
}

impl Drop for Corpus {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

#[test]
fn corpus() {
    let c = Corpus::new("corpus");
    let cases = std::fs::read_to_string(c.dir.join("cases.txt")).unwrap();
    let expected = std::fs::read_to_string(c.dir.join("expected.txt")).unwrap();
    let mut w = Wfdb::new();
    let mut out = String::new();
    let mut seen = std::collections::BTreeSet::new();
    for line in cases.lines() {
        let words: Vec<&str> = line.split(' ').filter(|x| !x.is_empty()).collect();
        let (rec, anns) = words.split_first().unwrap();
        let r = c.check(&mut w, rec, anns);
        assert_eq!(r.record, rec.as_bytes());
        assert_eq!(
            r.ok,
            !r.issues.iter().any(|i| i.severity == Severity::Error)
        );
        assert_eq!(r.to_string(), r.lines().join("\n"));
        seen.extend(r.issues.iter().map(|i| i.code));
        out.push_str(&format!("== {line}\n"));
        for l in r.lines() {
            out.push_str(&l);
            out.push('\n');
        }
    }
    assert_eq!(out, expected);
    // every issue code is produced (file_large: see the unit test)
    assert_eq!(seen.len(), 44);
    assert!(!seen.contains("file_large"));
}

#[test]
fn issue_fields() {
    let c = Corpus::new("fields");
    let mut w = Wfdb::new();
    let r = c.check(&mut w, "d_cksum", &[]);
    assert!(!r.ok && r.issues.len() == 1);
    let i = &r.issues[0];
    assert_eq!(
        (i.severity, i.code, i.r#where.as_str()),
        (Severity::Error, "checksum", "signal 1")
    );
    assert_eq!(
        i.message,
        "the checksum does not match: the header gives 1, the samples sum to 0"
    );
    assert_eq!(i.to_string(), format!("error: signal 1: {}", i.message));
    let r = c.check(&mut w, "clean", &["atr"]);
    assert!(r.ok && r.issues.is_empty());
    assert_eq!(r.to_string(), "no problems found");
    // warnings and infos only: ok
    let r = c.check(&mut w, "nolen", &[]);
    assert!(r.ok);
    assert_eq!(
        r.issues.iter().map(|i| i.severity).collect::<Vec<_>>(),
        [Severity::Warning, Severity::Info]
    );
    assert_eq!(
        r.issues[0].to_string(),
        "warning: the record length is not specified"
    );
}

#[test]
fn arguments_and_sample_record() {
    let _g = LOCK
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let mut w = Wfdb::new();
    assert!(w.check_record("", &[]).is_err());
    // the sample record: its header gives no units (as in the MIT-BIH
    // Arrhythmia Database), which is all that is reported
    let opt = ReadOptions {
        input_dir: Some(repo().join("tests/data").to_string_lossy().into_owned()),
        ..Default::default()
    };
    let r = w.check_record_with("100s", &["atr"], &opt).unwrap();
    assert!(r.ok);
    assert_eq!(
        r.lines(),
        [
            "warning: signal 0: the units are not specified",
            "warning: signal 1: the units are not specified"
        ]
    );
}

#[test]
fn settings_restored() {
    // legacy mode off during the call and restored; the library prints
    // nothing (its print setting is restored); the input directory is
    // restored
    let c = Corpus::new("settings");
    let mut w = Wfdb::new();
    let prev_dir = w.wfdbx_get_input_dir();
    w.wfdbx_set_legacy(1);
    let r = c.check(&mut w, "nofs", &["nofile"]);
    assert_eq!(w.wfdbx_get_legacy(), 1);
    w.wfdbx_set_legacy(0);
    // (legacy mode would assume 250 Hz: the frequency is reported missing)
    assert_eq!(r.issues[0].code, "fs_missing");
    assert_eq!(w.wfdbx_get_input_dir(), prev_dir);
    // quiet before: quiet after (the library's messages are recorded)
    w.wfdbquiet();
    c.check(&mut w, "nofs", &["nofile"]);
    w.isigopen("no_such_record", &mut [], 0);
    assert!(String::from_utf8_lossy(&w.wfdberror()).contains("no_such_record"));
    w.wfdbquit();
}

#[test]
fn modification_labels() {
    // codes 42 and 43 defined by the file's modification labels have a
    // mnemonic (no warning); the definitions do not outlive the check
    let c = Corpus::new("labels");
    let mut w = Wfdb::new();
    w.wfdbquiet();
    w.setannstr(42, "QQ");
    w.setanndesc(42, "my beat");
    let ann = Annotations {
        samples: vec![10, 20, 30],
        codes: vec![42, 1, 43],
        ..Default::default()
    };
    w.write_annotations("clean", "lab", &ann, 0.0, Some(&c.dir))
        .unwrap();
    w.setannstr(-42, "[42]");
    w.setanndesc(-42, None::<&str>);
    let r = c.check(&mut w, "clean", &["lab"]);
    assert_eq!(
        r.lines(),
        ["warning: annotator lab: 1 annotation uses a code without a mnemonic: at sample 30 (code 43)"]
    );
    assert_eq!(w.annstr(42), b"[42]");
}
