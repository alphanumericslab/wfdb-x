//! WFDB-x: the header metadata functions (read_metadata, get_metadata,
//! set_metadata, remove_metadata, update_metadata) and the metadata of
//! read_header and write_record.
//!
//! The shared cases (tests/metadata/cases.tsv, with the expected headers in
//! tests/metadata/expected/) are run by every implementation of WFDB-x,
//! which must give the same results and write byte-identical headers. A URL
//! is served by a local HTTP server on 127.0.0.1 (no other host is
//! contacted).
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

use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

use wfdbx::cstd;
use wfdbx::record::{Error, ReadOptions, WriteOptions};
use wfdbx::*;

/// The tests change the environment and the current directory: they run
/// one at a time.
static LOCK: Mutex<()> = Mutex::new(());

const ENV: [&str; 4] = [
    "WFDB",
    "WFDBX_INPUT_DIR",
    "WFDBX_OUTPUT_DIR",
    "WFDBX_NETWORK",
];

fn meta_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../tests/metadata")
}

/// A fresh, empty current directory (without the WFDB and WFDBX_
/// variables) while the value lives.
struct Dir {
    old: PathBuf,
    dir: PathBuf,
    _guard: MutexGuard<'static, ()>,
}

impl Dir {
    fn new(name: &str) -> Dir {
        let guard = LOCK
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        for k in ENV {
            std::env::remove_var(k);
        }
        let dir = std::env::temp_dir().join(format!("wfdbx-meta-{}-{}", name, std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let dir = dir.canonicalize().unwrap();
        let old = std::env::current_dir().unwrap();
        std::env::set_current_dir(&dir).unwrap();
        Dir {
            old,
            dir,
            _guard: guard,
        }
    }

    /// Copies the input header `name` (tests/metadata/headers) into the
    /// directory `to` (relative to this directory); returns the record
    /// name (its absolute path, without `.hea`).
    fn copy(&self, name: &str, to: &str) -> Vec<u8> {
        let d = self.dir.join(to);
        std::fs::copy(
            meta_dir().join("headers").join(format!("{name}.hea")),
            d.join(format!("{name}.hea")),
        )
        .unwrap();
        cstd::os_to_bytes(d.join(name).into_os_string())
    }

    /// The names of the files in the directory `sub`, sorted.
    fn files(&self, sub: &str) -> Vec<String> {
        let mut v: Vec<String> = std::fs::read_dir(self.dir.join(sub))
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        v.sort();
        v
    }
}

impl Drop for Dir {
    fn drop(&mut self) {
        let _ = std::env::set_current_dir(&self.old);
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn quiet() -> Wfdb {
    let mut w = Wfdb::new();
    w.wfdbquiet();
    w
}

fn b(s: &str) -> Vec<u8> {
    s.as_bytes().to_vec()
}

fn pairs(v: &[(&str, &str)]) -> Vec<(Vec<u8>, Vec<u8>)> {
    v.iter().map(|(k, v)| (b(k), b(v))).collect()
}

/// The class of an error, as the shared cases name it: "file" for a file
/// that cannot be read or written, "argument" for any other.
fn kind(e: &Error) -> &'static str {
    let m = e.message();
    if m.starts_with("can't read header for record")
        || m.starts_with("can't write header for record")
        || (m.starts_with("directory ") && m.ends_with(" does not exist"))
    {
        "file"
    } else {
        "argument"
    }
}

/// The bytes of a string of cases.tsv (`x` and hexadecimal digits), or
/// `None` for `-`.
fn unhex(s: &str) -> Option<Vec<u8>> {
    if s == "-" {
        return None;
    }
    let h = s.strip_prefix('x').expect("string of cases.tsv");
    Some(
        (0..h.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&h[i..i + 2], 16).unwrap())
            .collect(),
    )
}

/// A list of `KEY:VALUE` pairs of cases.tsv.
fn unhex_list(s: &str) -> Vec<(Vec<u8>, Option<Vec<u8>>)> {
    if s.is_empty() {
        return Vec::new();
    }
    s.split(',')
        .map(|p| {
            let (k, v) = p.split_once(':').unwrap();
            (unhex(k).unwrap(), unhex(v))
        })
        .collect()
}

/// The marker set as the last message before each case: a warning
/// replaces it.
const MARK: &[u8] = b"(no warning)\n";
const WARNING: &[u8] = b"WFDB-x: header of record ";

#[test]
fn shared_cases() {
    let tsv = std::fs::read_to_string(meta_dir().join("cases.tsv")).unwrap();
    let mut n = 0;
    for line in tsv.lines().filter(|l| !l.starts_with('#') && !l.is_empty()) {
        let c: Vec<&str> = line.split('\t').collect();
        assert_eq!(c.len(), 10, "{line}");
        let (name, header, op) = (c[0], c[1], c[2]);
        let d = Dir::new(&format!("case-{name}"));
        let rec = d.copy(header, ".");
        let mut hea = rec.clone();
        hea.extend_from_slice(b".hea");
        let hea = cstd::bytes_to_path(&hea);
        let before = std::fs::read(&hea).unwrap();
        let mut w = quiet();
        w.wfdb_error(MARK);
        let key = unhex(c[3]);
        let value = unhex(c[4]);
        // (the result, as cases.tsv gives it)
        let got: Result<Option<String>, Error> = match op {
            "read" => w.read_metadata(&rec).map(|md| {
                Some(
                    md.iter()
                        .map(|(k, v)| format!("x{}:x{}", hex(k), hex(v)))
                        .collect::<Vec<_>>()
                        .join(","),
                )
            }),
            "get" => w
                .get_metadata(&rec, key.unwrap())
                .map(|v| Some(v.map_or("-".to_string(), |v| format!("x{}", hex(&v))))),
            "set" => w
                .set_metadata(&rec, key.unwrap(), value.unwrap())
                .map(|_| Some("-".to_string())),
            "remove" => w
                .remove_metadata(&rec, key.unwrap())
                .map(|n| Some(n.to_string())),
            "update" => w
                .update_metadata(&rec, &unhex_list(c[5]))
                .map(|_| Some("-".to_string())),
            _ => panic!("unknown operation {op}"),
        };
        let msg = w.wfdberror();
        let warnings = if msg == MARK {
            0
        } else {
            assert!(msg.starts_with(WARNING), "{name}: {msg:?}");
            1
        };
        assert_eq!(warnings.to_string(), c[7], "{name}: warnings");
        match got {
            Ok(r) => {
                assert_eq!(c[6], "-", "{name}: succeeded, expected an error");
                assert_eq!(r.as_deref(), Some(c[8]), "{name}: result");
            }
            Err(e) => {
                assert_eq!(kind(&e), c[6], "{name}: {}", e.message());
                assert_eq!(c[8], "-", "{name}");
            }
        }
        let after = std::fs::read(&hea).unwrap();
        if c[9] == "-" {
            assert_eq!(after, before, "{name}: header changed");
        } else {
            let expected = std::fs::read(meta_dir().join(c[9])).unwrap();
            assert_eq!(after, expected, "{name}: header");
        }
        // no temporary file is left behind
        assert_eq!(d.files("."), [format!("{header}.hea")], "{name}");
        n += 1;
    }
    assert_eq!(n, 49);
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|c| format!("{c:02x}")).collect()
}

#[test]
fn duplicate_warning_text() {
    let d = Dir::new("dupwarn");
    let rec = d.copy("dups", ".");
    let mut w = quiet();
    assert_eq!(w.get_metadata(&rec, "AGE").unwrap(), Some(b("40")));
    let mut expected = b"WFDB-x: header of record ".to_vec();
    expected.extend_from_slice(&rec);
    expected.extend_from_slice(
        b" has more than one entry for key age (lines 4, 6); the first is used\n",
    );
    assert_eq!(w.wfdberror(), expected);
    let e = w.set_metadata(&rec, "Age", "1").unwrap_err();
    assert!(e
        .message()
        .ends_with("has more than one entry for key Age (lines 4, 6); remove them first"));
}

/// Options of the small records written by the tests.
fn wopt() -> WriteOptions {
    WriteOptions {
        gains: vec![200.0],
        adcres: vec![12],
        units: vec![Some("mV".into())],
        ..Default::default()
    }
}

#[test]
fn read_header_and_write_record() {
    let _d = Dir::new("hl");
    let mut w = quiet();
    let x = [0i32; 10];
    let opt = WriteOptions {
        comments: vec![b("a comment"), b("Site: B")],
        metadata: pairs(&[("Age", " 63 "), ("Notes", "")]),
        ..wopt()
    };
    w.write_record("w", &x, 1, 100.0, &opt).unwrap();
    let data = std::fs::read("w.hea").unwrap();
    assert!(data.ends_with(b"#a comment\r\n#Site: B\r\n# Age: 63\r\n# Notes:\r\n"));
    let h = w.read_header("w", false).unwrap();
    assert_eq!(
        h.metadata,
        pairs(&[("Site", "B"), ("Age", "63"), ("Notes", "")])
    );
    assert_eq!(
        h.comments,
        [b("a comment"), b("Site: B"), b(" Age: 63"), b(" Notes:")]
    );
    let opt = WriteOptions {
        metadata: pairs(&[("Dx", "426783006")]),
        ..wopt()
    };
    w.write_record("v", &x, 1, 100.0, &opt).unwrap();
    assert_eq!(w.read_metadata("v").unwrap(), pairs(&[("Dx", "426783006")]));
    // the free functions, and read_header_with
    write_record_physical("p", &[0.0; 4], 1, 100.0, &opt).unwrap();
    assert_eq!(read_metadata("p").unwrap(), pairs(&[("Dx", "426783006")]));
    let h = read_header_with("p", &ReadOptions::default()).unwrap();
    assert_eq!(h.metadata, pairs(&[("Dx", "426783006")]));
    // a header without entries; an EDF file named directly (no .hea) is
    // still read, with no entries
    let data = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../tests/data");
    let opt = ReadOptions {
        input_dir: Some(data.to_string_lossy().into_owned()),
        ..Default::default()
    };
    let h = w.read_header_with("100s", &opt).unwrap();
    assert_eq!(h.metadata.len(), 1); // "Produced by xform ...: 0"
    let h = w.read_header_with("100s.edf", &opt).unwrap();
    assert_eq!((h.nsig, h.metadata.len()), (2, 0));
    let h = w.read_header_with("fmt16.edf", &opt).unwrap();
    assert!(h.nsig > 0);
    assert!(h.metadata.is_empty());
}

#[test]
fn write_record_metadata_errors() {
    let d = Dir::new("wrerr");
    let mut w = quiet();
    let x = [0i32; 10];
    for md in [
        pairs(&[("a:b", "1")]),
        pairs(&[("Age", "1\n2")]),
        pairs(&[("Age", "1"), ("AGE", "2")]),
        pairs(&[("", "x")]),
        pairs(&[("A#", "x")]),
        vec![(b("Age"), b"1\0".to_vec())],
    ] {
        let opt = WriteOptions {
            metadata: md,
            ..wopt()
        };
        let e = w.write_record("e", &x, 1, 100.0, &opt).unwrap_err();
        assert!(e.message().starts_with("write_record: "), "{e}");
        let e = w
            .write_record_physical("e", &[0.0; 4], 1, 100.0, &opt)
            .unwrap_err();
        assert!(e.message().starts_with("write_record: "), "{e}");
    }
    let opt = WriteOptions {
        comments: vec![b("age: 1")],
        metadata: pairs(&[("Age", "2")]),
        ..wopt()
    };
    let e = w.write_record("e", &x, 1, 100.0, &opt).unwrap_err();
    assert_eq!(
        e.message(),
        "write_record: metadata key 'age' is also given in comments"
    );
    let opt = WriteOptions {
        metadata: pairs(&[("a:b", "1")]),
        ..wopt()
    };
    let e = w.write_record("e", &x, 1, 100.0, &opt).unwrap_err();
    assert_eq!(
        e.message(),
        "write_record: metadata key 'a:b' must not contain ':'"
    );
    assert!(d.files(".").is_empty()); // nothing was written
}

#[test]
fn info_file_ignored() {
    let d = Dir::new("info");
    let rec = d.copy("lf", ".");
    let mut info = rec.clone();
    info.extend_from_slice(b".info");
    std::fs::write(cstd::bytes_to_path(&info), b"#Age: 1\n").unwrap();
    let mut w = quiet();
    assert!(w.read_metadata(&rec).unwrap().is_empty());
}

#[test]
fn input_dir_and_dir() {
    let d = Dir::new("dirs");
    std::fs::create_dir("in").unwrap();
    std::fs::create_dir("out").unwrap();
    d.copy("basic", "in");
    let original = std::fs::read("in/basic.hea").unwrap();
    let mut w = quiet();
    let input = MetadataOptions {
        input_dir: Some("in".into()),
        ..Default::default()
    };
    assert_eq!(
        w.get_metadata_with("basic", "Sex", &input).unwrap(),
        Some(b("F"))
    );
    // the setting is restored after the call
    assert!(w.get_metadata("basic", "Sex").is_err());
    w.wfdbx_set_input_dir("in");
    assert_eq!(w.get_metadata("basic.hea", "sex").unwrap(), Some(b("F")));
    let out = MetadataOptions {
        dir: Some("out".into()),
        ..Default::default()
    };
    w.set_metadata_with("basic", "Age", "64", &out).unwrap();
    assert_eq!(std::fs::read("in/basic.hea").unwrap(), original);
    let here = MetadataOptions {
        input_dir: Some(String::new()),
        ..Default::default()
    };
    assert_eq!(
        w.get_metadata_with("out/basic", "Age", &here).unwrap(),
        Some(b("64"))
    );
    // an unchanged header is still written to dir
    assert_eq!(w.remove_metadata_with("basic", "Weight", &out).unwrap(), 0);
    assert_eq!(std::fs::read("out/basic.hea").unwrap(), original);
    let none = MetadataOptions {
        dir: Some("none".into()),
        ..Default::default()
    };
    let e = w.set_metadata_with("basic", "Age", "1", &none).unwrap_err();
    assert_eq!(
        (kind(&e), e.message()),
        ("file", "directory none does not exist")
    );
    w.wfdbx_set_input_dir(NULL);
    // the header is changed where it was read, not in the output directory
    w.wfdbx_set_output_dir("out");
    w.set_metadata("in/basic", "Age", "65").unwrap();
    assert_eq!(w.get_metadata("in/basic", "Age").unwrap(), Some(b("65")));
    w.wfdbx_set_output_dir(NULL);
    // update_metadata_with, with dir
    let changes: [(&str, Option<&str>); 2] = [("Age", Some("70")), ("Sex", None)];
    w.update_metadata_with("in/basic", &changes, &out).unwrap();
    assert_eq!(w.get_metadata("out/basic", "Age").unwrap(), Some(b("70")));
    assert_eq!(w.get_metadata("out/basic", "Sex").unwrap(), None);
    assert_eq!(w.get_metadata("in/basic", "Age").unwrap(), Some(b("65")));
    // a write that fails (the destination is a directory) leaves no
    // temporary file
    std::fs::create_dir("out2").unwrap();
    std::fs::create_dir("out2/basic.hea").unwrap();
    let out2 = MetadataOptions {
        dir: Some("out2".into()),
        ..Default::default()
    };
    let e = w
        .set_metadata_with("in/basic", "Age", "1", &out2)
        .unwrap_err();
    assert_eq!(kind(&e), "file");
    assert_eq!(d.files("out2"), ["basic.hea"]);
    assert_eq!(d.files("in"), ["basic.hea"]);
    assert_eq!(d.files("out"), ["basic.hea"]);
}

#[test]
fn missing_and_invalid() {
    let d = Dir::new("invalid");
    let mut w = quiet();
    for r in [w.read_metadata("none"), w.read_metadata("none.hea")] {
        let e = r.unwrap_err();
        assert_eq!(kind(&e), "file");
        assert!(e.message().starts_with("can't read header for record none"));
    }
    let e = w.set_metadata("none", "Age", "1").unwrap_err();
    assert_eq!(e.message(), "can't read header for record none");
    let e = w.read_metadata("").unwrap_err();
    assert_eq!(e.message(), "record name must not be empty");
    let e = w.read_metadata("-").unwrap_err();
    assert_eq!(
        e.message(),
        "the metadata of a header read from the standard input cannot be read or changed"
    );
    assert!(w.remove_metadata("-", "Age").is_err());
    // an invalid argument is reported before the header is read
    let e = w.get_metadata("none", "a#b").unwrap_err();
    assert_eq!(e.message(), "metadata key 'a#b' must not contain '#'");
    let e = w.set_metadata("none", " ", "1").unwrap_err();
    assert_eq!(e.message(), "metadata key must not be empty");
    let e = w.set_metadata("none", "Age", "1\r2").unwrap_err();
    assert_eq!(
        e.message(),
        "value of metadata key 'Age' must not contain a line break"
    );
    let e = w
        .update_metadata("none", &[("Age", Some("1")), ("AGE", None)])
        .unwrap_err();
    assert_eq!(
        e.message(),
        "metadata key 'AGE' is given more than once (keys are compared without regard to letter case)"
    );
    d.copy("basic", ".");
    // bytes are stored and returned as given
    w.set_metadata("basic", b"Name", b"Z\xc3\xbcrich").unwrap();
    assert_eq!(
        w.get_metadata("basic", "Name").unwrap(),
        Some(b"Z\xc3\xbcrich".to_vec())
    );
    w.set_metadata("basic", "City", b"Jos\xe9").unwrap();
    assert_eq!(
        w.get_metadata("basic", "city").unwrap(),
        Some(b"Jos\xe9".to_vec())
    );
    std::fs::write("norec.hea", b"# only a comment\n").unwrap();
    assert!(w.read_metadata("norec").unwrap().is_empty());
    let e = w.set_metadata("norec", "Age", "1").unwrap_err();
    assert_eq!(e.message(), "header of record norec has no record line");
    assert_eq!(std::fs::read("norec.hea").unwrap(), b"# only a comment\n");
    // the free functions, on the default Wfdb value
    wfdbquiet();
    assert_eq!(get_metadata("basic", "Age").unwrap(), Some(b("63")));
    set_metadata("basic", "Age", "64").unwrap();
    assert_eq!(remove_metadata("basic", "AGE").unwrap(), 1);
    update_metadata("basic", &[("Sex", None::<&str>)]).unwrap();
    let opt = MetadataOptions::default();
    assert!(read_metadata_with("basic", &opt)
        .unwrap()
        .iter()
        .all(|(k, _)| k != b"Age" && k != b"Sex"));
    set_metadata_with("basic", "Age", "1", &opt).unwrap();
    assert_eq!(
        get_metadata_with("basic", "age", &opt).unwrap(),
        Some(b("1"))
    );
    assert_eq!(remove_metadata_with("basic", "age", &opt).unwrap(), 1);
    update_metadata_with("basic", &[("Age", Some("2"))], &opt).unwrap();
    assert_eq!(get_metadata("basic", "age").unwrap(), Some(b("2")));
    assert_eq!(d.files("."), ["basic.hea", "norec.hea"]);
}

#[cfg(unix)]
#[test]
fn permissions_kept() {
    use std::os::unix::fs::PermissionsExt;
    let d = Dir::new("perm");
    let rec = d.copy("basic", ".");
    std::fs::set_permissions("basic.hea", std::fs::Permissions::from_mode(0o640)).unwrap();
    let mut w = quiet();
    w.set_metadata(&rec, "Age", "64").unwrap();
    let mode = std::fs::metadata("basic.hea").unwrap().permissions().mode();
    assert_eq!(mode & 0o7777, 0o640);
    assert_eq!(w.get_metadata(&rec, "Age").unwrap(), Some(b("64")));
}

/// Serves the files of `root` on 127.0.0.1; returns the base URL (ending
/// in `/`).
fn serve(root: PathBuf) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/", listener.local_addr().unwrap());
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut s) = stream else { continue };
            let mut r = BufReader::new(s.try_clone().unwrap());
            let mut line = String::new();
            if r.read_line(&mut line).is_err() {
                continue;
            }
            loop {
                let mut h = String::new();
                if r.read_line(&mut h).unwrap_or(0) == 0 || h == "\r\n" {
                    break;
                }
            }
            let path = line.split(' ').nth(1).unwrap_or("/").to_string();
            let resp = match std::fs::read(root.join(&path[1..])) {
                Ok(data) => {
                    let mut v = format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        data.len()
                    )
                    .into_bytes();
                    v.extend_from_slice(&data);
                    v
                }
                Err(_) => {
                    b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                        .to_vec()
                }
            };
            let _ = s.write_all(&resp);
        }
    });
    url
}

