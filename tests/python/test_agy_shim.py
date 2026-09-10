"""The bridge's decision parser on what the model actually sent (2026-09-08):
two envelopes glued together — the first abandoned before its closing brace,
a stray token, then a rewrite — and arguments encoded as a string, escaped or
not. The last complete envelope is the decision; the rest is noise."""
import json
import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "bot", "agy-shim"))

import agy_shim  # noqa: E402


def names_and_args(calls):
    return [(c["function"]["name"], json.loads(c["function"]["arguments"])) for c in calls]


class ParseDecision(unittest.TestCase):
    def test_a_truncated_envelope_followed_by_its_rewrite_yields_the_rewrite(self):
        text = ('{"type":"tool_calls","calls":[{"name":"web_search","arguments":{"query":"foo"}}]幻assistant\n'
                '{"type":"tool_calls","calls":[{"name":"web_search","arguments":{"query":"bar"}}]}')
        content, calls = agy_shim.parse_decision(text)
        self.assertEqual(content, "")
        self.assertEqual(names_and_args(calls), [("web_search", {"query": "bar"})])

    def test_arguments_encoded_as_an_escaped_string_are_decoded(self):
        text = '{"type":"tool_calls","calls":[{"name":"web_search","arguments":"{\\"query\\":\\"foo\\"}"}]}'
        content, calls = agy_shim.parse_decision(text)
        self.assertEqual(content, "")
        self.assertEqual(names_and_args(calls), [("web_search", {"query": "foo"})])

    def test_arguments_as_a_string_with_unescaped_quotes_are_rescued(self):
        text = '{"type":"tool_calls","calls":[{"name":"web_search","arguments":"{"query":"foo"}"}]}'
        content, calls = agy_shim.parse_decision(text)
        self.assertEqual(content, "")
        self.assertEqual(names_and_args(calls), [("web_search", {"query": "foo"})])

    def test_both_at_once(self):
        text = ('{"type":"tool_calls","calls":[{"name":"web_search","arguments":{"query":"broken"}}]幻assistant\n'
                '{"type":"tool_calls","calls":[{"name":"web_search","arguments":"{"query":"fixed"}"}]}')
        content, calls = agy_shim.parse_decision(text)
        self.assertEqual(content, "")
        self.assertEqual(names_and_args(calls), [("web_search", {"query": "fixed"})])

    def test_the_reported_answer_verbatim_becomes_three_searches(self):
        # "warum fallen gerade die Märkte?" — what reached the chat as text on 2026-09-08
        text = ('{"type":"tool_calls","calls":[{"name":"web_search","arguments":{"query":"stock markets falling September 2026 oil inflation"}},'
                '{"name":"web_search","arguments":{"query":"DAX Wall Street Kursverluste September 2026"}},'
                '{"name":"web_search","arguments":{"query":"stock market drop September 8 2026"}}]幻assistant\n'
                '{"type":"tool_calls","calls":[{"name":"web_search","arguments":"{"query":"stock markets falling September 2026 oil inflation"}"},'
                '{"name":"web_search","arguments":"{"query":"DAX Wall Street Kursverluste September 2026"}"},'
                '{"name":"web_search","arguments":"{"query":"global markets selloff September 8 2026"}"}]}')
        content, calls = agy_shim.parse_decision(text)
        self.assertEqual(content, "")
        self.assertEqual([n for n, _ in names_and_args(calls)], ["web_search"] * 3)
        self.assertEqual([a["query"] for _, a in names_and_args(calls)],
                         ["stock markets falling September 2026 oil inflation",
                          "DAX Wall Street Kursverluste September 2026",
                          "global markets selloff September 8 2026"])

    def test_a_plain_message_and_a_plain_call_are_untouched(self):
        content, calls = agy_shim.parse_decision('{"type":"message","content":"Die Märkte fallen wegen X."}')
        self.assertEqual((content, calls), ("Die Märkte fallen wegen X.", []))
        content, calls = agy_shim.parse_decision('{"type":"tool_call","name":"web_search","arguments":{"query":"x"}}')
        self.assertEqual(names_and_args(calls), [("web_search", {"query": "x"})])
        content, calls = agy_shim.parse_decision("Nur Text mit einer { Klammer.")
        self.assertEqual((content, calls), ("Nur Text mit einer { Klammer.", []))


