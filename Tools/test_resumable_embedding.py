"""Isolated SQLite fixtures and mocked batches; no corpus, Swift or Simulator."""
from dataclasses import replace
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

import narrative_pipeline as pipeline
import narrative_resume_pipeline as wrapper
import resumable_embedding as resumable
import scalable


MODEL = "Fixture English revision 1"
VECTOR = [1.0] + [0.0] * 511


class Progress:
    def __init__(self, stop_at=None):
        self.updates = []
        self.stop_at = stop_at

    def update(self, **fields):
        self.updates.append(fields)
        if fields.get("preparedMentions") == self.stop_at and fields.get("phase") == "preparingEmbeddings":
            raise RuntimeError("Fixture interruption after preparation commit")


class RecoveryFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="chronoscope-resumable-fixture-")
        self.data = Path(self.temporary.name)
        self.stage = pipeline.open_stage(self.data)
        self.records = []
        self.progress = Progress()

    def tearDown(self):
        self.stage.close()
        self.temporary.cleanup()

    def sources(self, count, *, duplicate_summary=False):
        for index in range(count):
            record = {"id": "M" + str(index).zfill(5), "title": "Fixture title" if duplicate_summary else "Title " + str(index),
                      "summary": "A dated fixture claim" if duplicate_summary else "Dated claim " + str(index)}
            payload = json.dumps(record, ensure_ascii=False, separators=(",", ":"))
            self.records.append((record, payload))
            self.stage.execute("INSERT INTO narrative_events VALUES(?,?,?,?)", (record["id"], str(index + 1), payload, "[]"))
        checkpoint = {"complete": True, "limited": False, "fingerprint": "fixture-full-fingerprint",
                      "extractedMentions": count, "scannedPages": count, "articlePages": count}
        self.stage.execute("INSERT INTO extraction_checkpoint VALUES('progress',?)", (json.dumps(checkpoint),))
        self.stage.commit()
        self.context = resumable.Context(checkpoint["fingerprint"], count, MODEL, {"module": "fixture-runtime-hash"})
        return self.context

    def reopen(self):
        self.stage.close()
        self.stage = sqlite3.connect(self.data / "prose-stage.sqlite")

    def snapshot(self):
        return tuple(self.stage.iterdump())

    def authoritative(self):
        return (self.stage.execute("SELECT * FROM narrative_events ORDER BY id").fetchall(),
                self.stage.execute("SELECT * FROM sentence_vectors ORDER BY signature").fetchall(),
                self.stage.execute("SELECT * FROM extraction_checkpoint ORDER BY key").fetchall())

    def state(self):
        return json.loads(self.stage.execute(f"SELECT value FROM {resumable.CHECKPOINT_TABLE} WHERE key='active'").fetchone()[0])

    @staticmethod
    def fake_batch(stage, records, data, model):
        if stage.in_transaction:
            raise AssertionError("Embedding began inside a queue transaction")
        for record in records:
            stage.execute("INSERT OR REPLACE INTO sentence_vectors VALUES(?,?,?)", (record["id"], model, json.dumps(VECTOR)))
        stage.commit()
        return {"model": model, "dimensions": 512}

    def write_output(self, records, *, model=MODEL, dimensions=512, tail=""):
        raw = self.data / "raw"
        raw.mkdir(exist_ok=True)
        output = raw / "full-embeddings.jsonl"
        output.write_text(json.dumps({"model": model, "dimensions": dimensions}) + "\n"
                          + "".join(json.dumps(record) + "\n" for record in records) + tail)
        return output


