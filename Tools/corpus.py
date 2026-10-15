#!/usr/bin/env python3
"""Resumable Wikimedia downloads, sourced event extraction and native embeddings.

Only Python's standard library, system curl and Apple's NaturalLanguage are needed.
Network requests are sequential; a concurrent bulk download adds one connection.
"""
import argparse
import bz2
import calendar
import contextlib
import datetime as dt
import hashlib
import html
import json
import math
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import sys
import time
import urllib.parse
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "Data"
RAW = DATA / "raw"
CACHE = RAW / "cache"
CATALOG = ROOT / "App/Resources/catalog.json"
AGENT = "Chronoscope/0.1 (personal noncommercial history atlas; Wikimedia offline research)"
DUMP_ORIGIN = "https://dumps.wikimedia.org"
MONTHS = {m.lower(): i for i, m in enumerate(calendar.month_name) if m}
MONTHS.update({m.lower(): i for i, m in enumerate(calendar.month_abbr) if m})


def log(*args):
    print(dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"), *args, flush=True)


def save_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(json.dumps(value, ensure_ascii=False, separators=(",", ":")))
    temp.replace(path)


def save_catalog(path, catalog):
    """Write large arrays incrementally instead of allocating a second full JSON copy."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + ".tmp")
    with temp.open("w") as file:
        file.write("{")
        keys = [key for key in catalog if key not in ("events", "edges")]
        for key in keys:
            file.write(json.dumps(key) + ":" + json.dumps(catalog[key], ensure_ascii=False) + ",")
        for index, key in enumerate(("events", "edges")):
            file.write(json.dumps(key) + ":[")
            for item_index, item in enumerate(catalog[key]):
                if item_index: file.write(",")
                file.write(json.dumps(item, ensure_ascii=False, separators=(",", ":")))
            file.write("]" + ("," if index == 0 else ""))
        file.write("}")
    temp.replace(path)


def fetch(url, params=None):
    CACHE.mkdir(parents=True, exist_ok=True)
    full = url + ("?" + urllib.parse.urlencode(params) if params else "")
    cached = CACHE / (hashlib.sha256(full.encode()).hexdigest() + ".json")
    if cached.exists():
        return json.loads(cached.read_text())
    for attempt in range(5):
        r = subprocess.run(["curl", "-sS", "-L", "--compressed", "--max-time", "90", "--connect-timeout", "15",
                            "-A", AGENT, "-w", "\n%{http_code}", full], capture_output=True, text=True)
        body, _, code = r.stdout.rpartition("\n")
        if r.returncode == 0 and code == "200":
            try:
                payload = json.loads(body)
            except json.JSONDecodeError:
                payload = None
            if isinstance(payload, dict) and not payload.get("error"):
                save_json(cached, payload)
                # Anonymous Wikimedia crawler allowance: no more than ten requests/minute.
                time.sleep(6.5)
                return payload
        log("HTTP retry", attempt + 1, code, r.stderr[:150], full[:100])
        time.sleep(min(4 * (attempt + 1), 20))
    raise RuntimeError("Could not download " + full[:200])


def api(site, **params):
    return fetch("https://" + site + "/w/api.php", {"format": "json", "formatversion": "2", "maxlag": "5", **params})


def discover_manifest(snapshot):
    RAW.mkdir(parents=True, exist_ok=True)
    path = RAW / ("dumpstatus-" + snapshot + ".json")
    if not path.exists():
        save_json(path, fetch(f"{DUMP_ORIGIN}/enwiki/{snapshot}/dumpstatus.json"))
    manifest = json.loads(path.read_text())
    job = manifest["jobs"]["articlesmultistreamdumprecombine"]
    if job["status"] != "done":
        raise RuntimeError("Requested snapshot is incomplete; select a completed dated snapshot")
    name, info = next((n, i) for n, i in job["files"].items() if n.endswith("-multistream.xml.bz2"))
    return name, info


def checksum(path, digest):
    h = hashlib.sha1()
    with path.open("rb") as file:
        while chunk := file.read(8 * 1024 * 1024):
            h.update(chunk)
    return h.hexdigest() == digest


def download(snapshot, first_shard=False):
    name, info = discover_manifest(snapshot)
    if first_shard:
        manifest = json.loads((RAW / ("dumpstatus-" + snapshot + ".json")).read_text())
        name, info = next((n, i) for n, i in manifest["jobs"]["articlesmultistreamdump"]["files"].items()
                          if "-multistream1.xml-" in n)
    downloads = DATA / "downloads"
    downloads.mkdir(parents=True, exist_ok=True)
    final = downloads / name
    partial = final.with_suffix(final.suffix + ".part")
    remaining = info["size"] - (partial.stat().st_size if partial.exists() else 0)
    if shutil.disk_usage(downloads).free < remaining + 15 * 1024 ** 3:
        raise RuntimeError("Not enough free space for corpus plus 15 GiB working reserve")
    state = {"snapshot": snapshot, "url": DUMP_ORIGIN + info["url"], "expectedBytes": info["size"],
             "expectedSHA1": info["sha1"], "path": str(final), "status": "downloading", "pid": os.getpid()}
    state_path = DATA / ("shard-download-status.json" if first_shard else "download-status.json")
    if final.exists() and final.stat().st_size == info["size"] and checksum(final, info["sha1"]):
        state.update(status="verified", downloadedBytes=info["size"])
        save_json(state_path, state)
        return final
    log("Downloading", name, info["size"], "bytes; one connection; resumable")
    command = ["curl", "-fL", "--silent", "--show-error", "--retry", "20", "--retry-delay", "10",
               "--retry-all-errors", "--continue-at", "-", "--connect-timeout", "30", "-A", AGENT,
               "--output", str(partial), state["url"]]
    process = subprocess.Popen(command)
    while process.poll() is None:
        state.update(downloadedBytes=partial.stat().st_size if partial.exists() else 0,
                     updatedAt=dt.datetime.now(dt.timezone.utc).isoformat())
        save_json(state_path, state)
        log("Download progress", state["downloadedBytes"], "/", info["size"])
        time.sleep(15)
    if process.returncode != 0:
        state.update(status="paused", error="curl exit " + str(process.returncode))
        save_json(state_path, state)
        raise RuntimeError(state["error"])
    state.update(status="verifying", downloadedBytes=partial.stat().st_size)
    save_json(state_path, state)
    if partial.stat().st_size != info["size"] or not checksum(partial, info["sha1"]):
        state.update(status="checksum-failed")
        save_json(state_path, state)
        raise RuntimeError("Downloaded file does not match official size/SHA1")
    partial.replace(final)
    state.update(status="verified", completedAt=dt.datetime.now(dt.timezone.utc).isoformat())
    save_json(state_path, state)
    log("Verified", final)
    return final


def leap(year):
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)


def decimal_date(year, month=1, day=1):
    days = [31, 29 if leap(year) else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    month = max(1, min(12, month))
    day = max(1, min(days[month - 1], day))
    return year + (sum(days[:month - 1]) + day - 1) / sum(days)


def wd_date(value):
    match = re.match(r"([+-]?)(\d+)-(\d+)-(\d+)T", value["time"])
    if not match:
        return None
    sign, year, month, day = match.groups()
    year = int(year)
    if sign == "-":
        year = 1 - year  # Wikidata historical BCE numbering -> astronomical numbering.
    precision = int(value.get("precision", 9))
    text = {6: "millennium", 7: "century", 8: "decade", 9: "year", 10: "month", 11: "day"}.get(precision, "year")
    return decimal_date(year, int(month) if precision >= 10 else 1, int(day) if precision >= 11 else 1), text


def precision_upper(value, precision):
    """Conservative possible-date endpoint, not a claim of event duration."""
    year = math.floor(value)
    if precision == "year":
        return year + 1 - 1e-8
    if precision == "month":
        month = max(m for m in range(1, 13) if decimal_date(year, m, 1) <= value + 1e-8)
        return (decimal_date(year, month + 1, 1) if month < 12 else year + 1) - 1e-8
    return value


def claim_value(claim):
    snak = claim.get("mainsnak", {})
    if snak.get("snaktype") != "value":
        return None
    return snak.get("datavalue", {}).get("value")


def first_value(entity, property_name):
    values = [c for c in entity.get("claims", {}).get(property_name, []) if c.get("rank") != "deprecated"]
    values.sort(key=lambda c: c.get("rank") != "preferred")
    return next((value for c in values if (value := claim_value(c)) is not None), None)


def add_source_text_anchors(events, edges, wiki):
    """A requested technology milestone, admitted only by its dated source prose."""
    page = wiki.get("Printing press", {})
    revisions = page.get("revisions", [])
    raw = revisions[0].get("slots", {}).get("main", {}).get("content", "") if revisions else ""
    intro = clean_wikitext(raw.split("\n==", 1)[0]) or page.get("extract", "")
    pattern = r"(?:Gutenberg.{0,120}(?:invented|developed).{0,100}\b1440\b|(?:invented|developed).{0,120}Gutenberg.{0,100}\b1440\b)"
    if not re.search(pattern, intro, re.I):
        log("Printing press anchor omitted: dated invention sentence not found")
        return
    anchor_id = "Q144334-invention"
    summary = "Around 1440, Johannes Gutenberg developed a mechanical movable-type printing press in Europe, combining reusable type with a press and ink suitable for printing. This enabled faster production and wider distribution of books. The date is approximate (circa 1440)."
    existing = next((e for e in events if e["id"] == anchor_id), None)
    if existing:
        if existing["summary"] != summary:
            existing["summary"] = summary
            existing["embedding"] = []
        return
    revision = str(revisions[0]["revid"]) if revisions else None
    events.append({"id": anchor_id, "title": "Invention of Gutenberg's printing press",
                   "summary": summary,
                   "start": 1440, "end": precision_upper(1440, "year"), "precision": "year",
                   "latitude": None, "longitude": None, "category": "Science", "url": "https://en.wikipedia.org/wiki/Printing_press",
                   "revision": revision, "embedding": []})
    title_ids = {e["title"]: e["id"] for e in events}
    title_ids["Printing press"] = anchor_id
    for source_title, source_page in wiki.items():
        source_id = title_ids.get(source_title)
        if not source_id:
            continue
        source_revisions = source_page.get("revisions", [])
        content = source_revisions[0].get("slots", {}).get("main", {}).get("content", "") if source_revisions else ""
        source_revision = str(source_revisions[0]["revid"]) if source_revisions else None
        for linked_title in set(re.findall(r"\[\[([^\]|#]+)", content)):
            target_id = title_ids.get(linked_title)
            if target_id and target_id != source_id and (source_id == anchor_id or target_id == anchor_id):
                url = "https://en.wikipedia.org/wiki/" + urllib.parse.quote(source_title.replace(" ", "_"))
                edges.append({"source": source_id, "target": target_id, "kind": "wikiLink", "label": "article links to",
                              "evidence": url + ("?oldid=" + source_revision if source_revision else "") + "; hyperlink to " + linked_title, "score": 1.0})
    log("Admitted source-text printing press invention anchor", revision)


def wiki_link_edges(events, wiki, article_rows):
    """Map graph IDs to canonical events while citing the text actually inspected.

    An event can retain a newer API summary while an older dump revision provides
    one of its links. The link evidence must use that dump revision, not whichever
    revision happens to be stored on the merged event record.
    """
    title_ids = {event["title"]: event["id"] for event in events}
    for event in events:
        article_title = urllib.parse.unquote(urllib.parse.urlparse(event["url"]).path.removeprefix("/wiki/")).replace("_", " ")
        title_ids[article_title] = event["id"]
    edges = []

    def append_source(source_id, source_url, revision, links):
        if not revision:
            return
        for title in sorted(set(links)):
            target_id = title_ids.get(title)
            if target_id and target_id != source_id:
                edges.append({"source": source_id, "target": target_id, "kind": "wikiLink", "label": "article links to",
                              "evidence": source_url + "?oldid=" + str(revision) + "; hyperlink to " + title, "score": 1.0})

    for title, page in wiki.items():
        source_id = title_ids.get(title)
        revisions = page.get("revisions", [])
        if not source_id or not revisions:
            continue
        source_revision = revisions[0]
        content = source_revision.get("slots", {}).get("main", {}).get("content", "")
        links = {link["title"] for link in page.get("links", [])}
        links.update(re.findall(r"\[\[([^\]|#]+)", content))
        url = "https://en.wikipedia.org/wiki/" + urllib.parse.quote(title.replace(" ", "_"))
        append_source(source_id, url, source_revision.get("revid"), links)
    for raw, links in article_rows:
        source = json.loads(raw)
        source_id = title_ids.get(source["title"])
        if source_id:
            append_source(source_id, source["url"], source["revision"], json.loads(links))
    return edges


def merge_article_events(events, article_rows):
    """Refresh previously extracted articles, retaining canonical Wikidata IDs."""
    by_title = {event["title"]: event for event in events}
    for raw, _ in article_rows:
        event = json.loads(raw)
        existing = by_title.get(event["title"])
        if existing is None:
            events.append(event)
            by_title[event["title"]] = event
        elif existing["id"] == event["id"]:
            vector = existing.get("embedding", []) if existing["summary"] == event["summary"] else []
            existing.update(event)
            existing["embedding"] = vector
    return events


EVENT_TYPES = [
    ("Q178561", "Conflict", 600), ("Q198", "Conflict", 250), ("Q350604", "Conflict", 200),
    ("Q124734", "Politics", 150), ("Q10931", "Politics", 100), ("Q273120", "Politics", 120),
    ("Q8065", "Disaster", 100), ("Q7944", "Disaster", 200), ("Q7692360", "Disaster", 100),
    ("Q44512", "Health", 100), ("Q752783", "Space", 130), ("Q131569", "Politics", 150),
    ("Q1656682", "History", 200),
]
# High-recognition graph anchors, fetched from Wikidata as real records, never invented.
ANCHORS = "Q362 Q180376 Q696252 Q808 Q866 Q34266 Q361 Q54514 Q8676 Q47659 Q1490 Q7987 Q39740 Q6034 Q420 Q8740 Q167311 Q12418 Q12546 Q12419 Q36224 Q45382 Q34812 Q8472 Q49008 Q5377 Q7989 Q7990 Q177588 Q179876 Q12407 Q12431 Q34053 Q9283 Q2873 Q10859 Q11668 Q15850".split()
ANCHOR_TITLES = {
    "Apollo 11": "Space", "Apollo 13": "Space", "Sputnik 1": "Space", "Vostok 1": "Space",
    "French Revolution": "Politics", "Fall of Constantinople": "Conflict", "American Revolution": "Politics",
    "Battle of Marathon": "Conflict", "Battle of Salamis": "Conflict", "Battle of Thermopylae": "Conflict",
    "Battle of Kadesh": "Conflict", "Industrial Revolution": "History", "Printing press": "Science",
}


def bootstrap(limit=2500):
    categories = {}
    for event_type, category, count in EVENT_TYPES:
        query = f'''SELECT DISTINCT ?item WHERE {{ ?item wdt:P31 wd:{event_type} .
            {{ ?item wdt:P585 ?time }} UNION {{ ?item wdt:P580 ?time }}
            ?article schema:about ?item; schema:isPartOf <https://en.wikipedia.org/> . }} LIMIT {count}'''
        result = fetch("https://query.wikidata.org/sparql", {"query": query, "format": "json"})
        items = [row["item"]["value"].rsplit("/", 1)[-1] for row in result["results"]["bindings"]]
        log("Event class", event_type, category, len(items))
        categories.update({qid: category for qid in items})
    for qid in ANCHORS:
        categories.setdefault(qid, "History")
    anchor_pages = api("en.wikipedia.org", action="query", titles="|".join(ANCHOR_TITLES), redirects="1", prop="pageprops")
    for page in anchor_pages.get("query", {}).get("pages", []):
        qid = page.get("pageprops", {}).get("wikibase_item")
        if qid:
            categories[qid] = ANCHOR_TITLES.get(page["title"], "History")
    entities = {}
    ids = list(categories)[:limit]
    for offset in range(0, len(ids), 50):
        result = api("www.wikidata.org", action="wbgetentities", ids="|".join(ids[offset:offset + 50]),
                     props="labels|descriptions|claims|sitelinks", languages="en", sitefilter="enwiki")
        entities.update(result.get("entities", {}))
        log("Wikidata entities", min(offset + 50, len(ids)), "/", len(ids))
    save_json(RAW / "bootstrap-entities.json", entities)
    wiki = {}
    titles = [e["sitelinks"]["enwiki"]["title"] for e in entities.values() if "enwiki" in e.get("sitelinks", {})]
    for offset in range(0, len(titles), 50):
        result = api("en.wikipedia.org", action="query", titles="|".join(titles[offset:offset + 50]), redirects="1",
                     prop="extracts|coordinates|revisions|links", exintro="1", explaintext="1", exchars="850", exlimit="max",
                     colimit="max", coprimary="primary", rvprop="ids|content", rvslots="main", pllimit="max", plnamespace="0")
        for page in result.get("query", {}).get("pages", []):
            wiki[page["title"]] = page
        log("Wikipedia articles", min(offset + 50, len(titles)), "/", len(titles))
    save_json(RAW / "bootstrap-wikipedia.json", wiki)
    events, edges = [], []
    relation_labels = {"P361": "part of", "P527": "includes", "P155": "follows", "P156": "followed by",
                       "P1542": "has effect", "P828": "has cause", "P138": "named after", "P793": "significant event"}
    for qid, entity in entities.items():
        title = entity.get("sitelinks", {}).get("enwiki", {}).get("title")
        if not title:
            continue
        # Person birth/death and publication dates are deliberately excluded.
        start_claim = first_value(entity, "P580") or first_value(entity, "P585") or first_value(entity, "P619")
        if title == "Printing press":
            start_claim = start_claim or first_value(entity, "P571")
        if not isinstance(start_claim, dict) or "time" not in start_claim:
            continue
        start = wd_date(start_claim)
        if not start:
            continue
        end_claim = first_value(entity, "P582") or first_value(entity, "P620")
        end = wd_date(end_claim) if isinstance(end_claim, dict) and "time" in end_claim else start
        if not end:
            end = start
        if end[0] < start[0]:
            end = start
        page = wiki.get(title, {})
        coordinate = first_value(entity, "P625")
        latitude = coordinate.get("latitude") if isinstance(coordinate, dict) else None
        longitude = coordinate.get("longitude") if isinstance(coordinate, dict) else None
        if latitude is None and page.get("coordinates"):
            latitude, longitude = page["coordinates"][0]["lat"], page["coordinates"][0]["lon"]
        summary = page.get("extract") or entity.get("descriptions", {}).get("en", {}).get("value", "")
        revision = str(page["revisions"][0]["revid"]) if page.get("revisions") else None
        display_title = "Invention of the printing press" if title == "Printing press" else title
        if title == "Printing press":
            summary = "Invention date from Wikidata inception claim; article describes Gutenberg's European printing press. " + summary
        events.append({"id": qid, "title": display_title, "summary": summary, "start": start[0], "end": precision_upper(end[0], end[1]),
                       "precision": start[1], "latitude": latitude, "longitude": longitude,
                       "category": categories[qid], "url": "https://en.wikipedia.org/wiki/" + urllib.parse.quote(title.replace(" ", "_")),
                       "revision": revision, "embedding": []})
        for prop, label in relation_labels.items():
            for claim in entity.get("claims", {}).get(prop, []):
                value = claim_value(claim)
                if isinstance(value, dict) and value.get("id") in entities:
                    edges.append({"source": qid, "target": value["id"], "kind": "wikidata", "label": label,
                                  "evidence": f"Wikidata {qid} property {prop}, statement {claim.get('id', '')}; https://www.wikidata.org/wiki/{qid}#{prop}", "score": 1.0})
    title_ids = {e["title"]: e["id"] for e in events}
    for qid, entity in entities.items():
        original_title = entity.get("sitelinks", {}).get("enwiki", {}).get("title")
        if original_title and any(e["id"] == qid for e in events):
            title_ids[original_title] = qid
    for event in events:
        source_title = entities[event["id"]]["sitelinks"]["enwiki"]["title"]
        page = wiki.get(source_title, {})
        raw_text = page.get("revisions", [{}])[0].get("slots", {}).get("main", {}).get("content", "")
        linked_titles = {link["title"] for link in page.get("links", [])}
        linked_titles.update(re.findall(r"\[\[([^\]|#]+)", raw_text))
        for linked_title in linked_titles:
            if linked_title in title_ids and title_ids[linked_title] != event["id"]:
                edges.append({"source": event["id"], "target": title_ids[linked_title], "kind": "wikiLink", "label": "article links to",
                              "evidence": event["url"] + ("?oldid=" + event["revision"] if event["revision"] else "") + "; hyperlink to " + linked_title, "score": 1.0})
    add_source_text_anchors(events, edges, wiki)
    # Preserve events already extracted from a completed bulk shard during this crawl.
    if CATALOG.exists():
        previous = json.loads(CATALOG.read_text())
        current_titles = {e["title"] for e in events}
        extra = [e for e in previous["events"] if e["title"] not in current_titles]
        previous_ids = {e["id"]: next((n["id"] for n in events if n["title"] == e["title"]), e["id"]) for e in previous["events"]}
        events.extend(extra)
        for edge in previous["edges"]:
            if edge["kind"] != "semantic":
                edges.append({**edge, "source": previous_ids.get(edge["source"], edge["source"]), "target": previous_ids.get(edge["target"], edge["target"])})
    export(events, edges, f"{len(events):,} dated event articles fetched from English Wikipedia and Wikidata, with any completed bulk shards. Select event classes; incomplete historical coverage.")


def embed(events, reuse_model=None):
    pending = [event for event in events if reuse_model is None or len(event.get("embedding", [])) != 512]
    input_path, output_path = RAW / "embedding-input.jsonl", RAW / "embeddings.jsonl"
    with input_path.open("w") as file:
        for event in pending:
            file.write(json.dumps({k: event[k] for k in ("id", "title", "summary")}, ensure_ascii=False) + "\n")
    subprocess.run(["swift", "-module-cache-path", "/private/tmp/chronoscope-swift-module-cache", str(ROOT / "Tools/embed.swift"),
                    str(input_path), str(output_path), "--jsonl"], check=True)
    event_ids = {event["id"]: event for event in pending}
    count = 0
    with output_path.open() as file:
        metadata = json.loads(next(file))
        for line in file:
            record = json.loads(line)
            event_ids[record["id"]]["embedding"] = record["embedding"]
            count += 1
    if count != len(pending):
        raise RuntimeError("Embedding output count does not match event count")
    if reuse_model is not None and (metadata["model"] != reuse_model or any(len(e["embedding"]) != metadata["dimensions"] for e in events)):
        return embed(events)
    return metadata["model"], metadata["dimensions"]


def semantic_edges(events, per_event=3, threshold=0.62):
    # NumPy is optional, used only to accelerate exact cosine on the bootstrap.
    try:
        import numpy as np
    except ImportError:
        log("NumPy unavailable; semantic links derived on demand by native app")
        return []
    if len(events) > 10000:
        log("Large catalog: semantic neighbors derived by native app; no quadratic all-pairs export")
        return []
    vectors = np.asarray([e["embedding"] for e in events], dtype=np.float32)
    vectors /= np.maximum(np.linalg.norm(vectors, axis=1, keepdims=True), 1e-12)
    edges = []
    for begin in range(0, len(events), 256):
        scores = vectors[begin:begin + 256] @ vectors.T
        for local, row in enumerate(scores):
            index = begin + local
            row[index] = -1
            for target in np.argsort(row)[-per_event:][::-1]:
                score = float(row[target])
                if score >= threshold:
                    edges.append({"source": events[index]["id"], "target": events[target]["id"], "kind": "semantic",
                                  "label": "similar meaning", "evidence": "Cosine similarity of Apple NaturalLanguage English sentence embeddings; semantic association, not a documented historical relationship.",
                                  "score": round(score, 6)})
    return edges


def xorshift32(state):
    mask = 0xFFFFFFFF
    state = (state ^ ((state << 13) & mask)) & mask
    state = (state ^ (state >> 17)) & mask
    return (state ^ ((state << 5) & mask)) & mask


def lsh_planes(dimensions):
    planes = []
    mask = 0xFFFFFFFF
    for table in range(16):
        table_planes = []
        for bit in range(8):
            state = (0x9E3779B9 ^ (((table + 1) * 0x85EBCA6B) & mask) ^ (((bit + 1) * 0xC2B2AE35) & mask)) & mask
            plane = []
            for _ in range(8):
                state = xorshift32(state)
                dimension = state % dimensions
                state = xorshift32(state)
                plane.append((dimension, 1 if state & 1 else -1))
            table_planes.append(plane)
        planes.append(table_planes)
    return planes


def vector_buckets(vector, planes=None):
    planes = planes or lsh_planes(len(vector))
    result = []
    for table, table_planes in enumerate(planes):
        signature = 0
        for bit, plane in enumerate(table_planes):
            if sum(vector[dimension] * sign for dimension, sign in plane) >= 0:
                signature |= 1 << bit
        result.append((table << 8) | signature)
    return result


def write_store(catalog):
    db = sqlite3.connect(DATA / "atlas.sqlite")
    create_store_schema(db)
    # Readers continue seeing the previous complete index until this replacement
    # commits; they never observe an empty or half-populated corpus.
    db.execute("BEGIN IMMEDIATE")
    for table in ("events", "edges", "events_fts", "vector_buckets"):
        db.execute("DELETE FROM " + table)
    planes = lsh_planes(len(catalog["events"][0]["embedding"]))
    for event in catalog["events"]:
        insert_store_event(db, event, planes)
    db.executemany("INSERT INTO edges VALUES(?,?,?,?,?,?)", ([edge[k] for k in ("source", "target", "kind", "label", "evidence", "score")] for edge in catalog["edges"]))
    for key in ("schemaVersion", "generatedAt", "coverage", "embeddingModel"):
        db.execute("INSERT OR REPLACE INTO metadata VALUES(?,?)", (key, json.dumps(catalog[key])))
    counts = {"eventCount": len(catalog["events"]), "edgeCount": len(catalog["edges"]),
              "documentedEdgeCount": sum(e["kind"] != "semantic" for e in catalog["edges"])}
    for key, value in counts.items():
        db.execute("INSERT OR REPLACE INTO metadata VALUES(?,?)", (key, json.dumps(value)))
    db.execute("INSERT OR REPLACE INTO metadata VALUES(?,?)", ("lshVersion", json.dumps("sparse-xorshift32-v1-16x8x8")))
    finish_store(db)


def create_store_schema(db):
    db.executescript('''PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS events(id TEXT PRIMARY KEY,title TEXT,summary TEXT,start REAL,end REAL,precision TEXT,latitude REAL,longitude REAL,category TEXT,url TEXT,revision TEXT,payload TEXT);
        CREATE INDEX IF NOT EXISTS events_time ON events(start,end);
        CREATE INDEX IF NOT EXISTS events_end ON events(end);
        CREATE INDEX IF NOT EXISTS events_category_time ON events(category,start,end);
        CREATE INDEX IF NOT EXISTS events_title ON events(title,id);
        CREATE TABLE IF NOT EXISTS edges(source TEXT,target TEXT,kind TEXT,label TEXT,evidence TEXT,score REAL);
        CREATE INDEX IF NOT EXISTS edges_source ON edges(source);
        CREATE INDEX IF NOT EXISTS edges_target ON edges(target);
        CREATE INDEX IF NOT EXISTS edges_kind_score ON edges(kind,score);
        CREATE TABLE IF NOT EXISTS vector_buckets(bucket INTEGER,event_id TEXT,PRIMARY KEY(bucket,event_id)) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS vector_buckets_event ON vector_buckets(event_id);
        CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(id UNINDEXED,title,summary,tokenize='unicode61');
        CREATE TRIGGER IF NOT EXISTS events_fts_insert AFTER INSERT ON events BEGIN
          INSERT INTO events_fts(id,title,summary) VALUES(new.id,new.title,new.summary); END;
        CREATE TRIGGER IF NOT EXISTS events_fts_delete AFTER DELETE ON events BEGIN
          DELETE FROM events_fts WHERE id=old.id; END;
        CREATE TRIGGER IF NOT EXISTS events_fts_update AFTER UPDATE ON events BEGIN
          DELETE FROM events_fts WHERE id=old.id;
          INSERT INTO events_fts(id,title,summary) VALUES(new.id,new.title,new.summary); END;''')


def insert_store_event(db, event, planes):
    db.execute("INSERT INTO events VALUES(?,?,?,?,?,?,?,?,?,?,?,?)", [event[k] for k in ("id", "title", "summary", "start", "end", "precision", "latitude", "longitude", "category", "url", "revision")] + [json.dumps(event, separators=(",", ":"))])
    db.executemany("INSERT INTO vector_buckets VALUES(?,?)", ((bucket, event["id"]) for bucket in vector_buckets(event["embedding"], planes)))


def finish_store(db):
    db.commit()
    try:
        checkpoint = db.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
        if checkpoint[0] != 0:
            raise RuntimeError("SQLite export checkpoint is busy; standalone index was not finalized")
        # A checkpoint alone leaves the header in WAL mode. A copied read-only
        # file can then require writable -shm/-wal sidecars merely to open.
        mode = db.execute("PRAGMA journal_mode=DELETE").fetchone()[0]
        if mode.lower() != "delete":
            raise RuntimeError("SQLite export did not enter portable DELETE journal mode")
    finally:
        db.close()


def bounded_bundle(events, edges, coverage, limit=3500):
    if len(events) <= limit:
        return events, edges, coverage
    # Keep structured bootstrap anchors and distribute remaining slots over all
    # chronologically sorted extracted events; never bundle the full raw corpus.
    anchors = [event for event in events if event["id"].startswith("Q") or event["title"] in ANCHOR_TITLES]
    anchors = anchors[:limit]
    selected = {event["id"]: event for event in anchors}
    candidates = [event for event in events if event["id"] not in selected]
    remaining = limit - len(selected)
    if remaining:
        for index in range(remaining):
            event = candidates[min(len(candidates) - 1, int(index * len(candidates) / remaining))]
            selected[event["id"]] = event
    bundled = sorted(selected.values(), key=lambda e: (e["start"], e["title"]))
    bundled_edges = [edge for edge in edges if edge["kind"] != "semantic" and edge["source"] in selected and edge["target"] in selected]
    bundled_edges += semantic_edges(bundled)
    text = f"Bounded bundle: {len(bundled):,} of {len(events):,} indexed dated event articles, sampled across epochs with structured anchors. Import Data/atlas.sqlite for the full extracted index. {coverage}"
    return bundled, bundled_edges, text


def export(events, edges, coverage, reuse_model=None):
    ids = {event["id"] for event in events}
    edges = [e for e in edges if e["source"] in ids and e["target"] in ids and e["source"] != e["target"]]
    seen = set()
    edges = [e for e in edges if (key := (e["source"], e["target"], e["kind"], e["label"])) not in seen and not seen.add(key)]
    events.sort(key=lambda e: (e["start"], e["title"]))
    model, dimensions = embed(events, reuse_model)
    edges += semantic_edges(events)
    catalog = {"schemaVersion": 1, "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
               "coverage": coverage, "embeddingModel": model, "events": events, "edges": edges}
    write_store(catalog)
    bundled, bundle_edges, bundle_coverage = bounded_bundle(events, edges, coverage)
    save_catalog(CATALOG, {**catalog, "events": bundled, "edges": bundle_edges, "coverage": bundle_coverage})
    stats = {"events": len(events), "edges": len(edges), "embeddingDimensions": dimensions,
             "earliest": min(e["start"] for e in events), "latest": max(e["end"] for e in events),
             "coordinates": sum(e["latitude"] is not None for e in events), "catalogBytes": CATALOG.stat().st_size,
             "bundledEvents": len(bundled), "bundledEdges": len(bundle_edges), "bundleCoverage": bundle_coverage,
             "edgeKinds": {kind: sum(e["kind"] == kind for e in edges) for kind in ("wikiLink", "wikidata", "semantic")},
             "categories": {kind: sum(e["category"] == kind for e in events) for kind in sorted({e["category"] for e in events})},
             "coverage": coverage, "generatedAt": catalog["generatedAt"], "model": model}
    save_json(DATA / "catalog-status.json", stats)
    log("Catalog exported", json.dumps(stats))


def augment():
    catalog = json.loads(CATALOG.read_text())
    wiki = json.loads((RAW / "bootstrap-wikipedia.json").read_text())
    events = catalog["events"]
    edges = [e for e in catalog["edges"] if e["kind"] != "semantic"]
    add_source_text_anchors(events, edges, wiki)
    export(events, edges, f"{len(events):,} dated event articles from real English Wikipedia/Wikidata downloads and a checksum-verified bulk shard. Select event classes and source-derived invention anchor; incomplete historical coverage.", catalog["embeddingModel"])


def export_full_json(output):
    """Explicit optional large export; the app bundle stays bounded."""
    db = sqlite3.connect(f"file:{DATA / 'atlas.sqlite'}?mode=ro", uri=True)
    metadata = {key: json.loads(value) for key, value in db.execute("SELECT key,value FROM metadata")}
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w") as file:
        file.write("{")
        for key in ("schemaVersion", "generatedAt", "coverage", "embeddingModel"):
            file.write(json.dumps(key) + ":" + json.dumps(metadata[key]) + ",")
        file.write('"events":[')
        for index, (payload,) in enumerate(db.execute("SELECT payload FROM events ORDER BY start,title")):
            if index: file.write(",")
            file.write(payload)
        file.write('],"edges":[')
        for index, row in enumerate(db.execute("SELECT source,target,kind,label,evidence,score FROM edges")):
            if index: file.write(",")
            file.write(json.dumps(dict(zip(("source", "target", "kind", "label", "evidence", "score"), row)), separators=(",", ":")))
        file.write("]}")
    db.close()
    log("Full JSON exported explicitly", output, output.stat().st_size, "bytes")


def clean_wikitext(text):
    text = re.sub(r"<!--.*?-->|<ref\b[^>]*>.*?</ref>|<ref\b[^>]*/>", "", text, flags=re.S | re.I)
    for _ in range(12):
        shortened = re.sub(r"\{\{[^{}]*\}\}", "", text)
        if shortened == text:
            break
        text = shortened
    text = re.sub(r"\[\[(?:File|Image|Category):[^\]]*\]\]", "", text, flags=re.I)
    text = re.sub(r"\[\[([^\]|]+)\|([^\]]+)\]\]", r"\2", text)
    text = re.sub(r"\[\[([^\]]+)\]\]", r"\1", text)
    text = re.sub(r"<[^>]+>|'{2,}|\{\|.*?\|\}", "", text, flags=re.S)
    return html.unescape(re.sub(r"\s+", " ", text)).strip()


def top_templates(text):
    stack, start, i = 0, 0, 0
    while i < len(text) - 1:
        pair = text[i:i + 2]
        if pair == "{{":
            if stack == 0:
                start = i + 2
            stack += 1
            i += 2
        elif pair == "}}" and stack:
            stack -= 1
            if stack == 0:
                yield text[start:i]
            i += 2
        else:
            i += 1


def split_template(text):
    result, current, nesting, brackets = [], [], 0, 0
    for part in re.split(r"(\{\{|\}\}|\[\[|\]\]|\|)", text):
        if part == "{{": nesting += 1
        elif part == "}}": nesting -= 1
        elif part == "[[": brackets += 1
        elif part == "]]": brackets -= 1
        if part == "|" and not nesting and not brackets:
            result.append("".join(current)); current = []
        else:
            current.append(part)
    result.append("".join(current))
    return result


INFOBOXES = {
    "infobox military conflict": "Conflict", "infobox civilian attack": "Conflict", "infobox civil conflict": "Politics",
    "infobox event": "History", "infobox historical event": "History", "infobox earthquake": "Disaster",
    "infobox volcanic eruption": "Disaster", "infobox eruption": "Disaster", "infobox spaceflight": "Space",
    "infobox space mission": "Space", "infobox pandemic": "Health", "infobox disease outbreak": "Health",
    "infobox civil unrest": "Politics", "infobox hurricane": "Disaster", "infobox storm": "Disaster",
    "infobox flood": "Disaster", "infobox wildfire": "Disaster", "infobox treaty": "Politics",
    "infobox terrorist attack": "Conflict", "infobox massacre": "Conflict", "infobox rail accident": "Disaster",
    "infobox news event": "History", "infobox oil spill": "Disaster", "infobox election": "Politics",
}
EVENT_INFOBOX_PATTERN = re.compile(r"\{\{\s*(?:" + "|".join(re.escape(name) for name in INFOBOXES) + r")\s*\|", re.I)


def parse_wiki_date(text):
    # A BCE suffix can apply to a whole range, including month/day forms.
    bce_context = bool(re.search(r"\b(?:BCE|BC)\b|\bbc\s*=\s*(?:yes|true|1)", text, re.I))
    template_dates = []
    for template in top_templates(text):
        fields = split_template(template)
        if re.match(r"(?:start date(?: and age)?|end date(?: and age)?|date(?: and age)?|dts|launch date|start-date|end-date)$", fields[0].strip(), re.I):
            digits = [int(x.strip()) for x in fields[1:] if re.fullmatch(r"-?\d{1,5}", x.strip())]
            if digits:
                year = digits[0]
                if bce_context and year > 0:
                    year = 1 - year
                template_dates.append((decimal_date(year, digits[1] if len(digits) > 1 else 1, digits[2] if len(digits) > 2 else 1), "day" if len(digits) > 2 else "month" if len(digits) > 1 else "year"))
    if template_dates:
        return min(x[0] for x in template_dates), max(x[0] for x in template_dates), template_dates[0][1]
    plain = clean_wikitext(text).replace("–", "-").replace("—", "-")
    dates = []
    for match in re.finditer(r"\b(?:(\d{1,2})\s+)?([A-Za-z]+)\s+(?:(\d{1,2}),?\s+)?(\d{3,4})\b", plain):
        before, month, after, year = match.groups()
        if month.lower() in MONTHS:
            number = 1 - int(year) if bce_context else int(year)
            dates.append((decimal_date(number, MONTHS[month.lower()], int(before or after or 1)), "day" if before or after else "month"))
    if dates:
        return min(d[0] for d in dates), max(d[0] for d in dates), dates[0][1]
    bce = re.search(r"\b(\d{1,5})(?:\s*(?:-|to)\s*(\d{1,5}))?\s*(?:BCE|BC)\b", plain, re.I)
    if bce:
        years = [1 - int(bce[1]), 1 - int(bce[2] or bce[1])]
        return min(years), max(years), "year"
    years = [int(m[0]) for m in re.finditer(r"(?<!\d)\d{3,4}(?!\d)", plain) if 100 <= int(m[0]) <= 2100]
    if years:
        return min(years), max(years), "year"
    return None


def extract_articles(stage, path, max_pages=None):
    scanned, extracted = 0, 0
    namespace = "{http://www.mediawiki.org/xml/export-0.11/}"
    started = time.monotonic()
    with contextlib.ExitStack() as stack:
        raw_file = stack.enter_context(Path(path).open("rb"))
        file = stack.enter_context(bz2.BZ2File(raw_file, "rb")) if str(path).endswith(".bz2") else raw_file
        context = ET.iterparse(file, events=("start", "end"))
        _, xml_root = next(context)
        for action, page in context:
            if action != "end" or page.tag != namespace + "page":
                continue
            scanned += 1
            if page.findtext(namespace + "ns") == "0" and page.find(namespace + "redirect") is None:
                title = page.findtext(namespace + "title", "")
                page_id = page.findtext(namespace + "id", "")
                revision = page.find(namespace + "revision")
                text = revision.findtext(namespace + "text", "") if revision is not None else ""
                # Most Wikipedia articles concern people/places/topics. Cheaply reject
                # them before doing balanced-template parsing; no biography date mining.
                marker = EVENT_INFOBOX_PATTERN.search(text[:80000].replace("_", " "))
                if title.startswith(("History of ", "Timeline of ", "List of ")):
                    marker = None
                for template in top_templates(text[marker.start():marker.start() + 80000] if marker else ""):
                    fields = split_template(template)
                    category = INFOBOXES.get(fields[0].strip().lower().replace("_", " "))
                    if not category:
                        continue
                    values = dict(pair.split("=", 1) for pair in fields[1:] if "=" in pair)
                    values = {k.strip().lower(): v.strip() for k, v in values.items()}
                    date_text = next((values[k] for k in ("date", "start_date", "launch_date", "eruption_date", "formed", "election_date") if values.get(k)), "")
                    date = parse_wiki_date(date_text)
                    if not date:
                        continue
                    start, end, precision = date
                    end_precision = precision
                    if values.get("end_date"):
                        end_date = parse_wiki_date(values["end_date"])
                        if end_date:
                            end = max(start, end_date[1])
                            end_precision = end_date[2]
                    end = precision_upper(end, end_precision)
                    summary = clean_wikitext(text.split("\n==", 1)[0])[:1000]
                    rev_id = revision.findtext(namespace + "id") if revision is not None else None
                    event = {"id": "WP" + page_id, "title": title, "summary": summary, "start": start, "end": end,
                             "precision": precision, "latitude": None, "longitude": None, "category": category,
                             "url": "https://en.wikipedia.org/wiki/" + urllib.parse.quote(title.replace(" ", "_")), "revision": rev_id, "embedding": []}
                    coord = re.search(r"\{\{[Cc]oord\|\s*(\-?[\d.]+)\|\s*(\-?[\d.]+)\s*(?:\|\s*(?:display|type|region|name|scale|format)|\}\})", text)
                    if coord:
                        lat, lon = map(float, coord.groups())
                        if -90 <= lat <= 90 and -180 <= lon <= 180:
                            event["latitude"], event["longitude"] = lat, lon
                    links = list(dict.fromkeys(re.findall(r"\[\[([^\]|#]+)", text)))
                    stage.execute("INSERT OR REPLACE INTO article_events VALUES(?,?,?,?,?)", (event["id"], title, rev_id, json.dumps(event), json.dumps(links)))
                    extracted += 1
                    break
            page.clear()
            xml_root.clear()
            if scanned % 2000 == 0:
                stage.commit()
                log("Extracting dated event infoboxes", scanned, "pages scanned,", extracted, "events")
                save_json(DATA / "ingest-status.json", {"path": str(path), "scannedPages": scanned, "extractedEvents": extracted,
                          "status": "running", "phase": "extracting", "sourceBytes": Path(path).stat().st_size,
                          "readBytes": raw_file.tell(), "elapsedSeconds": round(time.monotonic() - started, 1),
                          "updatedAt": dt.datetime.now(dt.timezone.utc).isoformat()})
            if max_pages and scanned >= max_pages:
                break
    stage.commit()
    return scanned, extracted


def ingest(path, max_pages=None, merge_bootstrap=True):
    path = Path(path).resolve()
    stage = sqlite3.connect(DATA / "articles.sqlite")
    stage.execute("PRAGMA journal_mode=WAL")
    stage.execute("CREATE TABLE IF NOT EXISTS article_events(id TEXT PRIMARY KEY,title TEXT,revision TEXT,event TEXT,links TEXT)")
    stage.execute("CREATE TABLE IF NOT EXISTS extraction_runs(signature TEXT PRIMARY KEY,summary TEXT)")
    stage.commit()
    info = path.stat()
    # Parser edits invalidate completed extraction, avoiding silently reusing
    # old precision/coordinate rules on a later restart.
    parser_revision = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    fingerprint = json.dumps([str(path), info.st_size, info.st_mtime_ns, parser_revision])
    previous = stage.execute("SELECT summary FROM extraction_runs WHERE signature=?", (fingerprint,)).fetchone() if not max_pages else None
    save_json(DATA / "ingest-status.json", {"path": str(path), "status": "running", "phase": "extracting", "pid": os.getpid()})
    if previous:
        summary = json.loads(previous[0])
        scanned, extracted = summary["scannedPages"], summary["extractedEvents"]
        log("Reusing completed extraction checkpoint", scanned, "pages; source fingerprint unchanged")
    else:
        scanned, extracted = extract_articles(stage, path, max_pages)
        if not max_pages:
            stage.execute("INSERT OR REPLACE INTO extraction_runs VALUES(?,?)", (fingerprint, json.dumps({"scannedPages": scanned, "extractedEvents": extracted})))
            stage.commit()
    events, edges = [], []
    wiki_path = RAW / "bootstrap-wikipedia.json"
    wiki = json.loads(wiki_path.read_text()) if merge_bootstrap and wiki_path.exists() else {}
    if merge_bootstrap and CATALOG.exists():
        catalog = json.loads(CATALOG.read_text())
        events = catalog["events"]
        # Cached article revisions let us rebuild prior links rather than retain
        # evidence accidentally inherited from a different merged revision.
        excluded = {"semantic", "wikiLink"} if wiki else {"semantic"}
        edges = [e for e in catalog["edges"] if e["kind"] not in excluded]
    if stage.execute("SELECT count(*) FROM article_events").fetchone()[0] > 10000:
        from scalable import export_staged
        seed = catalog if merge_bootstrap and CATALOG.exists() else {"events": [], "edges": [], "embeddingModel": ""}
        export_staged(stage, seed, wiki, DATA, CATALOG, path, scanned, extracted)
        stage.close()
        return
    rows = stage.execute("SELECT event, links FROM article_events").fetchall()
    merge_article_events(events, rows)
    edges.extend(wiki_link_edges(events, wiki, rows))
    stage.close()
    coverage = f"{len(events):,} dated event articles; {scanned:,} pages scanned from {Path(path).name}. Strict event infobox extraction plus Wikidata bootstrap; incomplete historical coverage."
    export(events, edges, coverage)
    from validate_sqlite import validate_sqlite
    validation = validate_sqlite(DATA / "atlas.sqlite")
    subprocess.run([sys.executable, str(ROOT / "Tools/validate_catalog.py"), str(CATALOG)], check=True)
    save_json(DATA / "validation-status.json", {**validation, "validatedAt": dt.datetime.now(dt.timezone.utc).isoformat()})
    save_json(DATA / "ingest-status.json", {"path": str(path), "scannedPages": scanned, "extractedEvents": extracted,
              "catalogEvents": len(events), "status": "complete", "phase": "complete", "validation": "passed"})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    boot = sub.add_parser("bootstrap"); boot.add_argument("--limit", type=int, default=2500)
    down = sub.add_parser("download"); down.add_argument("--snapshot", default="20261001"); down.add_argument("--first-shard", action="store_true")
    imp = sub.add_parser("ingest"); imp.add_argument("path", type=Path); imp.add_argument("--max-pages", type=int)
    full = sub.add_parser("full"); full.add_argument("--snapshot", default="20261001")
    exp = sub.add_parser("export-json"); exp.add_argument("--output", type=Path, default=DATA / "full-catalog.json")
    sub.add_parser("augment")
    args = parser.parse_args()
    RAW.mkdir(parents=True, exist_ok=True)
    if args.command == "bootstrap": bootstrap(args.limit)
    elif args.command == "download": download(args.snapshot, args.first_shard)
    elif args.command == "ingest": ingest(args.path, args.max_pages)
    elif args.command == "full":
        path = download(args.snapshot)
        # Load the current extraction code after a long download completes.
        subprocess.run([sys.executable, str(Path(__file__).resolve()), "ingest", str(path)], check=True)
    elif args.command == "export-json": export_full_json(args.output)
    elif args.command == "augment": augment()


if __name__ == "__main__":
    try:
        main()
    except BaseException as error:
        if len(sys.argv) > 1 and sys.argv[1] == "ingest":
            status_path = DATA / "ingest-status.json"
            status = json.loads(status_path.read_text()) if status_path.exists() else {}
            status.update(status="paused" if isinstance(error, KeyboardInterrupt) else "failed",
                          error=type(error).__name__ + ": " + str(error), updatedAt=dt.datetime.now(dt.timezone.utc).isoformat())
            save_json(status_path, status)
        raise
