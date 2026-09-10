#!/usr/bin/env bats

load_flexqos_functions() {
  local extracted="$BATS_TEST_TMPDIR/flexqos-schedule-functions.sh"

  python3 - "$PROJECT_ROOT/flexqos.sh" > "$extracted" <<'PY'
import re
import sys
from collections import Counter
from pathlib import Path

wanted = {
    "qos_stop",
    "qos_start",
    "_qs_trim",
    "_qs_to_dec",
    "_qs_hm",
    "_qs_int",
    "_qs_parse_time",
    "_qs_dow_matches",
    "_qs_shift_dow_next_day",
    "_qs_expand_dow_for_cron",
    "_qs_now_in_window",
    "_qs_valid_dow",
    "_qs_clear_jobs",
    "_qs_apply_jobs",
    "qos_schedule_sync_state",
    "qos_schedule_apply_from_config",
    "_qs_count",
    "_qs_parse_record_str",
}

lines = Path(sys.argv[1]).read_text().splitlines(keepends=True)
starts = []
for i, line in enumerate(lines):
    match = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{', line.rstrip('\n'))
    if match:
        starts.append((i, match.group(1)))

counts = Counter(name for _, name in starts if name in wanted)
bad = {name: counts[name] for name in wanted if counts[name] != 1}
if bad:
    raise SystemExit(f"expected each tested function exactly once: {bad}")

for pos, (start, name) in enumerate(starts):
    if name not in wanted:
        continue
    end = starts[pos + 1][0] if pos + 1 < len(starts) else len(lines)
    sys.stdout.write(''.join(lines[start:end]))
PY

  # shellcheck source=/dev/null
  source "$extracted"
}

am_settings_get() {
  [ -z "${SETTINGS_LOG:-}" ] || printf '%s\n' "${1:-}" >> "$SETTINGS_LOG"
  case "${1:-}" in
    flexqos_schedule) printf '%s\n' "${CONFIG_SCHEDULE:-}" ;;
    *) printf '\n' ;;
  esac
}

setup() {
  set -u -o pipefail

  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTNAME="flexqos"
  SCRIPTPATH="/jffs/addons/flexqos/flexqos.sh"
  CONFIG_SCHEDULE=""

  MOCK_DATE_H="12"
  MOCK_DATE_M="00"
  MOCK_DATE_W="2"
  NVRAM_QOS_TYPE="1"
  NVRAM_QOS_ENABLE="1"
  CRU_LIST_FAIL=0
  CRU_ADD_FAIL_AT=0
  CRU_DELETE_FAIL_ID=""

  NVRAM_LOG="$BATS_TEST_TMPDIR/nvram.log"
  SERVICE_LOG="$BATS_TEST_TMPDIR/service.log"
  FLOWCACHE_LOG="$BATS_TEST_TMPDIR/flowcache.log"
  PROMPT_LOG="$BATS_TEST_TMPDIR/prompt.log"
  CONNTRACK_LOG="$BATS_TEST_TMPDIR/conntrack.log"
  LOGMSG_LOG="$BATS_TEST_TMPDIR/logmsg.log"
  SETTINGS_LOG="$BATS_TEST_TMPDIR/settings.log"
  EVENT_LOG="$BATS_TEST_TMPDIR/events.log"
  CRU_LOG="$BATS_TEST_TMPDIR/cru.log"
  CRU_LIST_FILE="$BATS_TEST_TMPDIR/cru-list.txt"
  CRU_ADD_COUNT_FILE="$BATS_TEST_TMPDIR/cru-add-count.txt"
  MOCK_BIN="$BATS_TEST_TMPDIR/bin"

  : > "$NVRAM_LOG"
  : > "$SERVICE_LOG"
  : > "$FLOWCACHE_LOG"
  : > "$PROMPT_LOG"
  : > "$CONNTRACK_LOG"
  : > "$LOGMSG_LOG"
  : > "$SETTINGS_LOG"
  : > "$EVENT_LOG"
  : > "$CRU_LOG"
  : > "$CRU_LIST_FILE"
  printf '0\n' > "$CRU_ADD_COUNT_FILE"
  mkdir -p "$MOCK_BIN"

  cat > "$MOCK_BIN/cru" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  l)
    [ "${CRU_LIST_FAIL:-0}" -eq 0 ] || exit "$CRU_LIST_FAIL"
    cat "$CRU_LIST_FILE"
    ;;
  a)
    count="$(cat "$CRU_ADD_COUNT_FILE")"
    count=$((count + 1))
    printf '%s\n' "$count" > "$CRU_ADD_COUNT_FILE"
    [ "${CRU_ADD_FAIL_AT:-0}" -ne "$count" ] || exit 9
    printf '%s\n' "$*" >> "$CRU_LOG"
    id="${2:-}"
    printf '%s %s %s %s %s %s %s #%s#\n' "${3:-}" "${4:-}" "${5:-}" "${6:-}" "${7:-}" "${8:-}" "${9:-}" "$id" >> "$CRU_LIST_FILE"
    ;;
  d)
    id="${2:-}"
    [ -z "${CRU_DELETE_FAIL_ID:-}" ] || [ "$id" != "$CRU_DELETE_FAIL_ID" ] || exit 10
    printf '%s\n' "$*" >> "$CRU_LOG"
    awk -v marker="#$id#" 'index($0, marker) == 0' "$CRU_LIST_FILE" > "$CRU_LIST_FILE.tmp"
    mv "$CRU_LIST_FILE.tmp" "$CRU_LIST_FILE"
    ;;
  *)
    exit 2
    ;;
