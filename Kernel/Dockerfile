FROM debian:trixie-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends build-essential bc flex bison libssl-dev libelf-dev xz-utils ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /kernel
COPY linux.tar.xz stock.config ./
RUN tar -xf linux.tar.xz --strip-components=1 && cp stock.config .config && \
    scripts/config --enable FTRACE --enable FTRACE_SYSCALLS --enable BPF --enable BPF_SYSCALL --enable BPF_EVENTS --enable KPROBES --enable KPROBE_EVENTS --disable LOCALVERSION_AUTO && \
    make olddefconfig && \
    for option in FTRACE FTRACE_SYSCALLS BPF_SYSCALL BPF_EVENTS; do grep -qx "CONFIG_${option}=y" .config || exit 1; done
RUN make -j4 LOCALVERSION=-firehose Image && cp arch/arm64/boot/Image /vmlinux-firehose && cp .config /config-firehose
FROM scratch
COPY --from=build /vmlinux-firehose /config-firehose /
