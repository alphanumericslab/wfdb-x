//! Exact emulation of glibc's `srand`/`rand` (`random`, `TYPE_3` additive
//! feedback generator with 31 words of state), used for dithering by
//! `wrsamp -d` and `xform -d`.
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It has no counterpart in the original package.
//
// Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

use std::cell::RefCell;

/// glibc's `RAND_MAX`.
pub const RAND_MAX: i32 = i32::MAX;

/// Words of state of glibc's `TYPE_3` generator (`DEG_3`), and the distance
/// between its front and rear pointers (`SEP_3`).
const DEG_3: usize = 31;
const SEP_3: usize = 3;

/// The state of glibc's `rand()` generator.
#[derive(Clone, Debug)]
pub struct GlibcRand {
    state: [u32; DEG_3],
    f: usize,
    r: usize,
}

impl Default for GlibcRand {
    /// The generator as it is at program start (`srand(1)`).
    fn default() -> Self {
        GlibcRand::new(1)
    }
}

impl GlibcRand {
    /// A generator seeded with `srand(seed)`.
    pub fn new(seed: u32) -> GlibcRand {
        let mut g = GlibcRand {
            state: [0; DEG_3],
            f: SEP_3,
            r: 0,
        };
        g.srand(seed);
        g
    }

    /// C `srand(seed)` (a seed of 0 is the same as 1).
    pub fn srand(&mut self, seed: u32) {
        let seed = if seed == 0 { 1 } else { seed };
        self.state[0] = seed;
        let mut word = seed as i32 as i64;
        // The state is initialized with the "minimal standard" generator
        // 16807 * word % 2147483647 (computed with Schrage's method, as
        // 127773 * 16807 + 2836 == 2147483647), then the generator is
        // stirred by discarding 10 * DEG_3 values.
        for i in 1..DEG_3 {
            let hi = word / 127773;
            let lo = word % 127773;
            word = 16807 * lo - 2836 * hi;
            if word < 0 {
                word += 2147483647;
            }
            self.state[i] = word as u32;
        }
        self.f = SEP_3;
        self.r = 0;
        for _ in 0..10 * DEG_3 {
            self.rand();
        }
    }

    /// C `rand()`: the next value, in `0..=RAND_MAX`.
    #[allow(clippy::should_implement_trait)]
    pub fn rand(&mut self) -> i32 {
        let v = self.state[self.f].wrapping_add(self.state[self.r]);
        self.state[self.f] = v;
        self.f = if self.f == DEG_3 - 1 { 0 } else { self.f + 1 };
        self.r = if self.r == DEG_3 - 1 { 0 } else { self.r + 1 };
        (v >> 1) as i32
    }
}

thread_local! {
    static RAND: RefCell<GlibcRand> = RefCell::new(GlibcRand::default());
}

/// C `srand(seed)` on the (thread-local) process generator.
pub fn srand(seed: u32) {
    RAND.with(|r| r.borrow_mut().srand(seed));
}

/// C `rand()` on the (thread-local) process generator.
pub fn rand() -> i32 {
    RAND.with(|r| r.borrow_mut().rand())
}