class PreparationTests(RecoveryFixture):
    def test_interruption_reopen_resumes_after_committed_source_prefix(self):
        context = self.sources(9)
        original = self.authoritative()
        with self.assertRaisesRegex(RuntimeError, "interruption"):
            resumable.prepare_mentions(self.stage, context, Progress(stop_at=3), batch_size=3)
        self.assertEqual(self.state()["lastId"], "M00002")
        self.assertEqual(self.stage.execute("SELECT count(*) FROM embedding_events").fetchone()[0], 3)
        self.reopen()
        statements = []
        self.stage.set_trace_callback(statements.append)
        state = resumable.prepare_mentions(self.stage, context, self.progress, batch_size=3)
        writes = [sql for sql in statements if sql.startswith("INSERT INTO embedding_events")]
        self.assertEqual(len(writes), 6)
        self.assertFalse(any("'M00000'" in sql or "'M00001'" in sql or "'M00002'" in sql for sql in writes))
        self.assertEqual((state["phase"], state["preparedMentions"], state["remainingMentions"]), ("prepared", 9, 9))
        self.assertEqual(self.authoritative(), original)
        self.assertEqual(self.stage.execute("SELECT id,payload FROM embedding_events ORDER BY id").fetchall(),
                         [(record["id"], payload) for record, payload in self.records])

    def test_source_rows_queue_and_cursor_roll_back_together(self):
        context = self.sources(3)
        # Initialize with a progress interruption, then install an actual SQLite failpoint.
        with self.assertRaises(RuntimeError):
            resumable.prepare_mentions(self.stage, context, Progress(stop_at=0), batch_size=3)
        self.stage.execute(f"""CREATE TRIGGER fixture_abort BEFORE INSERT ON {resumable.CHECKPOINT_TABLE}
            WHEN json_extract(NEW.value,'$.preparedMentions')=3 BEGIN SELECT RAISE(ABORT,'fixture abort'); END""")
        self.stage.commit()
        with self.assertRaisesRegex(sqlite3.IntegrityError, "fixture abort"):
            resumable.prepare_mentions(self.stage, context, self.progress, batch_size=3)
        self.reopen()
        self.assertEqual(self.state()["preparedMentions"], 0)
        self.assertEqual(self.stage.execute("SELECT count(*) FROM embedding_events").fetchone()[0], 0)
        self.assertEqual(self.stage.execute(f"SELECT count(*) FROM {resumable.QUEUE_TABLE}").fetchone()[0], 0)

    def test_existing_identical_derived_payloads_are_not_updated(self):
        context = self.sources(4)
        for record, payload in self.records:
            self.stage.execute("INSERT INTO embedding_events VALUES(?,?,?)", (record["id"], scalable.signature(record, MODEL), payload))
        self.stage.execute("CREATE TABLE fixture_updates(id TEXT)")
        self.stage.execute("CREATE TRIGGER fixture_update AFTER UPDATE ON embedding_events BEGIN INSERT INTO fixture_updates VALUES(NEW.id); END")
        self.stage.commit()
        resumable.prepare_mentions(self.stage, context, self.progress, batch_size=2)
        self.assertEqual(self.stage.execute("SELECT count(*) FROM fixture_updates").fetchone()[0], 0)
        before = self.snapshot()
        resumable.prepare_mentions(self.stage, context, self.progress)
        self.assertEqual(self.snapshot(), before)

    def test_stale_derived_signature_and_payload_are_corrected(self):
        context = self.sources(1)
        record, payload = self.records[0]
        self.stage.execute("INSERT INTO embedding_events VALUES(?,?,?)", (record["id"], "stale", "stale payload"))
        self.stage.commit()
        resumable.prepare_mentions(self.stage, context, self.progress)
        self.assertEqual(self.stage.execute("SELECT signature,payload FROM embedding_events").fetchone(),
                         (scalable.signature(record, MODEL), payload))

    def test_context_mismatches_make_no_database_edits(self):
        context = self.sources(2)
        resumable.prepare_mentions(self.stage, context, self.progress)
        for changed in (replace(context, extraction_fingerprint="changed"), replace(context, model="changed"),
                        replace(context, implementation_hashes={"module": "changed"}), replace(context, version="changed"),
                        replace(context, algorithm="changed"), replace(context, expected_mentions=3)):
            with self.subTest(context=changed):
                before = self.snapshot()
                with self.assertRaises(RuntimeError):
                    resumable.prepare_mentions(self.stage, changed, self.progress)
                self.assertEqual(self.snapshot(), before)

    def test_limited_or_incomplete_extraction_fails_before_schema_changes(self):
        context = self.sources(1)
        for field in ("limited", "complete"):
            row = json.loads(self.stage.execute("SELECT value FROM extraction_checkpoint").fetchone()[0])
            row[field] = field == "limited"
            self.stage.execute("UPDATE extraction_checkpoint SET value=?", (json.dumps(row),))
            self.stage.commit()
            before = self.snapshot()
            with self.assertRaises(RuntimeError):
                resumable.prepare_mentions(self.stage, context, self.progress)
            self.assertEqual(self.snapshot(), before)
            row.update(complete=True, limited=False)
            self.stage.execute("UPDATE extraction_checkpoint SET value=?", (json.dumps(row),))
            self.stage.commit()

    def test_extra_legacy_derived_id_fails_without_deleting_it(self):
        context = self.sources(2)
        self.stage.execute("INSERT INTO embedding_events VALUES('extra','legacy','legacy payload')")
        self.stage.commit()
        original = self.authoritative()
        with self.assertRaisesRegex(RuntimeError, "extra or missing"):
            resumable.prepare_mentions(self.stage, context, self.progress)
        self.assertEqual(self.stage.execute("SELECT payload FROM embedding_events WHERE id='extra'").fetchone()[0], "legacy payload")
        self.assertEqual(self.authoritative(), original)
        self.assertEqual(self.state()["phase"], "preparing")

    def test_wrong_model_cache_is_preserved_and_rejected(self):
        context = self.sources(1)
        signature = scalable.signature(self.records[0][0], MODEL)
        self.stage.execute("INSERT INTO sentence_vectors VALUES(?,?,?)", (signature, "wrong model", json.dumps(VECTOR)))
        self.stage.commit()
        original = self.authoritative()
        with self.assertRaisesRegex(RuntimeError, "wrong model"):
            resumable.prepare_mentions(self.stage, context, self.progress)
        self.assertEqual(self.authoritative(), original)
        self.assertEqual(self.state()["preparedMentions"], 0)

    def test_batch_limit_is_enforced(self):
        context = self.sources(1)
        before = self.snapshot()
        for size in (0, 2001):
            with self.assertRaises(ValueError):
                resumable.prepare_mentions(self.stage, context, self.progress, batch_size=size)
        self.assertEqual(self.snapshot(), before)

    def test_preparation_reads_cache_models_without_vector_blobs_or_partial_aggregate(self):
        context = self.sources(3)
        signature = scalable.signature(self.records[0][0], MODEL)
        self.stage.execute("INSERT INTO sentence_vectors VALUES(?,?,?)", (signature, MODEL, json.dumps(VECTOR)))
        self.stage.commit()
        statements = []
        self.stage.set_trace_callback(statements.append)
        resumable.prepare_mentions(self.stage, context, self.progress, batch_size=1)
        queries = [sql for sql in statements if sql.startswith("SELECT model")]
        self.assertEqual(len(queries), 3)
        self.assertTrue(all("embedding" not in sql for sql in queries))
        preparing = [update for update in self.progress.updates if update["phase"] == "preparingEmbeddings"]
        self.assertTrue(all("embeddedMentions" not in update and "cachedPreparedMentions" in update for update in preparing))
        self.assertEqual(self.progress.updates[-1]["embeddedMentions"], 1)

    def test_sqlite_preparation_work_scales_linearly(self):
        def instructions(count):
            with tempfile.TemporaryDirectory(prefix="chronoscope-resumable-scale-") as directory:
                stage = pipeline.open_stage(directory)
                try:
                    for index in range(count):
                        record = {"id": str(index).zfill(6), "title": "Title " + str(index), "summary": "A claim"}
                        stage.execute("INSERT INTO narrative_events VALUES(?,?,?,?)", (record["id"], str(index), json.dumps(record), "[]"))
                    stage.execute("INSERT INTO extraction_checkpoint VALUES('progress',?)", (json.dumps({
                        "fingerprint": "scale-fixture", "complete": True, "limited": False, "extractedMentions": count}),))
                    stage.commit()
                    context = resumable.Context("scale-fixture", count, MODEL, {"module": "scale-fixture"})
                    steps = [0]
                    def tick():
                        steps[0] += 100
                        return 0
                    stage.set_progress_handler(tick, 100)
                    resumable.prepare_mentions(stage, context, Progress(), batch_size=256)
                    return steps[0]
                finally:
                    stage.close()
        smaller, larger = instructions(2048), instructions(4096)
        self.assertLess(larger, smaller * 2.7, (smaller, larger))


