#!/usr/bin/env python3
"""Independent, resumable prose pass over the verified Wikipedia archive.

Never writes the active infobox job's stage, vectors, atlas, or status files.
Prose records are source-specific dated claims, not resolved unique historical
events. Links come only from the recorded sentence, not its entire article.
"""
import argparse
import bz2
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import time
import unicodedata
import urllib.parse
import xml.etree.ElementTree as ET

import corpus
import scalable
from validate_sqlite import validate_sqlite

ROOT = Path(__file__).resolve().parents[1]
ARCHIVE_NAME = "enwiki-20261001-pages-articles-multistream.xml.bz2"
ARCHIVE_BYTES = 26917225724
ARCHIVE_SHA1 = "992b5ca87b3404894f013e59a43efbb8b1bc012b"


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def read_json(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return {}


def digest(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as file:
        for block in iter(lambda: file.read(4 * 1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


class Progress:
    def __init__(self, path, archive, data):
        self.path = Path(path)
        self.value = {"status": "running", "startedAt": now(), "pid": os.getpid(),
                      "archive": str(Path(archive).resolve()), "dataDirectory": str(Path(data).resolve())}

    def update(self, **fields):
        self.value.update(fields, updatedAt=now())
        corpus.save_json(self.path, self.value)


def verified_archive(archive, download_status):
    state = read_json(download_status)
    archive = Path(archive).resolve()
    if (state.get("status") != "verified" or Path(state.get("path", "")).resolve() != archive
            or state.get("expectedBytes") != ARCHIVE_BYTES or state.get("expectedSHA1") != ARCHIVE_SHA1
            or archive.name != ARCHIVE_NAME or archive.stat().st_size != ARCHIVE_BYTES):
        raise RuntimeError("Prose extraction requires the exact verified full 20261001 English archive")
    return state


def open_stage(data):
    data = Path(data)
    data.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(data / "prose-stage.sqlite")
    db.executescript("""PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS narrative_events(id TEXT PRIMARY KEY,page_id TEXT,payload TEXT NOT NULL,links TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS narrative_page ON narrative_events(page_id);
        CREATE TABLE IF NOT EXISTS extraction_checkpoint(key TEXT PRIMARY KEY,value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS sentence_vectors(signature TEXT PRIMARY KEY,model TEXT,embedding TEXT);
        CREATE TABLE IF NOT EXISTS embedding_events(id TEXT PRIMARY KEY,signature TEXT,payload TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS embedding_signature ON embedding_events(signature);
    """)
    return db


def source_fingerprint(archive, max_pages=None):
    import narrative
    info = Path(archive).stat()
    return json.dumps([str(Path(archive).resolve()), info.st_size, info.st_mtime_ns,
                       digest(narrative.__file__), digest(__file__), max_pages])


def extract_dump(stage, archive, data, progress, max_pages=None):
    from narrative import extract_narrative_events, has_date_candidates
    fingerprint = source_fingerprint(archive, max_pages)
    record = stage.execute("SELECT value FROM extraction_checkpoint WHERE key='progress'").fetchone()
    checkpoint = json.loads(record[0]) if record else {}
    if checkpoint.get("fingerprint") != fingerprint:
        stage.execute("DELETE FROM narrative_events")
        stage.execute("DELETE FROM embedding_events")
        checkpoint = {"fingerprint": fingerprint, "scannedPages": 0, "articlePages": 0,
                      "extractedMentions": 0, "complete": False, "limited": max_pages is not None}
        stage.commit()
    if checkpoint.get("complete"):
        progress.update(phase="extractionComplete", **{k: checkpoint[k] for k in
                        ("scannedPages", "articlePages", "extractedMentions", "limited")})
        return checkpoint
    resume_after = checkpoint["scannedPages"]
    scanned = 0
    article_pages = checkpoint["articlePages"]
    mentions = checkpoint["extractedMentions"]
    namespace = "{http://www.mediawiki.org/xml/export-0.11/}"
    started = time.monotonic()
    with contextlib.ExitStack() as stack:
        raw = stack.enter_context(Path(archive).open("rb"))
        source = stack.enter_context(bz2.BZ2File(raw, "rb")) if str(archive).endswith(".bz2") else raw
        context = ET.iterparse(source, events=("start", "end"))
        _, xml_root = next(context)
        for action, page in context:
            if action != "end" or page.tag != namespace + "page":
                continue
            scanned += 1
            if scanned > resume_after and page.findtext(namespace + "ns") == "0" and page.find(namespace + "redirect") is None:
                article_pages += 1
                title = page.findtext(namespace + "title", "")
                page_id = page.findtext(namespace + "id", "")
                revision = page.find(namespace + "revision")
                revision_id = revision.findtext(namespace + "id", "") if revision is not None else ""
                text = revision.findtext(namespace + "text", "") if revision is not None else ""
                year_article = re.fullmatch(r"\d{1,4}(?:\s+(?:BC|BCE|AD|CE))?", title, re.I)
                if revision_id and (has_date_candidates(text) or year_article):
                    for event in extract_narrative_events(title, page_id, revision_id, text):
                        links = event.pop("links", event.get("provenance", {}).get("links", []))
                        section = event["provenance"].get("sectionAnchor", event["provenance"]["section"].split(" / ")[-1])
                        if section:
                            parts = urllib.parse.urlsplit(event["url"])
                            event["url"] = urllib.parse.urlunsplit((parts.scheme, parts.netloc, parts.path, parts.query,
                                urllib.parse.quote(section.replace(" ", "_"), safe="_:")))
                        stage.execute("INSERT OR IGNORE INTO narrative_events VALUES(?,?,?,?)",
                                      (event["id"], page_id, json.dumps(event, ensure_ascii=False), json.dumps(links)))
                        mentions += stage.execute("SELECT changes()").fetchone()[0]
            page.clear()
            xml_root.clear()
            if scanned % 2000 == 0 and scanned > resume_after:
                checkpoint.update(scannedPages=scanned, articlePages=article_pages, extractedMentions=mentions)
                stage.execute("INSERT OR REPLACE INTO extraction_checkpoint VALUES('progress',?)", (json.dumps(checkpoint),))
                stage.commit()
                progress.update(phase="extracting", scannedPages=scanned, articlePages=article_pages,
                                extractedMentions=mentions, readBytes=raw.tell(), sourceBytes=Path(archive).stat().st_size,
                                elapsedSeconds=round(time.monotonic() - started, 1), limited=max_pages is not None)
            if max_pages and scanned >= max_pages:
                break
    checkpoint.update(scannedPages=scanned, articlePages=article_pages, extractedMentions=mentions, complete=True)
    stage.execute("INSERT OR REPLACE INTO extraction_checkpoint VALUES('progress',?)", (json.dumps(checkpoint),))
    stage.commit()
    corpus.save_json(Path(data) / "extraction.json", checkpoint)
    progress.update(phase="extractionComplete", scannedPages=scanned, articlePages=article_pages,
                    extractedMentions=mentions, limited=max_pages is not None)
    return checkpoint


def wait_for_base(archive, progress, data_root=ROOT / "Data"):
    while True:
        state = read_json(data_root / "ingest-status.json")
        validation = read_json(data_root / "validation-status.json")
        same = Path(state.get("path", "")).resolve() == Path(archive).resolve()
        if same and state.get("status") == "complete" and state.get("validation") == "passed" and validation.get("status") == "passed":
            return data_root / "atlas.sqlite"
        if same and state.get("status") in ("failed", "paused", "error"):
            progress.update(status="waiting", phase="waitingForBase", baseStatus=state.get("status"),
                            detail="Current infobox job needs recovery before expanded export; prose extraction is preserved")
        else:
            progress.update(status="waiting", phase="waitingForBase", baseStatus=state.get("status"), basePhase=state.get("phase"))
        time.sleep(30)


def revision_url(url, revision, section=""):
    parts = urllib.parse.urlsplit(url)
    query = urllib.parse.parse_qsl(parts.query, keep_blank_values=True)
    query = [(k, v) for k, v in query if k != "oldid"] + [("oldid", str(revision))]
    fragment = urllib.parse.quote(section.replace(" ", "_"), safe="_:") if section else parts.fragment
    return urllib.parse.urlunsplit((parts.scheme, parts.netloc, parts.path, urllib.parse.urlencode(query), fragment))


def sentence_edges(event, links, lookup):
    provenance = event["provenance"]
    for title in sorted(set(links)):
        target = lookup(title.replace("_", " ").split("#", 1)[0])
        if target and target != event["id"]:
            evidence = (revision_url(event["url"], event["revision"], provenance.get("sectionAnchor", provenance["section"].split(" / ")[-1]))
                        + "; source sentence hyperlink to " + title + "; quoted passage: " + provenance["quote"])
            yield (event["id"], target, "wikiLink", "source sentence mentions", evidence, 1.0)


def canonical_mapping(db):
    db.execute("CREATE TABLE IF NOT EXISTS canonical_article_events(title TEXT PRIMARY KEY,event_id TEXT)")
    structured, prose = 0, 0
    for identifier, title, url, payload in db.execute("SELECT id,title,url,payload FROM events"):
        if (json.loads(payload).get("provenance") or {}).get("method") == "datedProse":
            prose += 1
            continue
        structured += 1
        article = urllib.parse.unquote(urllib.parse.urlsplit(url).path.removeprefix("/wiki/")).replace("_", " ")
        for alias in {article, title}:
            db.execute("""INSERT INTO canonical_article_events VALUES(?,?)
                ON CONFLICT(title) DO UPDATE SET event_id=CASE
                WHEN canonical_article_events.event_id=excluded.event_id THEN excluded.event_id ELSE NULL END""", (alias, identifier))
    return structured, prose


def embed_mentions(stage, data, model, progress):
    scalable.recover_vectors(stage, Path(data) / "raw/full-embeddings.jsonl")
    stage.execute("DELETE FROM embedding_events")
    for identifier, payload in stage.execute("SELECT id,payload FROM narrative_events ORDER BY id"):
        event = json.loads(payload)
        stage.execute("INSERT INTO embedding_events VALUES(?,?,?)", (identifier, scalable.signature(event, model), payload))
    stage.commit()
    total = stage.execute("SELECT count(*) FROM embedding_events").fetchone()[0]
    # Rebuild only the remaining work once on resume. Never rescan all completed
    # mentions or recount their joins for every 512-record embedding batch.
    stage.execute("DROP TABLE IF EXISTS pending_embeddings")
    stage.execute("CREATE TABLE pending_embeddings(id TEXT PRIMARY KEY,signature TEXT NOT NULL)")
    stage.execute("CREATE INDEX pending_embedding_signature ON pending_embeddings(signature)")
    stage.execute("""INSERT INTO pending_embeddings SELECT e.id,e.signature FROM embedding_events e
        LEFT JOIN sentence_vectors v ON v.signature=e.signature AND v.model=? WHERE v.signature IS NULL""", (model,))
    remaining = stage.execute("SELECT count(*) FROM pending_embeddings").fetchone()[0]
    done = total - remaining
    stage.commit()
    while True:
        rows = stage.execute("""SELECT p.signature,e.payload FROM pending_embeddings p
            JOIN embedding_events e ON e.id=p.id ORDER BY p.id LIMIT 512""").fetchall()
        if not rows:
            break
        records = [{"id": key, "title": (event := json.loads(payload))["title"], "summary": event["summary"]} for key, payload in rows]
        scalable.embedding_batch(stage, records, data, model)
        for signature in {key for key, _ in rows}:
            stage.execute("DELETE FROM pending_embeddings WHERE signature=?", (signature,))
            done += stage.execute("SELECT changes()").fetchone()[0]
        stage.commit()
        progress.update(status="running", phase="embedding", embeddedMentions=done, proseMentions=total)
    stage.execute("DROP TABLE pending_embeddings")
    stage.commit()
    return total


def build_expanded(stage, base_path, data, checkpoint, progress, *, embedder=embed_mentions):
    data = Path(data)
    data.mkdir(parents=True, exist_ok=True)
    base_path = Path(base_path).resolve()
    base = sqlite3.connect("file:" + str(base_path) + "?mode=ro", uri=True)
    metadata = {k: json.loads(v) for k, v in base.execute("SELECT key,value FROM metadata")}
    model = metadata["embeddingModel"]
    base_count = base.execute("SELECT count(*) FROM events").fetchone()[0]
    prose_count = embedder(stage, data, model, progress)
    progress.update(status="running", phase="indexing", baseEvents=base_count, proseMentions=prose_count)
    building = data / "atlas-building.sqlite"
    for suffix in ("", "-wal", "-shm"):
        Path(str(building) + suffix).unlink(missing_ok=True)
    db = sqlite3.connect(building)
    base.backup(db)
    base.close()
    corpus.create_store_schema(db)
    db.execute("CREATE UNIQUE INDEX IF NOT EXISTS edges_identity ON edges(source,target,kind,label)")
    structured_count, base_prose_count = canonical_mapping(db)
    db.commit()
    planes = corpus.lsh_planes(metadata.get("embeddingDimensions", 512))
    added = 0
    def lookup(title):
        row = db.execute("SELECT event_id FROM canonical_article_events WHERE title=?", (title,)).fetchone()
        return row[0] if row else None
    for payload, links, vector in stage.execute("""SELECT e.payload,n.links,v.embedding FROM embedding_events e
        JOIN narrative_events n ON n.id=e.id JOIN sentence_vectors v ON v.signature=e.signature AND v.model=? ORDER BY e.id""", (model,)):
        event = json.loads(payload)
        event["embedding"] = json.loads(vector)
        existing = db.execute("SELECT payload FROM events WHERE id=?", (event["id"],)).fetchone()
        if existing:
            old = json.loads(existing[0])
            if {k: v for k, v in old.items() if k != "embedding"} != {k: v for k, v in event.items() if k != "embedding"}:
                raise RuntimeError("Conflicting source record for stable ID " + event["id"])
        else:
            corpus.insert_store_event(db, event, planes)
            added += 1
        db.executemany("INSERT OR IGNORE INTO edges VALUES(?,?,?,?,?,?)", sentence_edges(event, json.loads(links), lookup))
        if added and added % 1000 == 0:
            db.commit()
            progress.update(phase="indexing", indexedMentions=added, proseMentions=prose_count)
    count = db.execute("SELECT count(*) FROM events").fetchone()[0]
    edge_count = db.execute("SELECT count(*) FROM edges").fetchone()[0]
    documented = db.execute("SELECT count(*) FROM edges WHERE kind!='semantic'").fetchone()[0]
    total_prose = base_prose_count + added
    coverage = (f"{count:,} sourced dated records: {structured_count:,} structured event records and {total_prose:,} article-prose statements; "
                f"{checkpoint['scannedPages']:,} pages scanned from {ARCHIVE_NAME}. Explicit date and action rules plus heading and calendar-article context. "
                "Prose statements retain exact source passages and may describe the same historical event in different articles; "
                "these are not globally resolved unique events. Implicit dates, unsupported syntax and some events remain unextracted.")
    metadata.update(eventCount=count, edgeCount=edge_count, documentedEdgeCount=documented, coverage=coverage, generatedAt=now(),
                    structuredEventCount=structured_count, narrativeStatementCount=total_prose,
                    proseExtraction={"method": "datedProse", "scannedPages": checkpoint["scannedPages"],
                        "articlePages": checkpoint["articlePages"], "parserSHA256": digest(ROOT / "Tools/narrative.py"),
                        "archiveSHA1": ARCHIVE_SHA1, "baseIndexSHA256": digest(base_path), "limited": checkpoint.get("limited", False)})
    db.executemany("INSERT OR REPLACE INTO metadata VALUES(?,?)", ((k, json.dumps(v)) for k, v in metadata.items()))
    # Lookup tables are build-only; never leave an article-to-arbitrary-statement map in the portable app index.
    db.execute("DROP TABLE canonical_article_events")
    corpus.finish_store(db)
    progress.update(phase="validating", totalEvents=count, totalEdges=edge_count)
    validation = validate_sqlite(building)
    validate_provenance(building, total_prose)
    building.replace(data / "atlas.sqlite")
    corpus.save_json(data / "validation-status.json", {**validation, "proseStatementsChecked": total_prose, "validatedAt": now()})
    corpus.save_json(data / "catalog-status.json", {"events": count, "edges": edge_count, "structuredEvents": structured_count,
                     "narrativeStatements": total_prose, "newNarrativeStatements": added, "coverage": coverage, "generatedAt": metadata["generatedAt"]})
    progress.update(status="complete", phase="complete", validation="passed", totalEvents=count, totalEdges=edge_count,
                    structuredEvents=structured_count, narrativeStatements=total_prose, newNarrativeStatements=added, output=str(data / "atlas.sqlite"),
                    limited=checkpoint.get("limited", False), completedAt=now())
    return validation


def validate_provenance(path, expected):
    db = sqlite3.connect("file:" + str(Path(path).resolve()) + "?mode=ro", uri=True)
    checked = 0
    try:
        for (payload,) in db.execute("SELECT payload FROM events"):
            event = json.loads(payload)
            provenance = event.get("provenance") or {}
            if not event["id"].startswith("NP") and provenance.get("method") != "datedProse":
                continue
            assert re.fullmatch(r"NP[0-9a-f]{28}", event["id"]), "Prose event must retain a valid stable identity"
            for key in ("articleTitle", "pageID", "revisionID", "section", "quote", "dateText", "dateBasis", "confidence"):
                assert isinstance(provenance[key], str), key
            assert provenance["method"] == "datedProse" and provenance["quote"] and provenance["dateText"]
            assert provenance["revisionID"] == event["revision"]
            assert provenance["pageID"].isdigit() and int(provenance["pageID"]) > 0
            assert provenance["revisionID"].isdigit() and int(provenance["revisionID"]) > 0
            assert provenance["articleTitle"]
            assert provenance["dateBasis"] in ("explicit", "sectionYear", "articleYear", "articleDay")
            confidence = {"explicit": "explicitDate", "articleDay": "contextualDate"}.get(provenance["dateBasis"], "contextualYear")
            assert provenance["confidence"] == confidence
            assert event["summary"] == provenance["quote"], "Displayed claim must match the recorded passage"
            normalized = unicodedata.normalize("NFC", " ".join(provenance["quote"].casefold().split()))
            identity = provenance["pageID"] + "\0" + normalized + "\0" + repr((event["start"], event["end"], event["precision"]))
            assert event["id"] == "NP" + hashlib.sha256(identity.encode()).hexdigest()[:28], "Unstable prose identity"
            checked += 1
        assert checked == expected, (checked, expected)
    finally:
        db.close()


def validate_output_paths(data, status, base_index=None):
    data, status = Path(data).resolve(), Path(status).resolve()
    original = (ROOT / "Data").resolve()
    reserved = (original / "raw", original / "downloads")
    if data == original or any(data == path or path in data.parents for path in reserved):
        raise RuntimeError("Prose output must use its own data directory outside the active original job's files")
    protected = {original / name for name in ("download-status.json", "ingest-status.json", "validation-status.json",
                  "catalog-status.json", "native-refresh-status.json", "phone-update-status.json")}
    own_artifacts = {data / name for name in ("extraction.json", "catalog-status.json", "validation-status.json")}
    if (status.suffix != ".json" or status in protected or status in own_artifacts
            or any(status == path or path in status.parents for path in reserved)):
        raise RuntimeError("Prose status cannot overwrite an original pipeline or deployment status")
    if base_index and Path(base_index).resolve() == data / "atlas.sqlite":
        raise RuntimeError("The prose output cannot replace its own source base index")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("run", "extract", "build"))
    parser.add_argument("--archive", type=Path, default=ROOT / "Data/downloads" / ARCHIVE_NAME)
    parser.add_argument("--data-dir", type=Path, default=ROOT / "Data/narrative")
    parser.add_argument("--status", type=Path, default=ROOT / "Data/narrative-status.json")
    parser.add_argument("--base-index", type=Path)
    parser.add_argument("--max-pages", type=int)
    args = parser.parse_args()
    validate_output_paths(args.data_dir, args.status, args.base_index)
    args.data_dir.mkdir(parents=True, exist_ok=True)
    progress = Progress(args.status, args.archive, args.data_dir)
    with (args.data_dir / "pipeline.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit("A prose pipeline already owns this data directory; no duplicate was started")
        stage = open_stage(args.data_dir)
        try:
            verified_archive(args.archive, ROOT / "Data/download-status.json")
            progress.update(phase="starting", parserSHA256=digest(ROOT / "Tools/narrative.py"))
            checkpoint = extract_dump(stage, args.archive, args.data_dir, progress, args.max_pages)
            if args.command != "extract":
                if checkpoint.get("limited"):
                    raise RuntimeError("A bounded extraction is a QA sample; use a separate data directory for full export")
                base = args.base_index or wait_for_base(args.archive, progress)
                build_expanded(stage, base, args.data_dir, checkpoint, progress)
            else:
                progress.update(status="extracted", phase="extractionComplete")
        except BaseException as error:
            progress.update(status="paused" if isinstance(error, KeyboardInterrupt) else "failed",
                            error=type(error).__name__ + ": " + str(error))
            raise
        finally:
            stage.close()


if __name__ == "__main__":
    main()
