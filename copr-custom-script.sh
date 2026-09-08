#!/bin/bash
# COPR "Custom" source-method script for ripwire. Resolves the newest upstream release
# tag at build time, so a rebuild picks up a new release with no edits here.
#
# COPR package settings that go with it (see README.md):
#   Build dependencies: bash coreutils curl jq tar sed findutils rpm-build git-core
#   Chroot: fedora-latest-x86_64      Result directory: (empty)
# COPR caps this script at 4 kB — keep it terse; rationale belongs in README.md.
#
# Local run, the same way COPR does it:  COPR_RESULTDIR=./out ./copr-custom-script.sh

set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-redhat-et/ripwire}"
# Empty SPEC_URL falls back to a ripwire.spec beside this script (local runs).
SPEC_URL="${SPEC_URL:-https://raw.githubusercontent.com/AlmanacOS/ripwire-rpm/main/ripwire.spec}"

resultdir="${COPR_RESULTDIR:-$PWD}"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
mkdir -p "$resultdir" "$workdir/SOURCES"

say() { printf '==> %s\n' "$*" >&2; }

# ---- newest release tag ----
# /releases/latest skips drafts and prereleases; fall back to the newest plain tag.
api="https://api.github.com/repos/${UPSTREAM_REPO}"
auth=()
[ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

tag="$(curl -fsSL "${auth[@]}" "${api}/releases/latest" | jq -r '.tag_name // empty')"
if [ -z "$tag" ]; then
    say "no published release; using the newest tag"
    tag="$(curl -fsSL "${auth[@]}" "${api}/tags" | jq -r '.[0].name // empty')"
fi
[ -n "$tag" ] || { echo "no release tag for ${UPSTREAM_REPO}" >&2; exit 1; }

version="${tag#v}"
say "upstream tag ${tag} -> version ${version}"
# Anything but a plain dotted version would make an invalid RPM Version.
case "$version" in
    *[!0-9.]*|''|.*|*.) echo "tag '${tag}' is not a plain x.y.z version" >&2; exit 1 ;;
esac

# ---- spec ----
spec="${workdir}/ripwire.spec"
if [ -n "$SPEC_URL" ]; then
    say "fetching spec from ${SPEC_URL}"
    curl -fsSL "$SPEC_URL" -o "$spec"
else
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    [ -f "${here}/ripwire.spec" ] || { echo "no SPEC_URL and no local spec" >&2; exit 1; }
    say "using ${here}/ripwire.spec"
    cp "${here}/ripwire.spec" "$spec"
fi

sed -i -e "s/^Version:.*/Version:        ${version}/" \
       -e "s/^Release:.*/Release:        1%{?dist}/" "$spec"
grep -q "^Version:        ${version}\$" "$spec" || { echo "Version: not set" >&2; exit 1; }

# ---- sources ----
tarball="${workdir}/SOURCES/ripwire-${version}.tar.gz"
url="https://github.com/${UPSTREAM_REPO}/archive/${tag}/ripwire-${version}.tar.gz"
say "downloading ${url}"
curl -fsSL "$url" -o "$tarball"

# Subshell so `set +o pipefail` stays local: head exits after one line, tar takes
# SIGPIPE, and under pipefail that 141 would trip set -e.
top="$(set +o pipefail; tar tzf "$tarball" | head -1 | cut -d/ -f1)"
if [ "$top" != "ripwire-${version}" ]; then
    say "repacking ${top}/ as ripwire-${version}/"
    tar xzf "$tarball" -C "$workdir"
    mv "${workdir}/${top}" "${workdir}/ripwire-${version}"
    tar czf "$tarball" -C "$workdir" "ripwire-${version}"
    rm -rf "${workdir:?}/ripwire-${version}"
fi

# ---- srpm ----
say "building srpm"
rpmbuild -bs "$spec" \
    --define "_topdir ${workdir}" \
    --define "_sourcedir ${workdir}/SOURCES" \
    --define "_srcrpmdir ${resultdir}" \
    --define "dist %{nil}"