class EmbeddingTests(RecoveryFixture):
    def test_duplicate_signatures_compute_once_but_count_all_mentions(self):
        context = self.sources(600, duplicate_summary=True)
        attempts = []
        def batch(stage, records, data, model):
            attempts.extend(records)
            return self.fake_batch(stage, records, data, model)
        with patch.object(scalable, "embedding_batch", side_effect=batch):
            self.assertEqual(resumable.embed_mentions(self.stage, self.data, MODEL, self.progress, context=context), 600)
        self.assertEqual(len(attempts), 1)
        self.assertEqual(self.stage.execute("SELECT count(*) FROM sentence_vectors").fetchone()[0], 1)
        self.assertEqual(self.state()["remainingMentions"], 0)
        self.assertEqual(self.progress.updates[-1]["embeddedMentions"], 600)

    def test_cache_commit_before_queue_deletion_resumes_without_reembedding(self):
        context = self.sources(4)
        def interrupted(stage, records, data, model):
            self.fake_batch(stage, records, data, model)
            raise RuntimeError("Fixture interruption after vector commit")
        with patch.object(scalable, "embedding_batch", side_effect=interrupted):
            with self.assertRaisesRegex(RuntimeError, "vector commit"):
                resumable.embed_mentions(self.stage, self.data, MODEL, self.progress, context=context)
        self.assertEqual(self.stage.execute("SELECT count(*) FROM sentence_vectors").fetchone()[0], 4)
        self.assertEqual(self.state()["remainingMentions"], 4)
        self.reopen()
        with patch.object(scalable, "embedding_batch", side_effect=AssertionError("Repeated committed vectors")):
            self.assertEqual(resumable.embed_mentions(self.stage, self.data, MODEL, self.progress, context=context), 4)
        self.assertEqual(self.state()["phase"], "complete")
        before = self.snapshot()
        with patch.object(scalable, "embedding_batch", side_effect=AssertionError("Repeated complete run")):
            resumable.embed_mentions(self.stage, self.data, MODEL, self.progress, context=context)
        self.assertEqual(self.snapshot(), before)

    def test_cached_work_is_pruned_and_batches_start_outside_transactions(self):
        context = self.sources(5)
        resumable.prepare_mentions(self.stage, context, self.progress)
        cached = {scalable.signature(record, MODEL) for record, _ in self.records[:2]}
        for signature in cached:
            self.stage.execute("INSERT INTO sentence_vectors VALUES(?,?,?)", (signature, MODEL, json.dumps(VECTOR)))
        self.stage.commit()
        attempts = []
        def batch(stage, records, data, model):
            self.assertFalse(stage.in_transaction)
            attempts.extend(record["id"] for record in records)
            return self.fake_batch(stage, records, data, model)
        with patch.object(scalable, "embedding_batch", side_effect=batch):
            resumable.embed_mentions(self.stage, self.data, MODEL, self.progress, context=context)
        self.assertEqual(len(attempts), 3)
        self.assertFalse(cached.intersection(attempts))

    def test_wrong_model_batch_cannot_import_any_vectors(self):
        context = self.sources(2)
        def batch(stage, records, data, model):
            self.assertFalse(stage.in_transaction)
            stage.execute("INSERT OR REPLACE INTO sentence_vectors VALUES(?,?,?)", (records[0]["id"], "wrong", json.dumps(VECTOR)))
        with patch.object(scalable, "embedding_batch", side_effect=batch):
            with self.assertRaisesRegex(RuntimeError, "model or signature"):
                resumable.embed_mentions(self.stage, self.data, MODEL, self.progress, context=context)
        self.assertEqual(self.stage.execute("SELECT count(*) FROM sentence_vectors").fetchone()[0], 0)
        self.assertEqual(self.state()["remainingMentions"], 2)

    def test_pinned_batch_helpers_wrong_model_output_is_guarded_before_import(self):
        context = self.sources(1)
        signature = scalable.signature(self.records[0][0], MODEL)
        fixture = self
        class Process:
            def wait(self):
                fixture.write_output([{"id": signature, "embedding": VECTOR}], model="wrong model")
                return 0
            def poll(self):
                return 0
        with patch.object(scalable.subprocess, "Popen", return_value=Process()):
            with self.assertRaisesRegex(RuntimeError, "model or signature"):
                resumable.embed_mentions(self.stage, self.data, MODEL, self.progress, context=context)
        self.assertEqual(self.stage.execute("SELECT count(*) FROM sentence_vectors").fetchone()[0], 0)
        self.assertEqual(self.state()["remainingMentions"], 1)


