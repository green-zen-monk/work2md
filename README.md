# work2md

English | [Magyar](README.hu.md)

`work2md` is a CLI toolkit for exporting Jira issues and Confluence Cloud pages
to Markdown bundles that are practical for docs, backups, automation, and
AI-oriented workflows.

- `jira2md` exports Jira issues
- `confluence2md` exports Confluence Cloud pages
- `work2md-config` manages shared credentials and validation

The project is an independent third-party tool and is not affiliated with or
endorsed by Atlassian.

## Licensing notice

This repository is intentionally published without an open source license.
Except where applicable law permits otherwise, no rights are granted to use,
modify, or redistribute this code without explicit permission from the
copyright holder.

## Project status

The current release line is `0.9.x`. The tool is already useful for daily work,
but it is still a pre-`1.0` project, so CLI details and output conventions may
continue to evolve.

## Features

- Export content, metadata, comments, and downloaded attachments into a small
  bundle instead of a single file
- Accept Jira issue keys, Jira issue URLs, Confluence page IDs, and Confluence
  page URLs
- Share Jira and Confluence credentials through one config file
- Store tokens in the config file, a supported system keyring, or environment
  variables
- Emit a single artifact to stdout for pipes and automation
- Generate AI-friendly exports for LLM ingestion and RAG pipelines
- Add optional YAML front matter to `index.md`
- Redact emails, account IDs, internal URLs, or selected metadata fields
- Batch export through input files, Jira JQL, or Confluence CQL
- Reuse unchanged export bundles through manifest-driven `--incremental` mode
- Warn when configured API tokens are invalid, expired, or close to expiring

## Install

### Ubuntu or Debian

Download the latest `.deb` from GitHub Releases and install it with `apt`:

```bash
sudo apt install ./work2md_<version>_all.deb
```

Installed commands:

- `jira2md`
- `confluence2md`
- `work2md-config`

The package declares its runtime dependencies, so `apt` pulls them in
automatically.

### Homebrew on Linux

Tap the repository and install `work2md` with Homebrew:

```bash
brew tap green-zen-monk/work2md https://github.com/green-zen-monk/work2md
brew install work2md
```

Homebrew installs the same commands under the brew prefix:

- `jira2md`
- `confluence2md`
- `work2md-config`

The Homebrew formula tracks tagged GitHub releases. For an unreleased checkout,
use the Linux portable `tar.gz` path below instead.

### Linux portable tar.gz

Download the portable archive from GitHub Releases, unpack it, and place the
directory on your `PATH`:

```bash
tar -xzf work2md_<version>_portable.tar.gz
cd work2md-<version>
export PATH="$PWD:$PATH"
```

Portable runtime dependencies:

- `bash`
- `curl`
- `python3`

## Quick start

Initialize shared configuration:

```bash
work2md-config init
```

Or configure services one by one:

```bash
work2md-config jira init
work2md-config confluence init
```

Then export content:

```bash
jira2md PROJ-123
confluence2md 123456789
```

By default, exports are written under:

- `./docs/jira/<issue-key>/`
- `./docs/confluence/<page-id>-<slug>/`

## Configuration

Shared configuration is stored in:

```bash
~/.config/work2md/config
```

`work2md-config` keeps the parent directory private (`0700`) and the config
file itself private (`0600`). If an older file has looser permissions, the tool
tightens them automatically before reading or writing it.

Token backends:

- `config`: store the token in `~/.config/work2md/config`
- `keyring`: store the token in the Linux desktop keyring via `secret-tool`
- environment variables: override the stored token at runtime

Example:

```bash
work2md-config jira set base https://company.atlassian.net
work2md-config jira set email you@example.com
work2md-config jira set token-backend keyring
work2md-config jira set token <jira-api-token>

work2md-config confluence set base https://company.atlassian.net
work2md-config confluence set email you@example.com
work2md-config confluence set token-backend keyring
work2md-config confluence set token <confluence-api-token>
```

Environment override example:

```bash
export WORK2MD_JIRA_TOKEN='<jira-api-token>'
export WORK2MD_CONFLUENCE_TOKEN='<confluence-api-token>'
```

Useful config commands:

```bash
work2md-config path
work2md-config show
work2md-config validate
work2md-config doctor
```

`work2md-config validate` checks that the required fields exist and that a live
authenticated request succeeds. `work2md-config doctor` adds more detailed
diagnostics such as base URL sanity, token source, keyring availability, and
token expiry status.

### `work2md-config` command guide

Use `work2md-config` to manage the shared settings that both exporters read.

- `work2md-config init`: interactively initialize both Jira and Confluence in
  one run
