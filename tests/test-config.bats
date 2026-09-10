#!/usr/bin/env bats

load_config_functions() {
  local extracted="$BATS_TEST_TMPDIR/flexqos-config-functions.sh"
  python3 - "$PROJECT_ROOT/flexqos.sh" > "$extracted" <<'PY'
import re
import sys
from collections import Counter
from pathlib import Path

wanted = {"_config_valid_bwrates", "_config_convert_legacy_bandwidth", "get_config"}
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

setup() {
  set -u -o pipefail
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTNAME="flexqos"
  DEFAULT_BWRATES='<5>15>30>20>10>5>10>5<100>100>100>100>100>100>100>100<5>15>10>20>10>5>30>5<100>100>100>100>100>100>100>100'
  DEFAULT_IPTABLES='<>>udp>>500,4500>>3<>>udp>16384:16415>>>3<>>tcp>>119,563>>5<>>tcp>>80,443>08****>5'
  DEFAULT_APPDB='<000000>6<00006B>6<0D0007>5<0D0086>5<0D00A0>5<12003F>4<13****>4<14****>4'

  SET_IPTABLES=""
  SET_APPDB=""
  SET_BWRATES=""
  SET_BANDWIDTH=""
  SET_FCCONTROL=""
  SETTINGS_SET_LOG="$BATS_TEST_TMPDIR/settings-set.log"
  SED_LOG="$BATS_TEST_TMPDIR/sed.log"
  LOGMSG_LOG="$BATS_TEST_TMPDIR/logmsg.log"
  : > "$SETTINGS_SET_LOG"
  : > "$SED_LOG"
  : > "$LOGMSG_LOG"

  load_config_functions
}

am_settings_get() {
  case "${1:-}" in
    flexqos_iptables) printf '%s\n' "$SET_IPTABLES" ;;
    flexqos_appdb) printf '%s\n' "$SET_APPDB" ;;
    flexqos_bwrates) printf '%s\n' "$SET_BWRATES" ;;
    flexqos_bandwidth) printf '%s\n' "$SET_BANDWIDTH" ;;
    flexqos_fccontrol) printf '%s\n' "$SET_FCCONTROL" ;;
    *) printf '\n' ;;
  esac
}

am_settings_set() {
  printf '%s=%s\n' "${1:-}" "${2:-}" >> "$SETTINGS_SET_LOG"
}

logmsg() {
  printf '%s\n' "$*" >> "$LOGMSG_LOG"
}

sed() {
  if [ "${1:-}" = "-i" ]; then
    printf '%s\n' "$*" >> "$SED_LOG"
    return 0
  fi
  /bin/sed "$@"
}

assert_equal() {
  if [ "$1" != "$2" ]; then
    printf '%s\n' '--- expected' "$1" '--- actual' "$2" >&2
    return 1
  fi
}

@test "bwrates validator accepts exact four-by-eight percentage matrices" {
  for value in \
    "$DEFAULT_BWRATES" \
    '<1>2>3>4>5>6>7>8<9>10>11>12>13>14>15>16<17>18>19>20>21>22>23>24<93>94>95>96>97>98>99>100'
  do
    run _config_valid_bwrates "$value"
    [ "$status" -eq 0 ]
  done
}

@test "bwrates validator rejects malformed shape bounds and unsafe numeric forms" {
  local value
  for value in \
    '' \
    '1>2>3>4>5>6>7>8<9>10>11>12>13>14>15>16<17>18>19>20>21>22>23>24<25>26>27>28>29>30>31>32' \
    '<1>2>3>4>5>6>7<9>10>11>12>13>14>15>16<17>18>19>20>21>22>23>24<25>26>27>28>29>30>31>32' \
    '<1>2>3>4>5>6>7>8>9<10>11>12>13>14>15>16>17<18>19>20>21>22>23>24>25<26>27>28>29>30>31>32>33' \
    '<0>2>3>4>5>6>7>8<9>10>11>12>13>14>15>16<17>18>19>20>21>22>23>24<25>26>27>28>29>30>31>32' \
    '<101>2>3>4>5>6>7>8<9>10>11>12>13>14>15>16<17>18>19>20>21>22>23>24<25>26>27>28>29>30>31>32' \
    '<08>2>3>4>5>6>7>8<9>10>11>12>13>14>15>16<17>18>19>20>21>22>23>24<25>26>27>28>29>30>31>32' \
    '<x>2>3>4>5>6>7>8<9>10>11>12>13>14>15>16<17>18>19>20>21>22>23>24<25>26>27>28>29>30>31>32'
  do
    run _config_valid_bwrates "$value"
    [ "$status" -ne 0 ]
  done

  run _config_valid_bwrates "$DEFAULT_BWRATES"$'\n'"$DEFAULT_BWRATES"
  [ "$status" -ne 0 ]
}

@test "legacy bandwidth conversion uses the exact historical class reorder" {
  local legacy expected
  legacy='<1>2>3>4>5>6>7>8<11>12>13>14>15>16>17>18<21>22>23>24>25>26>27>28<31>32>33>34>35>36>37>38'
  expected='<1>3>6>2>5>8>4>7<11>13>16>12>15>18>14>17<21>23>26>22>25>28>24>27<31>33>36>32>35>38>34>37'
  run _config_convert_legacy_bandwidth "$legacy"
  [ "$status" -eq 0 ]
  assert_equal "$expected" "$output"
}

