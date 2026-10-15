# Wikimedia corpus pipeline

This is a real ingestion pipeline, not a generated historical dataset. All downloaded
responses are cached by request URL. It needs Python 3, system `curl`, Swift, and
macOS's English NaturalLanguage sentence embedding model. NumPy accelerates exact
cosine neighbor generation for catalogs smaller than 10,000 records.

Run from the Chronoscope directory:

```sh
python3 Tools/corpus.py bootstrap
python3 Tools/corpus.py download --snapshot 20261001 --first-shard
python3 Tools/corpus.py ingest Data/downloads/enwiki-20261001-pages-articles-multistream1.xml-p1p41242.bz2
python3 Tools/corpus.py full --snapshot 20261001
python3 Tools/validate_catalog.py App/Resources/catalog.json
python3 Tools/corpus.py export-json --output Data/full-catalog.json
```

The `full` command resumes the official 26,917,225,724-byte October 2026 English
Wikipedia article multistream snapshot. It verifies its size and SHA1 against
the dated Wikimedia manifest before extracting events. It downloads the English
article namespace plus the other namespaces included by that official export;
it does not download Wikipedia's media files, every language, or edit histories.
The dated snapshot is pinned so a changing `latest` symlink cannot corrupt a resume.
The `download` command only downloads; `full` downloads and then indexes.

Downloads use one connection per process. Run no more than three Wikimedia
connections at once, including API queries. Bootstrap requests are sequential
and paced to less than ten anonymous requests per minute. Transient HTTP errors
are retried; stop/restart uses the existing partial file and response cache.

`Data/download-status.json` records actual bytes, official expected size and SHA1,
status, and process ID. `Data/ingest-status.json` records actual scanned pages and
extracted events. `Data/catalog-status.json` records exact exported counts and
coverage. A `.part` download is not a verified completed corpus.

The native app's bootstrap file is `App/Resources/catalog.json`, bounded to 3,500
events even when full extraction produces a much larger corpus. It retains
structured anchors and samples across epochs. Its coverage string reports both
bundle and full-index counts. An explicit `export-json` command can write the
entire extracted index separately without growing the phone app bundle.
`Data/atlas.sqlite` provides events, FTS5 search, indexed temporal ranges, sourced
edges, embeddings inside event payloads, and metadata. It uses the same SQLite
schema as `ChronoscopeCore.AtlasCatalogStore` and can be imported through the app.
Exports checkpoint all committed data and close in DELETE journal mode, so the
standalone `.sqlite` file can be copied and opened read-only without WAL sidecars.
`Data/articles.sqlite` stages event article extraction independently of the
bootstrap. No uncompressed full XML copy is required.

For large imports, event payloads, sourced edges, and vectors stream into a
separate build database. Only title-to-ID lookup and the bounded app bundle are
held in memory. The validated portable index replaces `Data/atlas.sqlite`
atomically; the preceding index remains usable during extraction and embedding.
Sentence vectors are cached by model revision, title, and summary in SQLite,
committed every 512 records. A complete NDJSON prefix left by interruption is
recovered before embedding restarts. Completed extraction is fingerprinted by
source path, size, modification time, and parser code, so subsequent runs can reuse it;
interruption during XML parsing still requires rescanning the compressed stream.
No extra archive or model download is performed for these caches.

Finalization validates every event vector and its exact LSH buckets, SQLite
integrity/counts/edge endpoints, and the bounded JSON bundle. Only then is ingest
status set to `complete`. `Data/validation-status.json` records exact validated
counts. Extraction/embedding/indexing/validation phases and failures are recorded
in `Data/ingest-status.json`; a failed command exits nonzero and can be rerun with
the same `full --snapshot` command without deleting archive bytes or vector cache.

## What counts as an event

