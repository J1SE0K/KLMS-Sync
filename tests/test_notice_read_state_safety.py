import re
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]


class NoticeReadStateSafetyTests(unittest.TestCase):
    def test_notice_sync_has_no_stable_autoread_path(self) -> None:
        sources = [
            PROJECT_DIR / "src" / "js" / "sync_klms_notes.js",
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift",
        ]
        forbidden = [
            "autoread",
            "markStableDigestNoticesRead",
            "skipStableOnlyCapture",
            "read_fingerprint = fingerprint",
            "readFingerprint = fingerprint",
        ]

        for source in sources:
            text = source.read_text(encoding="utf-8")
            for token in forbidden:
                with self.subTest(source=source.name, token=token):
                    self.assertNotIn(token, text)

    def test_capture_failure_skips_render_to_preserve_checklists(self) -> None:
        text = (PROJECT_DIR / "src" / "js" / "sync_klms_notes.js").read_text(
            encoding="utf-8"
        )

        self.assertIn("capture-failed-preserve-user-state", text)
        self.assertIn("throw new Error(renderWarningText)", text)

    def test_archive_capture_cannot_create_read_state(self) -> None:
        text = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("displayMode == .primary && readChecked", text)
        self.assertIn("displayMode == .archive && readChecked", text)
        self.assertIn("plaintextHash(for: currentText) != expectedPlaintextHash", text)

    def test_large_notice_render_uses_rich_paste_and_optional_format_menu_styles(self) -> None:
        renderer = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")
        support = (
            PROJECT_DIR / "src" / "swift" / "notice_native_note_support.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("html: html, attributedText: attributed", renderer)
        self.assertIn("font-size:\\(cssFontSize(line.fontSize))pt", renderer)
        self.assertIn("NSFont.boldSystemFont(ofSize: line.fontSize)", renderer)
        self.assertIn("uiStyleMenuFormattingEnabled", renderer)
        self.assertIn('NOTICE_NATIVE_ENABLE_UI_STYLE_FORMAT', support)
        self.assertIn('NOTICE_NATIVE_DISABLE_UI_STYLE_FORMAT', support)
        self.assertNotIn('NOTICE_NATIVE_ENABLE_UI_STYLE_FALLBACK"] == "1"', renderer)
        self.assertIn('menuItems: ["제목", "Title"]', renderer)
        self.assertIn('menuItems: ["머리말", "Heading"]', renderer)
        self.assertIn('menuItems: ["부머리말", "Subheading"]', renderer)
        self.assertIn("reason=rich_paste_default", renderer)
        self.assertIn("readability_validation_targets_finish", renderer)

    def test_notice_render_batches_adjacent_checklist_lines(self) -> None:
        renderer = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")
        support = (
            PROJECT_DIR / "src" / "swift" / "notice_native_note_support.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("batchChecklistFormattingEnabled", support)
        self.assertIn("NOTICE_NATIVE_DISABLE_BATCH_CHECKLIST_FORMAT", support)
        self.assertIn("styleVersion = \"style_version\"", support)
        self.assertIn("checklistPairSelectionRange", renderer)
        self.assertIn("checklist_format_batch_start", renderer)
        self.assertIn("fallbackRanges.append(resolved.readRange)", renderer)
        self.assertIn("styleVersion: nativeNoticeRenderStyleVersion", renderer)

    def test_archive_empty_state_uses_guidance_copy(self) -> None:
        renderer = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")
        support = (
            PROJECT_DIR / "src" / "swift" / "notice_native_note_support.swift"
        ).read_text(encoding="utf-8")

        self.assertNotIn("확인한 공지가 없어.", renderer)
        self.assertNotIn("표시할 공지가 없습니다.", renderer)
        self.assertIn("noticeArchiveEmptyGuidanceLine", renderer)
        self.assertIn(
            '\\"읽음\\"만 체크한 공지는 다음 동기화 때 KLMS 확인한 공지에 표시됩니다.',
            support,
        )
        self.assertIn(
            '\\"중요\\"를 체크한 공지는 다음 동기화 때 KLMS 공지 상단의 중요 공지에 표시됩니다.',
            support,
        )
        self.assertIn("새 글/수정 글은 새로운 공지에", support)

    def test_notice_render_assigns_readability_font_hierarchy(self) -> None:
        support = (
            PROJECT_DIR / "src" / "swift" / "notice_native_note_support.swift"
        ).read_text(encoding="utf-8")
        renderer = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")

        for token in [
            "noticeDocumentTitleFontSize",
            "noticeSectionHeadingFontSize",
            "noticeCourseHeadingFontSize",
            "noticeItemTitleFontSize",
            "noticeMetaFontSize",
        ]:
            with self.subTest(token=token):
                self.assertIn(token, support)
                self.assertIn(token, renderer)

        self.assertIn(
            "appendLine(noteTitle, bold: true, fontSize: noticeDocumentTitleFontSize)",
            renderer,
        )
        self.assertIn(
            "appendLine(finalTitle, bold: true, fontSize: noticeItemTitleFontSize)",
            renderer,
        )
        self.assertIn("cssFontSize(line.fontSize)", renderer)
        self.assertIn("let noticeBodyFontSize: CGFloat = 14", support)
        self.assertIn("line-height:1.42", renderer)

    def test_notice_format_menu_does_not_toggle_bold_off(self) -> None:
        renderer = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("func missingBoldTargets", renderer)
        self.assertIn("func reinforceMissingBoldTargetsIfNeeded", renderer)
        self.assertIn("func boldBlockTextsContain", renderer)
        self.assertIn("func currentLineRange", renderer)
        self.assertIn('replacingOccurrences(of: "&amp", with: "&")', renderer)
        self.assertIn("bold_reinforce_start", renderer)
        self.assertIn("bold_reinforce_finish", renderer)
        self.assertIn("font-weight\\s*:\\s*(?:bold|bolder|[6-9]00)", renderer)
        self.assertNotIn("applyBold(summaryRange)", renderer)
        self.assertNotIn("applyBold(meta)", renderer)
        self.assertNotIn("applyBold(attachmentHeading)", renderer)

    def test_notice_layout_skips_empty_sections_and_compacts_body_noise(self) -> None:
        renderer = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("func appendPrimarySection", renderer)
        self.assertIn("guard count > 0 else", renderer)
        self.assertIn("noticePrimaryEmptyGuidanceLine", renderer)
        self.assertIn("(?im)^\\s*-{20,}\\s*$", renderer)
        self.assertIn("Original\\s+due|New\\s+due|Original|New|Due", renderer)
        self.assertIn("(?=#{1,6}\\s+)", renderer)
        self.assertIn('"  위치: \\(displayPath)"', renderer)

    def test_notice_header_includes_check_guidance(self) -> None:
        renderer = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("func appendNoticeGuidanceBlock", renderer)
        self.assertIn('appendLine("체크 안내"', renderer)
        self.assertIn("appendLine(noticeReadGuidanceLine", renderer)
        self.assertIn("appendLine(noticeImportantGuidanceLine", renderer)
        self.assertIn("appendLine(noticeFreshGuidanceLine", renderer)
        self.assertIn("appendNoticeGuidanceBlock(includeFreshGuidance: true)", renderer)
        self.assertIn("appendNoticeGuidanceBlock(includeFreshGuidance: false)", renderer)

    def test_notice_style_version_is_shared_between_swift_and_js(self) -> None:
        support = (
            PROJECT_DIR / "src" / "swift" / "notice_native_note_support.swift"
        ).read_text(encoding="utf-8")
        js = (PROJECT_DIR / "src" / "js" / "sync_klms_notes.js").read_text(
            encoding="utf-8"
        )

        swift_match = re.search(r'nativeNoticeRenderStyleVersion = "([^"]+)"', support)
        js_match = re.search(r'NATIVE_NOTICE_RENDER_STYLE_VERSION = "([^"]+)"', js)
        self.assertIsNotNone(swift_match)
        self.assertIsNotNone(js_match)
        self.assertEqual(swift_match.group(1), js_match.group(1))

    def test_swift_process_capture_does_not_pipe_large_outputs(self) -> None:
        text = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")
        run_process = text[
            text.index("func runProcessResult") : text.index(
                "func runProcessOutput", text.index("func runProcessResult")
            )
        ]

        self.assertIn("FileManager.default.temporaryDirectory", run_process)
        self.assertIn("FileHandle(forWritingTo:", run_process)
        self.assertNotIn("Pipe()", run_process)
        self.assertNotIn("readDataToEndOfFile", run_process)

    def test_stable_noop_verifies_notice_readability_format(self) -> None:
        text = (PROJECT_DIR / "src" / "js" / "sync_klms_notes.js").read_text(
            encoding="utf-8"
        )

        stable_noop_index = text.index("stable-noop-after-capture")
        verify_index = text.index("verifyNoticeNativeNoteReadableFormat")
        self.assertLess(verify_index, stable_noop_index)
        self.assertIn("readability-format-check-failed", text)
        self.assertIn("Native notice note readability format missing", text)
        self.assertIn("noteReadableStyleMetricsViaAppleScript", text)
        self.assertIn("font_size_tags", text)
        self.assertIn("heading_tags", text)
        self.assertIn("large_font_tags", text)
        self.assertIn("minimumLargeFontTags", text)
        self.assertIn('targetKey === "primary" ? 20 : 1', text)
        self.assertIn("NATIVE_NOTICE_RENDER_STYLE_VERSION", text)
        self.assertIn("noticeRenderStyleVersion", text)
        self.assertIn("style_version", text)
        self.assertNotIn("return body of note", text)


if __name__ == "__main__":
    unittest.main()
