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


if __name__ == "__main__":
    unittest.main()
