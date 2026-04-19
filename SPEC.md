# Yamiochi Specification

## 1. Overview

Yamiochi is a minimal, RFC-compliant HTTP/1.1 Ruby Rack application server designed for deployment behind a reverse proxy (e.g., Nginx). It uses a preforking process model for concurrency and targets correctness over feature breadth.

**Design principles:**

- Reverse-proxy-first: no SSL, no HTTP/2, no direct internet exposure assumed
- Preforking concurrency only: no threads, no async I/O
- 100% compliance with current RFCs on HTTP.

## 2. Non-Goals

The following are explicitly out of scope for v1:

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

### 3.2 Master Process Responsibilities

- Load the Rack application (before forking)
- Bind all listening sockets
- Fork and monitor the worker pool
- Handle signals (see §7)
- Manage PID file lifecycle
- Detect and replace stuck workers via heartbeat

### 3.3 Worker Process Responsibilities

- Accept a connection from the shared listening socket(s)
- Parse the HTTP/1.1 request
- Build the Rack environment hash
- Invoke the Rack application
- Write the HTTP/1.1 response
- Close the connection
- Write heartbeat timestamp
- Loop

### 3.4 Worker Timeout and Heartbeat

Each worker writes its PID and a Unix timestamp to a per-worker tmpfile (`/tmp/yamiochi-heartbeat-<pid>`) after completing each request and immediately before each `accept(2)` call. The master checks these files on a 1-second interval. If a worker's timestamp is older than the configured timeout, the master sends `SIGKILL` to that worker and forks a replacement.

Default timeout: 60 seconds.

## 4. HTTP/1.1 Protocol

### 4.1 Request Parsing

Yamiochi parses HTTP/1.1 requests per RFC 7230.

Yamiochi REJECTS HTTP/1.0 requests.

**Request line:**

- Format: `METHOD SP Request-URI SP HTTP-version CRLF`
- Accepted HTTP versions: `HTTP/1.1` only; `HTTP/1.0` requests receive a 400 response

**Headers:**

- Format: `field-name ":" OWS field-value OWS CRLF`
- Header names are case-insensitive
- Obsolete line folding (obs-fold) in request headers: respond with 400 (RFC 7230 §3.2.4)
- Multiple headers with the same name are combined as comma-separated values, except `Cookie` (concatenated with `; `)
- Maximum header count: 100 (configurable)
- Maximum total header size: 8 KB (configurable)
- Maximum request-URI length: 8 KB (configurable)

**Error responses for malformed requests:**

| Condition | Status |
|-----------|--------|
| Malformed request line or headers | 400 Bad Request |
| Body exceeds configured maximum | 413 Payload Too Large |
| URI exceeds length limit | 414 URI Too Long |
| Headers exceed size limit | 431 Request Header Fields Too Large |
| Unknown `Transfer-Encoding` value | 501 Not Implemented |

### 4.2 Request Body Handling

- `Content-Length` present: read exactly that many bytes into the body buffer
- `Transfer-Encoding: chunked` present: decode per RFC 7230 §4.1; chunked trailers are read and discarded (not exposed to Rack)
- Both present: ignore `Content-Length`, use chunked (RFC 7230 §3.3.3 rule 3)
- Neither present: body is empty (`rack.input` returns empty reads)
- Body is buffered in memory if ≤ 16 KB; spilled to a `Tempfile` if larger
- Maximum body size: configurable (default: no limit)

### 4.3 Response Writing

**Status line:** `HTTP/1.1 SP status-code SP reason-phrase CRLF`

**Mandatory response headers (always added by Yamiochi):**

| Header | Value |
|--------|-------|
| `Date` | RFC 7231 §7.1.1.2 format |
| `Server` | `Yamiochi` |
| `Connection` | `close` |

**Body framing:**

- If the Rack application sets a `Content-Length` header, or the body responds to `#to_ary` (allowing length determination): use identity encoding with `Content-Length`
- Otherwise: use `Transfer-Encoding: chunked`; do not set `Content-Length`
- Yamiochi must not set both `Content-Length` and `Transfer-Encoding: chunked`

**HEAD requests:** write headers only; do not write the body but do call `body.each` (to allow side effects) unless body responds to `#close`, in which case close it immediately.

**Body close:** call `body.close` after response is written if the body responds to `#close`.

### 4.4 HTTP Methods

All standard methods are accepted at the parser level: `GET`, `HEAD`, `POST`, `PUT`, `DELETE`, `PATCH`, `OPTIONS`, `TRACE`. Unrecognized methods are passed to the Rack application unchanged (RFC 7231 §4.1); Yamiochi does not reject them.

