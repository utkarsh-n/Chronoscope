import unittest

from corpus import decimal_date, precision_upper
from narrative import extract_narrative_events, has_date_candidates, sentence_spans


def records(text, title="History of Example", page="42", revision="100", **kwargs):
    return list(extract_narrative_events(title, page, revision, text, reference_year=2026, **kwargs))


class NarrativeDateTests(unittest.TestCase):
    def test_day_month_year_occurrence(self):
        event, = records("On 20 July 1969, Apollo 11 landed on the Moon.")
        self.assertEqual(event["start"], decimal_date(1969, 7, 20))
        self.assertEqual(event["start"], event["end"])
        self.assertEqual(event["precision"], "day")
        self.assertEqual(event["provenance"]["dateBasis"], "explicit")

    def test_month_day_year_occurrence(self):
        event, = records("Apollo 11 landed on July 20, 1969.")
        self.assertEqual(event["start"], decimal_date(1969, 7, 20))

    def test_iso_date_is_unambiguous(self):
        event, = records("The observatory opened on 2000-02-29.")
        self.assertEqual(event["start"], decimal_date(2000, 2, 29))

    def test_month_precision_covers_only_named_month(self):
        event, = records("The observatory opened in February 2000.")
        self.assertEqual(event["precision"], "month")
        self.assertEqual(event["start"], decimal_date(2000, 2, 1))
        self.assertEqual(event["end"], precision_upper(event["start"], "month"))

    def test_year_precision_is_not_fabricated_january_first(self):
        event, = records("The observatory opened in 1990.")
        self.assertEqual(event["precision"], "year")
        self.assertEqual(event["start"], 1990)
        self.assertGreater(event["end"], decimal_date(1990, 12, 31))
        self.assertLess(event["end"], 1991)

    def test_bce_dates_use_astronomical_numbering(self):
        event, = records("Julius Caesar was assassinated on 15 March 44 BC.")
        self.assertEqual(event["start"], decimal_date(-43, 3, 15))
        event, = records("The temple opened in 1 BCE.")
        self.assertEqual(event["start"], 0)

    def test_ad_prefix_year(self):
        event, = records("The temple opened in AD 44.")
        self.assertEqual(event["start"], 44)

    def test_explicit_range_is_not_claimed_as_duration(self):
        event, = records("The temple was built between 431 and 404 BC.")
        self.assertEqual(event["start"], -430)
        self.assertLess(event["end"], -402)
        self.assertIn("need not be an event duration", event["provenance"]["uncertainty"])

    def test_precise_day_range(self):
        event, = records("The festival took place from 16 July 1969 to 24 July 1969.")
        self.assertEqual(event["start"], decimal_date(1969, 7, 16))
        self.assertEqual(event["end"], decimal_date(1969, 7, 24))

    def test_bce_range_suffix_scopes_both_calendar_endpoints(self):
        event, = records("The war took place from 25 April 431 to 25 March 404 BC.")
        self.assertEqual(event["start"], decimal_date(-430, 4, 25))
        self.assertEqual(event["end"], decimal_date(-403, 3, 25))

    def test_dotted_bce_era_is_not_misread_as_ce(self):
        event, = records("Julius Caesar was assassinated on 15 March 44 B.C.E.")
        self.assertEqual(event["start"], decimal_date(-43, 3, 15))

    def test_invalid_template_month_is_not_coarsened_into_year(self):
        self.assertEqual(records("The station opened in {{date|2000|13|1}}."), [])

    def test_invalid_dates_never_fall_back_to_month_or_year(self):
        for text in ("The station opened on 30 February 2000.", "The station opened on 1900-02-29.",
                     "== 1969 ==\n* 32 July: The station opened."):
            with self.subTest(text=text): self.assertEqual(records(text), [])

    def test_unknown_unbounded_dates_are_skipped(self):
        for qualifier in ("circa", "around", "about", "before", "after", "by", "since", "c."):
            with self.subTest(qualifier=qualifier):
                self.assertEqual(records(f"The printing press was invented {qualifier} 1440."), [])

    def test_short_year_ranges_are_not_coarsened_into_first_year(self):
        for value in ("1963–68", "1963-68", "1914–18", "1898–02"):
            with self.subTest(value=value):
                self.assertEqual(records(f"The sculpture was created during {value}."), [])

    def test_complete_year_range_during_is_preserved(self):
        event, = records("The sculpture was created during 1963–1968.")
        self.assertEqual(event["start"], 1963)
        self.assertEqual(event["end"], precision_upper(1968, "year"))

    def test_future_calendar_year_is_rejected(self):
        self.assertEqual(records("The station opened on 20 July 2030."), [])

    def test_date_template_in_prose_is_expanded_without_leaking_infobox(self):
        event, = records("Albert Einstein was born on {{birth date|df=yes|1879|3|14}}.")
        self.assertEqual(event["start"], decimal_date(1879, 3, 14))
        self.assertIn("{{birth date|df=yes|1879|3|14}}", event["provenance"]["sourceQuote"])


