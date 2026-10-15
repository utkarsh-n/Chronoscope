import unittest
import json
from pathlib import Path
import shutil
import sqlite3
import tempfile
from unittest.mock import patch
from corpus import wd_date, parse_wiki_date, decimal_date, split_template, precision_upper, vector_buckets, wiki_link_edges, merge_article_events, write_store
from scalable import signature, recover_vectors, export_staged


class DateTests(unittest.TestCase):
    def test_wikidata_bce_uses_astronomical_year(self):
        self.assertEqual(wd_date({"time": "-0001-00-00T00:00:00Z", "precision": 9}), (0, "year"))
        self.assertEqual(wd_date({"time": "-0490-00-00T00:00:00Z", "precision": 9}), (-489, "year"))

    def test_bce_month_and_day_is_not_read_as_ce(self):
        start, end, precision = parse_wiki_date("10 September 490 BC")
        self.assertAlmostEqual(start, decimal_date(-489, 9, 10))
        self.assertEqual(start, end)
        self.assertEqual(precision, "day")

    def test_bce_range_suffix_applies_to_both_dates(self):
        start, end, _ = parse_wiki_date("25 April 431 – 25 March 404 BC")
        self.assertAlmostEqual(start, decimal_date(-430, 4, 25))
        self.assertAlmostEqual(end, decimal_date(-403, 3, 25))

    def test_nested_templates_keep_date_range(self):
        start, end, precision = parse_wiki_date("{{start date|1969|7|16}} – {{end date|1969|7|24}}")
        self.assertAlmostEqual(start, decimal_date(1969, 7, 16))
        self.assertAlmostEqual(end, decimal_date(1969, 7, 24))
        self.assertEqual(precision, "day")

    def test_leap_year_is_astronomical(self):
        self.assertAlmostEqual(decimal_date(2000, 3, 1), 2000 + 60 / 366)
        self.assertAlmostEqual(decimal_date(1900, 3, 1), 1900 + 59 / 365)

    def test_template_links_do_not_split_parameter(self):
        self.assertEqual(split_template("Infobox event|name=[[Apollo 11|Moon mission]]|date={{start date|1969|7|16}}"),
                         ["Infobox event", "name=[[Apollo 11|Moon mission]]", "date={{start date|1969|7|16}}"])

    def test_imprecise_dates_cover_source_period_without_crossing_year(self):
        self.assertGreater(precision_upper(2025, "year"), decimal_date(2025, 12, 31))
        self.assertLess(precision_upper(2025, "year"), 2026)
        self.assertGreater(precision_upper(decimal_date(2000, 2, 1), "month"), decimal_date(2000, 2, 29))
        self.assertLess(precision_upper(decimal_date(2000, 2, 1), "month"), decimal_date(2000, 3, 1))
        self.assertEqual(precision_upper(2025.5, "day"), 2025.5)

    def test_month_only_text_preserves_month_precision(self):
        start, _, precision = parse_wiki_date("October 1917")
        self.assertAlmostEqual(start, decimal_date(1917, 10, 1))
        self.assertEqual(precision, "month")

    def test_month_only_template_preserves_month_precision(self):
        start, end, precision = parse_wiki_date("{{start date|1917|10}}")
        self.assertAlmostEqual(start, decimal_date(1917, 10, 1))
        self.assertEqual(start, end)
        self.assertEqual(precision, "month")

    def test_vector_lsh_has_one_distinct_bucket_per_table(self):
        vector = [(i - 256) / 256 for i in range(512)]
        buckets = vector_buckets(vector)
        self.assertEqual(len(buckets), 16)
        self.assertEqual([b >> 8 for b in buckets], list(range(16)))
        self.assertEqual(vector_buckets([v * 2 for v in vector]), buckets)