- `work2md-config jira init`: initialize or refresh only the Jira settings
- `work2md-config confluence init`: initialize or refresh only the Confluence
  settings
- `work2md-config show`: print the current configuration with secrets masked
- `work2md-config validate`: verify required fields and perform a live
  authenticated API check
- `work2md-config doctor`: print a more detailed health report, including token
  source, keyring availability, and expiry warnings
- `work2md-config path`: print the config file path so scripts can discover it

The `set` subcommand updates one field at a time:

- `base`: Atlassian site base URL such as `https://company.atlassian.net`
- `email`: Atlassian account email used together with the API token
- `token`: API token value; stored in the configured backend
- `token-expiry`: optional expiry date for warnings and diagnostics; accepts
  `YYYY-MM-DD` or an ISO-8601 timestamp
- `token-backend`: where the token is stored; supported values are `config` and
  `keyring`

Examples:

```bash
work2md-config jira set base https://company.atlassian.net
work2md-config jira set token-expiry 2026-12-31
work2md-config confluence set token-backend keyring
work2md-config --log-format json validate
```

`--log-format text|json` is available on `work2md-config` so shell scripts and
CI jobs can parse diagnostics more easily.

The `keyring` backend currently targets Linux systems with
`libsecret-tools`/`secret-tool`. On systems without that provider, use the
`config` backend or environment variables.

## Authentication notes

`work2md` currently authenticates directly against site-local Atlassian URLs
such as:

- `https://company.atlassian.net/rest/api/...`
- `https://company.atlassian.net/wiki/rest/api/...`

That means the simplest supported setup is an Atlassian API token used together
with your Atlassian email address.

Create a token at:

- <https://id.atlassian.com/manage-profile/security/api-tokens>

The token does not grant extra access by itself. It can only read the Jira and
Confluence content that the underlying Atlassian account is already allowed to
view.

## Usage

Both exporters follow the same model:

- provide exactly one input source
- write a Markdown bundle by default
- or use `--stdout` to print a single generated artifact instead of writing
  files
- apply shaping options such as `--front-matter`, `--redact`, and
  `--drop-field` before the output is finalized

`--stdout` cannot be combined with `--output-dir`, and it is only supported for
single-item exports.

### Jira

Command forms:

```bash
jira2md ISSUE_KEY_OR_URL [options]
jira2md --input-file PATH [options]
jira2md --jql QUERY [options]
```

Accepted input:

- `PROJ-123`
- `https://company.atlassian.net/browse/PROJ-123`

Examples:

```bash
jira2md PROJ-123
jira2md PROJ-123 --output-dir ./export
jira2md PROJ-123 --stdout --emit metadata
jira2md PROJ-123 --front-matter
jira2md PROJ-123 --redact email,internal-url --drop-field reporter,url
jira2md PROJ-123 --ai-friendly
jira2md --input-file ./issues.txt --incremental
jira2md --jql 'project = DOCS ORDER BY updated DESC'
```

What the Jira-specific inputs are for:

- `ISSUE_KEY_OR_URL`: export one issue when you already know the key or have a
  browser URL
- `--input-file PATH`: export many issues from a text file; blank lines and
  comment lines are ignored
- `--jql QUERY`: ask Jira for a dynamic issue set, then export each result in
  sequence

### `jira2md` options

- `--output-dir PATH`: change the parent directory where bundles are written;
  the tool still creates a per-issue subdirectory under that path
- `--stdout`: print one generated document to standard output instead of
  writing `index.md`, `metadata.md`, and `comments.md`
- `--emit index|metadata|comments`: choose which generated document `--stdout`
  should print
- `--front-matter`: convert metadata into YAML front matter and prepend it to
  `index.md`
- `--redact RULES`: scrub sensitive value classes from the generated Markdown;
  useful before sharing or indexing exports
- `--drop-field FIELDS`: remove selected metadata keys from `metadata.md` and
  from generated front matter
- `--ai-friendly`: create an additional `-ai` bundle with a more linear content
  profile for LLM or RAG ingestion
- `--incremental`: reuse the existing bundle when the source content and export
  options have not changed
- `--log-format text|json`: format stderr logs for humans or machines
- `--version`: print the installed version

Typical `jira2md` workflows:

- documentation backup: `jira2md PROJ-123 --output-dir ./export`
- pipeline handoff: `jira2md PROJ-123 --stdout --emit index`
- publishing to static sites: `jira2md PROJ-123 --front-matter`
- privacy-aware exports: `jira2md PROJ-123 --redact email,internal-url`
- large recurring syncs: `jira2md --jql 'project = DOCS' --incremental`

### Confluence