esac
SH
  chmod +x "$MOCK_BIN/cru"
  export CRU_LOG CRU_LIST_FILE CRU_ADD_COUNT_FILE CRU_LIST_FAIL CRU_ADD_FAIL_AT CRU_DELETE_FAIL_ID
  PATH="$MOCK_BIN:$PATH"
  export PATH

  load_flexqos_functions
  : > "$SETTINGS_LOG"
  SCHEDULE=""
}

date() {
  case "${1:-}" in
    +%H) printf '%s\n' "$MOCK_DATE_H" ;;
    +%M) printf '%s\n' "$MOCK_DATE_M" ;;
    +%w) printf '%s\n' "$MOCK_DATE_W" ;;
    *) return 2 ;;
  esac
}

nvram() {
  case "${1:-}" in
    get)
      case "${2:-}" in
        qos_type) printf '%s\n' "$NVRAM_QOS_TYPE" ;;
        qos_enable) printf '%s\n' "$NVRAM_QOS_ENABLE" ;;
        *) printf '\n' ;;
      esac
      ;;
    set)
      printf '%s\n' "${2:-}" >> "$NVRAM_LOG"
      printf 'nvram-set %s\n' "${2:-}" >> "$EVENT_LOG"
      case "${2:-}" in
        qos_type=*) NVRAM_QOS_TYPE="${2#*=}" ;;
        qos_enable=*) NVRAM_QOS_ENABLE="${2#*=}" ;;
        *) return 2 ;;
      esac
      ;;
    *) return 2 ;;
  esac
}

service() {
  printf '%s\n' "$*" >> "$SERVICE_LOG"
  printf 'service %s\n' "$*" >> "$EVENT_LOG"
}

_fc_apply_policy() {
  printf '%s\n' "$*" >> "$FLOWCACHE_LOG"
  printf 'flowcache %s\n' "$*" >> "$EVENT_LOG"
}

prompt_restart() {
  printf 'prompt\n' >> "$PROMPT_LOG"
  printf 'prompt\n' >> "$EVENT_LOG"
}

_flush_conntrack_() {
  printf 'flush\n' >> "$CONNTRACK_LOG"
  printf 'conntrack flush\n' >> "$EVENT_LOG"
}

logmsg() {
  printf '%s\n' "$*" >> "$LOGMSG_LOG"
}

assert_equal() {
  local expected="$1" actual="$2"
  if [ "$expected" != "$actual" ]; then
    printf '%s\n' '--- expected' >&2
    printf '%s\n' "$expected" >&2
    printf '%s\n' '--- actual' >&2
    printf '%s\n' "$actual" >&2
    return 1
  fi
}

assert_success() {
  if [ "$status" -ne 0 ]; then
    printf 'expected success, got status %s\n%s\n' "$status" "$output" >&2
    return 1
  fi
}

assert_failure() {
  if [ "$status" -eq 0 ]; then
    printf 'expected failure, got success\n%s\n' "$output" >&2
    return 1
  fi
}

