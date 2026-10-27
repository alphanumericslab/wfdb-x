// The default Wfdb instance on the JVM: one per thread.
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

package wfdbx

private val defaultWfdb: ThreadLocal<Wfdb> = ThreadLocal.withInitial { Wfdb() }

internal actual fun threadDefaultWfdb(): Wfdb = defaultWfdb.get()
