# Chronoscope

A native SwiftUI iPhone event atlas, inspired by Cipher's walkable word sphere.
Events live in three-dimensional meaning space; time is an independent fourth
dimension. Drag to look, pinch to zoom, use the walking controls, or tap a nearby
event. The trail records where you have walked.

The time window ranges from millennia to days. Exact date entry supports BCE and
CE, leap days, and source precision. Records with only a year/month date retain
that uncertainty. A focus retained outside the window is labeled as pinned.
The geographic view uses recorded coordinates; unknown positions stay in
meaning space.

The 7 Degrees tab searches either the downloaded event graph or arbitrary live
Wikipedia topics. Every hop shows its evidence and direction. Documented
hyperlinks mean an article connects the topics; they do not imply historical
causation. Vector suggestions show genuine cosine similarity and are visibly
separate from documented statements. Live topic searches have explicit resource
bounds and can fail to discover an existing route.

## Run

Requires Xcode, XcodeGen, and iOS 26 or newer.

```sh
xcodegen generate
open Chronoscope.xcodeproj
```

Select the Chronoscope scheme and an iPhone destination. The app bundles a
downloaded, attributed Wikimedia collection and works offline with that catalog.
Larger .sqlite indexes can be imported through Corpus & sources. Imports are
copied into the app's own storage and retained across launches.
JSON imports are capped at 64 MiB. Use SQLite for larger catalogs.

On this Mac, Xcode file coordination under iCloud-backed Documents can stall.
The helper below builds a SHA256-verified mirror of App/Core/project.yml in
local temporary storage, preserving the original source as the editable project:

```sh
python3 scripts/build-native.py --simulator 9AC0979F-7162-42A7-A2BD-FB3CC1D6439D
```

Debug builds accept `--import-atlas /absolute/path/to/catalog.sqlite` as a launch
argument. It runs the same native importer for repeatable copy, query, and
persistence verification. This option is absent from release builds.

## Download and index Wikipedia

The long-running `Tools/corpus.py full --snapshot 20261001` job resumes the pinned
English Wikipedia article dump, verifies its official size and SHA1, extracts
dated event records, embeds summaries, and exports a SQLite index automatically.
The full download does not mean all events have been extracted. The current
extractor admits supported event infoboxes and explicitly dated Wikidata event
classes. Narratives, missing dates, unsupported calendars, and events absent
from Wikipedia remain outside its coverage.

Progress is recorded in Data/download-status.json, Data/ingest-status.json, and
Data/catalog-status.json. Raw downloads are intentionally excluded from Git.
The bulk data files must remain present until verification/ingestion finishes.
The one-off `scripts/refresh-native-after-ingest.py` helper waits for the verified
full archive and completed ingestion, validates the new bundle, runs Core tests,
and rebuilds the native app without changing a running Simulator. Its status and
log are in Data/native-refresh-status.json and Data/native-refresh.log.
Copy Data/atlas.sqlite to Files on the iPhone, then import it. Indexed temporal,
text, and graph queries keep views bounded rather than loading the full corpus.
Approximate vector buckets select on-disk candidates; cosine reranking measures
their actual similarity. This is not an exhaustive nearest-neighbor guarantee.

See [Tools/README.md](Tools/README.md) for reproducible ingestion and attribution,
and [Core/README.md](Core/README.md) for date, graph, and database contracts.

## Verify

```sh
swift test --package-path Core
python3 Tools/validate_catalog.py App/Resources/catalog.json
```

Core checks cover evidence, reversal, hop limits, disconnected graphs, invalid
vectors, BCE dates, leap-day navigation, source precision, filtered SQLite
queries, transactional validation, and indexed similarity candidates. Simulator
verification is recorded separately from physical-device runtime.


## Public snapshot

See [PUBLICATION.md](PUBLICATION.md) for publication exclusions and setup requirements.
