# Firehose

Firehose is a procmon-like outerframe app. The backend owns the event buffer and the frontend asks for only the visible event window with `/api/events?start=N&count=M`. Event responses use a little-endian binary format with fixed-size records and `StringRef32` offset/length references into a variable-length string region.

The backend stores captured events in an append-only temporary binary file, so the event history is limited by available temporary storage rather than a fixed in-memory ring.

The Linux backend collects process events through eBPF `sched` tracepoints and requires root privileges.

## Deploy Over SSH

With a current Outer Shell installed on the target:

```bash
./app target "ssh root@server"
./app deploy
```

Firehose defaults to a system deployment because its eBPF collector requires
root. A non-root SSH account can set `OUTER_TARGET_SCOPE=system` in the
gitignored `target.env`; `./app deploy` will request the administrator password
when needed. Deployment detects the target architecture and libc and builds
only the matching dynamic backend. glibc builds use the manylinux2014 (glibc
2.17) baseline; musl builds use musllinux 1.2. Run `./app build-matrix` to build
all four Linux release variants, or `./app help` for the other commands.

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
./build/macos/Release/FirehoseBackend --port "$PORT" --bundles-dir ./build/run/bundles
```

Open this URL in Outer Loop or Outer Frame:

```text
http://127.0.0.1:7352/
```

The backend serves the outerframe descriptor, the archived macOS content bundles, and the event API from the same loopback HTTP server.

The event API response format starts with magic `TRCE`, version `1`, `total`, `start`, `count`, and `recordSize`. Each event record stores `id`, `timestamp`, `pid`, `ppid`, then `StringRef32` fields for `time`, `type`, `process`, and `detail`.

On Linux, the backend requires root and uses the eBPF collector:

```bash
sudo ./FirehoseBackend --port 7353 --bundles-dir ./bundles --capture ebpf
```

## Current Architecture

- `Frontend/TraceContent.swift`: native outerframe table UI with scroll/key navigation and viewport-sized API fetches.
- `Backend/main.c`: loopback HTTP server, eBPF process collector, event ring buffer, `.outer` descriptor, and bundle serving.
- `Scripts/archive_trace_bundle.sh`: creates `FirehoseContent.bundle.macos-arm.aar` and `FirehoseContent.bundle.macos-x86.aar`.

## Container-aware HTML view

On Linux with cgroup v2, Firehose captures the emitting task's cgroup ID in each eBPF event. A background thread discovers registered Docker containers through Outer Shell's binary registry API and maps cgroup filesystem IDs to container identities. Event records retain the observed identity/name after the process exits. The HTML container picker filters both events and the process timeline on the server. PIDs remain host PIDs.

Discovery refreshes every five seconds. Events from cgroups not yet discovered are explicitly labeled unresolved, rather than attributed to the host. The collector runs on the Linux host; containers inside a different VM/kernel are not supported by this path. No container helper or additional container privileges are installed.

Run `python3 Scripts/test_container_events.py` for sanitizer-backed fork-path copying, event identity, binary encoding, and filtering checks.

Linux capture uses task IDs consistently for fork, syscall, and exit events, while the timeline groups those events by the owning process ID (TGID). Worker-thread lifecycle events do not create separate process rows or end the owning process. Fork names are read at capture time from either fixed-length or `__data_loc` tracepoint fields, including for children that exit before userspace consumes the event. `Scripts/test_linux_task_capture.py /absolute/path/to/FirehoseBackend` tests this using a separate backend instance and requires root on Linux.

## macOS container tracing

The user app supports registered Docker and Apple Container targets. The Mac
backend never traces macOS. The landing page chooses a runtime or an Apple
container; target paths are retained in HTML and outerframe navigation.

Docker uses an app-owned Linux worker with explicit tracing capabilities and
access to the VM PID namespace. Only containers in Outer Shell's binary registry
are eligible, and expired registry snapshots fail closed. No Docker socket is
mounted in the worker. It starts on first use and stops with the Mac backend.

Apple Container runs the app's own Linux helper inside the selected container.
The helper stays alive while the backend uses it and exits when its stdin closes.
Requests and responses use the existing binary app APIs in offset-based TRPC
frames over `container exec --interactive`; there is no JSON helper protocol.
The registry, rather than CLI container listings, supplies targets.

Build and install with `./app deploy --local`. Xcode and either Docker or Apple
Container are needed to build the Linux helper. Set
`OUTER_BUILD_CONTAINER_RUNTIME=container|docker` to choose the builder. The app
packages its helper under `Contents/Resources/helpers`, and Outer Shell's
container bootstrap includes it in new base images. Existing images need their
helper installed at `/usr/local/bin/outer-firehose-helper` and rebuilt.
Docker worker images are built during installation when Docker is available, or
on first Docker use otherwise.

Apple Container 1.1.0's standard Linux 6.18.15 kernel has FTRACE disabled.
Firehose now supplies a checksum-verified custom-kernel builder and an in-app
setup guide at `/help/apple-container`. The unsupported-capture banner links to
that guide; the native frontend includes setup instructions too. See
[Kernel/README.md](Kernel/README.md) for the build and validation details.

Live capture has been verified with the generated kernel and BPF, PERFMON,
SYS_ADMIN and IPC_LOCK capabilities. Events use container-local process/task IDs,
exclude the surrounding VM's tasks, and preserve short-lived child/thread events.
Existing containers must be recreated with the kernel and capabilities; installing
Firehose does not replace their kernels or change Apple's user-wide default.

Windows support is built and packaged by `Backends/Windows`. Its native C host
runs as an ordinary user task and exposes a named pipe. Docker tracing uses a
helper container with tracing capabilities and the selected container's PID
namespace. WSLc has separate target identities from WSL distributions, but its
current capability restrictions prevent live capture. The Windows picker explains
this limitation. Both HTML and macOS native content are included. See
`../Backends/Windows/README.md` for the permission model and build instructions.

Run `python3 Scripts/test_macos_container_app.py` after installation to verify
Docker APIs, host exclusion, HTML and favicon. The portable frame codec test is
`cc -std=gnu17 Scripts/test_tracing_stream.c -o /tmp/test-stream && /tmp/test-stream`.
