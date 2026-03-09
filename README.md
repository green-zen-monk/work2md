# work2md

Independent CLI tools for exporting Jira issues and Confluence pages to Markdown.

This project is an independent third-party tool and is not affiliated with or endorsed by Atlassian.

## Install on Ubuntu

Download the latest `.deb` package from the GitHub Releases page, then install it:

```bash
sudo apt install ./work2md_<version>_all.deb
```

Installed commands:

- `jira2md`
- `confluence2md`

## Runtime dependencies

The Debian package installs the required runtime dependencies automatically:

- `bash`
- `curl`
- `jq`
- `python3`

## Usage

```bash
jira2md PROJ-123
confluence2md 123456789
confluence2md "https://company.atlassian.net/wiki/spaces/TEAM/pages/123456789/Page+Title"
```

Show help or version:

```bash
jira2md --help
confluence2md --help
jira2md --version
confluence2md --version
```

## Releases

- Pull requests and pushes to `main` run the packaging workflow.
- Git tags matching `v*` publish `.deb` release assets automatically through GitHub Actions.
- Launchpad PPA publishing is documented in [`docs/RELEASING.md`](docs/RELEASING.md).
