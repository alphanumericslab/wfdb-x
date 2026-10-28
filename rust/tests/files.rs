//! WFDB-x: finding files (normal mode): explicit names, the input and
//! output directories, `setwfdb`/`getwfdb`, files named in headers and
//! their containment, multi-segment records; legacy mode unchanged. (The
//! network is tested in `tests/network.rs`.)
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
use std::sync::{Mutex, MutexGuard};

use wfdbx::cstd;
use wfdbx::record::ReadOptions;
use wfdbx::*;

/// The tests change the environment and the current directory: they run
/// one at a time.
static LOCK: Mutex<()> = Mutex::new(());

const ENV: [&str; 5] = [
    "WFDB",
    "WFDBX_INPUT_DIR",
    "WFDBX_OUTPUT_DIR",
    "WFDBX_NETWORK",
    "HOME",
];

/// A fresh, empty current directory (with `HOME` = its `home`
/// subdirectory, and no WFDB or WFDBX_ variables) while the value lives.
struct Dir {
    old: PathBuf,
    dir: PathBuf,
    saved: Vec<(&'static str, Option<std::ffi::OsString>)>,
    _guard: MutexGuard<'static, ()>,
}

impl Dir {
    fn new(name: &str) -> Dir {
        let guard = LOCK
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let dir = std::env::temp_dir().join(format!("wfdbx-files-{}-{}", name, std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("home")).unwrap();
        let dir = dir.canonicalize().unwrap();
        let saved = ENV.iter().map(|&k| (k, std::env::var_os(k))).collect();
        for k in ENV {
            std::env::remove_var(k);
        }
        std::env::set_var("HOME", dir.join("home"));
        let old = std::env::current_dir().unwrap();
        std::env::set_current_dir(&dir).unwrap();
        Dir {
            old,
            dir,
            saved,
            _guard: guard,
        }
    }

    /// Copies `name` from tests/data to `to` (relative to the directory).
    fn copy(&self, name: &str, to: &str) {
        let data = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../tests/data");
        let to = self.dir.join(to);
        std::fs::create_dir_all(to.parent().unwrap()).unwrap();
        std::fs::copy(data.join(name), to).unwrap();
    }

    fn write(&self, name: &str, text: &[u8]) {
        let p = self.dir.join(name);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, text).unwrap();
    }

