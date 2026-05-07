# KAIST KLMS 작업 도구

이 폴더는 Safari에 로그인된 KAIST KLMS 세션을 재사용해서 세 가지 작업을 분리해서 수행한다.

1. `KLMS 동기화`: 과제/시험 상태를 읽어 Reminders, Calendar, 과제 메모를 갱신
2. `공지 정리`: `Notice` 게시판 글을 요약해서 `KLMS 공지` 메모를 갱신
3. `파일 정리`: 첨부파일을 과목별 폴더로 수집하고 정리

현재 구조는 Safari 기반 증분 수집과 quick sync를 기준으로 맞춰져 있고, Chromium/Playwright 경로는 제거했다. 기본 동작은 `최소 탐색`을 우선해서, 캐시가 있는 상세/중간 페이지는 가능한 한 재사용하고 목록 페이지나 실제로 변동이 의심되는 URL만 다시 읽는다. 세 기능은 캐시를 공유할 수는 있지만 실행 entrypoint는 서로 독립적이다.

## 공개/보안 주의

이 프로젝트는 KAIST 또는 KLMS의 공식 도구가 아니다. 개인 Safari 세션, macOS 자동화 권한, Apple Reminders/Calendar/Notes 권한을 사용하므로 본인 계정에서만 실행해야 한다.

퍼블릭 레포에는 `config.env`, `manual_assignment_overrides.json`, `kaikey_state.json`, `runtime/`, `course_files/`, QR 스크린샷, 쿠키, 다운로드 파일을 올리지 않는다. 이 레포에는 예시 설정과 코드만 보관하고, 실제 인증 상태와 수업 데이터는 `.gitignore` 대상 또는 `~/Library/Application Support/KLMSNotesSync` 아래에 둔다.

Kaikey 자동 인증을 켜면 Mac에 저장되는 기기키가 사실상 KAIST MFA 등록 기기 역할을 한다. `kaikey_state.json`이 유출되었거나 공개 커밋에 들어갔다고 의심되면 즉시 KAIST 인증 기기 등록을 해제/재등록하고, 기존 state 파일은 폐기한다. iPhone에서 Mac 승인을 호출할 때도 공개 HTTP endpoint를 만들지 말고 SSH, 로컬 네트워크, VPN처럼 접근 제어가 있는 경로만 사용한다.

## 구성

루트에는 사용자가 직접 실행하는 entrypoint만 둔다.

- `sync_klms_core.sh`: 사용자용 `KLMS 동기화` entrypoint. 과제/시험/Reminders/Calendar/과제 메모를 갱신
- `sync_klms_notice.sh`: 사용자용 `공지 정리` entrypoint. `KLMS 공지` 메모만 갱신
- `refresh_course_files.sh`: 첨부파일 manifest 생성, 다운로드, prune을 담당하는 `파일 정리` entrypoint
- `run_all.sh`: `KLMS 동기화 + 공지 정리`만 안정성 우선으로 직렬 실행하는 기본 entrypoint
- `run_all_full.sh`: `KLMS 동기화 + 공지 정리 + 파일 정리`를 안정성 우선으로 직렬 실행하는 full entrypoint
- `run_all_parallel.sh`: 같은 세 작업을 로그인 preflight 뒤 병렬 실행하는 수동 실험용 entrypoint
- `sync_klms_all.sh`: generic sync wrapper. 대화형 실행에서는 어떤 동기화를 원하는지 먼저 물어보고, 비대화 실행에서는 기존처럼 기본 `run_all.sh`로 떨어진다
- `kaikey_setup.sh`, `kaikey_auto_login.sh`, `kaikey_approve_number.sh`: Kaikey 등록/자동 로그인/숫자 승인 helper
- `install_launch_agent.sh`: 자동 실행용 LaunchAgent 설치
- `verify_sync_state.sh`: 공지 렌더 누락, 파일 manifest 누락, 캘린더 개수까지 한 번에 점검하는 검증 스크립트

내부 구현은 기능과 언어별로 분리한다.

- `src/sh/`: 공통 shell helper, launchd worker, tmp cleanup, native Notes renderer wrapper
- `src/js/`: Safari/JXA 자동화, Reminders/Notes 동기화 runner, Kaikey protocol CLI
- `src/python/`: KLMS HTML 파서, 증분 fetch backend, 파일 manifest/prune 도구
- `src/swift/`: Calendar 동기화, QR decode, native Notes renderer
- `examples/`: 공개 가능한 예시 설정 파일
- `docs/`: 공개 배포 체크리스트 등 보조 문서
- `legacy/`: 호환 wrapper와 수동 디버깅용 보조 스크립트

## 준비

1. `examples/config.env.example`를 `config.env`로 복사한다.
2. Safari에서 `https://klms.kaist.ac.kr/my/`에 로그인되어 있어야 한다.
3. 첫 실행 때 macOS가 Safari / Reminders / Calendar 자동화 권한을 물으면 허용한다.

## 실행

### 1. KLMS 동기화

```sh
cd klms-notes-sync
./sync_klms_core.sh
```

