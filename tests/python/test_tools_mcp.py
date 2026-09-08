"""The caller's tools as an MCP server, and the bridge's side of that channel.

What matters: the CLI is handed exactly the caller's functions, a call with
missing arguments comes back as a correction rather than a decision, a valid
one is recorded and handed over, and the bridge turns the CLI's step event
into the decision the agent framework expects."""
import json
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SHIM_DIR = os.path.join(ROOT, "bot", "agy-shim")
sys.path.insert(0, SHIM_DIR)

import tools_mcp  # noqa: E402
import agy_shim  # noqa: E402

TOOLS = [
    {"type": "function", "function": {"name": "web_search", "description": "Search the web.",
                                      "parameters": {"type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"]}}},
    {"type": "function", "function": {"name": "tasks_add", "description": "Create a task card.",
                                      "parameters": {"type": "object", "additionalProperties": False,
                                                     "properties": {"tenant": {"type": "string"}, "title": {"type": "string"},
                                                                    "priority": {"type": "string", "enum": ["low", "high"]},
                                                                    "days": {"type": "integer"}},
                                                     "required": ["tenant", "title"]}}},
]


def step(state, tool="web_search", args=None, server="tools", error=None):
    info = {"name": "call_mcp_tool", "parameters": {"ServerName": server, "ToolName": tool,
                                                    "Arguments": {} if args is None else args}}
    if error is not None:
        info["error"] = error
    su = {"step_type": "tool", "state": state, "tool_name": "call_mcp_tool", "tool_info": info}
    if error is not None:
        su["error"] = error
    return su


