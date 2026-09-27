"""The CLI's own read-only web tools (ADR 0028).

The bridge switches the CLI's built-in tools off and hands the model the
caller's functions instead. Reading the web is the one exception, and it is
kept narrow on purpose: a configured name outside the read-only pair is
refused, the agent definition lists exactly what is configured, every text the
model reads says the same thing, a search inside a turn is neither a decision
nor an intent to translate, and over ACP the permission reply is the switch.
"""
import os
import queue
import sys
import types
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "bot", "agy-shim"))

import agy_shim  # noqa: E402

SYSTEM = "# Acme News\n\nYour name is **Acme News**."
TOOLS = [{"function": {"name": "memory", "description": "Remember a fact."}}]


def step(name, state, params):
    return {"step_type": "tool", "state": state, "tool_info": {"name": name, "parameters": params}}


class Configuration(unittest.TestCase):
    def test_the_read_only_pair_passes_in_order_and_once(self):
        self.assertEqual(agy_shim.parse_builtin_tools("search_web"), ("search_web",))
        self.assertEqual(agy_shim.parse_builtin_tools("search_web, read_url_content search_web"),
                         ("search_web", "read_url_content"))
        self.assertEqual(agy_shim.parse_builtin_tools(""), ())

    def test_anything_that_acts_is_refused(self):
        for bad in ("run_command", "search_web,write_to_file", "browser_subagent"):
            with self.assertRaises(ValueError):
                agy_shim.parse_builtin_tools(bad)


class AgentDefinition(unittest.TestCase):
    @staticmethod
    def head(text):
        return text.split("---\n", 2)[1]

    def test_without_builtins_the_cli_has_no_tools(self):
        head = self.head(agy_shim.agent_file_text(SYSTEM))
        self.assertIn("tools: []\n", head)
        self.assertIn("commandExecutionPolicy: off\n", head)

    def test_search_is_listed_and_commands_stay_off(self):
        head = self.head(agy_shim.agent_file_text(SYSTEM, ("search_web",)))
        self.assertIn("tools: [search_web]\n", head)
        self.assertIn("commandExecutionPolicy: off\n", head)
        self.assertIn("inheritCustomizations: false\n", head)

    def test_both_web_tools(self):
        head = self.head(agy_shim.agent_file_text(SYSTEM, ("search_web", "read_url_content")))
        self.assertIn("tools: [search_web, read_url_content]\n", head)


class WhatTheModelIsTold(unittest.TestCase):
    def test_the_contract_does_not_forbid_the_search_it_was_given(self):
        text = agy_shim.tool_contract(TOOLS, ("search_web",))
        self.assertIn("apart from your own web search (search_web)", text)
        self.assertIn("Never try commands, files or the browser yourself", text)
        self.assertNotIn("or the web", text)
        self.assertIn("the ONLY", text)

    def test_without_builtins_the_web_is_off_as_before(self):
        self.assertIn("commands, files, the browser or the web", agy_shim.tool_contract(TOOLS))
        self.assertEqual(agy_shim.tool_contract([], ("search_web",)), "")

    def test_the_project_instructions_name_what_is_enabled(self):
        md = agy_shim.agents_md_text(SYSTEM, ("search_web",))
        self.assertIn("only web search (search_web) is enabled", md)
        self.assertIn("You are **Acme News**", md)
        self.assertNotIn("TOOL PROTOCOL", md)
        self.assertIn("are enabled", agy_shim.agents_md_text(SYSTEM, ("search_web", "read_url_content")))
        self.assertIn("Your built-in tools are disabled", agy_shim.agents_md_text(SYSTEM))

    def test_the_reminders_follow_the_configuration(self):
        self.assertIn("use your web search (search_web)", agy_shim.tool_reminder(("search_web",)))
        self.assertNotIn("search_web", agy_shim.tool_reminder(()))
        self.assertNotIn("TOOL PROTOCOL", agy_shim.tool_reminder(("search_web",)))
        self.assertIn("besides them you may use only your web search", agy_shim.mcp_call_reminder(("search_web",)))
        self.assertIn("and nothing else", agy_shim.mcp_call_reminder(()))


