# Semantic search

A search overlay for the [Omarchy](https://omarchy.org) shell that finds
documents and pictures by what they say or show, not only by the words in
them. Ask for "what if a pipe bursts" and it finds the insurance policy that
says "water damage from plumbing".

Everything runs on your machine: [EmbeddingGemma 2](https://huggingface.co/google/embeddinggemma-2)
through [llama.cpp](https://github.com/ggml-org/llama.cpp), with the index in
SQLite. Nothing is sent anywhere.

![Semantic search overlay](preview.png)

## What it does

- **Documents**: PDF, Markdown, text, Org, reStructuredText, DOCX and ODT are
  split into passages and each passage is embedded. A hit is the passage that
  matched, not just the file.
- **Pictures**: PNG, JPEG, WebP, GIF, BMP and TIFF are embedded by content, so
  "screenshot of a terminal" finds one whatever it is called.
- **Names and paths**: folder and file names are searchable too.
- **Preview**: a PDF opens on the matching page with the passage and your
  words highlighted. Text shows the passage, pictures show themselves.
- **Why it matched**: each hit says whether it has your words, a matching
  name, a similar meaning, or (for pictures) looks like what you described.
- **Stays current**: indexed folders are watched with inotify, and compared
  against the index every time the daemon starts.

| Key | Action |
|---|---|
| <kbd>↑</kbd> <kbd>↓</kbd> <kbd>PgUp</kbd> <kbd>PgDn</kbd> | Move through the hits |
| <kbd>Enter</kbd> | Open |
| <kbd>Shift</kbd>+<kbd>Enter</kbd> | Show in the file manager |
| <kbd>Ctrl</kbd>+<kbd>C</kbd> | Copy the path |
| <kbd>Esc</kbd> | Clear the query, then close |

## Requirements

- Omarchy 4 (Quattro) on x86-64.
- `uv`, `poppler` (`pdftotext`, `pdftoppm`), `curl`, `systemd` user services.
  Omarchy ships all of them.
- About 1 GB of disk for the model and runtime, and a few MB per thousand
  passages for the index.
- A Vulkan GPU is used when there is one. The model is small enough for a CPU;
  set `gpu_layers = 0` to force that.

`wl-copy`, `xdg-open` and `gdbus` are used for the copy, open and reveal
actions.

## Install

```bash
omarchy plugin add https://github.com/depletionmode/omarchy-semsearch.git --enable
~/.config/omarchy/plugins/depmod.semsearch/install.sh
```

The plugin is two parts, and `omarchy plugin add` only installs the first:

1. The overlay, a QML file that runs inside the Omarchy shell.
2. `semsearchd`, a background daemon that does the indexing and searching.

`install.sh` sets up the daemon. Read it before running it. It does not use
root, and does exactly this:

- downloads a llama.cpp release build (`b11556`, Vulkan, x64) from GitHub and
  the EmbeddingGemma 2 `Q8_0` GGUF files from Hugging Face at a pinned
  revision, verifying each against a SHA-256 in the script, into
  `~/.local/share/semsearch/`;
- writes `~/.config/systemd/user/semsearch.service` and enables and starts it.

The daemon is a [`uv` script](https://docs.astral.sh/uv/guides/scripts/); on
first start `uv` installs its three Python dependencies (`numpy`,
`watchfiles`, `pillow`) into its own cache.

Then bind a key, for example in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + F4", "Semantic search", "omarchy-shell shell toggle depmod.semsearch '{}'")
```

The first index starts immediately and you can search while it runs; the
footer shows the progress. Expect roughly 10 to 20 passages or 4 to 5 pictures
a second on a mid-range GPU.

After `omarchy plugin update`, restart the daemon to pick up the new code:

```bash
systemctl --user restart semsearch
```

## Remove

```bash
~/.config/omarchy/plugins/depmod.semsearch/uninstall.sh --purge
omarchy plugin remove depmod.semsearch
```

`uninstall.sh` stops and removes the service. `--purge` also deletes the
index, the model and runtime (`~/.local/share/semsearch`) and the rendered
pages (`~/.cache/semsearch`). Your own `~/.config/semsearch/config.toml`, if
you made one, is left alone.

## Configuration

Optional, in `~/.config/semsearch/config.toml`. These are the defaults:

```toml
roots = ["~/Documents", "~/Downloads", "~/Desktop", "~/Pictures"]
exclude = ["node_modules", "__pycache__", "venv", "site-packages"]
extensions = ["pdf", "md", "txt", "org", "rst", "docx", "odt"]
image_extensions = ["png", "jpg", "jpeg", "webp", "gif", "bmp", "tif", "tiff"]
max_file_mb = 100
max_pages = 500            # of a PDF
gpu_layers = 99            # 0 runs the model on the CPU
idle_unload_seconds = 300  # 0 keeps the model loaded
min_similarity = 0.35
min_image_similarity = 0.29
```

Hidden files and folders are never indexed. Restart the daemon after a change:
`systemctl --user restart semsearch`.

## How it works

`semsearchd` splits each document into passages of about 180 words (PDFs page
by page), embeds them, and stores text and vectors in
`~/.local/share/semsearch/index.db`. A picture gets one vector.

A query is matched three ways and the three lists are merged by reciprocal
rank fusion:

- **Words**: SQLite FTS5 over the passages and file paths. Every term must be
  present; if nothing matches that and nothing matches by meaning either, any
  term will do.
- **Meaning**: cosine similarity between the query and each passage, after
  subtracting the corpus mean vector. EmbeddingGemma's vectors share a large
  common component, and without this step unrelated passages score nearly as
  high as relevant ones.
- **Looks**: the same against pictures, which share a vector space with text.

The model is loaded when a query or an indexing job needs it and unloaded
after five idle minutes, so nothing sits in GPU memory in between. Queries and
documents only need the text model (about 310 MB); the vision projector (about
555 MB) is loaded only while pictures are being indexed. Opening the overlay
starts loading the model, and until it is ready a search is answered with the
word matches alone.

The overlay talks to the daemon with JSON lines over
`$XDG_RUNTIME_DIR/semsearch.sock`, which is created readable only by you.
`semsearch` is a small command-line client for the same socket:

```bash
semsearch status
semsearch rescan
semsearch where is the boiler warranty
```

## Limits

- **Relevance cut-off.** An embedding always has a nearest neighbour, so the
  daemon has to decide when the nearest one is not a match. The thresholds
  (`min_similarity`, `min_image_similarity`) were tuned on one person's files
  and are a judgement call: too high hides weak but correct matches, too low
  shows unrelated ones. Picture matches are the less reliable of the two.
- Scanned PDFs without a text layer are not read (no OCR).
- HEIC, audio and video are not indexed.
- Opening a PDF does not jump to the matching page.
- A PDF passage never spans two pages.
- Only one llama.cpp build is offered: x86-64 with Vulkan.

## Privacy

The index holds the text of your documents in plain SQLite under
`~/.local/share/semsearch/`, and rendered pages under `~/.cache/semsearch/`.
Both stay on your disk with your user's permissions. The daemon makes no
network connections; `install.sh` is the only part that downloads anything.
llama.cpp listens on a random `127.0.0.1` port while the model is loaded.

## Development

```bash
uv run --with numpy --with watchfiles --with pillow --with pytest pytest tests/
journalctl --user -u semsearch -f
```

The overlay is `keepLoaded`, so after editing `SemSearch.qml` run
`omarchy restart shell`.

## License

MIT. EmbeddingGemma 2 is Apache 2.0 and llama.cpp is MIT; neither is
redistributed here, `install.sh` downloads them from their publishers.
