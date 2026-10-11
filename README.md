# Semantic search

A search overlay for the [Omarchy](https://omarchy.org) shell that finds
documents and pictures by what they say or show, not only by the words in
them. Everything runs locally: [EmbeddingGemma 2](https://huggingface.co/google/embeddinggemma-2)
through [llama.cpp](https://github.com/ggml-org/llama.cpp), index in SQLite.

![Semantic search overlay](preview.png)

## Install

Needs Omarchy 4 on x86-64 and about 1 GB of disk.

```bash
sudo pacman -S --needed uv poppler
omarchy plugin add https://github.com/depletionmode/omarchy-semsearch.git --enable
~/.config/omarchy/plugins/depmod.semsearch/install.sh
```

Then bind a key in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + F4", "Semantic search", "omarchy-shell shell toggle depmod.semsearch '{}'")
```

Indexing starts straight away and you can search while it runs.

`install.sh` needs no root. It downloads llama.cpp build `b11556` and the
EmbeddingGemma 2 `Q8_0` model (about 900 MB, each file checked against a
SHA-256 pinned in the script) into `~/.local/share/semsearch/`, then installs
and starts the `semsearch.service` user unit.

After `omarchy plugin update`, run `systemctl --user restart semsearch`.

## Remove

```bash
~/.config/omarchy/plugins/depmod.semsearch/uninstall.sh --purge
omarchy plugin remove depmod.semsearch
```

`--purge` also deletes the index, model and page cache
(`~/.local/share/semsearch`, `~/.cache/semsearch`).

## Use

| Key | Action |
|---|---|
| <kbd>↑</kbd> <kbd>↓</kbd> <kbd>PgUp</kbd> <kbd>PgDn</kbd> | Move through the hits |
| <kbd>Enter</kbd> | Open |
| <kbd>Shift</kbd>+<kbd>Enter</kbd> | Show in the file manager |
| <kbd>Ctrl</kbd>+<kbd>C</kbd> | Copy the path |
| <kbd>Esc</kbd> | Clear the query, then close |

Each hit says why it matched: it has your words, its name matches, it means
something similar, or (pictures) it looks like what you described. A PDF opens
in the preview on the matching page with the passage highlighted.

From a terminal: `semsearch status`, `semsearch rescan`, `semsearch <query>`
(in the plugin folder).

## What is indexed

By default `~/Documents`, `~/Downloads`, `~/Desktop` and `~/Pictures`:

- **Documents** (`pdf md txt org rst docx odt`), split into passages of about
  180 words.
- **Pictures** (`png jpg jpeg webp gif bmp tif tiff`), by what they show.
- **Paths**: folder and file names of the above.

Hidden files and folders are skipped, as are `node_modules`, `__pycache__`,
`venv` and `site-packages`, files over 100 MB and pictures under 64 px.
Folders are watched with inotify and re-checked whenever the daemon starts.

## Configuration

Optional, in `~/.config/semsearch/config.toml` (defaults shown). Restart the
daemon after a change.

```toml
roots = ["~/Documents", "~/Downloads", "~/Desktop", "~/Pictures"]
exclude = ["node_modules", "__pycache__", "venv", "site-packages"]
extensions = ["pdf", "md", "txt", "org", "rst", "docx", "odt"]
image_extensions = ["png", "jpg", "jpeg", "webp", "gif", "bmp", "tif", "tiff"]
max_file_mb = 100
max_pages = 500            # of a PDF
gpu_layers = 99            # 0 keeps the model off the GPU
idle_unload_seconds = 300  # 0 keeps the model loaded
min_similarity = 0.35
min_image_similarity = 0.29
```

## How it works

`semsearchd` embeds every passage and picture and stores text and vectors in
`~/.local/share/semsearch/index.db`. A query is ranked three ways and the
lists are fused: literal words (SQLite FTS5, no stemming), passage meaning and
picture content (cosine similarity after subtracting the corpus mean vector).

The model is loaded on demand and unloaded after five idle minutes. Searching
loads only the text model (310 MB); the vision projector (555 MB) is loaded
while pictures are being indexed. Until the model is ready a search is
answered with the word matches alone. The overlay talks to the daemon over
`$XDG_RUNTIME_DIR/semsearch.sock`.

The daemon is a [`uv` script](https://docs.astral.sh/uv/guides/scripts/); on
first start `uv` installs `numpy`, `watchfiles` and `pillow` into its cache.

## Limits

- **Relevance cut-off.** An embedding always has a nearest neighbour, so the
  daemon has to decide when the nearest one is not a match. The thresholds
  were tuned on one person's files: expect the odd unrelated hit, and the odd
  weak but correct match hidden. Picture matches are the less reliable half.
- No OCR for scanned PDFs. HEIC, audio and video are not indexed.
- Opening a PDF does not jump to the matching page.
- One llama.cpp build is offered: x86-64 with Vulkan.

## Privacy

The index holds the text of your documents in plain SQLite in your home
directory. The daemon makes no network connections beyond a llama.cpp server
on a random `127.0.0.1` port; only `install.sh` downloads anything.

## Development

```bash
uv run --with numpy --with watchfiles --with pillow --with pytest pytest tests/
journalctl --user -u semsearch -f
```

The overlay is `keepLoaded`: after editing `SemSearch.qml` run
`omarchy restart shell`.

## License

MIT. EmbeddingGemma 2 (Apache 2.0) and llama.cpp (MIT) are not redistributed
here; `install.sh` downloads them from their publishers.
