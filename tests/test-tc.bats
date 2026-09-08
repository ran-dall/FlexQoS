#!/usr/bin/env bats

load_flexqos_functions() {
  local extracted="$BATS_TEST_TMPDIR/flexqos-tc-functions.sh"

  python3 - "$PROJECT_ROOT/flexqos.sh" > "$extracted" <<'PY'
import re
import sys
from collections import Counter
from pathlib import Path

wanted = {
    "get_static_filter",
    "write_appdb_static_rules",
    "init_tc_cache",
    "ensure_tc_variables",
    "get_burst",
    "get_cburst",
    "get_quantum",
    "get_overhead",
    "get_custom_rate_rule",
    "write_custom_rates",
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
  case "${1:-}" in
    *_qdisc) printf '%s\n' "$SETTINGS_QDISC" ;;
    *) printf '\n' ;;
  esac
}

nvram() {
  case "${1:-}:${2:-}" in
    get:qos_overhead) printf '%s\n' "$NVRAM_QOS_OVERHEAD" ;;
    get:qos_atm) printf '%s\n' "$NVRAM_QOS_ATM" ;;
    *) printf '\n' ;;
  esac
}

setup() {
  set -u -o pipefail

  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTNAME="flexqos-tc-${BATS_TEST_NUMBER}"
  RULE_FILE="/tmp/${SCRIPTNAME}_tcrules"
  WANMTU=1500
  SETTINGS_QDISC="1"
  NVRAM_QOS_OVERHEAD=""
  NVRAM_QOS_ATM="0"

  tclan="br0"
  tcwan="eth0"
  DownCeil=100000
  UpCeil=50000
  MIN_PACKET=1749
  QDISC=1
  HTB_OVERHEAD=""
  bwrates="configured"
  iptables_rules="configured"

  Net_mark="09"
  Work_mark="06"
  Gaming_mark="08"
  Others_mark="0a"
  Web_mark="18"
  Streaming_mark="04"
  Downloads_mark="03"
  Learn_mark="3f"

  Net_flow="1:10"
  Work_flow="1:11"
  Gaming_flow="1:12"
  Others_flow="1:13"
  Web_flow="1:14"
  Streaming_flow="1:15"
  Downloads_flow="1:16"
  Learn_flow="1:17"

  load_flexqos_functions
  rm -f "$RULE_FILE"
}

teardown() {
  rm -f "$RULE_FILE"
}

@test "tc cache selects ASUS qdisc and exact ATM overhead metadata" {
  SETTINGS_QDISC="0"
  NVRAM_QOS_OVERHEAD="42"
  NVRAM_QOS_ATM="1"
  WANMTU=1500

  init_tc_cache

  [ "$QDISC" = "0" ]
  [ "$MIN_PACKET" = "1749" ]
  [ "$HTB_OVERHEAD" = "overhead 42 linklayer atm" ]
}

@test "tc cache defaults unknown qdisc values to fq_codel and ethernet overhead" {
  SETTINGS_QDISC="unexpected"
  NVRAM_QOS_OVERHEAD="18"
  NVRAM_QOS_ATM="0"

  init_tc_cache

  [ "$QDISC" = "1" ]
  [ "$MIN_PACKET" = "1749" ]
  [ "$HTB_OVERHEAD" = "overhead 18 linklayer ethernet" ]
}

@test "tc cache ignores zero and negative overhead values" {
  for overhead in 0 -1 -127; do
    NVRAM_QOS_OVERHEAD="$overhead"
    HTB_OVERHEAD="stale"
    init_tc_cache
    [ "$HTB_OVERHEAD" = "" ]
  done
}

@test "burst calculation clamps to qdisc-specific minimums and preserves larger values" {
  MIN_PACKET=1749
  QDISC=1
  [ "$(get_burst 1000 1000)" = "1749" ]
  [ "$(get_burst 80000 1000)" = "10000" ]

  QDISC=0
  [ "$(get_burst 1000 1000)" = "3200" ]
  [ "$(get_burst 80000 1000)" = "10000" ]
}

