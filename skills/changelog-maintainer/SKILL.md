---
name: changelog-maintainer
description: Maintain `/debian/changelog` and `/CHANGELOG.md` together for this repository. Use when preparing a release, bumping or correcting a version, rewriting release notes, removing a never-published version, or reconciling mismatched Debian and project changelog history.
---

# Changelog Maintainer

## Overview

Keep the Debian package changelog and the project changelog aligned without
inventing release history. Update both files in one pass and preserve the
difference in purpose between package metadata and user-facing release notes.

## Workflow

1. Read `debian/changelog` and `CHANGELOG.md` before editing anything.
2. Identify the intended change:
   release a new version, revise the latest entry, or remove an unreleased
   historical version that should not exist.
3. Resolve the source of truth for version, date, and maintainer identity
   before drafting.
4. If you need drafting help, read
   `references/changelog-templates.md` and adapt the relevant template instead
   of writing from scratch.
5. Update both files in lockstep.
6. Verify that the top Debian entry and the top project release entry describe
   the same release.
7. Run a quick consistency check after editing.

## File Roles

Treat the two changelogs as related but not identical:

- `debian/changelog`
  Keep it package-oriented and suitable for Debian tooling.
- `CHANGELOG.md`
  Keep it release-note oriented and readable on GitHub.

Do not force identical wording. Keep the scope aligned while adapting the style
to each file.

## Release Sources

Before editing, resolve the release facts from repository sources:

- version
  Prefer the current top release entry being edited. If other files disagree,
  reconcile them instead of choosing a value ad hoc.
- date
  Use the release date being published in `CHANGELOG.md` and the matching RFC
  2822 timestamp in `debian/changelog`.
- maintainer identity
  Copy it from the current `debian/changelog` entry or `debian/control`.

If repository files disagree on the intended version, treat that as a
consistency issue to fix across the release artifacts.

## Debian Rules

When editing `debian/changelog`:

- Keep the newest entry first.
- Use the standard header format:
  `work2md (<version>-1) noble; urgency=medium`
  unless the user explicitly asks for another Debian revision or target series.
- Preserve the existing maintainer identity on the signature line and update
  only the timestamp when needed.
- When creating a new top entry, copy the maintainer name and email from the
  current `debian/changelog` entry or `debian/control`. Do not invent a new
  signature from model context, local git config, or placeholder text.
- Use concise bullet points focused on shipped package changes.
- Use an RFC 2822 style timestamp on the signature line.
- If a version never shipped, remove its whole entry instead of preserving fake
  history.

## Project Changelog Rules

When editing `CHANGELOG.md`:

- Keep `## [Unreleased]` at the top.
- Put released versions below it in reverse chronological order.
- Use section headers such as `### Added`, `### Changed`, and `### Fixed` when
  they help readability.
- Write from the user or project perspective, not Debian packaging perspective.
- Do not keep placeholder release sections for versions that were never
  published.
- If the release is the first public release, say that explicitly instead of
  implying older public versions existed.

When handling `## [Unreleased]`:

- Fold relevant unreleased bullets into the new versioned section when cutting a
  release.
- Keep `## [Unreleased]` present after the release, even if it becomes empty.
- Do not duplicate the same note in both `Unreleased` and the new released
  section.

## Synchronization Rules

Always keep these aligned across both files:

- release version
- release date
- overall release scope
- whether the release is public, unpublished, corrected, or removed

It is acceptable for bullet wording and grouping to differ between the files.

## Content Sourcing

Base release notes on one or more of these:

- the user's explicit instructions
- the current diff
- nearby documentation changes
- the existing unreleased notes

Do not invent features or claim something shipped unless the repository or the
user clearly supports it.

Every release bullet should be traceable to repo evidence such as a diff,
existing notes, nearby docs, package metadata, or explicit user instruction. If
the support is weak, omit the claim or phrase it more conservatively.

## Style Rules

Prefer short, concrete bullets that describe shipped outcomes.

- Start bullets with a strong verb such as `Add`, `Improve`, `Fix`, `Correct`,
  or `Remove` when that keeps the wording clear.
- Keep Debian bullets package-oriented and avoid GitHub-style subsection names
  inside `debian/changelog`.
- Keep `CHANGELOG.md` user-facing and avoid repeating the exact same bullet
  under multiple section headers.
- Prefer a small number of high-signal bullets over exhaustive commit-by-commit
  narration.

## Templates

When you need a concrete starting point for new text, read
`references/changelog-templates.md`.

Use the templates as structure, not as boilerplate to paste unchanged. Always
rewrite them to match the actual release scope and repository state.

## Common Cases

### Prepare a new release

Create or update the top Debian entry and the matching `CHANGELOG.md` section.
If `CHANGELOG.md` already has an `Unreleased` section with relevant notes, fold
them into the new versioned entry instead of duplicating them.

### Correct a version

If the repo should use `0.9.0` instead of `1.0.0`, update both changelogs so
the release story stays coherent. Remove or rewrite contradictory history.

### Decide whether it is the first public release

Treat the surviving top release as the first public release only when the older
entries were never actually published or were placeholder history that should
not remain.

If a real public release already shipped, do not relabel a later correction as
the first public release. Instead, fix the specific bad version or stale notes
while preserving the existence of the earlier release.

### Remove a never-published version

Delete the bogus release section from `CHANGELOG.md` and the whole matching
Debian entry from `debian/changelog`. Rewrite the surviving top entry so it
clearly reads as the first real public release if that is the case.

## Quick Checks

After editing:

- search for stale version strings that should no longer exist
- run `dpkg-parsechangelog -S Version` if `debian/changelog` changed
- verify that `## [Unreleased]` still exists and does not duplicate the new
  release notes
- verify Debian timestamp format and maintainer identity on the signature line
- check nearby release metadata files if the repo keeps the version elsewhere
- skim the top section of both files together to ensure they tell the same
  story