class RawRecoveryTests(RecoveryFixture):
    def _assert_source_mismatch_before_raw_import(self, resumed):
        context = self.sources(2)
        if resumed:
            resumable.prepare_mentions(self.stage, context, self.progress)
        signature = scalable.signature(self.records[0][0], MODEL)
        output = self.write_output([{"id": signature, "embedding": VECTOR}])
        self.stage.execute("DELETE FROM narrative_events WHERE id=?", (self.records[-1][0]["id"],))
        self.stage.commit()
        before = self.snapshot()
        updates = list(self.progress.updates)
        with self.assertRaisesRegex(RuntimeError, "Authoritative narrative count"):
            resumable.embed_mentions(self.stage, self.data, MODEL, self.progress, context=context)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.progress.updates, updates)
        for check in (lambda: resumable.validate_resume_context(self.stage, context),
                      lambda: resumable.recover_output_prefix(self.stage, output, context)):
            with self.assertRaisesRegex(RuntimeError, "Authoritative narrative count"):
                check()
            self.assertEqual(self.snapshot(), before)

    def test_initial_source_count_mismatch_and_valid_raw_prefix_leave_entire_db_unchanged(self):
        self._assert_source_mismatch_before_raw_import(False)

    def test_resume_source_count_mismatch_and_valid_raw_prefix_leave_entire_db_unchanged(self):
        self._assert_source_mismatch_before_raw_import(True)

    def test_boolean_unit_vector_is_rejected_before_cache_writes(self):
        context = self.sources(1)
        signature = scalable.signature(self.records[0][0], MODEL)
        self.write_output([{"id": signature, "embedding": [True] + [False] * 511}])
        before = self.snapshot()
        with self.assertRaisesRegex(RuntimeError, "finite unit"):
            resumable.embed_mentions(self.stage, self.data, MODEL, self.progress, context=context)
        self.assertEqual(self.snapshot(), before)

    def test_wrong_model_or_dimension_header_fails_without_any_edits(self):
        context = self.sources(1)
        signature = scalable.signature(self.records[0][0], MODEL)
        for model, dimensions in (("wrong model", 512), (MODEL, 128)):
            self.write_output([{"id": signature, "embedding": VECTOR}], model=model, dimensions=dimensions)
            before = self.snapshot()
            with self.assertRaisesRegex(RuntimeError, "header"):
                resumable.embed_mentions(self.stage, self.data, MODEL, self.progress, context=context)
            self.assertEqual(self.snapshot(), before)

    def test_complete_prefix_is_recovered_and_partial_tail_is_ignored(self):
        context = self.sources(2)
        signature = scalable.signature(self.records[0][0], MODEL)
        self.write_output([{"id": signature, "embedding": VECTOR}], tail='{"id":"unfinished')
        attempts = []
        def batch(stage, records, data, model):
            attempts.extend(record["id"] for record in records)
            return self.fake_batch(stage, records, data, model)
        with patch.object(scalable, "embedding_batch", side_effect=batch):
            resumable.embed_mentions(self.stage, self.data, MODEL, self.progress, context=context)
        self.assertEqual(len(attempts), 1)
        self.assertNotIn(signature, attempts)
        self.assertEqual(self.stage.execute("SELECT count(*) FROM sentence_vectors").fetchone()[0], 2)

    def test_partial_header_is_ignored(self):
        context = self.sources(1)
        output = self.write_output([])
        output.write_text('{"model":"partial')
        before = self.snapshot()
        self.assertEqual(resumable.recover_output_prefix(self.stage, output, context), 0)
        self.assertEqual(self.snapshot(), before)

    def test_invalid_complete_vector_prevents_partial_import(self):
        context = self.sources(2)
        signatures = [scalable.signature(record, MODEL) for record, _ in self.records]
        output = self.write_output([{"id": signatures[0], "embedding": VECTOR}, {"id": signatures[1], "embedding": [1.0]}])
        before = self.snapshot()
        with self.assertRaisesRegex(RuntimeError, "finite unit"):
            resumable.recover_output_prefix(self.stage, output, context)
        self.assertEqual(self.snapshot(), before)

    def test_raw_conflict_does_not_replace_existing_cache(self):
        context = self.sources(1)
        signature = scalable.signature(self.records[0][0], MODEL)
        self.stage.execute("INSERT INTO sentence_vectors VALUES(?,?,?)", (signature, MODEL, json.dumps(VECTOR)))
        self.stage.commit()
        output = self.write_output([{"id": signature, "embedding": [-1.0] + [0.0] * 511}])
        before = self.snapshot()
        with self.assertRaisesRegex(RuntimeError, "conflicts"):
            resumable.recover_output_prefix(self.stage, output, context)
        self.assertEqual(self.snapshot(), before)