assert_empty_file() {
  if [ -s "$1" ]; then
    printf 'expected empty file: %s\n' "$1" >&2
    cat "$1" >&2
    return 1
  fi
}

assert_file_equals() {
  local expected="$1" file="$2"
  assert_equal "$expected" "$(cat "$file")"
}

set_mock_time() {
  MOCK_DATE_H="$1"
  MOCK_DATE_M="$2"
  MOCK_DATE_W="$3"
}

@test "scheduler trim removes surrounding whitespace and carriage returns" {
  assert_equal "07:05" "$(_qs_trim $' \t07:05\r ' )"
}

@test "scheduler decimal conversion does not interpret leading zeroes as octal" {
  assert_equal "8" "$(_qs_to_dec 08)"
  assert_equal "9" "$(_qs_int 09)"
  assert_equal "07:05" "$(_qs_hm 07 05)"
}

@test "scheduler time parser accepts hour-only and HH:MM forms" {
  local value expected
  for value in 7 07:05 23:59 0:00; do
    case "$value" in
      7) expected="07 00" ;;
      07:05) expected="07 05" ;;
      23:59) expected="23 59" ;;
      0:00) expected="00 00" ;;
    esac
    run _qs_parse_time "$value"
    assert_success
    assert_equal "$expected" "$output"
  done
}

@test "scheduler time parser rejects malformed and out-of-range values" {
  local value
  for value in '' 24:00 12:60 12: 1:2:3 -1 12:ab '12 30'; do
    run _qs_parse_time "$value"
    assert_failure
  done
}

@test "DOW validator accepts wildcard lists normal ranges and wraparound ranges" {
  local value
  for value in '*' 0 7 1,3,5 1-5 5-1 0-7 7-2; do
    run _qs_valid_dow "$value"
    assert_success
  done
}

@test "DOW validator rejects empty fields malformed ranges and invalid days" {
  local value
  for value in '' ',' '1,' ',1' '1,,2' 8 1-8 1-2-3 a '1 2'; do
    run _qs_valid_dow "$value"
    assert_failure
  done
}

@test "DOW matcher handles wildcard and Sunday alias exactly" {
  run _qs_dow_matches '*' 4
  assert_success
  run _qs_dow_matches 0 7
  assert_success
  run _qs_dow_matches 7 0
  assert_success
  run _qs_dow_matches 1 0
  assert_failure
}

@test "DOW matcher handles normal ranges and lists" {
  run _qs_dow_matches 1-5 3
  assert_success
  run _qs_dow_matches 1-5 6
  assert_failure
  run _qs_dow_matches 0,6 6
  assert_success
  run _qs_dow_matches 0,6 2
  assert_failure
}

@test "DOW matcher handles wraparound ranges" {
  local day
  for day in 5 6 0 1; do
    run _qs_dow_matches 5-1 "$day"
    assert_success
  done
  for day in 2 3 4; do
    run _qs_dow_matches 5-1 "$day"
    assert_failure
  done
}

@test "DOW matcher restores the caller IFS exactly" {
  local original
  IFS=$' \t\n;'
  original="$IFS"
  _qs_dow_matches '5-1,3' 6
  assert_equal "$original" "$IFS"
}

@test "cron DOW expansion is deterministic for ranges aliases and full week" {
  assert_equal "1,2,3,4,5" "$(_qs_expand_dow_for_cron 1-5)"
  assert_equal "5,6,0,1" "$(_qs_expand_dow_for_cron 5-1)"
  assert_equal "0" "$(_qs_expand_dow_for_cron 7)"
  assert_equal "*" "$(_qs_expand_dow_for_cron 0-7)"
  assert_equal "*" "$(_qs_expand_dow_for_cron '*')"
}

@test "overnight stop DOW shifting advances every selected day" {
  assert_equal "6,0,1,2" "$(_qs_shift_dow_next_day '5,6,0,1')"
  assert_equal "0" "$(_qs_shift_dow_next_day 6)"
  assert_equal "1" "$(_qs_shift_dow_next_day 7)"
  assert_equal "*" "$(_qs_shift_dow_next_day 0-7)"
  assert_equal "*" "$(_qs_shift_dow_next_day '*')"
}

