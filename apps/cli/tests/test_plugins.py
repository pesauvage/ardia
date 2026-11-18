import contextlib
import io
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from ardia_cli import cli, control, plugins_cli

FIXTURES = Path(__file__).resolve().parent / "fixtures"
EXAMPLE = Path(__file__).resolve().parents[3] / "tests" / "fixtures" / "plugins" / "example"
LEGACY = {
    "name": "compact-command-bar",
    "title": "Compact command bar",
    "description": "Fewer tabs before you type.",
    "requires": "0.2.46-nightly.4",
    "settings": {"commandBarStart": {"openTabs": {"limit": 5}}},
    "reset": {"commandBarStart": {}},
}


class PluginsCliTest(unittest.TestCase):
    def setUp(self):
        self.data = Path(tempfile.mkdtemp(prefix="ardia-plugins-"))
        schema_dir = self.data / "config-schema"
        schema_dir.mkdir()
        shutil.copy(FIXTURES / "plugin.schema.json", schema_dir / "plugin.schema.json")
        self.unreachable = mock.patch.object(control, "call", side_effect=control.unreachable("test"))
        self.unreachable.start()

    def tearDown(self):
        self.unreachable.stop()
        shutil.rmtree(self.data, ignore_errors=True)

    def ardia(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = cli.run(["plugins", *args, "--data-dir", str(self.data)])
        return status, out.getvalue(), err.getvalue()

    def test_install_copies_the_example_and_refuses_a_second_copy(self):
        status, out, _ = self.ardia("install", str(EXAMPLE))
        self.assertEqual(status, 0)
        self.assertIn("It's off", out)
        installed = self.data / "config" / "plugins" / "example"
        self.assertTrue((installed / "plugin.json").is_file())
        self.assertTrue((installed / "page" / "index.html").is_file())
        self.assertEqual(self.ardia("install", str(EXAMPLE))[0], 1)
        self.assertEqual(self.ardia("install", str(EXAMPLE), "--force")[0], 0)

    def test_a_settings_only_plugin_installs_from_its_plugin_json(self):
        source = self.data / "legacy.json"
        source.write_text(json.dumps(LEGACY))
        self.assertEqual(self.ardia("install", str(source))[0], 0)
        self.assertEqual(json.loads((self.data / "config" / "plugins" / "compact-command-bar" / "plugin.json").read_text()), LEGACY)

    def test_check_reports_schema_problems_with_their_path(self):
        bad = self.data / "bad"
        bad.mkdir()
        manifest = json.loads((EXAMPLE / "plugin.json").read_text())
        manifest["process"]["memoryMB"] = 1
        manifest["typo"] = True
        (bad / "plugin.json").write_text(json.dumps(manifest))
        status, out, _ = self.ardia("check", str(bad) + "/")
        self.assertEqual(status, 1)
        self.assertIn("process.memoryMB", out)
        self.assertIn("typo", out)
        status, _, err = self.ardia("install", str(bad))
        self.assertEqual(status, 1)
        self.assertIn("memoryMB", err)

    def test_check_refuses_every_manifest_the_app_refuses(self):
        cases = json.loads((EXAMPLE.parent / "rejected-manifests.json").read_text())
        for case in cases:
            folder = self.data / "cases" / str(cases.index(case))
            folder.mkdir(parents=True)
            (folder / "plugin.json").write_text(json.dumps(case["manifest"]))
            status, out, _ = self.ardia("check", str(folder) + "/")
            self.assertEqual(status, 1, f"{case['why']}: {out}")
        self.assertEqual(self.ardia("check", str(EXAMPLE) + "/")[0], 0)

    def test_install_checks_the_copy_it_publishes(self):
        source = self.data / "changing"
        shutil.copytree(EXAMPLE, source)
        real_copy = plugins_cli.copy_tree

        def swap_while_copying(src, dst):
            real_copy(src, dst)
            manifest = json.loads((dst / "plugin.json").read_text())
            manifest["permissions"] = ["fullUrls"]
            (dst / "plugin.json").write_text(json.dumps(manifest))

        with mock.patch.object(plugins_cli, "copy_tree", side_effect=swap_while_copying):
            status, _, err = self.ardia("install", str(source))
        self.assertEqual(status, 1)
        self.assertIn("fullUrls needs tabs", err)
        self.assertFalse((self.data / "config" / "plugins" / "example").exists())

    def test_install_never_replaces_a_plugin_that_appears_while_it_copies(self):
        target = self.data / "config" / "plugins" / "example"
        real_copy = plugins_cli.copy_tree

        def another_install_lands_first(src, dst):
            real_copy(src, dst)
            target.mkdir(parents=True)
            (target / "plugin.json").write_text('{"name": "example", "title": "Theirs"}')

        with mock.patch.object(plugins_cli, "copy_tree", side_effect=another_install_lands_first):
            status, _, err = self.ardia("install", str(EXAMPLE))
        self.assertEqual(status, 1)
        self.assertIn("already installed", err)
        self.assertEqual(json.loads((target / "plugin.json").read_text())["title"], "Theirs")

    def test_a_forced_replace_that_fails_keeps_the_old_install(self):
        self.assertEqual(self.ardia("install", str(EXAMPLE))[0], 0)
        target = self.data / "config" / "plugins" / "example"
        before = (target / "plugin.json").read_text()
        with mock.patch.object(plugins_cli, "rename_no_replace", side_effect=OSError("disk full")):
            status, _, _ = self.ardia("install", str(EXAMPLE), "--force")
        self.assertEqual(status, 1)
        self.assertEqual((target / "plugin.json").read_text(), before, "the old install is still there")
        self.assertEqual(sorted(p.name for p in target.parent.iterdir()), ["example"], "and nothing is left beside it")

    def test_a_forced_install_that_fails_its_checks_leaves_the_installed_plugin_on(self):
        self.assertEqual(self.ardia("install", str(EXAMPLE))[0], 0)
        broken = self.data / "broken"
        shutil.copytree(EXAMPLE, broken)
        manifest = json.loads((broken / "plugin.json").read_text())
        manifest["permissions"] = ["fullUrls"]
        (broken / "plugin.json").write_text(json.dumps(manifest))
        real_copy = plugins_cli.copy_tree
        self.unreachable.stop()
        with mock.patch.object(control, "call", return_value={}) as call, mock.patch.object(plugins_cli, "manifest_problems", side_effect=[[], ["broken"]]), mock.patch.object(plugins_cli, "copy_tree", side_effect=real_copy):
            status, _, _ = self.ardia("install", str(broken), "--force")
        self.unreachable.start()
        self.assertEqual(status, 1)
        self.assertNotIn("plugins.disable", [c.args[1] for c in call.call_args_list], "nothing is turned off before the new copy passes")

    def test_check_reports_an_installed_folder_whose_name_differs_from_its_manifest(self):
        folder = self.data / "config" / "plugins" / "renamed"
        shutil.copytree(EXAMPLE, folder)
        status, out, _ = self.ardia("check", "renamed")
        self.assertEqual(status, 1)
        self.assertIn("but its folder is renamed", out)

    def test_list_and_remove_work_from_the_files_when_ardia_is_away(self):
        self.ardia("install", str(EXAMPLE))
        status, out, _ = self.ardia("list", "--json")
        self.assertEqual(status, 0)
        listed = json.loads(out)
        self.assertEqual([p["name"] for p in listed], ["example"])
        self.assertEqual(listed[0]["problems"], [])
        self.assertEqual(self.ardia("remove", "example")[0], 0)
        self.assertFalse((self.data / "config" / "plugins" / "example").exists())
        self.assertEqual(self.ardia("remove", "example")[0], 1)

    def test_links_inside_a_plugin_are_refused(self):
        source = self.data / "linked"
        shutil.copytree(EXAMPLE, source)
        (source / "escape").symlink_to(Path.home())
        status, _, err = self.ardia("install", str(source))
        self.assertEqual(status, 1)
        self.assertIn("is a link", err)

    def test_enable_and_call_need_ardia(self):
        self.assertEqual(self.ardia("enable", "example")[0], 2)
        self.assertEqual(self.ardia("call", "example", "hello")[0], 2)

    def test_call_sends_the_tool_and_prints_its_result(self):
        self.unreachable.stop()
        with mock.patch.object(control, "call", return_value={"text": "Hello"}) as call:
            status, out, _ = self.ardia("call", "example", "hello", '{"who": "you"}')
        self.unreachable.start()
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(out), {"text": "Hello"})
        self.assertEqual(call.call_args.args[1:3], ("plugins.call", {"plugin": "example", "tool": "hello", "input": {"who": "you"}}))
        self.assertGreaterEqual(call.call_args.args[3], 300)


if __name__ == "__main__":
    unittest.main()