정상 동작하면 기본적으로 Apple Reminders의 `KLMS 과제` 목록이 갱신되고, 승인된 시험/헬프데스크 일정은 각각 설정한 Apple Calendar 캘린더로 반영된다. 현재 설정 예시는 iCloud Reminders를 이용한 양 기기 알림과 `시험`/`기타` 캘린더 동기화를 함께 쓰는 구성을 기본값으로 둔다.

### 2. 파일 정리

```sh
cd klms-notes-sync
./refresh_course_files.sh
```

### 3. 공지 정리

```sh
cd klms-notes-sync
./sync_klms_notice.sh
```

기본 전체 동기화는 `KLMS 동기화 + 공지 정리`만 순서대로 돈다.

```sh
cd klms-notes-sync
./run_all.sh
```

generic entrypoint가 필요하면 아래 wrapper를 써도 된다. 터미널에서 직접 실행하면 먼저 어떤 동기화를 원하는지 묻고, launchd 같은 비대화 실행에서는 기본값으로 `run_all.sh`를 호출한다.

```sh
cd klms-notes-sync
./sync_klms_all.sh
```

idle 자동 실행(`launch_sync_if_idle.sh`)도 기본적으로 이 `run_all.sh`를 호출한다. 즉 평소 자동 동기화는 `core + notice`까지만 처리하고, 파일 정리는 `run_all_full.sh`나 `refresh_course_files.sh`를 명시적으로 실행할 때만 돈다.

파일까지 포함한 3단계 full sync가 필요하면 아래 스크립트를 쓴다.

```sh
cd klms-notes-sync
./run_all_full.sh
```

속도가 더 중요하고 병렬 실행을 직접 선택하고 싶으면 아래 스크립트를 쓴다.

```sh
cd klms-notes-sync
./run_all_parallel.sh
```

누적된 임시 산출물을 정리하려면 아래 스크립트를 쓴다.

```sh
cd klms-notes-sync
./src/sh/cleanup_runtime_tmp.sh
```

자동 sync entrypoint(`sync_klms_core.sh`, `sync_klms_notice.sh`, `refresh_course_files.sh`, `run_all.sh`, `run_all_full.sh`)는 성공 후 `runtime/tmp`를 자동 정리한다. 기본값은 성공한 실행의 tmp를 즉시 비우는 방식이고, 실패한 실행은 디버깅을 위해 남긴다. `KLMS_RUNTIME_TMP_CLEANUP_ENABLED=0`으로 끄거나 `KLMS_RUNTIME_TMP_MAX_AGE_HOURS`로 보존 시간을 바꿀 수 있다.
각 entrypoint는 작업별 lock을 쓴다. 기본 경로는 `~/Library/Application Support/KLMSNotesSync/runtime/automation/{core,notice,files,all}.lock` 형태다. 기본 `run_all.sh`는 `all.lock`을 잡은 뒤 `core -> notice`만 직렬 실행하고, `run_all_full.sh`는 `core -> notice -> files`까지 직렬 실행한다.
병렬 수동 실행 경로인 `run_all_parallel.sh`도 같은 작업별 lock과 work cache를 쓴다. fetch/intermediate cache와 tmp는 `runtime/cache/{core,notice,files}` 및 `runtime/tmp/{core,notice,files}` 아래로 분리했고, 사용자 상태와 최종 산출물은 기존처럼 `runtime/cache/notice_*.json`, `runtime/cache/course_file_manifest.json`, `runtime/state/state.json` 같은 canonical 경로를 유지한다.

`SYNC_MODE`와 `FILE_REFRESH_MODE`는 각각 `KLMS 동기화/공지 정리`와 `파일 정리` 단계의 `quick/full/auto` 모드를 제어한다.
기본값은 `SYNC_MINIMAL_EXPLORATION_ENABLED=1`, `FILE_MINIMAL_EXPLORATION_ENABLED=1`이고, 이 상태에서는 background probe를 거의 하지 않고 `새 URL`, `stale URL`, 꼭 다시 확인해야 하는 일부 URL만 Safari로 다시 읽는다. 추가로 `FETCH_AUTO_FULL_MIN_COVERAGE=0.2`, `FETCH_AUTO_REQUIRE_LAST_FULL=0`, `FETCH_AUTO_FULL_ON_TTL_EXPIRE=0` 기본값을 써서, 캐시가 조금만 있어도 `auto`가 쉽게 `full`로 되돌아가지 않게 맞춰 두었다. 넓은 재탐색이 필요하면 `full`을 수동으로 돌리는 쪽이 기본 전략이다.
세 entrypoint는 실행 전에 공통 로그인 preflight를 거친다. 먼저 Safari의 현재 KLMS 탭을 빠르게 확인해서 로그인 페이지가 이미 떠 있으면 즉시 실패하고, 그게 아니면 이전 dashboard 캐시를 버린 뒤 새 dashboard fetch로 최종 확인한다. 직접 실행하는 entrypoint에서 로그인 실패가 감지되면 기본값으로 Safari의 기존 KLMS/portal 탭을 로그인 URL로 돌리고, 해당 탭이 없을 때만 새 탭을 만든다. 필요 없으면 `KLMS_LOGIN_OPEN_SAFARI_ON_FAILURE=0`으로 끌 수 있다. 로그인 성공 상태는 다음 실행을 통과시키는 캐시로 쓰지 않는다. `run_all.sh`, `run_all_full.sh`, `run_all_parallel.sh`의 하위 작업만 같은 실행에서 방금 확인한 dashboard를 넘겨받아 다시 검사한다. 이 fast-fail은 `KLMS_LOGIN_FAST_TAB_CHECK_ENABLED=1`로 켜진다.