@test "same-day window includes start and excludes end" {
  set_mock_time 09 00 2
  run _qs_now_in_window 9 0 17 0 2
  assert_success

  set_mock_time 16 59 2
  run _qs_now_in_window 9 0 17 0 2
  assert_success

  set_mock_time 17 00 2
  run _qs_now_in_window 9 0 17 0 2
  assert_failure
}

@test "same-day window requires the configured DOW" {
  set_mock_time 12 00 6
  run _qs_now_in_window 9 0 17 0 1-5
  assert_failure

  set_mock_time 12 00 5
  run _qs_now_in_window 9 0 17 0 1-5
  assert_success
}

@test "overnight pre-midnight segment uses the current schedule day" {
  set_mock_time 23 30 5
  run _qs_now_in_window 22 0 6 0 5
  assert_success

  set_mock_time 23 30 6
  run _qs_now_in_window 22 0 6 0 5
  assert_failure
}

@test "overnight post-midnight segment uses the previous schedule day" {
  set_mock_time 01 00 6
  run _qs_now_in_window 22 0 6 0 5
  assert_success

  run _qs_now_in_window 22 0 6 0 6
  assert_failure

  set_mock_time 06 00 6
  run _qs_now_in_window 22 0 6 0 5
  assert_failure
}

@test "schedule record helpers count and parse four-part records" {
  SCHEDULE='<1>1-5>07:00>20:00|<0>0,6>09:00>10:00'
  assert_equal "2" "$(_qs_count)"
  assert_equal "1 1-5 07:00 20:00" "$(_qs_parse_record_str '<1>1-5>07:00>20:00')"
  SCHEDULE=""
  assert_equal "0" "$(_qs_count)"
}

@test "cron cleanup deletes only FlexQoS scheduler jobs" {
  cat > "$CRU_LIST_FILE" <<'EOF_CRU'
0 7 * * 1 /jffs/addons/flexqos/flexqos.sh -qossync #flexqos_qoson_1#
0 20 * * 1 /jffs/addons/flexqos/flexqos.sh -qossync #flexqos_qosoff#
0 0 * * * /other/script #unrelated_job#
EOF_CRU

  _qs_clear_jobs

  assert_file_equals $'d flexqos_qoson_1\nd flexqos_qosoff' "$CRU_LOG"
}

@test "empty schedule clears jobs without changing QoS state" {
  SCHEDULE=""
  _qs_apply_jobs

  assert_empty_file "$CRU_LOG"
  assert_empty_file "$NVRAM_LOG"
  assert_empty_file "$SERVICE_LOG"
  assert_empty_file "$FLOWCACHE_LOG"
  assert_empty_file "$LOGMSG_LOG"
}

@test "active daytime schedule emits exact cron jobs and keeps QoS running" {
  SCHEDULE='<1>1-5>07:00>20:00'
  set_mock_time 08 30 2
  NVRAM_QOS_TYPE=1
  NVRAM_QOS_ENABLE=1

  _qs_apply_jobs

  assert_file_equals $'a flexqos_qoson_1 0 7 * * 1,2,3,4,5 /jffs/addons/flexqos/flexqos.sh -qossync\na flexqos_qosoff_2 0 20 * * 1,2,3,4,5 /jffs/addons/flexqos/flexqos.sh -qossync' "$CRU_LOG"
  assert_empty_file "$SERVICE_LOG"
  grep -qx 'Starting Adaptive QoS...' "$LOGMSG_LOG"
  grep -qx 'Adaptive QoS already running; nothing to do.' "$LOGMSG_LOG"
}

@test "inactive daytime schedule emits cron jobs and keeps disabled QoS stopped" {
  SCHEDULE='<1>1-5>07:00>20:00'
  set_mock_time 21 00 2
  NVRAM_QOS_TYPE=1
  NVRAM_QOS_ENABLE=0

  _qs_apply_jobs

  assert_file_equals $'a flexqos_qoson_1 0 7 * * 1,2,3,4,5 /jffs/addons/flexqos/flexqos.sh -qossync\na flexqos_qosoff_2 0 20 * * 1,2,3,4,5 /jffs/addons/flexqos/flexqos.sh -qossync' "$CRU_LOG"
  assert_empty_file "$SERVICE_LOG"
  grep -qx 'Stopping Adaptive QoS...' "$LOGMSG_LOG"
  grep -qx 'Adaptive QoS already disabled; nothing to do.' "$LOGMSG_LOG"
}

