"""Fixture-only pipeline checks; no real archive, Swift, or live data jobs."""
import contextlib
import bz2
import hashlib
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import types
import unicodedata
import unittest
from unittest.mock import Mock, patch
import urllib.parse
from xml.sax.saxutils import escape

import corpus
import narrative_pipeline as pipeline
import scalable


MODEL = "Fixture English 512"
VECTOR = [1.0] + [0.0] * 511


class RecordingProgress:
    def __init__(self):
        self.updates = []

    def update(self, **fields):
        self.updates.append(fields)


def event(identifier, title, article=None, start=1969.0, *, provenance=None):
    record = {"id": identifier, "title": title, "summary": "A sourced fixture event.",
              "start": start, "end": start, "precision": "day", "latitude": None,
              "longitude": None, "category": "Space", "revision": "100",
              "url": "https://en.wikipedia.org/wiki/" + urllib.parse.quote((article or title).replace(" ", "_")),
              "embedding": list(VECTOR)}
    if provenance is not None:
        record["provenance"] = provenance
    return record


def prose(page_id="11", discriminator="landing", title="A dated action", *, article="Source article", links=(), day=20):
    quote = "On " + str(day) + " July 1969, the spacecraft " + discriminator + "."
    start = 1969 + (day - 1) / 365
    normalized = unicodedata.normalize("NFC", " ".join(quote.casefold().split()))
    identifier = "NP" + hashlib.sha256((str(page_id) + "\0" + normalized + "\0"
                                       + repr((start, start, "day"))).encode()).hexdigest()[:28]
    record = event(identifier, title, article, start)
    record["summary"] = quote
    record["embedding"] = []
    record["provenance"] = {"method": "datedProse", "articleTitle": article, "pageID": str(page_id),
                            "revisionID": "100", "section": "Mission history", "quote": quote,
                            "dateText": str(day) + " July 1969", "dateBasis": "explicit",
                            "confidence": "explicitDate", "links": list(links),
                            "sourceQuote": quote,
                            "sourceURL": record["url"] + "?oldid=100#Mission_history",
                            "dateContext": "", "extractionMethod": "fixture-v1", "entities": []}
    record["links"] = list(links)
    return record


def write_xml(path, pages):
    text = ['<mediawiki xmlns="http://www.mediawiki.org/xml/export-0.11/">']
    for number, namespace, redirect, body in pages:
        text.append("<page><title>Fixture " + str(number) + "</title><ns>" + str(namespace)
                    + "</ns><id>" + str(number) + "</id>"
                    + ('<redirect title="Elsewhere"/>' if redirect else "")
                    + "<revision><id>100</id><text>" + escape(body) + "</text></revision></page>")
    text.append("</mediawiki>")
    Path(path).write_text("".join(text))


@contextlib.contextmanager
def mock_parser(root, extractor):
    module = types.ModuleType("narrative")
    source = Path(root) / "Tools/narrative.py"
    source.parent.mkdir(parents=True, exist_ok=True)
    if not source.exists():
        source.write_text("# Stable parser fixture; extraction is mocked.\n")
    module.__file__ = str(source)
    module.has_date_candidates = Mock(side_effect=lambda text: "DATED" in text)
    module.extract_narrative_events = Mock(side_effect=extractor)
    with patch.dict(sys.modules, {"narrative": module}):
        yield module


def cache_embedder(stage, data, model, progress):
    """Inject deterministic unit vectors while retaining real cache joins."""
    stage.execute("DELETE FROM embedding_events")
    count = 0
    for identifier, payload in stage.execute("SELECT id,payload FROM narrative_events ORDER BY id"):
        key = scalable.signature(json.loads(payload), model)
        stage.execute("INSERT INTO embedding_events VALUES(?,?,?)", (identifier, key, payload))
        stage.execute("INSERT OR REPLACE INTO sentence_vectors VALUES(?,?,?)", (key, model, json.dumps(VECTOR)))
        count += 1
    stage.commit()
    return count


def insert_prose(stage, record):
    record = json.loads(json.dumps(record))
    links = record.pop("links", record["provenance"].get("links", []))
    stage.execute("INSERT INTO narrative_events VALUES(?,?,?,?)",
                  (record["id"], record["provenance"]["pageID"], json.dumps(record), json.dumps(links)))
    stage.commit()


