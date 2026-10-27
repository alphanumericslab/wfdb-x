// tests.hpp: a minimal unit test framework for the WFDB-x C++ library
//
// Each test is a function defined with WFDBX_TEST(name) in any file of
// cpp/tests/; it registers itself, and main.cpp runs every registered test.
// CHECK(cond) records a failure (and continues); REQUIRE(cond) records a
// failure and ends the test.  WFDBX_TEST_DATA is the directory of the test
// records (tests/data).
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

#ifndef WFDBX_TESTS_HPP
#define WFDBX_TESTS_HPP

#include <cstdio>
#include <cstdlib>
#include <optional>
#include <string>
#if defined(_WIN32)
#include <io.h>
#else
#include <unistd.h>
#endif

namespace wfdbx_tests {

using TestFunction = void (*)();

// Registers a test (used by WFDBX_TEST).
struct Registrar {
    Registrar(const char *name, TestFunction fn);
};

// Records a failure of the current test.
void fail(const char *file, int line, const std::string &what);

// The number of failures recorded so far (by all tests).
int failure_count();

// Thrown by REQUIRE to end the current test.
struct Abort {};

// The directory of the test data (tests/data).
std::string data_dir();

// An environment variable set to `value` (unset if nullptr) for the lifetime
// of the object, and restored afterwards.
struct EnvVar {
    std::string name;
    std::optional<std::string> old;
    EnvVar(const char *n, const char *value) : name(n) {
        if (const char *p = std::getenv(n)) old = p;
        set(value);
    }
    ~EnvVar() { set(old ? old->c_str() : nullptr); }
    void set(const char *value) {
#if defined(_WIN32)
        _putenv_s(name.c_str(), value ? value : "");
#else
        if (value)
            setenv(name.c_str(), value, 1);
        else
            unsetenv(name.c_str());
#endif
    }
};

// What is written on the standard error (file descriptor 2) during the
// lifetime of the object, or until text() is called.
struct StderrCapture {
    std::FILE *tmp = nullptr;
    int saved = -1;
    StderrCapture() {
        std::fflush(stderr);
        tmp = std::tmpfile();
#if defined(_WIN32)
        if (tmp) { saved = _dup(2); _dup2(_fileno(tmp), 2); }
#else
        if (tmp) { saved = dup(2); dup2(fileno(tmp), 2); }
#endif
    }
    ~StderrCapture() { text(); }
    StderrCapture(const StderrCapture &) = delete;
    StderrCapture &operator=(const StderrCapture &) = delete;
    // Stop capturing; returns the text captured.
    std::string text() {
        std::string out;
        if (!tmp) return out;
        std::fflush(stderr);
#if defined(_WIN32)
        _dup2(saved, 2);
        _close(saved);
#else
        dup2(saved, 2);
        close(saved);
#endif
        std::rewind(tmp);
        char buf[4096];
        size_t k;
        while ((k = std::fread(buf, 1, sizeof buf, tmp)) > 0) out.append(buf, k);
        std::fclose(tmp);
        tmp = nullptr;
        return out;
    }
};

} // namespace wfdbx_tests

#define WFDBX_TEST(name)                                                    \
    static void name();                                                     \
    static ::wfdbx_tests::Registrar name##_registrar(#name, name);          \
    static void name()

#define CHECK(cond)                                                         \
    do {                                                                    \
        if (!(cond)) ::wfdbx_tests::fail(__FILE__, __LINE__, #cond);        \
    } while (0)

#define CHECK_EQ(a, b)                                                      \
    do {                                                                    \
        if (!((a) == (b)))                                                  \
            ::wfdbx_tests::fail(__FILE__, __LINE__, #a " == " #b);          \
    } while (0)

#define REQUIRE(cond)                                                       \
    do {                                                                    \
        if (!(cond)) {                                                      \
            ::wfdbx_tests::fail(__FILE__, __LINE__, #cond);                 \
            throw ::wfdbx_tests::Abort();                                   \
        }                                                                   \
    } while (0)

#endif // WFDBX_TESTS_HPP