class TimelineContextTests(unittest.TestCase):
    def test_dated_list_with_present_occurrence(self):
        event, = records("* '''1969''' – Apollo 11 lands on the Moon.")
        self.assertEqual(event["start"], 1969)
        self.assertEqual(event["provenance"]["confidence"], "explicitDate")

    def test_dated_list_with_named_occurrence(self):
        event, = records("* 1960 – The Valdivia earthquake in Chile.")
        self.assertEqual(event["category"], "Disaster")

    def test_year_heading_provides_partial_date(self):
        event, = records("== History ==\n=== 1969 ===\n* 20 July: Apollo 11 landed on the Moon.")
        self.assertEqual(event["start"], decimal_date(1969, 7, 20))
        self.assertEqual(event["provenance"]["section"], "History / 1969")
        self.assertEqual(event["provenance"]["dateBasis"], "sectionYear")
        self.assertEqual(event["provenance"]["dateContext"], "1969")

    def test_year_heading_can_date_a_bullet_without_day(self):
        event, = records("== 1969 ==\n* Apollo 11 landed on the Moon.")
        self.assertEqual(event["precision"], "year")
        self.assertEqual(event["provenance"]["confidence"], "contextualYear")

    def test_year_context_does_not_leak_into_next_sibling_section(self):
        events = records("== 1969 ==\n* Apollo 11 landed on the Moon.\n== Later history ==\n* The station opened on 20 July.")
        self.assertEqual(len(events), 1)

    def test_strict_year_article_dates_partial_prose(self):
        event, = records("== Events ==\n* July 20 – Apollo 11 landed on the Moon.", title="1969")
        self.assertEqual(event["start"], decimal_date(1969, 7, 20))
        self.assertEqual(event["provenance"]["dateBasis"], "articleYear")

    def test_strict_bce_year_article(self):
        event, = records("* 15 March – Julius Caesar was assassinated.", title="44 BC")
        self.assertEqual(event["start"], decimal_date(-43, 3, 15))
        self.assertEqual(event["provenance"]["dateBasis"], "articleYear")

    def test_month_heading_day_bullets_in_year_article(self):
        event, = records("== Events ==\n=== July ===\n* 20 – Apollo 11 landed on the Moon.", title="1969")
        self.assertEqual(event["start"], decimal_date(1969, 7, 20))
        self.assertEqual(event["provenance"]["dateContext"], "1969 / July")

    def test_year_embedded_in_arbitrary_title_is_not_context(self):
        self.assertEqual(records("* July 20 – Apollo 11 landed on the Moon.", title="Technology in 1969"), [])

    def test_inline_year_anchors_partial_day(self):
        event, = records("In 1969, on 20 July, Apollo 11 landed on the Moon.")
        self.assertEqual(event["start"], decimal_date(1969, 7, 20))
        self.assertEqual(event["provenance"]["dateBasis"], "explicit")

    def test_inline_bce_year_anchors_partial_day(self):
        event, = records("In 44 BC, on 15 March, Julius Caesar was assassinated.")
        self.assertEqual(event["start"], decimal_date(-43, 3, 15))

    def test_prefilter_allows_month_day_without_year(self):
        self.assertTrue(has_date_candidates("* July 20 – Apollo 11 landed on the Moon."))
        self.assertTrue(has_date_candidates("* 15 March – Julius Caesar was assassinated."))

    def test_calendar_article_supplies_day_for_leading_year(self):
        event, = records("== Events ==\n* [[1969]] – [[Apollo 11]] landed on the [[Moon]].", title="July 20")
        self.assertEqual(event["start"], decimal_date(1969, 7, 20))
        self.assertEqual(event["precision"], "day")
        self.assertEqual(event["provenance"]["dateBasis"], "articleDay")
        self.assertEqual(event["provenance"]["confidence"], "contextualDate")
        self.assertEqual(event["provenance"]["dateContext"], "July 20")
        self.assertTrue(event["provenance"]["sourceQuote"].startswith("[[1969]]"))

    def test_calendar_deaths_do_not_trigger_from_parenthetical_birth(self):
        sentence = "1938 – [[George Bryant (actor)|George Bryant]], Australian actor (born 1878)"
        event, = records("== Deaths ==\n=== 1901–present ===\n* " + sentence, title="April 18")
        self.assertEqual(event["start"], decimal_date(1938, 4, 18))
        self.assertEqual(event["provenance"]["occurrence"], "death")
        self.assertEqual(event["provenance"]["sourceQuote"], sentence)
        self.assertTrue(event["title"].startswith("Death · April 18"))
        self.assertIn("born 1878", event["provenance"]["quote"])

    def test_calendar_births_do_not_trigger_from_parenthetical_death(self):
        event, = records("== Births ==\n* 181 – [[Emperor Xian of Han]], Chinese emperor (died 234)", title="April 2")
        self.assertEqual(event["start"], decimal_date(181, 4, 2))
        self.assertEqual(event["provenance"]["occurrence"], "birth")
        self.assertTrue(event["title"].startswith("Birth · April 2"))

    def test_calendar_life_lists_work_without_opposite_life_annotation(self):
        event, = records("== Births ==\n* 1900 – [[Jane Example]], British author", title="April 2")
        self.assertEqual(event["start"], decimal_date(1900, 4, 2))
        self.assertEqual(event["provenance"]["occurrence"], "birth")

    def test_generic_life_lists_cannot_use_opposite_parenthetical_date(self):
        self.assertEqual(records("== Deaths ==\n* 1938 – George Bryant, actor (born 1878)", title="History of actors"), [])
        self.assertEqual(records("== Births ==\n* 181 – Emperor Xian, emperor (died 234)", title="History of emperors"), [])

    def test_calendar_events_cannot_trigger_from_parenthetical_life_annotation(self):
        self.assertEqual(records("== Events ==\n* 1938 – George Bryant, actor (born 1878)", title="April 18"), [])

    def test_only_strict_calendar_title_supplies_day(self):
        event, = records("* 1969 – Apollo 11 landed on the Moon.", title="History of July 20")
        self.assertEqual(event["precision"], "year")
        self.assertEqual(event["provenance"]["dateBasis"], "explicit")

    def test_calendar_february_29_validates_actual_year(self):
        self.assertEqual(records("== Events ==\n* 1900 – The station opened.", title="February 29"), [])
        event, = records("== Events ==\n* 2000 – The station opened.", title="February 29")
        self.assertEqual(event["start"], decimal_date(2000, 2, 29))

    def test_calendar_day_can_resolve_early_ce_year(self):
        event, = records("== Births ==\n* 44 – A Roman author", title="April 2")
        self.assertEqual(event["start"], decimal_date(44, 4, 2))

    def test_calendar_day_bce_year(self):
        event, = records("== Events ==\n* 44 BC – Julius Caesar was assassinated.", title="March 15")
        self.assertEqual(event["start"], decimal_date(-43, 3, 15))