def write_base(path, records, edges=()):
    db = sqlite3.connect(path)
    corpus.create_store_schema(db)
    planes = corpus.lsh_planes(512)
    for record in records:
        corpus.insert_store_event(db, record, planes)
    db.executemany("INSERT INTO edges VALUES(?,?,?,?,?,?)", edges)
    metadata = {"schemaVersion": 1, "generatedAt": "1969-07-20", "coverage": "Portable fixture base",
                "embeddingModel": MODEL, "embeddingDimensions": 512,
                "eventCount": len(records), "edgeCount": len(edges),
                "documentedEdgeCount": sum(edge[2] != "semantic" for edge in edges),
                "lshVersion": "sparse-xorshift32-v1-16x8x8"}
    db.executemany("INSERT INTO metadata VALUES(?,?)", ((key, json.dumps(value)) for key, value in metadata.items()))
    corpus.finish_store(db)


class PipelineFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="chronoscope-prose-pipeline-")
        self.root = Path(self.temporary.name)
        self.data = self.root / "narrative"
        self.stage = pipeline.open_stage(self.data)
        self.progress = RecordingProgress()
        parser = self.root / "Tools/narrative.py"
        parser.parent.mkdir()
        parser.write_text("# Parser fixture\n")

    def tearDown(self):
        self.stage.close()
        self.temporary.cleanup()


class OutputIsolationTests(PipelineFixture):
    def test_separate_default_and_custom_outputs_are_allowed(self):
        with patch.object(pipeline, "ROOT", self.root):
            pipeline.validate_output_paths(self.root / "Data/narrative", self.root / "Data/narrative-status.json")
            pipeline.validate_output_paths(self.data, self.root / "fixture-status.json", self.root / "Data/atlas.sqlite")

    def test_original_output_cache_and_download_directories_are_rejected(self):
        original = self.root / "Data"
        paths = (original, original / "raw", original / "raw/nested", original / "downloads",
                 original / "downloads/nested", original / "downloads/../raw/nested")
        with patch.object(pipeline, "ROOT", self.root):
            for path in paths:
                with self.subTest(path=path), self.assertRaises(RuntimeError):
                    pipeline.validate_output_paths(path, self.root / "fixture-status.json")

    def test_original_statuses_and_artifacts_cannot_be_replaced_by_progress(self):
        original = self.root / "Data"
        paths = [original / name for name in ("download-status.json", "ingest-status.json", "validation-status.json",
                 "catalog-status.json", "native-refresh-status.json", "phone-update-status.json", "atlas.sqlite", "articles.sqlite")]
        paths += [original / "raw/full-embeddings.jsonl", original / "downloads/verified.xml.bz2",
                  self.data / "prose-stage.sqlite", self.data / "atlas.sqlite",
                  self.data / "extraction.json", self.data / "catalog-status.json", self.data / "validation-status.json"]
        with patch.object(pipeline, "ROOT", self.root):
            for path in paths:
                with self.subTest(path=path), self.assertRaises(RuntimeError):
                    pipeline.validate_output_paths(self.data, path)

    def test_resolved_symlink_aliases_do_not_bypass_protected_paths(self):
        original = self.root / "Data"
        original.mkdir()
        original_status = original / "ingest-status.json"
        original_status.write_text("original status")
        directory_alias = self.root / "original-alias"
        directory_alias.symlink_to(original, target_is_directory=True)
        status_alias = self.root / "status-alias.json"
        status_alias.symlink_to(original_status)
        with patch.object(pipeline, "ROOT", self.root):
            with self.assertRaises(RuntimeError):
                pipeline.validate_output_paths(directory_alias, self.root / "fixture-status.json")
            with self.assertRaises(RuntimeError):
                pipeline.validate_output_paths(self.data, status_alias)
        self.assertEqual(original_status.read_text(), "original status")

    def test_base_index_cannot_be_the_destination_index(self):
        with patch.object(pipeline, "ROOT", self.root), self.assertRaises(RuntimeError):
            pipeline.validate_output_paths(self.data, self.root / "fixture-status.json", self.data / "atlas.sqlite")

    def test_cli_rejects_unsafe_paths_before_creating_or_opening_any_output(self):
        original = self.root / "Data"
        argv = ["narrative_pipeline.py", "run", "--data-dir", str(original), "--status", str(original / "ingest-status.json")]
        with patch.object(sys, "argv", argv), patch.object(pipeline, "ROOT", self.root), \
                patch.object(pipeline, "open_stage") as stage, patch.object(pipeline, "Progress") as progress:
            with self.assertRaises(RuntimeError):
                pipeline.main()
        stage.assert_not_called()
        progress.assert_not_called()
        self.assertFalse(original.exists())


