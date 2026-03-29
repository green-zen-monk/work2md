# Releasing `work2md`

## Prerequisites

- `autopkgtest`, `build-essential`, `debhelper`, `devscripts`, `dpkg-dev`,
  `fakeroot`, `lintian`, and `python3`

## Additional prerequisites for Launchpad PPA uploads

- Launchpad account with a registered PPA
- GPG key configured for Debian source uploads
- `dput`

## GitHub distribution

- Pushes and pull requests trigger the GitHub Actions workflow at
  `.github/workflows/package.yml`.
- The workflow verifies that [`VERSION`](../VERSION) matches the upstream
  version in `debian/changelog`, checks shell and Python syntax, builds the
  `.deb`, runs `lintian`, then runs the autopkgtest suite.
- The workflow also builds a portable `tar.gz` bundle, smoke-tests the unpacked
  CLI entrypoints, and writes release checksums for both artifact types.
- The supported install paths are Ubuntu/Debian packages, a Linux portable
  `tar.gz` bundle, and Homebrew on Linux via [`Formula/work2md.rb`](../Formula/work2md.rb).
- Pushes to `main` also refresh a rolling GitHub prerelease tagged `edge`.
  The `edge` release reuses the latest `main` commit, marks the GitHub Release
  as a prerelease, and publishes installable assets whose filenames include the
  release-line version plus the source commit hash for traceability.
- Tagged pushes matching `v*` also publish the built `.deb`, `.changes`,
  `.buildinfo`, portable `.tar.gz`, and `.sha256` files to the matching GitHub
  Release.
- GitHub Release notes are sourced from the matching section in
  [`CHANGELOG.md`](../CHANGELOG.md).
- Before creating a tag, keep [`VERSION`](../VERSION), `debian/changelog`, and
  the matching [`CHANGELOG.md`](../CHANGELOG.md) and
  [`Formula/work2md.rb`](../Formula/work2md.rb) entries in sync.

## Release flow

### Rolling `edge` prerelease from `main`

- Push the desired commit to `main`.
- GitHub Actions rebuilds the package set, force-updates the moving `edge` tag,
  and refreshes the `work2md edge` prerelease with the latest installable
  assets.
- Use this channel for "latest from main" testing; keep stable install guidance
  pointed at tagged releases.

### Stable tagged release

1. Update [`VERSION`](../VERSION), `debian/changelog`, and [`CHANGELOG.md`](../CHANGELOG.md) for the new release.
2. Rebuild the portable bundle locally and update [`Formula/work2md.rb`](../Formula/work2md.rb) with the matching release URL, version, and SHA-256.
3. Commit the release changes and push them to GitHub.
4. Create a matching Git tag such as `v0.9.0` and push the tag.
5. GitHub Actions will build the release artifacts automatically and attach them
   to the GitHub Release.
6. Build and validate locally when you need a pre-release check:

   ```bash
   version="$(dpkg-parsechangelog -S Version)"
   upstream_version="${version%%-*}"
   bundle_dir="$(mktemp -d)"
   trap 'rm -rf "$bundle_dir"' EXIT
   dpkg-buildpackage -us -uc -b
   lintian --fail-on error \
     "../work2md_${version}_all.deb" \
     "../work2md_${version}_amd64.buildinfo" \
     "../work2md_${version}_amd64.changes"
   sudo autopkgtest . "../work2md_${version}_all.deb" -- null
   scripts/build-portable-release.sh --output-dir dist
   tar -xzf "dist/work2md_${upstream_version}_portable.tar.gz" -C "$bundle_dir"
   "$bundle_dir/work2md-${upstream_version}/jira2md" --version
   "$bundle_dir/work2md-${upstream_version}/confluence2md" --version
   "$bundle_dir/work2md-${upstream_version}/work2md-config" --version
   ```
7. Upload each Ubuntu series separately if you also publish through Launchpad
   PPA. Run the script from the exact tagged release commit with a clean
   working tree; it copies the current repository contents into a temporary
   source tree and expects `HEAD` to match `v<upstream-version>` such as
   `v0.9.0`:

   ```bash
   scripts/release-ppa.sh ppa:<launchpad-user>/<ppa-name> jammy
   scripts/release-ppa.sh ppa:<launchpad-user>/<ppa-name> noble
   ```

   The script creates a temporary source tree, rewrites the top changelog entry to
   the requested series, appends an Ubuntu-specific suffix such as `~jammy1`, then
   builds and uploads the matching source package.

8. After Launchpad finishes the build, verify the packages on Ubuntu 22.04 and 24.04.
