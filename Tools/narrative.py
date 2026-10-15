"""Conservative dated-occurrence extraction from Wikipedia article prose.

This module performs no IO, networking, embeddings, or job startup. The public
iterator yields AtlasEvent-compatible dictionaries with additional provenance.
``sourceQuote`` is an exact slice of the original wikitext; ``quote`` is its
readable rendering with citations/formatting removed. Sentence-local wikilinks
are evidence of article links, never evidence of causation.

Recall is deliberately limited: unsupported calendar expressions, conflicting
dates, uncertain attribution, negated occurrences, and future plans are skipped.
Unbounded approximate/before/after dates are skipped rather than assigned a
fabricated finite interval. Coordinates are never inherited
from the article, because its subject's location need not locate an occurrence.
"""
import calendar
import datetime as dt
import hashlib
import html
import re
import unicodedata
import urllib.parse
from dataclasses import dataclass

from corpus import decimal_date, leap, precision_upper, split_template


EXTRACTION_VERSION = "dated-prose-v1"
_MONTHS = {name.lower(): number for number, name in enumerate(calendar.month_name) if name}
_MONTHS.update({name.lower(): number for number, name in enumerate(calendar.month_abbr) if name})
_MONTHS["sept"] = 9
_MONTH = r"(?:" + "|".join(sorted(_MONTHS, key=len, reverse=True)) + r")\.?"
_ERA = r"(?:B\.?C\.?E?|C\.?E|A\.?D)"
_YEAR = r"\d{1,5}"
_DMY = re.compile(r"\b(?P<day>\d{1,2})(?:st|nd|rd|th)?\s+(?P<month>" + _MONTH + r")\s+(?P<year>" + _YEAR + r")(?:\s*(?P<era>" + _ERA + r"))?\b", re.I)
_MDY = re.compile(r"\b(?P<month>" + _MONTH + r")\s+(?P<day>\d{1,2})(?:st|nd|rd|th)?[,]?\s+(?P<year>" + _YEAR + r")(?:\s*(?P<era>" + _ERA + r"))?\b", re.I)
_MY = re.compile(r"\b(?P<month>" + _MONTH + r")\s+(?P<year>" + _YEAR + r")(?:\s*(?P<era>" + _ERA + r"))?\b", re.I)
_ISO = re.compile(r"(?<!\d)(?P<year>\d{4})-(?P<month>\d{2})-(?P<day>\d{2})(?!\d)")
_YEAR_RANGE = re.compile(r"\b(?:(?P<anchor>between|from|during|in)\s+)?(?P<first>\d{1,5})\s*(?P<join>[–—-]|to|and)\s*(?P<last>\d{1,5})(?:\s*(?P<era>" + _ERA + r"))?\b", re.I)
_ERA_YEAR = re.compile(r"\b(?:(?P<prefix>AD|CE)\s+(?P<pyear>" + _YEAR + r")|(?P<year>" + _YEAR + r")\s*(?P<era>" + _ERA + r"))\b", re.I)
_ANCHORED_YEAR = re.compile(r"\b(?P<anchor>in|during|circa|around|approximately|about)\s+(?:(?P<prefix>AD|CE)\s+)?(?P<year>\d{3,4})(?:\s*(?P<era>" + _ERA + r"))?\b|(?<!\w)(?P<short>c\.|ca\.)\s*(?P<shortyear>\d{3,4})\b", re.I)
_LEADING_YEAR = re.compile(r"^\s*(?P<year>\d{1,5})(?:\s*(?P<era>" + _ERA + r"))?\s*(?:[–—:.-]|$)", re.I)
_PARTIAL_DM = re.compile(r"\b(?P<day>\d{1,2})(?:st|nd|rd|th)?\s+(?P<month>" + _MONTH + r")\b", re.I)
_PARTIAL_MD = re.compile(r"\b(?P<month>" + _MONTH + r")\s+(?P<day>\d{1,2})(?:st|nd|rd|th)?(?!\d)\b", re.I)
_DATE_HINT = re.compile(r"\b\d{3,4}\b|\b\d{1,5}\s*" + _ERA + r"\b|\b(?:AD|CE)\s*\d+\b|\b\d{1,2}\s+" + _MONTH + r"\b|\b" + _MONTH + r"\s+\d{1,2}\b", re.I)
_HEADING = re.compile(r"^\s*(={2,6})\s*(.*?)\s*\1\s*$")
_SKIP_SECTIONS = re.compile(r"^(?:references?|bibliography|bibliographies|notes?|footnotes?|endnotes?|citations?|sources?|external links?|further reading|works cited|publications|filmography|discography|plot|plot summary|synopsis|fictional biography|in popular culture)$", re.I)
_EXCLUDED_TAGS = re.compile(r"<(ref|gallery|timeline|math|code|syntaxhighlight|nowiki|pre|blockquote|figcaption|caption)\b[^>]*>.*?</\1\s*>|<ref\b[^>]*/\s*>|<!--.*?-->", re.S | re.I)
_NAMESPACES = {"file", "image", "category", "template", "help", "wikipedia", "portal", "special", "media", "talk"}
_DATE_TEMPLATES = re.compile(r"^(?:start date(?: and age)?|end date(?: and age)?|date(?: and age)?|birth date(?: and age)?|death date(?: and age)?|dts|launch date)$", re.I)
_OCCURRENCE = re.compile(r"\b(?:born|died|killed|assassinated|executed|married|divorced|buried|elected|crowned|inaugurated|appointed|won|lost|defeated|captured|invaded|attacked|signed|ratified|declared|adopted|enacted|passed|approved|founded|established|created|opened|closed|launched|landed|lifted off|took off|arrived|departed|discovered|invented|introduced|released|published|completed|constructed|reconstructed|rebuilt|built|collapsed|exploded|erupted|struck|sank|broke out|occurred|took place|began|started|ended|ceased|annexed|joined|merged|split|demolished|replaced|abolished|proclaimed|recognized|baptized|converted|graduated|resigned|abdicated|overthrew|arrested|escaped|settled|migrated|traveled|travelled|performed|awarded|commissioned|unveiled|presented|returned|reached|flew|met|visited|renamed|admitted|announced|sued|opted|forced)\b", re.I)
_LIST_OCCURRENCE = re.compile(r"\b(?:birth of|death of|assassination of|coronation of|election of|battle of|siege of|earthquake|eruption|massacre|invasion|treaty|revolution|coup|flood|explosion|outbreak|launch of|landing of|opens|closes|lands|launches|signs|declares|invades|dies|is born|begins|ends|wins|defeats|arrives|erupts|is founded|is established|is released|is published)\b", re.I)
_FUTURE = re.compile(r"\b(?:will|would|planned|planning|plans|scheduled|proposed|proposal|expected|expects|intended|intends|anticipated|aims|hopes|due to be|set to|going to)\b", re.I)
_NEGATED = re.compile(r"\bnever\b|\b(?:did|was|were|has|had|is|are|have|could)\s+not\b|\b(?:didn't|wasn't|weren't|hasn't|hadn't|isn't|aren't)\b", re.I)
_ATTRIBUTED = re.compile(r"\b(?:according to|claimed that|claims that|reportedly|allegedly|believed to|legend|tradition holds|states? that|reports? that|reported that|depicts?|depicted|set in|fictional|story takes place)\b", re.I)
_CONDITIONAL = re.compile(r"\b(?:if|unless|whether|hypothetically|counterfactual)\b", re.I)
_UNBOUNDED_DATE = re.compile(r"\b(?:circa|around|approximately|about|before|after|by|since|prior to|later than|earlier than)\s+(?:\d|" + _MONTH + r")|(?<!\w)(?:c\.|ca\.)\s*\d", re.I)
_ABBREVIATIONS = {"mr", "mrs", "ms", "dr", "prof", "st", "mt", "gen", "lt", "col", "capt", "rev", "sr", "jr", "inc", "ltd", "no", "vol", "pp", "ed", "eds", "e.g", "i.e", "c", "ca", "approx"} | set(_MONTHS)
_ENTITY_WORD = r"(?:[A-ZÀ-ÖØ-Þ][\w’'-]+|[A-Z]\.|[A-Z]{2,}|\d+)"
_ENTITY = re.compile(r"\b" + _ENTITY_WORD + r"(?:\s+(?:(?:of|the|de|van|von|and)\s+)?" + _ENTITY_WORD + r"){1,5}")
_BACKGROUND_VERB = re.compile(r"\b(?:had|was|were|is|are|has|have|remained|contained|included|seemed|appeared|became|lived|existed|served|ruled|reigned|gained)\b", re.I)
_SHORT_RANGE = re.compile(r"\b\d{3,4}\s*[–—-]\s*\d{1,2}(?!\d)")
_YEAR_WORD = re.compile(r"\b\d{3,4}\b")
_QUANTITY_UNIT = re.compile(r"\s+(?:people|persons|men|women|residents|soldiers|troops|votes|seats|copies|specimens|kilometres?|kilometers?|metres?|meters?|km|m|tons?|tonnes?|dollars?|pounds?|USD|GBP|euros?)\b", re.I)
_BIO_PARENTHETICAL = re.compile(r"\((?:born|died|b\.|d\.)\s+[^()]*\)", re.I)