`KAIKEY_LOGIN_ASSIST_ENABLED=1`이면 터미널에서 직접 실행할 때 로그인 실패 시 Safari SSO 페이지를 자동으로 진행한다. `KAIKEY_AUTO_APPROVE_ENABLED=0`이면 2FA 화면에 표시된 값을 터미널에 `KAIST 인증 번호: NN` 형태로 보여주고, 휴대폰 인증 화면에서 같은 번호를 선택할 때까지 기다린다. `KAIKEY_AUTO_APPROVE_ENABLED=1`이면 등록된 기기키로 `auth/check`를 확인한 뒤 Safari 2FA 화면에 실제로 표시된 2자리 숫자와 서버 challenge에서 파생한 숫자가 같을 때만 `auth` 승인을 보낸다.

수동 승인만 쓸 때는 아래 설정을 둔다.

```sh
KAIKEY_LOGIN_ASSIST_ENABLED="1"
KAIKEY_AUTO_LOGIN_ENABLED="0"
KAIKEY_AUTO_APPROVE_ENABLED="0"
KAIKEY_MANUAL_APPROVAL_TIMEOUT_SECONDS="300"
```

이 설정에서는 LaunchAgent 같은 비대화 자동 동기화가 로그인 보조를 실행하지 않고 기존 로그인 알림 경로로 빠진다. SSO 로그인 ID는 `KLMS_SSO_LOGIN_ID` 또는 `KAIST_SSO_LOGIN_ID`로 지정할 수 있다. 이 값이 없으면 기존 Kaikey state 파일의 identity를 재사용한다. Mac 자동 승인을 쓰려면 처음 한 번은 KAIST 2FA 등록 페이지의 QR 스크린샷으로 로컬 기기를 등록해야 한다.

```sh
cd klms-notes-sync
./kaikey_setup.sh --qr-image /path/to/qr-screenshot.png
```

등록 상태는 아래처럼 확인한다.

```sh
node ./src/js/kaikey_cli.mjs status
```

기본 기기키 저장 위치는 `~/Library/Application Support/KLMSNotesSync/kaikey_state.json`이고 권한은 `0600`으로 맞춘다. 경로를 바꾸려면 `KAIKEY_STATE_PATH`를 설정한다. launchd 설치본에서 Homebrew Node를 못 찾으면 `KAIKEY_NODE_BIN=/opt/homebrew/bin/node`처럼 지정한다.

KAIST MFA가 등록 기기 1개만 허용하는 경우에는 휴대폰 PASSNI와 Mac Kaikey를 동시에 등록 기기로 유지할 수 없다. 이때는 아래 둘 중 하나를 선택해야 한다.

1. `Mac 자동 인증기 우선`: Mac을 유일한 등록 기기로 두고 KLMS 자동 동기화를 완전 자동화한다. iPhone에서 KAIST 로그인이 필요할 때는 iOS Shortcuts의 `Run Script over SSH`로 Mac의 승인 명령만 실행한다.
2. `휴대폰 PASSNI 우선`: 휴대폰 PASSNI를 유일한 등록 기기로 유지한다. 이 경우 `KAIKEY_LOGIN_ASSIST_ENABLED=1`, `KAIKEY_AUTO_APPROVE_ENABLED=0`으로 두고, 직접 동기화할 때 Safari SSO 2자리 번호를 터미널에서 확인한 뒤 휴대폰에서 승인한다.

첫 번째 방식을 고르면 iPhone 로그인 화면에 표시된 2자리 숫자를 Shortcut에서 입력받아 아래 명령으로 넘긴다.

```sh
cd ~/Library/Application\ Support/KLMSNotesSync
./kaikey_approve_number.sh "$SHORTCUT_INPUT"
```

이 helper도 서버 challenge에서 파생한 실제 숫자와 입력 숫자가 일치할 때만 승인한다. Mac이 켜져 있고 SSH 접근이 가능해야 하며, 공개 HTTP endpoint로 노출하지 않는다.

- `full`: 대상 URL을 전부 다시 읽는다.
- `quick`: 새 URL, stale URL, 항상 확인해야 하는 URL을 우선 다시 읽고, 나머지는 각 작업별 `runtime/cache/{core,notice,files}/fetch_state.json`과 이전 JSON 결과를 재사용한다.
- `auto`: 캐시 커버리지와 마지막 full 시각을 참고해 quick 또는 full을 자동 선택한다. 최소 탐색 기본값에서는 마지막 full이 오래됐더라도 캐시가 충분하면 quick를 유지한다.

