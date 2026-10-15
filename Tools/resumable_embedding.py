"""Checkpoint derived prose preparation without resetting extracted sources.

The caller must hold the prose pipeline lock. Source rows and extraction identity
remain immutable; the sentence cache grows only through validated vector imports.
"""
from __future__ import annotations

from contextlib import contextmanager
from dataclasses import asdict, dataclass
import json
import math
from pathlib import Path
import re

import scalable


VERSION = "keyset-prose-embedding-v1"
ALGORITHM = "sha256(model-NUL-title-NUL-summary)-v1"
MAX_PREPARATION_BATCH = 2000
EMBEDDING_BATCH = 512
CHECKPOINT_TABLE = "resumable_embedding_checkpoint"
QUEUE_TABLE = "resumable_pending_embeddings"


@dataclass(frozen=True)
class Context:
    extraction_fingerprint: str
    expected_mentions: int
    model: str
    implementation_hashes: dict[str, str]
    dimensions: int = 512
    version: str = VERSION
    algorithm: str = ALGORITHM

    def identity(self):
        # Round-trip prevents a mutable caller dictionary becoming checkpoint state.
        return json.loads(json.dumps(asdict(self), sort_keys=True))


@contextmanager
def transaction(stage):
    if stage.in_transaction:
        raise RuntimeError("Resumable embedding requires an idle SQLite connection")
    stage.execute("BEGIN IMMEDIATE")
    try:
        yield
        stage.commit()
    except BaseException:
        stage.rollback()
        raise


def _validate_source(stage, context):
    row = stage.execute("SELECT value FROM extraction_checkpoint WHERE key='progress'").fetchone()
    checkpoint = json.loads(row[0]) if row else {}
    if (checkpoint.get("complete") is not True or checkpoint.get("limited") is not False
            or checkpoint.get("fingerprint") != context.extraction_fingerprint
            or checkpoint.get("extractedMentions") != context.expected_mentions):
        raise RuntimeError("Full extraction checkpoint does not match the frozen recovery context")
    if (type(context.expected_mentions) is not int or context.expected_mentions < 0
            or context.dimensions != 512 or not context.model
            or context.algorithm != ALGORITHM or context.version != VERSION):
        raise RuntimeError("Invalid recovery count, model or embedding dimensions")


def _load_state(stage, context):
    _validate_source(stage, context)
    exists = stage.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
                           (CHECKPOINT_TABLE,)).fetchone()
    if not exists:
        _validate_source_count(stage, context)
        return None
    row = stage.execute(f"SELECT value FROM {CHECKPOINT_TABLE} WHERE key='active'").fetchone()
    if row is None:
        raise RuntimeError("Recovery schema exists without its atomic checkpoint")
    state = json.loads(row[0])
    if state["context"] != context.identity():
        raise RuntimeError("Recovery fingerprint, model or implementation identity changed")
    if (state.get("phase") not in {"preparing", "prepared", "embedding", "complete"}
            or not isinstance(state.get("lastId"), str)
            or not 0 <= state.get("remainingMentions", -1) <= state.get("preparedMentions", -1) <= context.expected_mentions
            or (state["phase"] != "preparing" and state["preparedMentions"] != context.expected_mentions)
            or (state["phase"] == "complete" and state["remainingMentions"] != 0)):
        raise RuntimeError("Invalid durable recovery phase, cursor or mention counts")
    _validate_source_count(stage, context)
    return state


def _validate_source_count(stage, context):
    if stage.execute("SELECT count(*) FROM narrative_events").fetchone()[0] != context.expected_mentions:
        raise RuntimeError("Authoritative narrative count differs from the extraction checkpoint")


def _save_state(stage, state):
    stage.execute(f"INSERT OR REPLACE INTO {CHECKPOINT_TABLE} VALUES('active',?)",
                  (json.dumps(state, sort_keys=True),))