@dataclass(frozen=True)
class DateMention:
    start: float
    end: float
    precision: str
    text: str
    begin: int
    stop: int
    basis: str = "explicit"
    uncertainty: str = ""
    covered: tuple = ()


def has_date_candidates(text):
    """Cheap safe prefilter; date templates and year headings also match."""
    return bool(_DATE_HINT.search(text))


def _calendar_year(year, era, reference_year):
    number = int(year)
    if number < 1:
        return None
    if (era or "").upper().replace(".", "").replace(" ", "") in {"BC", "BCE"}:
        return 1 - number
    if number > reference_year:
        return None
    return number


def _date(year, month, day, era, precision, reference_year):
    year = _calendar_year(year, era, reference_year)
    if year is None:
        return None
    month = int(month) if str(month).isdigit() else _MONTHS.get(str(month).lower().rstrip("."))
    day = int(day)
    if month is None or not 1 <= month <= 12:
        return None
    days = (31, 29 if leap(year) else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)
    if not 1 <= day <= days[month - 1]:
        return None
    start = decimal_date(year, month, day)
    return start, precision_upper(start, precision)


def _date_template(raw):
    fields = split_template(raw[2:-2])
    if not fields or not _DATE_TEMPLATES.fullmatch(fields[0].strip().replace("_", " ")):
        return None
    digits = [part.strip() for part in fields[1:] if re.fullmatch(r"\d{1,5}", part.strip())]
    if not digits:
        return None
    year = digits[0]
    suffix = " BCE" if any(re.fullmatch(r"\s*bc\s*=\s*(?:yes|true|1)\s*", part, re.I) for part in fields[1:]) else ""
    if len(digits) >= 2 and not 1 <= int(digits[1]) <= 12:
        return None
    if len(digits) >= 3:
        return f"{digits[2]} {calendar.month_name[int(digits[1])]} {year}{suffix}"
    if len(digits) >= 2 and 1 <= int(digits[1]) <= 12:
        return f"{calendar.month_name[int(digits[1])]} {year}{suffix}"
    return year + suffix


