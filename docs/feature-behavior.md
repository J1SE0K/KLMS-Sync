# Feature Behavior

## 공지 메모

`NOTICE_SUMMARY_ENABLED=1`이면 `sync_klms_notice.sh` 또는 `sync_klms_all.sh` 실행 시 Notice 게시판의 새 글/수정 글을 article 단위로 읽어 `runtime/cache/notice_digest.json`과 render state를 갱신한다.

사용자에게 보이는 Notes 메모는 두 개다.

| 메모 | 내용 |
| --- | --- |
| `KLMS 공지` | 중요 공지, 새로운 공지, 읽지 않은 공지 |
| `KLMS 확인한 공지` | `읽음`이면서 `중요`가 아닌 공지 |

정렬과 체크 정책:

- 메인 메모는 `중요 공지 -> 새로운 공지 -> 읽지 않은 공지` 순서로 보인다.
- 과목 heading과 공지 제목은 접히는 Notes heading 구조로 렌더된다.
- 각 공지 아래에는 네이티브 체크리스트 `읽음`, `중요` 두 줄이 붙는다.
- `읽음`과 `중요`는 서로 독립적으로 유지된다.
- 사용자가 Notes에서 직접 체크한 항목만 다음 sync 때 상태로 저장된다.
- `읽음`을 체크하면 다음 sync 때 해당 공지는 보관 메모로 이동한다.
- `중요`를 체크하면 메인 메모의 `중요 공지` 섹션으로 올라간다.
- fingerprint가 바뀐 공지는 다시 미확인으로 돌아온다.
- 체크 상태 캡처에 실패하면 기존 상태 보호를 위해 공지 메모를 덮어쓰지 않고 sync를 실패시킨다.

가독성/성능 정책:

- 빈 상태에서는 해당 메모와 관련된 안내만 짧게 표시한다.
- 굵기와 글자 크기는 HTML/RTF rich paste를 우선 사용한다.
- 느린 Notes Format 메뉴 반복 적용은 기본적으로 끈다.
- `NOTICE_NATIVE_ENABLE_UI_STYLE_FORMAT=1`이면 native 제목/머리말 메뉴 스타일을 강제로 다시 적용한다.
- 형식 적용 후 굵게가 빠진 줄만 확인해서 보강한다.
- 체크리스트는 공지별 `읽음`/`중요` 두 줄을 batch 변환한다. `NOTICE_NATIVE_DISABLE_BATCH_CHECKLIST_FORMAT=1`이면 기존 개별 변환으로 되돌린다.
- render 뒤 note 전체 validator를 돌려 stray checklist나 문단 오염을 검사한다.

## 파일 정리

`refresh_course_files.sh`는 첨부파일 manifest를 만든 뒤 `course_files`와 `~/Downloads/KLMS Files`를 같은 manifest 기준으로 맞춘다.

기본 구조:

```text
<과목>/<bucket>/<source title>/<filename>
```

예:

```text
Example Course/resources/1주차/Week 1 Notes.pdf
```

`FILE_WEEKLY_FOLDERS_ENABLED=0`이면 source title 폴더를 생략한다.

```text
Example Course/resources/Week 1 Notes.pdf
```

정리 정책:

- 파일명은 가능하면 KLMS가 실제로 내려준 다운로드 파일명을 그대로 유지한다.
- 같은 bucket 안에서 파일명이 겹치면 `filename (2).pdf`처럼 suffix를 붙인다.
- 게시판 글의 본문 인라인 이미지/미디어는 제외하고, 실제 첨부파일 목록의 문서/압축파일/스프레드시트 등을 manifest에 넣는다.
- 새 파일은 먼저 `~/Downloads/KLMS Files` 아래에 확보하고, 과목별 정리본에는 별도 복사본을 만든다.
- 현재 정리본, Downloads mirror, 이전 다운로드 로그가 가리키는 예전 경로를 먼저 재사용한다.
- 세 위치에 없을 때만 Safari를 열어 실제 다운로드를 시도한다.
- 실행이 끝나면 `course_files`와 `~/Downloads/KLMS Files` 모두 manifest 기준으로 prune한다.
- archive prune 결과는 `runtime/cache/course_file_archive_prune_result.json`에 남긴다.
- manifest가 비정상적으로 줄어든 상태에서는 바로 prune하지 않고 full rebuild를 한 번 재시도한다.
- 기존 파일이 있어도 전부 다시 받으려면 `FILE_FORCE_DOWNLOAD=1`을 설정한다.

## Reminders

`REMINDERS_SYNC_ENABLED=1`이면 `KLMS 과제` 목록을 갱신한다.