@test "overnight schedule shifts only the stop cron job to the next DOW" {
  SCHEDULE='<1>5>22:00>06:00'
  set_mock_time 23 00 5
  NVRAM_QOS_TYPE=1
  NVRAM_QOS_ENABLE=1

  _qs_apply_jobs

  assert_file_equals $'a flexqos_qoson_1 0 22 * * 5 /jffs/addons/flexqos/flexqos.sh -qossync\na flexqos_qosoff_2 0 6 * * 6 /jffs/addons/flexqos/flexqos.sh -qossync' "$CRU_LOG"
  assert_empty_file "$SERVICE_LOG"
}

@test "multiple schedules keep deterministic cron numbering and any active window enables QoS" {
  SCHEDULE='<1>1>07:00>08:00|<1>2>12:00>13:00'
  set_mock_time 12 30 2
  NVRAM_QOS_TYPE=1
  NVRAM_QOS_ENABLE=0

  _qs_apply_jobs

  assert_file_equals $'a flexqos_qoson_1 0 7 * * 1 /jffs/addons/flexqos/flexqos.sh -qossync\na flexqos_qosoff_2 0 8 * * 1 /jffs/addons/flexqos/flexqos.sh -qossync\na flexqos_qoson_3 0 12 * * 2 /jffs/addons/flexqos/flexqos.sh -qossync\na flexqos_qosoff_4 0 13 * * 2 /jffs/addons/flexqos/flexqos.sh -qossync' "$CRU_LOG"
  assert_file_equals 'qos_enable=1' "$NVRAM_LOG"
  assert_file_equals 'start_qos' "$SERVICE_LOG"
  assert_file_equals 'on' "$FLOWCACHE_LOG"
}

@test "disabled and malformed schedule records do not create cron jobs" {
  SCHEDULE='<0>1-5>07:00>20:00|<1>2>25:00>26:00|<1>8>07:00>20:00|<1>2>07:00'
  set_mock_time 12 00 2
  NVRAM_QOS_ENABLE=0

  _qs_apply_jobs

  assert_empty_file "$CRU_LOG"
  assert_empty_file "$SERVICE_LOG"
  grep -qx 'Stopping Adaptive QoS...' "$LOGMSG_LOG"
}

@test "schedule apply loads saved configuration when runtime schedule is empty" {
  CONFIG_SCHEDULE='<1>2>07:00>20:00'
  SCHEDULE=""
  set_mock_time 08 00 2
  NVRAM_QOS_TYPE=1
  NVRAM_QOS_ENABLE=1

  qos_schedule_apply_from_config

  assert_equal "$CONFIG_SCHEDULE" "$SCHEDULE"
  assert_file_equals $'a flexqos_qoson_1 0 7 * * 2 /jffs/addons/flexqos/flexqos.sh -qossync\na flexqos_qosoff_2 0 20 * * 2 /jffs/addons/flexqos/flexqos.sh -qossync' "$CRU_LOG"
}

@test "schedule apply with no saved configuration only clears cron jobs" {
  cat > "$CRU_LIST_FILE" <<'EOF_CRU'
0 7 * * 1 /jffs/addons/flexqos/flexqos.sh -qossync #flexqos_qoson_1#
EOF_CRU
  CONFIG_SCHEDULE=""
  SCHEDULE=""

  qos_schedule_apply_from_config

  assert_file_equals 'd flexqos_qoson_1' "$CRU_LOG"
  assert_empty_file "$SERVICE_LOG"
  assert_empty_file "$NVRAM_LOG"
}

@test "qos_start applies both type and enable transitions with runtime side effects" {
  NVRAM_QOS_TYPE=0
  NVRAM_QOS_ENABLE=0

  qos_start

  assert_file_equals $'qos_type=1\nqos_enable=1' "$NVRAM_LOG"
  assert_file_equals 'start_qos' "$SERVICE_LOG"
  assert_file_equals 'on' "$FLOWCACHE_LOG"
  assert_file_equals 'prompt' "$PROMPT_LOG"
  assert_file_equals 'flush' "$CONNTRACK_LOG"
  assert_file_equals $'nvram-set qos_type=1\nnvram-set qos_enable=1\nservice start_qos\nflowcache on\nprompt\nconntrack flush' "$EVENT_LOG"
}

