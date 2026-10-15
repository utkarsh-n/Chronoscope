# Article-prose event extraction

The first full archive pass admits supported dated event infoboxes and a
Wikidata bootstrap. It produced 78,101 extracted article records, plus the
bootstrap's additional records. It intentionally skips history, timeline and
list articles. That count is a consequence of its admission rules, rather than
the number of events described in Wikipedia.

The second pass scans article text, including history sections, timeline lists,
biographies, inventions, publications and institutions. It selects statements
with an explicit date and occurrence language, or a dated list item grounded in
an explicit year heading or calendar article title. Calendar-day lists combine
the leading year with the article's month and day; births and deaths are
attributed to the list section, rather than an opposite life date in parentheses.
References, infobox fields, captions and citation
publication dates are excluded. Planned and negated occurrences are rejected.
Unsupported or ambiguous dates are skipped; day, month and year precision remain
separate. Unbounded qualifiers such as “circa”, incomplete year ranges and
ambiguous competing dates are skipped instead of being assigned exact bounds.

Each prose record keeps its source article, page and revision IDs, section,
cleaned displayed quote, raw wikitext passage, date expression, date basis and
extraction method. These fields describe how the record was obtained; confidence
labels are rule categories, not calibrated probabilities. The app shows the
source passage and distinguishes explicit dates from dates supplied partly by a
section heading or calendar article title. Every record opens the recorded source revision.

Repeated local claims are deduplicated by their source page, normalized passage
and date. Display titles and source URLs are not unique keys: one article can
contain many records. Similar statements from different articles remain distinct
source records until a common historical event identity can be verified. Counts
therefore mean **sourced dated statements**, rather than globally unique events.

Documented graph edges use only hyperlinks in the selected sentence and target
an unambiguous structured event. An entire article's links are never inherited by
all its prose records. Shared source articles do not establish a causal
relationship. Existing structured links remain intact. Sentence embeddings and
the native similarity index provide additional clearly marked suggestions.

The prose pass uses its own `Data/narrative/prose-stage.sqlite`, embedding files,
portable `Data/narrative/atlas.sqlite` and status files. It leaves the current
infobox extraction, vector cache and `Data/atlas.sqlite` unchanged. Text scanning
can proceed in parallel; vector generation waits for the structured pass to
finish. A persistent vector cache and an indexed remaining-work queue avoid
reprocessing completed batches. The merged export reuses all validated structured records and vectors,
then adds prose records. Publication is atomic after complete schema, vector,
bucket, endpoint and provenance validation. A bounded QA sample can never satisfy
the full export gate.

The existing phone follow-up will install the complete validated structured
index as its first milestone, then the prose-expanded index when ready. It must
package the complete SQLite artifact and preserve explicitly imported catalogs.
It remains active until the expanded installation is verified.

Progress is recorded in `Data/narrative-status.json`; extraction checkpoints and
final validation/counts are in `Data/narrative/`. The validated 2,000-page real-dump pilot produced 24,338 sourced statements;
its calendar-heavy prefix is not a basis for a corpus-wide count estimate.
The pilot, 106 Python checks, 26 Core checks and a six-record real-vector native
UI exercise are recorded in `Documentation/Checks/`. Broader admission adds
processing work, so the earlier structured-only ETA does not cover this pass.

This is a deterministic extractor for dated prose, not exhaustive event
understanding. It misses implicit references such as “the following spring”,
unsupported calendars and phrasing, and events without a defensible date.
Historically distinct events can share dates, while one event can have several
source records. Quote retention makes these limitations inspectable.

Reference syntax follows the source's
[MediaWiki wikitext conventions](https://www.mediawiki.org/wiki/Help:Wikitext_examples).
Temporal expression recognition and event admission are separate decisions;
[Stanford's temporal-language examples](https://nlp.stanford.edu/projects/time.shtml)
illustrate why a number or date-like phrase alone is insufficient.

The full prose worker was started on 2026-10-11 at 00:41 UTC. Its launch identity
and command are in `Data/narrative/launch.json`, and its log is
`Data/narrative/pipeline.log`. The pipeline and parser fingerprints are immutable
for this run; changing either source file invalidates resumed extraction.
