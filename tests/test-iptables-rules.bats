#!/usr/bin/env bats

load_flexqos_functions() {
  local extracted="$BATS_TEST_TMPDIR/flexqos-functions.sh"

  python3 - "$PROJECT_ROOT/flexqos.sh" > "$extracted" <<'PY'
import re
import sys
from collections import Counter
from pathlib import Path

wanted = {
    "get_class_mark",
    "Is_Valid_CIDR",
    "Is_Valid_Port",
    "Is_Valid_Mark",
    "format_negated_arg",
    "format_ipset_arg",
    "create_ipset",
    "parse_iptablerule",
    "normalize_iptables_rules",
    "write_iptables_rules",
    "validate_iptables_rules",
}

lines = Path(sys.argv[1]).read_text().splitlines(keepends=True)
starts = []
for i, line in enumerate(lines):
    match = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\(\) \{$', line.rstrip('\n'))
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
  SCRIPTNAME_DISPLAY="FlexQoS"
  IPv6_enabled="disabled"
  iptables_rules=""
  lan="br0"

  Net_mark="09"
  Work_mark="06"
  Gaming_mark="08"
  Others_mark="0a"
  Web_mark="18"
  Streaming_mark="04"
  Downloads_mark="03"
  Learn_mark="3f"

  IPSET_LOG="$BATS_TEST_TMPDIR/ipset.log"
  IPTABLES_EXEC_LOG="$BATS_TEST_TMPDIR/iptables.log"
  NVRAM_LOG="$BATS_TEST_TMPDIR/nvram.log"
  : > "$IPSET_LOG"
  : > "$IPTABLES_EXEC_LOG"
  : > "$NVRAM_LOG"

  IPV4_DOWN_STATE=""
  IPV4_UP_STATE=""
  IPV6_DOWN_STATE=""
  IPV6_UP_STATE=""
  IPTABLES_S_FAIL=0
  IP6TABLES_S_FAIL=0

  load_flexqos_functions
}

teardown() {
  rm -f "/tmp/${SCRIPTNAME}_iprules"
}

nvram() {
  [ "${1:-}" = "get" ] || return 2
  printf '%s\n' "${2:-}" >> "$NVRAM_LOG"
  case "${2:-}" in
    ipv6_autoconf_type) printf '0\n' ;;
    dhcp_lease) printf '86400\n' ;;
    ipv6_dhcp_lifetime) printf '3600\n' ;;
    *) printf '\n' ;;
  esac
}

ipset() {
  printf '%s\n' "$*" >> "$IPSET_LOG"
  return 0
}

iptables() {
  case "$*" in
    "-t mangle -S ${SCRIPTNAME_DISPLAY}_down")
      [ "$IPTABLES_S_FAIL" -eq 0 ] || return "$IPTABLES_S_FAIL"
      [ -z "$IPV4_DOWN_STATE" ] || printf '%s\n' "$IPV4_DOWN_STATE"
      ;;
    "-t mangle -S ${SCRIPTNAME_DISPLAY}_up")
      [ "$IPTABLES_S_FAIL" -eq 0 ] || return "$IPTABLES_S_FAIL"
      [ -z "$IPV4_UP_STATE" ] || printf '%s\n' "$IPV4_UP_STATE"
      ;;
    *)
      printf 'iptables %s\n' "$*" >> "$IPTABLES_EXEC_LOG"
      ;;
  esac
  return 0
}

ip6tables() {
  case "$*" in
    "-t mangle -S ${SCRIPTNAME_DISPLAY}_down")
      [ "$IP6TABLES_S_FAIL" -eq 0 ] || return "$IP6TABLES_S_FAIL"
      [ -z "$IPV6_DOWN_STATE" ] || printf '%s\n' "$IPV6_DOWN_STATE"
      ;;
    "-t mangle -S ${SCRIPTNAME_DISPLAY}_up")
      [ "$IP6TABLES_S_FAIL" -eq 0 ] || return "$IP6TABLES_S_FAIL"
      [ -z "$IPV6_UP_STATE" ] || printf '%s\n' "$IPV6_UP_STATE"
      ;;
    *)
      printf 'ip6tables %s\n' "$*" >> "$IPTABLES_EXEC_LOG"
      ;;
  esac
  return 0
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