Safari 수집은 `FETCH_MIN_WAIT_SECONDS`, `FETCH_STABLE_POLLS`를 써서 DOM이 빨리 안정화되면 고정 6초를 끝까지 기다리지 않고 다음 페이지로 넘어간다.
수집 중에는 기존 KLMS Safari 창을 재사용하고, 같은 창 안의 임시 탭만 열어 페이지를 읽은 뒤 닫는다. URL마다 새 창을 만들고 닫지 않는다.
일반 sync의 course/all-week 페이지는 `SYNC_COURSE_PAGE_STALE_SECONDS`, `SYNC_ALL_WEEK_COURSE_PAGE_STALE_SECONDS` 동안 캐시를 재사용한다. supplemental crawl은 `Notice/자료/강의계획` 계열 primary와 `Q&A/Board` 계열 secondary로 나뉘며, secondary는 `SYNC_SECONDARY_SUPPLEMENTAL_QUICK_LIMIT`, `SYNC_SECONDARY_SUPPLEMENTAL_STALE_SECONDS`로 느리게 probe 한다. supplemental detail은 이전 run의 detail URL과 현재 active 시험/헬프데스크 source article을 기준으로 우선순위를 다시 정렬한 뒤, `SYNC_SUPPLEMENTAL_DETAIL_QUICK_LIMIT`, `SYNC_SUPPLEMENTAL_DETAIL_STALE_SECONDS`로 별도 조절한다. 최소 탐색 기본값에서는 이 quick limit들이 `0`에 가깝게 잡혀서 불필요한 background probe를 줄이고, `SYNC_SUPPLEMENTAL_DETAIL_INCLUDE_NON_RELEVANT_PRIMARY=0`으로 primary 공지게시판의 비관련 article detail 재수집도 기본적으로 막는다. 파일 정리 단계는 `FILE_COURSE_PAGE_STALE_SECONDS`, `FILE_ALL_WEEK_COURSE_PAGE_STALE_SECONDS`로 같은 방식을 쓴다.

시험 일정은 KLMS 대시보드에 직접 안 보여도, 각 과목의 `Notice 게시판`, `Course Material`, 강의계획서 링크를 추가로 확인해서 후보를 찾는다. `Notice` 게시판은 제목에 시험 키워드가 없어도 새 글/수정 글 본문을 다시 읽어서, 본문에만 적힌 시험 일정도 후보로 잡는다. 새 후보는 바로 `시험` 캘린더에 넣지 않고 확인 대기 상태로 남기며, 승인된 항목만 `시험 일정` 섹션과 `시험` 캘린더에 반영한다. KLMS에서 날짜만 확인되는 경우에는 시간 미상으로 표시된다.
일반 sync는 게시판/폴더의 HTML 페이지만 추가 확인하고, `pluginfile` 같은 첨부 문서 URL 자체는 따라가지 않는다. 첨부파일 다운로드는 파일 정리 단계에서만 일어난다.
`NOTICE_SUMMARY_ENABLED=1`이면 `sync_klms_notice.sh` 또는 `sync_klms_all.sh` 실행 시 `Notice` 게시판의 새 글/수정 글만 article 단위로 다시 읽어 `runtime/cache/notice_digest.json`, `runtime/cache/notice_summary_state.json`을 갱신한다. 최소 탐색 기본값에서는 공지 정리 단계가 `Notice` 게시판 경로만 우선 다시 보고, 자료실/리소스 경로는 공지 sync에서 기본적으로 따라가지 않는다. 각 과목 `Notice` 게시판은 페이지네이션까지 따라가며 누적 추적하고, `NOTICE_NOTE_NAME`과 `NOTICE_ARCHIVE_NOTE_NAME` 두 메모를 네이티브 제목/머리말/체크리스트 형식으로 갱신한다. Notes 체크 상태 캡처나 렌더 단계가 실패하면 전체 notice sync도 실패로 끝나며, 자세한 원인은 `runtime/cache/notice_note_render_warning.txt`에 남긴다. stage별 소요 시간은 `runtime/cache/{core,notice}/stage_timings.json`에서 볼 수 있다.

