import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]


class LoginAssistPerformanceTests(unittest.TestCase):
    def test_safari_step_advances_multiple_login_states_per_process(self) -> None:
        text = (PROJECT_DIR / "src" / "js" / "kaikey_safari_step.js").read_text(
            encoding="utf-8"
        )

        self.assertIn("advanceUntilTerminal", text)
        self.assertIn("advanceOneStep", text)
        self.assertIn('options["max-seconds"]', text)
        self.assertIn('options["poll-ms"]', text)
        self.assertIn("isTerminalStatus", text)
        self.assertIn("readTitle(tab)", text)
        self.assertNotIn("const title = safeString(() => tab.name())", text)
        self.assertNotIn("delay(0.5)", text)
        self.assertNotIn("delay(0.8)", text)

    def test_shell_login_assist_uses_inner_safari_polling(self) -> None:
        text = (PROJECT_DIR / "bin" / "kaikey_auto_login.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn("KAIKEY_SAFARI_STEP_TIMEOUT_SECONDS", text)
        self.assertIn("KAIKEY_SAFARI_STEP_POLL_MS", text)
        self.assertIn('KAIKEY_AUTO_LOGIN_POLL_SECONDS="${KAIKEY_AUTO_LOGIN_POLL_SECONDS:-0.2}"', text)
        self.assertIn('KAIKEY_SAFARI_STEP_POLL_MS="${KAIKEY_SAFARI_STEP_POLL_MS:-75}"', text)
        self.assertIn("--max-seconds=$KAIKEY_SAFARI_STEP_TIMEOUT_SECONDS", text)
        self.assertIn("--poll-ms=$KAIKEY_SAFARI_STEP_POLL_MS", text)


if __name__ == "__main__":
    unittest.main()
