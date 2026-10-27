//! wfdb-x: network access (normal mode), against a local HTTP server on
//! 127.0.0.1 (no other host is contacted): off by default (the message,
//! once per process), URL names and a URL input directory, files named in
//! a remote header, caching, a 404, a redirection, curl missing, the
//! `network` option; also the once-per-process WFDB warning. One test, as
//! these messages are printed once per process.
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
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use wfdbx::record::ReadOptions;
use wfdbx::*;

/// Serves the files of `root` on 127.0.0.1 (`/redirect/NAME` redirects to
/// `/NAME`); returns the base URL (ending in `/`) and the log of the paths
/// requested.
fn serve(root: PathBuf) -> (String, Arc<Mutex<Vec<String>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/", listener.local_addr().unwrap());
    let log = Arc::new(Mutex::new(Vec::new()));
    let log2 = Arc::clone(&log);
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
            log2.lock().unwrap().push(path.clone());
            let resp = if let Some(rest) = path.strip_prefix("/redirect/") {
                format!("HTTP/1.1 302 Found\r\nLocation: /{rest}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                    .into_bytes()
            } else {
                match std::fs::read(root.join(&path[1..])) {
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
                }
            };
            let _ = s.write_all(&resp);
        }
    });
    (url, log)
}

fn count(log: &Arc<Mutex<Vec<String>>>, path: &str) -> usize {
    log.lock().unwrap().iter().filter(|p| *p == path).count()
}

