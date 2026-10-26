// tests.hpp: a minimal unit test framework for the wfdb-x C++ library
//
// Each test is a function defined with WFDBX_TEST(name) in any file of
// cpp/tests/; it registers itself, and main.cpp runs every registered test.
// CHECK(cond) records a failure (and continues); REQUIRE(cond) records a
// failure and ends the test.  WFDBX_TEST_DATA is the directory of the test
// records (tests/data).
//
// Part of wfdb-x, Reza Sameni, Oct 2026.
// GNU General Public License, version 2 or later (see LICENSE).

#ifndef WFDBX_TESTS_HPP
#define WFDBX_TESTS_HPP

#include <cstdlib>
#include <optional>
#include <string>

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