- 메인 메모 `KLMS 공지`는 `중요 공지 -> 새로운 공지 -> 읽지 않은 공지` 순서로 보인다.
- 보관 메모 `KLMS 확인한 공지`에는 `읽음`이면서 `중요`가 아닌 공지만 모아둔다.
- `중요 공지`, `새로운 공지`, `읽지 않은 공지`는 서로 독립적으로 접히는 상위 섹션으로 렌더된다.
- 과목 heading은 각 상위 섹션 아래에서 접히는 `머리말` 섹션으로 렌더된다.
- 각 공지 제목도 접히는 `부머리말` 섹션으로 렌더된다.
- 각 공지 아래에는 네이티브 체크리스트 `읽음`, `중요` 두 줄이 붙는다.
- `읽음`과 `중요`는 서로 독립적으로 유지된다. Notes에서 직접 체크한 항목만 다음 sync 때 다시 체크된다.
- `읽음`을 체크하면 다음 sync 때 그 공지는 보관 메모 `KLMS 확인한 공지`로 이동한다.
- `중요`를 체크하면 다음 sync 때 해당 공지는 메인 메모 상단 `중요 공지` 섹션으로 올라간다. 보관 메모에서 `중요`를 체크해도 다음 sync 때 메인 메모의 `중요 공지`로 이동한다.
- 두 메모 상단에는 `체크 안내`를 표시해서 `읽음`, `중요`, 새/수정/미확인 공지가 다음 sync 때 어느 섹션에 표시되는지 바로 확인할 수 있게 한다.
- 새로 올라온 공지나 수정된 공지는 `새로운 공지` 섹션으로 먼저 분류된다. 이미 읽지 않았지만 새/수정 상태가 아닌 공지만 `읽지 않은 공지`에 남는다.
- 같은 공지라도 fingerprint가 바뀌면 다시 미확인으로 돌아온다.
- 체크 상태를 Notes에서 읽지 못하면 공지 메모를 덮어쓰지 않고 sync를 실패로 끝낸다.
- 사용자 눈에 보이는 노트는 `KLMS 공지`, `KLMS 확인한 공지` 두 개를 유지하고, 체크 상태는 `runtime/cache/notice_user_state.json`에 저장한다.
- 네이티브 공지 메모 renderer는 Swift binary를 tmp build cache에 재사용한다. 공지 변화가 없어도 `읽음`/`중요` 체크 상태는 매번 Notes UI에서 캡처하고, 직전 render state의 `content_hash`와 새 render plan이 같을 때만 Notes 전체 재렌더를 건너뛴다.
- 공지 본문 굵기와 글자 크기는 기본적으로 HTML/RTF rich paste 한 번으로 적용하고, 느린 Notes Format 메뉴 반복 적용은 끈다. native 제목/머리말 메뉴 스타일을 강제로 다시 쓰려면 `NOTICE_NATIVE_ENABLE_UI_STYLE_FORMAT=1`을 설정한다.
- native 제목/머리말 메뉴 스타일을 켠 경우에도 `굵게` 메뉴를 무조건 다시 누르지 않고, 형식 적용 후 실제로 굵게가 빠진 줄만 확인해서 다시 보강한다.
- 공지 체크리스트는 각 공지의 `읽음`/`중요` 두 줄을 한 번에 변환한다. 문제가 있으면 실패한 줄만 개별 변환으로 fallback하고, 기존 한 줄씩 변환으로 되돌리려면 `NOTICE_NATIVE_DISABLE_BATCH_CHECKLIST_FORMAT=1`을 설정한다.
- `KLMS 확인한 공지`는 머리줄에서 변동 시각을 빼서, 실제 archive 내용이 안 바뀌면 대부분의 sync에서 다시 쓰지 않는다. 다만 체크 상태 캡처는 계속 수행한다.
- 공지 메모는 render 뒤 note 전체 validator를 돌려 stray checklist나 잘못된 문단 오염을 전수 검사한다. 양식 이상이 감지되면 보수적인 경로로 다시 렌더한다.
- 메인 공지가 많을 때는 Notes 메뉴 자동화가 과도하게 오래 걸리지 않도록 개별 제목/메타데이터 스타일링을 생략하고, 본문/체크리스트 정확성을 우선한다.

## Reminders 동작 방식

- `REMINDERS_SYNC_ENABLED=1`일 때 `KLMS 과제` 목록을 자동으로 갱신한다.
- 과제마다 리마인더 1개씩 만들고, 제목은 `[과목] 과제명` 형식으로 정리한다.
- 마감 시각은 리마인더의 `due date`에 반영된다.
- 승인된 시험 일정은 Reminders로 보내지 않고, `EXAM_CALENDAR_SYNC_ENABLED=1`일 때 `시험` 같은 별도 캘린더로만 동기화한다.
- 시험/헬프데스크 일정은 날짜가 지나도 캘린더에서 바로 제거하지 않는다.
- KLMS 공지에서 잡힌 과제성 공지는 공지 링크를 가진 일반 과제로 승격해서 과제 목록/Reminders에 넣고, 이미 지난 마감은 자동 완료 처리해서 다시 띄우지 않는다.
- core sync는 현재 실행에서 다시 읽은 supplemental article뿐 아니라 기존 `runtime/cache/notice_digest.json`도 재사용해서 과거 공지 기반 후보를 backfill한다.
- 새 시험 후보도 Reminders에는 올리지 않고, 사용자가 승인하기 전까지는 `시험` 캘린더에 들어가지 않는다. `Nano Quiz`, `Homework/Grading/Solution` 류 공지는 시험 후보에서 제외한다.
- `sync_klms_core.sh` 같은 core 결과 문자열에도 `exam_candidates=<n>`, `assignment_candidates=<n>`이 같이 찍혀서 마지막 실행 요약에서 확인 대기 후보 수를 바로 볼 수 있다.
- `Help Desk` 공지는 시험 후보로 넣지 않고, 시간 정보가 있으면 `HELP_DESK_CALENDAR_SYNC_ENABLED=1`일 때 `기타` 같은 일반 캘린더에 `[KLMS 헬프데스크]` 일정으로 넣는다.
- iPhone과 MacBook 양쪽 알림은 iCloud Reminders의 기본 `due date` 알림을 사용한다. 따라서 `KLMS 과제` 목록이 iCloud 계정 아래에 있어야 한다.
- `REMINDER_STAGE_ALERTS_ENABLED=1`이면 별도 iCloud 목록 `REMINDER_ALERT_LIST_NAME`에 `1일 전 / 2시간 전` 단계 알림용 리마인더를 자동으로 만든다. Apple Reminders 한 항목에는 여러 알림 시점을 넣을 수 없어서, 이 단계 알림은 별도 리마인더 항목으로 구현한다.
- `REMINDER_DEVICE_ALERTS_ENABLED=1`은 별도 `remind me date`를 강제로 넣는 옵션인데, Reminders 표시 시각을 앞당겨 보이게 만들 수 있어서 기본값은 `0`으로 둔다.
- 리마인더 본문에는 `과목 / 마감 / 해야 할 일 / KLMS 링크`가 들어간다.
- 확인 대기 후보는 Reminders에 만들지 않고, core 결과와 state를 통해서만 확인한다. 공지 기반 과제는 별도 후보로 남기지 않는다.
- KLMS에서 사라지거나 이미 지난 과제는 전용 리마인더 목록에서 자동 정리된다.
- 사용자가 직접 완료 체크한 리마인더는 그대로 유지한 채 내용만 최신화한다.
- 단계 알림용 `KLMS 알림` 목록의 항목은 알림 시각 자체를 `due date`와 `remind me date`로 함께 가진다. 원래 마감 시각은 본문에 적어둔다.
- 맥 전용 다단계 알림은 `MACOS_REMINDER_NOTIFICATIONS_ENABLED=1`일 때만 launchd가 `1일 전 / 2시간 전` 단계로 추가 표시한다. 기본값은 `0`이다.

