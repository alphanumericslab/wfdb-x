// http_server.hpp: a minimal HTTP server on 127.0.0.1 for the unit tests of
// network access (test_files.cpp, test_metadata.cpp); the tests never
// contact any other host.
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

#ifndef WFDBX_TESTS_HTTP_SERVER_HPP
#define WFDBX_TESTS_HTTP_SERVER_HPP

#if defined(__unix__) || defined(__APPLE__)
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#define WFDBX_HAVE_SOCKETS 1
#endif

#ifdef WFDBX_HAVE_SOCKETS
#include <atomic>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace wfdbx_tests {

// A minimal HTTP server on 127.0.0.1 (a free port), serving the files of a
// directory: GET /NAME returns the file NAME (404 if there is none), and
// GET /redir/NAME redirects to /NAME.  The paths requested are logged.
class HttpServer {
public:
    explicit HttpServer(std::filesystem::path root) : root_(std::move(root)) {
        fd_ = socket(AF_INET, SOCK_STREAM, 0);
        sockaddr_in a{};
        a.sin_family = AF_INET;
        a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        a.sin_port = 0;
        socklen_t len = sizeof(a);
        if (fd_ < 0 || bind(fd_, reinterpret_cast<sockaddr *>(&a), len) != 0 ||
            listen(fd_, 16) != 0 ||
            getsockname(fd_, reinterpret_cast<sockaddr *>(&a), &len) != 0) {
            ok_ = false;
            return;
        }
        port_ = ntohs(a.sin_port);
        thread_ = std::thread([this] { serve(); });
    }
    ~HttpServer() {
        stop_ = true;
        if (fd_ >= 0) {
            shutdown(fd_, SHUT_RDWR);   // (wakes up accept)
            close(fd_);
        }
        if (thread_.joinable()) thread_.join();
    }
    HttpServer(const HttpServer &) = delete;
    HttpServer &operator=(const HttpServer &) = delete;
    bool ok() const { return ok_; }
    std::string url() const {
        return "http://127.0.0.1:" + std::to_string(port_) + "/";
    }
    std::vector<std::string> requests() {
        std::lock_guard<std::mutex> lock(mutex_);
        return log_;
    }
    size_t count(const std::string &path) {
        size_t n = 0;
        for (const std::string &p : requests()) n += (p == path);
        return n;
    }

private:
    static std::string read_file(const std::filesystem::path &name) {
        std::ifstream f(name, std::ios::binary);
        return std::string(std::istreambuf_iterator<char>(f), {});
    }

    void serve() {
        while (!stop_) {
            int c = accept(fd_, nullptr, nullptr);
            if (c < 0) {
                if (stop_) return;
                continue;
            }
            std::string req;
            char buf[4096];
            ssize_t n;
            while (req.find("\r\n\r\n") == std::string::npos &&
                   (n = recv(c, buf, sizeof(buf), 0)) > 0)
                req.append(buf, n);
            std::string path;
            size_t sp = req.find(' ');
            if (sp != std::string::npos)
                path = req.substr(sp + 1, req.find(' ', sp + 1) - sp - 1);
            {
                std::lock_guard<std::mutex> lock(mutex_);
                log_.push_back(path);
            }
            std::string resp;
            std::error_code ec;
            if (path.compare(0, 7, "/redir/") == 0)
                resp = "HTTP/1.0 302 Found\r\nLocation: " + path.substr(6) +
                       "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            else if (path.size() > 1 && path.find("..") == std::string::npos &&
                     std::filesystem::is_regular_file(root_ / path.substr(1),
                                                      ec)) {
                std::string body = read_file(root_ / path.substr(1));
                resp = "HTTP/1.0 200 OK\r\nContent-Length: " +
                       std::to_string(body.size()) +
                       "\r\nConnection: close\r\n\r\n" + body;
            } else
                resp = "HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\n"
                       "Connection: close\r\n\r\n";
            for (size_t off = 0; off < resp.size();) {
                ssize_t w = send(c, resp.data() + off, resp.size() - off, 0);
                if (w <= 0) break;
                off += static_cast<size_t>(w);
            }
            close(c);
        }
    }

    std::filesystem::path root_;
    int fd_ = -1;
    int port_ = 0;
    bool ok_ = true;
    std::atomic<bool> stop_{false};
    std::thread thread_;
    std::mutex mutex_;
    std::vector<std::string> log_;
};

// True if the curl program (which the library runs to fetch URLs) is found.
inline bool have_curl()
{
    return std::system("curl --version >/dev/null 2>&1") == 0;
}

} // namespace wfdbx_tests

#endif // WFDBX_HAVE_SOCKETS

#endif // WFDBX_TESTS_HTTP_SERVER_HPP