def _balanced_spans(text, opening, closing):
    depth = 0
    start = 0
    # Scan delimiters in C instead of walking every character of large articles.
    for match in re.finditer(re.escape(opening) + "|" + re.escape(closing), text):
        position, pair = match.start(), match[0]
        if pair == opening:
            if depth == 0:
                start = position
            depth += 1
        elif pair == closing and depth:
            depth -= 1
            if depth == 0:
                yield start, match.end()
    if depth:
        # Unclosed markup is unsupported; do not mine its metadata/caption.
        yield start, len(text)


def _blank(text):
    return re.sub(r"[^\n]", " ", text)


def _mask_nonprose(text):
    masked = _EXCLUDED_TAGS.sub(lambda match: _blank(match[0]), text)
    masked = re.sub(r"\{\|.*?\|\}", lambda match: _blank(match[0]), masked, flags=re.S)
    spans = list(_balanced_spans(masked, "{{", "}}"))
    spans += [(a, b) for a, b in _balanced_spans(masked, "[[", "]]")
              if masked[a + 2:b - 2].split(":", 1)[0].strip().lower() in _NAMESPACES]
    excluded = []
    for begin, end in sorted(spans):
        if masked[begin:begin + 2] == "{{" and _date_template(masked[begin:end]) is not None:
            continue
        if excluded and begin <= excluded[-1][1]:
            excluded[-1] = (excluded[-1][0], max(end, excluded[-1][1]))
        else:
            excluded.append((begin, end))
    pieces, previous = [], 0
    for begin, end in excluded:
        pieces.extend((masked[previous:begin], _blank(masked[begin:end])))
        previous = end
    pieces.append(masked[previous:])
    return "".join(pieces)


