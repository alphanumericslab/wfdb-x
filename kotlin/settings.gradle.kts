// WFDB-x for Kotlin: Gradle settings.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It has no counterpart in the original package.
//
// Copyright (C) 2026 Reza Sameni.
//
// This file is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

pluginManagement {
    // -PmavenMirror=URL (or mavenMirror=URL in ~/.gradle/gradle.properties)
    // replaces Maven Central, e.g. where Maven Central is rate-limited.
    val mirror = providers.gradleProperty("mavenMirror").orNull
    repositories {
        if (mirror != null) maven(mirror) else mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    val mirror = providers.gradleProperty("mavenMirror").orNull
    repositories {
        if (mirror != null) maven(mirror) else mavenCentral()
    }
}

rootProject.name = "wfdbx"