valid_cidr() {
  printf '%s\n' "$1" | Is_Valid_CIDR
}

valid_port() {
  printf '%s\n' "$1" | Is_Valid_Port
}

valid_mark() {
  printf '%s\n' "$1" | Is_Valid_Mark
}

canonical_file() {
  sed -E 's/[[:space:]]+/ /g; s/[[:space:]]+$//' "/tmp/${SCRIPTNAME}_iprules"
}

canonical_appends() {
  canonical_file | /bin/grep -E '^ip6?tables -t mangle -A ' || true
}

count_generated() {
  canonical_file | /bin/grep -cE "$1" || true
}

state_from_generated() {
  local binary="$1" chain="$2"
  canonical_file |
    /bin/grep -E "^${binary} -t mangle -A ${chain} " |
    sed -E "s/^${binary} -t mangle //" || true
}

reverse_lines() {
  awk '{ line[NR]=$0 } END { for (i=NR; i>=1; i--) print line[i] }'
}

set_chain_counts() {
  local down4="$1" up4="$2" down6="$3" up6="$4" i
  IPV4_DOWN_STATE=""
  IPV4_UP_STATE=""
  IPV6_DOWN_STATE=""
  IPV6_UP_STATE=""
  for ((i=0; i<down4; i++)); do IPV4_DOWN_STATE+="-A ${SCRIPTNAME_DISPLAY}_down -p tcp -j MARK"$'\n'; done
  for ((i=0; i<up4; i++)); do IPV4_UP_STATE+="-A ${SCRIPTNAME_DISPLAY}_up -p tcp -j MARK"$'\n'; done
  for ((i=0; i<down6; i++)); do IPV6_DOWN_STATE+="-A ${SCRIPTNAME_DISPLAY}_down -p tcp -j MARK"$'\n'; done
  for ((i=0; i<up6; i++)); do IPV6_UP_STATE+="-A ${SCRIPTNAME_DISPLAY}_up -p tcp -j MARK"$'\n'; done
  IPV4_DOWN_STATE="${IPV4_DOWN_STATE%$'\n'}"
  IPV4_UP_STATE="${IPV4_UP_STATE%$'\n'}"
  IPV6_DOWN_STATE="${IPV6_DOWN_STATE%$'\n'}"
  IPV6_UP_STATE="${IPV6_UP_STATE%$'\n'}"
}

set_exact_chain_state() {
  write_iptables_rules validate
  IPV4_DOWN_STATE="$(state_from_generated iptables "${SCRIPTNAME_DISPLAY}_down")"
  IPV4_UP_STATE="$(state_from_generated iptables "${SCRIPTNAME_DISPLAY}_up")"
  IPV6_DOWN_STATE="$(state_from_generated ip6tables "${SCRIPTNAME_DISPLAY}_down")"
  IPV6_UP_STATE="$(state_from_generated ip6tables "${SCRIPTNAME_DISPLAY}_up")"
}

@test "class destination mapping matches FlexQoS marks exactly" {
  local expected actual class
  expected=$'09\n08\n04\n06\n18\n03\n0a\n3f'
  actual=""
  for class in 0 1 2 3 4 5 6 7; do
    actual+="$(get_class_mark "$class")"$'\n'
  done
  actual="${actual%$'\n'}"
  assert_equal "$expected" "$actual"
  assert_equal "" "$(get_class_mark 8)"
  assert_equal "" "$(get_class_mark garbage)"
}

@test "CIDR validator accepts normal IPv4 and negated CIDR forms" {
  local value
  for value in 1.1.1.1 192.168.1.100 255.255.255.254/32 9.9.9.0/24 '!192.168.1.100/31'; do
    run valid_cidr "$value"
    assert_success
  done
}