    fn path(&self, name: &str) -> Vec<u8> {
        cstd::os_to_bytes(self.dir.join(name).into_os_string())
    }
}

impl Drop for Dir {
    fn drop(&mut self) {
        let _ = std::env::set_current_dir(&self.old);
        let _ = std::fs::remove_dir_all(&self.dir);
        for (k, v) in &self.saved {
            match v {
                Some(v) => std::env::set_var(k, v),
                None => std::env::remove_var(k),
            }
        }
    }
}

fn quiet() -> Wfdb {
    let mut w = Wfdb::new();
    w.wfdbquiet();
    w
}

fn v(s: &str) -> Option<Vec<u8>> {
    Some(s.as_bytes().to_vec())
}

#[test]
fn input_dir_setting() {
    let _d = Dir::new("in");
    let mut w = quiet();
    assert_eq!(w.wfdbx_get_input_dir(), None);
    assert_eq!(w.getwfdb(), b".");
    assert_eq!(w.wfdbx_set_input_dir("a"), None);
    assert_eq!(w.wfdbx_set_input_dir("b"), v("a"));
    assert_eq!(w.getwfdb(), b"b");
    assert_eq!(w.wfdbx_set_input_dir(""), v("b"));
    assert_eq!(w.wfdbx_get_input_dir(), None);
    w.wfdbx_set_input_dir("c");
    w.wfdbquit(); // the setting is kept
    assert_eq!(w.wfdbx_get_input_dir(), v("c"));
    // WFDBX_INPUT_DIR: read when first needed, then kept; the default
    let mut w = quiet();
    std::env::set_var("WFDBX_INPUT_DIR", "envdir");
    assert_eq!(w.wfdbx_get_input_dir(), v("envdir"));
    std::env::set_var("WFDBX_INPUT_DIR", "changed");
    assert_eq!(w.wfdbx_set_input_dir("x"), v("envdir"));
    assert_eq!(w.wfdbx_set_input_dir(NULL), v("x"));
    assert_eq!(w.wfdbx_get_input_dir(), v("envdir"));
    // the default instance has its own setting
    std::env::set_var("WFDBX_INPUT_DIR", "");
    let prev = wfdbx::wfdbx_set_input_dir("dflt");
    assert_eq!(wfdbx::wfdbx_get_input_dir(), v("dflt"));
    wfdbx::wfdbx_set_input_dir(&prev);
}

#[test]
fn output_dir_setting() {
    let _d = Dir::new("out");
    std::env::set_var("WFDBX_OUTPUT_DIR", "envout");
    let mut w = quiet();
    assert_eq!(w.wfdbx_get_output_dir(), v("envout"));
    assert_eq!(w.wfdbx_set_output_dir("o"), v("envout"));
    // a URL is refused: the setting is unchanged, its value returned
    assert_eq!(w.wfdbx_set_output_dir("http://127.0.0.1/x"), v("o"));
    assert_eq!(
        w.wfdberror(),
        b"wfdbx_set_output_dir: the output directory must be a local directory\n"
    );
    assert_eq!(w.wfdbx_get_output_dir(), v("o"));
    assert_eq!(w.wfdbx_set_output_dir(NULL), v("o"));
    assert_eq!(w.wfdbx_get_output_dir(), v("envout"));
    // a URL in WFDBX_OUTPUT_DIR is refused too
    std::env::set_var("WFDBX_OUTPUT_DIR", "https://127.0.0.1/x");
    let mut w = quiet();
    assert_eq!(w.wfdbx_get_output_dir(), None);
    assert_eq!(
        w.wfdberror(),
        b"wfdbx_set_output_dir: the output directory must be a local directory\n"
    );
}

#[test]
fn network_setting() {
    let _d = Dir::new("net");
    let mut w = quiet();
    assert_eq!(w.wfdbx_get_network(), 0);
    assert_eq!(w.wfdbx_set_network(1), 0);
    assert_eq!(w.wfdbx_set_network(0), 1);
    assert_eq!(w.wfdbx_get_network(), 0);
    for (value, on) in [
        ("1", 1),
        (" 2", 1),
        ("-1", 1),
        ("1abc", 1),
        ("0x1", 0),
        ("x", 0),
        ("", 0),
        ("0", 0),
    ] {
        std::env::set_var("WFDBX_NETWORK", value);
        let mut w = quiet();
        assert_eq!(w.wfdbx_get_network(), on, "WFDBX_NETWORK={value:?}");
        w.wfdbx_set_network(1 - on);
        assert_eq!(w.wfdbx_set_network(-1), 1 - on); // the default
        assert_eq!(w.wfdbx_get_network(), on);
    }
}

#[test]
fn setwfdb_normal_mode() {
    let _d = Dir::new("setwfdb");
    let mut w = quiet();
    w.setwfdb("one");
    assert_eq!(w.getwfdb(), b"one");
    assert_eq!(w.wfdbx_get_input_dir(), v("one"));
    assert!(std::env::var_os("WFDB").is_none()); // nothing is exported
    for p in ["a b", "a;b", "a:b", ". http://127.0.0.1/x"] {
        w.setwfdb(p);
        assert_eq!(
            w.wfdberror(),
            &b"setwfdb: WFDB-x reads from a single input directory; use \
wfdbx_set_input_dir (or legacy mode for the WFDB search path)\n"[..]
        );
        assert_eq!(w.getwfdb(), b"one", "{p}");
    }
    w.setwfdb(" http://127.0.0.1:8080/db ");
    assert_eq!(w.getwfdb(), b"http://127.0.0.1:8080/db");
    w.setwfdb("two");
    w.wfdbx_set_input_dir("three");
    w.resetwfdb(); // the value of the last setwfdb
    assert_eq!(w.getwfdb(), b"two");
    for p in ["", ";", "  "] {
        w.setwfdb(p);
        assert_eq!(w.getwfdb(), b".");
    }
    w.setwfdb(NULL);
    assert_eq!(w.wfdbx_get_input_dir(), None);
    // without a setwfdb, resetwfdb changes nothing
    let mut w = quiet();
    w.wfdbx_set_input_dir("x");
    w.resetwfdb();
    assert_eq!(w.getwfdb(), b"x");
}

#[test]
fn names() {
    let d = Dir::new("names");
    d.write("r.hea", b"");
    d.write("sub/s.hea", b"");
    d.write("in/x.hea", b"");
    d.write("home/h.hea", b"");
    let mut w = quiet();
    // relative: as given, or under the input directory (one separator)
    assert_eq!(w.wfdbfile("hea", "r"), v("r.hea"));
    assert_eq!(w.wfdbfile("hea", "sub/s"), v("sub/s.hea"));
    w.wfdbx_set_input_dir(".");
    assert_eq!(w.wfdbfile("hea", "r"), v("./r.hea"));
    w.wfdbx_set_input_dir("sub/");
    assert_eq!(w.wfdbfile("hea", "s"), v("sub/s.hea"));
    assert_eq!(w.wfdbfile("hea", "../r"), v("sub/../r.hea")); // ".." allowed
    w.wfdbx_set_input_dir("in");
    assert_eq!(w.wfdbfile("hea", "x"), v("in/x.hea"));
    assert_eq!(w.wfdbfile("hea", "r"), None); // nothing is searched
                                              // absolute: as given
    let abs = d.path("r");
    let mut absh = abs.clone();
    absh.extend_from_slice(b".hea");
    assert_eq!(w.wfdbfile("hea", &abs), Some(absh));
    // ~: the home directory
    let home = d.path("home/h.hea");
    assert_eq!(w.wfdbfile("hea", "~/h"), Some(home.clone()));
    assert_eq!(w.wfdbfile("hea", "~nosuchuser-wfdbx/h"), None);
    assert_eq!(w.wfdb_filename(), b"~nosuchuser-wfdbx/h.hea");
    w.wfdbx_set_input_dir("~");
    assert_eq!(w.wfdbfile("hea", "h"), Some(home));
    std::env::set_var("HOME", "");
    assert_eq!(w.wfdbfile("hea", "~/nosuch"), None);
    assert_eq!(w.wfdb_filename(), b"/nosuch.hea");
    std::env::set_var("HOME", d.dir.join("home"));
    // the 8.3 form, at the same location
    d.write("in/y.abc", b"");
    w.wfdbx_set_input_dir("in");
    assert_eq!(w.wfdbfile("abcdef", "y"), v("in/y.abc"));
    // output: under the output directory (relative names only)
    w.wfdbx_set_output_dir("out");
    let f = w.wfdb_open("hea", "o", WFDB_WRITE).unwrap();
    drop(f);
    assert_eq!(w.wfdb_filename(), b"out/o.hea");
    assert!(d.dir.join("out/o.hea").exists());
    w.wfdb_open("hea", "~/o2", WFDB_WRITE).unwrap();
    assert!(d.dir.join("home/o2.hea").exists());
    let mut abs2 = d.path("o3");
    w.wfdb_open("hea", &abs2, WFDB_WRITE).unwrap();
    assert!(d.dir.join("o3.hea").exists());
    abs2.extend_from_slice(b".hea");
    assert_eq!(w.wfdb_filename(), &abs2[..]);
    assert!(w
        .wfdb_open("hea", "http://127.0.0.1:9/o", WFDB_WRITE)
        .is_none());
    w.wfdbx_set_output_dir(NULL);
}

/// A header naming its signal file `fname`, and a 4-sample signal file
/// `db/data/a.dat`.
fn header(d: &Dir, rec: &str, fname: &str) {
    d.write(
        &format!("db/{rec}.hea"),
        format!("{rec} 1 100 4\n{fname} 16 200/mV 16 0 1 10 0 x\n").as_bytes(),
    );
    d.write("db/data/a.dat", &[1, 0, 2, 0, 3, 0, 4, 0]);
}

#[test]
fn files_named_in_headers() {
    let d = Dir::new("hdr");
    header(&d, "rec", "data/a.dat");
    d.write("data/a.dat", &[1, 0, 3, 0, 2, 0, 4, 0]); // (legacy mode only)
    let mut w = quiet();
    let r = w.read_record("db/rec", &ReadOptions::default()).unwrap();
    assert_eq!(r.samples, [1, 2, 3, 4]);
    let opt = ReadOptions {
        input_dir: Some("db".into()),
        ..Default::default()
    };
    assert_eq!(w.read_record("rec", &opt).unwrap().samples, [1, 2, 3, 4]);
    assert_eq!(w.wfdbx_get_input_dir(), None); // restored
    let abs = format!("{}/db/data/a.dat", d.dir.display());
    for name in [
        "../a.dat",
        "data/../data/a.dat",
        &abs[..],
        "~/a.dat",
        "http://127.0.0.1:9/a.dat",
    ] {
        header(&d, "bad", name);
        // the header can be read; its signal file is refused
        assert_eq!(w.read_header("db/bad", false).unwrap().nsig, 1);
        assert!(w.read_record("db/bad", &ReadOptions::default()).is_err());
        assert!(w
            .wfdbx_open_in(Some(b"db/"), NULL, name.as_bytes(), b"db/bad")
            .is_none());
        assert_eq!(
            w.wfdberror(),
            format!(
                "init: file {name} named in the header of record db/bad is not in the header's directory\n"
            )
            .as_bytes()
        );
    }
    // names that stay inside are fine
    for name in ["./data/a.dat", "data//a.dat"] {
        header(&d, "ok", name);
        assert_eq!(
            w.read_record("db/ok", &ReadOptions::default())
                .unwrap()
                .samples,
            [1, 2, 3, 4]
        );
    }
    // legacy mode: the WFDB path (the signal file is found in the current
    // directory, not next to the header)
    w.wfdbx_set_legacy(1);
    w.setwfdb(".");
    header(&d, "rec", "data/a.dat");
    assert_eq!(
        w.read_record("db/rec", &ReadOptions::default())
            .unwrap()
            .samples,
        [1, 3, 2, 4]
    );
    w.wfdbx_set_legacy(0);
}

#[test]
fn multi_segment_records() {
    let d = Dir::new("multi");
    for f in ["multi.hea", "100s.hea", "100s.dat", "null.hea"] {
        d.copy(f, &format!("db/{f}"));
    }
    d.write("db/gap.hea", b"gap/2 2 360 23400\n100s 21600\n~ 1800\n");
    d.write(
        "db/out.hea",
        b"out/2 2 360 23400\n100s 21600\n../100s 1800\n",
    );
    d.copy("100s.hea", "100s.hea");
    d.copy("100s.dat", "100s.dat");
    let mut w = quiet();
    let local = w.read_record("100s", &ReadOptions::default()).unwrap();
    let n = local.samples.len();
    let r = w.read_record("db/multi", &ReadOptions::default()).unwrap();
    assert_eq!(r.samples.len(), 2 * 45000);
    assert_eq!(&r.samples[..n], &local.samples[..]);
    assert_eq!(&r.samples[r.samples.len() - n..], &local.samples[..]);
    // a "~" segment is a gap
    let g = w.read_record("db/gap", &ReadOptions::default()).unwrap();
    assert_eq!(g.samples.len(), 2 * 23400);
    assert_eq!(g.samples[n], WFDB_INVALID_SAMPLE);
    // a segment outside the header's directory is refused
    let mut si = vec![Siginfo::default(); 2];
    assert_eq!(w.isigopen("db/out", &mut si, 2), 2);
    let mut x = [0; 2];
    assert_eq!(w.isigsettime(21600), -1);
    assert!(w.getvec(&mut x) < 0);
    w.wfdbquit();
}

#[test]
fn high_level_options_restore() {
    let d = Dir::new("hl");
    d.copy("100s.hea", "db/100s.hea");
    d.copy("100s.dat", "db/100s.dat");
    d.copy("100s.atr", "db/100s.atr");
    let mut w = quiet();
    w.wfdbx_set_input_dir("nosuch");
    w.wfdbx_set_network(0);
    let opt = ReadOptions {
        to: Some("s10".into()),
        input_dir: Some("db".into()),
        network: Some(true),
        ..Default::default()
    };
    assert_eq!(w.read_record("100s", &opt).unwrap().samples.len(), 20);
    assert_eq!(
        (w.wfdbx_get_input_dir(), w.wfdbx_get_network()),
        (v("nosuch"), 0)
    );
    assert_eq!(w.read_header_with("100s", &opt).unwrap().nsig, 2);
    let all = ReadOptions {
        to: None,
        ..opt.clone()
    };
    assert_eq!(
        w.read_annotations_with("100s", "atr", None, &all)
            .unwrap()
            .len(),
        75
    );
    assert_eq!(
        (w.wfdbx_get_input_dir(), w.wfdbx_get_network()),
        (v("nosuch"), 0)
    );
    // also after an error
    assert!(w.read_record("nosuch", &opt).is_err());
    assert_eq!(
        (w.wfdbx_get_input_dir(), w.wfdbx_get_network()),
        (v("nosuch"), 0)
    );
    // input_dir "" is the default for the call; None keeps the setting
    let opt = ReadOptions {
        input_dir: Some(String::new()),
        ..Default::default()
    };
    assert!(w.read_header_with("db/100s", &opt).is_ok());
    assert!(w
        .read_header_with("db/100s", &ReadOptions::default())
        .is_err());
    assert_eq!(w.wfdbx_get_input_dir(), v("nosuch"));
}

#[test]
fn legacy_mode_unchanged() {
    let d = Dir::new("legacy");
    d.copy("100s.hea", "b/100s.hea");
    d.copy("100s.dat", "b/100s.dat");
    d.write("x/r.hea", b"r 0\n");
    let mut w = quiet();
    w.wfdbx_set_legacy(1);
    w.wfdbx_set_input_dir("nosuch"); // ignored in legacy mode
    w.wfdbx_set_network(1); // likewise: no network access
    w.setwfdb("a b"); // the WFDB path: searched
    assert_eq!(w.getwfdb(), b"a b");
    assert_eq!(cstd::getenv("WFDB").unwrap(), b"a b"); // exported, as in C
    assert_eq!(w.wfdbfile("hea", "100s"), v("b/100s.hea"));
    assert_eq!(
        w.read_record("100s", &ReadOptions::default()).unwrap().nsig,
        2
    );
    w.setwfdb("x");
    assert_eq!(w.wfdbfile("hea", "../x/r"), None); // ".." refused
    assert_eq!(w.wfdbfile("hea", "http://127.0.0.1:9/r"), None); // no network
    assert_eq!(w.wfdbfile("hea", "~/r"), None); // "~" not expanded
    w.wfdbquit(); // restores the WFDB path, as in C
    w.wfdbx_set_legacy(0);
    assert_eq!(w.getwfdb(), b"nosuch"); // normal mode: the input directory
}
