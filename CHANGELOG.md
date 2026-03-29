# Changelog

All notable project-level changes for `work2md` are documented in this file.

This changelog is used for GitHub Releases.
The Debian packaging history remains in `debian/changelog`.

## [Unreleased]

## [0.9.0] - 2026-03-29

### Added

- First official public release of `work2md`.
- Add `jira2md` and `confluence2md` for exporting Jira issues and Confluence Cloud pages to Markdown bundles with metadata, comments, and downloaded attachments.
- Add `work2md-config` for shared credential setup, validation, diagnostics, and token backend management.
- Add AI-friendly exports, YAML front matter, redaction and metadata filtering, batch input modes, and manifest-driven incremental exports.
- Add Debian packages, Linux portable `tar.gz` bundles, and Homebrew on Linux as supported distribution paths.

### Changed

- Publish `v0.9.0` as the first official tagged GitHub release for the project.
- Establish the `0.9.x` line as the first official pre-`1.0` release series for the project.
- Standardize the release flow so GitHub Release notes are sourced from this changelog.

### Fixed

- Improve Confluence export compatibility by falling back to alternate page and comment endpoints when storage content is unavailable from the primary API response.