@test "CIDR validator rejects out-of-range octets and prefixes" {
  local value
  for value in 256.1.1.1 999.999.999.999 192.168.1.1/33 192.168.1.1/99; do
    run valid_cidr "$value"
    assert_failure
  done
}

@test "port validator accepts legal singles, ranges, lists and negation" {
  local value
  for value in 1 65535 80:443 53,123,853 '!443' '!53,123,853'; do
    run valid_port "$value"
    assert_success
  done
}

@test "port validator rejects illegal ranges, bounds and oversized multiport lists" {
  local value
  for value in 0 65536 443:80 1:65536 '1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16'; do
    run valid_port "$value"
    assert_failure
  done
}

@test "mark validator accepts exact and wildcard forms and rejects malformed marks" {
  local value
  for value in 1400C5 14**** '!1400C5' '!14****'; do
    run valid_mark "$value"
    assert_success
  done
  for value in 1400C 1400C55 '1*****' 'ZZ0000' '14**00'; do
    run valid_mark "$value"
    assert_failure
  done
}

@test "negated argument formatting is exact" {
  assert_equal '-d 192.168.1.2' "$(format_negated_arg 192.168.1.2 -d | sed -E 's/^ +//')"
  assert_equal '! -d 192.168.1.2' "$(format_negated_arg '!192.168.1.2' -d)"
  assert_equal '--dports 443' "$(format_negated_arg 443 --dports | sed -E 's/^ +//')"
  assert_equal '! --dports 443' "$(format_negated_arg '!443' --dports)"
}

@test "IPv6 ipset argument formatting preserves direction and negation" {
  assert_equal '-m set --match-set 192.168.1.2 dst' "$(format_ipset_arg 192.168.1.2 dst)"
  assert_equal '-m set ! --match-set 192.168.1.2 src' "$(format_ipset_arg '!192.168.1.2' src)"
}

@test "remote TCP port rule generates exact down and up commands" {
  local expected
  iptables_rules='<>>tcp>>443>>5'
  write_iptables_rules validate
  expected=$'iptables -t mangle -A FlexQoS_down -p tcp -m multiport --sports 443 -j MARK --set-mark 0x8003ffff/0xc03fffff\niptables -t mangle -A FlexQoS_up -p tcp -m multiport --dports 443 -j MARK --set-mark 0x4003ffff/0xc03fffff'
  assert_equal "$expected" "$(canonical_appends)"
}

@test "port-based both rule expands in deterministic TCP then UDP order" {
  local expected
  iptables_rules='<>>both>>443>>5'
  write_iptables_rules validate
  expected=$'iptables -t mangle -A FlexQoS_down -p tcp -m multiport --sports 443 -j MARK --set-mark 0x8003ffff/0xc03fffff\niptables -t mangle -A FlexQoS_up -p tcp -m multiport --dports 443 -j MARK --set-mark 0x4003ffff/0xc03fffff\niptables -t mangle -A FlexQoS_down -p udp -m multiport --sports 443 -j MARK --set-mark 0x8003ffff/0xc03fffff\niptables -t mangle -A FlexQoS_up -p udp -m multiport --dports 443 -j MARK --set-mark 0x4003ffff/0xc03fffff'
  assert_equal "$expected" "$(canonical_appends)"
}

@test "port-based both rule expands even for a one-digit port" {
  iptables_rules='<>>both>>5>>5'
  write_iptables_rules validate
  [ "$(count_generated '^iptables -t mangle -A FlexQoS_down ')" -eq 2 ]
  [ "$(count_generated '^iptables -t mangle -A FlexQoS_up ')" -eq 2 ]
  [[ "$(canonical_appends)" == *'-p tcp '* ]]
  [[ "$(canonical_appends)" == *'-p udp '* ]]
}