- 과제마다 리마인더 1개를 만들고 제목은 `[과목] 과제명` 형식으로 정리한다.
- 마감 시각은 리마인더의 `due date`에 반영된다.
- 승인된 시험 일정은 Reminders로 보내지 않고 Calendar로만 보낸다.
- KLMS 공지에서 잡힌 과제성 공지는 일반 과제로 승격해서 과제 목록/Reminders에 넣는다.
- 이미 지난 마감은 자동 완료 처리해서 다시 띄우지 않는다.
- 사용자가 직접 완료 체크한 리마인더는 그대로 유지한 채 내용만 최신화한다.
- iPhone과 MacBook 양쪽 알림은 iCloud Reminders의 기본 `due date` 알림을 사용한다.

단계 알림:

- `REMINDER_STAGE_ALERTS_ENABLED=1`이면 `REMINDER_ALERT_LIST_NAME` 목록에 `1일 전 / 2시간 전` 단계 알림용 리마인더를 만든다.
- Apple Reminders 한 항목에는 여러 알림 시점을 넣을 수 없어서 단계 알림은 별도 항목으로 구현한다.
- `REMINDER_RECREATE_STAGE_ALERT_LIST=1`이면 목록을 재생성해서 비교 시간을 줄인다.
- `REMINDER_DEVICE_ALERTS_ENABLED=1`은 표시 시각을 앞당겨 보이게 만들 수 있어 기본값은 `0`이다.

## Calendar

시험/헬프데스크 일정은 통합 Swift calendar pass 한 번으로 처리한다.

- 시험은 `EXAM_CALENDAR_SYNC_ENABLED=1`일 때 `EXAM_CALENDAR_NAME` 캘린더에 `[KLMS 시험]`으로 들어간다.
- 헬프데스크는 `HELP_DESK_CALENDAR_SYNC_ENABLED=1`일 때 `HELP_DESK_CALENDAR_NAME` 캘린더에 `[KLMS 헬프데스크]`로 들어간다.
- 기본 캘린더 이름 추천값은 시험 `시험`, 헬프데스크 `기타`다.
- `Nano Quiz` 같은 일반 퀴즈는 시험 캘린더로 보내지 않는다.
- 승인된 시험 일정만 캘린더에 들어간다.
- KLMS에서 날짜만 확인되고 과목별 수업 시간이 있으면 시험 시간은 수업 시간으로 잡는다.
- 기간만 있는 항목은 마지막 날 `23:59` 마감으로 해석한다.
- 시험 장소는 Calendar 이벤트의 `location` 필드에 넣는다.
- 시험 범위는 Calendar 메모에 1-4줄 정도로 요약하고, 원문은 `메모:` 아래에 남긴다.
- 범위가 애매하면 `시험 범위: 확인 필요 - 원문 참고`로 표시한다.

캘린더 정리만 필요할 때:

```sh
swift ./src/swift/sync_klms_calendar.swift --clear "시험"
swift ./src/swift/sync_klms_calendar.swift --delete-calendar "시험"
```

## Notes 과제 메모

`NOTES_SYNC_ENABLED=1`일 때만 과제 노트를 갱신한다. 기본값은 꺼져 있다.

- 전용 노트 `KLMS 과제 업데이트`를 사용한다.
- 기존 노트 내용은 유지하고 맨 위 첫 번째 목록만 KLMS 기준으로 갱신한다.
- 전용 노트가 없으면 Notes 폴더에 자동 생성한다.
- `남은 시간`처럼 매 실행마다 바뀌는 값은 제외해서 실제 과제 내용이 바뀔 때만 메모를 갱신한다.

## 완료와 수동 Override

KLMS 과제 상세의 `제출 상태`가 완료로 보이면 과제 목록과 Reminders 동기화에서 제외한다.

사용자가 Apple Reminders의 `KLMS 과제` 또는 `KLMS 확인 필요` 목록에서 과제를 완료 체크하면 다음 동기화 때 해당 과제 URL이 수동 `completed` override로 저장되고 이후 다시 나타나지 않는다.

예외 과제는 `manual_assignment_overrides.json`로 처리한다. 형식은 [manual_assignment_overrides.example.json](../examples/manual_assignment_overrides.example.json)을 참고한다.

- `assignments` 아래 값이 `completed`이면 수동 완료 처리한다.
- `assignments` 아래 값이 `ignored`이면 완전히 무시한다.
- `exams` 아래에는 시험 공지 URL이나 `URL::시험명` 키로 수동 시험 시간 override를 넣을 수 있다.
- `status: approved`가 있는 시험만 실제 캘린더에 반영된다.
- `sync_start`, `sync_due`, `due`, `location`, `coverage`, `coverage_summary`를 지정할 수 있다.
- `class_times` 아래에는 과목별 기본 수업 시간을 넣을 수 있다.

LaunchAgent 설치본과 작업 폴더가 다른 경로를 써도 같은 override 파일을 보게 하려면 `OVERRIDES_JSON_PATH`를 절대 경로로 지정한다.
