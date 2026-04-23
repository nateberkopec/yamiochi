# Yamiochi Specification

## 1. Overview

Yamiochi is a minimal, RFC-compliant HTTP/1.1 Ruby Rack application server designed for deployment behind a reverse proxy (e.g., Nginx). It uses a preforking process model for concurrency and targets correctness over feature breadth.

**Design principles:**

- Reverse-proxy-first: no SSL, no HTTP/2, no direct internet exposure assumed
- Preforking concurrency only: no threads, no async I/O
- 100% compliance with current RFCs on HTTP for supported features.
- Least surprise. Where implemented, the user-facing behavior should be broadly similar to Puma, Unicorn and Webrick.
- What (limited) things we do, we do securely (lacking vulnerabilities) and with high performance.

### 1.1 This Document's Precedence

Yamiochi's tests, contained in `test/`, are considered subsidiary to this document. Where behavior is undefined by this specification, the tests are considered authoritative. However, the tests must never contradict this specification.

## 2. Non-Goals

The following features, though common in Ruby application servers, are out of scope:

- TLS/SSL termination
- HTTP/2 or HTTP/3
- Threading or async I/O within workers
- Keep-alive / persistent connections (every response includes `Connection: close`)
- Zero-downtime restarts (phased restart, USR2-style)
- WebSockets or HTTP upgrade
- Request pipelining
- Acting as a reverse proxy

## 3. Architecture

### 3.1 Process Model

Yamiochi uses a preforking master/worker model. It does not support any other models, such as a single-process model.

Preforking is mandatory and cannot be disabled.

## 4. HTTP/1.1 Protocol

Yamiochi should have 100% RFC compliance for HTTP 1.1 except for the following explicit exclusions:

1. keep-alives are not supported
2. Request pipelining is not supported

### 4.1 Request Parsing

`HTTP/1.1` only; `HTTP/1.0` requests receive a 400 response

### 4.2 HTTP Methods

Unrecognized methods are passed to the Rack application unchanged (RFC 7231 §4.1); Yamiochi does not reject them.

## 5. Rack Interface

Yamiochi targets the [**Rack 3** specification](support/RACK.rdoc).

## 6. Configuration

### 6.1 Config File DSL

Yamiochi loads a Ruby config file (default: `config/yamiochi.rb` if it exists). The file is evaluated in the context of a configuration DSL object. Example:

```ruby
bind "tcp://0.0.0.0:9292"
bind "unix:///tmp/yamiochi.sock"
workers 4
pid_file "/var/run/yamiochi.pid"
stdout_redirect "/var/log/yamiochi.stdout.log"
stderr_redirect "/var/log/yamiochi.stderr.log"

before_fork do
  # called in master before each worker is forked
  close_log_handles
end

on_worker_boot do
  # called in each worker after fork, before the accept loop
  reopen_log_handles
end
```

Yamiochi supports two hooks:

**Lifecycle hooks:**

- `before_fork`: block called in the master process immediately before forking each worker. Use to release resources (DB connections, file handles) that should not be shared across fork.
- `on_worker_boot`: block called inside the worker process after fork, before the accept loop begins. Use to re-establish resources released in `before_fork`.

Both hooks are optional.

### 6.2 CLI Flags

| Flag | Default | Description |
|------|---------|-------------|
| `-b`, `--bind URI` | `tcp://0.0.0.0:9292` | Bind address (repeatable) |
| `-w`, `--workers N` | `2` | Number of worker processes |
| `-C`, `--config FILE` | `config/yamiochi.rb` | Config file path |
| `-p`, `--pid FILE` | none | PID file path |
| `--stdout FILE` | none | Redirect stdout to file |
| `--stderr FILE` | none | Redirect stderr to file |

**Precedence:** CLI flags override config file values.

### 6.3 Invocation

```sh
yamiochi -b tcp://0.0.0.0:9292 -w 4 config.ru

rackup -s yamiochi -p 9292 config.ru
```

## 7. Process Management

### 7.1 Signal Handling

| Signal | Master behavior | Worker behavior |
|--------|----------------|-----------------|
| `SIGTERM` | Graceful shutdown (see §7.2) | Finish current request, then exit 0 |
| `SIGQUIT` | Graceful shutdown (see §7.2) | Finish current request, then exit 0 |
| `SIGINT` | Immediate shutdown: SIGKILL all workers, exit 0 | Exit immediately |
| `SIGHUP` | Reopen stdout/stderr log files | Reopen stdout/stderr log files |
| `SIGCHLD` | Reap dead workers; replace if not shutting down | — |


