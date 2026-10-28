// WFDB-x for Kotlin: build script.
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

import java.io.OutputStream
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    kotlin("multiplatform") version "2.1.21"
    `maven-publish`
}

group = "io.github.alphanumericslab"
version = "1.1.0"

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
        // The benchmark driver (../benchmarks/kotlin, run by benchmarks/run.py)
        compilations.create("bench") {
            associateWith(this@jvm.compilations.getByName("main"))
            defaultSourceSet { kotlin.srcDir("../benchmarks/kotlin") }
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

// A class data sharing archive of the jar of the tools,
// build/libs/wfdbx-all.jsa (made after fatJar by running rdsamp once):
// bin/wfdbx gives it to the JVM, which then starts faster. Without it (a
// JVM before 13, or one that cannot use it), the tools run as before.
val cdsArchive by tasks.registering(Exec::class) {
    group = "build"
    description = "Builds build/libs/wfdbx-all.jsa, the class data sharing archive of the tools."
    val jar = layout.buildDirectory.file("libs/wfdbx-all.jar")
    val jsa = layout.buildDirectory.file("libs/wfdbx-all.jsa")
    dependsOn(fatJar)
    inputs.file(jar)
    outputs.file(jsa)
    workingDir(testData)
    executable = File(System.getProperty("java.home"), "bin/java").path
    args(
        "-XX:+IgnoreUnrecognizedVMOptions", "-XX:ArchiveClassesAtExit=" + jsa.get().asFile.path,
        "-XX:+UseSerialGC", "-XX:TieredStopAtLevel=1", "-cp", jar.get().asFile.path,
        "wfdbx.cli.MainKt", "rdsamp", "-r", "100s", "-t", "5", "-p", "-v",
    )
    isIgnoreExitValue = true
    standardOutput = OutputStream.nullOutputStream()
    errorOutput = OutputStream.nullOutputStream()
    doFirst {
        environment.remove("JAVA_TOOL_OPTIONS")
        jsa.get().asFile.delete()
    }
}
fatJar { finalizedBy(cdsArchive) }

// The benchmark driver: build/libs/wfdbx-bench.jar (`./gradlew benchJar`),
// with the library and the Kotlin standard library (see benchmarks/README.md).
val benchJar by tasks.registering(Jar::class) {
    group = "build"
    description = "Builds build/libs/wfdbx-bench.jar, the benchmark driver."
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

// The POM of the published artifacts.
publishing {
    publications.withType<MavenPublication>().configureEach {
        pom {
            name.set("WFDB-x for Kotlin")
            description.set(
                "A reimplementation of the WFDB Software Package (library and command-line tools) " +
                    "in Kotlin, part of WFDB-x: the same package in seven languages, tested to give " +
                    "byte-for-byte identical results",
            )
            url.set("https://github.com/alphanumericslab/wfdb-x")
            licenses {
                license {
                    name.set("GPL-3.0-or-later")
                    url.set("https://www.gnu.org/licenses/gpl-3.0.html")
                }
            }
            scm {
                url.set("https://github.com/alphanumericslab/wfdb-x")
                connection.set("scm:git:https://github.com/alphanumericslab/wfdb-x.git")
            }
        }
    }
}