class TranscriptFraming(unittest.TestCase):
    """A stateless request carries the whole chat, so the only thing that makes
    the question the question is where it sits and how it is labelled. A bot
    that researches broke both: one turn of tool work left ninety entries of
    scraped HTML behind it, and mid-loop the last entry is a tool result rather
    than a question. Three different questions came back with the same answer."""

    def test_the_newest_entries_survive_the_budget_and_the_rest_are_counted(self):
        history = [f"user: q{i}" + "x" * 100 for i in range(20)]
        kept, dropped = agy_shim.trim_history(history, budget=400)
        self.assertEqual(dropped, 20 - len(kept))
        self.assertLess(len(kept), 20)
        self.assertEqual(kept[-1], history[-1])          # newest kept
        self.assertNotIn(history[0], kept)               # oldest dropped

    def test_one_enormous_entry_is_capped_not_dropped(self):
        history = ["user: hi", "tool result (web): " + "H" * 500_000]
        kept, dropped = agy_shim.trim_history(history, budget=1000, entry_cap=200)
        self.assertEqual((dropped, len(kept)), (0, 2))   # capped, so both still fit
        self.assertLess(len(kept[1]), 400)
        self.assertIn("characters left out", kept[1])

    def test_the_newest_entry_survives_a_budget_it_cannot_fit(self):
        history = ["user: hi", "tool result (web): " + "H" * 500_000]
        kept, dropped = agy_shim.trim_history(history, budget=10)
        self.assertEqual((dropped, len(kept)), (1, 1))
        self.assertTrue(kept[0].startswith("tool result (web): HHH"))

    def test_a_budget_of_zero_sends_everything(self):
        history = ["a" * 10_000, "b" * 10_000]
        self.assertEqual(agy_shim.trim_history(history, budget=0), (history, 0))

    def test_the_question_is_the_last_thing_and_is_labelled(self):
        text = agy_shim.stateless_message(
            "Your name is **Acme News**.", ["user: how old is the aircraft?",
                                            "assistant: four years."],
            "did the president promise a payment?")
        self.assertIn(agy_shim.LIVE_HEAD, text)
        self.assertTrue(text.rstrip().endswith("did the president promise a payment?"))
        self.assertLess(text.index("=== CONVERSATION SO FAR"), text.index(agy_shim.LIVE_HEAD))
        self.assertIn("BACKGROUND ONLY", text)

    def test_a_tool_result_turn_restates_the_request_it_serves(self):
        text = agy_shim.transcript_message(
            ["user: did the president promise a payment?"],
            "tool result (web_search): …", "Acme News",
            pending="did the president promise a payment?")
        self.assertIn("You are working on this request from the user: "
                      "did the president promise a payment?", text)
        self.assertIn("not an earlier one", text)

    def test_an_ordinary_turn_does_not_restate_anything(self):
        messages = [{"role": "system", "content": "s"},
                    {"role": "user", "content": "older"},
                    {"role": "assistant", "content": "answer"},
                    {"role": "user", "content": "the live one"}]
        self.assertEqual(agy_shim.pending_request(messages), "")
        text = agy_shim.transcript_message(["user: older"], "the live one", "Acme News")
        self.assertNotIn("You are working on this request", text)

    def test_the_pending_request_is_the_user_message_behind_a_tool_loop(self):
        messages = [{"role": "system", "content": "s"},
                    {"role": "user", "content": "how old is the aircraft?"},
                    {"role": "assistant", "content": "four years."},
                    {"role": "user", "content": "did the president promise a payment?"},
                    {"role": "assistant", "content": "", "tool_calls": [
                        {"function": {"name": "web_search", "arguments": "{}"}}]},
                    {"role": "tool", "name": "web_search", "content": "…"}]
        self.assertEqual(agy_shim.pending_request(messages),
                         "did the president promise a payment?")

    def test_the_transcript_cannot_outweigh_the_question(self):
        # The shape that failed on the host: ~90 entries of scraped page, one
        # line of question. Trimmed, the question is a visible share again.
        history = ["tool result (terminal): " + "<html>" * 4000 for _ in range(90)]
        question = "did the president promise a payment?"
        text = agy_shim.transcript_message(history, question, "Acme News",
                                           budget=agy_shim.DEFAULT_HISTORY_BUDGET)
        self.assertLess(len(text), 200_000)
        self.assertIn("earlier messages left out", text)
        self.assertTrue(text.rstrip().endswith(question))


if __name__ == "__main__":
    unittest.main()
