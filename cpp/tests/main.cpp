// main.cpp: runs the unit tests of the wfdb-x C++ library (see tests.hpp)
//
// Usage: wfdbx_tests [NAME ...]   (with no arguments, run every test)
//
// Part of wfdb-x, Reza Sameni, Oct 2026.
// GNU General Public License, version 2 or later (see LICENSE).

#include "tests.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <vector>

namespace wfdbx_tests {

namespace {

struct Test {
    const char *name;
    TestFunction fn;
};

std::vector<Test> &registry()
{
    static std::vector<Test> tests;
    return tests;
}

int failures = 0;

} // namespace

Registrar::Registrar(const char *name, TestFunction fn)
{
    registry().push_back({name, fn});
}

void fail(const char *file, int line, const std::string &what)
{
    std::fprintf(stderr, "  %s:%d: check failed: %s\n", file, line,
                 what.c_str());
    failures++;
}

int failure_count() { return failures; }

std::string data_dir()
{
    const char *d = std::getenv("WFDBX_TEST_DATA");
    if (d && *d) return d;
#ifdef WFDBX_TEST_DATA
    return WFDBX_TEST_DATA;
#else
    return "tests/data";
#endif
}

} // namespace wfdbx_tests

int main(int argc, char **argv)
{
    using namespace wfdbx_tests;
    int run = 0, failed = 0;
    for (const Test &t : registry()) {
        if (argc > 1) {
            bool selected = false;
            for (int i = 1; i < argc; i++)
                if (std::strcmp(argv[i], t.name) == 0) selected = true;
            if (!selected) continue;
        }
        int before = failures;
        try {
            t.fn();
        } catch (const Abort &) {
        } catch (const std::exception &e) {
            fail(__FILE__, __LINE__, std::string("exception: ") + e.what());
        }
        run++;
        if (failures != before) {
            failed++;
            std::fprintf(stderr, "FAIL %s\n", t.name);
        } else
            std::fprintf(stderr, "ok   %s\n", t.name);
    }
    std::fprintf(stderr, "%d test(s), %d failed\n", run, failed);
    return failed ? 1 : 0;
}