def _render(raw, offset=0):
    """Render inline markup while mapping every output char to original offsets."""
    characters, mapping = [], []

    def append(value, begin, end):
        for char in value:
            char = " " if char.isspace() else char
            if char == " " and (not characters or characters[-1] == " "):
                continue
            characters.append(char)
            mapping.append((offset + begin, offset + end))

    position = 0
    while position < len(raw):
        if raw.startswith("[[", position):
            end = raw.find("]]", position + 2)
            if end < 0:
                break
            inside = raw[position + 2:end]
            if "|" in inside:
                label_offset = position + 2 + inside.rfind("|") + 1
                label = inside.rsplit("|", 1)[1]
            else:
                label_offset = position + 2
                label = inside.replace("_", " ")
            rendered, local_map = _render(label, offset + label_offset)
            if local_map:
                # Keep the full link delimiters/target when it begins or ends a
                # sentence, so local link evidence cannot lose its opening [[.
                local_map[0] = (offset + position, local_map[0][1])
                local_map[-1] = (local_map[-1][0], offset + end + 2)
            for char, span in zip(rendered, local_map):
                if char == " " and (not characters or characters[-1] == " "):
                    continue
                characters.append(char); mapping.append(span)
            position = end + 2
            continue
        if raw.startswith("{{", position):
            end = raw.find("}}", position + 2)
            if end < 0:
                break
            value = _date_template(raw[position:end + 2])
            if value is not None:
                append(value, position, end + 2)
            position = end + 2
            continue
        if raw.startswith("''", position):
            while position < len(raw) and raw[position] == "'": position += 1
            continue
        if raw[position] == "<":
            end = raw.find(">", position)
            if end >= 0:
                if re.match(r"<br\b", raw[position:end + 1], re.I): append(" ", position, end + 1)
                position = end + 1
                continue
        if raw[position] == "[" and re.match(r"\[(?:https?://|//)", raw[position:], re.I):
            end = raw.find("]", position)
            if end >= 0:
                inside = raw[position + 1:end]
                label = inside.split(None, 1)
                if len(label) == 2:
                    label_offset = position + 1 + len(label[0]) + 1
                    append(label[1], label_offset, end)
                position = end + 1
                continue
        if raw[position] == "&":
            entity = re.match(r"&(?:#\d+|#x[0-9a-fA-F]+|[A-Za-z]+);", raw[position:])
            if entity:
                append(html.unescape(entity[0]), position, position + len(entity[0]))
                position += len(entity[0])
                continue
        append(raw[position], position, position + 1)
        position += 1
    rendered = "".join(characters)
    if rendered.endswith(" "):
        rendered = rendered[:-1]; mapping = mapping[:-1]
    return rendered, mapping


def _heading_year(title, reference_year):
    match = re.fullmatch(r"(?:(AD|CE)\s+)?(\d{3,4}|\d{1,5}\s+(?:BCE|BC|CE|AD))", title.strip(), re.I)
    if not match:
        return None
    tail = re.fullmatch(r"(\d+)\s*(BCE|BC|CE|AD)?", match[2], re.I)
    return _calendar_year(tail[1], tail[2] or match[1], reference_year)


def _article_day(title):
    names = "|".join(name for name in calendar.month_name if name)
    match = re.fullmatch(r"(" + names + r")\s+(\d{1,2})", title.strip(), re.I)
    if not match: return None
    month, day = _MONTHS[match[1].lower()], int(match[2])
    # February 29 is a valid calendar article; each actual year is validated later.
    if not _date(2000, month, day, "CE", "day", 2026): return None
    return month, day


def _calendar_life_label(section, listed, article_day, quote):
    if not listed or article_day is None or not _LEADING_YEAR.match(quote): return ""
    parts = [part.strip().lower() for part in section.split(" / ")]
    if "births" in parts: return "birth"
    if "deaths" in parts: return "death"
    return ""


