# Trace

Trace is a procmon-like outerframe prototype. The backend owns the event buffer and the frontend asks for only the visible event window with `/api/events?start=N&count=M`. Event responses use a little-endian binary format with fixed-size records and `StringRef32` offset/length references into a variable-length string region.

The backend stores captured events in an append-only temporary binary file, so the event history is limited by available temporary storage rather than a fixed in-memory ring.

The Linux backend collects process events through eBPF `sched` tracepoints and requires root privileges.

The current event types are:

- `capture.start`
- `process.present`
- `process.fork`
- `process.execve`
- `process.start`
- `process.exit`
- `file.openat`
- `file.openat2`
- `file.close`
- `file.read`
- `file.write`
- `capture.warning`

This gives the app an end-to-end event pipeline before adding lower-level syscall, file, and network collectors.

## Build

```bash
./build_run.sh
```

## Run

```bash
PORT=7352
./build/macos/Release/TraceBackend --port "$PORT" --bundles-dir ./build/run/bundles
```

Open this URL in Outer Loop or Outer Frame:

```text
http://127.0.0.1:7352/
```

The backend serves the outerframe descriptor, the archived macOS content bundles, and the event API from the same loopback HTTP server.

The event API response format starts with magic `TRCE`, version `1`, `total`, `start`, `count`, and `recordSize`. Each event record stores `id`, `timestamp`, `pid`, `ppid`, then `StringRef32` fields for `time`, `type`, `process`, and `detail`.

On Linux, the backend requires root and uses the eBPF collector:

```bash
sudo ./TraceBackend --port 7353 --bundles-dir ./bundles --capture ebpf
```

## Current Architecture

- `Frontend/TraceContent.swift`: native outerframe table UI with scroll/key navigation and viewport-sized API fetches.
- `Backend/main.c`: loopback HTTP server, eBPF process collector, event ring buffer, `.outer` descriptor, and bundle serving.
- `Scripts/archive_trace_bundle.sh`: creates `TraceContent.bundle.macos-arm.aar` and `TraceContent.bundle.macos-x86.aar`.