An independent article-prose pass now supplements these structured records.
Run `python3 Tools/narrative_pipeline.py run` against the already verified full
archive. It scans history sections, timeline lists and ordinary article prose,
keeps source passages and their date basis, and exports a merged portable index
to `Data/narrative/atlas.sqlite`. It never rewrites the active structured job's
stage or output. Embedding begins after that job has completed validation.
Progress is in `Data/narrative-status.json`. Resume with the same command;
a process lock prevents duplicates and durable checkpoints retain extracted
records and completed vectors. Interrupted XML scans must decompress the prefix
again, but skip already committed pages. Use a separate data/status path and
`extract --max-pages N` for bounded QA; bounded samples cannot be published as
the full prose corpus.

The app can display multiple sourced statements from one article. Their
provenance includes article/page/revision, section, quote and explicit-date or
section-year grounding. Prose counts refer to dated source statements, with
local duplicates removed; cross-article historical event identity is not yet
resolved. Only sentence-local hyperlinks supply documented prose edges.
See [article-prose extraction](../Documentation/narrative-extraction.md) for
admission rules, validation, scope and remaining limitations.

The Wikidata bootstrap queries explicitly classified dated battles, wars,
conflicts, rebellions, revolutions, protests, disasters, earthquakes, volcanic
eruptions, epidemics, spaceflights, treaties, and events with English articles.
It uses `P580`/`P582` or `P585`, with launch/landing dates as applicable. Person
birth/death dates and topic founding/publication dates are not converted to events.

Bulk extraction admits only supported event infoboxes with a parseable date.
It preserves revision IDs, title, source article URL, date precision, and direct
article links. It currently extracts numeric decimal coordinates; unsupported
coordinate/date forms remain missing. This deliberately conservative first pass
does not claim exhaustive extraction, even after the download finishes.

Time values are astronomical decimal years: year 0 is 1 BCE, -1 is 2 BCE.
Wikidata's historical negative-year numbering is converted. Decimal fractions use
proleptic Gregorian year lengths. Source calendar model, uncertainty qualifiers,
and historical Julian-to-Gregorian conversion are not yet modeled. Year/month
precision dates are conservative possible-date windows covering that source
period; they must not be interpreted as continuous event activity. Day precision
points stay points. Statistical confidence intervals are not available.

## Relationship evidence and embeddings

`wikiLink` edges identify a source article hyperlink at a recorded revision.
When API and dump records overlap, each edge cites the revision whose text
provided its link; that revision can differ from the event summary's revision.
They show a documented mention, not proof of causation. `wikidata` edges retain
typed properties including part-of, follows, followed-by, has-cause, has-effect,
and named-after, plus statement/source identifiers. Unreferenced Wikidata
statements remain Wikidata claims; their presence is not independent verification.

The Swift helper uses **Apple NaturalLanguage English sentence embeddings,
revision 1, 512 dimensions**, on title plus summary, normalized to unit length.
`semantic` edges are exact cosine top-three neighbors above 0.62. They are labeled
"similar meaning" and explicitly say semantic association is not a documented
historical relationship. Semantic edges must never be presented as cause/effect
or as an evidence-only degrees-of-separation chain. All-pairs neighbor export is
skipped above 10,000 events. SQLite stores sixteen deterministic sparse random
hyperplane LSH buckets per vector (`sparse-xorshift32-v1-16x8x8`); the native store
retrieves at most 1,024 candidates and reranks them by exact cosine. Candidate
retrieval is approximate and can miss a globally closest event. It does not
generate a historical claim or require loading every vector into app memory.

## Sources and reuse

- [Official pinned snapshot manifest](https://dumps.wikimedia.org/enwiki/20261001/dumpstatus.json)
- [Official download index](https://dumps.wikimedia.org/enwiki/20261001/)
- [Wikimedia data-dump documentation](https://meta.wikimedia.org/wiki/Data_dumps)
- [Wikidata Query Service](https://query.wikidata.org/)
- [Wikidata data access and CC0 license](https://www.wikidata.org/wiki/Wikidata:Data_access)
- [Wikipedia text reuse and attribution requirements](https://en.wikipedia.org/wiki/Wikipedia:Copyrights)

Wikipedia text must retain source attribution and its applicable share-alike
license when redistributed. Each exported event retains an article URL and,
when available, its exact revision. Wikidata structured data is CC0.