def _blocks(text, reference_year, article_year=None, article_title=""):
    masked = _mask_nonprose(text)
    headings, pending = [], []
    heading_counts, heading_ids = {}, set()
    offset = 0

    def current_context():
        year = next((item[2] for item in reversed(headings) if item[2] is not None), None)
        date_context = next((item[1] for item in reversed(headings) if item[2] is not None), "")
        basis = "sectionYear"
        if year is None and article_year is not None:
            year, date_context, basis = article_year, article_title, "articleYear"
        month = next((_MONTHS[item[1].lower().rstrip(".")] for item in reversed(headings)
                      if item[1].lower().rstrip(".") in _MONTHS), None) if year is not None else None
        if month: date_context += " / " + calendar.month_name[month]
        anchor = headings[-1][3] if headings else ""
        return " / ".join(item[1] for item in headings), year, date_context, basis, month, anchor

    def flush():
        if not pending: return None
        start, pieces = pending[0][0], "".join(item[1] for item in pending)
        pending.clear()
        return (start, pieces, False, *current_context())

    for line in masked.splitlines(keepends=True):
        stripped = line.strip()
        heading = _HEADING.fullmatch(stripped)
        if heading:
            block = flush()
            if block: yield block
            level = len(heading[1])
            title, _ = _render(heading[2])
            while headings and headings[-1][0] >= level: headings.pop()
            base = title.replace(" ", "_")
            anchor = ""
            if base:
                count = heading_counts.get(base, 0) + 1
                anchor = base if count == 1 else f"{base}_{count}"
                while anchor in heading_ids:
                    count += 1
                    anchor = f"{base}_{count}"
                heading_counts[base] = count
                heading_ids.add(anchor)
            headings.append((level, title, _heading_year(title, reference_year), anchor))
        elif not stripped:
            block = flush()
            if block: yield block
        elif any(_SKIP_SECTIONS.fullmatch(item[1]) for item in headings):
            pending.clear()
        elif stripped.startswith(("|", "!", ":", ">", "__")):
            block = flush()
            if block: yield block
        elif re.match(r"^[*#;]+\s*", stripped):
            block = flush()
            if block: yield block
            prefix = re.match(r"\s*[*#;]+\s*", line).end()
            yield (offset + prefix, line[prefix:], True, *current_context())
        else:
            pending.append((offset, line))
        offset += len(line)
    block = flush()
    if block: yield block


def sentence_spans(text):
    """Boundaries preserve initials, titles, month abbreviations and U.S./U.K."""
    start = 0
    position = 0
    while position < len(text):
        char = text[position]
        boundary = char in "!?;"
        if char == ".":
            preceding = re.search(r"([\w.]+)$", text[:position])
            word = preceding[1].lower() if preceding else ""
            abbreviation = word in _ABBREVIATIONS or bool(re.fullmatch(r"(?:[a-z]\.)*[a-z]", word))
            decimal = position > 0 and position + 1 < len(text) and text[position - 1].isdigit() and text[position + 1].isdigit()
            boundary = not abbreviation and not decimal
        if boundary:
            stop = position + 1
            while stop < len(text) and text[stop] in '\"”’)]': stop += 1
            if stop == len(text) or text[stop].isspace():
                left = start
                while left < stop and text[left].isspace(): left += 1
                if left < stop: yield left, stop
                start = stop
                position = stop
                continue
        position += 1
    while start < len(text) and text[start].isspace(): start += 1
    if start < len(text): yield start, len(text)