class ArchiveVerificationTests(PipelineFixture):
    def archive_fixture(self):
        archive = self.root / "fixture-full.xml.bz2"
        archive.write_bytes(b"Verified fixture bytes")
        state = {"status": "verified", "path": str(archive), "expectedBytes": archive.stat().st_size,
                 "expectedSHA1": hashlib.sha1(archive.read_bytes()).hexdigest()}
        status = self.root / "download-status.json"
        status.write_text(json.dumps(state))
        return archive, status, state

    def test_exact_verified_full_archive_is_admitted(self):
        archive, status, state = self.archive_fixture()
        with patch.multiple(pipeline, ARCHIVE_NAME=archive.name, ARCHIVE_BYTES=state["expectedBytes"], ARCHIVE_SHA1=state["expectedSHA1"]):
            self.assertEqual(pipeline.verified_archive(archive, status), state)

    def test_status_path_size_sha1_and_filename_mismatches_are_rejected(self):
        archive, status, original = self.archive_fixture()
        cases = {"status": "downloading", "path": str(self.root / "different.xml.bz2"),
                 "expectedBytes": original["expectedBytes"] + 1, "expectedSHA1": "wrong"}
        with patch.multiple(pipeline, ARCHIVE_NAME=archive.name, ARCHIVE_BYTES=original["expectedBytes"], ARCHIVE_SHA1=original["expectedSHA1"]):
            for key, value in cases.items():
                with self.subTest(key=key):
                    status.write_text(json.dumps({**original, key: value}))
                    with self.assertRaises(RuntimeError):
                        pipeline.verified_archive(archive, status)
            status.write_text(json.dumps(original))
            archive.write_bytes(b"truncated")
            with self.assertRaises(RuntimeError):
                pipeline.verified_archive(archive, status)
            archive.write_bytes(b"Verified fixture bytes")
            with patch.object(pipeline, "ARCHIVE_NAME", "other-full.xml.bz2"):
                with self.assertRaises(RuntimeError):
                    pipeline.verified_archive(archive, status)

    def test_cli_rejects_unverified_archive_before_extraction(self):
        archive = self.root / "unverified.xml"
        status = self.root / "status.json"
        argv = ["narrative_pipeline.py", "extract", "--archive", str(archive),
                "--data-dir", str(self.data), "--status", str(status)]
        with patch.object(sys, "argv", argv), patch.object(pipeline, "ROOT", self.root), \
                patch.object(pipeline, "verified_archive", side_effect=RuntimeError("Archive not verified")), \
                patch.object(pipeline, "extract_dump") as extract:
            with self.assertRaisesRegex(RuntimeError, "not verified"):
                pipeline.main()
        extract.assert_not_called()
        self.assertEqual(json.loads(status.read_text())["status"], "failed")

    def test_cli_prevents_bounded_sample_from_being_published(self):
        archive = self.root / "sample.xml"
        write_xml(archive, [(1, 0, False, "DATED"), (2, 0, False, "DATED")])
        argv = ["narrative_pipeline.py", "build", "--archive", str(archive),
                "--data-dir", str(self.data), "--status", str(self.root / "status.json"), "--max-pages", "1"]
        with mock_parser(self.root, ExtractionCheckpointTests.extract), \
                patch.object(sys, "argv", argv), patch.object(pipeline, "ROOT", self.root), \
                patch.object(pipeline, "verified_archive", return_value={"status": "verified"}), \
                patch.object(pipeline, "wait_for_base") as wait, patch.object(pipeline, "build_expanded") as build:
            with self.assertRaisesRegex(RuntimeError, "bounded extraction"):
                pipeline.main()
        wait.assert_not_called()
        build.assert_not_called()
        self.assertFalse((self.data / "atlas.sqlite").exists())