class ProvenanceTests(unittest.TestCase):
    def test_reingest_refreshes_bulk_precision_without_replacing_wikidata_identity(self):
        previous = {"id": "enwiki-1", "title": "Bulk event", "summary": "Unchanged text", "end": 2025, "precision": "day", "embedding": [0.5]}
        corrected = {**previous, "end": precision_upper(2025, "year"), "precision": "year", "embedding": []}
        canonical = {"id": "Q2", "title": "Shared event", "summary": "Canonical description", "end": 2000, "precision": "year", "embedding": [0.1]}
        duplicate = {**canonical, "id": "enwiki-2", "end": 1900, "summary": "Dump description", "embedding": []}
        events = [previous, canonical]
        merge_article_events(events, [(json.dumps(corrected), "[]"), (json.dumps(duplicate), "[]")])
        self.assertEqual(len(events), 2)
        self.assertEqual(previous["end"], corrected["end"])
        self.assertEqual(previous["precision"], "year")
        self.assertEqual(previous["embedding"], [0.5])
        self.assertEqual(canonical["id"], "Q2")
        self.assertEqual(canonical["end"], 2000)
        self.assertEqual(canonical["summary"], "Canonical description")

    def test_merged_event_keeps_each_links_actual_source_revision(self):
        canonical = {"id": "Q1", "title": "Shared event", "url": "https://en.wikipedia.org/wiki/Shared_event", "revision": "200"}
        target_a = {"id": "Q2", "title": "API target", "url": "https://en.wikipedia.org/wiki/API_target", "revision": "201"}
        target_b = {"id": "Q3", "title": "Dump target", "url": "https://en.wikipedia.org/wiki/Dump_target", "revision": "202"}
        wiki = {"Shared event": {"revisions": [{"revid": 200, "slots": {"main": {"content": "[[API target]]"}}}]}}
        dump = {**canonical, "id": "enwiki-99", "revision": "100"}
        edges = wiki_link_edges([canonical, target_a, target_b], wiki, [(json.dumps(dump), json.dumps(["Dump target"]))])
        self.assertEqual(len(edges), 2)
        by_target = {edge["target"]: edge for edge in edges}
        self.assertEqual(by_target["Q2"]["evidence"], canonical["url"] + "?oldid=200; hyperlink to API target")
        self.assertEqual(by_target["Q3"]["evidence"], canonical["url"] + "?oldid=100; hyperlink to Dump target")
        self.assertTrue(all(edge["source"] == "Q1" for edge in edges))

    def test_display_alias_uses_original_article_title_for_links(self):
        anchor = {"id": "Q144334-invention", "title": "Invention of Gutenberg's printing press", "url": "https://en.wikipedia.org/wiki/Printing_press", "revision": "300"}
        target = {"id": "Q2", "title": "Target", "url": "https://en.wikipedia.org/wiki/Target", "revision": "301"}
        wiki = {"Printing press": {"revisions": [{"revid": 300, "slots": {"main": {"content": "[[Target]]"}}}]}}
        edges = wiki_link_edges([anchor, target], wiki, [])
        self.assertEqual([(e["source"], e["target"]) for e in edges], [(anchor["id"], target["id"])])


class PortableStoreTests(unittest.TestCase):
    def test_export_opens_after_copying_only_database_into_readonly_directory(self):
        event = {"id": "fixture", "title": "Portable event", "summary": "SQLite portability fixture", "start": 2000,
                 "end": 2000, "precision": "day", "latitude": None, "longitude": None, "category": "History",
                 "url": "https://en.wikipedia.org/wiki/Test", "revision": "1", "embedding": [1.0] + [0.0] * 511}
        catalog = {"schemaVersion": 1, "generatedAt": "2000-01-01T00:00:00Z", "coverage": "Test fixture",
                   "embeddingModel": "Test fixture", "events": [event], "edges": []}
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, destination = root / "source", root / "readonly"
            source.mkdir(); destination.mkdir()
            with patch("corpus.DATA", source):
                write_store(catalog)
            # SQLite file header bytes 18/19 are rollback-journal read/write
            # versions 1; a checkpointed WAL database would still report 2.
            self.assertEqual((source / "atlas.sqlite").read_bytes()[18:20], b"\x01\x01")
            self.assertEqual(sorted(p.name for p in source.iterdir()), ["atlas.sqlite"])
            copied = destination / "catalog.sqlite"
            shutil.copyfile(source / "atlas.sqlite", copied)
            copied.chmod(0o444); destination.chmod(0o555)
            try:
                with sqlite3.connect("file:" + str(copied) + "?mode=ro", uri=True) as db:
                    self.assertEqual(db.execute("PRAGMA journal_mode").fetchone()[0], "delete")
                    self.assertEqual(db.execute("PRAGMA integrity_check").fetchone()[0], "ok")
                    self.assertEqual(db.execute("SELECT count(*) FROM events").fetchone()[0], 1)
                    self.assertEqual(db.execute("SELECT count(*) FROM vector_buckets").fetchone()[0], 16)
                    self.assertEqual(db.execute("SELECT count(*) FROM events_fts WHERE events_fts MATCH 'portable'").fetchone()[0], 1)
                self.assertEqual(sorted(p.name for p in destination.iterdir()), ["catalog.sqlite"])
            finally:
                destination.chmod(0o755); copied.chmod(0o644)