@test "qos_start still reapplies QoS when only the type is wrong" {
  NVRAM_QOS_TYPE=0
  NVRAM_QOS_ENABLE=1

  qos_start

  assert_file_equals 'qos_type=1' "$NVRAM_LOG"
  assert_file_equals 'start_qos' "$SERVICE_LOG"
  assert_file_equals 'on' "$FLOWCACHE_LOG"
}

@test "qos_start is idempotent when Adaptive QoS is already running" {
  NVRAM_QOS_TYPE=1
  NVRAM_QOS_ENABLE=1

  qos_start

  assert_empty_file "$NVRAM_LOG"
  assert_empty_file "$SERVICE_LOG"
  assert_empty_file "$FLOWCACHE_LOG"
  assert_empty_file "$PROMPT_LOG"
  assert_empty_file "$CONNTRACK_LOG"
}

@test "qos_stop disables active QoS with matching runtime side effects" {
  NVRAM_QOS_ENABLE=1

  qos_stop

  assert_file_equals 'qos_enable=0' "$NVRAM_LOG"
  assert_file_equals 'stop_qos' "$SERVICE_LOG"
  assert_file_equals 'off' "$FLOWCACHE_LOG"
  assert_file_equals 'prompt' "$PROMPT_LOG"
  assert_file_equals 'flush' "$CONNTRACK_LOG"
  assert_file_equals $'nvram-set qos_enable=0\nservice stop_qos\nflowcache off\nprompt\nconntrack flush' "$EVENT_LOG"
}

@test "qos_stop is idempotent when QoS is already disabled" {
  NVRAM_QOS_ENABLE=0

  qos_stop

  assert_empty_file "$NVRAM_LOG"
  assert_empty_file "$SERVICE_LOG"
  assert_empty_file "$FLOWCACHE_LOG"
  assert_empty_file "$PROMPT_LOG"
  assert_empty_file "$CONNTRACK_LOG"
}


@test "all scheduler DOW ranges match an exhaustive independent day model" {
  local start end day ns ne expected status
  for start in 0 1 2 3 4 5 6 7; do
    for end in 0 1 2 3 4 5 6 7; do
      ns="$start"; ne="$end"
      [ "$ns" = "7" ] && ns=0
      [ "$ne" = "7" ] && ne=0
      for day in 0 1 2 3 4 5 6; do
        expected=1
        if [ "$start-$end" = "0-7" ]; then
          expected=0
        elif [ "$ns" -le "$ne" ]; then
          [ "$day" -ge "$ns" ] && [ "$day" -le "$ne" ] && expected=0
        else
          { [ "$day" -ge "$ns" ] || [ "$day" -le "$ne" ]; } && expected=0
        fi
        if _qs_dow_matches "$start-$end" "$day"; then status=0; else status=$?; fi
        if [ "$expected" -eq 0 ]; then
          [ "$status" -eq 0 ] || { echo "expected $start-$end to match day $day" >&2; return 1; }
        else
          [ "$status" -ne 0 ] || { echo "expected $start-$end not to match day $day" >&2; return 1; }
        fi
      done
    done
  done
}

@test "all DOW transformation helpers restore the caller IFS exactly" {
  local original
  IFS=$' \t\n;'
  original="$IFS"
  _qs_expand_dow_for_cron '5-1,3' >/dev/null
  assert_equal "$original" "$IFS"
  _qs_shift_dow_next_day '5,6,0,1' >/dev/null
  assert_equal "$original" "$IFS"
}

@test "stored schedules with invalid DOW never reach cron" {
  SCHEDULE='<1>8>07:00>20:00|<1>1-8>08:00>21:00|<1>1,,2>09:00>22:00'
  NVRAM_QOS_ENABLE=0

  _qs_apply_jobs

  assert_empty_file "$CRU_LOG"
  assert_empty_file "$CRU_LIST_FILE"
  assert_empty_file "$SERVICE_LOG"
}

@test "cron cleanup fails closed when cron state cannot be inspected" {
  CRU_LIST_FAIL=7
  run _qs_clear_jobs
  assert_failure
  assert_empty_file "$CRU_LOG"
}

