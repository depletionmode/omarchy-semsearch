# Run with: uv run --with numpy --with watchfiles --with pillow --with pytest pytest tests/
import importlib.util
import sqlite3
import subprocess
import time
from importlib.machinery import SourceFileLoader
from pathlib import Path

import numpy as np

path = str(Path(__file__).parent.parent / "semsearchd")
loader = SourceFileLoader("semsearchd", path)
spec = importlib.util.spec_from_loader("semsearchd", loader)
sd = importlib.util.module_from_spec(spec)
loader.exec_module(sd)


def test_windows_cover_every_word_and_overlap():
    spans = sd.windows(400, size=180, overlap=30)
    assert spans[0] == (0, 180)
    assert spans[-1][1] == 400
    for (a0, a1), (b0, b1) in zip(spans, spans[1:]):
        assert b0 == a1 - 30


def test_windows_short_and_empty():
    assert sd.windows(0) == []
    assert sd.windows(12) == [(0, 12)]
    # A tail that the previous window already covers is not its own passage.
    assert sd.windows(190, size=180, overlap=30) == [(0, 190)]


def test_query_terms_drop_stopwords():
    assert sd.query_terms("where they talk about water damage") == ["talk", "water", "damage"]
    assert sd.query_terms("the of and") == []


def test_snippet_centres_on_match_and_escapes():
    text = "filler " * 60 + "water damage from <plumbing> & pipes " + "filler " * 60
    html = sd.snippet(text, ["water", "plumbing"], width=80)
    assert "<b>water</b>" in html
    assert "&lt;<b>plumbing</b>&gt;" in html
    assert "&amp;" in html
    assert html.startswith("…") and html.endswith("…")


def test_snippet_without_terms_is_the_start():
    assert sd.snippet("alpha beta gamma", [], width=80) == "alpha beta gamma"


def test_parse_bbox_pages_and_words():
    xhtml = """<doc>
  <page width="100.0" height="200.0">
    <word xMin="10.0" yMin="20.0" xMax="30.0" yMax="28.0">Tom &amp; Jerry</word>
    <word xMin="32.0" yMin="20.0" xMax="50.0" yMax="28.0">ran</word>
  </page>
  <page width="100.0" height="200.0">
  </page>
</doc>"""
    pages = sd.parse_bbox(xhtml)
    assert len(pages) == 2
    assert pages[0]["size"] == (100.0, 200.0)
    assert pages[0]["words"][0] == ("Tom & Jerry", 10.0, 20.0, 30.0, 28.0)
    assert pages[1]["words"] == []


def test_line_rects_merge_words_on_one_line():
    words = [("a", 10, 20, 30, 28), ("b", 32, 20, 50, 28), ("c", 10, 40, 20, 48)]
    rects = sd.line_rects(words, (100.0, 200.0))
    assert len(rects) == 2
    x, y, w, h = rects[0]
    assert (round(x, 2), round(y, 2), round(w, 2), round(h, 2)) == (0.1, 0.1, 0.4, 0.04)


class FakeEmbedder:
    """Maps each text onto fixed axes so ranking is predictable."""

    AXES = ["pipe", "tax", "bread", "sunset"]

    def embed(self, texts):
        out = []
        for t in texts:
            # Every picture is "a sunset".
            t = t.lower() if isinstance(t, str) else "sunset"
            v = [1.0 if a in t else 0.0 for a in self.AXES] + [0.05]
            out.append(v)
        m = np.array(out, dtype=np.float32)
        return m / np.linalg.norm(m, axis=1, keepdims=True)


def make_index(tmp_path):
    index = sd.Index(sqlite3.connect(":memory:", check_same_thread=False), FakeEmbedder())
    docs = {
        "insurance.txt": "water damage from a burst pipe is covered wherever you are",
        "return.txt": "the advance tax payment is due each quarter",
        "sourdough.txt": "bake the bread with steam",
    }
    for name, body in docs.items():
        f = tmp_path / name
        f.write_text(body)
        index.index_file(str(f))
    return index


def test_search_ranks_by_meaning_and_labels_reason(tmp_path):
    index = make_index(tmp_path)
    hits = index.search("pipe")
    assert hits[0]["name"] == "insurance.txt"
    assert hits[0]["why"] == "words"
    assert "<b>pipe</b>" in hits[0]["snippet"]

    # No shared word with the document: only the embedding can find it.
    hits = index.search("TAX")
    assert hits[0]["name"] == "return.txt"


def test_words_alone_need_no_model(tmp_path):
    index = make_index(tmp_path)
    index.embedder = None  # any embed() call would raise
    hits = index.search("burst pipe", semantic=False)
    assert [h["name"] for h in hits] == ["insurance.txt"]


def test_any_term_matches_only_when_nothing_else_does(tmp_path):
    index = make_index(tmp_path)
    # "steam" and "quarter" never share a passage, and mean nothing to the model.
    names = {h["name"] for h in index.search("steam quarter")}
    assert names == {"sourdough.txt", "return.txt"}

    # "steam" is in the bread recipe, but the tax document is what is meant.
    assert [h["name"] for h in index.search("steam tax")] == ["return.txt"]