class ToolsFile(unittest.TestCase):
    def test_the_file_carries_the_callers_functions_and_the_server_lists_them(self):
        with tempfile.TemporaryDirectory() as d:
            agy_shim.write_tools_file(d, TOOLS)
            fns = tools_mcp.load_tools(d)
            self.assertEqual([f["name"] for f in fns], ["web_search", "tasks_add"])
            listed = tools_mcp.Server(d).handle({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
            names = [t["name"] for t in listed["result"]["tools"]]
            self.assertEqual(names, ["web_search", "tasks_add"])
            schema = listed["result"]["tools"][1]["inputSchema"]
            self.assertEqual(schema["required"], ["tenant", "title"])
            self.assertEqual(schema["type"], "object")

    def test_no_file_means_no_tools_so_a_cli_started_for_something_else_gets_none(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(tools_mcp.load_tools(d), [])
            listed = tools_mcp.Server(d).handle({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
            self.assertEqual(listed["result"]["tools"], [])

    def test_a_toolset_is_identified_by_its_names_regardless_of_order(self):
        self.assertEqual(agy_shim.tools_signature(TOOLS), agy_shim.tools_signature(list(reversed(TOOLS))))
        self.assertNotEqual(agy_shim.tools_signature(TOOLS), agy_shim.tools_signature(TOOLS[:1]))
        self.assertEqual(agy_shim.tools_signature([]), "notools")


class Calls(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        agy_shim.write_tools_file(self.dir, TOOLS)
        self.srv = tools_mcp.Server(self.dir)

    def call(self, name, args):
        return self.srv.handle({"jsonrpc": "2.0", "id": 9, "method": "tools/call",
                                "params": {"name": name, "arguments": args}})["result"]

    def recorded(self):
        path = os.path.join(self.dir, tools_mcp.CALLS_FILE)
        if not os.path.exists(path):
            return []
        with open(path, encoding="utf-8") as f:
            return [json.loads(line) for line in f]

    def test_a_valid_call_is_recorded_and_handed_over_not_executed(self):
        out = self.call("web_search", {"query": "Bundesrat"})
        self.assertFalse(out["isError"])
        self.assertIn("caller runs this call", out["content"][0]["text"])
        rec = self.recorded()
        self.assertEqual(len(rec), 1)
        self.assertEqual((rec[0]["name"], rec[0]["arguments"]), ("web_search", {"query": "Bundesrat"}))

    def test_missing_arguments_are_a_correction_the_model_can_act_on_and_nothing_is_recorded(self):
        out = self.call("tasks_add", {})
        self.assertTrue(out["isError"])
        text = out["content"][0]["text"]
        self.assertIn("missing required 'tenant'", text)
        self.assertIn("missing required 'title'", text)
        self.assertEqual(self.recorded(), [])

    def test_wrong_types_unknown_arguments_and_enums_are_reported(self):
        self.assertIn("'days' must be integer", self.call("tasks_add", {"tenant": "A", "title": "t", "days": "3"})["content"][0]["text"])
        self.assertIn("unknown argument 'x'", self.call("tasks_add", {"tenant": "A", "title": "t", "x": 1})["content"][0]["text"])
        self.assertIn("must be one of", self.call("tasks_add", {"tenant": "A", "title": "t", "priority": "mid"})["content"][0]["text"])
        self.assertEqual(self.recorded(), [])

    def test_an_unknown_tool_is_refused(self):
        out = self.call("delete_everything", {})
        self.assertTrue(out["isError"])
        self.assertIn("unknown tool", out["content"][0]["text"])
        self.assertEqual(self.recorded(), [])

    def test_the_server_speaks_the_protocol_over_stdio(self):
        msgs = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
                {"jsonrpc": "2.0", "method": "notifications/initialized"},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
                {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "web_search", "arguments": {"query": "x"}}}]
        proc = subprocess.run([sys.executable, os.path.join(SHIM_DIR, "tools_mcp.py")], cwd=self.dir,
                              input="".join(json.dumps(m) + "\n" for m in msgs),
                              capture_output=True, text=True, timeout=30)
        replies = [json.loads(l) for l in proc.stdout.splitlines() if l.strip()]
        self.assertEqual([r["id"] for r in replies], [1, 2, 3])          # the notification gets no reply
        self.assertEqual(replies[0]["result"]["serverInfo"]["name"], "tools")
        self.assertEqual([t["name"] for t in replies[1]["result"]["tools"]], ["web_search", "tasks_add"])
        self.assertFalse(replies[2]["result"]["isError"])
        self.assertEqual(self.recorded()[0]["name"], "web_search")


class Decision(unittest.TestCase):
    def test_a_finished_call_to_the_tools_server_is_the_decision(self):
        d = agy_shim.mcp_call_decision(step("DONE", "tasks_add", {"tenant": "Acme", "title": "t"}))
        self.assertEqual(d, {"type": "tool_call", "name": "tasks_add", "arguments": {"tenant": "Acme", "title": "t"}})

    def test_the_first_incomplete_attempt_is_not_a_decision_so_the_model_may_correct_itself(self):
        self.assertIsNone(agy_shim.mcp_call_decision(step("ACTIVE", "tasks_add", {})))
        self.assertIsNone(agy_shim.mcp_call_decision(step("ERROR", "tasks_add", {},
                                                          error={"message": "invalid arguments: missing required 'tenant'"})))

    def test_a_denied_call_with_arguments_is_salvaged_so_the_turn_is_not_lost(self):
        d = agy_shim.mcp_call_decision(step("ERROR", "web_search", {"query": "x"},
                                            error={"message": 'permission check failed for mcp "tools/web_search": user denied permission'}))
        self.assertEqual(d["name"], "web_search")
        self.assertEqual(d["arguments"], {"query": "x"})

    def test_another_server_another_tool_and_other_steps_are_none_of_our_business(self):
        self.assertIsNone(agy_shim.mcp_call_decision(step("DONE", server="probe")))
        self.assertIsNone(agy_shim.mcp_call_decision({"step_type": "tool", "state": "DONE",
                                                      "tool_info": {"name": "view_file", "parameters": {}}}))
        self.assertIsNone(agy_shim.mcp_call_decision({"step_type": "agent_response", "state": "DONE"}))
        self.assertIsNone(agy_shim.mcp_call_decision({}))


class Contract(unittest.TestCase):
    def test_the_native_contract_names_the_functions_without_schemas_or_json_envelope(self):
        text = agy_shim.tool_contract(TOOLS, native=True)
        self.assertIn("web_search: Search the web.", text)
        self.assertIn("tasks_add: Create a task card.", text)
        self.assertIn("`tools` server", text)
        self.assertNotIn('{"type":"tool_call"', text)
        self.assertNotIn("properties", text)
        self.assertIn("Never write a tool call as JSON text", text)

    def test_the_text_protocol_is_still_there_for_a_cli_without_the_tools_server(self):
        text = agy_shim.tool_contract(TOOLS)
        self.assertIn("NO tools", text)
        self.assertIn('{"type":"tool_call"', text)
        self.assertIn("properties", text)

    def test_no_tools_no_contract_in_either_mode(self):
        self.assertEqual(agy_shim.tool_contract([]), "")
        self.assertEqual(agy_shim.tool_contract([], native=True), "")


class Detection(unittest.TestCase):
    def _home(self, servers, allow):
        d = tempfile.mkdtemp()
        os.makedirs(os.path.join(d, ".gemini", "config"))
        os.makedirs(os.path.join(d, ".gemini", "antigravity-cli"))
        with open(os.path.join(d, ".gemini", "config", "mcp_config.json"), "w") as f:
            json.dump({"mcpServers": servers}, f)
        with open(os.path.join(d, ".gemini", "antigravity-cli", "settings.json"), "w") as f:
            json.dump({"permissions": {"allow": allow}}, f)
        return d

    def run_with_home(self, home):
        old = os.environ.get("HOME")
        os.environ["HOME"] = home
        try:
            return agy_shim.tools_server_configured()
        finally:
            if old is not None:
                os.environ["HOME"] = old

    def test_the_server_entry_decides_and_the_allow_rule_is_checked(self):
        entry = {"command": "/usr/bin/python3", "args": ["/usr/local/lib/x/tools_mcp.py"]}
        self.assertTrue(self.run_with_home(self._home({"tools": entry}, ["mcp(tools/*)"])))
        with self.assertLogs("agy-shim", level="WARNING") as logs:
            self.assertTrue(self.run_with_home(self._home({"tools": entry}, [])))
        self.assertIn("allow rule", "\n".join(logs.output))
        self.assertFalse(self.run_with_home(self._home({}, ["mcp(tools/*)"])))
        self.assertFalse(self.run_with_home(self._home({"tools": dict(entry, disabled=True)}, ["mcp(tools/*)"])))
        self.assertFalse(self.run_with_home(tempfile.mkdtemp()))


if __name__ == "__main__":
    unittest.main()