@test "local and remote endpoints map to correct directions" {
  local expected
  iptables_rules='<192.168.1.2>9.9.9.9>udp>53>123>>3'
  write_iptables_rules validate
  expected=$'iptables -t mangle -A FlexQoS_down -d 192.168.1.2 -s 9.9.9.9 -p udp -m multiport --dports 53 -m multiport --sports 123 -j MARK --set-mark 0x8006ffff/0xc03fffff\niptables -t mangle -A FlexQoS_up -s 192.168.1.2 -d 9.9.9.9 -p udp -m multiport --sports 53 -m multiport --dports 123 -j MARK --set-mark 0x4006ffff/0xc03fffff'
  assert_equal "$expected" "$(canonical_appends)"
}

@test "remote IPv4 criteria suppress IPv6 generation" {
  IPv6_enabled="native"
  iptables_rules='<>9.9.9.9>tcp>>>>5'
  write_iptables_rules validate
  [ "$(count_generated '^iptables -t mangle -A FlexQoS_down ')" -eq 1 ]
  [ "$(count_generated '^ip6tables -t mangle -A FlexQoS_down ')" -eq 0 ]
}

@test "IPv6 local address translation uses matching ipset directions" {
  local appends
  IPv6_enabled="native"
  iptables_rules='<192.168.1.2>>tcp>>>>5'
  write_iptables_rules validate
  appends="$(canonical_appends)"
  [[ "$appends" == *'ip6tables -t mangle -A FlexQoS_down -m set --match-set 192.168.1.2 dst -p tcp'* ]]
  [[ "$appends" == *'ip6tables -t mangle -A FlexQoS_up -m set --match-set 192.168.1.2 src -p tcp'* ]]
}

@test "negated IP port and mark criteria preserve negation in generated commands" {
  local rules
  iptables_rules='<!192.168.1.2>9.9.9.9>tcp>!443>!853>!1400C5>6'
  write_iptables_rules validate
  rules="$(canonical_appends)"
  [[ "$rules" == *'! -d 192.168.1.2'* ]]
  [[ "$rules" == *'! --dports 443'* ]]
  [[ "$rules" == *'! --sports 853'* ]]
  [[ "$rules" == *'-m mark ! --mark 0x801400C5/0xc03fffff'* ]]
}

@test "wildcard AppDB mark uses category mask exactly" {
  local rules
  iptables_rules='<>>tcp>>>14****>6'
  write_iptables_rules validate
  rules="$(canonical_appends)"
  [[ "$rules" == *'-m mark --mark 0x80140000/0xc03f0000'* ]]
  [[ "$rules" == *'-m mark --mark 0x40140000/0xc03f0000'* ]]
}

@test "invalid class produces no append rule" {
  iptables_rules='<>>tcp>>443>>99'
  write_iptables_rules validate
  assert_equal "" "$(canonical_appends)"
}

@test "invalid protocol is rejected instead of silently changing semantics" {
  iptables_rules='<>>sctp>>443>>5'
  write_iptables_rules validate
  assert_equal "" "$(canonical_appends)"
}

@test "invalid nonempty criteria reject the record instead of broadening it" {
  iptables_rules='<not-an-ip>>tcp>>443>>5'
  write_iptables_rules validate
  assert_equal "" "$(canonical_appends)"

  iptables_rules='<192.168.1.2>not-an-ip>tcp>>443>>5'
  write_iptables_rules validate
  assert_equal "" "$(canonical_appends)"

  iptables_rules='<192.168.1.2>>tcp>bad-port>>>5'
  write_iptables_rules validate
  assert_equal "" "$(canonical_appends)"

  iptables_rules='<192.168.1.2>>tcp>>>ZZZZZZ>5'
  write_iptables_rules validate
  assert_equal "" "$(canonical_appends)"
}

