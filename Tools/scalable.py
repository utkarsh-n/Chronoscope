"""Streaming full-corpus export, durable sentence-vector cache and validation."""
import datetime as dt
import hashlib
import json
import math
from pathlib import Path
import sqlite3
import subprocess
import sys
import urllib.parse
import corpus


def signature(event, model):
    return hashlib.sha256((model + "\0" + event["title"] + "\0" + event["summary"]).encode()).hexdigest()


def recover_vectors(stage, output):
    """Commit complete NDJSON records, including a prefix left by interruption."""
    if not output.exists() or not output.stat().st_size:
        return None
    with output.open() as file:
        first = next(file, "")
        if not first.endswith("\n"):
            return None
        metadata = json.loads(first)
        for line in file:
            if not line.endswith("\n"):
                break
            record = json.loads(line)
            vector = record["embedding"]
            assert len(vector) == metadata["dimensions"] and all(math.isfinite(v) for v in vector)
            assert abs(math.sqrt(sum(v*v for v in vector)) - 1) < 0.0001
            stage.execute("INSERT OR REPLACE INTO sentence_vectors VALUES(?,?,?)",
                          (record["id"], metadata["model"], json.dumps(vector, separators=(",", ":"))))
    stage.commit()
    return metadata


def embedding_batch(stage, records, data, expected_model=None):
    raw = data / "raw"
    raw.mkdir(parents=True, exist_ok=True)
    input_path, output_path = raw / "full-embedding-input.jsonl", raw / "full-embeddings.jsonl"
    with input_path.open("w") as file:
        for record in records:
            file.write(json.dumps(record, ensure_ascii=False) + "\n")
    process = subprocess.Popen(["swift", "-module-cache-path", "/private/tmp/chronoscope-swift-module-cache",
                                str(corpus.ROOT / "Tools/embed.swift"), str(input_path), str(output_path), "--jsonl"])
    try:
        if process.wait() != 0:
            raise RuntimeError("Sentence embedding batch failed")
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait()
    metadata = recover_vectors(stage, output_path)
    if expected_model is not None and metadata["model"] != expected_model:
        raise RuntimeError("Sentence embedding model changed during export")
    for record in records:
        if not stage.execute("SELECT 1 FROM sentence_vectors WHERE signature=? AND model=?", (record["id"], metadata["model"])).fetchone():
            raise RuntimeError("Embedding batch omitted record " + record["id"])
    return metadata


def source_edges(source_id, url, revision, links, title_ids):
    if not source_id or not revision:
        return
    for title in sorted(set(links)):
        target = title_ids.get(title)
        if target and target != source_id:
            yield (source_id, target, "wikiLink", "article links to", url + "?oldid=" + str(revision) + "; hyperlink to " + title, 1.0)


def prepare_events(stage, seed, model):
    stage.executescript("DROP TABLE IF EXISTS build_events; CREATE TABLE build_events(id TEXT PRIMARY KEY,title TEXT UNIQUE,start REAL,signature TEXT,payload TEXT);")
    for event in seed["events"]:
        key = signature(event, model)
        if seed["embeddingModel"] == model and len(event.get("embedding", [])):
            stage.execute("INSERT OR REPLACE INTO sentence_vectors VALUES(?,?,?)", (key, model, json.dumps(event["embedding"], separators=(",", ":"))))
        bare = {**event, "embedding": []}
        stage.execute("INSERT INTO build_events VALUES(?,?,?,?,?)", (event["id"], event["title"], event["start"], key, json.dumps(bare)))
    for (raw,) in stage.execute("SELECT event FROM article_events ORDER BY id"):
        event = json.loads(raw)
        existing = stage.execute("SELECT id FROM build_events WHERE title=?", (event["title"],)).fetchone()
        if existing is None:
            stage.execute("INSERT INTO build_events VALUES(?,?,?,?,?)", (event["id"], event["title"], event["start"], signature(event, model), raw))
        elif existing[0] == event["id"]:
            stage.execute("UPDATE build_events SET start=?,signature=?,payload=? WHERE id=?", (event["start"], signature(event, model), raw, event["id"]))
    stage.execute("CREATE INDEX build_events_time ON build_events(start,title)")
    stage.commit()
    return stage.execute("SELECT count(*) FROM build_events").fetchone()[0]


