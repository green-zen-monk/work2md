# Releasing `work2md`

## Prerequisites

- Launchpad account with a registered PPA
- GPG key configured for Debian source uploads
- `devscripts`, `debhelper`, `dput`, `lintian`, `autopkgtest`, and `build-essential`

## GitHub distribution

- Pushes and pull requests trigger the GitHub Actions workflow at
  `.github/workflows/package.yml`.
- The workflow checks shell syntax, builds the `.deb`, runs `lintian`, then runs
  the autopkgtest smoke suite.
- Tagged pushes matching `v*` also publish the built `.deb`, `.changes`, and
  `.buildinfo` files to the matching GitHub Release.
- Before creating a tag, keep [`VERSION`](../VERSION) and `debian/changelog` in sync.

## Release flow

1. Update [`VERSION`](../VERSION) and `debian/changelog` for the new release.
2. Commit the release changes and push them to GitHub.
3. Create a matching Git tag such as `v0.1.0` and push the tag.
4. GitHub Actions will build the release artifacts automatically and attach them to the GitHub Release.
5. Build and validate locally when you need a pre-release check:

   ```bash
   dpkg-buildpackage -us -uc -b
   lintian ../work2md_<version>_all.deb
   autopkgtest . ../work2md_<version>_all.deb -- null
   ```

6. Upload each Ubuntu series separately if you also publish through Launchpad PPA:

   ```bash
   scripts/release-ppa.sh ppa:<launchpad-user>/<ppa-name> jammy
   scripts/release-ppa.sh ppa:<launchpad-user>/<ppa-name> noble
   ```

   The script creates a temporary source tree, rewrites the top changelog entry to
   the requested series, appends an Ubuntu-specific suffix such as `~jammy1`, then
   builds and uploads the matching source package.

7. After Launchpad finishes the build, verify the packages on Ubuntu 22.04 and 24.04.