## 완료 처리

- KLMS 과제 상세의 `제출 상태`가 `제출되었습니다`, `채점을 위해 제출되었습니다`, `제출 완료`, `채점 완료`처럼 완료로 보이면 과제 목록과 리마인더 동기화에서 자동으로 제외한다.
- 사용자가 Apple Reminders의 `KLMS 과제` 또는 `KLMS 확인 필요` 목록에서 과제를 직접 완료 체크하면, 다음 동기화 때 해당 과제 URL이 수동 override `completed`로 저장되고 이후 과제 목록에 다시 나타나지 않는다.
- 완료 체크되었거나 KLMS에서 완료 처리된 과제의 리마인더와 단계 알림은 다음 동기화에서 바로 삭제한다.
- `COMPLETED_REMINDER_RETENTION_DAYS`는 기본값 `0`이며, 과제 외의 완료 리마인더를 따로 보존하고 싶을 때만 쓴다.
- KLMS에 제출 완료가 안 찍히는 예외 과제는 `manual_assignment_overrides.json`의 `assignments` 아래에 과제 URL을 키로 넣고 값을 `completed`로 두면 수동으로 숨길 수 있다. 파일 형식은 [examples/manual_assignment_overrides.example.json](./examples/manual_assignment_overrides.example.json)을 참고한다.
- 완전히 무시만 하고 싶으면 같은 파일에서 값을 `ignored`로 두면 된다.
- 같은 파일의 `exams` 아래에는 시험 공지 URL이나 `URL::시험명` 키로 수동 시험 시간 override를 넣을 수 있다. `status: approved`를 둔 항목만 실제 시험 일정으로 반영되고, `sync_start`, `sync_due`, `due`를 함께 넣으면 캘린더도 명시된 시작/종료 시각으로 생성된다.
- LaunchAgent 설치본과 작업 폴더가 다른 경로를 써도 같은 override 파일을 보게 하려면 `config.env`의 `OVERRIDES_JSON_PATH`를 절대 경로로 지정하면 된다.

## 다운로드 정리 안전장치

- 문서 스캔 때문에 `~/Downloads`를 잠깐 사용할 때는 다운로드 목록 manifest를 먼저 만든 뒤 [src/js/cleanup_tracked_downloads.js](./src/js/cleanup_tracked_downloads.js)로 정리한다.
- 이 스크립트는 manifest에 적힌 파일명만 대상으로 삼고, `~/Downloads` 전체를 비우거나 manifest 밖의 파일을 지우지 않는다.
- 자동 삭제는 하지 않는다. 다운로드 후 남겨둔 사본은 사용자가 cleanup 명령을 직접 실행할 때만 지운다.
- 실행 예시는 `osascript -l JavaScript ./src/js/cleanup_tracked_downloads.js --manifest=./runtime/tmp/file_scan_manifest.json` 형태다.

## 과목별 파일 정리