def _find_dates(text, listed, context_year, reference_year, context_basis="sectionYear", context_month=None, article_day=None):
    dates, occupied = [], []
    malformed = False

    def add(match, parsed, precision, basis="explicit", uncertainty=""):
        if parsed is None or any(match.start() < end and match.end() > begin for begin, end in occupied): return
        occupied.append(match.span())
        dates.append(DateMention(*parsed, precision, match[0], match.start(), match.end(), basis, uncertainty))

    for pattern in (_ISO, _DMY, _MDY):
        for match in pattern.finditer(text):
            parsed = _date(match["year"], match["month"], match["day"], match.groupdict().get("era"), "day", reference_year)
            if parsed is None: malformed = True
            add(match, parsed, "day")
    if malformed: return []
    for match in _MY.finditer(text):
        # "July 20" is a partial day, not an implicit month in AD 20.
        if int(match["year"]) < 100 and not match["era"]: continue
        parsed = _date(match["year"], match["month"], 1, match["era"], "month", reference_year)
        if parsed is None: return []
        add(match, parsed, "month")
    for match in _YEAR_RANGE.finditer(text):
        if match["join"].lower() == "and" and (match["anchor"] or "").lower() != "between": continue
        if not match["anchor"] and not listed and not match["era"]: continue
        if not match["era"] and (int(match["first"]) < 100 or int(match["last"]) < 100): continue
        first = _date(match["first"], 1, 1, match["era"], "year", reference_year)
        last = _date(match["last"], 1, 1, match["era"], "year", reference_year)
        if first and last:
            add(match, (min(first[0], last[0]), max(first[1], last[1])), "year", uncertainty="date range stated in source; interval need not be an event duration")
    for match in _ERA_YEAR.finditer(text):
        add(match, _date(match["year"] or match["pyear"], 1, 1, match["era"] or match["prefix"], "year", reference_year), "year")
    for match in _ANCHORED_YEAR.finditer(text):
        approximate = match["short"] is not None or (match["anchor"] or "").lower() in {"around", "approximately", "about", "circa"}
        uncertainty = "approximate; source gives no bounds, interval represents only the named year" if approximate else ""
        add(match, _date(match["year"] or match["shortyear"], 1, 1, match["era"] or match["prefix"], "year", reference_year), "year", uncertainty=uncertainty)
    if listed:
        match = _LEADING_YEAR.match(text)
        if match and (int(match["year"]) >= 100 or match["era"] or article_day is not None):
            add(match, _date(match["year"], 1, 1, match["era"], "year", reference_year), "year")
    # A partial date can inherit a uniquely stated sentence year or a year heading.
    explicit_years = {int(date.start) for date in dates if date.precision == "year" and date.end < date.start + 1}
    partial_year = next(iter(explicit_years)) if len(explicit_years) == 1 else context_year
    if partial_year is not None:
        partials = []
        for pattern in (_PARTIAL_DM, _PARTIAL_MD):
            for match in pattern.finditer(text):
                if any(match.start() < end and match.end() > begin for begin, end in occupied): continue
                # _date accepts historical numbering, so resolve astronomical BCE directly.
                era, year = ("BCE", 1 - partial_year) if partial_year <= 0 else ("CE", partial_year)
                parsed = _date(year, match["month"], match["day"], era, "day", reference_year)
                if parsed:
                    covered = tuple((date.begin, date.stop) for date in dates if date.precision == "year") if explicit_years else ()
                    partials.append(DateMention(*parsed, "day", match[0], match.start(), match.end(), "explicit" if explicit_years else context_basis, covered=covered))
                else:
                    return []
        if listed and context_month is not None and not partials:
            match = re.match(r"^\s*(?P<day>\d{1,2})(?:st|nd|rd|th)?\s*[–—:.-]", text, re.I)
            if match:
                era, year = ("BCE", 1 - partial_year) if partial_year <= 0 else ("CE", partial_year)
                parsed = _date(year, context_month, match["day"], era, "day", reference_year)
                if parsed:
                    partials.append(DateMention(*parsed, "day", match[0], match.start(), match.end(), context_basis))
                else:
                    return []
        if len(partials) == 1:
            dates = [date for date in dates if date.precision != "year"] + partials
        elif partials:
            dates += partials
    if not dates and listed and context_year is not None:
        start = decimal_date(context_year)
        dates = [DateMention(start, precision_upper(start, "year"), "year", "", 0, 0, context_basis)]
    dates.sort(key=lambda date: date.begin)
    # A short endpoint (1963–68) is not a single-year occurrence. Reject it unless
    # it is part of a complete already-parsed ISO date; no century is guessed.
    for match in _SHORT_RANGE.finditer(text):
        if not any(date.begin <= match.start() and date.stop >= match.end() for date in dates): return []
    # A connected explicit two-endpoint range is a single interval. Two independent
    # occurrences in a sentence are ambiguous and are left to a more capable parser.
    if len(dates) == 2 and re.fullmatch(r"\s*(?:[–—-]|to|until|through)\s*", text[dates[0].stop:dates[1].begin], re.I):
        first, last = dates
        # A terminal BCE suffix scopes both endpoints of an explicit range:
        # "25 April 431 – 25 March 404 BC" is never 431 CE to 404 BCE.
        if first.start > 0 and last.start <= 0 and re.search(r"\bB\.?C\.?E?\b", last.text, re.I) and not re.search(r"\b" + _ERA + r"\b", first.text, re.I):
            for pattern in (_DMY, _MDY, _MY):
                match = pattern.fullmatch(first.text)
                if match:
                    parsed = _date(match["year"], match["month"], match.groupdict().get("day") or 1, "BCE", first.precision, reference_year)
                    if parsed:
                        first = DateMention(*parsed, first.precision, first.text, first.begin, first.stop, first.basis)
                    break
        return [DateMention(min(first.start, last.start), max(first.end, last.end), first.precision if first.precision == last.precision else "year",
                            text[first.begin:last.stop], first.begin, last.stop, first.basis,
                            "date range stated in source; interval need not be an event duration")]
    if len(dates) == 1 and listed and article_day is not None:
        date, leading = dates[0], _LEADING_YEAR.match(text)
        if date.precision == "year" and date.end < date.start + 1 and leading and date.begin == leading.start():
            era, year = ("BCE", 1 - int(date.start)) if date.start <= 0 else ("CE", int(date.start))
            parsed = _date(year, *article_day, era, "day", reference_year)
            if parsed is None: return []
            dates = [DateMention(*parsed, "day", date.text, date.begin, date.stop, "articleDay", date.uncertainty)]
    return dates


