// wfdb-x for Kotlin: build script.
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It has no counterpart in the original package.
//
// Copyright (C) 2026 Reza Sameni.
//
// This file is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    kotlin("multiplatform") version "2.1.21"
    `maven-publish`
}

group = "io.github.alphanumericslab"
version = "1.0.0"

// The linuxX64 target needs the Kotlin/Native toolchain (downloaded from
// download.jetbrains.com on first use). It is built when -Pwfdbx.linux=true
// is given (or wfdbx.linux=true is set in ~/.gradle/gradle.properties).
val withLinux = providers.gradleProperty("wfdbx.linux").orNull == "true"

val testData = rootProject.layout.projectDirectory.dir("../tests/data").asFile.absolutePath

kotlin {
    compilerOptions {
        freeCompilerArgs.add("-Xexpect-actual-classes")
    }
    jvm {
        compilerOptions { jvmTarget.set(JvmTarget.JVM_11) }
        // The benchmark program (benchmarks/src, run by benchmarks/run.sh)
        compilations.create("bench") {
            associateWith(this@jvm.compilations.getByName("main"))
            defaultSourceSet { kotlin.srcDir("benchmarks/src") }
        }
    }
    // Declared for iOS; they can only be built on macOS.
    iosArm64()
    iosSimulatorArm64()
    iosX64()
    if (withLinux) {
        linuxX64()
    }

    applyDefaultHierarchyTemplate()

    sourceSets {
        commonTest.dependencies {
            implementation(kotlin("test"))
        }
    }
}

tasks.withType<JavaCompile>().configureEach {
    options.release.set(11)
}

tasks.withType<Test>().configureEach {
    systemProperty("wfdbx.testdata", testData)
    testLogging {
        events("failed")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
}

tasks.withType<org.jetbrains.kotlin.gradle.targets.native.tasks.KotlinNativeTest>().configureEach {
    environment("WFDBX_TESTDATA", testData)
}

// The runnable jar of the command-line tools, with the Kotlin standard
// library: build/libs/wfdbx-all.jar (`./gradlew fatJar`), run by bin/wfdbx
// (java -cp build/libs/wfdbx-all.jar wfdbx.cli.MainKt TOOL ARGS...).
val fatJar by tasks.registering(Jar::class) {
    group = "build"
    description = "Builds build/libs/wfdbx-all.jar, the runnable jar of the tools."
    archiveFileName.set("wfdbx-all.jar")
    destinationDirectory.set(layout.buildDirectory.dir("libs"))
    manifest { attributes["Main-Class"] = "wfdbx.cli.MainKt" }
    val main = kotlin.jvm().compilations.getByName("main")
    from(main.output.allOutputs)
    dependsOn(main.compileTaskProvider)
    from({ main.runtimeDependencyFiles.filter { it.name.endsWith(".jar") }.map { zipTree(it) } })
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE
    exclude("META-INF/*.SF", "META-INF/*.DSA", "META-INF/*.RSA", "META-INF/versions/**", "**/module-info.class")
}

// The benchmark program: build/libs/wfdbx-bench.jar (`./gradlew benchJar`),
// with the library and the Kotlin standard library (see benchmarks/run.sh).
val benchJar by tasks.registering(Jar::class) {
    group = "build"
    description = "Builds build/libs/wfdbx-bench.jar, the benchmark program."
    archiveFileName.set("wfdbx-bench.jar")
    destinationDirectory.set(layout.buildDirectory.dir("libs"))
    manifest { attributes["Main-Class"] = "wfdbx.bench.BenchKt" }
    val main = kotlin.jvm().compilations.getByName("main")
    val bench = kotlin.jvm().compilations.getByName("bench")
    from(main.output.allOutputs, bench.output.allOutputs)
    dependsOn(main.compileTaskProvider, bench.compileTaskProvider)
    from({ main.runtimeDependencyFiles.filter { it.name.endsWith(".jar") }.map { zipTree(it) } })
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE
    exclude("META-INF/*.SF", "META-INF/*.DSA", "META-INF/*.RSA", "META-INF/versions/**", "**/module-info.class")
}