### 7.2 Graceful Shutdown Timeout

The master can wait for up to 25 seconds for workers to exit.

### 7.3 PID File

- Written after sockets are bound, before workers are forked
- Contains master PID as a decimal string followed by newline
- Removed on clean exit (SIGTERM, SIGQUIT, or SIGINT)
- Not removed on crash; stale PID files are overwritten on next start

## 8. Networking

TCP and Unix sockets are supported.

### 8.2 Socket Options

**TCP sockets:**
- `TCP_NODELAY`: enabled
- Listen backlog: 1024

## 9. Error Handling

Yamiochi rescues application errors and returns 500.

## 10. Logging

Yamoichi's log output is configurable.

## 11. Gem Structure

Yamiochi is distributed as a Ruby gem named `yamiochi`.

`yamiochi` has zero runtime dependencies outside the Ruby standard library and default gems.

**Ruby version requirement:** >= 3.2

## 12. Security and Performance

Yamiochi should be secure, in that there are no vulnerabilities in it which would require a patch-level release to fix and potentially a CVE.

Yamiochi will be performant in terms of throughput and latency. It must process 400,000 hello world requests per second over 4 worker processes on our reference benchmark hardware.

Yamiochi must not implement or use any native language extensions. They are difficult to maintain from a security perspective.

## 13. Definition of Done

### 13.1 Process Model

- [ ] Master binds all sockets before forking any workers
- [ ] Forking N workers produces exactly N live worker processes
- [ ] A worker that exits unexpectedly is replaced within 1 second
- [ ] `before_fork` hook is called in master before each worker fork
- [ ] `on_worker_boot` hook is called inside each worker after fork, before the accept loop

### 13.2 HTTP Request Parsing

- [ ] Complies fully with HTTP 1.1

### 13.3 HTTP Response

- [ ] Every response includes `Date`, `Server: Yamiochi`, `Connection: close`
- [ ] Responses with known body length use `Content-Length`, not chunked
- [ ] Responses with unknown body length use `Transfer-Encoding: chunked`
- [ ] HEAD responses send headers only, no body
- [ ] 500 is returned when the Rack app raises an unhandled exception
- [ ] `body.close` is called after response is written when available

### 13.4 Rack Compliance

- [ ] All required Rack 3 environment keys are present and correctly typed
- [ ] `rack.input` supports `#read`, `#gets`, `#each`, `#rewind`
- [ ] `rack.input` is rewound to position 0 before app invocation
- [ ] `rack.multithread` is `false`
- [ ] `rack.multiprocess` is `true`
- [ ] `rack.hijack?` is `false`
- [ ] Application passes `Rack::Lint` without errors
- [ ] Rackup handler `yamiochi` is registered and invocable via `rackup -s yamiochi`

### 13.5 Configuration

- [ ] `--bind tcp://HOST:PORT` binds to specified TCP address
- [ ] `--bind unix:///path` binds to specified Unix socket
- [ ] Repeated `--bind` flags bind to all specified addresses
- [ ] `-w N` sets worker count
- [ ] `-C FILE` loads specified config file
- [ ] Config file DSL supports all options available via CLI
- [ ] CLI flags override equivalent config file settings
- [ ] Missing config file is not an error (when using default path)

### 13.6 Networking

- [ ] TCP bind to `0.0.0.0:PORT` works and accepts connections
- [ ] TCP bind to a specific interface address works
- [ ] Unix socket bind works; socket file is created with mode 0666
- [ ] Existing Unix socket file is removed before binding
- [ ] Unix socket file is removed on clean exit
- [ ] `TCP_NODELAY` is set on TCP sockets

### 13.7 Signals

- [ ] SIGTERM triggers graceful shutdown; in-flight requests complete before exit
- [ ] SIGQUIT triggers graceful shutdown; identical behavior to SIGTERM
- [ ] SIGINT triggers immediate shutdown; workers are SIGKILLed
- [ ] SIGHUP reopens stdout/stderr log files in master and all workers
- [ ] PID file is removed on clean exit (SIGTERM, SIGQUIT, or SIGINT)

### 13.8 Logging

- [ ] Each completed request produces one access log line with method, path, status, duration, bytes
- [ ] Worker crashes are logged at WARN level
- [ ] Application exceptions are logged with full backtrace at ERROR level
- [ ] Master startup logs bind addresses and worker count
- [ ] SIGHUP causes log files to be reopened without dropping log lines
