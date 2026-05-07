import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]


class DownloadFilenameSafetyTests(unittest.TestCase):
    def test_logged_filename_reuse_rejects_cross_source_ambiguous_names(self) -> None:
        text = (PROJECT_DIR / "src" / "js" / "download_klms_files.js").read_text(
            encoding="utf-8"
        )

        self.assertIn("ambiguousRecordedFilenames", text)
        self.assertIn("downloadLogFilenameReuseAllowed", text)
        self.assertIn("filenameCompatibleWithExpected", text)
        self.assertIn("freshDownloadFilenameMatchesExpected", text)
        self.assertIn("fetchedPayloadCompatibleWithExpected", text)
        self.assertIn("text/html", text)
        self.assertIn("Downloaded filename does not match expected file type", text)
        self.assertIn("result.course", text)
        self.assertIn("result.source_url", text)


if __name__ == "__main__":
    unittest.main()
