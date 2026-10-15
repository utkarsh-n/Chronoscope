# Public source snapshot

This repository contains a reviewed source snapshot. Original Git history, credentials, personal records, local signing identities, device diagnostics, build outputs, downloaded model weights, firmware, and unreviewed media are excluded. Existing upstream license and attribution files apply to their respective components. Publication does not grant a new license to third-party content.

Configure your own Apple signing team to run native apps on a physical device. Downloaded datasets, binary runtimes, fonts, demo media, and models may need to be obtained separately using the documented upstream sources or fetch/build tools. This publication review does not certify that this snapshot builds or runs.

## Project setup and omitted assets

`Data/` is omitted in full: downloaded Wikipedia dumps, article/event indexes, SQLite/WAL state, caches and pipeline progress are development data. The retained `App/Resources/catalog.json` is the fixed attributed Wikimedia starter collection. Each exported event retains source article links. Wikipedia-derived summaries retain CC BY-SA requirements; Wikidata-derived structured facts use CC0. Preserve `Tools/README.md` and the app's source/attribution view when redistributing the catalog.

To create a new starter catalog use `python3 Tools/corpus.py bootstrap`; full corpus/index creation is optional and documented in `Tools/README.md`. The full pipeline may download tens of gigabytes and requires substantial extra storage. Device/process reports and host diagnostics are omitted. `Tools/monitor_narrative_worker.py` now derives its project root from its own location; it still expects the documented complete local pipeline state.