#[test]
fn url() {
    let d = Dir::new("url");
    // only 127.0.0.1 is contacted: no proxy
    for k in [
        "http_proxy",
        "https_proxy",
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "ALL_PROXY",
        "all_proxy",
    ] {
        std::env::remove_var(k);
    }
    std::env::set_var("NO_PROXY", "127.0.0.1,localhost");
    std::env::set_var("no_proxy", "127.0.0.1,localhost");
    d.copy("basic", ".");
    let root: &Path = &d.dir;
    let url = format!("{}basic", serve(root.to_path_buf()));
    let mut w = quiet();
    let e = w.read_metadata(&url).unwrap_err(); // network off
    assert_eq!(kind(&e), "file");
    let net = MetadataOptions {
        network: Some(true),
        ..Default::default()
    };
    assert_eq!(
        w.get_metadata_with(&url, "Age", &net).unwrap(),
        Some(b("63"))
    );
    let e = w.set_metadata_with(&url, "Age", "1", &net).unwrap_err();
    assert_eq!(kind(&e), "argument");
    assert!(e
        .message()
        .contains("was read from a URL, and cannot be changed"));
    std::fs::create_dir("copy").unwrap();
    let copy = MetadataOptions {
        network: Some(true),
        dir: Some("copy".into()),
        ..Default::default()
    };
    w.set_metadata_with(&url, "Age", "1", &copy).unwrap();
    assert_eq!(w.get_metadata("copy/basic", "Age").unwrap(), Some(b("1")));
    assert_eq!(w.get_metadata("basic", "Age").unwrap(), Some(b("63")));
    assert_eq!(d.files("copy"), ["basic.hea"]);
}
