# Sync Workflows

## 준비

1. `examples/config.env.example`를 `config.env`로 복사한다.
2. Safari에서 `https://klms.kaist.ac.kr/my/`에 로그인한다.
3. 첫 실행 때 macOS 자동화 권한을 허용한다.

```sh
cp examples/config.env.example config.env
./sync_klms_core.sh
```

## 실행 흐름

| 명령 | 흐름 |
| --- | --- |
| `./sync_klms_core.sh` | dashboard/course/detail 수집 후 Reminders, Calendar, 과제 메모 갱신 |
| `./sync_klms_notice.sh` | Notice 게시판 수집 후 native Notes 공지 메모 렌더 |
| `./refresh_course_files.sh` | 파일 manifest 생성, 다운로드, `course_files`/Downloads mirror prune |
| `./run_all.sh` | `core -> notice` 직렬 실행 |
| `./run_all_full.sh` | `core -> notice -> files` 직렬 실행 |
| `./run_all_parallel.sh` | 로그인 preflight 뒤 `core`, `notice`, `files` 병렬 실행 |

자동 sync entrypoint는 성공 후 `runtime/tmp`를 정리한다. 실패한 실행의 tmp는 디버깅을 위해 보존한다. `KLMS_RUNTIME_TMP_CLEANUP_ENABLED=0`으로 끄거나 `KLMS_RUNTIME_TMP_MAX_AGE_HOURS`로 보존 시간을 바꿀 수 있다.

각 entrypoint는 작업별 lock을 쓴다. 기본 경로는 `~/Library/Application Support/KLMSNotesSync/runtime/automation/{core,notice,files,all}.lock`이고, 쓰기 불가 환경에서는 repo 내부 fallback lock으로 내려간다.

## 모드와 캐시

`SYNC_MODE`와 `FILE_REFRESH_MODE`는 각각 `quick`, `full`, `auto`를 지원한다.

| 모드 | 의미 |
| --- | --- |
| `full` | 대상 URL을 전부 다시 읽는다 |
| `quick` | 새 URL, stale URL, 항상 확인해야 하는 URL 위주로 읽고 나머지는 cache를 재사용 |
| `auto` | cache coverage와 마지막 full 시각을 참고해 quick/full을 선택 |

기본값은 최소 탐색을 우선한다.

- `SYNC_MINIMAL_EXPLORATION_ENABLED=1`
- `FILE_MINIMAL_EXPLORATION_ENABLED=1`
- `FETCH_AUTO_FULL_MIN_COVERAGE=0.2`
- `FETCH_AUTO_REQUIRE_LAST_FULL=0`
- `FETCH_AUTO_FULL_ON_TTL_EXPIRE=0`

Safari 수집은 `FETCH_MIN_WAIT_SECONDS`, `FETCH_STABLE_POLLS`를 써서 DOM이 빨리 안정화되면 고정 대기 시간을 끝까지 쓰지 않고 다음 페이지로 넘어간다.

## 로그인과 Kaikey

세 entrypoint는 실행 전에 공통 로그인 preflight를 거친다. Safari의 현재 KLMS 탭이 로그인 페이지면 즉시 실패하고, 아니면 dashboard fetch로 최종 확인한다. 직접 실행하는 entrypoint에서 로그인 실패가 감지되면 기본값으로 기존 KLMS/portal 탭을 로그인 URL로 돌린다.

수동 승인만 쓰려면 아래 설정을 둔다.

```sh
KAIKEY_LOGIN_ASSIST_ENABLED="1"
KAIKEY_AUTO_LOGIN_ENABLED="0"
KAIKEY_AUTO_APPROVE_ENABLED="0"
KAIKEY_MANUAL_APPROVAL_TIMEOUT_SECONDS="300"
```

이 설정에서는 2FA 화면에 표시된 값을 터미널에 `KAIST 인증 번호: NN` 형태로 보여주고, 휴대폰에서 같은 번호를 선택할 때까지 기다린다. LaunchAgent 같은 비대화 자동 동기화는 로그인 보조를 실행하지 않고 기존 로그인 알림 경로로 빠진다.

Mac 자동 인증을 쓰려면 처음 한 번 QR 스크린샷으로 로컬 기기를 등록한다.

```sh
./kaikey_setup.sh --qr-image /path/to/qr-screenshot.png
node ./src/js/kaikey_cli.mjs status
```

기본 기기키 저장 위치는 `~/Library/Application Support/KLMSNotesSync/kaikey_state.json`이고 권한은 `0600`으로 맞춘다. 경로를 바꾸려면 `KAIKEY_STATE_PATH`를 설정한다.

iPhone에서 Mac 승인을 호출할 때는 공개 HTTP endpoint를 만들지 말고 SSH, 로컬 네트워크, VPN처럼 접근 제어가 있는 경로만 사용한다.

```sh
cd ~/Library/Application\ Support/KLMSNotesSync
./kaikey_approve_number.sh "$SHORTCUT_INPUT"
```

## 자동 실행

`install_launch_agent.sh`를 실행하면 자동 실행용 파일이 `~/Library/Application Support/KLMSNotesSync`로 복사되고 LaunchAgent가 등록된다.

```sh
./install_launch_agent.sh
```

`launch_sync_if_idle.sh`는 15분마다 깨어난다. 실제 KLMS 재수집/동기화는 아래 조건을 만족할 때만 수행한다.

- 마지막 실제 시도 후 `SYNC_INTERVAL_SECONDS` 이상 지났을 것
- 사용자가 `MIN_IDLE_SECONDS` 이상 입력이 없을 것
- 로그인 preflight를 통과할 것

로그인 세션이 풀리면 macOS 알림으로 다시 로그인 요청을 띄운다. 같은 로그인 만료 상태에서 창과 알림이 계속 쌓이지 않도록 `LOGIN_PROMPT_COOLDOWN_SECONDS` 동안 재알림을 억제한다.

## 검증과 병목 확인

실제 상태 검증:

```sh
./verify_sync_state.sh
./verify_sync_state.sh --json
./doctor.sh
./sync_report.sh
```

이 검증은 다음을 함께 확인한다.

- `notice_digest.json`의 공지 URL이 Notes render state에 반영됐는지
- file manifest의 `absolute_path`가 실제 파일로 존재하는지
- state의 시험/헬프데스크 수와 Apple Calendar의 `[KLMS 시험]`, `[KLMS 헬프데스크]` 이벤트 수가 맞는지
- 예전 `KLMS 과제`, `KLMS 알림` 캘린더가 남아 있는지

병목 후보는 `runtime/cache/{core,notice,files}/stage_timings.json`의 `slowest_stages`, `slowest_events`를 본다. `SYNC_COMMAND_TIMING_ENABLED=1`이면 하위 명령의 시작/종료/소요 시간도 `events`에 남는다.

변경 예정 사항만 보고 싶으면 각 entrypoint에 `--dry-run`을 붙인다. dry-run은 side effect를 건너뛰고 `runtime/cache/<scope>/dry_run_report.json`에 요약을 남긴다.