def test_prefix_only_when_the_word_itself_is_absent(tmp_path):
    index = make_index(tmp_path)
    (tmp_path / "breadth.txt").write_text("breadth first traversal")
    index.index_file(str(tmp_path / "breadth.txt"))
    assert [h["name"] for h in index.search("bread", semantic=False)] == ["sourdough.txt"]
    assert [h["name"] for h in index.search("travers", semantic=False)] == ["breadth.txt"]


def test_a_longer_word_is_not_a_word_match(tmp_path):
    index = make_index(tmp_path)
    (tmp_path / "bank.txt").write_text("your account number and account name")
    index.index_file(str(tmp_path / "bank.txt"))
    assert index.search("accountant", semantic=False) == []
    assert "<b>" not in sd.snippet("your account number", ["accountant"])

    # The other way round is a word being typed, and does match.
    hit = index.search("accou", semantic=False)[0]
    assert (hit["name"], hit["why"]) == ("bank.txt", "words")


def test_word_index_is_rebuilt_when_its_tokenizer_changes(tmp_path):
    index = make_index(tmp_path)
    with index.db:
        index.db.execute("DROP TABLE fts")
        index.db.execute("CREATE VIRTUAL TABLE fts USING fts5(title, body, tokenize='porter unicode61')")
        index.db.execute("UPDATE meta SET value='old' WHERE key='fts'")
    rebuilt = sd.Index(index.db, FakeEmbedder())
    assert [h["name"] for h in rebuilt.search("burst pipe", semantic=False)] == ["insurance.txt"]
    assert [h["name"] for h in rebuilt.search("insurance", semantic=False)] == ["insurance.txt"]


def test_unrelated_query_finds_nothing(tmp_path):
    index = make_index(tmp_path)
    assert index.search("zeppelin") == []


def test_similarity_is_measured_from_the_corpus_mean(tmp_path):
    """Vectors that all share one large component still separate."""

    class Anisotropic(FakeEmbedder):
        def embed(self, texts):
            m = super().embed(texts) + np.array([0, 0, 0, 0, 3.0], dtype=np.float32)
            return m / np.linalg.norm(m, axis=1, keepdims=True)

    index = sd.Index(sqlite3.connect(":memory:", check_same_thread=False), Anisotropic())
    for i in range(120):
        f = tmp_path / ("note%d.txt" % i)
        f.write_text("tax" if i % 2 else "bread")
        index.index_file(str(f))
    target = tmp_path / "leak.txt"
    target.write_text("pipe")
    index.index_file(str(target))

    # Raw cosine puts every document within 0.06 of the query.
    hits = index.search("pipe")
    assert [h["name"] for h in hits] == ["leak.txt"]


def test_model_is_unloaded_only_after_the_idle_period():
    embedder = sd.LlamaEmbedder(dict(sd.DEFAULTS, idle_unload_seconds=300))
    embedder.proc = subprocess.Popen(["sleep", "60"])  # stands in for llama-server
    embedder.last_used = time.monotonic() - 200
    embedder.unload_if_idle()
    assert embedder.loaded()

    embedder.last_used = time.monotonic() - 301
    embedder.active = 1  # a request is in flight
    embedder.unload_if_idle()
    assert embedder.loaded()

    embedder.active = 0
    embedder.unload_if_idle()
    assert not embedder.loaded()


def test_reindex_replaces_and_remove_forgets(tmp_path):
    index = make_index(tmp_path)
    f = tmp_path / "insurance.txt"
    f.write_text("now this file is about bread instead")
    index.index_file(str(f))
    assert index.search("pipe") == [] or index.search("pipe")[0]["name"] != "insurance.txt"
    index.remove_file(str(f))
    assert all(h["name"] != "insurance.txt" for h in index.search("bread"))
    assert index.stats()["files"] == 2


def test_image_found_by_what_it_shows_and_by_path(tmp_path):
    from PIL import Image

    index = make_index(tmp_path)
    (tmp_path / "holiday").mkdir()
    picture = tmp_path / "holiday" / "IMG_0042.png"
    Image.new("RGB", (80, 80), "orange").save(picture)
    icon = tmp_path / "icon.png"
    Image.new("RGB", (16, 16)).save(icon)
    index.index_file(str(picture))
    index.index_file(str(icon))

    hit = index.search("sunset")[0]
    assert (hit["name"], hit["why"], hit["image"]) == ("IMG_0042.png", "looks", True)
    assert index.preview(hit["chunk"], "sunset")["aspect"] == 1.0

    # Nothing in the picture or its name says "holiday"; its folder does.
    hit = index.search("holiday")[0]
    assert (hit["name"], hit["why"]) == ("IMG_0042.png", "name")

    assert all(h["name"] != "icon.png" for h in index.search("sunset"))
