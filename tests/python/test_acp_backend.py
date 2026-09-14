"""The ACP backend (ADR 0027 move 3), tested without the 2 GB server.

The transport, the permission policy and the decision shape are pure enough to
exercise directly: feed AcpClient the JSON-RPC messages the server would send
and check what it collects and what it writes back; drive AcpPool.complete with
a stand-in client and check the prompt it builds and the decision it returns.
"""
import json
import os
import sys
import types
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "bot", "agy-shim"))

import agy_shim  # noqa: E402


class DecisionShape(unittest.TestCase):
    def test_no_calls_is_no_decision(self):
        self.assertIsNone(agy_shim.acp_decision([]))

    def test_one_call_is_a_tool_call(self):
        d = agy_shim.acp_decision([{"name": "web_search", "arguments": {"query": "x"}}])
        self.assertEqual(d, {"type": "tool_call", "name": "web_search", "arguments": {"query": "x"}})

    def test_several_calls_travel_together(self):
        d = agy_shim.acp_decision([{"name": "a", "arguments": {}}, {"name": "b", "arguments": {"k": 1}}])
        self.assertEqual(d["type"], "tool_calls")
        self.assertEqual([c["name"] for c in d["calls"]], ["a", "b"])

    def test_the_decision_renders_through_the_shared_converter(self):
        # what the Handler does with meta["decision"]
        d = agy_shim.acp_decision([{"name": "web_search", "arguments": {"query": "x"}}])
        content, calls = agy_shim.decision_to_calls(d)
        self.assertEqual(content, "")
        self.assertEqual(calls[0]["function"]["name"], "web_search")


class Transport(unittest.TestCase):
    def _client(self):
        c = agy_shim.AcpClient("/nonexistent")     # not started; no subprocess
        c.written = []
        c._write = lambda obj: c.written.append(obj)
        return c

    def test_a_response_wakes_its_waiter(self):
        c = self._client()
        import threading
        result = {}
        def caller():
            result["r"] = c.request("initialize", {}, timeout=5)
        t = threading.Thread(target=caller); t.start()
        # the id the request allocated
        while not c._pending:
            pass
        rid = next(iter(c._pending))
        c._dispatch({"jsonrpc": "2.0", "id": rid, "result": {"ok": True}})
        t.join(5)
        self.assertEqual(result["r"], {"ok": True})

    def test_a_tools_call_is_allowed_and_recorded_as_the_decision(self):
        c = self._client()
        turn = agy_shim._Turn()
        c._turns["S1"] = turn
        c._dispatch({"jsonrpc": "2.0", "id": 7, "method": "session/request_permission",
                     "params": {"sessionId": "S1",
                                "toolCall": {"title": "tools_web_search",
                                             "rawInput": {"arguments": {"query": "x"}}},
                                "options": [{"optionId": "a", "kind": "allow_once"},
                                            {"optionId": "r", "kind": "reject_once"}]}})
        # recorded, prefix stripped
        self.assertEqual(turn.calls, [{"name": "web_search", "arguments": {"query": "x"}}])
        # replied ALLOW
        reply = c.written[-1]
        self.assertEqual(reply["id"], 7)
        self.assertEqual(reply["result"]["outcome"], {"outcome": "selected", "optionId": "a"})

    def test_a_builtin_call_is_refused_and_not_recorded(self):
        c = self._client()
        turn = agy_shim._Turn()
        c._turns["S1"] = turn
        c._dispatch({"jsonrpc": "2.0", "id": 8, "method": "session/request_permission",
                     "params": {"sessionId": "S1",
                                "toolCall": {"title": "Run search_web?", "rawInput": {"query": "x"}},
                                "options": [{"optionId": "a", "kind": "allow_once"},
                                            {"optionId": "r", "kind": "reject_once"}]}})
        self.assertEqual(turn.calls, [])
        self.assertEqual(c.written[-1]["result"]["outcome"], {"outcome": "selected", "optionId": "r"})

    def test_streamed_text_is_collected_for_the_right_session(self):
        c = self._client()
        turn = agy_shim._Turn()
        c._turns["S1"] = turn
        for piece in ("Hallo ", "Welt"):
            c._dispatch({"jsonrpc": "2.0", "method": "session/update",
                         "params": {"sessionId": "S1",
                                    "update": {"sessionUpdate": "agent_message_chunk",
                                               "content": {"type": "text", "text": piece}}}})
        # an update for an unknown session is ignored, not an error
        c._dispatch({"jsonrpc": "2.0", "method": "session/update",
                     "params": {"sessionId": "OTHER",
                                "update": {"sessionUpdate": "agent_message_chunk",
                                           "content": {"text": "ignored"}}}})
        self.assertEqual("".join(turn.text), "Hallo Welt")

    def test_an_unsupported_agent_request_is_declined_not_ignored(self):
        c = self._client()
        c._dispatch({"jsonrpc": "2.0", "id": 9, "method": "fs/read_text_file",
                     "params": {"path": "/etc/passwd"}})
        self.assertEqual(c.written[-1]["id"], 9)
        self.assertIn("error", c.written[-1])