- 현재 수강 강좌의 첨부파일을 과목별 폴더로 모으려면 내부적으로 `src/python/build_course_file_manifest.py`로 manifest를 만들고 `src/js/download_klms_files.js`로 내려받는다.
- 생성된 file manifest와 download log에는 KLMS 화면에서 읽은 기준 시각(`klms_timestamp*`)과 로컬에 확보한 시각(`local_downloaded_*`)을 함께 저장한다.
- 파일 정리 단계는 `course_files` 정리본과 `~/Downloads/KLMS Files` 보관 사본의 파일 수정 시각(`mtime`)도 가능하면 같은 KLMS 기준 시각으로 맞춘다. 그래서 Finder/정렬 기준이 로그와 더 일관되게 보인다.
- 파일명은 가능하면 KLMS가 실제로 내려준 다운로드 파일명을 그대로 유지하고, 이후 manifest/state도 그 이름으로 맞춘다.
- `sync_klms_core.sh`와 `sync_klms_notice.sh`는 첨부파일 다운로드를 호출하지 않는다. 파일 다운로드는 `refresh_course_files.sh` 같은 파일 정리 단계에서만 일어난다.
- 기본 정리 위치 예시는 `./course_files`다.
- 기본 정리 구조는 `<과목>/<bucket>/<source title>/<filename>` 형태다. 예: `Example Course/resources/1주차/Week 1 Notes.pdf`
- `FILE_WEEKLY_FOLDERS_ENABLED=0`으로 두면 주차/source title 폴더를 생략해서 `<과목>/<bucket>/<filename>` 형태로 정리한다. 예: `Example Course/resources/Week 1 Notes.pdf`
- 같은 bucket 안에서 파일명이 겹치면 `filename (2).pdf`처럼 suffix를 붙여 충돌을 피한다.
- `<filename>`은 실제 다운로드된 원본 파일명을 그대로 사용한다(임의 리네임 없음).
- 게시판 글의 본문에 인라인으로 삽입된 이미지/미디어는 수집 대상에서 제외하고, 실제 첨부파일 목록에 올라온 문서/압축파일/스프레드시트 같은 파일만 manifest에 넣는다.
- 이번 실행에서 새로 받은 파일은 먼저 `~/Downloads/KLMS Files` 아래의 같은 정리 구조로 내려받고, 과목별 폴더에는 별도 복사본을 만든다.
- 파일 정리 스크립트는 먼저 현재 정리본, `~/Downloads/KLMS Files`, 이전 다운로드 로그가 가리키는 예전 경로를 재사용한다. 이 셋에 파일이 없을 때만 Safari를 열어 실제 다운로드를 시도한다.
- 파일 정리 실행이 끝나면 `course_files`와 `~/Downloads/KLMS Files`를 같은 manifest 기준으로 prune해서 예전 경로, 중복 경로, 빈 폴더를 제거한다.
- archive prune 결과는 `runtime/cache/course_file_archive_prune_result.json`에 남긴다.
- `FILE_REFRESH_MODE=quick` 또는 `auto`를 쓰면 seed/nested HTML 수집도 증분 캐시를 사용한다.
- 기본값인 `FILE_MINIMAL_EXPLORATION_ENABLED=1`에서는 `FILE_*_QUICK_LIMIT`와 background probe가 거의 `0`으로 잡혀서, 새로 발견된 URL이나 stale URL이 아니면 Safari 재탐색을 최대한 줄인다.
- 추가로 `FILE_PRIMARY_BOARD_ALWAYS_FETCH_ONLY=1` 기본값에서는 seed 단계의 always-fetch 대상을 primary 게시판 1페이지와 `assign/resource` index 페이지로 좁힌다. nested page2/page3는 기본적으로 stale/new일 때만 다시 읽는다.
- linked HTML index는 source page fingerprint를 같이 저장해서, fetch summary가 비어 있거나 넓게 잡혀도 HTML 본문이 안 바뀐 source page는 다시 파싱하지 않는다.
- nested HTML은 새로 발견된 URL을 우선 다시 읽고, 필요하면 `FILE_NESTED_BACKGROUND_QUICK_LIMIT`, `FILE_NESTED2_BACKGROUND_QUICK_LIMIT`를 올려 기존 URL background probe를 다시 늘릴 수 있다.
- 로그인 만료로 dashboard가 SSO 페이지를 돌려주면 file refresh는 바로 중단된다.
- generated manifest가 기존 정리본보다 비정상적으로 줄어들거나 비었는데 기존 정리 파일이 남아 있으면, file refresh는 먼저 한 번 full rebuild를 다시 시도한 뒤에만 prune 단계로 넘어간다.
- 기존 파일이 있어도 KLMS에서 전부 다시 받으려면 `refresh_course_files.sh` 실행 시 `FILE_FORCE_DOWNLOAD=1`을 설정한다.
- 과목별 다운로드 뒤 `~/Downloads`의 추적 파일을 전부 정리하려면 `osascript -l JavaScript ./src/js/cleanup_tracked_downloads.js --manifest=./runtime/cache/course_file_download_log.json`처럼 직접 실행한다.
- 새로 받은 파일만 남기고 싶으면 `osascript -l JavaScript ./src/js/cleanup_tracked_downloads.js --manifest=./runtime/cache/course_file_download_log.json --keep-fresh-downloads`를 쓰거나, 자동 파일 동기화 기본값인 `FILE_KEEP_FRESH_DOWNLOADS=1`을 유지한다.

## 메모 동작 방식

