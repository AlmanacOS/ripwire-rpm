#!/bin/bash
# Run copr-cli in a container, for hosts without it (Silverblue/Kinoite and friends).
#
# Needs a COPR API token at ~/.config/copr. Get one from
# https://copr.fedorainfracloud.org/api/ (log in first) and paste the whole
# [copr-cli] block into that file.
#
#   ./copr-cli-podman.sh whoami
#   ./copr-cli-podman.sh build-package AlmanacOS --name ripwire
#
# The repository is mounted at /pkg and that is the working directory, so paths
# like copr-custom-script.sh resolve as they would locally.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config="${COPR_CONFIG:-$HOME/.config/copr}"

if [ ! -f "$config" ]; then
    cat >&2 <<MSG
No COPR API token at $config

  1. open https://copr.fedorainfracloud.org/api/ and log in
  2. copy the [copr-cli] block it shows
  3. install -Dm600 /dev/stdin $config   # then paste, Ctrl-D

MSG
    exit 1
fi

# The image is built once and reused; rebuilt only if it is missing.
image=localhost/copr-cli-runner
if ! podman image exists "$image"; then
    printf '==> building %s\n' "$image" >&2
    podman build -q -t "$image" -f - . >/dev/null <<'CONTAINERFILE'
FROM registry.fedoraproject.org/fedora:44
RUN dnf -y install --setopt=install_weak_deps=False copr-cli && dnf clean all
CONTAINERFILE
fi

# -t only when stdout is a terminal; otherwise podman warns about a missing TTY.
tty=(); [ -t 1 ] && tty=(-it)

exec podman run --rm "${tty[@]}" \
    -v "$config:/root/.config/copr:ro,Z" \
    -v "$repo:/pkg:ro,Z" \
    -w /pkg \
    "$image" copr-cli "$@"