@test "schedule apply aborts before side effects when cron cleanup fails" {
  SCHEDULE='<1>2>07:00>20:00'
  CRU_LIST_FAIL=7
  NVRAM_QOS_ENABLE=0

  run _qs_apply_jobs
  assert_failure
  assert_empty_file "$CRU_LOG"
  assert_empty_file "$NVRAM_LOG"
  assert_empty_file "$SERVICE_LOG"
  assert_empty_file "$EVENT_LOG"
}

@test "schedule apply reports cron deletion failures and does not install replacements" {
  cat > "$CRU_LIST_FILE" <<'EOF_CRU'
0 7 * * 2 /jffs/addons/flexqos/flexqos.sh -qossync #flexqos_qoson_1#
EOF_CRU
  SCHEDULE='<1>2>08:00>20:00'
  CRU_DELETE_FAIL_ID='flexqos_qoson_1'

  run _qs_apply_jobs
  assert_failure
  assert_empty_file "$CRU_LOG"
  assert_empty_file "$SERVICE_LOG"
}

@test "partial cron installation is cleaned up and reported as failure" {
  SCHEDULE='<1>2>07:00>20:00'
  CRU_ADD_FAIL_AT=2
  NVRAM_QOS_ENABLE=0

  run _qs_apply_jobs
  assert_failure
  assert_empty_file "$CRU_LIST_FILE"
  assert_empty_file "$NVRAM_LOG"
  assert_empty_file "$SERVICE_LOG"
}

@test "reapplying a schedule replaces managed cron jobs instead of duplicating them" {
  SCHEDULE='<1>2>07:00>20:00'
  set_mock_time 08 00 2
  _qs_apply_jobs
  : > "$CRU_LOG"

  SCHEDULE='<1>2>08:00>21:00'
  _qs_apply_jobs

  assert_equal "2" "$(grep -c '#flexqos_qos' "$CRU_LIST_FILE")"
  grep -qx '0 8 \* \* 2 /jffs/addons/flexqos/flexqos.sh -qossync #flexqos_qoson_1#' "$CRU_LIST_FILE"
  grep -qx '0 21 \* \* 2 /jffs/addons/flexqos/flexqos.sh -qossync #flexqos_qosoff_2#' "$CRU_LIST_FILE"
}

@test "aggregate schedule sync keeps QoS enabled across overlapping window boundaries" {
  SCHEDULE='<1>2>09:00>12:00|<1>2>11:00>15:00'
  set_mock_time 12 00 2
  NVRAM_QOS_TYPE=1
  NVRAM_QOS_ENABLE=0

  qos_schedule_sync_state

  assert_file_equals 'qos_enable=1' "$NVRAM_LOG"
  assert_file_equals 'start_qos' "$SERVICE_LOG"
  assert_file_equals 'on' "$FLOWCACHE_LOG"
}

@test "aggregate schedule sync stops QoS only after every window is inactive" {
  SCHEDULE='<1>2>09:00>12:00|<1>2>11:00>15:00'
  set_mock_time 15 00 2
  NVRAM_QOS_ENABLE=1

  qos_schedule_sync_state

  assert_file_equals 'qos_enable=0' "$NVRAM_LOG"
  assert_file_equals 'stop_qos' "$SERVICE_LOG"
  assert_file_equals 'off' "$FLOWCACHE_LOG"
}

@test "aggregate schedule sync with no saved schedule leaves runtime QoS untouched" {
  SCHEDULE=""
  CONFIG_SCHEDULE=""
  NVRAM_QOS_ENABLE=1

  qos_schedule_sync_state

  assert_file_equals 'flexqos_schedule' "$SETTINGS_LOG"
  assert_empty_file "$NVRAM_LOG"
  assert_empty_file "$SERVICE_LOG"
  assert_empty_file "$EVENT_LOG"
}

@test "runtime schedule takes precedence without rereading saved settings" {
  SCHEDULE='<1>2>07:00>20:00'
  CONFIG_SCHEDULE='<1>3>01:00>02:00'
  set_mock_time 08 00 2
  NVRAM_QOS_ENABLE=1

  qos_schedule_sync_state

  assert_empty_file "$SETTINGS_LOG"
  assert_empty_file "$SERVICE_LOG"
}

@test "internal qossync command is wired to aggregate scheduler reconciliation" {
  local block
  block="$(grep -A2 -F "'qossync')" "$PROJECT_ROOT/flexqos.sh")"
  printf '%s\\n' "$block" | grep -q 'qos_schedule_sync_state'
}
