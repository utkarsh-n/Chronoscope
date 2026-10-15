#!/usr/bin/env python3
"""Bounded catalog integrity and corpus-provenance checks."""
import argparse
import json
import math
from collections import Counter
from pathlib import Path


def validate(path):
    catalog = json.loads(path.read_text())
    events, edges = catalog["events"], catalog["edges"]
    assert catalog["schemaVersion"] == 1
    assert events, "Catalog has no events"
    ids = {e["id"] for e in events}
    assert len(ids) == len(events), "Duplicate event IDs"
    dims = {len(e["embedding"]) for e in events}
    assert len(dims) == 1 and next(iter(dims)) > 0, "Invalid embedding dimensions"
    for event in events:
        assert event["start"] <= event["end"], event["title"]
        assert all(math.isfinite(v) for v in [event["start"], event["end"], *event["embedding"]])
        norm = math.sqrt(sum(v * v for v in event["embedding"]))
        assert abs(norm - 1) < 0.0001, (event["title"], norm)
        assert event["url"].startswith("https://en.wikipedia.org/wiki/"), event["title"]
        if event["latitude"] is not None:
            assert -90 <= event["latitude"] <= 90
            assert event["longitude"] is not None and -180 <= event["longitude"] <= 180
    for edge in edges:
        assert edge["source"] in ids and edge["target"] in ids
        assert edge["source"] != edge["target"]
        assert edge["kind"] in {"wikiLink", "wikidata", "semantic"}
        assert edge["evidence"] and edge["label"]
        assert math.isfinite(edge["score"])
        if edge["kind"] == "semantic":
            assert "not a documented historical relationship" in edge["evidence"]
    result = {"events": len(events), "edges": len(edges), "dimensions": next(iter(dims)),
              "categories": dict(Counter(e["category"] for e in events)),
              "edgeKinds": dict(Counter(e["kind"] for e in edges)),
              "coordinates": sum(e["latitude"] is not None for e in events),
              "earliest": min(e["start"] for e in events), "latest": max(e["end"] for e in events),
              "coverage": catalog["coverage"], "status": "passed"}
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path)
    validate(parser.parse_args().path)
