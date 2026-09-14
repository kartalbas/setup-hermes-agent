"""The bridge's decision path.

Until ADR 0027 the model wrote its decisions as JSON text into its answer and
this file pinned the parser that had to survive them: envelopes abandoned
mid-object, a stray token between two attempts, arguments encoded as a string
with the quotes left unescaped. Those cases are gone with the protocol that
produced them. A decision is now an object this program builds from the CLI's
own structured report of a completed tool call, so what is left to test is the
rendering, and that an unknown shape is refused rather than guessed at."""
import json
import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "bot", "agy-shim"))

import agy_shim  # noqa: E402


def names_and_args(calls):
    return [(c["function"]["name"], json.loads(c["function"]["arguments"])) for c in calls]


class DecisionRendering(unittest.TestCase):
    def test_one_call_becomes_one_openai_tool_call(self):
        content, calls = agy_shim.decision_to_calls(
            {"type": "tool_call", "name": "web_search", "arguments": {"query": "foo"}})
        self.assertEqual(content, "")
        self.assertEqual(names_and_args(calls), [("web_search", {"query": "foo"})])
        self.assertTrue(calls[0]["id"].startswith("call_"))
        self.assertEqual(calls[0]["type"], "function")

    def test_several_independent_calls_travel_together(self):
        content, calls = agy_shim.decision_to_calls({"type": "tool_calls", "calls": [
            {"name": "web_search", "arguments": {"query": "a"}},
            {"name": "web_search", "arguments": {"query": "b"}},
            {"name": "read_page", "arguments": {"url": "https://example.com"}}]})
        self.assertEqual(content, "")
        self.assertEqual([n for n, _ in names_and_args(calls)],
                         ["web_search", "web_search", "read_page"])
        self.assertEqual(len({c["id"] for c in calls}), 3)      # ids are distinct

    def test_a_message_decision_is_prose_and_no_calls(self):
        self.assertEqual(agy_shim.decision_to_calls({"type": "message", "content": "Die Märkte fallen."}),
                         ("Die Märkte fallen.", []))

    def test_missing_arguments_render_as_an_empty_object(self):
        _, calls = agy_shim.decision_to_calls({"type": "tool_call", "name": "now", "arguments": None})
        self.assertEqual(calls[0]["function"]["arguments"], "{}")

    def test_a_call_without_a_name_is_dropped_not_guessed(self):
        _, calls = agy_shim.decision_to_calls({"type": "tool_calls", "calls": [
            {"arguments": {"query": "x"}}, {"name": "web_search", "arguments": {"query": "y"}}]})
        self.assertEqual(names_and_args(calls), [("web_search", {"query": "y"})])

    def test_an_unknown_shape_is_refused_rather_than_interpreted(self):
        # The old parser guessed at anything; a decision this program built
        # itself has no excuse for an unknown shape, so it is discarded loudly.
        self.assertEqual(agy_shim.decision_to_calls({"type": "something-else"}), ("", []))
        self.assertEqual(agy_shim.decision_to_calls({}), ("", []))


class TranscriptFraming(unittest.TestCase):
    """A stateless request carries the whole chat, so the only thing that makes
    the question the question is where it sits and how it is labelled. A bot
    that researches broke both: one turn of tool work left ninety entries of
    scraped HTML behind it, and mid-loop the last entry is a tool result rather
    than a question. Three different questions came back with the same answer."""

    def test_nothing_in_the_transcript_is_cut(self):
        """ADR 0027, move 1. A 6,000-character cap used to apply to every entry
        and a 120,000-character budget across all of them. Both are gone: this
        bridge translates, it does not decide what the model may read. A long
        mail now arrives whole."""
        history = ["user: hi", "tool result (web): " + "H" * 500_000]
        block = agy_shim.transcript_block(history)
        self.assertIn("H" * 500_000, block)
        self.assertNotIn("characters left out", block)
        self.assertNotIn("earlier messages left out", block)

    def test_an_empty_transcript_produces_no_block_at_all(self):
        self.assertEqual(agy_shim.transcript_block([]), "")

    def test_a_long_pending_request_is_restated_in_full(self):
        pending = "Bitte prüfe " + "x" * 20_000
        text = agy_shim.transcript_message(["user: older"], "tool result (web): …",
                                           "Acme News", pending=pending)
        self.assertIn(pending, text)

    def test_the_question_is_the_last_thing_and_is_labelled(self):
        text = agy_shim.stateless_message(
            "Your name is **Acme News**.", ["user: how old is the aircraft?",
                                            "assistant: four years."],
            "did the president promise a payment?")
        self.assertIn(agy_shim.LIVE_HEAD, text)
        self.assertTrue(text.rstrip().endswith("did the president promise a payment?"))
        self.assertLess(text.index("=== CONVERSATION SO FAR"), text.index(agy_shim.LIVE_HEAD))
        self.assertIn("BACKGROUND ONLY", text)

    def test_a_past_tool_result_is_capped_but_human_content_and_the_live_result_are_whole(self):
        # The news-bot regression (2026-09-14): untrimmed scraped pages made an
        # ACP session slow to a minute a turn. Past tool output is capped;
        # mails and the live result are not.
        huge = "H" * 200_000
        messages = [
            {"role": "system", "content": "s"},
            {"role": "user", "content": "M" * 50_000},                    # a long mail: whole
            {"role": "assistant", "content": "", "tool_calls": [
                {"function": {"name": "web_search", "arguments": "{}"}}]},
            {"role": "tool", "name": "web_search", "content": huge},        # past result: capped
            {"role": "user", "content": "die eigentliche Frage"},
        ]
        system, prior, last = agy_shim.split_history(messages)
        joined = "\n\n".join(prior)
        self.assertIn("M" * 50_000, joined)                                # the mail survives whole
        self.assertNotIn("H" * agy_shim.PAST_TOOL_RESULT_CAP + "H", joined)  # the page is cut
        self.assertIn("characters elided from a past tool result", joined)
        self.assertEqual(last, "die eigentliche Frage")

    def test_the_live_tool_result_is_never_capped(self):
        huge = "H" * 200_000
        messages = [{"role": "user", "content": "frage"},
                    {"role": "tool", "name": "web_search", "content": huge}]   # last = live
        _, _, last = agy_shim.split_history(messages)
        self.assertIn(huge, last)
        self.assertNotIn("elided", last)

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

    def test_a_huge_transcript_still_ends_with_the_question(self):
        # The shape that failed on the host: ~90 entries of scraped page, one
        # line of question. Cutting was one answer to it; the framing is the
        # other, and the framing is the one that survives move 1. The
        # transcript is now sent whole and the question is still last, still
        # under its own heading, with everything before it marked background.
        history = ["tool result (terminal): " + "<html>" * 4000 for _ in range(90)]
        question = "did the president promise a payment?"
        text = agy_shim.transcript_message(history, question, "Acme News")
        self.assertGreater(len(text), 2_000_000)         # nothing was dropped
        self.assertNotIn("earlier messages left out", text)
        self.assertIn("BACKGROUND ONLY", text)
        self.assertTrue(text.rstrip().endswith(question))


if __name__ == "__main__":
    unittest.main()