class PoolComplete(unittest.TestCase):
    """AcpPool.complete with a stand-in client: build the object without
    __init__ (which would start a real server) and check the prompt it sends
    and the decision it returns."""

    def _pool(self, tmp, turn):
        pool = object.__new__(agy_shim.AcpPool)
        import threading
        pool.args = types.SimpleNamespace(workdir=tmp, timeout=30, queue_timeout=5,
                                          max_concurrent=2, models=["gemini-3.8-flash-high"],
                                          acp_server="/nonexistent")
        pool.lock = threading.Lock()
        pool.sessions = {}
        pool.slots = threading.BoundedSemaphore(2)
        pool.restarts = 0
        pool.procs = {}
        sent = {}
        class FakeClient:
            def alive(self): return True
            def request(self, method, params, timeout=300.0):
                sent[method] = params
                if method == "session/new":
                    return {"sessionId": "SID", "configOptions": [
                        {"id": "model", "options": [{"value": "gemini-3.8-flash-high"}]}]}
                return {}
            def prompt(self, sid, text, timeout):
                sent["prompt_text"] = text
                return turn
        pool.client = FakeClient()
        return pool, sent

    def test_first_turn_seeds_system_and_history_then_answers(self):
        import tempfile
        tmp = tempfile.mkdtemp()
        turn = agy_shim._Turn(); turn.text = ["Die Antwort."]
        pool, sent = self._pool(tmp, turn)
        content, usage, meta = pool.complete(
            "key1", ["user: früher", "assistant: ok"], "Wie geht es?",
            system="Your name is **Acme Probe**.", model="gemini-3.8-flash-high",
            tools=[{"function": {"name": "web_search", "description": "d", "parameters": {}}}])
        # the model was set, a session was made with our tools server
        self.assertIn("session/new", sent)
        self.assertEqual(sent["session/new"]["mcpServers"][0]["name"], "tools")
        self.assertEqual(sent["session/new"]["mcpServers"][0]["env"][0]["name"], "AGY_TOOLS_DIR")
        # the seed carries the system framing, the history and the live message
        self.assertIn("Acme Probe", sent["prompt_text"])
        self.assertIn("CONVERSATION SO FAR", sent["prompt_text"])
        self.assertTrue(sent["prompt_text"].rstrip().endswith("Wie geht es?"))
        self.assertEqual(content, "Die Antwort.")
        self.assertEqual(usage, {})                 # ACP reports no per-turn tokens
        self.assertIsNone(meta["decision"])

    def test_second_turn_sends_only_the_new_message(self):
        import tempfile
        tmp = tempfile.mkdtemp()
        pool, sent = self._pool(tmp, agy_shim._Turn())
        pool.complete("key1", [], "erste Frage", system="Your name is **Acme Probe**.",
                      model="gemini-3.8-flash-high", tools=[])
        # second call on the same key: no reseed, no CONVERSATION block
        turn2 = agy_shim._Turn(); turn2.calls = [{"name": "web_search", "arguments": {"query": "x"}}]
        pool.client = self._pool(tmp, turn2)[0].client   # fresh recorder, same fake
        # reuse the recorder from a client bound to `sent`
        sent2 = {}
        class C2:
            def alive(self): return True
            def request(self, m, p, timeout=300.0): sent2[m] = p; return {}
            def prompt(self, sid, text, timeout): sent2["prompt_text"] = text; return turn2
        pool.client = C2()
        content, usage, meta = pool.complete("key1", ["user: erste Frage"], "zweite Frage",
                                             system="Your name is **Acme Probe**.",
                                             model="gemini-3.8-flash-high", tools=[])
        self.assertNotIn("session/new", sent2)      # session reused
        self.assertNotIn("CONVERSATION SO FAR", sent2["prompt_text"])
        self.assertTrue(sent2["prompt_text"].rstrip().endswith("zweite Frage"))
        self.assertEqual(meta["decision"], {"type": "tool_call", "name": "web_search", "arguments": {"query": "x"}})

    def test_a_bare_pending_marker_is_not_delivered_to_the_user(self):
        import tempfile
        turn = agy_shim._Turn(); turn.text = ["pending"]     # marker leaked, no captured call
        pool, _ = self._pool(tempfile.mkdtemp(), turn)
        content, _, meta = pool.complete("k", [], "frage", system="Your name is **P**.",
                                         model="gemini-3.8-flash-high", tools=[])
        self.assertEqual(content, "")
        self.assertIsNone(meta["decision"])

    def test_a_real_answer_that_happens_to_contain_pending_is_kept(self):
        import tempfile
        turn = agy_shim._Turn(); turn.text = ["Die Zahlung ist noch pending."]
        pool, _ = self._pool(tempfile.mkdtemp(), turn)
        content, _, _ = pool.complete("k", [], "frage", system="Your name is **P**.",
                                      model="gemini-3.8-flash-high", tools=[])
        self.assertIn("pending", content)

    def test_stats_reports_the_acp_mode(self):
        import tempfile
        pool, _ = self._pool(tempfile.mkdtemp(), agy_shim._Turn())
        self.assertEqual(pool.stats()["mode"], "acp")


if __name__ == "__main__":
    unittest.main()