class ExtractionCheckpointTests(PipelineFixture):
    @staticmethod
    def extract(title, page_id, revision, text):
        return [prose(page_id, "landed", article=title, links=("Local target",))]

    def test_only_nonredirect_namespace_zero_pages_are_extracted(self):
        archive = self.root / "sample.xml"
        write_xml(archive, [(1, 0, False, "DATED"), (2, 1, False, "DATED"),
                            (3, 0, True, "DATED"), (4, 0, False, "No dates")])
        with mock_parser(self.root, self.extract) as parser:
            result = pipeline.extract_dump(self.stage, archive, self.data, self.progress)
            self.assertEqual(parser.extract_narrative_events.call_count, 1)
        self.assertEqual((result["scannedPages"], result["articlePages"], result["extractedMentions"]), (4, 2, 1))
        payload, links = self.stage.execute("SELECT payload,links FROM narrative_events").fetchone()
        self.assertNotIn("links", json.loads(payload))
        self.assertEqual(json.loads(links), ["Local target"])

    def test_streaming_bzip2_archive_uses_the_same_extraction_path(self):
        plain = self.root / "sample.xml"
        write_xml(plain, [(1, 0, False, "DATED")])
        archive = self.root / "sample.xml.bz2"
        archive.write_bytes(bz2.compress(plain.read_bytes()))
        with mock_parser(self.root, self.extract):
            result = pipeline.extract_dump(self.stage, archive, self.data, self.progress)
        self.assertEqual(result["extractedMentions"], 1)
        self.assertTrue(result["complete"])

    def test_year_article_without_explicit_year_in_text_is_sent_to_parser(self):
        archive = self.root / "year.xml"
        archive.write_text('<mediawiki xmlns="http://www.mediawiki.org/xml/export-0.11/">'
                           '<page><title>1990</title><ns>0</ns><id>11</id>'
                           '<revision><id>100</id><text>January 1 – A spacecraft launched.</text></revision>'
                           '</page></mediawiki>')
        with mock_parser(self.root, self.extract) as parser:
            self.assertFalse(parser.has_date_candidates("January 1 – A spacecraft launched."))
            result = pipeline.extract_dump(self.stage, archive, self.data, self.progress)
            parser.extract_narrative_events.assert_called_once()
        self.assertEqual(result["extractedMentions"], 1)

    def test_complete_checkpoint_reuses_extraction_without_calling_parser(self):
        archive = self.root / "sample.xml"
        write_xml(archive, [(1, 0, False, "DATED")])
        with mock_parser(self.root, self.extract) as parser:
            first = pipeline.extract_dump(self.stage, archive, self.data, self.progress)
            parser.extract_narrative_events.reset_mock(side_effect=True)
            parser.extract_narrative_events.side_effect = AssertionError("Completed input was reparsed")
            self.assertEqual(pipeline.extract_dump(self.stage, archive, self.data, self.progress), first)
            parser.extract_narrative_events.assert_not_called()

    def test_crash_resumes_after_committed_checkpoint_without_duplicate_mentions(self):
        archive = self.root / "sample.xml"
        write_xml(archive, [(number, 0, False, "DATED") for number in range(1, 2003)])
        def interrupted(title, page_id, revision, text):
            if page_id == "2001":
                raise RuntimeError("Fixture interrupted after durable checkpoint")
            return self.extract(title, page_id, revision, text)
        with mock_parser(self.root, interrupted) as parser:
            with self.assertRaisesRegex(RuntimeError, "durable checkpoint"):
                pipeline.extract_dump(self.stage, archive, self.data, self.progress)
            self.stage.rollback()
            checkpoint = json.loads(self.stage.execute("SELECT value FROM extraction_checkpoint WHERE key='progress'").fetchone()[0])
            self.assertEqual(checkpoint["scannedPages"], 2000)
            self.assertEqual(self.stage.execute("SELECT count(*) FROM narrative_events").fetchone()[0], 2000)
            parser.extract_narrative_events.reset_mock(side_effect=True)
            parser.extract_narrative_events.side_effect = self.extract
            result = pipeline.extract_dump(self.stage, archive, self.data, self.progress)
            self.assertEqual(parser.extract_narrative_events.call_count, 2)
        self.assertTrue(result["complete"])
        self.assertEqual(result["extractedMentions"], 2002)
        self.assertEqual(self.stage.execute("SELECT count(*) FROM narrative_events").fetchone()[0], 2002)

    def test_limited_sample_is_not_reused_as_complete_full_extraction(self):
        archive = self.root / "sample.xml"
        write_xml(archive, [(1, 0, False, "DATED"), (2, 0, False, "DATED")])
        with mock_parser(self.root, self.extract):
            limited = pipeline.extract_dump(self.stage, archive, self.data, self.progress, max_pages=1)
            self.assertTrue(limited["limited"])
            self.assertEqual(limited["extractedMentions"], 1)
            complete = pipeline.extract_dump(self.stage, archive, self.data, self.progress)
        self.assertFalse(complete["limited"])
        self.assertEqual(complete["extractedMentions"], 2)

    def test_parser_revision_change_invalidates_completed_checkpoint(self):
        archive = self.root / "sample.xml"
        write_xml(archive, [(1, 0, False, "DATED")])
        with mock_parser(self.root, self.extract) as parser:
            pipeline.extract_dump(self.stage, archive, self.data, self.progress)
            Path(parser.__file__).write_text("# Updated parser fixture\n")
            parser.extract_narrative_events.side_effect = lambda *args: [prose("1", "lifted off")]
            result = pipeline.extract_dump(self.stage, archive, self.data, self.progress)
        self.assertEqual(result["extractedMentions"], 1)
        self.assertIn("lifted off", self.stage.execute("SELECT payload FROM narrative_events").fetchone()[0])


