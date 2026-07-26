# The Escapement website

The site published at <https://granroth.com/escapement>. Built with
[Zola](https://www.getzola.org) — a single binary, no dependency tree.

```sh
brew install zola

zola serve    # http://127.0.0.1:1111, live reload
zola build    # writes public/
```

## Layout

```
web/
├── config.toml         site metadata, and the version shown on the download page
├── content/            the words — plain Markdown
│   ├── _index.md       home: copy lives in front matter, prose in the body
│   ├── docs.md
│   ├── faq.md
│   └── download.md
├── templates/          the presentation
│   ├── base.html       head, nav, footer
│   ├── index.html      home layout
│   ├── page.html       docs and FAQ
│   ├── download.html   download card, then prose
│   ├── macros.html     inline icons
│   └── shortcodes/     note, table, figure
├── static/             CSS, theme toggle, images — copied verbatim
└── public/             build output, not committed
```

Content and presentation are separate on purpose: everyday edits are Markdown in
`content/` and never touch HTML. The home page is the exception — its headline,
feature cards, and example schedules are front-matter fields in `_index.md`, so
the copy is still editable without opening a template.

Markdown extras, used sparingly:

- `{% note(title="…") %}` — a callout. Add `plain=true` for the quieter variant.
- `{% table() %}` — wraps a Markdown table so it scrolls on narrow screens
  instead of overflowing.
- `{{ figure(src="…", alt="…") }}` — a framed screenshot. `wide=true` fills the
  column.

## Deploying

There is no auto-deploy. Build, then copy `public/` to the document root:

```sh
zola build
rsync -av --delete public/ user@host:/var/www/granroth.com/escapement/
```

`--delete` removes files that no longer exist here, which keeps stale assets
from accumulating. Drop it if that directory holds anything not produced by this
build.

URLs are absolute and derived from `base_url` in `config.toml`. If the site ever
moves to a different path or host, change it there and rebuild — the built
output is tied to it. `zola serve` substitutes localhost automatically, so
previews work regardless.

## Maintenance

- **After tagging a release**, update `version` in `config.toml`. The download
  button points at `/releases/latest` and never goes stale on its own.
- **After a UI change**, retake the screenshots in `static/`; see the capture
  notes in `AGENTS.md`.
- **Facts on these pages are load-bearing.** The claims about privileges,
  networking, and what Escapement refuses to touch are the reason someone trusts
  it with their backups. If behaviour changes, these pages change with it. The
  known-limitations list also appears in the root `README.md`; change both
  together.