@test "cburst calculation clamps to qdisc-specific minimums and preserves larger values" {
  MIN_PACKET=1749
  QDISC=1
  [ "$(get_cburst 1000)" = "1749" ]
  [ "$(get_cburst 10000)" = "11200" ]

  QDISC=0
  [ "$(get_cburst 1000)" = "3200" ]
  [ "$(get_cburst 10000)" = "11200" ]
}

@test "fq_codel cburst never falls below a jumbo-frame minimum packet" {
  WANMTU=9000
  SETTINGS_QDISC="1"
  init_tc_cache
  [ "$MIN_PACKET" = "10017" ]

  [ "$(get_cburst 5120)" = "10017" ]
}

@test "quantum calculation clamps to packet minimum and preserves larger values" {
  MIN_PACKET=1749
  [ "$(get_quantum 100)" = "1749" ]
  [ "$(get_quantum 1000)" = "12500" ]

  MIN_PACKET=10017
  [ "$(get_quantum 500)" = "10017" ]
}

@test "custom HTB rule serialization is exact with ATM overhead" {
  QDISC=1
  MIN_PACKET=1749
  HTB_OVERHEAD="overhead 42 linklayer atm"

  run get_custom_rate_rule br0 3 5000 10000

  [ "$status" -eq 0 ]
  [ "$output" = "class change dev br0 parent 1:1 classid 1:13 htb overhead 42 linklayer atm prio 3 rate 5000Kbit ceil 10000Kbit burst 1749b cburst 11200b quantum 62500" ]
}

@test "custom HTB rule serialization is exact without overhead" {
  QDISC=0
  MIN_PACKET=1749
  HTB_OVERHEAD=""

  run get_custom_rate_rule eth0 7 100 1000

  [ "$status" -eq 0 ]
  [ "$output" = "class change dev eth0 parent 1:1 classid 1:17 htb  prio 7 rate 100Kbit ceil 1000Kbit burst 3200b cburst 3200b quantum 1749" ]
}

@test "static AppDB filters are emitted in exact class and interface order" {
  write_appdb_static_rules

  run cat "$RULE_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = "filter add dev br0 protocol all prio 5 u32 match mark 0x8009ffff 0xc03fffff flowid 1:10
filter add dev eth0 protocol all prio 5 u32 match mark 0x4009ffff 0xc03fffff flowid 1:10
filter add dev br0 protocol all prio 5 u32 match mark 0x8006ffff 0xc03fffff flowid 1:11
filter add dev eth0 protocol all prio 5 u32 match mark 0x4006ffff 0xc03fffff flowid 1:11
filter add dev br0 protocol all prio 5 u32 match mark 0x8008ffff 0xc03fffff flowid 1:12
filter add dev eth0 protocol all prio 5 u32 match mark 0x4008ffff 0xc03fffff flowid 1:12
filter add dev br0 protocol all prio 5 u32 match mark 0x800affff 0xc03fffff flowid 1:13
filter add dev eth0 protocol all prio 5 u32 match mark 0x400affff 0xc03fffff flowid 1:13
filter add dev br0 protocol all prio 5 u32 match mark 0x8018ffff 0xc03fffff flowid 1:14
filter add dev eth0 protocol all prio 5 u32 match mark 0x4018ffff 0xc03fffff flowid 1:14
filter add dev br0 protocol all prio 5 u32 match mark 0x8004ffff 0xc03fffff flowid 1:15
filter add dev eth0 protocol all prio 5 u32 match mark 0x4004ffff 0xc03fffff flowid 1:15
filter add dev br0 protocol all prio 5 u32 match mark 0x8003ffff 0xc03fffff flowid 1:16
filter add dev eth0 protocol all prio 5 u32 match mark 0x4003ffff 0xc03fffff flowid 1:16
filter add dev br0 protocol all prio 5 u32 match mark 0x803fffff 0xc03fffff flowid 1:17
filter add dev eth0 protocol all prio 5 u32 match mark 0x403fffff 0xc03fffff flowid 1:17" ]
}