- `NOTES_SYNC_ENABLED=1`일 때만 노트를 갱신한다.
- 기본값은 꺼져 있고, 켜면 기존 수기 메모와 분리된 전용 노트 `KLMS 과제 업데이트`를 사용하는 방식이다.
- 노트를 사용할 경우 기존 노트 내용은 유지하고, 맨 위 첫 번째 목록만 KLMS 기준으로 갱신한다.
- `과제` 노트처럼 상단에 과제 목록이 있고 그 아래에 다른 메모 섹션이 이어지는 구조를 기준으로 맞춰져 있다.
- 전용 노트가 아직 없으면 `Notes` 폴더에 자동 생성한 뒤 그 안의 과제 목록만 계속 갱신한다.
- 시험 캘린더는 `EXAM_CALENDAR_SYNC_ENABLED=1`일 때 `EXAM_CALENDAR_NAME`에 지정한 별도 캘린더를 사용한다. 현재 추천값은 `시험`이다.
- 헬프데스크 일정은 `HELP_DESK_CALENDAR_SYNC_ENABLED=1`일 때 `HELP_DESK_CALENDAR_NAME`에 지정한 캘린더를 사용한다. 현재 추천값은 `기타`다.
- 과거 시험/헬프데스크를 얼마나 오래 추적할지는 `CALENDAR_LOOKBACK_DAYS`로 조절한다. 기본값은 `365`일이다.
- `KLMS 동기화`는 필요한 캘린더들을 개별 Swift 프로세스로 여러 번 띄우지 않고, 통합 calendar pass 한 번으로 처리한다.
- `Nano Quiz` 같은 일반 퀴즈는 시험 캘린더로 보내지 않는다. 승인된 시험 일정만 시험 캘린더에 들어간다.
- 각 일정은 처음 확인한 시점부터 마감 시각까지 이어지는 이벤트로 잡힌다.
- `2026.03.17~2026.03.21`처럼 기간만 있는 항목은 마지막 날 `23:59` 마감으로 해석해 캘린더에 넣는다.
- 캘린더 정리만 필요할 때는 `swift ./src/swift/sync_klms_calendar.swift --clear "시험"`처럼 관리 대상 일정만 비우거나 `--delete-calendar`로 캘린더 자체를 삭제할 수 있다.
- 검증은 `zsh ./verify_sync_state.sh` 한 번으로 공지/파일/캘린더 상태를 함께 확인할 수 있다.
- `남은 시간`처럼 매 실행마다 바뀌는 값은 일부러 제외해서, 실제 과제 내용이 바뀔 때만 메모를 갱신한다.
- Safari에서 읽은 큰 HTML은 스크립트가 직접 JSON 파일로 저장해서, 표준 출력 크기 때문에 동기화가 흔들리지 않게 했다.

## 자동 실행

- `launch_sync_if_idle.sh`는 15분마다 깨어나고, 자동 실행 대상은 `KLMS 동기화(core)` 하나다.
- 리마인더 알림 확인은 매번 실행하고, 실제 KLMS 재수집/동기화는 아래 조건을 모두 만족할 때만 수행한다.
- 마지막 실제 시도 후 `6시간` 이상 지났을 것 (`SYNC_INTERVAL_SECONDS=21600`)
- 사용자가 최소 `10분` 이상 입력이 없을 것 (`MIN_IDLE_SECONDS=600`)
- 로그인 세션이 풀리면 macOS 알림으로 `KLMS 다시 로그인` 요청을 띄우고, 사용자가 직접 Safari에서 로그인과 OTP 승인을 진행하게 둔다. `KAIKEY_AUTO_APPROVE_ENABLED=0`인 경우 LaunchAgent는 터미널에 보이지 않는 로그인 보조를 실행하지 않는다.
- 필요하면 `LOGIN_PROMPT_OPEN_SAFARI=1`로 바꿔 로그인 안내 때 Safari 로그인 페이지를 자동으로 열 수 있다.
- 같은 로그인 만료 상태에서 창과 알림이 계속 쌓이지 않도록 `LOGIN_PROMPT_COOLDOWN_SECONDS` 동안은 재알림을 억제한다.
- 로그인 오류가 나면 다음 15분 주기에서 다시 빨리 재시도해서, 사용자가 OTP 승인을 마친 뒤 오래 기다리지 않게 했다.
- 공지의 `읽음` 상태는 `KLMS 공지` 메모에서 사용자가 직접 `읽음` 체크리스트를 체크했을 때만 저장한다. stable 공지라는 이유로 자동 읽음 처리하지 않고, 캡처에 실패하면 기존 체크 상태를 보호하기 위해 메모 렌더링을 건너뛴다.
- 별도 watcher가 Safari의 KLMS 관련 탭을 짧게 감시하고, 로그인 완료로 보이면 즉시 `KLMS 동기화(core)`를 다시 시도한다.
- 그 외 실패는 일반 동기화 실패 알림으로 구분해서 띄운다.
- LaunchAgent는 `Documents` 폴더 보호를 피하기 위해 자동 실행용 파일을 `~/Library/Application Support/KLMSNotesSync`로 복사해서 사용한다.
- LaunchAgent 정의 파일은 `install_launch_agent.sh` 실행 시 `~/Library/LaunchAgents/` 아래에 생성된다.
- 설치된 자동화 로그는 `~/Library/Application Support/KLMSNotesSync/runtime/logs/` 아래에 쌓인다.
- 설정을 바꾼 뒤 자동 실행에도 반영하려면 [install_launch_agent.sh](./install_launch_agent.sh)를 다시 실행해 설치본을 갱신하면 된다.

## 공개 배포

GitHub에 공개하기 전에는 [docs/publication-checklist.md](./docs/publication-checklist.md)를 끝까지 확인한다. 특히 `git status --ignored --short`와 추적 파일 대상 문자열 검색으로 로컬 설정, 인증 state, 수업 파일, 개인 식별 정보가 커밋 대상에 들어가지 않았는지 확인한다.

라이선스는 [MIT](./LICENSE)이며, Kaikey 프로토콜 구현에서 참고한 외부 코드 고지는 [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md)에 둔다.