@test "multiple records preserve configured order" {
  local rules first second
  iptables_rules='<>>tcp>>443>>5<>>udp>>53>>0'
  write_iptables_rules validate
  rules="$(canonical_appends)"
  first="$(printf '%s\n' "$rules" | sed -n '1p')"
  second="$(printf '%s\n' "$rules" | sed -n '3p')"
  [[ "$first" == *'-p tcp '* ]]
  [[ "$second" == *'-p udp '* ]]
}

@test "iptables rule normalization handles xtables serialization differences" {
  local input expected
  input='-A FlexQoS_down -s 192.168.1.5/24 -p all -j MARK --set-xmark 0x8003ffff/0xc03fffff'
  expected='-A FlexQoS_down -s 192.168.1.0/24 -j MARK --set-mark 0x8003ffff/0xc03fffff'
  assert_equal "$expected" "$(printf '%s\n' "$input" | normalize_iptables_rules)"

  input='-A FlexQoS_down -d 192.168.1.2/32 -p tcp -j MARK --set-mark 0x8003ffff/0xc03fffff'
  expected='-A FlexQoS_down -d 192.168.1.2 -p tcp -j MARK --set-mark 0x8003ffff/0xc03fffff'
  assert_equal "$expected" "$(printf '%s\n' "$input" | normalize_iptables_rules)"
}

@test "generated rule file is valid shell syntax" {
  IPv6_enabled="native"
  iptables_rules='<!192.168.1.2>>both>!443>53,123>!14****>6'
  write_iptables_rules validate
  run sh -n "/tmp/${SCRIPTNAME}_iprules"
  assert_success
}

@test "apply generation executes real create_ipset behavior against mocks" {
  local expected_ipsets
  IPv6_enabled="native"
  iptables_rules='<192.168.1.2>>tcp>>>>5'
  write_iptables_rules

  expected_ipsets=$'-! create 192.168.1.2-mac hash:mac timeout 86400\n-! flush 192.168.1.2-mac\n-! create 192.168.1.2 hash:ip family inet6 timeout 600\n-! flush 192.168.1.2'
  assert_equal "$expected_ipsets" "$(cat "$IPSET_LOG")"
  [[ "$(canonical_file)" == *'iptables -t mangle -I PREROUTING -i br0 -m conntrack --ctstate NEW -s 192.168.1.2 -j SET --add-set 192.168.1.2-mac src --exist'* ]]
  [[ "$(canonical_file)" == *'ip6tables -t mangle -I PREROUTING -i br0 -m conntrack --ctstate NEW -m set --match-set 192.168.1.2-mac src -j SET --add-set 192.168.1.2 src --exist'* ]]
}

@test "generated apply file executes flushes and appends against command mocks" {
  iptables_rules='<>>tcp>>443>>5'
  write_iptables_rules validate
  : > "$IPTABLES_EXEC_LOG"

  # shellcheck source=/dev/null
  source "/tmp/${SCRIPTNAME}_iprules"

  [ "$(wc -l < "$IPTABLES_EXEC_LOG")" -eq 4 ]
  assert_equal 'iptables -t mangle -F FlexQoS_down' "$(sed -n '1p' "$IPTABLES_EXEC_LOG")"
  assert_equal 'iptables -t mangle -F FlexQoS_up' "$(sed -n '2p' "$IPTABLES_EXEC_LOG")"
  [[ "$(sed -n '3p' "$IPTABLES_EXEC_LOG")" == 'iptables -t mangle -A FlexQoS_down '* ]]
  [[ "$(sed -n '4p' "$IPTABLES_EXEC_LOG")" == 'iptables -t mangle -A FlexQoS_up '* ]]
}

@test "validation generation has no ipset or nvram side effects" {
  IPv6_enabled="native"
  iptables_rules='<192.168.1.2>>tcp>>>>5'
  write_iptables_rules validate
  [ ! -s "$IPSET_LOG" ]
  [ ! -s "$NVRAM_LOG" ]
}