class NarrativePrecisionTests(unittest.TestCase):
    def test_biography_birth_and_death_are_legitimate_occurrences(self):
        events = records("Ada Lovelace was born on 10 December 1815. She died on 27 November 1852.", title="Ada Lovelace")
        self.assertEqual(len(events), 2)
        self.assertEqual([event["start"] for event in events], [decimal_date(1815, 12, 10), decimal_date(1852, 11, 27)])

    def test_future_plans_and_conditionals_are_not_occurrences(self):
        for text in ("The station was scheduled to open on 20 July 2000.",
                     "The station will be opened on 20 July 2026.",
                     "In 2000, the station was announced as a proposed project.",
                     "If the station opened in 1776, the town was established later."):
            with self.subTest(text=text): self.assertEqual(records(text), [])

    def test_negated_occurrence(self):
        self.assertEqual(records("The station was not opened in 2000."), [])

    def test_reference_dates_cannot_date_an_event(self):
        for text in ("The station opened.<ref>Smith, 2000, History of the station.</ref>",
                     "The station opened. {{cite book|year=2000|title=History}}",
                     "== References ==\n* In 2000, Smith published The History of Stations.",
                     "== Sources ==\n=== Books ===\nIn 2000, Smith published his history."):
            with self.subTest(text=text): self.assertEqual(records(text), [])

    def test_infoboxes_captions_tables_and_code_are_not_prose(self):
        for text in ("{{Infobox person|born=14 March 1879|caption=Einstein was born on 14 March 1879.}}",
                     "[[File:Station.jpg|thumb|The station opened in 2000.]]",
                     "{| class=wikitable\n| In 2000, the station opened.\n|}",
                     "<gallery>Station.jpg|The station opened in 2000.</gallery>",
                     "<nowiki>The station opened in 2000.</nowiki>"):
            with self.subTest(text=text): self.assertEqual(records(text), [])

    def test_bare_number_and_date_without_occurrence_are_rejected(self):
        for text in ("The station has 2000 seats.", "In 2000, the station had red walls.",
                     "The 2000 model opened a new category of products."):
            with self.subTest(text=text): self.assertEqual(records(text), [])

    def test_unrelated_multiple_dates_are_not_merged(self):
        self.assertEqual(records("The station opened in 2000, following a vote in 1998."), [])

    def test_unanchored_second_year_cannot_tag_a_different_award(self):
        self.assertEqual(records("He won the award in 1947, followed by their 1979 award."), [])
        self.assertEqual(records("She had met Ulvaeus briefly in 1963 during a talent contest and Fältskog during a TV show in early 1968."), [])

    def test_number_with_explicit_quantity_unit_is_not_a_second_year(self):
        event, = records("In 1969, the expedition reached the island with 1200 specimens.")
        self.assertEqual(event["start"], 1969)

    def test_one_date_cannot_tag_two_separate_actions(self):
        self.assertEqual(records("In 1776, the country declared independence and the station opened."), [])
        self.assertEqual(records("In 1776, the town had 500 residents; the station opened."), [])

    def test_background_clause_date_cannot_tag_later_action(self):
        self.assertEqual(records("After independence in 1776, the station opened later."), [])
        self.assertEqual(records("The town had 500 residents in 1776, and the station opened."), [])

    def test_pilot_payment_year_cannot_date_later_damages(self):
        quote = "Ajitabh Bachchan sued Swedish newspaper Dagens Nyheter for linking him to Bofors payments in 1990 and won damages in the United Kingdom."
        self.assertEqual(records(quote, title="Amitabh Bachchan"), [])

    def test_pilot_earthquake_year_cannot_date_subsequent_reconstruction(self):
        self.assertEqual(records("* It was reconstructed after an earthquake in AD 63.", title="Apollo"), [])

    def test_pilot_choice_year_cannot_date_replacement_relative_clause(self):
        quote = "He opted in 1997 for a replacement heart valve made from his own pulmonary valve, which, in turn, was replaced with a cadaveric pulmonic valve, in a Ross procedure;"
        self.assertEqual(records(quote, title="Arnold Schwarzenegger"), [])

    def test_pilot_establishment_date_does_not_date_undated_forced_submission(self):
        quote = "In response, the Mongols established an administration post at Nurgan (now Tyr, Russia) at the junction of the Amur and Amgun rivers in 1263, and forced the submission of the two peoples."
        self.assertEqual(records(quote, title="Ainu people"), [])

    def test_explicit_reconstruction_date_remains_eligible(self):
        event, = records("The temple was reconstructed in AD 63 after an earthquake.")
        self.assertEqual(event["start"], 63)

    def test_coordinated_subjects_are_not_mistaken_for_background_clauses(self):
        event, = records("In 1969, Neil Armstrong and Buzz Aldrin landed on the Moon.")
        self.assertEqual(event["start"], 1969)

    def test_attributed_and_fictional_claims_are_skipped(self):
        self.assertEqual(records("According to legend, the temple was founded in 1200."), [])
        self.assertEqual(records("== Plot ==\nThe fictional station opened in 2000."), [])


