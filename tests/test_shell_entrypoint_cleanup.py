import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]


class ShellEntrypointCleanupTests(unittest.TestCase):
    def test_single_scope_wrappers_use_common_entrypoint(self) -> None:
        for script_name, scope in [
            ("sync_klms_core.sh", "core"),
            ("sync_klms_notice.sh", "notice"),
        ]:
            with self.subTest(script=script_name):
                text = (PROJECT_DIR / script_name).read_text(encoding="utf-8")
                self.assertIn(f"klms_run_sync_scope_entrypoint {scope}", text)
                self.assertNotIn("sync_output=\"$(klms_run_sync_scope", text)

    def test_serial_run_scripts_share_common_job_runner(self) -> None:
        for script_name in ["run_all.sh", "run_all_full.sh"]:
            with self.subTest(script=script_name):
                text = (PROJECT_DIR / script_name).read_text(encoding="utf-8")
                self.assertIn("klms_export_shared_sync_cache_defaults", text)
                self.assertIn("klms_prepare_prefetched_dashboard_for_namespaces", text)
                self.assertIn("klms_run_serial_child_job", text)
                self.assertNotIn("run_serial_job()", text)

    def test_cleanup_script_removes_common_local_artifacts(self) -> None:
        text = (
            PROJECT_DIR / "src" / "sh" / "cleanup_runtime_tmp.sh"
        ).read_text(encoding="utf-8")

        self.assertIn('".DS_Store"', text)
        self.assertIn('"__pycache__"', text)
        self.assertIn('"*.pyc"', text)


if __name__ == "__main__":
    unittest.main()
