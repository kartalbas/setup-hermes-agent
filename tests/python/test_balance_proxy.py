"""The balance proxy's pure parts: footer, extraction, and the two injections."""
import json
import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "bot", "api-proxy"))
import balance_proxy as bp  # noqa: E402


def sse(*objs, done=True):
    lines = ["data: " + json.dumps(o) + "\n\n" for o in objs]
    if done:
        lines.append("data: [DONE]\n\n")
    return lines


def chunk(delta=None, finish=None):
    return {"id": "c1", "object": "chat.completion.chunk", "created": 1, "model": "m",
            "choices": [{"index": 0, "delta": delta or {}, "finish_reason": finish}]}


class Footer(unittest.TestCase):
    def test_extraction_and_text(self):
        self.assertEqual(bp.extract_balance("deepseek", {"is_available": True, "balance_infos": [{"currency": "USD", "total_balance": "18.42"}]}), ("18.42", "USD"))
        self.assertEqual(bp.extract_balance("moonshot", {"data": {"available_balance": 49.5}}), ("49.5", "CNY"))
        with self.assertRaises(ValueError):
            bp.extract_balance("deepseek", {})
        self.assertEqual(bp.footer_text("DeepSeek", "18.42", "USD"), "(DeepSeek-Guthaben: 18.42 USD)")
        self.assertEqual(bp.footer_text("DeepSeek", "unbekannt", ""), "(DeepSeek-Guthaben: unbekannt)")

    def test_a_model_written_balance_line_is_removed(self):
        self.assertEqual(bp.strip_model_footer("Erledigt.\n\n(DeepSeek-Guthaben: 1 USD)"), "Erledigt.")
        self.assertEqual(bp.strip_model_footer("Erledigt. (kein Guthaben)"), "Erledigt. (kein Guthaben)")

    def test_non_streamed_answer_gets_the_footer_only_when_it_is_a_message(self):
        body = {"choices": [{"index": 0, "finish_reason": "stop", "message": {"role": "assistant", "content": "Hallo"}}]}
        out = bp.append_footer_json(body, "(X-Guthaben: 1 USD)")
        self.assertEqual(out["choices"][0]["message"]["content"], "Hallo\n\n(X-Guthaben: 1 USD)")
        tool = {"choices": [{"index": 0, "finish_reason": "tool_calls", "message": {"role": "assistant", "content": None, "tool_calls": [{"id": "t"}]}}]}
        self.assertEqual(bp.append_footer_json(json.loads(json.dumps(tool)), "(X)"), tool)

    def test_streamed_answer_gets_one_content_chunk_before_the_finish_chunk(self):
        lines = sse(chunk({"role": "assistant", "content": "Hal"}), chunk({"content": "lo"}), chunk(finish="stop"))
        out = list(bp.inject_footer_sse(lines, "(X-Guthaben: 1 USD)"))
        payloads = [json.loads(l[5:].strip()) for l in out if l.startswith("data:") and "[DONE]" not in l]
        contents = [c["choices"][0]["delta"].get("content") for c in payloads]
        self.assertEqual(contents, ["Hal", "lo", "\n\n(X-Guthaben: 1 USD)", None])
        self.assertEqual(payloads[-1]["choices"][0]["finish_reason"], "stop")
        self.assertTrue(out[-1].startswith("data: [DONE]"))

    def test_streamed_tool_call_turns_are_left_alone(self):
        lines = sse(chunk({"role": "assistant", "tool_calls": [{"index": 0, "id": "t", "function": {"name": "f", "arguments": ""}}]}), chunk(finish="tool_calls"))
        out = list(bp.inject_footer_sse(lines, "(X)"))
        self.assertEqual(out, lines)

    def test_non_sse_lines_pass_through_untouched(self):
        lines = [": keep-alive\n\n", "data: not json\n\n", "data: [DONE]\n\n"]
        self.assertEqual(list(bp.inject_footer_sse(lines, "(X)")), lines)