@test "default config is exact and causes no migration side effects" {
  get_config
  assert_equal "$DEFAULT_IPTABLES" "$iptables_rules"
  assert_equal "$DEFAULT_APPDB" "$appdb_rules"
  assert_equal "$DEFAULT_BWRATES" "$bwrates"
  assert_equal "0" "$fccontrol"
  [ ! -s "$SETTINGS_SET_LOG" ]
  [ ! -s "$SED_LOG" ]
  [ ! -s "$LOGMSG_LOG" ]
}

@test "valid persisted settings take precedence without touching legacy bandwidth" {
  SET_IPTABLES='<>>tcp>>443>>5'
  SET_APPDB='<1400C5>4'
  SET_BWRATES='<1>2>3>4>5>6>7>8<9>10>11>12>13>14>15>16<17>18>19>20>21>22>23>24<93>94>95>96>97>98>99>100'
  SET_BANDWIDTH='<99>99>99>99>99>99>99>99<99>99>99>99>99>99>99>99<99>99>99>99>99>99>99>99<99>99>99>99>99>99>99>99'
  SET_FCCONTROL='2'

  get_config

  assert_equal "$SET_IPTABLES" "$iptables_rules"
  assert_equal "$SET_APPDB" "$appdb_rules"
  assert_equal "$SET_BWRATES" "$bwrates"
  assert_equal "2" "$fccontrol"
  [ ! -s "$SETTINGS_SET_LOG" ]
  [ ! -s "$SED_LOG" ]
  [ ! -s "$LOGMSG_LOG" ]
}

@test "explicit zero iptables setting disables defaults" {
  SET_IPTABLES='0'
  get_config
  assert_equal "" "$iptables_rules"
}

@test "invalid persisted bwrates falls back to defaults and is reported" {
  SET_BWRATES='<0>2>3>4>5>6>7>8<9>10>11>12>13>14>15>16<17>18>19>20>21>22>23>24<25>26>27>28>29>30>31>32'
  get_config
  assert_equal "$DEFAULT_BWRATES" "$bwrates"
  assert_equal 'Ignoring invalid flexqos_bwrates setting' "$(cat "$LOGMSG_LOG")"
  [ ! -s "$SETTINGS_SET_LOG" ]
  [ ! -s "$SED_LOG" ]
}

@test "valid nondefault legacy bandwidth migrates once then deletes only legacy key" {
  SET_BANDWIDTH='<1>2>3>4>5>6>7>8<11>12>13>14>15>16>17>18<21>22>23>24>25>26>27>28<31>32>33>34>35>36>37>38'
  local expected
  expected='<1>3>6>2>5>8>4>7<11>13>16>12>15>18>14>17<21>23>26>22>25>28>24>27<31>33>36>32>35>38>34>37'

  get_config

  assert_equal "$expected" "$bwrates"
  assert_equal "flexqos_bwrates=$expected" "$(cat "$SETTINGS_SET_LOG")"
  assert_equal '-i /^flexqos_bandwidth /d /jffs/addons/custom_settings.txt' "$(cat "$SED_LOG")"
  [ ! -s "$LOGMSG_LOG" ]
}

@test "legacy default bandwidth is normalized implicitly without storing redundant bwrates" {
  SET_BANDWIDTH='<5>20>15>10>10>30>5>5<100>100>100>100>100>100>100>100<5>20>15>30>10>10>5>5<100>100>100>100>100>100>100>100'
  get_config
  assert_equal "$DEFAULT_BWRATES" "$bwrates"
  [ ! -s "$SETTINGS_SET_LOG" ]
  assert_equal '-i /^flexqos_bandwidth /d /jffs/addons/custom_settings.txt' "$(cat "$SED_LOG")"
}

@test "malformed legacy bandwidth is preserved and never migrated" {
  SET_BANDWIDTH='<1>2>3'
  get_config
  assert_equal "$DEFAULT_BWRATES" "$bwrates"
  [ ! -s "$SETTINGS_SET_LOG" ]
  [ ! -s "$SED_LOG" ]
  assert_equal 'Ignoring invalid flexqos_bandwidth setting' "$(cat "$LOGMSG_LOG")"
}

@test "invalid current bwrates can recover from a valid legacy setting" {
  SET_BWRATES='<bad>'
  SET_BANDWIDTH='<1>2>3>4>5>6>7>8<11>12>13>14>15>16>17>18<21>22>23>24>25>26>27>28<31>32>33>34>35>36>37>38'
  local expected
  expected='<1>3>6>2>5>8>4>7<11>13>16>12>15>18>14>17<21>23>26>22>25>28>24>27<31>33>36>32>35>38>34>37'
  get_config
  assert_equal "$expected" "$bwrates"
  assert_equal "flexqos_bwrates=$expected" "$(cat "$SETTINGS_SET_LOG")"
  assert_equal '-i /^flexqos_bandwidth /d /jffs/addons/custom_settings.txt' "$(cat "$SED_LOG")"
  assert_equal 'Ignoring invalid flexqos_bwrates setting' "$(cat "$LOGMSG_LOG")"
}

@test "flow-cache control accepts only the three supported modes" {
  local value
  for value in 0 1 2; do
    SET_FCCONTROL="$value"
    : > "$LOGMSG_LOG"
    get_config
    assert_equal "$value" "$fccontrol"
    [ ! -s "$LOGMSG_LOG" ]
  done

  for value in -1 3 yes garbage; do
    SET_FCCONTROL="$value"
    : > "$LOGMSG_LOG"
    get_config
    assert_equal "0" "$fccontrol"
    assert_equal 'Ignoring invalid flexqos_fccontrol setting' "$(cat "$LOGMSG_LOG")"
  done
}
