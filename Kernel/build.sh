#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
output="${1:-$HOME/Library/Application Support/org.outershell.Firehose/kernels/6.18.15-firehose}"
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'This kernel builder targets Apple silicon Macs.' >&2; exit 1; }
container system status >/dev/null
runtime="${OUTER_BUILD_CONTAINER_RUNTIME:-container}"
case "$runtime" in container|docker) ;; *) echo 'Choose container or docker as the build runtime.' >&2; exit 1;; esac
mkdir -p "$output"
output="$(cd "$output" && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
version=$(container run --rm alpine:3.22 uname -r)
case "$version" in 6.18.15*) ;; *) echo "Expected Apple kernel 6.18.15, found $version. Update and validate the kernel source/configuration pair before building." >&2; exit 1;; esac
container run --rm alpine:3.22 sh -c 'zcat /proc/config.gz' > "$work/stock.config"
grep -q '^CONFIG_ARM64=y$' "$work/stock.config"
curl --fail --location --retry 3 https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.15.tar.xz -o "$work/linux.tar.xz"
printf '%s  %s\n' 7c716216c3c4134ed0de69195701e677577bbcdd3979f331c182acd06bf2f170 "$work/linux.tar.xz" | shasum -a 256 -c -
cp "$root/Dockerfile" "$work/Dockerfile"
"$runtime" build --platform linux/arm64 --output "type=local,dest=$work/export" "$work"
artifacts="$work/export"
if [[ ! -f "$artifacts/vmlinux-firehose" ]]; then artifacts="$artifacts/out.tar/linux_arm64"; fi
install -m 644 "$artifacts/vmlinux-firehose" "$output/vmlinux-firehose"
install -m 644 "$artifacts/config-firehose" "$output/config-firehose"
printf '\nBuilt kernel: %s\nUse it with container create --kernel (see the Firehose setup guide).\n' "$output/vmlinux-firehose"
