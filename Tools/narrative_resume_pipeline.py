#!/usr/bin/env python3
"""Build the full prose index using frozen extraction and resumable derived work.

This is a separate runtime, not the original extraction pipeline. It cannot
extract, reset an extraction checkpoint, or accept bounded source samples.
"""
import argparse
import fcntl
import json
from pathlib import Path
import sqlite3

import corpus
import narrative_pipeline as pipeline
import resumable_embedding as resumable


PARSER_SHA256 = "794f151703c3b8981cf67223a888bd30d4b46c98c1fc2883ff8c1ed74f3bbe26"
PIPELINE_SHA256 = "762531bda814e55b5789c13dcef7582c41e1f5d4a4547865e7a496e269037b7a"
FULL_COUNTS = {"scannedPages": 25932219, "articlePages": 7249099, "extractedMentions": 8173429}


class RuntimeProgress:
    def __init__(self, progress, manifest_path, identity):
        self.progress, self.manifest_path = progress, manifest_path
        self.identity = identity

    def update(self, **fields):
        self.progress.update(**fields, derivedRuntime=self.identity)
        corpus.save_json(self.manifest_path, {**self.identity, "progress": self.progress.value})


def verified_base(path, archive, scanned_pages):
    path = Path(path).resolve()
    original = pipeline.ROOT / "Data"
    if path != (original / "atlas.sqlite").resolve():
        raise RuntimeError("Recovery requires the original validated full infobox base index")
    state = pipeline.read_json(original / "ingest-status.json")
    validation = pipeline.read_json(original / "validation-status.json")
    if (state.get("status") != "complete" or state.get("validation") != "passed"
            or validation.get("status") != "passed"
            or state.get("scannedPages") != scanned_pages
            or Path(state.get("path", "")).resolve() != Path(archive).resolve()):
        raise RuntimeError("The full infobox base must be complete and validated for this archive")
    with sqlite3.connect("file:" + str(path) + "?mode=ro", uri=True) as db:
        metadata = {key: json.loads(value) for key, value in db.execute("SELECT key,value FROM metadata")}
        count = db.execute("SELECT count(*) FROM events").fetchone()[0]
    if count != metadata.get("eventCount") or count != validation.get("events"):
        raise RuntimeError("Base index counts do not match its validated metadata")
    if not metadata.get("embeddingModel") or metadata.get("embeddingDimensions", 512) != 512:
        raise RuntimeError("Base index must use the expected 512-dimensional embedding model")
    return metadata


def verified_extraction(stage, archive, data):
    row = stage.execute("SELECT value FROM extraction_checkpoint WHERE key='progress'").fetchone()
    checkpoint = json.loads(row[0]) if row else {}
    fingerprint = pipeline.source_fingerprint(archive)
    if (checkpoint.get("complete") is not True or checkpoint.get("limited") is not False
            or checkpoint.get("fingerprint") != fingerprint
            or any(checkpoint.get(key) != value for key, value in FULL_COUNTS.items())
            or checkpoint != pipeline.read_json(Path(data) / "extraction.json")):
        raise RuntimeError("Stored extraction and sidecar must match the exact pinned complete full-corpus checkpoint")
    return checkpoint


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("build",))
    parser.add_argument("--archive", type=Path, default=pipeline.ROOT / "Data/downloads" / pipeline.ARCHIVE_NAME)
    parser.add_argument("--data-dir", type=Path, default=pipeline.ROOT / "Data/narrative")
    parser.add_argument("--status", type=Path, default=pipeline.ROOT / "Data/narrative-status.json")
    parser.add_argument("--base-index", type=Path, default=pipeline.ROOT / "Data/atlas.sqlite")
    args = parser.parse_args()
    pipeline.validate_output_paths(args.data_dir, args.status, args.base_index)
    if pipeline.digest(pipeline.ROOT / "Tools/narrative.py") != PARSER_SHA256:
        raise RuntimeError("Pinned extraction parser changed; recovery will not reset extraction")
    if pipeline.digest(Path(pipeline.__file__)) != PIPELINE_SHA256:
        raise RuntimeError("Pinned extraction pipeline changed; recovery will not reset extraction")
    pipeline.verified_archive(args.archive, pipeline.ROOT / "Data/download-status.json")
    if not args.data_dir.is_dir() or not (args.data_dir / "prose-stage.sqlite").is_file():
        raise RuntimeError("Recovery requires an existing completed prose stage")
    manifest = args.data_dir / "derived-runtime.json"
    if args.status.resolve() == manifest.resolve():
        raise RuntimeError("Runtime manifest and progress status must have separate paths")
    with (args.data_dir / "pipeline.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit("A prose pipeline already owns this data directory; no duplicate was started")
        # URI rw refuses to create an empty replacement stage if the path disappears.
        stage = sqlite3.connect("file:" + str((args.data_dir / "prose-stage.sqlite").resolve()) + "?mode=rw", uri=True)
        try:
            checkpoint = verified_extraction(stage, args.archive, args.data_dir)
            fingerprint = checkpoint["fingerprint"]
            metadata = verified_base(args.base_index, args.archive, checkpoint["scannedPages"])
            paths = {"wrapper": Path(__file__), "preparer": Path(resumable.__file__),
                     "signatureAndBatchHelper": pipeline.ROOT / "Tools/scalable.py",
                     "embeddingProgram": pipeline.ROOT / "Tools/embed.swift",
                     "storeAndProgressHelper": pipeline.ROOT / "Tools/corpus.py",
                     "indexValidator": pipeline.ROOT / "Tools/validate_sqlite.py"}
            hashes = {key: pipeline.digest(path) for key, path in paths.items()}
            context = resumable.Context(fingerprint, checkpoint["extractedMentions"], metadata["embeddingModel"], hashes)
            # Identity validation precedes status/schema/cache changes.
            resumable.validate_resume_context(stage, context)
            if stage.execute("PRAGMA journal_mode").fetchone()[0].lower() != "wal":
                raise RuntimeError("Recovery requires the existing stage's WAL journal mode")
            stage.execute("PRAGMA synchronous=FULL")
            identity = {"runtime": "narrative_resume_pipeline", "version": resumable.VERSION,
                        "extractionFingerprint": fingerprint, "extractionParserSHA256": PARSER_SHA256,
                        "extractionPipelineSHA256": PIPELINE_SHA256, "derivedImplementationSHA256": hashes,
                        "embeddingModel": context.model, "embeddingDimensions": context.dimensions,
                        "signatureAlgorithm": context.algorithm, "expectedMentions": context.expected_mentions,
                        "fullExtractionCounts": FULL_COUNTS,
                        "baseIndex": str(args.base_index.resolve())}
            progress = RuntimeProgress(pipeline.Progress(args.status, args.archive, args.data_dir), manifest, identity)
            try:
                progress.update(phase="resumingDerivedPreparation", limited=False)
                def embedder(stage, data, model, progress):
                    return resumable.embed_mentions(stage, data, model, progress, context=context)
                pipeline.build_expanded(stage, args.base_index, args.data_dir, checkpoint, progress, embedder=embedder)
            except BaseException as error:
                progress.update(status="paused" if isinstance(error, KeyboardInterrupt) else "failed",
                                error=type(error).__name__ + ": " + str(error))
                raise
        finally:
            stage.close()


if __name__ == "__main__":
    main()