class AttributionTests(PipelineFixture):
    def test_canonical_mapping_marks_ambiguous_article_and_display_aliases(self):
        db = sqlite3.connect(":memory:")
        try:
            db.execute("CREATE TABLE events(id TEXT,title TEXT,url TEXT,payload TEXT)")
            records = [event("Q1", "Shared title", "Shared article"),
                       event("Q2", "Shared title", "Other article"),
                       event("Q3", "Unique display title", "Shared article"),
                       prose("1", "landed", title="Other article", article="Other article")]
            db.executemany("INSERT INTO events VALUES(?,?,?,?)", ((record["id"], record["title"], record["url"], json.dumps(record)) for record in records))
            pipeline.canonical_mapping(db)
            mapped = dict(db.execute("SELECT title,event_id FROM canonical_article_events"))
            self.assertIsNone(mapped["Shared title"])
            self.assertIsNone(mapped["Shared article"])
            self.assertEqual(mapped["Other article"], "Q2")
            self.assertEqual(mapped["Unique display title"], "Q3")
        finally:
            db.close()

    def test_canonical_mapping_accepts_null_optional_provenance(self):
        db = sqlite3.connect(":memory:")
        try:
            record = event("Q1", "Legacy event")
            record["provenance"] = None
            db.execute("CREATE TABLE events(id TEXT,title TEXT,url TEXT,payload TEXT)")
            db.execute("INSERT INTO events VALUES(?,?,?,?)", (record["id"], record["title"], record["url"], json.dumps(record)))
            pipeline.canonical_mapping(db)
            self.assertEqual(db.execute("SELECT event_id FROM canonical_article_events WHERE title='Legacy event'").fetchone()[0], "Q1")
        finally:
            db.close()

    def test_revision_query_precedes_fragment_and_replaces_old_revision(self):
        result = pipeline.revision_url("https://en.wikipedia.org/wiki/C%2B%2B?oldid=10&uselang=en#Old_section", "100", "Formation & launch")
        parts = urllib.parse.urlsplit(result)
        self.assertEqual(urllib.parse.parse_qs(parts.query), {"oldid": ["100"], "uselang": ["en"]})
        self.assertEqual(urllib.parse.unquote(parts.fragment), "Formation_&_launch")
        self.assertLess(result.index("oldid=100"), result.index("#"))
        preserved = pipeline.revision_url("https://en.wikipedia.org/wiki/Fixture#Existing_section", "101")
        self.assertEqual(urllib.parse.urlsplit(preserved).fragment, "Existing_section")

    def test_sentence_edges_use_only_local_links_and_quote_revision(self):
        record = prose(links=("Local_target#Section", "Ambiguous", "Unknown"))
        record["articleLinks"] = ["Article wide only"]
        mapping = {"Local target": "Q2", "Ambiguous": None, "Article wide only": "Q3"}
        edges = list(pipeline.sentence_edges(record, record["links"], mapping.get))
        self.assertEqual([(edge[0], edge[1], edge[3]) for edge in edges], [(record["id"], "Q2", "source sentence mentions")])
        url = edges[0][4].split("; ", 1)[0]
        self.assertEqual(urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)["oldid"], ["100"])
        self.assertEqual(urllib.parse.urlsplit(url).fragment, "Mission_history")
        self.assertIn(record["provenance"]["quote"], edges[0][4])

    def test_nested_section_evidence_uses_the_actual_leaf_heading(self):
        record = prose(links=("Local target",))
        record["provenance"]["section"] = "Mission history / Launch"
        record["provenance"]["sourceURL"] = record["url"] + "?oldid=100#Launch"
        edge = next(pipeline.sentence_edges(record, record["links"], {"Local target": "Q2"}.get))
        url = edge[4].split("; ", 1)[0]
        self.assertEqual(urllib.parse.urlsplit(url).fragment, "Launch")