### 4.5 100-Continue

If the request includes `Expect: 100-continue`, send `HTTP/1.1 100 Continue\r\n\r\n` before reading the request body. Other `Expect` values return 417 Expectation Failed.

### 4.6 Absolute-Form URIs

Requests with absolute-form URIs (e.g., `GET http://example.com/path HTTP/1.1`) are accepted. Extract the path and query string for Rack; use the host component to populate `SERVER_NAME` and `SERVER_PORT` when no `Host` header is present.

### 4.7 Reason Phrases

Yamiochi uses the canonical reason phrases from RFC 7231 §6. For unknown status codes, the reason phrase is `Unknown`.

## 5. Rack Interface

Yamiochi targets the **Rack 3** specification.

### 5.1 Environment Hash

| Key | Value |
|-----|-------|
| `REQUEST_METHOD` | HTTP method, uppercase string |
| `SCRIPT_NAME` | `""` |
| `PATH_INFO` | Request path; percent-encoded characters are preserved except `%2F` |
| `QUERY_STRING` | Query string without leading `?`, or `""` |
| `SERVER_NAME` | Host from `Host` header, without port |
| `SERVER_PORT` | Port as string (from `Host` header or socket address) |
| `SERVER_PROTOCOL` | `"HTTP/1.1"` |
| `rack.input` | IO-like body object (see below) |
| `rack.errors` | `$stderr` |
| `rack.url_scheme` | `"http"` (always; TLS is upstream) |
| `rack.multithread` | `false` |
| `rack.multiprocess` | `true` |
| `rack.run_once` | `false` |
| `rack.hijack?` | `false` |
| `CONTENT_TYPE` | Value of `Content-Type` header, or `""` |
| `CONTENT_LENGTH` | Value of `Content-Length` header, or `""` |
| `HTTP_*` | All other request headers, uppercased, hyphens replaced with underscores |

`rack.input` must support `#read`, `#gets`, `#each`, and `#rewind`. It must be rewound to position 0 before being handed to the app.

### 5.2 Response Contract

The application returns `[status, headers, body]`:

- `status`: Integer
- `headers`: Hash (string keys → string values or Array of strings)
- `body`: Object responding to `#each`, yielding `String` chunks

Yamiochi adds `Date`, `Server`, and `Connection` headers and may add `Transfer-Encoding: chunked`. It must not otherwise modify or remove application-provided headers.

### 5.3 Rack::Handler Registration

Yamiochi registers itself as a Rack handler under the name `yamiochi`, enabling:

```
rackup -s yamiochi config.ru
```

## 6. Configuration

### 6.1 Config File DSL

Yamiochi loads a Ruby config file (default: `config/yamiochi.rb` if it exists). The file is evaluated in the context of a configuration DSL object. Example:

```ruby
bind "tcp://0.0.0.0:9292"
bind "unix:///tmp/yamiochi.sock"
workers 4
timeout 30
pid_file "/var/run/yamiochi.pid"
stdout_redirect "/var/log/yamiochi.stdout.log"
stderr_redirect "/var/log/yamiochi.stderr.log"
max_header_size 16384
max_uri_length 8192
backlog 1024

before_fork do
  # called in master before each worker is forked
  close_log_handles
end

on_worker_boot do
  # called in each worker after fork, before the accept loop
  reopen_log_handles
end
```

**Lifecycle hooks:**

- `before_fork`: block called in the master process immediately before forking each worker. Use to release resources (DB connections, file handles) that should not be shared across fork.
- `on_worker_boot`: block called inside the worker process after fork, before the accept loop begins. Use to re-establish resources released in `before_fork`.

Both hooks are optional. Exceptions raised in either hook are logged and re-raised, aborting the fork.

### 6.2 CLI Flags

| Flag | Default | Description |
|------|---------|-------------|
| `-b`, `--bind URI` | `tcp://0.0.0.0:9292` | Bind address (repeatable) |
| `-w`, `--workers N` | `2` | Number of worker processes |
| `-t`, `--timeout N` | `60` | Worker request timeout in seconds |
| `-C`, `--config FILE` | `config/yamiochi.rb` | Config file path |
| `-p`, `--pid FILE` | none | PID file path |
| `--stdout FILE` | none | Redirect stdout to file |
| `--stderr FILE` | none | Redirect stderr to file |

**Precedence:** CLI flags override config file values.

### 6.3 Invocation

