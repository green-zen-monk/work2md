# Changelog Templates

Use these templates as starting structures for this repository.

Adapt them to the actual release. Do not copy the placeholder bullets verbatim
unless they are true.
For Debian maintainer signatures, copy the real name and email from the current
`debian/changelog` entry or `debian/control`.

## Debian Entry Template

Use for `debian/changelog`.

```text
work2md (<version>-1) noble; urgency=medium

  * Short package-oriented summary.
  * Add or improve the main shipped capabilities in concise bullets.
  * Mention release-relevant fixes without GitHub-style section headers.
  * Keep bullets short and focused on what actually ships.

 -- <maintainer name> <maintainer@example.com>  <RFC-2822 date>
```

## Debian First Public Release Template

Use when the surviving top entry is the first real public release.

```text
work2md (<version>-1) noble; urgency=medium

  * First public pre-1.0 release.
  * Add the main user-visible commands and packaging outputs.
  * Summarize the most important workflow and export capabilities.
  * Mention the most important content-extraction or compatibility fixes.

 -- <maintainer name> <maintainer@example.com>  <RFC-2822 date>
```

## Project Changelog Release Template

Use for `CHANGELOG.md`.

```markdown
## [<version>] - <YYYY-MM-DD>

### Added

- Add the main new commands, export modes, or distribution artifacts.
- Add the most important new workflow capabilities.

### Changed

- Describe notable behavior or release-process changes.
- Mention whether this is the first public release if that matters.

### Fixed

- Summarize the highest-impact fixes in user-facing language.
```

## Project Changelog First Public Release Template

Use when the release should clearly read as the first public release line.

```markdown
## [<version>] - <YYYY-MM-DD>

### Added

- Initial public release of `work2md`.
- Add the main CLI commands and export bundle structure.
- Add packaging or release distribution paths that actually ship.

### Changed

- Establish the first public release line for the project.

### Fixed

- Include only real fixes that shipped in this release.
```

## Remove Never-Published Version Template

Use this process when a version section should disappear entirely.

1. Remove the full version section from `CHANGELOG.md`.
2. Remove the full top-level matching entry from `debian/changelog`.
3. Rewrite the new top surviving entry if it now becomes the first public
   release.
4. Search for the stale version string in both files and nearby release docs.