class NarrativeProvenanceTests(unittest.TestCase):
    def test_original_article_revision_quote_and_section_are_retained(self):
        sentence = "On 20 July 1969, [[Apollo 11]] landed on the [[Moon]]."
        event, = records("== Missions ==\n" + sentence, title="Space exploration", page="991", revision="12345")
        provenance = event["provenance"]
        self.assertEqual(provenance["method"], "datedProse")
        self.assertEqual(provenance["sourceQuote"], sentence)
        self.assertEqual(provenance["quote"], "On 20 July 1969, Apollo 11 landed on the Moon.")
        self.assertEqual(provenance["articleTitle"], "Space exploration")
        self.assertEqual(provenance["pageID"], "991")
        self.assertEqual(provenance["revisionID"], "12345")
        self.assertEqual(provenance["section"], "Missions")
        self.assertEqual(provenance["sourceURL"], "https://en.wikipedia.org/wiki/Space_exploration?oldid=12345#Missions")
        self.assertEqual(event["revision"], "12345")
        self.assertEqual(event["url"], "https://en.wikipedia.org/wiki/Space_exploration")

    def test_sentence_local_links_exclude_other_sentences_and_refs(self):
        sentence = "[[Albert Einstein]] was born on 14 March 1879<ref>[[Biography source]] (2000).</ref>."
        event, = records(sentence + " The article also discusses [[Germany]].")
        self.assertEqual(event["links"], ["Albert Einstein"])
        self.assertIn("[[Albert Einstein]]", event["provenance"]["sourceQuote"])

    def test_ids_are_independent_of_revision_offsets_sections_and_markup(self):
        plain = "Apollo 11 landed on the Moon on 20 July 1969."
        first, = records(plain, revision="100")
        moved, = records("Undated introductory text.\n\n== Missions ==\n" + plain, revision="200")
        linked, = records("[[Apollo 11]] landed on the [[Moon]] on 20 July 1969.")
        self.assertTrue(first["id"].startswith("NP"))
        self.assertEqual(first["id"], moved["id"])
        self.assertEqual(first["id"], linked["id"])
        self.assertNotEqual(first["revision"], moved["revision"])

    def test_same_sentence_date_deduplicates_but_distinct_occurrences_survive(self):
        first = "The station opened in 2000."
        second = "The museum opened in 2000."
        events = records(first + "\n\n" + first + "\n\n" + second)
        self.assertEqual(len(events), 2)
        self.assertNotEqual(events[0]["id"], events[1]["id"])

    def test_named_entities_and_abbreviations_preserve_sentence_boundaries(self):
        sentence = "On 20 July 1969, Dr. Neil A. Armstrong landed on the Moon as a U.S. astronaut."
        event, = records(sentence)
        self.assertEqual(event["summary"], sentence)
        self.assertTrue(any("Neil A. Armstrong" in entity for entity in event["provenance"]["entities"]))

    def test_unknown_revision_is_not_assigned_a_source(self):
        self.assertEqual(records("The station opened in 2000.", revision=None), [])

    def test_cap_is_explicit_and_zero_means_no_records(self):
        text = "The station opened in 2000. The museum opened in 2001."
        self.assertEqual(records(text, max_events=0), [])
        self.assertEqual(len(records(text, max_events=1)), 1)
        self.assertEqual(len(records(text)), 2)

    def test_calendar_uncertainty_is_retained_without_conversion(self):
        event, = records("The station opened on 1 March 1800 (Old Style).")
        self.assertIn("calendar conversion not modeled", event["provenance"]["uncertainty"])
        self.assertEqual(event["start"], decimal_date(1800, 3, 1))

    def test_duplicate_subsection_anchors_cite_the_actual_calendar_section(self):
        text = "== Events ==\n=== 1901–present ===\n* 1938 – The station opened.\n== Births ==\n=== 1901–present ===\n* 1938 – Jane Example, author (died 2002)\n== Deaths ==\n=== 1901–present ===\n* 1938 – George Example, actor (born 1878)"
        events = records(text, title="April 18")
        self.assertEqual(len(events), 3)
        self.assertEqual([e["provenance"]["sectionAnchor"] for e in events], ["1901–present", "1901–present_2", "1901–present_3"])
        self.assertTrue(events[2]["provenance"]["sourceURL"].endswith("#1901%E2%80%93present_3"))
        self.assertEqual(events[2]["provenance"]["section"], "Deaths / 1901–present")

    def test_anchor_changes_do_not_change_event_identity(self):
        quote = "The station opened in 2000."
        first, = records("== History ==\n" + quote)
        second, = records("== History ==\nAn undated description.\n== History ==\n" + quote)
        self.assertEqual(first["id"], second["id"])
        self.assertEqual(first["provenance"]["sectionAnchor"], "History")
        self.assertEqual(second["provenance"]["sectionAnchor"], "History_2")

    def test_literal_numbered_heading_does_not_collide_with_duplicate_anchor(self):
        text = "== History ==\nAn undated description.\n== History_2 ==\nAnother description.\n== History ==\nThe station opened in 2000."
        event, = records(text)
        self.assertEqual(event["provenance"]["sectionAnchor"], "History_3")


if __name__ == "__main__":
    unittest.main()