class PortableExportTests(PipelineFixture):
    def test_multi_statement_shared_title_article_preserves_base_and_full_counts(self):
        base = self.root / "base.sqlite"
        records = [event("Q1", "Source event", "Source article"), event("Q2", "Local target"), event("Q3", "Article wide only")]
        base_edges = [("Q1", "Q3", "wikiLink", "article links to", "https://en.wikipedia.org/wiki/Source_article?oldid=90", 1.0)]
        write_base(base, records, base_edges)
        before_hash = pipeline.digest(base)
        statements = [prose("11", "landed", links=("Local target",)),
                      prose("11", "returned", links=("Local target",), day=24)]
        self.assertEqual(statements[0]["title"], statements[1]["title"])
        for record in statements:
            insert_prose(self.stage, record)
        checkpoint = {"scannedPages": 3, "articlePages": 3, "limited": False}
        with patch.object(pipeline, "ROOT", self.root):
            validation = pipeline.build_expanded(self.stage, base, self.data, checkpoint, self.progress, embedder=cache_embedder)
        self.assertEqual(validation["events"], 5)
        self.assertEqual(validation["edges"], 3)
        self.assertEqual(validation["dimensions"], 512)
        self.assertEqual(pipeline.digest(base), before_hash)
        output = self.data / "atlas.sqlite"
        with output.open("rb") as file:
            self.assertEqual(file.read(20)[18:20], b"\x01\x01")
        with sqlite3.connect("file:" + str(output) + "?mode=ro", uri=True) as db:
            metadata = {key: json.loads(value) for key, value in db.execute("SELECT key,value FROM metadata")}
            self.assertEqual((metadata["eventCount"], metadata["structuredEventCount"], metadata["narrativeStatementCount"]), (5, 3, 2))
            self.assertEqual(metadata["proseExtraction"]["baseIndexSHA256"], before_hash)
            self.assertEqual(metadata["proseExtraction"]["parserSHA256"], pipeline.digest(self.root / "Tools/narrative.py"))
            self.assertFalse(metadata["proseExtraction"]["limited"])
            self.assertEqual(db.execute("SELECT count(*) FROM events_fts").fetchone()[0], 5)
            self.assertEqual(db.execute("SELECT count(*) FROM vector_buckets").fetchone()[0], 80)
            self.assertFalse(db.execute("SELECT 1 FROM sqlite_master WHERE name='canonical_article_events'").fetchone())
            self.assertEqual(db.execute("SELECT source,target,kind,label,evidence,score FROM edges WHERE source='Q1'").fetchall(), base_edges)
            for record in records:
                self.assertEqual(json.loads(db.execute("SELECT payload FROM events WHERE id=?", (record["id"],)).fetchone()[0]), record)
            for record in statements:
                self.assertEqual(db.execute("SELECT target FROM edges WHERE source=?", (record["id"],)).fetchall(), [("Q2",)])
                payload = json.loads(db.execute("SELECT payload FROM events WHERE id=?", (record["id"],)).fetchone()[0])
                self.assertEqual(payload["provenance"], record["provenance"])
            self.assertIn("not globally resolved unique events", metadata["coverage"])
        self.assertFalse(Path(str(output) + "-wal").exists())
        self.assertEqual(self.progress.updates[-1]["status"], "complete")

    def test_existing_base_prose_is_preserved_and_included_in_provenance_totals(self):
        base = self.root / "base.sqlite"
        existing = prose("11", "landed")
        existing.pop("links")
        existing["embedding"] = list(VECTOR)
        write_base(base, [event("Q1", "Source event", "Source article"), existing])
        insert_prose(self.stage, prose("12", "returned", day=24))
        before_hash = pipeline.digest(base)
        with patch.object(pipeline, "ROOT", self.root):
            validation = pipeline.build_expanded(self.stage, base, self.data,
                                                 {"scannedPages": 2, "articlePages": 2},
                                                 self.progress, embedder=cache_embedder)
        self.assertEqual(validation["events"], 3)
        self.assertEqual(pipeline.digest(base), before_hash)
        with sqlite3.connect(self.data / "atlas.sqlite") as db:
            metadata = {key: json.loads(value) for key, value in db.execute("SELECT key,value FROM metadata")}
            self.assertEqual((metadata["structuredEventCount"], metadata["narrativeStatementCount"]), (1, 2))
            self.assertEqual(json.loads(db.execute("SELECT payload FROM events WHERE id=?", (existing["id"],)).fetchone()[0]), existing)
        state = json.loads((self.data / "validation-status.json").read_text())
        self.assertEqual(state["proseStatementsChecked"], 2)

    def test_stable_statement_already_in_base_is_not_inserted_twice(self):
        base = self.root / "base.sqlite"
        existing = prose()
        base_record = json.loads(json.dumps(existing))
        base_record.pop("links")
        base_record["embedding"] = list(VECTOR)
        write_base(base, [event("Q1", "Source event", "Source article"), base_record])
        insert_prose(self.stage, existing)
        with patch.object(pipeline, "ROOT", self.root):
            validation = pipeline.build_expanded(self.stage, base, self.data,
                                                 {"scannedPages": 1, "articlePages": 1},
                                                 self.progress, embedder=cache_embedder)
        self.assertEqual(validation["events"], 2)
        with sqlite3.connect(self.data / "atlas.sqlite") as db:
            self.assertEqual(db.execute("SELECT count(*) FROM events_fts").fetchone()[0], 2)
            self.assertEqual(db.execute("SELECT count(*) FROM vector_buckets").fetchone()[0], 32)
            metadata = {key: json.loads(value) for key, value in db.execute("SELECT key,value FROM metadata")}
            self.assertEqual((metadata["structuredEventCount"], metadata["narrativeStatementCount"]), (1, 1))

    def test_conflicting_payload_for_same_stable_identity_does_not_replace_verified_output(self):
        base = self.root / "base.sqlite"
        existing = prose()
        base_record = json.loads(json.dumps(existing))
        base_record.pop("links")
        base_record["embedding"] = list(VECTOR)
        write_base(base, [event("Q1", "Source event", "Source article"), base_record])
        changed = json.loads(json.dumps(existing))
        changed["provenance"]["quote"] = changed["summary"] = "A conflicting source claim."
        insert_prose(self.stage, changed)
        output = self.data / "atlas.sqlite"
        output.write_bytes(b"previous verified output")
        with patch.object(pipeline, "ROOT", self.root):
            with self.assertRaisesRegex(RuntimeError, "Conflicting source record"):
                pipeline.build_expanded(self.stage, base, self.data,
                                        {"scannedPages": 1, "articlePages": 1}, self.progress, embedder=cache_embedder)
        self.assertEqual(output.read_bytes(), b"previous verified output")

    def test_cached_vectors_complete_embedding_without_swift(self):
        record = prose()
        insert_prose(self.stage, record)
        key = scalable.signature(record, MODEL)
        self.stage.execute("INSERT INTO sentence_vectors VALUES(?,?,?)", (key, MODEL, json.dumps(VECTOR)))
        self.stage.commit()
        with patch.object(scalable, "embedding_batch", side_effect=AssertionError("Cached vectors invoked Swift")):
            self.assertEqual(pipeline.embed_mentions(self.stage, self.data, MODEL, self.progress), 1)
        self.assertEqual(self.stage.execute("SELECT id FROM embedding_events").fetchone()[0], record["id"])

    def test_calendar_day_context_provenance_survives_portable_export(self):
        base = self.root / "base.sqlite"
        write_base(base, [event("Q1", "Source event", "Source article")])
        record = prose(article="April 2")
        record["provenance"].update(dateBasis="articleDay", confidence="contextualDate", dateContext="April 2")
        insert_prose(self.stage, record)
        with patch.object(pipeline, "ROOT", self.root):
            result = pipeline.build_expanded(self.stage, base, self.data,
                                             {"scannedPages": 1, "articlePages": 1}, self.progress, embedder=cache_embedder)
        self.assertEqual(result["events"], 2)
        with sqlite3.connect(self.data / "atlas.sqlite") as db:
            restored = json.loads(db.execute("SELECT payload FROM events WHERE id=?", (record["id"],)).fetchone()[0])
            self.assertEqual(restored["provenance"], record["provenance"])

    def test_failed_validation_does_not_publish_over_existing_expanded_index(self):
        base = self.root / "base.sqlite"
        write_base(base, [event("Q1", "Source event", "Source article")])
        record = prose()
        record["provenance"]["quote"] = ""
        insert_prose(self.stage, record)
        portable = self.data / "atlas.sqlite"
        portable.write_bytes(b"previous verified output")
        with patch.object(pipeline, "ROOT", self.root):
            with self.assertRaises(AssertionError):
                pipeline.build_expanded(self.stage, base, self.data, {"scannedPages": 1, "articlePages": 1}, self.progress, embedder=cache_embedder)
        self.assertEqual(portable.read_bytes(), b"previous verified output")


