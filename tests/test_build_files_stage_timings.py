import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]


class BuildFilesStageTimingsTests(unittest.TestCase):
    def test_builds_json_summary_from_file_refresh_log(self) -> None:
        script = PROJECT_DIR / "src" / "python" / "build_files_stage_timings.py"
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            log_path = tmp_path / "stage_timings.log"
            output_path = tmp_path / "stage_timings.json"
            log_path.write_text(
                "\n".join(
                    [
                        "[files 2026-05-08 15:59:06 KST] refresh start output_root=/tmp mode=auto",
                        "[files 2026-05-08 15:59:10 KST] fetch start context=files-seed-pages mode=auto",
                        "[files 2026-05-08 15:59:25 KST] fetch finish context=files-seed-pages status=0 duration_s=15",
                        "[files 2026-05-08 15:59:27 KST] manifest build start",
                        "[files 2026-05-08 15:59:38 KST] manifest build finish duration_s=11",
                        "[files 2026-05-08 15:59:39 KST] refresh finish",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            subprocess.run(
                [
                    sys.executable,
                    str(script),
                    "--log",
                    str(log_path),
                    "--output-json",
                    str(output_path),
                ],
                check=True,
                capture_output=True,
                text=True,
            )

            payload = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertEqual(payload["scope"], "files")
            self.assertEqual(payload["status"], "ok")
            self.assertEqual(payload["elapsed_ms"], 33000)
            self.assertEqual(payload["slowest_stages"][0]["name"], "files-seed-pages")
            self.assertEqual(payload["slowest_stages"][0]["duration_ms"], 15000)
            self.assertEqual(payload["slowest_stages"][1]["name"], "manifest build")
            self.assertEqual(payload["slowest_stages"][1]["duration_ms"], 11000)


if __name__ == "__main__":
    unittest.main()