Command forms:

```bash
confluence2md PAGE_ID_OR_URL [options]
confluence2md --input-file PATH [options]
confluence2md --cql QUERY [options]
```

Accepted input:

- `123456789`
- `https://company.atlassian.net/wiki/spaces/TEAM/pages/123456789/Page+Title`

Examples:

```bash
confluence2md 123456789
confluence2md 123456789 --output-dir ./export
confluence2md 123456789 --stdout --emit comments
confluence2md 123456789 --front-matter
confluence2md 123456789 --redact email,account-id --drop-field url
confluence2md 123456789 --ai-friendly
confluence2md --input-file ./pages.txt --incremental
confluence2md --cql 'type = page order by lastmodified desc'
```

What the Confluence-specific inputs are for:

- `PAGE_ID_OR_URL`: export one known page by numeric ID or page URL
- `--input-file PATH`: export many pages listed in a file
- `--cql QUERY`: let Confluence resolve a page list from search criteria, then
  export the matches

### `confluence2md` options

Most options behave the same way as in `jira2md`:

- `--output-dir PATH`: write bundles under a different base directory
- `--stdout`: print one generated artifact instead of writing files
- `--emit index|metadata|comments`: choose which artifact `--stdout` returns
- `--front-matter`: prepend YAML front matter to `index.md`
- `--redact RULES`: remove sensitive classes such as emails, account IDs, or
  internal URLs from generated Markdown
- `--drop-field FIELDS`: remove selected metadata keys before writing
  `metadata.md` and front matter
- `--ai-friendly`: create an additional `-ai` export directory
- `--incremental`: skip rewriting unchanged pages by consulting `manifest.json`
- `--log-format text|json`: select plain text or machine-readable logs
- `--version`: print the installed version

The main Confluence-specific difference is the batch query mode:

- `--cql QUERY` uses Confluence search syntax instead of Jira JQL
- page exports are written to `<page-id>-<slug>/` so repeated titles remain
  distinct

### Common redaction and metadata controls

`--redact` accepts a comma-separated list. Supported classes are:

- `email`: redact email addresses
- `account-id`: redact Atlassian account identifiers
- `internal-url`: redact URLs that point back to the configured Atlassian site

`--drop-field` also accepts a comma-separated list. Use it when the content
body should stay intact, but selected metadata entries should not be written
into `metadata.md` or front matter. Common examples include `url`,
`reporter`, `assignee`, and `updated_by`.

## Output layout

A normal export writes a bundle like this:

```text
docs/
  jira/
    PROJ-123/
      index.md
      metadata.md
      comments.md
      manifest.json
      assets/
  confluence/
    123456789-page-title/
      index.md
      metadata.md
      comments.md
      manifest.json
      assets/
```

- `index.md` contains the main body content
- `metadata.md` contains source-specific metadata
- `comments.md` contains exported comments
- `manifest.json` stores fingerprints and attachment metadata for incremental
  reuse

With `--stdout`, the supported `--emit` targets are:

- `index`
- `metadata`
- `comments`

## Front matter, redaction, and AI-friendly output

Use `--front-matter` to prepend YAML front matter to `index.md` for static-site
pipelines.

Use `--redact` with one or more comma-separated rules:

- `email`
- `account-id`
- `internal-url`

Use `--drop-field` to remove specific metadata keys before writing
`metadata.md` and generated front matter.

`--ai-friendly` writes a second export directory with a `-ai` suffix and a
more linear content profile that is easier to consume in LLM workflows.

Examples:

```bash
jira2md PROJ-123 --front-matter --redact email,internal-url --drop-field reporter,url
confluence2md 123456789 --front-matter --redact account-id --drop-field url,updated_by
```

## Batch and incremental exports

Both exporters accept exactly one input source at a time:

- a single Jira issue or Confluence page
- `--input-file`
- Jira `--jql`
- Confluence `--cql`

`--incremental` writes and consults `manifest.json`. If the source content and
export options have not changed, the existing bundle is kept in place and its
attachments can be reused.

## Notes

- The CLIs refuse to run as `root`
- Confluence exports target Confluence Cloud
- Legacy config files under `~/.config/jira2md/` and
  `~/.config/confluence2md/` are still read if present

## Releases

- Pushes and pull requests to `main` run the packaging workflow
- Pushes to `main` refresh a rolling `edge` GitHub prerelease built from the latest commit
- `edge` asset filenames include the release-line version plus the source commit hash
- Git tags matching `v*` publish stable `.deb` and portable `.tar.gz` assets
- Release and PPA steps are documented in [`docs/RELEASING.md`](docs/RELEASING.md)