@test "empty configuration produces only IPv4 flushes when IPv6 is disabled" {
  local expected
  iptables_rules=""
  write_iptables_rules validate
  expected=$'iptables -t mangle -F FlexQoS_down 2>/dev/null\niptables -t mangle -F FlexQoS_up 2>/dev/null'
  assert_equal "$expected" "$(canonical_file)"
}

@test "empty configuration includes IPv6 flushes when IPv6 is enabled" {
  IPv6_enabled="native"
  iptables_rules=""
  write_iptables_rules validate
  [ "$(count_generated '^iptables -t mangle -F FlexQoS_')" -eq 2 ]
  [ "$(count_generated '^ip6tables -t mangle -F FlexQoS_')" -eq 2 ]
  [ "$(count_generated '^-A ')" -eq 0 ]
}

@test "validator accepts exact generated IPv4 state" {
  iptables_rules='<>>tcp>>443>>5'
  set_exact_chain_state
  run validate_iptables_rules
  assert_success
}

@test "validator rejects missing and extra rules in either IPv4 direction" {
  iptables_rules='<>>tcp>>443>>5'
  set_exact_chain_state
  IPV4_DOWN_STATE=""
  run validate_iptables_rules
  assert_failure

  set_exact_chain_state
  IPV4_UP_STATE=""
  run validate_iptables_rules
  assert_failure

  set_exact_chain_state
  IPV4_DOWN_STATE="${IPV4_DOWN_STATE}"$'\n'"${IPV4_DOWN_STATE}"
  run validate_iptables_rules
  assert_failure

  set_exact_chain_state
  IPV4_UP_STATE="${IPV4_UP_STATE}"$'\n'"${IPV4_UP_STATE}"
  run validate_iptables_rules
  assert_failure
}

@test "validator checks both IPv6 directions when enabled" {
  IPv6_enabled="native"
  iptables_rules='<>>both>>443>>5'
  set_exact_chain_state
  run validate_iptables_rules
  assert_success

  set_exact_chain_state
  IPV6_DOWN_STATE="$(printf '%s\n' "$IPV6_DOWN_STATE" | sed '$d')"
  run validate_iptables_rules
  assert_failure

  set_exact_chain_state
  IPV6_UP_STATE="$(printf '%s\n' "$IPV6_UP_STATE" | sed '$d')"
  run validate_iptables_rules
  assert_failure
}

@test "validator detects stale rules when custom rules are disabled" {
  iptables_rules=""
  set_chain_counts 1 0 0 0
  run validate_iptables_rules
  assert_failure
}

@test "validator removes its generated temporary file on success and failure" {
  iptables_rules='<>>tcp>>443>>5'
  set_exact_chain_state
  run validate_iptables_rules
  assert_success
  [ ! -e "/tmp/${SCRIPTNAME}_iprules" ]

  set_exact_chain_state
  IPV4_DOWN_STATE=""
  run validate_iptables_rules
  assert_failure
  [ ! -e "/tmp/${SCRIPTNAME}_iprules" ]
}

@test "validator rejects same-count state with wrong rule contents" {
  iptables_rules='<>>tcp>>443>>5'
  set_exact_chain_state
  IPV4_DOWN_STATE='-A FlexQoS_down -p udp -j MARK --set-mark 0xdeadbeef'
  run validate_iptables_rules
  assert_failure
}

@test "validator rejects same-count state with wrong rule order" {
  iptables_rules='<>>tcp>>443>>5<>>udp>>53>>0'
  set_exact_chain_state
  IPV4_DOWN_STATE="$(printf '%s\n' "$IPV4_DOWN_STATE" | reverse_lines)"
  run validate_iptables_rules
  assert_failure
}

@test "validator fails closed when iptables state cannot be inspected" {
  iptables_rules=""
  IPTABLES_S_FAIL=2
  run validate_iptables_rules
  assert_failure
}

@test "validator fails closed when ip6tables state cannot be inspected" {
  IPv6_enabled="native"
  iptables_rules=""
  IP6TABLES_S_FAIL=2
  run validate_iptables_rules
  assert_failure
}