class StreamingTests(unittest.TestCase):
    def test_interrupted_embedding_output_recovers_only_complete_records(self):
        with tempfile.TemporaryDirectory() as temporary:
            stage = sqlite3.connect(":memory:")
            stage.execute("CREATE TABLE sentence_vectors(signature TEXT PRIMARY KEY,model TEXT,embedding TEXT)")
            output = Path(temporary) / "partial.jsonl"
            metadata = {"model": "Fixture model", "dimensions": 2}
            output.write_text(json.dumps(metadata) + "\n" + json.dumps({"id": "complete", "embedding": [1.0, 0.0]}) + '\n{"id":"interrupted"')
            self.assertEqual(recover_vectors(stage, output), metadata)
            self.assertEqual(stage.execute("SELECT signature FROM sentence_vectors").fetchall(), [("complete",)])
            stage.close()

    def test_streaming_export_preserves_ids_provenance_cache_and_portability(self):
        model = "Fixture model"
        vector = [1.0] + [0.0] * 511
        source = {"id": "Q1", "title": "Shared event", "summary": "Canonical summary", "start": 2000,
                  "end": 2000, "precision": "day", "latitude": None, "longitude": None, "category": "History",
                  "url": "https://en.wikipedia.org/wiki/Shared_event", "revision": "200", "embedding": vector}
        target = {**source, "id": "Q2", "title": "Target", "url": "https://en.wikipedia.org/wiki/Target"}
        bulk = {**source, "id": "WP1", "revision": "100", "summary": "Older dump summary", "embedding": []}
        new = {**source, "id": "WP3", "title": "New event", "url": "https://en.wikipedia.org/wiki/New_event", "embedding": []}
        seed = {"events": [source, target], "edges": [], "embeddingModel": model}
        with tempfile.TemporaryDirectory() as temporary:
            data = Path(temporary)
            stage = sqlite3.connect(data / "articles.sqlite")
            stage.execute("CREATE TABLE article_events(id TEXT PRIMARY KEY,title TEXT,revision TEXT,event TEXT,links TEXT)")
            stage.execute("CREATE TABLE sentence_vectors(signature TEXT PRIMARY KEY,model TEXT,embedding TEXT)")
            for event in (bulk, new):
                stage.execute("INSERT INTO article_events VALUES(?,?,?,?,?)", (event["id"], event["title"], event["revision"], json.dumps(event), '["Target"]'))
            stage.execute("INSERT INTO sentence_vectors VALUES(?,?,?)", (signature(new, model), model, json.dumps(vector)))
            stage.commit()
            def probe(_stage, records, _data, expected_model=None):
                self.assertEqual(records, [], "Cached records must not be re-embedded")
                return {"model": model, "dimensions": 512}
            with patch("scalable.embedding_batch", probe), patch("corpus.semantic_edges", return_value=[]):
                stats = export_staged(stage, seed, {}, data, data / "catalog.json", data / "fixture.xml", 10, 2)
            stage.close()
            self.assertEqual(stats["events"], 3)
            db = sqlite3.connect("file:" + str(data / "atlas.sqlite") + "?mode=ro", uri=True)
            event = json.loads(db.execute("SELECT payload FROM events WHERE id='Q1'").fetchone()[0])
            self.assertEqual(event["summary"], source["summary"])
            self.assertIsNone(db.execute("SELECT 1 FROM events WHERE id='WP1'").fetchone())
            evidence = db.execute("SELECT evidence FROM edges WHERE source='Q1'").fetchone()[0]
            self.assertIn("?oldid=100; hyperlink to Target", evidence)
            self.assertEqual(db.execute("PRAGMA journal_mode").fetchone()[0], "delete")
            indexes = {row[1] for row in db.execute("PRAGMA index_list(events)")}
            self.assertTrue({"events_end", "events_category_time", "events_title"}.issubset(indexes))
            db.close()
            state = json.loads((data / "ingest-status.json").read_text())
            self.assertEqual((state["status"], state["validation"]), ("complete", "passed"))
            self.assertFalse((data / "atlas-building.sqlite").exists())


if __name__ == "__main__":
    unittest.main()
