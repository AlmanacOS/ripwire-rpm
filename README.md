# ripwire COPR packaging

RPM packaging for [redhat-et/ripwire](https://github.com/redhat-et/ripwire), built in
[copr.fedorainfracloud.org/coprs/clemperorpenguin/AlmanacOS](https://copr.fedorainfracloud.org/coprs/clemperorpenguin/AlmanacOS/).

The package is built **from source** and always tracks the **newest upstream release tag**:
`copr-custom-script.sh` asks the GitHub API for the latest release, downloads that tarball,
rewrites `Version:` in `ripwire.spec`, and hands COPR the resulting SRPM. No version number
is ever edited by hand.

| File | Role |
| --- | --- |
| `ripwire.spec` | The spec. Single source of truth; its `Version:` is a placeholder. |
| `copr-custom-script.sh` | COPR *custom* source-method script — resolves the tag, builds the SRPM. |
| `.github/workflows/copr-rebuild.yml` | Daily check that fires a COPR rebuild when upstream releases. |
| `copr-cli-podman.sh` | Runs `copr-cli` in a container, for hosts without it (Silverblue/Kinoite). |

ripwire vendors every dependency (tree-sitter core + 22 grammars, doctest, and four
header-only libraries) under `third_party/`, and `CMakeLists.txt` hard-fails rather than
falling back to a network clone — so the build is fully offline, as COPR requires.

## One-time COPR setup

```sh
dnf install copr-cli          # then: copr-cli whoami   (login token from the COPR web UI)
```

On an image-based host (Silverblue/Kinoite), use the bundled wrapper instead — it runs
`copr-cli` in a container and takes the same arguments:

```sh
./copr-cli-podman.sh whoami
```

Either way `copr-cli` needs an API token at `~/.config/copr`, from
https://copr.fedorainfracloud.org/api/ . Keep it mode 0600.

The `AlmanacOS` project already carries a `ripwire` package, currently set to the **SCM**
source method pointing at `redhat-et/ripwire` with `rpkg` — that configuration cannot
succeed, because upstream ships no spec file, and it has no successful builds. Switch it to
the custom method:

```sh
copr-cli edit-package-custom AlmanacOS \
    --name ripwire \
    --script copr-custom-script.sh \
    --script-chroot fedora-latest-x86_64 \
    --script-builddeps "bash coreutils curl jq tar sed findutils rpm-build git-core" \
    --webhook-rebuild on
```

(Use `add-package-custom` with the same arguments if the package is ever removed.)

Make sure the project's chroots cover the targets — Fedora 43, 44 and rawhide on x86_64 and
aarch64. C++23 needs GCC 13+, which all three have:

```sh
copr-cli modify AlmanacOS \
    --chroot fedora-43-x86_64  --chroot fedora-43-aarch64 \
    --chroot fedora-44-x86_64  --chroot fedora-44-aarch64 \
    --chroot fedora-rawhide-x86_64 --chroot fedora-rawhide-aarch64
```

`copr-custom-script.sh` fetches `ripwire.spec` from this repository's `main` branch, so spec
changes take effect on the next rebuild without re-pasting the script into COPR. Override with
the `SPEC_URL` variable at the top of the script if the packaging repo ever moves; setting it
empty makes the script fall back to a `ripwire.spec` sitting beside it, which is what local
runs use.

## Building

```sh
copr-cli build-package AlmanacOS --name ripwire     # builds whatever the latest tag is now
```

Consumers install with:

```sh
dnf copr enable clemperorpenguin/AlmanacOS
dnf install ripwire
```

## Keeping up with releases automatically

COPR does not poll upstream on its own — something has to pull the trigger. Pick one:

1. **Scheduled GitHub Action (included).** `.github/workflows/copr-rebuild.yml` compares the
   newest upstream tag against the version COPR last built and POSTs the package's rebuild
   webhook only when they differ. Copy the webhook URL from the COPR package's *Webhooks*
   settings into the `COPR_WEBHOOK_URL` repository secret. Works without any access to
   `redhat-et/ripwire`.

2. **Upstream webhook.** If you get admin on `redhat-et/ripwire`, add the same COPR webhook
   URL there and builds start the moment a release is published. Fastest, but needs rights
   on a repository you may not own.

3. **Local timer.** A systemd user timer running
   `copr-cli build-package AlmanacOS --name ripwire` on a schedule. Simplest, but only fires
   when your machine is up.

## Local verification

No rpmbuild on an image-based host, so do it in a container:

```sh
podman run --rm -v "$PWD":/pkg:ro,Z registry.fedoraproject.org/fedora:44 bash -c '
  dnf -y install rpm-build cmake gcc-c++ ninja-build jq curl tar git-core &&
  mkdir -p /work /out && cp /pkg/ripwire.spec /pkg/copr-custom-script.sh /work/ && cd /work &&
  COPR_RESULTDIR=/out ./copr-custom-script.sh &&
  rpmbuild --rebuild /out/*.src.rpm'
```

## Packaging notes

- **License.** `Apache-2.0 AND MIT AND Zlib` — ripwire is Apache-2.0; the vendored code adds
  MIT (tree-sitter and its grammars, doctest, unordered_dense, svector), Apache-2.0 (gtl) and
  Zlib (pdqsort). Every bundled `LICENSE` is installed under
  `/usr/share/licenses/ripwire/bundled/`, and the corresponding `bundled(...)` virtual Provides are
  declared.
- **`--component ripwire` on install.** Without it, `cmake --install` also runs the vendored
  tree-sitter subproject's install rules and drops its headers, pkgconfig file and static
  library into the buildroot.
- **`RIPWIRE_NATIVE=OFF`.** Upstream's `install.sh` sets it ON, which bakes the builder's CPU
  extensions into the binary — wrong for anything that ships. The spec keeps the default.
- **Not the upstream binary tarballs.** The release assets are built elsewhere; building from
  source gets real debuginfo, correct per-arch packages, and Fedora's hardening flags.
- **`-Wno-error=format-security`.** `src/serialize.h` and `src/pageview.h` pass a format
  string through a variadic template into `snprintf`. Every call site passes a literal, but
  GCC cannot see through the template, and Fedora's `%optflags` make that warning fatal.
  Upstream suppresses it with `#pragma clang diagnostic`, which GCC ignores.
- **`RIPWIRE_TESTS=OFF`.** Upstream's verification gates are not built by any upstream
  workflow and have drifted from the API they test — at v0.5.0, `test/verify_pagerank.cpp`
  assigns `pageRankDouble`'s `PageRankRun` result to an `unsigned` and does not compile. A
  package that follows every release cannot depend on a gate upstream does not build.
  `%check` smoke-tests the built binary instead and asserts it reports the expected version.
- **`CMAKE_BUILD_TYPE=RelWithDebInfo`.** Fedora 44's `%cmake` leaves the build type unset,
  which is upstream's *dev* flavour: no `NDEBUG`, so asserts and `DEGRADED_PATH_ALERT` stay
  live in a binary users run. `RelWithDebInfo` is the same NDEBUG+LTO branch upstream's own
  release installer takes, and keeps the `-g` that the debuginfo subpackage needs.
- **EPEL 10 is in the chroot set.** Its GCC 14 is untested against this C++23 tree, so that
  chroot may fail while the Fedora ones succeed. The project's other packages already build
  there, which is why the chroot list is the union rather than Fedora-only.
- **The COPR script field is capped at 4 kB.** `copr-custom-script.sh` is written to stay
  under it; put rationale in this file rather than in the script's comments.
- **Version stamp.** There is no git metadata in a release tarball, so `--version` reports its
  git stamp as `unknown`. The version string itself comes from `CMakeLists.txt`, so it stays
  correct.
