"""Bounded-memory validation of a completed portable Chronoscope index."""
import argparse
import json
import math
from pathlib import Path
import sqlite3
from corpus import vector_buckets, lsh_planes


def validate_sqlite(path):
    path = Path(path)
    with path.open("rb") as file:
        header = file.read(20)
    assert header[:16] == b"SQLite format 3\x00" and header[18:20] == b"\x01\x01", "Nonportable SQLite header"
    db = sqlite3.connect("file:" + str(path.resolve()) + "?mode=ro", uri=True)
    try:
        assert db.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
        metadata = {key: json.loads(value) for key, value in db.execute("SELECT key,value FROM metadata")}
        count = db.execute("SELECT count(*) FROM events").fetchone()[0]
        edge_count = db.execute("SELECT count(*) FROM edges").fetchone()[0]
        documented = db.execute("SELECT count(*) FROM edges WHERE kind!='semantic'").fetchone()[0]
        assert count > 0 and metadata["schemaVersion"] == 1
        assert metadata["eventCount"] == count and metadata["edgeCount"] == edge_count
        assert metadata["documentedEdgeCount"] == documented
        assert metadata["lshVersion"] == "sparse-xorshift32-v1-16x8x8"
        assert db.execute("SELECT count(*) FROM events_fts").fetchone()[0] == count
        assert not db.execute("SELECT 1 FROM events_fts f LEFT JOIN events e ON e.id=f.id WHERE e.id IS NULL LIMIT 1").fetchone()
        assert not db.execute("SELECT 1 FROM vector_buckets GROUP BY event_id HAVING count(*)!=16 LIMIT 1").fetchone()
        assert db.execute("SELECT count(*) FROM vector_buckets").fetchone()[0] == count * 16
        dimensions = None
        planes = None
        for identifier, payload in db.execute("SELECT id,payload FROM events ORDER BY id"):
            event = json.loads(payload)
            assert event["id"] == identifier and isinstance(event["title"], str) and event["title"]
            assert isinstance(event["summary"], str) and event["url"].startswith("https://en.wikipedia.org/wiki/")
            assert math.isfinite(event["start"]) and math.isfinite(event["end"]) and event["start"] <= event["end"]
            for key, bound in (("latitude", 90), ("longitude", 180)):
                assert event[key] is None or (math.isfinite(event[key]) and abs(event[key]) <= bound)
            vector = event["embedding"]
            dimensions = dimensions or len(vector)
            assert dimensions > 0 and len(vector) == dimensions and all(math.isfinite(v) for v in vector)
            assert abs(math.sqrt(sum(v * v for v in vector)) - 1) < 0.0001, identifier
            planes = planes or lsh_planes(dimensions)
            actual = [row[0] for row in db.execute("SELECT bucket FROM vector_buckets WHERE event_id=? ORDER BY bucket", (identifier,))]
            assert actual == vector_buckets(vector, planes), "LSH mismatch: " + identifier
        assert not db.execute("SELECT 1 FROM edges e LEFT JOIN events s ON s.id=e.source LEFT JOIN events t ON t.id=e.target WHERE s.id IS NULL OR t.id IS NULL OR e.source=e.target LIMIT 1").fetchone()
        assert not db.execute("SELECT 1 FROM edges WHERE kind NOT IN ('wikiLink','wikidata','semantic') OR label IS NULL OR label='' OR evidence IS NULL OR evidence='' OR score IS NULL OR score<0 OR score>1 LIMIT 1").fetchone()
        semantic_checked = 0
        for source, target, score, evidence in db.execute("SELECT source,target,score,evidence FROM edges WHERE kind='semantic'"):
            assert math.isfinite(score) and "not a documented historical relationship" in evidence
            a = json.loads(db.execute("SELECT payload FROM events WHERE id=?", (source,)).fetchone()[0])["embedding"]
            b = json.loads(db.execute("SELECT payload FROM events WHERE id=?", (target,)).fetchone()[0])["embedding"]
            cosine = sum(x * y for x, y in zip(a, b)) / math.sqrt(sum(x*x for x in a) * sum(y*y for y in b))
            assert abs(score - cosine) < 0.00002
            semantic_checked += 1
        return {"status": "passed", "events": count, "edges": edge_count, "documentedEdges": documented,
                "dimensions": dimensions, "lshVectorsChecked": count, "semanticCosinesChecked": semantic_checked,
                "bytes": path.stat().st_size, "coverage": metadata["coverage"]}
    finally:
        db.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path)
    print(json.dumps(validate_sqlite(parser.parse_args().path), indent=2))