def bundle_from_store(path, metadata, limit=3500):
    db = sqlite3.connect("file:" + str(path.resolve()) + "?mode=ro", uri=True)
    try:
        count = db.execute("SELECT count(*) FROM events").fetchone()[0]
        if count <= limit:
            ids = {row[0] for row in db.execute("SELECT id FROM events")}
        else:
            ids = {row[0] for row in db.execute("SELECT id FROM events WHERE id LIKE 'Q%' ORDER BY start,title LIMIT ?", (limit,))}
            remaining = limit - len(ids)
            candidates = db.execute("SELECT count(*) FROM events WHERE id NOT LIKE 'Q%'").fetchone()[0]
            offsets = {int(index * candidates / remaining) for index in range(remaining)} if remaining else set()
            for index, (identifier,) in enumerate(db.execute("SELECT id FROM events WHERE id NOT LIKE 'Q%' ORDER BY start,title")):
                if index in offsets:
                    ids.add(identifier)
        db.execute("CREATE TEMP TABLE bundle_ids(id TEXT PRIMARY KEY)")
        db.executemany("INSERT INTO bundle_ids VALUES(?)", ((identifier,) for identifier in ids))
        events = [json.loads(row[0]) for row in db.execute("SELECT e.payload FROM events e JOIN bundle_ids b ON e.id=b.id ORDER BY e.start,e.title")]
        keys = ("source", "target", "kind", "label", "evidence", "score")
        edges = [dict(zip(keys, row)) for row in db.execute("SELECT e.source,e.target,e.kind,e.label,e.evidence,e.score FROM edges e JOIN bundle_ids s ON s.id=e.source JOIN bundle_ids t ON t.id=e.target WHERE e.kind!='semantic'")]
        edges.extend(corpus.semantic_edges(events))
        coverage = f"Bounded bundle: {len(events):,} of {count:,} indexed dated event articles, sampled across epochs with structured anchors. Import Data/atlas.sqlite for the full extracted index. " + metadata["coverage"]
        return {key: metadata[key] for key in ("schemaVersion", "generatedAt", "embeddingModel")} | {"coverage": coverage, "events": events, "edges": edges}
    finally:
        db.close()