def _initialize(stage, context):
    if stage.execute("SELECT 1 FROM sqlite_master WHERE name=?", (QUEUE_TABLE,)).fetchone():
        raise RuntimeError("Recovery queue exists without its checkpoint; refusing to reset it")
    state = {"context": context.identity(), "phase": "preparing", "lastId": "",
             "preparedMentions": 0, "remainingMentions": 0}
    with transaction(stage):
        stage.execute(f"CREATE TABLE {CHECKPOINT_TABLE}(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
        stage.execute(f"CREATE TABLE {QUEUE_TABLE}(id TEXT PRIMARY KEY,signature TEXT NOT NULL)")
        _save_state(stage, state)
    return state


def _report(progress, state, phase):
    total = state["context"]["expected_mentions"]
    fields = {"status": "running", "phase": phase, "preparedMentions": state["preparedMentions"],
              "proseMentions": total, "preparationLastID": state["lastId"], "recoveryVersion": VERSION}
    if phase == "preparingEmbeddings":
        fields.update(cachedPreparedMentions=state["preparedMentions"] - state["remainingMentions"],
                      pendingPreparedMentions=state["remainingMentions"])
    else:
        fields.update(pendingMentions=state["remainingMentions"], embeddedMentions=total - state["remainingMentions"])
    progress.update(**fields)


def _cache_entry(stage, signature, context, *, include_embedding=False):
    columns = "model,embedding" if include_embedding else "model"
    row = stage.execute(f"SELECT {columns} FROM sentence_vectors WHERE signature=?", (signature,)).fetchone()
    if row and row[0] != context.model:
        raise RuntimeError("Existing vector has the wrong model for signature " + signature)
    return row


def validate_resume_context(stage, context):
    """Validate frozen source/runtime identity without creating schema or importing vectors."""
    return _load_state(stage, context)


def _validate_counts(stage, context, state, *, validated_source_count=None):
    _validate_source(stage, context)
    source = (stage.execute("SELECT count(*) FROM narrative_events").fetchone()[0]
              if validated_source_count is None else validated_source_count)
    derived = stage.execute("SELECT count(*) FROM embedding_events").fetchone()[0]
    pending = stage.execute(f"SELECT count(*) FROM {QUEUE_TABLE}").fetchone()[0]
    if source != context.expected_mentions or state["preparedMentions"] != source:
        raise RuntimeError("Recovery has not visited every authoritative source mention")
    # Every source ID has been inserted. Equal cardinality then excludes extra IDs.
    if derived != source:
        raise RuntimeError("Derived embedding rows include extra or missing source IDs; refusing deletion")
    if pending != state["remainingMentions"]:
        raise RuntimeError("Recovery queue and durable mention count disagree")


def prepare_mentions(stage, context, progress, batch_size=MAX_PREPARATION_BATCH):
    if not 1 <= batch_size <= MAX_PREPARATION_BATCH:
        raise ValueError("Preparation batches must contain 1–2000 source rows")
    state = _load_state(stage, context)
    return _prepare_validated_mentions(stage, context, progress, batch_size, state)


def _prepare_validated_mentions(stage, context, progress, batch_size, state):
    """Continue after this invocation's read-only source/runtime validation."""
    if state is None:
        state = _initialize(stage, context)
    if state["phase"] != "preparing":
        _validate_counts(stage, context, state, validated_source_count=context.expected_mentions)
        return state
    _report(progress, state, "preparingEmbeddings")
    while True:
        rows = stage.execute("SELECT id,payload FROM narrative_events WHERE id>? ORDER BY id LIMIT ?",
                             (state["lastId"], batch_size)).fetchall()
        if not rows:
            break
        prepared, missing = [], []
        for identifier, payload in rows:
            event = json.loads(payload)
            if event["id"] != identifier:
                raise RuntimeError("Source payload ID differs from its authoritative row ID")
            signature = scalable.signature(event, context.model)
            prepared.append((identifier, signature, payload))
            if _cache_entry(stage, signature, context) is None:
                missing.append((identifier, signature))
        updated = {**state, "lastId": rows[-1][0],
                   "preparedMentions": state["preparedMentions"] + len(rows),
                   "remainingMentions": state["remainingMentions"] + len(missing)}
        with transaction(stage):
            stage.executemany("""INSERT INTO embedding_events(id,signature,payload) VALUES(?,?,?)
                ON CONFLICT(id) DO UPDATE SET signature=excluded.signature,payload=excluded.payload
                WHERE embedding_events.signature IS NOT excluded.signature
                   OR embedding_events.payload IS NOT excluded.payload""", prepared)
            stage.executemany(f"INSERT INTO {QUEUE_TABLE} VALUES(?,?)", missing)
            _save_state(stage, updated)
        state = updated
        _report(progress, state, "preparingEmbeddings")
    _validate_counts(stage, context, state)
    state = {**state, "phase": "prepared"}
    with transaction(stage):
        _save_state(stage, state)
    _report(progress, state, "embeddingPreparationReady")
    return state


def _validate_vector(vector, dimensions):
    if (not isinstance(vector, list) or len(vector) != dimensions
            or not all(type(value) in (int, float) and math.isfinite(value) for value in vector)
            or abs(math.sqrt(sum(value * value for value in vector)) - 1) >= 0.0001):
        raise RuntimeError("Recovered embedding is not a finite unit vector of the expected dimension")


class GuardedCacheConnection:
    """Validate the pinned batch helper's cache imports before any SQLite write."""
    def __init__(self, stage, context):
        self.stage, self.context = stage, context

    @property
    def in_transaction(self):
        return self.stage.in_transaction

    def execute(self, sql, parameters=()):
        if sql.upper().startswith("INSERT OR REPLACE INTO SENTENCE_VECTORS"):
            signature, model, embedding = parameters
            if model != self.context.model or not re.fullmatch(r"[0-9a-f]{64}", signature):
                raise RuntimeError("Embedding output model or signature differs from the frozen context")
            vector = json.loads(embedding)
            _validate_vector(vector, self.context.dimensions)
            existing = _cache_entry(self.stage, signature, self.context, include_embedding=True)
            if existing and json.loads(existing[1]) != vector:
                raise RuntimeError("Embedding output conflicts with an authoritative cached vector")
            return self.stage.execute("INSERT OR IGNORE INTO sentence_vectors VALUES(?,?,?)", parameters)
        return self.stage.execute(sql, parameters)

    def commit(self):
        self.stage.commit()


def recover_output_prefix(stage, output, context):
    """Validate source/runtime identity, then import only a checked raw prefix."""
    _load_state(stage, context)
    return _recover_validated_output_prefix(stage, output, context)


def _recover_validated_output_prefix(stage, output, context):
    """Ignore partial final lines; validate the complete prefix before importing."""
    output = Path(output)
    if not output.exists() or not output.stat().st_size:
        return 0
    records = []
    with output.open() as file:
        first = next(file, "")
        if not first.endswith("\n"):
            return 0
        metadata = json.loads(first)
        if metadata.get("model") != context.model or metadata.get("dimensions") != context.dimensions:
            raise RuntimeError("Raw embedding header model or dimensions differ from the frozen context")
        for line in file:
            if not line.endswith("\n"):
                break
            record = json.loads(line)
            _validate_vector(record["embedding"], context.dimensions)
            if not re.fullmatch(r"[0-9a-f]{64}", record["id"]):
                raise RuntimeError("Raw embedding output contains an invalid signature")
            records.append(record)
            if len(records) > EMBEDDING_BATCH:
                raise RuntimeError("Raw embedding prefix exceeds the bounded batch size")
    # Check all existing records first, so a conflict never partially imports.
    for record in records:
        existing = _cache_entry(stage, record["id"], context, include_embedding=True)
        if existing and json.loads(existing[1]) != record["embedding"]:
            raise RuntimeError("Raw embedding output conflicts with an authoritative cached vector")
    guarded = GuardedCacheConnection(stage, context)
    with transaction(stage):
        for record in records:
            guarded.execute("INSERT OR REPLACE INTO sentence_vectors VALUES(?,?,?)",
                            (record["id"], context.model, json.dumps(record["embedding"], separators=(",", ":"))))
    return len(records)


def embed_mentions(stage, data, model, progress, *, context, batch_size=MAX_PREPARATION_BATCH):
    if model != context.model:
        raise RuntimeError("Build model differs from the frozen recovery context")
    if not 1 <= batch_size <= MAX_PREPARATION_BATCH:
        raise ValueError("Preparation batches must contain 1–2000 source rows")
    # Check identity before schema creation or importing a recoverable raw prefix.
    state = _load_state(stage, context)
    _recover_validated_output_prefix(stage, Path(data) / "raw/full-embeddings.jsonl", context)
    state = _prepare_validated_mentions(stage, context, progress, batch_size, state)
    if state["phase"] == "complete":
        return context.expected_mentions
    while True:
        rows = stage.execute(f"""SELECT p.id,p.signature,e.payload FROM {QUEUE_TABLE} p
            JOIN embedding_events e ON e.id=p.id ORDER BY p.id LIMIT ?""", (EMBEDDING_BATCH,)).fetchall()
        if not rows:
            break
        records = {}
        for identifier, signature, payload in rows:
            if _cache_entry(stage, signature, context) is None:
                event = json.loads(payload)
                records[signature] = {"id": signature, "title": event["title"], "summary": event["summary"]}
        if records:
            if stage.in_transaction:
                raise RuntimeError("Embedding batch must start outside any queue transaction")
            try:
                metadata = scalable.embedding_batch(GuardedCacheConnection(stage, context),
                    list(records.values()), Path(data), context.model)
                if metadata.get("model") != context.model or metadata.get("dimensions") != context.dimensions:
                    raise RuntimeError("Embedding batch metadata differs from the frozen context")
                for signature in records:
                    row = _cache_entry(stage, signature, context, include_embedding=True)
                    if row is None:
                        raise RuntimeError("Embedding batch omitted signature " + signature)
                    _validate_vector(json.loads(row[1]), context.dimensions)
            except BaseException:
                stage.rollback()
                raise
        updated = {**state, "phase": "embedding"}
        with transaction(stage):
            removed = 0
            # Delete only this bounded mention batch. Shared signatures may cover
            # arbitrarily many mentions; subsequent batches prune their cache hits.
            for identifier, _, _ in rows:
                removed += stage.execute(f"DELETE FROM {QUEUE_TABLE} WHERE id=?", (identifier,)).rowcount
            updated["remainingMentions"] -= removed
            _save_state(stage, updated)
        state = updated
        _report(progress, state, "embedding")
    _validate_counts(stage, context, state)
    if state["remainingMentions"]:
        raise RuntimeError("Pending mentions could not be joined to prepared source rows")
    state = {**state, "phase": "complete"}
    with transaction(stage):
        _save_state(stage, state)
    _report(progress, state, "embeddingComplete")
    return context.expected_mentions