class EmbeddingWorkTests(PipelineFixture):
    @staticmethod
    def fake_batch(stage, records, data, model):
        stage.executemany("INSERT OR REPLACE INTO sentence_vectors VALUES(?,?,?)",
                          ((record["id"], model, json.dumps(VECTOR)) for record in records))
        stage.commit()

    def test_interrupted_batches_resume_only_missing_vectors(self):
        records = [prose(str(index + 1), title="Claim " + str(index)) for index in range(1100)]
        for record in records:
            insert_prose(self.stage, record)
        expected = {scalable.signature(record, MODEL) for record in records}
        attempts = []
        def interrupted(stage, batch, data, model):
            attempts.append({record["id"] for record in batch})
            if len(attempts) == 2:
                raise RuntimeError("Fixture interruption")
            self.fake_batch(stage, batch, data, model)
        with patch.object(scalable, "embedding_batch", side_effect=interrupted):
            with self.assertRaisesRegex(RuntimeError, "interruption"):
                pipeline.embed_mentions(self.stage, self.data, MODEL, self.progress)
        cached = {row[0] for row in self.stage.execute("SELECT signature FROM sentence_vectors")}
        self.assertEqual(len(cached), 512)
        resumed = []
        def complete(stage, batch, data, model):
            resumed.extend(record["id"] for record in batch)
            self.fake_batch(stage, batch, data, model)
        with patch.object(scalable, "embedding_batch", side_effect=complete):
            self.assertEqual(pipeline.embed_mentions(self.stage, self.data, MODEL, self.progress), 1100)
        self.assertEqual(set(resumed), expected - cached)
        self.assertEqual(len(resumed), 588)
        self.assertEqual(self.stage.execute("SELECT count(*) FROM sentence_vectors").fetchone()[0], 1100)
        self.assertEqual(self.progress.updates[-1]["embeddedMentions"], 1100)

    def test_embedding_sqlite_work_grows_linearly_across_many_batches(self):
        def instructions(count):
            stage = pipeline.open_stage(self.root / ("scale-" + str(count)))
            try:
                def records():
                    for index in range(count):
                        record = event("Fixture" + str(index), "Claim " + str(index))
                        record["embedding"] = []
                        yield (record["id"], str(index + 1), json.dumps(record), "[]")
                stage.executemany("INSERT INTO narrative_events VALUES(?,?,?,?)", records())
                stage.commit()
                steps = [0]
                def tick():
                    steps[0] += 100
                    return 0
                stage.set_progress_handler(tick, 100)
                with patch.object(scalable, "embedding_batch", side_effect=self.fake_batch):
                    self.assertEqual(pipeline.embed_mentions(stage, self.data, MODEL, RecordingProgress()), count)
                return steps[0]
            finally:
                stage.set_progress_handler(None, 0)
                stage.close()
        smaller, larger = instructions(4096), instructions(8192)
        self.assertLess(larger, smaller * 2.6,
                        "Doubling the corpus must not repeatedly scan the growing completed prefix: "
                        + str((smaller, larger)))


