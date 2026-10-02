# ripwire — https://github.com/redhat-et/ripwire
#
# The Version: field below is REWRITTEN by copr-custom-script.sh, which resolves the
# newest upstream release tag at build time. The value checked in here is only the
# default used for a manual/local build.

# src/serialize.h and src/pageview.h pass a format string through a variadic template
# into snprintf. Every call site passes a literal, but GCC cannot see through the
# template and -Werror=format-security (from Fedora's %%optflags) makes it fatal.
# Upstream guards these with #pragma clang diagnostic, which GCC ignores.
%global optflags %{optflags} -Wno-error=format-security

Name:           ripwire
Version:        0.5.0
Release:        1%{?dist}
Summary:        Ranked, deterministic repository map for coding agents

# ripwire's own sources (src/, including src/infra/) are Apache-2.0 (LICENSE).
# Vendored, statically linked into the binary (see THIRD_PARTY.md):
#   MIT              - tree-sitter core + every grammar, doctest, unordered_dense, svector
#   Apache-2.0       - gtl (btree.hpp and its headers), tree-sitter-elixir (with MIT)
#   Zlib             - pdqsort
#   Unicode-DFS-2016 - the ICU subset in tree-sitter's lib/src/unicode/
License:        Apache-2.0 AND MIT AND Zlib AND Unicode-DFS-2016
URL:            https://github.com/redhat-et/ripwire
Source0:        %{url}/archive/v%{version}/%{name}-%{version}.tar.gz

# C++23. GCC 13 is the first release that compiles this tree.
BuildRequires:  gcc-c++ >= 13
BuildRequires:  cmake >= 3.24
BuildRequires:  ninja-build
BuildRequires:  make

# Nothing is downloaded during the build: third_party/deps/ holds the complete
# dependency set, and CMakeLists.txt hard-fails rather than falling back to a clone.
Provides:       bundled(doctest) = 2.4.12
Provides:       bundled(gtl)
Provides:       bundled(pdqsort)
Provides:       bundled(svector)
Provides:       bundled(tree-sitter) = 0.26.9
Provides:       bundled(unordered_dense)

%description
ripwire is a zero-dependency C++23 command line tool and MCP server that gives
coding agents a ranked, deterministic map of a repository: what a symbol is,
what depends on it, the blast radius of a change, the tests worth running, and
the quality delta a change introduces.

It parses with tree-sitter and reports signatures rather than bodies, which is
roughly 80% fewer bytes than the code itself and about 5% of the tokens a
grep-and-read pass would spend.

The package also ships the agent skills (%{_datadir}/%{name}/skills) and the
advisory hooks (%{_datadir}/%{name}/hooks) from the upstream tree.

%prep
%autosetup -n %{name}-%{version} -p1

%build
# RIPWIRE_NATIVE stays OFF: -march=native would bake the builder's CPU extensions
# into a binary that ships to other machines.
# RIPWIRE_TESTS stays OFF: upstream's verification gates are not built by any upstream
# workflow and have drifted from the API they test (at v0.5.0 test/verify_pagerank.cpp
# assigns pageRankDouble's PageRankRun result to an unsigned and fails to compile).
# A package that follows every release cannot depend on a gate upstream does not build.
# Fedora 44's %%cmake does not set CMAKE_BUILD_TYPE, and an unset build type is upstream's
# *dev* flavour: no NDEBUG, so asserts and the DEGRADED_PATH_ALERT diagnostics stay live in a
# binary users run. Upstream's own release installer builds Release; RelWithDebInfo is the
# same NDEBUG+LTO branch (CMakeLists.txt:111) and keeps the -g that debuginfo needs.
%cmake -G Ninja \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DRIPWIRE_NATIVE:BOOL=OFF \
    -DRIPWIRE_TESTS:BOOL=OFF
%cmake_build

%install
# --component ripwire scopes the install to this project's own rules; without it the
# vendored tree-sitter subproject also installs its headers, pkgconfig and static lib.
DESTDIR=%{buildroot} %__cmake --install "%{__cmake_builddir}" \
    --prefix "%{_prefix}" --component ripwire

# Ship the license text of every vendored dependency beside ripwire's own.
install -Dpm 0644 LICENSE %{buildroot}%{_defaultlicensedir}/%{name}/LICENSE
for dir in third_party/deps/*/; do
    dep=$(basename "$dir")
    for lic in "$dir"LICENSE "$dir"LICENSE.txt; do
        [ -f "$lic" ] || continue
        install -Dpm 0644 "$lic" \
            %{buildroot}%{_defaultlicensedir}/%{name}/bundled/${dep}-LICENSE
    done
    # Apache-2.0 asks for NOTICE files to travel with the code (tree-sitter-elixir has one).
    if [ -f "${dir}NOTICE" ]; then
        install -Dpm 0644 "${dir}NOTICE" \
            %{buildroot}%{_defaultlicensedir}/%{name}/bundled/${dep}-NOTICE
    fi
done
install -Dpm 0644 third_party/deps/tree_sitter/lib/src/unicode/LICENSE \
    %{buildroot}%{_defaultlicensedir}/%{name}/bundled/tree_sitter-unicode-LICENSE

%check
# Smoke-test the binary that was actually built, and assert it reports the version the
# spec claims — %%cmake_build is happy to produce something that cannot start.
"%{__cmake_builddir}/ripwire" --version
"%{__cmake_builddir}/ripwire" --version | grep -qw '%{version}'
"%{__cmake_builddir}/ripwire" --help >/dev/null

%files
%license %{_defaultlicensedir}/%{name}/LICENSE
%license %{_defaultlicensedir}/%{name}/bundled/
%doc README.md CHANGELOG.md THIRD_PARTY.md
%{_bindir}/%{name}
%dir %{_datadir}/%{name}
%{_datadir}/%{name}/skills
%{_datadir}/%{name}/hooks

%changelog
* Mon Sep 07 2026 Clem <clem@pendragon.systems> - 0.5.0-1
- Initial COPR package, tracking the newest upstream release tag automatically
