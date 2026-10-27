//! Runs `check_record` on each case of a `check_record` corpus (made by
//! python/tests/check_corpus.py) and prints the reports in the format of
//! its `expected.txt`: a line `== RECORD ANN...`, then the report's lines.
//!
//! Usage: `cargo run --example check_cases DIR`
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It has no counterpart in the original package.
//
// Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

use wfdbx::{check_record_with, ReadOptions};

fn main() {
    let dir = std::env::args().nth(1).expect("usage: check_cases DIR");
    let cases = std::fs::read_to_string(format!("{dir}/cases.txt")).expect("cases.txt");
    let opt = ReadOptions {
        input_dir: Some(dir),
        ..Default::default()
    };
    for line in cases.lines() {
        let words: Vec<&str> = line.split(' ').filter(|w| !w.is_empty()).collect();
        let Some((rec, anns)) = words.split_first() else {
            continue;
        };
        println!("== {}", words.join(" "));
        let report = check_record_with(rec, anns, &opt).expect("check_record");
        for l in report.lines() {
            println!("{l}");
        }
    }
}