def _has_other_year(quote, dates):
    for match in _YEAR_WORD.finditer(quote):
        if any(begin <= match.start() and end >= match.end()
               for date in dates for begin, end in ((date.begin, date.stop),) + date.covered): continue
        if _QUANTITY_UNIT.match(quote, match.end()): continue
        return True
    return False


def _date_in_background_clause(quote, date, occurrences):
    if len(occurrences) != 1 or date.basis != "explicit": return False
    occurrence = occurrences[0]
    if occurrence.end() < date.begin and re.search(r"\b(?:after|before|following|since|subsequent to|prior to|because of|in response to)\b", quote[occurrence.end():date.begin], re.I):
        return True
    for match in re.finditer(r",|\b(?:and|but|while|although|whereas)\b", quote, re.I):
        if not date.stop <= match.start() < occurrence.start(): continue
        left = quote[:match.start()].strip()
        # Date-only introductory phrases ("In 1969,") are valid. A background
        # statement with its own verb/date cannot date a later undated action.
        if _BACKGROUND_VERB.search(left): return True
        if re.match(r"^(?:after|before|since|following|until|while|when|once)\b", left, re.I): return True
    return False


def _links(raw):
    targets = []
    for match in re.finditer(r"\[\[([^\]|#]+)", _mask_nonprose(raw)):
        target = html.unescape(match[1]).replace("_", " ").strip()
        if ":" in target and target.split(":", 1)[0].lower() in _NAMESPACES: continue
        if target and target not in targets: targets.append(target)
    return targets


def _entities(quote, links):
    entities = list(links)
    for match in _ENTITY.finditer(quote):
        name = match[0].strip()
        first = name.split()[0].lower().rstrip(".")
        if first in _MONTHS or first in {"on", "in", "the", "during", "between", "from", "after", "before", "by"}: continue
        if name not in entities: entities.append(name)
    return entities


def _category(quote):
    for category, terms in (
        ("Conflict", r"\b(?:battle|war|invad|attack|assassinat|massacre|siege)"),
        ("Disaster", r"\b(?:earthquake|eruption|flood|hurricane|explos|collapsed|sank)"),
        ("Space", r"\b(?:apollo|spacecraft|spaceflight|astronaut|satellite|moon|mars)\b"),
        ("Health", r"\b(?:pandemic|epidemic|outbreak|vaccine)\b"),
        ("Politics", r"\b(?:elected|election|treaty|ratified|resigned|abdicated|crowned|inaugurated)\b"),
        ("Science", r"\b(?:discovered|invented|experiment|scientist)\b"),
    ):
        if re.search(terms, quote, re.I): return category
    return "History"


