from pathlib import Path


def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one match, found {count}")
    return text.replace(old, new, 1)


script = Path("flexqos.sh")
text = script.read_text()
start = text.index("get_config() {\n")
end = text.index("\n} # get_config", start) + len("\n} # get_config")
old_get_config = text[start:end]
new_get_config = r'''_config_valid_bwrates() {
	# Four '<' groups, eight '>'-separated integer percentages per group.
	# Reject leading zeroes so later shell arithmetic cannot reinterpret values.
	printf '%s\n' "${1:-}" | awk '
	NR != 1 { exit 1 }
	{
		if ($0 !~ /^</) exit 1
		n = split(substr($0, 2), groups, "<")
		if (n != 4) exit 1
		for (g = 1; g <= 4; g++) {
			m = split(groups[g], values, ">")
			if (m != 8) exit 1
			for (i = 1; i <= 8; i++) {
				if (values[i] !~ /^[1-9][0-9]*$/) exit 1
				if ((values[i] + 0) < 1 || (values[i] + 0) > 100) exit 1
			}
		}
		valid = 1
	}
	END { exit(valid ? 0 : 1) }
	'
} # _config_valid_bwrates

_config_convert_legacy_bandwidth() {
	local drp0 drp1 drp2 drp3 drp4 drp5 drp6 drp7
	local dcp0 dcp1 dcp2 dcp3 dcp4 dcp5 dcp6 dcp7
	local urp0 urp1 urp2 urp3 urp4 urp5 urp6 urp7
	local ucp0 ucp1 ucp2 ucp3 ucp4 ucp5 ucp6 ucp7
	local legacy

	legacy="${1:-}"
	_config_valid_bwrates "${legacy}" || return 1

	read -r \
		drp0 drp1 drp2 drp3 drp4 drp5 drp6 drp7 \
		dcp0 dcp1 dcp2 dcp3 dcp4 dcp5 dcp6 dcp7 \
		urp0 urp1 urp2 urp3 urp4 urp5 urp6 urp7 \
		ucp0 ucp1 ucp2 ucp3 ucp4 ucp5 ucp6 ucp7 \
<<EOF
$(printf '%s\n' "${legacy}" | sed 's/^<//;s/[<>]/ /g')
EOF

	printf '<%s>%s>%s>%s>%s>%s>%s>%s<%s>%s>%s>%s>%s>%s>%s>%s<%s>%s>%s>%s>%s>%s>%s>%s<%s>%s>%s>%s>%s>%s>%s>%s' \
		"${drp0}" "${drp2}" "${drp5}" "${drp1}" "${drp4}" "${drp7}" "${drp3}" "${drp6}" \
		"${dcp0}" "${dcp2}" "${dcp5}" "${dcp1}" "${dcp4}" "${dcp7}" "${dcp3}" "${dcp6}" \
		"${urp0}" "${urp2}" "${urp5}" "${urp1}" "${urp4}" "${urp7}" "${urp3}" "${urp6}" \
		"${ucp0}" "${ucp2}" "${ucp5}" "${ucp1}" "${ucp4}" "${ucp7}" "${ucp3}" "${ucp6}"
} # _config_convert_legacy_bandwidth

get_config() {
	local default_bwrates legacy_bandwidth converted_bwrates

	default_bwrates="<5>15>30>20>10>5>10>5<100>100>100>100>100>100>100>100<5>15>10>20>10>5>30>5<100>100>100>100>100>100>100>100"

	# Read settings from Addon API config file. If not defined, set default values.
	iptables_rules="$(am_settings_get "${SCRIPTNAME}"_iptables)"
	if [ -z "${iptables_rules}" ]; then
		iptables_rules="<>>udp>>500,4500>>3<>>udp>16384:16415>>>3<>>tcp>>119,563>>5<>>tcp>>80,443>08****>5"
	elif [ "${iptables_rules}" = "0" ]; then
		iptables_rules=""
	fi

	appdb_rules="$(am_settings_get "${SCRIPTNAME}"_appdb)"
	if [ -z "${appdb_rules}" ]; then
		appdb_rules="<000000>6<00006B>6<0D0007>5<0D0086>5<0D00A0>5<12003F>4<13****>4<14****>4"
	fi

	bwrates="$(am_settings_get "${SCRIPTNAME}"_bwrates)"
	if [ -n "${bwrates}" ] && ! _config_valid_bwrates "${bwrates}"; then
		logmsg "Ignoring invalid ${SCRIPTNAME}_bwrates setting"
		bwrates=""
	fi

	if [ -z "${bwrates}" ]; then
		legacy_bandwidth="$(am_settings_get "${SCRIPTNAME}"_bandwidth)"
		if [ -z "${legacy_bandwidth}" ]; then
			bwrates="${default_bwrates}"
		elif converted_bwrates="$(_config_convert_legacy_bandwidth "${legacy_bandwidth}")"; then
			bwrates="${converted_bwrates}"
			if [ "${bwrates}" != "${default_bwrates}" ]; then
				am_settings_set "${SCRIPTNAME}"_bwrates "${bwrates}"
			fi
			sed -i "/^${SCRIPTNAME}_bandwidth /d" /jffs/addons/custom_settings.txt
		else
			# Preserve malformed legacy input for recovery instead of deleting it.
			logmsg "Ignoring invalid ${SCRIPTNAME}_bandwidth setting"
			bwrates="${default_bwrates}"
		fi
	fi

	fccontrol="$(am_settings_get "${SCRIPTNAME}"_fccontrol)"
	case "${fccontrol}" in
		0|1|2) ;;
		'') fccontrol="0" ;;
		*)
			logmsg "Ignoring invalid ${SCRIPTNAME}_fccontrol setting"
			fccontrol="0"
			;;
	esac
} # get_config'''
text = text[:start] + new_get_config + text[end:]
script.write_text(text)

Path("tests/test-config.bats").write_text(r'''#!/usr/bin/env bats

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
  SET_BANDWIDTH='<5>20>15>10>10>30>5>5<100>100>100>100>100>100>100>100<5>20>15>10>10>10>5>30<100>100>100>100>100>100>100>100'
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
''')

Path(".mise/tasks/test-config").write_text('''#!/usr/bin/env bash
#MISE description="Run persisted configuration regression tests"

set -euo pipefail

cd "$MISE_PROJECT_ROOT"
bats tests/test-config.bats
''')
Path(".mise/tasks/test-config").chmod(0o755)

check = Path(".mise/tasks/check")
check_text = check.read_text()
check_text = replace_once(
    check_text,
    "  lint-webui\n  test-iptables\n",
    "  lint-webui\n  test-config\n  test-iptables\n",
    "mise config test ordering",
)
check.write_text(check_text)