```sh
# Direct
yamiochi -b tcp://0.0.0.0:9292 -w 4 config.ru

# Via rackup
rackup -s yamiochi -p 9292 config.ru
```

The Rack application is loaded via `Rack::Builder.parse_file`.

## 7. Process Management

### 7.1 Signal Handling

| Signal | Master behavior | Worker behavior |
|--------|----------------|-----------------|
| `SIGTERM` | Graceful shutdown (see §7.2) | Finish current request, then exit 0 |
| `SIGQUIT` | Graceful shutdown (see §7.2) | Finish current request, then exit 0 |
| `SIGINT` | Immediate shutdown: SIGKILL all workers, exit 0 | Exit immediately |
| `SIGHUP` | Reopen stdout/stderr log files | Reopen stdout/stderr log files |
| `SIGCHLD` | Reap dead workers; replace if not shutting down | — |

`SIGTERM` and `SIGQUIT` are equivalent. Both are provided for operator ergonomics: `SIGTERM` matches Puma convention; `SIGQUIT` matches Unicorn convention.

### 7.2 Graceful Shutdown Sequence

1. Master receives `SIGTERM` or `SIGQUIT`
2. Master closes all listening sockets (no new connections accepted)
3. Master sends `SIGTERM` to all workers
4. Master waits up to the configured timeout for workers to exit
5. Master sends `SIGKILL` to any remaining workers
6. Master removes PID file
7. Master exits 0

### 7.3 PID File

- Written after sockets are bound, before workers are forked
- Contains master PID as a decimal string followed by newline
- Removed on clean exit (SIGTERM, SIGQUIT, or SIGINT)
- Not removed on crash; stale PID files are overwritten on next start

## 8. Networking

### 8.1 Bind URI Schemes

| Scheme | Example | Notes |
|--------|---------|-------|
| `tcp://` | `tcp://0.0.0.0:9292` | IPv4 TCP |
| `tcp://` | `tcp://[::]:9292` | IPv6 TCP |
| `unix://` | `unix:///tmp/yamiochi.sock` | Unix domain socket |

Multiple bind URIs are supported via repeated `--bind` flags or `bind` calls in the config file. Workers select among all sockets using `IO.select` before calling `accept`.

### 8.2 Socket Options

**TCP sockets:**
- `SO_REUSEADDR`: enabled
- `TCP_NODELAY`: enabled
- Listen backlog: 1024 (configurable via `backlog N`)

**Unix domain sockets:**
- Permissions: `0666` (access control delegated to filesystem)
- Existing socket file is removed before binding

### 8.3 Worker Accept Strategy

Workers use a plain `accept(2)` loop on the inherited socket fd(s). When multiple sockets are configured, workers use `IO.select` to find a readable socket, then call `accept`. No advisory locking is used; `accept(2)` is atomic at the OS level on Linux and macOS.

## 9. Error Handling

### 9.1 Application Exceptions

- Exceptions raised by the Rack application are rescued in the worker
- Exception class, message, and backtrace are logged to stderr
- If response headers have not been sent: a `500 Internal Server Error` response is written
- If headers have been partially written: the connection is closed without completing the response

### 9.2 Malformed Rack Responses

If the application returns an invalid status (non-integer, out of range), a non-enumerable body, or headers that are not a Hash, Yamiochi logs an error and closes the connection.

### 9.3 Client Errors

`Errno::ECONNRESET`, `Errno::EPIPE`, and `EOFError` during request read or response write are rescued silently; the connection is closed and the worker moves on.

## 10. Logging

- All log output goes to stderr by default (redirectable via config)
- Format: `[PID] YYYY-MM-DDTHH:MM:SS.sss LEVEL MESSAGE`
- Default log level: INFO

**Logged events:**

| Event | Level |
|-------|-------|
| Startup: bind addresses, worker count, PID | INFO |
| Worker forked | DEBUG |
| Worker exited normally | DEBUG |
| Worker crashed (unexpected exit) | WARN |
| Worker killed for timeout | WARN |
| Worker replaced after crash | INFO |
| Application exception | ERROR (with backtrace) |
| Graceful shutdown initiated | INFO |

**Per-request access log (worker, after response):**

```
[PID] TIMESTAMP INFO GET /path 200 1.23ms 4096b
```

Fields: method, path, status code, duration in ms, response bytes sent.

## 11. Gem Structure

Yamiochi is distributed as a Ruby gem named `yamiochi`.

**Executables:** `yamiochi`

**Runtime dependencies:**

- `rack` >= 3.0 (Rack 3 interface)

**No other runtime dependencies.** Standard library only (`socket`, `io/wait`, `tempfile`, `optparse`, `etc`).

