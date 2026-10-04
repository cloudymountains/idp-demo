"""The harness holds without a model, so it is tested without one.

    ./.venv/bin/python -m unittest discover -s agent/tests -t .

A scripted stand-in plays the model. Each test is a way an agent might push on
the boundary, and an assertion that the boundary did not move.
"""

from __future__ import annotations

import os
import pathlib
import shutil
import tempfile
import types
import unittest

SOURCE = pathlib.Path(__file__).resolve().parents[2]

GOOD = """\
apiVersion: platform.cloudymountains.io/v1
kind: Service
metadata:
  name: orders
  owner: checkout-team
  costCentre: CC-4472
  environment: dev
spec:
  runtime: { type: container }
  database:
    engine: postgres
    size: {size}
"""


def text(value):
    return types.SimpleNamespace(type="text", text=value)


def tool(name, **args):
    return types.SimpleNamespace(type="tool_use", id=f"t{id(args)}", name=name, input=args)


def scripted(*turns):
    """A model that plays back fixed turns, then repeats the last one."""
    calls = iter(turns)
    last = [turns[-1]]

    def complete(system, tools, messages):
        last[0] = next(calls, last[0])
        return types.SimpleNamespace(content=list(last[0]))

    return complete


class AgentTest(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.repo = self.tmp / "repo"
        for rel in ("platform/bin", "platform/schemas", "platform/policies", "platform/evals",
                    "platform/skills", ".kiro/steering", "services"):
            shutil.copytree(SOURCE / rel, self.repo / rel, ignore=shutil.ignore_patterns("__pycache__"))
        (self.repo / ".env").write_text("SECRET=hunter2\n")
        os.environ["AGENT_DECISIONS_FILE"] = str(self.tmp / "decisions.jsonl")
        for name in ("DECISION_LOG", "DECISION_LOG_ENDPOINT"):
            os.environ.pop(name, None)
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def run_agent(self, *turns):
        from agent.loop import run

        return run("test request", complete=scripted(*turns), repo=self.repo, on_event=lambda *_: None)

    def harness(self):
        from agent.harness import Harness

        return Harness(self.repo)

    def decisions(self):
        from agent import decisions

        return [(d["phase"], d["verdict"]) for d in decisions.recent("orders")][::-1]

    # -- the controls ---------------------------------------------------------

    def test_cannot_read_outside_the_allow_list(self):
        h = self.harness()
        for path in (".env", "../../etc/passwd", "/etc/passwd", "platform/bin/check.sh", "services/../.env"):
            output, is_error = h.call("read_file", {"path": path})
            self.assertTrue(is_error, path)
            self.assertNotIn("hunter2", output)

    def test_can_read_the_contract(self):
        output, is_error = self.harness().call("read_file", {"path": "platform/schemas/service.v1.json"})
        self.assertFalse(is_error)
        self.assertIn("costCentre", output)

    def test_cannot_write_anywhere_but_a_manifest(self):
        h = self.harness()
        before = (self.repo / "platform/policies/service.rego").read_text()
        for name in ("../platform/policies", "a/b", "../../x", "Orders", "", "x"):
            _, is_error = h.call("write_manifest", {"service": name, "content": "package platform.service\n"})
            self.assertTrue(is_error, name)
        self.assertEqual(before, (self.repo / "platform/policies/service.rego").read_text())
        self.assertEqual({}, h.snapshots)

    def test_there_is_no_shell(self):
        h = self.harness()
        for name in ("bash", "run_command", "terraform_apply", "edit_policy"):
            _, is_error = h.call(name, {"command": "rm -rf /"})
            self.assertTrue(is_error, name)

    def test_oversized_manifest_is_refused(self):
        _, is_error = self.harness().call("write_manifest", {"service": "orders", "content": "x: y\n" * 2000})
        self.assertTrue(is_error)

    # -- the loop -------------------------------------------------------------

    def test_denied_then_corrected(self):
        result = self.run_agent(
            [tool("write_manifest", service="orders", content=GOOD.replace("{size}", "xlarge"))],
            [tool("run_checks")],
            [tool("write_manifest", service="orders", content=GOOD.replace("{size}", "medium"))],
            [tool("run_checks")],
            [text("xlarge is not allowed in dev, so orders gets a medium database.")],
        )
        self.assertEqual("ready", result.status)
        self.assertIn("size: medium", result.manifests["services/orders/service.yaml"])
        self.assertIn("xlarge is not permitted in environment=dev", result.denials[0])
        self.assertEqual(
            [("request", "proposed"), ("policy", "denied"), ("policy", "corrected")], self.decisions())

    def test_claiming_done_on_a_denied_manifest_keeps_nothing(self):
        result = self.run_agent(
            [tool("write_manifest", service="orders", content=GOOD.replace("{size}", "xlarge"))],
            [text("Done. The orders database is provisioned as xlarge.")],
        )
        self.assertEqual("refused", result.status)
        self.assertEqual({}, result.manifests)
        self.assertFalse((self.repo / "services/orders").exists())
        self.assertIn(("policy", "denied"), self.decisions())

    def test_a_failed_change_restores_the_existing_manifest(self):
        path = self.repo / "services/analytics/service.yaml"
        before = path.read_text()
        result = self.run_agent(
            [tool("write_manifest", service="analytics", content=before.replace("size: medium", "size: xlarge"))],
            [text("Done.")],
        )
        self.assertEqual("refused", result.status)
        self.assertEqual(before, path.read_text())

    def test_a_question_goes_back_to_the_caller(self):
        result = self.run_agent([tool("ask_caller", question="Which environment: dev, staging or prod?")])
        self.assertEqual("needs_input", result.status)
        self.assertIn("Which environment", result.message)
        self.assertFalse((self.repo / "services/orders").exists())

    def test_the_turn_limit_ends_a_loop_that_will_not(self):
        result = self.run_agent(
            [tool("write_manifest", service="orders", content=GOOD.replace("{size}", "xlarge"))],
            [tool("run_checks")],
        )
        self.assertEqual("gave_up", result.status)
        self.assertFalse((self.repo / "services/orders").exists())

    def test_a_model_failure_midway_leaves_nothing_behind(self):
        from agent.loop import run

        turns = iter([[tool("write_manifest", service="orders", content=GOOD.replace("{size}", "small"))]])

        def complete(system, tools, messages):
            try:
                return types.SimpleNamespace(content=next(turns))
            except StopIteration:
                raise ConnectionError("model unreachable") from None

        result = run("test request", complete=complete, repo=self.repo, on_event=lambda *_: None)
        self.assertEqual("error", result.status)
        self.assertFalse((self.repo / "services/orders").exists())

    def test_text_only_changes_nothing(self):
        result = self.run_agent([text("The schema has no queue type. The closest option is a container service.")])
        self.assertEqual("no_change", result.status)

    # -- memory ---------------------------------------------------------------

    def denied_then_corrected(self, service="orders"):
        good = GOOD.replace("name: orders", f"name: {service}")
        return self.run_agent(
            [tool("write_manifest", service=service, content=good.replace("{size}", "xlarge"))],
            [tool("run_checks")],
            [tool("write_manifest", service=service, content=good.replace("{size}", "medium"))],
            [text("Settled on medium.")],
        )

    def test_memory_recalls_the_refusal_and_what_passed(self):
        from agent import memory

        self.assertIn("No refusals on record", memory.recall("dev"))
        self.denied_then_corrected()
        told = memory.recall("dev", "orders")
        self.assertIn("refused 1x: database.size=xlarge is not permitted in environment=dev", told)
        self.assertIn("Allowed: small, medium", told)
        self.assertIn("passed afterwards 1x: database postgres/medium", told)
        self.assertIn("Recent history for orders", told)

    def test_memory_is_scoped_by_environment(self):
        from agent import memory

        self.denied_then_corrected()
        self.assertIn("No refusals on record", memory.recall("prod"))

    def test_memory_forgets_old_entries(self):
        from agent import decisions, memory

        self.denied_then_corrected()
        self.assertEqual(1, len(memory.lessons(memory.fresh(decisions.everything()))))
        self.assertEqual([], memory.fresh(decisions.everything(), days=-1))

    def test_the_agent_can_ask_its_memory(self):
        self.denied_then_corrected()
        seen = []

        def complete(system, tools, messages):
            if len(messages) == 1:
                return types.SimpleNamespace(content=[tool("recall", environment="dev")])
            seen.append(messages[-1]["content"][0]["content"])
            return types.SimpleNamespace(content=[text("Noted.")])

        from agent.loop import run

        run("test request", complete=complete, repo=self.repo, on_event=lambda *_: None)
        self.assertIn("xlarge is not permitted", seen[0])

    def test_memory_can_be_switched_off(self):
        from agent.harness import tools

        os.environ["AGENT_MEMORY"] = "off"
        self.addCleanup(os.environ.pop, "AGENT_MEMORY", None)
        self.assertNotIn("recall", [t["name"] for t in tools()])
        _, is_error = self.harness().call("recall", {"environment": "dev"})
        self.assertTrue(is_error)

    def test_memory_does_not_overrule_policy(self):
        # Even with precedent on record, a denied manifest is still discarded.
        self.denied_then_corrected()
        result = self.run_agent(
            [tool("recall", environment="dev")],
            [tool("write_manifest", service="payments",
                  content=GOOD.replace("name: orders", "name: payments").replace("{size}", "xlarge"))],
            [text("Done.")],
        )
        self.assertEqual("refused", result.status)

    def test_patterns_surface_what_keeps_recurring(self):
        from agent import memory

        for service in ("orders", "payments", "reporting"):
            self.denied_then_corrected(service)
        self.assertEqual([], memory.patterns(minimum=4))
        found = memory.patterns(minimum=3)
        self.assertEqual(3, found[0]["count"])
        self.assertEqual({"orders", "payments", "reporting"}, found[0]["services"])


if __name__ == "__main__":
    unittest.main()