@test "no configured iptables rules produces an empty static TC file" {
  iptables_rules=""

  write_appdb_static_rules

  [ -f "$RULE_FILE" ]
  [ ! -s "$RULE_FILE" ]
}

@test "custom rates emit exactly sixteen deterministic class changes" {
  for i in 0 1 2 3 4 5 6 7; do
    eval "DownRate${i}=1000"
    eval "DownCeil${i}=2000"
    eval "UpRate${i}=500"
    eval "UpCeil${i}=1000"
  done
  DownCeil=2000
  UpCeil=1000
  QDISC=1
  MIN_PACKET=1749
  HTB_OVERHEAD=""
  : > "$RULE_FILE"

  write_custom_rates

  run cat "$RULE_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = "class change dev br0 parent 1:1 classid 1:10 htb  prio 0 rate 1000Kbit ceil 2000Kbit burst 1749b cburst 1749b quantum 12500
class change dev eth0 parent 1:1 classid 1:10 htb  prio 0 rate 500Kbit ceil 1000Kbit burst 1749b cburst 1749b quantum 6250
class change dev br0 parent 1:1 classid 1:11 htb  prio 1 rate 1000Kbit ceil 2000Kbit burst 1749b cburst 1749b quantum 12500
class change dev eth0 parent 1:1 classid 1:11 htb  prio 1 rate 500Kbit ceil 1000Kbit burst 1749b cburst 1749b quantum 6250
class change dev br0 parent 1:1 classid 1:12 htb  prio 2 rate 1000Kbit ceil 2000Kbit burst 1749b cburst 1749b quantum 12500
class change dev eth0 parent 1:1 classid 1:12 htb  prio 2 rate 500Kbit ceil 1000Kbit burst 1749b cburst 1749b quantum 6250
class change dev br0 parent 1:1 classid 1:13 htb  prio 3 rate 1000Kbit ceil 2000Kbit burst 1749b cburst 1749b quantum 12500
class change dev eth0 parent 1:1 classid 1:13 htb  prio 3 rate 500Kbit ceil 1000Kbit burst 1749b cburst 1749b quantum 6250
class change dev br0 parent 1:1 classid 1:14 htb  prio 4 rate 1000Kbit ceil 2000Kbit burst 1749b cburst 1749b quantum 12500
class change dev eth0 parent 1:1 classid 1:14 htb  prio 4 rate 500Kbit ceil 1000Kbit burst 1749b cburst 1749b quantum 6250
class change dev br0 parent 1:1 classid 1:15 htb  prio 5 rate 1000Kbit ceil 2000Kbit burst 1749b cburst 1749b quantum 12500
class change dev eth0 parent 1:1 classid 1:15 htb  prio 5 rate 500Kbit ceil 1000Kbit burst 1749b cburst 1749b quantum 6250
class change dev br0 parent 1:1 classid 1:16 htb  prio 6 rate 1000Kbit ceil 2000Kbit burst 1749b cburst 1749b quantum 12500
class change dev eth0 parent 1:1 classid 1:16 htb  prio 6 rate 500Kbit ceil 1000Kbit burst 1749b cburst 1749b quantum 6250
class change dev br0 parent 1:1 classid 1:17 htb  prio 7 rate 1000Kbit ceil 2000Kbit burst 1749b cburst 1749b quantum 12500
class change dev eth0 parent 1:1 classid 1:17 htb  prio 7 rate 500Kbit ceil 1000Kbit burst 1749b cburst 1749b quantum 6250" ]
}

@test "automatic bandwidth mode leaves existing TC rate file untouched" {
  DownCeil=0
  UpCeil=0
  printf 'sentinel\n' > "$RULE_FILE"

  write_custom_rates

  run cat "$RULE_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = "sentinel" ]
}