**Development dependencies** (test/tooling only): `minitest`, `rack-test`, `rubocop`.

**Ruby version requirement:** >= 3.1

## 12. Definition of Done

### 12.1 Process Model

- [ ] Master binds all sockets before forking any workers
- [ ] Forking N workers produces exactly N live worker processes (`ps` count)
- [ ] A worker that exits unexpectedly is replaced within 1 second
- [ ] A worker that exceeds the timeout is killed and replaced
- [ ] `before_fork` hook is called in master before each worker fork
- [ ] `on_worker_boot` hook is called inside each worker after fork, before the accept loop
- [ ] Exception in `before_fork` or `on_worker_boot` is logged and aborts the fork

### 12.2 HTTP Request Parsing

- [ ] GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS requests parsed correctly
- [ ] Chunked request body decoded correctly (including multi-chunk bodies)
- [ ] Content-Length body read exactly
- [ ] Malformed request line returns 400
- [ ] Oversized URI returns 414
- [ ] Oversized headers return 431
- [ ] Expect: 100-continue elicits 100 before body read
- [ ] Absolute-form URI accepted and parsed correctly
- [ ] obs-fold in request headers returns 400

### 12.3 HTTP Response

- [ ] Every response includes `Date`, `Server: Yamiochi`, `Connection: close`
- [ ] Responses with known body length use `Content-Length`, not chunked
- [ ] Responses with unknown body length use `Transfer-Encoding: chunked`
- [ ] HEAD responses send headers only, no body
- [ ] 500 is returned when the Rack app raises an unhandled exception
- [ ] `body.close` is called after response is written when available

### 12.4 Rack Compliance

- [ ] All required Rack 3 environment keys are present and correctly typed
- [ ] `rack.input` supports `#read`, `#gets`, `#each`, `#rewind`
- [ ] `rack.input` is rewound to position 0 before app invocation
- [ ] `rack.multithread` is `false`
- [ ] `rack.multiprocess` is `true`
- [ ] `rack.hijack?` is `false`
- [ ] Application passes `Rack::Lint` without errors
- [ ] Rackup handler `yamiochi` is registered and invocable via `rackup -s yamiochi`

### 12.5 Configuration

- [ ] `--bind tcp://HOST:PORT` binds to specified TCP address
- [ ] `--bind unix:///path` binds to specified Unix socket
- [ ] Repeated `--bind` flags bind to all specified addresses
- [ ] `-w N` sets worker count
- [ ] `-t N` sets request timeout
- [ ] `-C FILE` loads specified config file
- [ ] Config file DSL supports all options available via CLI
- [ ] CLI flags override equivalent config file settings
- [ ] Missing config file is not an error (when using default path)

### 12.6 Networking

- [ ] TCP bind to `0.0.0.0:PORT` works and accepts connections
- [ ] TCP bind to a specific interface address works
- [ ] Unix socket bind works; socket file is created with mode 0666
- [ ] Existing Unix socket file is removed before binding
- [ ] Unix socket file is removed on clean exit
- [ ] `SO_REUSEADDR` is set on TCP sockets
- [ ] `TCP_NODELAY` is set on TCP sockets

### 12.7 Signals

- [ ] SIGTERM triggers graceful shutdown; in-flight requests complete before exit
- [ ] SIGQUIT triggers graceful shutdown; identical behavior to SIGTERM
- [ ] SIGINT triggers immediate shutdown; workers are SIGKILLed
- [ ] SIGHUP reopens stdout/stderr log files in master and all workers
- [ ] PID file is removed on clean exit (SIGTERM, SIGQUIT, or SIGINT)

### 12.8 Logging

- [ ] Each completed request produces one access log line with method, path, status, duration, bytes
- [ ] Worker crashes are logged at WARN level
- [ ] Application exceptions are logged with full backtrace at ERROR level
- [ ] Master startup logs bind addresses and worker count
- [ ] SIGHUP causes log files to be reopened without dropping log lines

### 12.9 Protocol Compliance

- [ ] http-probe.com reports no critical or major failures against a running Yamiochi instance
- [ ] h1spec (`github.com/uNetworking/h1spec`) reports no failures against a running Yamiochi instance (RFC 7230–7235 conformance)
- [ ] REDbot (`github.com/mnot/redbot`, self-hosted) reports no errors against a running Yamiochi instance
- [ ] A standard Sinatra `hello world` application serves correctly under Yamiochi
- [ ] A standard Rails application in production mode serves correctly under Yamiochi
