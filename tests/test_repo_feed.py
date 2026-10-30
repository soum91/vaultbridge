import unittest

from scripts.update_repo import make_feed


class FeedTests(unittest.TestCase):
    def values(self, version="0.1.0.1"):
        return dict(version=version, build=version.split(".")[-1], date="2026-10-30",
                    url=f"https://github.com/soum91/vaultbridge/releases/download/vaultbridge-v{version}/VaultBridge.ipa",
                    size=12345, notes="Test release")

    def test_first_release_has_direct_download_and_identity(self):
        feed = make_feed({}, **self.values())
        app = feed["apps"][0]
        self.assertEqual(app["bundleIdentifier"], "com.soum91.vaultbridge")
        self.assertTrue(feed["sourceURL"].endswith("/source.json"))
        self.assertTrue(app["iconURL"].endswith("/Icon-1024.png"))
        self.assertEqual(app["versions"][0]["version"], "0.1.0.1")

    def test_new_version_precedes_old_and_repeat_is_idempotent(self):
        initial = make_feed({}, **self.values())
        updated = make_feed(initial, **self.values("0.1.0.2"))
        self.assertEqual([v["version"] for v in updated["apps"][0]["versions"]],
                         ["0.1.0.2", "0.1.0.1"])
        repeated = make_feed(updated, **self.values("0.1.0.2"))
        self.assertEqual(len(repeated["apps"][0]["versions"]), 2)

    def test_reject_actions_artifact_or_empty_file(self):
        values = self.values()
        values["url"] = "https://github.com/soum91/vaultbridge/actions/runs/123"
        with self.assertRaises(ValueError):
            make_feed({}, **values)
        values = self.values()
        values["size"] = 0
        with self.assertRaises(ValueError):
            make_feed({}, **values)


if __name__ == "__main__":
    unittest.main()