def extract_narrative_events(title, page_id, revision, text, *, max_events=None, reference_year=None):
    """Yield sourced dated occurrences from one main-namespace article.

    Caller must exclude redirects/non-article namespaces. No cap is applied by
    default; an explicit cap is deterministic in source order. Unknown revisions
    are rejected rather than inventing an exact source citation.
    """
    if not title or not str(page_id or "") or not str(revision or ""): return
    if max_events is not None and max_events <= 0: return
    reference_year = reference_year or dt.datetime.now(dt.timezone.utc).year
    article_year = _heading_year(title, reference_year)
    article_day = _article_day(title)
    if not has_date_candidates(text) and article_year is None and article_day is None: return
    page_id, revision = str(page_id), str(revision)
    article_url = "https://en.wikipedia.org/wiki/" + urllib.parse.quote(title.replace(" ", "_"))
    seen, emitted = set(), 0
    for offset, raw, listed, section, context_year, date_context, context_basis, context_month, section_anchor in _blocks(text, reference_year, article_year, title):
        if not has_date_candidates(raw) and not (listed and (context_year is not None or article_day is not None)): continue
        raw_life_context = listed and article_day is not None and any(part.strip().lower() in {"births", "deaths"} for part in section.split(" / "))
        if not (_OCCURRENCE.search(raw) or (listed and _LIST_OCCURRENCE.search(raw)) or raw_life_context): continue
        rendered, mapping = _render(raw, offset)
        for begin, end in sentence_spans(rendered):
            quote = rendered[begin:end].strip()
            if not 12 <= len(quote) <= 2000: continue
            life_label = _calendar_life_label(section, listed, article_day, quote)
            # A calendar list's Births/Deaths heading supplies the occurrence type.
            # Its opposite life date in parentheses is biographical metadata, not
            # the leading entry's event. Preserve it in the exact quote, but never
            # use it as the trigger/date for the primary occurrence.
            analysis_quote = _BIO_PARENTHETICAL.sub(lambda match: " " * len(match[0]), quote) if life_label else quote
            if _FUTURE.search(analysis_quote) or _NEGATED.search(analysis_quote) or _ATTRIBUTED.search(analysis_quote) or _CONDITIONAL.search(analysis_quote): continue
            # Unbounded temporal qualifiers cannot be represented as finite exact
            # intervals. Do not turn "before 1900" or "circa 1440" into year 1900/1440.
            if _UNBOUNDED_DATE.search(analysis_quote): continue
            occurrences = list(_OCCURRENCE.finditer(analysis_quote))
            if not (occurrences or (listed and _LIST_OCCURRENCE.search(analysis_quote)) or life_label): continue
            # A single date cannot safely date several separate actions. Likewise
            # a date in a subordinate conditional clause cannot date the main clause.
            if len(occurrences) > 1: continue
            dates = _find_dates(analysis_quote, listed, context_year, reference_year, context_basis, context_month, article_day)
            if len(dates) != 1: continue
            date = dates[0]
            if _has_other_year(analysis_quote, dates): continue
            if _date_in_background_clause(analysis_quote, date, occurrences): continue
            source_quote = text[mapping[begin][0]:mapping[end - 1][1]]
            normalized = unicodedata.normalize("NFC", " ".join(quote.casefold().split()))
            key = (normalized, date.start, date.end, date.precision)
            if key in seen: continue
            seen.add(key)
            identifier = "NP" + hashlib.sha256((page_id + "\0" + normalized + "\0" + repr(key[1:])).encode()).hexdigest()[:28]
            fragment = urllib.parse.quote(section_anchor) if section_anchor else ""
            source_url = article_url + "?oldid=" + urllib.parse.quote(revision) + ("#" + fragment if fragment else "")
            uncertainty = date.uncertainty
            if re.search(r"\b(?:Julian|Old Style)\b|\bO\.S\.", quote, re.I):
                uncertainty = "; ".join(filter(None, (uncertainty, "source calendar conversion not modeled")))
            links = _links(source_quote)
            provenance = {"method": "datedProse", "articleTitle": title, "pageID": page_id,
                          "revisionID": revision, "section": section, "quote": quote,
                          "dateText": date.text or date_context, "dateBasis": date.basis,
                          "confidence": "explicitDate" if date.basis == "explicit" else "contextualDate" if date.basis == "articleDay" else "contextualYear",
                          "sourceQuote": source_quote, "sourceURL": source_url,
                          "sectionAnchor": section_anchor,
                          "dateContext": title if date.basis == "articleDay" else date_context if date.basis != "explicit" else "",
                          "extractionMethod": EXTRACTION_VERSION, "links": links,
                          "entities": _entities(quote, links)}
            if uncertainty: provenance["uncertainty"] = uncertainty
            if life_label: provenance["occurrence"] = life_label
            snippet = quote if len(quote) <= 150 else quote[:147].rstrip() + "…"
            label = (life_label.capitalize() + " · ") if life_label else ""
            yield {"id": identifier, "title": label + title + " · " + snippet, "summary": quote,
                   "start": date.start, "end": date.end, "precision": date.precision,
                   "latitude": None, "longitude": None, "category": _category(quote),
                   "url": article_url, "revision": revision, "embedding": [],
                   "provenance": provenance, "links": links}
            emitted += 1
            if max_events is not None and emitted >= max_events: return


# The short alias is useful for bulk wrappers; both names have the same contract.
extract_events = extract_narrative_events