#[test]
fn network() {
    for k in ["WFDBX_INPUT_DIR", "WFDBX_OUTPUT_DIR", "WFDBX_NETWORK"] {
        std::env::remove_var(k);
    }
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

    // The WFDB variable is ignored in normal mode (warned once).
    std::env::set_var("WFDB", "somewhere");
    let mut w = Wfdb::new();
    w.wfdbquiet();
    assert_eq!(w.getwfdb(), b".");
    assert_eq!(
        w.wfdberror(),
        b"wfdb-x: the WFDB environment variable is ignored; set WFDBX_INPUT_DIR instead (or use legacy mode)\n"
    );
    let mut w = Wfdb::new();
    w.wfdbquiet();
    w.getwfdb();
    assert_eq!(
        w.wfdberror(),
        b"WFDB library version 10.7.0 (Jun 10 2022).\n"
    );
    std::env::remove_var("WFDB");

    let root = std::env::temp_dir().join(format!("wfdbx-net-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let data = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../tests/data");
    std::fs::create_dir_all(root.join("db/data")).unwrap();
    for f in ["100s.hea", "100s.dat", "100s.atr", "multi.hea", "null.hea"] {
        std::fs::copy(data.join(f), root.join("db").join(f)).unwrap();
    }
    std::fs::write(
        root.join("db/sub.hea"),
        b"sub 1 100 4\ndata/a.dat 16 200/mV 16 0 1 10 0 x\n",
    )
    .unwrap();
    std::fs::write(root.join("db/data/a.dat"), [1, 0, 2, 0, 3, 0, 4, 0]).unwrap();
    std::fs::write(
        root.join("db/esc.hea"),
        b"esc 1 100 4\n../a.dat 16 200/mV 16 0 1 10 0 x\n",
    )
    .unwrap();
    let (url, log) = serve(root.clone());
    let db = format!("{url}db/");
    let local = {
        let mut w = Wfdb::new();
        w.setwfdb(data.to_str().unwrap());
        w.read_record("100s", &ReadOptions::default()).unwrap()
    };

    // Network off (the default): the URL is not opened; the message is
    // printed once per process.
    let mut w = Wfdb::new();
    w.wfdbquiet();
    let hea = format!("{db}100s");
    assert!(w.wfdb_open("hea", &hea, WFDB_READ).is_none());
    let msg = format!(
        "wfdb-x: network access is disabled; set WFDBX_NETWORK=1 or call wfdbx_set_network(1) to open {db}100s.hea\n"
    );
    assert_eq!(w.wfdberror(), msg.as_bytes());
    assert!(w.read_header(&hea, false).is_err());
    let mut w2 = Wfdb::new();
    w2.wfdbquiet();
    assert!(w2.wfdb_open("hea", &hea, WFDB_READ).is_none());
    assert_eq!(
        w2.wfdberror(),
        b"WFDB library version 10.7.0 (Jun 10 2022).\n"
    );
    assert!(log.lock().unwrap().is_empty()); // (failures are not cached)

    // Network on: a URL record name, and a URL input directory.
    w.wfdbx_set_network(1);
    let r = w.read_record(&hea, &ReadOptions::default()).unwrap();
    assert_eq!(r.samples, local.samples);
    let opt = ReadOptions {
        input_dir: Some(db.clone()),
        ..Default::default()
    };
    assert_eq!(w.read_record("100s", &opt).unwrap().samples, local.samples);
    // each URL is requested once per process (failures too)
    assert_eq!(count(&log, "/db/100s.hea"), 1);
    assert_eq!(count(&log, "/db/100s.dat"), 1);
    assert_eq!(
        w.read_annotations_with("100s", "atr", None, &opt)
            .unwrap()
            .len(),
        75
    );
    // the input directory without a final '/'
    let opt2 = ReadOptions {
        input_dir: Some(format!("{url}db")),
        ..Default::default()
    };
    assert_eq!(w.read_header_with("100s", &opt2).unwrap().nsig, 2);
    // files named in a remote header: under its URL, contained
    assert_eq!(w.read_record("sub", &opt).unwrap().samples, [1, 2, 3, 4]);
    assert_eq!(count(&log, "/db/data/a.dat"), 1);
    assert!(w.read_record("esc", &opt).is_err());
    assert_eq!(count(&log, "/a.dat"), 0);
    // a multi-segment record
    let m = w.read_record("multi", &opt).unwrap();
    assert_eq!(m.samples.len(), 2 * 45000);
    // a 404, cached
    assert!(w.read_header_with("nosuch", &opt).is_err());
    assert!(w.read_header_with("nosuch", &opt).is_err());
    assert_eq!(count(&log, "/db/nosuch.hea"), 1);
    // a redirection is followed
    let mut f = w
        .wfdb_open("hea", &format!("{url}redirect/db/null"), WFDB_READ)
        .unwrap();
    assert_eq!(
        f.read_to_end(),
        std::fs::read(root.join("db/null.hea")).unwrap()
    );
    assert!(f.is_remote());
    // URLs cannot be written
    assert!(w.wfdb_open("hea", &format!("{db}w"), WFDB_WRITE).is_none());

    // The network option of the readers, restored afterwards.
    w.wfdbx_set_network(0);
    let on = ReadOptions {
        network: Some(true),
        ..opt.clone()
    };
    assert!(w.read_header_with("100s", &on).is_ok());
    assert_eq!(w.wfdbx_get_network(), 0);
    let off = ReadOptions {
        network: Some(false),
        ..opt.clone()
    };
    w.wfdbx_set_network(1);
    assert!(w.read_header_with("null", &off).is_err());
    assert_eq!(w.wfdbx_get_network(), 1);
    // legacy mode: no network access
    let lo = ReadOptions {
        legacy: true,
        ..Default::default()
    };
    let n = log.lock().unwrap().len();
    assert!(w.read_header_with(&hea, &lo).is_err());
    assert_eq!(log.lock().unwrap().len(), n);

    // curl missing (a PATH without it): the message, once per process.
    let path = std::env::var_os("PATH");
    std::env::set_var("PATH", "/nonexistent-wfdbx");
    let mut w = Wfdb::new();
    w.wfdbquiet();
    w.wfdbx_set_network(1);
    assert!(w
        .wfdb_open("hea", &format!("{db}fresh"), WFDB_READ)
        .is_none());
    assert_eq!(
        w.wfdberror(),
        b"wfdb-x: network access needs the curl program, which was not found\n"
    );
    let mut w = Wfdb::new();
    w.wfdbquiet();
    w.wfdbx_set_network(1);
    assert!(w
        .wfdb_open("hea", &format!("{db}fresh2"), WFDB_READ)
        .is_none());
    assert_eq!(
        w.wfdberror(),
        b"WFDB library version 10.7.0 (Jun 10 2022).\n"
    );
    if let Some(p) = path {
        std::env::set_var("PATH", p);
    }
    assert_eq!(count(&log, "/db/fresh.hea"), 0);
    let _ = std::fs::remove_dir_all(&root);
}