class ProvenanceContractTests(PipelineFixture):
    def validate_fixture(self, records, expected):
        path = self.root / "provenance.sqlite"
        db = sqlite3.connect(path)
        db.execute("CREATE TABLE events(id TEXT PRIMARY KEY,payload TEXT)")
        db.executemany("INSERT INTO events VALUES(?,?)", ((record["id"], json.dumps(record)) for record in records))
        db.commit()
        db.close()
        pipeline.validate_provenance(path, expected)

    def test_valid_provenance_and_exact_count(self):
        self.validate_fixture([prose()], 1)
        with self.assertRaises(AssertionError):
            pipeline.validate_provenance(self.root / "provenance.sqlite", 2)

    def test_explicit_section_article_year_and_calendar_day_contracts_are_valid(self):
        records = []
        for index, basis in enumerate(("explicit", "sectionYear", "articleYear", "articleDay")):
            record = prose(str(index + 1))
            record["provenance"]["dateBasis"] = basis
            record["provenance"]["confidence"] = {"explicit": "explicitDate", "articleDay": "contextualDate"}.get(basis, "contextualYear")
            record["provenance"]["dateContext"] = "April 2" if basis == "articleDay" else "1969" if basis != "explicit" else ""
            records.append(record)
        self.validate_fixture(records, 4)

    def test_invalid_quote_revision_basis_and_field_types_are_rejected(self):
        cases = [("quote", ""), ("dateText", ""), ("revisionID", "999"),
                 ("dateBasis", "inferredWithoutSource"), ("pageID", ""),
                 ("articleTitle", ""), ("confidence", 0.9), ("confidence", "invented"),
                 ("method", "unknown"), ("pageID", "not-a-page"), ("revisionID", "unknown")]
        for index, (key, value) in enumerate(cases):
            with self.subTest(key=key):
                record = prose(str(index + 1))
                record["provenance"][key] = value
                path = self.root / "provenance.sqlite"
                path.unlink(missing_ok=True)
                with self.assertRaises((AssertionError, KeyError)):
                    self.validate_fixture([record], 1)

    def test_dated_prose_requires_stable_np_hash_identity(self):
        for identifier in ("NP", "NP11-short", "NP" + "a" * 27, "NP" + "G" * 28):
            with self.subTest(identifier=identifier):
                record = prose()
                record["id"] = identifier
                (self.root / "provenance.sqlite").unlink(missing_ok=True)
                with self.assertRaises(AssertionError):
                    self.validate_fixture([record], 1)

    def test_dated_prose_cannot_hide_under_a_non_np_identifier(self):
        valid = prose()
        hidden = prose("12", "returned")
        hidden["id"] = "unexpected-prose-id"
        with self.assertRaises(AssertionError):
            self.validate_fixture([valid, hidden], 1)

    def test_displayed_summary_cannot_differ_from_recorded_quote(self):
        record = prose()
        record["summary"] = "An unsupported summary replaces the quoted claim."
        with self.assertRaises(AssertionError):
            self.validate_fixture([record], 1)


if __name__ == "__main__":
    unittest.main()
