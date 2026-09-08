#!/bin/bash
# COPR "Custom" source-method script for ripwire.
#
# Paste this into the Script box of the ripwire package in
# https://copr.fedorainfracloud.org/coprs/clemperorpenguin/AlmanacOS/
#
# It resolves the newest upstream release tag at build time, so every rebuild
# (webhook-triggered or periodic) picks up the latest release with no edits here.
#
# COPR package settings that go with it:
#   Build dependencies: bash coreutils curl jq tar sed findutils rpm-build git-core
#   Result directory:   (leave empty)
#
# Run it locally the same way COPR does:
#   COPR_RESULTDIR=./out ./copr-custom-script.sh

set -euo pipefail

# Upstream project the release tag is read from.
UPSTREAM_REPO="${UPSTREAM_REPO:-redhat-et/ripwire}"

# Where ripwire.spec comes from. Point SPEC_URL at the raw spec in your packaging
# repo so spec edits take effect without re-pasting this script. If the variable is
# empty, the script falls back to a ripwire.spec sitting next to it (local runs).
SPEC_URL="${SPEC_URL:-https://raw.githubusercontent.com/AlmanacOS/ripwire-rpm/main/ripwire.spec}"

resultdir="${COPR_RESULTDIR:-$PWD}"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
mkdir -p "$resultdir"

say() { printf '==> %s\n' "$*" >&2; }

# ---- 1. newest release tag -------------------------------------------------
# /releases/latest skips drafts and prereleases. If the project has tags but no
# published release, fall back to the most recent tag.
api="https://api.github.com/repos/${UPSTREAM_REPO}"
auth=()
[ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

tag="$(curl -fsSL "${auth[@]}" "${api}/releases/latest" | jq -r '.tag_name // empty')"
if [ -z "$tag" ]; then
    say "no published release; falling back to the newest tag"
    tag="$(curl -fsSL "${auth[@]}" "${api}/tags" | jq -r '.[0].name // empty')"
fi
[ -n "$tag" ] || { echo "could not resolve a release tag for ${UPSTREAM_REPO}" >&2; exit 1; }

version="${tag#v}"
say "upstream tag ${tag} -> version ${version}"

# A tag that is not a plain dotted version would produce an invalid RPM Version.
case "$version" in
    *[!0-9.]*|''|.*|*.) echo "tag '${tag}' is not a plain x.y.z version" >&2; exit 1 ;;
esac

# ---- 2. spec ---------------------------------------------------------------
spec="${workdir}/ripwire.spec"
if [ -n "$SPEC_URL" ]; then
    say "fetching spec from ${SPEC_URL}"
    curl -fsSL "$SPEC_URL" -o "$spec"
else
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    [ -f "${here}/ripwire.spec" ] || {
        echo "SPEC_URL is unset and no ripwire.spec next to this script" >&2; exit 1; }
    say "using ${here}/ripwire.spec"
    cp "${here}/ripwire.spec" "$spec"
fi

# Pin the spec to the tag we just resolved, and reset Release for the new version.
sed -i -e "s/^Version:.*/Version:        ${version}/" \
       -e "s/^Release:.*/Release:        1%{?dist}/" "$spec"

grep -q "^Version:        ${version}\$" "$spec" || {
    echo "failed to set Version: in the spec" >&2; exit 1; }

# ---- 3. sources ------------------------------------------------------------
mkdir -p "${workdir}/SOURCES"
tarball="${workdir}/SOURCES/ripwire-${version}.tar.gz"
url="https://github.com/${UPSTREAM_REPO}/archive/${tag}/ripwire-${version}.tar.gz"
say "downloading ${url}"
curl -fsSL "$url" -o "$tarball"

# The archive's top directory is named after the tag, which carries the leading "v";
# %autosetup expects ripwire-<version>. Repack when they differ.
# Subshell so `set +o pipefail` stays local: head exits after one line, tar takes SIGPIPE,
# and under pipefail that 141 would otherwise trip set -e.
top="$(set +o pipefail; tar tzf "$tarball" | head -1 | cut -d/ -f1)"
if [ "$top" != "ripwire-${version}" ]; then
    say "repacking ${top}/ as ripwire-${version}/"
    tar xzf "$tarball" -C "$workdir"
    mv "${workdir}/${top}" "${workdir}/ripwire-${version}"
    tar czf "$tarball" -C "$workdir" "ripwire-${version}"
    rm -rf "${workdir:?}/ripwire-${version}"
fi

# ---- 4. srpm ---------------------------------------------------------------
say "building srpm"
rpmbuild -bs "$spec" \
    --define "_topdir ${workdir}" \
    --define "_sourcedir ${workdir}/SOURCES" \
    --define "_srcrpmdir ${resultdir}" \
    --define "dist %{nil}"

say "wrote:"
ls -l "$resultdir"/*.src.rpm >&2