class WrapperGuardTests(RecoveryFixture):
    def test_production_full_counts_are_pinned(self):
        self.assertEqual(wrapper.FULL_COUNTS, {"scannedPages": 25932219, "articlePages": 7249099,
                                              "extractedMentions": 8173429})

    def test_extraction_sidecar_and_full_counts_must_match_without_db_edits(self):
        context = self.sources(2)
        checkpoint = json.loads(self.stage.execute("SELECT value FROM extraction_checkpoint").fetchone()[0])
        sidecar = self.data / "extraction.json"
        sidecar.write_text(json.dumps(checkpoint))
        counts = {key: checkpoint[key] for key in wrapper.FULL_COUNTS}
        with patch.object(wrapper, "FULL_COUNTS", counts), patch.object(pipeline, "source_fingerprint", return_value=context.extraction_fingerprint):
            before = self.snapshot()
            self.assertEqual(wrapper.verified_extraction(self.stage, self.data / "archive.bz2", self.data), checkpoint)
            self.assertEqual(self.snapshot(), before)
            for changed in ({**checkpoint, "articlePages": 1}, {**checkpoint, "complete": False},
                            {**checkpoint, "fingerprint": "other"}):
                sidecar.write_text(json.dumps(changed))
                with self.assertRaisesRegex(RuntimeError, "sidecar"):
                    wrapper.verified_extraction(self.stage, self.data / "archive.bz2", self.data)
                self.assertEqual(self.snapshot(), before)
            sidecar.write_text(json.dumps(checkpoint))
            with patch.object(wrapper, "FULL_COUNTS", {**counts, "extractedMentions": 3}):
                with self.assertRaises(RuntimeError):
                    wrapper.verified_extraction(self.stage, self.data / "archive.bz2", self.data)
            self.assertEqual(self.snapshot(), before)

    def test_base_requires_validated_same_archive_full_scan_and_counts(self):
        data = self.data / "Data"
        data.mkdir()
        archive = self.data / "archive.bz2"
        base = data / "atlas.sqlite"
        with sqlite3.connect(base) as db:
            db.execute("CREATE TABLE events(id TEXT PRIMARY KEY)")
            db.executemany("INSERT INTO events VALUES(?)", [("A",), ("B",)])
            db.execute("CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT)")
            metadata = {"embeddingModel": MODEL, "embeddingDimensions": 512, "eventCount": 2}
            db.executemany("INSERT INTO metadata VALUES(?,?)", [(key, json.dumps(value)) for key, value in metadata.items()])
        ingest = {"status": "complete", "validation": "passed", "path": str(archive), "scannedPages": 2}
        (data / "ingest-status.json").write_text(json.dumps(ingest))
        (data / "validation-status.json").write_text(json.dumps({"status": "passed", "events": 2}))
        with patch.object(pipeline, "ROOT", self.data):
            self.assertEqual(wrapper.verified_base(base, archive, 2), metadata)
            for changes in ({"scannedPages": 1}, {"path": str(self.data / "other.bz2")}, {"status": "running"}):
                (data / "ingest-status.json").write_text(json.dumps({**ingest, **changes}))
                with self.assertRaises(RuntimeError):
                    wrapper.verified_base(base, archive, 2)
            (data / "ingest-status.json").write_text(json.dumps(ingest))
            (data / "validation-status.json").write_text(json.dumps({"status": "passed", "events": 1}))
            with self.assertRaisesRegex(RuntimeError, "counts"):
                wrapper.verified_base(base, archive, 2)

    def test_progress_manifest_identifies_separate_derived_runtime(self):
        identity = {"runtime": "fixture-derived-runtime", "extractionPipelineSHA256": "original",
                    "derivedImplementationSHA256": {"wrapper": "new"}}
        progress = wrapper.RuntimeProgress(pipeline.Progress(self.data / "status.json", self.data / "archive", self.data),
                                          self.data / "derived-runtime.json", identity)
        progress.update(phase="preparingEmbeddings", preparedMentions=3)
        status = json.loads((self.data / "status.json").read_text())
        manifest = json.loads((self.data / "derived-runtime.json").read_text())
        self.assertEqual(status["derivedRuntime"], identity)
        self.assertEqual(manifest["runtime"], "fixture-derived-runtime")
        self.assertEqual(manifest["progress"], status)


if __name__ == "__main__":
    unittest.main()
