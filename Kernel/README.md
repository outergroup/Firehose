# Apple Container tracing kernel

`build.sh [OUTPUT_DIRECTORY]` builds an ARM64 Linux 6.18.15 kernel using the
configuration exported from the installed Apple Container kernel. It verifies
the kernel.org source SHA-256 before building. The supported configuration/source
pair is intentionally pinned; a different installed kernel requires updating
and validating the pair, not silently reusing an unrelated configuration.

Apple Container is the default builder; `OUTER_BUILD_CONTAINER_RUNTIME=docker`
uses Docker. Neither mode changes the default runtime kernel or existing
containers. The installed Firehose app packages this directory under
`Contents/Resources/kernel` and serves its user guide at `/help/apple-container`.

The configuration enables FTRACE, syscall tracepoints, BPF events, and kprobes.
Create the target with `--kernel PATH --cap-add BPF --cap-add PERFMON
--cap-add SYS_ADMIN --cap-add IPC_LOCK`. The helper mounts tracefs in a private
temporary directory and removes it on exit. IPC_LOCK permits the per-CPU perf
ring buffers without raising the container's general resource limits.

Firehose uses `bpf_get_ns_current_pid_tgid` to filter events to the target PID
namespace and obtain local task/process IDs. Fork tracepoints carry kernel IDs;
the collector resolves them using the child's subsequent event, including exit,
and handles records arriving out of order from different CPU rings. A task that
has not yet produced an event can have its fork row deferred until it does.

Validation on Apple Container 1.1.0: the live task-capture test passes with this
kernel, including short-lived processes, thread names, local IDs and grouping.
`Tests/NamespaceEventsTest.c` covers delayed and out-of-order fork resolution and
PID reuse. Run it on Linux with AddressSanitizer and UndefinedBehaviorSanitizer.

Kernel source: https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.15.tar.xz
Apple kernel build documentation: https://github.com/apple/containerization/tree/main/kernel
