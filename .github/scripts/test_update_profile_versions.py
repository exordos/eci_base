import unittest
import base64
import subprocess
from unittest.mock import patch

import yaml

from update_profile_versions import UPDATE_BRANCH, update_repository, update_versions


class UpdateVersionsTests(unittest.TestCase):
    def test_updates_only_matching_images_and_preserves_comments(self):
        source = '''# Header
build:
  elements:
    - images:
        - name: full
          profile: exordos_base
          profile_version: "1.2.1" # Keep comment
        - name: minimal
          profile: exordos_base_minimal
          profile_version: '1.2.1'
        - name: unrelated
          profile: ubuntu_26
          profile_version: "1.2.1"
other:
  profile: exordos_base
  profile_version: "1.2.1"
'''
        expected = source.replace('"1.2.1" #', '"1.3.6" #').replace("'1.2.1'", '"1.3.6"')
        self.assertEqual(update_versions(source, "1.3.6"), expected)
        self.assertEqual(update_versions(expected, "1.3.6"), expected)

    def test_missing_version_is_inserted_in_image(self):
        for newline in ("\n", "\r\n"):
            source = 'build:\n  elements:\n    - images:\n        - profile: exordos_base # Comment\n          name: full\n'.replace("\n", newline)
            result = update_versions(source, "1.3.6")
            image = yaml.safe_load(result)["build"]["elements"][0]["images"][0]
            self.assertEqual(image["profile_version"], "1.3.6")
            self.assertIn("# Comment" + newline, result)
            self.assertEqual(update_versions(result, "1.3.6"), result)

    def test_flow_mapping_existing_version(self):
        source = 'build: {elements: [{images: [{profile: exordos_base, profile_version: 1.2.1}]}]}'
        result = update_versions(source, "1.3.6")
        self.assertEqual(yaml.safe_load(result)["build"]["elements"][0]["images"][0]["profile_version"], "1.3.6")

    def test_empty_or_unrelated_document(self):
        for source in ("", "# Comment\n", "other: value\n"):
            self.assertEqual(update_versions(source, "1.3.6"), source)

    def run_repository(self, existing=False, unchanged=False, fallback=False):
        source = 'build: {elements: [{images: [{profile: exordos_base, profile_version: "1.2.1"}]}]}'
        if unchanged:
            source = source.replace("1.2.1", "1.3.6")
        responses = [
            {"object": {"sha": "base"}},
        ]
        if fallback:
            responses.append(subprocess.CalledProcessError(
                1, "gh", stderr="gh: Not Found (HTTP 404)"))
        responses.append({"content": base64.b64encode(source.encode()).decode()})
        if not unchanged:
            responses += [{"tree": {"sha": "base-tree"}}, {"sha": "updated-tree"}]
            if existing:
                responses += [[{"ref": f"refs/heads/{UPDATE_BRANCH}",
                                "object": {"sha": "previous"}}],
                              {"tree": {"sha": "updated-tree"}},
                              [{"number": 42}], {"html_url": "https://example.test/pr/42"}]
            else:
                responses += [[], {"sha": "new-commit"}, {}, [],
                              {"html_url": "https://example.test/pr/1"}]
        with patch("update_profile_versions.api", side_effect=responses) as mock:
            update_repository("exordos/test", "master", "1.3.6")
        return mock.call_args_list

    def test_creates_update_branch_and_pr_without_changing_default_branch(self):
        calls = self.run_repository()
        writes = [call for call in calls if "method" in call.kwargs]
        self.assertEqual([call.kwargs["method"] for call in writes], ["POST"] * 4)
        self.assertEqual(writes[2].args[1]["ref"], f"refs/heads/{UPDATE_BRANCH}")
        self.assertEqual(writes[3].args[1]["base"], "master")
        self.assertEqual(writes[3].args[1]["head"], UPDATE_BRANCH)

    def test_repeat_run_reuses_pr_and_does_not_create_another_commit(self):
        calls = self.run_repository(existing=True)
        writes = [call for call in calls if "method" in call.kwargs]
        self.assertEqual(len(writes), 2)
        self.assertEqual(writes[1].args[0], "/repos/exordos/test/pulls/42")
        self.assertEqual(writes[1].kwargs["method"], "PATCH")

    def test_up_to_date_repository_has_no_writes(self):
        calls = self.run_repository(unchanged=True)
        self.assertFalse(any("method" in call.kwargs for call in calls))

    def test_root_path_is_a_fallback_and_no_tree_is_scanned(self):
        calls = self.run_repository(fallback=True)
        self.assertEqual(calls[1].args[0], "/repos/exordos/test/contents/exordos/exordos.yaml?ref=base")
        self.assertEqual(calls[2].args[0], "/repos/exordos/test/contents/exordos.yaml?ref=base")
        tree_write = next(call for call in calls if call.args[0].endswith("/git/trees"))
        self.assertEqual(tree_write.args[1]["tree"][0]["path"], "exordos.yaml")
        self.assertFalse(any("recursive=" in call.args[0] for call in calls))

    def test_missing_manifests_skip_repository(self):
        missing = subprocess.CalledProcessError(1, "gh", stderr="gh: Not Found (HTTP 404)")
        with patch("update_profile_versions.api", side_effect=[
            {"object": {"sha": "base"}}, missing, missing,
        ]) as mock:
            update_repository("exordos/test", "master", "1.3.6")
        self.assertEqual(mock.call_count, 3)

    def test_api_failures_are_not_treated_as_missing_manifests(self):
        forbidden = subprocess.CalledProcessError(1, "gh", stderr="gh: Forbidden (HTTP 403)")
        with patch("update_profile_versions.api", side_effect=[
            {"object": {"sha": "base"}}, forbidden,
        ]) as mock:
            with self.assertRaises(subprocess.CalledProcessError):
                update_repository("exordos/test", "master", "1.3.6")
        self.assertEqual(mock.call_count, 2)


if __name__ == "__main__":
    unittest.main()