def export_staged(stage, seed, wiki, data, catalog_path, path, scanned, extracted):
    from validate_sqlite import validate_sqlite
    data, catalog_path = Path(data), Path(catalog_path)
    stage.execute("CREATE TABLE IF NOT EXISTS sentence_vectors(signature TEXT PRIMARY KEY,model TEXT,embedding TEXT)")
    stage.commit()
    recover_vectors(stage, data / "raw/full-embeddings.jsonl")
    model_info = embedding_batch(stage, [], data)
    model = model_info["model"]
    count = prepare_events(stage, seed, model)
    state = {"path": str(path), "scannedPages": scanned, "extractedEvents": extracted, "catalogEvents": count,
             "status": "running", "phase": "embedding", "embeddingModel": model}
    corpus.save_json(data / "ingest-status.json", state)
    while True:
        rows = stage.execute("SELECT e.signature,e.payload FROM build_events e LEFT JOIN sentence_vectors v ON v.signature=e.signature AND v.model=? WHERE v.signature IS NULL ORDER BY e.id LIMIT 512", (model,)).fetchall()
        if not rows:
            break
        records = [{"id": key, "title": (event := json.loads(raw))["title"], "summary": event["summary"]} for key, raw in rows]
        embedding_batch(stage, records, data, model)
        done = stage.execute("SELECT count(*) FROM build_events e JOIN sentence_vectors v ON e.signature=v.signature AND v.model=?", (model,)).fetchone()[0]
        state.update(embeddedEvents=done, updatedAt=dt.datetime.now(dt.timezone.utc).isoformat())
        corpus.save_json(data / "ingest-status.json", state)
        corpus.log("Sentence vectors checkpointed", done, "/", count)
    state.update(phase="indexing", embeddedEvents=count)
    corpus.save_json(data / "ingest-status.json", state)
    building = data / "atlas-building.sqlite"
    for suffix in ("", "-wal", "-shm"):
        candidate = Path(str(building) + suffix)
        if candidate.exists(): candidate.unlink()
    db = sqlite3.connect(building)
    corpus.create_store_schema(db)
    db.execute("CREATE UNIQUE INDEX edges_identity ON edges(source,target,kind,label)")
    db.execute("BEGIN IMMEDIATE")
    planes = corpus.lsh_planes(model_info["dimensions"])
    title_ids = {}
    for raw, embedding in stage.execute("SELECT e.payload,v.embedding FROM build_events e JOIN sentence_vectors v ON e.signature=v.signature AND v.model=? ORDER BY e.start,e.title", (model,)):
        event = json.loads(raw); event["embedding"] = json.loads(embedding)
        corpus.insert_store_event(db, event, planes)
        title_ids[event["title"]] = event["id"]
        title = urllib.parse.unquote(urllib.parse.urlparse(event["url"]).path.removeprefix("/wiki/")).replace("_", " ")
        title_ids[title] = event["id"]
    edge_sql = "INSERT OR IGNORE INTO edges VALUES(?,?,?,?,?,?)"
    all_ids = set(title_ids.values())
    for edge in seed["edges"]:
        if edge["kind"] == "wikidata" and edge["source"] in all_ids and edge["target"] in all_ids:
            db.execute(edge_sql, [edge[key] for key in ("source", "target", "kind", "label", "evidence", "score")])
    for title, page in wiki.items():
        revisions = page.get("revisions", [])
        if not revisions: continue
        revision = revisions[0]
        content = revision.get("slots", {}).get("main", {}).get("content", "")
        links = {link["title"] for link in page.get("links", [])}
        links.update(corpus.re.findall(r"\[\[([^\]|#]+)", content))
        url = "https://en.wikipedia.org/wiki/" + urllib.parse.quote(title.replace(" ", "_"))
        db.executemany(edge_sql, source_edges(title_ids.get(title), url, revision.get("revid"), links, title_ids))
    for raw, links in stage.execute("SELECT event,links FROM article_events ORDER BY id"):
        event = json.loads(raw)
        db.executemany(edge_sql, source_edges(title_ids.get(event["title"]), event["url"], event["revision"], json.loads(links), title_ids))
    edge_count = db.execute("SELECT count(*) FROM edges").fetchone()[0]
    coverage = f"{count:,} dated event articles; {scanned:,} pages scanned from {Path(path).name}. Strict event infobox extraction plus Wikidata bootstrap; incomplete historical coverage."
    metadata = {"schemaVersion": 1, "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(), "coverage": coverage,
                "embeddingModel": model, "eventCount": count, "edgeCount": edge_count, "documentedEdgeCount": edge_count,
                "lshVersion": "sparse-xorshift32-v1-16x8x8"}
    db.executemany("INSERT INTO metadata VALUES(?,?)", ((key, json.dumps(value)) for key, value in metadata.items()))
    corpus.finish_store(db)
    state.update(phase="validating")
    corpus.save_json(data / "ingest-status.json", state)
    validation = validate_sqlite(building)
    bundle = bundle_from_store(building, metadata)
    bundle_path = catalog_path.with_suffix(".validated.json")
    corpus.save_catalog(bundle_path, bundle)
    subprocess.run([sys.executable, str(corpus.ROOT / "Tools/validate_catalog.py"), str(bundle_path)], check=True)
    # Publish only after both artifacts validate; an interrupted build leaves
    # the previous portable atlas and bundle usable.
    building.replace(data / "atlas.sqlite")
    bundle_path.replace(catalog_path)
    corpus.save_json(data / "validation-status.json", {**validation, "bundleEvents": len(bundle["events"]), "bundleEdges": len(bundle["edges"]), "validatedAt": dt.datetime.now(dt.timezone.utc).isoformat()})
    stats = {"events": count, "edges": edge_count, "bundledEvents": len(bundle["events"]), "bundledEdges": len(bundle["edges"]),
             "embeddingDimensions": model_info["dimensions"], "model": model, "coverage": coverage, "bundleCoverage": bundle["coverage"],
             "generatedAt": metadata["generatedAt"], "catalogBytes": catalog_path.stat().st_size}
    corpus.save_json(data / "catalog-status.json", stats)
    state.update(status="complete", phase="complete", edges=edge_count, bundledEvents=len(bundle["events"]),
                 validation="passed", completedAt=dt.datetime.now(dt.timezone.utc).isoformat())
    corpus.save_json(data / "ingest-status.json", state)
    corpus.log("Full index validated and exported", stats)
    return stats