class PrintModeTurn(unittest.TestCase):
    def test_a_search_is_neither_a_decision_nor_an_intent_to_translate(self):
        done = step("search_web", "DONE", {"query": "SNB Leitzins"})
        self.assertIsNone(agy_shim.native_call_decision(done, {"web_search", "memory"}))
        self.assertIsNone(agy_shim.mcp_call_decision(done))
        self.assertIsNone(agy_shim.map_cli_intents([{"name": "search_web", "parameters": {"query": "x"}}],
                                                   {"web_search"}))

    def test_a_turn_that_searched_ends_in_the_answer(self):
        p = types.SimpleNamespace()
        p._events = queue.Queue()
        for ev in ({"event": "step_update", "step_update": step("search_web", "ACTIVE", {"query": "x"})},
                   {"event": "step_update", "step_update": step("search_web", "DONE", {"query": "x"})},
                   {"event": "result", "result": {"status": "SUCCESS", "response": "Leitzins 0,0 %",
                                                  "usage": {"input_tokens": 9}}}):
            p._events.put(ev)
        p.proc = types.SimpleNamespace(stdin=types.SimpleNamespace(write=lambda s: None, flush=lambda: None),
                                       poll=lambda: None)
        p._closed, p.turns, p.last_used, p.input_tokens = False, 0, 0, 0
        p.available_tools, p.one_shot, p.builtins = {"memory"}, True, ("search_web",)
        p.stderr_tail = lambda: ""
        p.alive = lambda: True
        p._decision_payload = types.MethodType(agy_shim.AgentProcess._decision_payload, p)
        with self.assertLogs("agy-shim", level="INFO") as logs:
            res = agy_shim.AgentProcess.turn(p, "frage", 5)
        self.assertEqual(res["response"], "Leitzins 0,0 %")
        self.assertIsNone(res.get("decision"))
        self.assertTrue(any("built-in search_web done: x" in line for line in logs.output), logs.output)

    def test_lookups_go_to_the_journal_and_nothing_else_does(self):
        with self.assertLogs("agy-shim", level="INFO") as logs:
            agy_shim.log_builtin_step(step("search_web", "DONE", {"query": "SNB Leitzins"}))
            agy_shim.log_builtin_step(step("read_url_content", "ERROR", {"Url": "https://example.org"}))
        self.assertIn("built-in search_web done: SNB Leitzins", logs.output[0])
        self.assertIn("built-in read_url_content failed: https://example.org", logs.output[1])
        with self.assertNoLogs("agy-shim", level="INFO"):
            agy_shim.log_builtin_step(step("call_mcp_tool", "DONE", {}))
            agy_shim.log_builtin_step(step("search_web", "ACTIVE", {"query": "x"}))


class AcpPermission(unittest.TestCase):
    """The ACP server ignores the agent definition; it asks for every tool call,
    and a built-in asks as "Run <name>?" (seen 2026-09-28)."""

    def ask(self, client, rid, title, raw):
        client._dispatch({"jsonrpc": "2.0", "id": rid, "method": "session/request_permission",
                          "params": {"sessionId": "S1", "toolCall": {"title": title, "rawInput": raw},
                                     "options": [{"optionId": "a", "kind": "allow_once"},
                                                 {"optionId": "r", "kind": "reject_once"}]}})
        return client.written[-1]["result"]["outcome"]["optionId"]

    def client(self, builtins):
        c = agy_shim.AcpClient("/nonexistent", builtins)     # not started; no subprocess
        c.written = []
        c._write = lambda obj: c.written.append(obj)
        c._turns["S1"] = agy_shim._Turn()
        return c

    def test_a_configured_builtin_is_allowed_and_is_not_a_decision(self):
        c = self.client(("search_web",))
        self.assertEqual(self.ask(c, 1, "Run search_web?", {"query": "x"}), "a")
        self.assertEqual(c._turns["S1"].calls, [])            # the server runs it; nothing for the caller
        self.assertEqual(self.ask(c, 2, "Run read_url_content?", {"Url": "https://example.org/a"}), "r")
        self.assertEqual(self.ask(c, 3, "Run run_command?", {"CommandLine": "ls"}), "r")
        self.assertEqual(self.ask(c, 4, "Run search_web? and more", {}), "r")   # whole title only

    def test_without_builtins_every_builtin_is_refused(self):
        c = self.client(())
        self.assertEqual(self.ask(c, 1, "Run search_web?", {"query": "x"}), "r")


if __name__ == "__main__":
    unittest.main()
