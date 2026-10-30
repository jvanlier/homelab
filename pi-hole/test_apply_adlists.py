import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import apply_adlists

PRO = "https://example.org/pro.txt"
TIF = "https://example.org/tif.txt"


class ApplyAdlistsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        directory = Path(temporary.name)
        (directory / "adlists.txt").write_text(f"# Security lists\n{PRO}\n\n{TIF}\n{PRO}\n")
        self.directory = directory
        self.enterContext(patch.object(apply_adlists, "DIRECTORY", directory))
        self.password = self.enterContext(patch.object(apply_adlists.getpass, "getpass", return_value="secret"))
        self.docker = self.enterContext(patch.object(apply_adlists.subprocess, "run"))
        self.enterContext(patch("builtins.print"))

    def api(self, lists, fail_add=False):
        """Model API state across runs, including disabled and unrelated lists."""
        mutations = []

        def request(method, path, payload=None, sid=None):
            if path == "/auth" and method == "POST":
                self.assertEqual(payload, {"password": "secret"})
                return {"session": {"valid": True, "sid": "test-session"}}
            self.assertEqual(sid, "test-session")
            if path == "/auth" and method == "DELETE":
                return {}
            self.assertEqual(path, "/lists?type=block")
            if method == "GET":
                return {"lists": list(lists.values())}
            self.assertEqual(method, "POST")
            address = payload["address"]
            if fail_add:
                # Pi-hole can report item failures in an HTTP success response.
                return {"processed": {"errors": [{"item": address, "error": "database failure"}], "success": []}}
            self.assertNotIn(address, lists)
            self.assertEqual(payload["groups"], [0])
            self.assertTrue(payload["enabled"])
            lists[address] = payload.copy()
            mutations.append(address)
            return {"processed": {"errors": [], "success": [{"item": address}]}}

        return request, mutations

    def test_rerun_preserves_disabled_and_unrelated_lists(self):
        disabled = {"address": PRO, "enabled": False, "groups": [2]}
        unrelated = {"address": "https://example.org/other.txt", "enabled": True, "groups": [3]}
        lists = {PRO: disabled.copy(), unrelated["address"]: unrelated.copy()}
        api, mutations = self.api(lists)
        with patch.object(apply_adlists, "request", side_effect=api) as request:
            apply_adlists.main()
            apply_adlists.main()
        self.assertEqual(mutations, [TIF])
        self.assertEqual(lists[PRO], disabled)
        self.assertEqual(lists[unrelated["address"]], unrelated)
        self.assertEqual(sum(call.args[:2] == ("DELETE", "/auth") for call in request.call_args_list), 2)
        gravity_calls = [call for call in self.docker.call_args_list if call.args[0][-1] == "-g"]
        self.assertEqual(len(gravity_calls), 2)

    def test_item_failure_logs_out_and_stops_before_gravity(self):
        api, _ = self.api({}, fail_add=True)
        with patch.object(apply_adlists, "request", side_effect=api) as request:
            with self.assertRaisesRegex(RuntimeError, "database failure"):
                apply_adlists.main()
        self.assertEqual(request.call_args.args, ("DELETE", "/auth"))
        self.assertEqual(len(self.docker.call_args_list), 1)

    def test_docker_failure_stops_before_authentication(self):
        self.docker.side_effect = subprocess.CalledProcessError(1, "docker")
        with self.assertRaises(subprocess.CalledProcessError):
            apply_adlists.main()
        self.password.assert_not_called()

    def test_invalid_url_stops_before_changes(self):
        for address in ("http://example.org/list", "https://user:secret@example.org/list", "https://example.org/a b"):
            with self.subTest(address=address):
                (self.directory / "adlists.txt").write_text(address)
                with self.assertRaises(ValueError):
                    apply_adlists.main()
        self.docker.assert_not_called()
        self.password.assert_not_called()


if __name__ == "__main__":
    unittest.main()
