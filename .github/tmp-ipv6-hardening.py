from pathlib import Path


def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one match, found {count}")
    return text.replace(old, new, 1)


script = Path("flexqos.sh")
text = script.read_text()

text = replace_once(
    text,
    '''\t\tprintf "iptables -t mangle -F %s 2>/dev/null\\n" "${SCRIPTNAME_DISPLAY}_down"
\t\tprintf "iptables -t mangle -F %s 2>/dev/null\\n" "${SCRIPTNAME_DISPLAY}_up"
\t\tif [ "${IPv6_enabled}" != "disabled" ]; then
\t\t\tprintf "ip6tables -t mangle -F %s 2>/dev/null\\n" "${SCRIPTNAME_DISPLAY}_down"
\t\t\tprintf "ip6tables -t mangle -F %s 2>/dev/null\\n" "${SCRIPTNAME_DISPLAY}_up"
\t\tfi
''',
    '''\t\tprintf "iptables -t mangle -F %s 2>/dev/null\\n" "${SCRIPTNAME_DISPLAY}_down"
\t\tprintf "iptables -t mangle -F %s 2>/dev/null\\n" "${SCRIPTNAME_DISPLAY}_up"
\t\t# Always flush the managed IPv6 chains. If IPv6 was disabled after being
\t\t# active, otherwise-stale FlexQoS rules would survive indefinitely.
\t\tprintf "ip6tables -t mangle -F %s 2>/dev/null\\n" "${SCRIPTNAME_DISPLAY}_down"
\t\tprintf "ip6tables -t mangle -F %s 2>/dev/null\\n" "${SCRIPTNAME_DISPLAY}_up"
''',
    "write IPv6 flushes",
)

text = replace_once(
    text,
    '''\tif [ "${IPv6_enabled}" != "disabled" ]; then
\t\tif ! ipv6_down_raw="$(ip6tables -t mangle -S "${SCRIPTNAME_DISPLAY}_down" 2>/dev/null)" ||
\t\t   ! ipv6_up_raw="$(ip6tables -t mangle -S "${SCRIPTNAME_DISPLAY}_up" 2>/dev/null)"; then
\t\t\treturn 1
\t\tfi
\t\tipv6_down_present="$(printf '%s\\n' "${ipv6_down_raw}" | /bin/grep "^-A ${SCRIPTNAME_DISPLAY}_down " | normalize_iptables_rules)"
\t\tipv6_up_present="$(printf '%s\\n' "${ipv6_up_raw}" | /bin/grep "^-A ${SCRIPTNAME_DISPLAY}_up " | normalize_iptables_rules)"

\t\tif [ "${ipv6_down_present}" != "${ipv6_down_expected}" ] ||
\t\t   [ "${ipv6_up_present}" != "${ipv6_up_expected}" ]; then
\t\t\treturn 1
\t\tfi
\tfi
''',
    '''\tif [ "${IPv6_enabled}" != "disabled" ]; then
\t\tif ! ipv6_down_raw="$(ip6tables -t mangle -S "${SCRIPTNAME_DISPLAY}_down" 2>/dev/null)" ||
\t\t   ! ipv6_up_raw="$(ip6tables -t mangle -S "${SCRIPTNAME_DISPLAY}_up" 2>/dev/null)"; then
\t\t\treturn 1
\t\tfi
\t\tipv6_down_present="$(printf '%s\\n' "${ipv6_down_raw}" | /bin/grep "^-A ${SCRIPTNAME_DISPLAY}_down " | normalize_iptables_rules)"
\t\tipv6_up_present="$(printf '%s\\n' "${ipv6_up_raw}" | /bin/grep "^-A ${SCRIPTNAME_DISPLAY}_up " | normalize_iptables_rules)"

\t\tif [ "${ipv6_down_present}" != "${ipv6_down_expected}" ] ||
\t\t   [ "${ipv6_up_present}" != "${ipv6_up_expected}" ]; then
\t\t\treturn 1
\t\tfi
\telse
\t\t# Missing managed IPv6 chains are normal while IPv6 is disabled. Existing
\t\t# managed chains, however, must be empty so stale classification cannot live on.
\t\tif ipv6_down_raw="$(ip6tables -t mangle -S "${SCRIPTNAME_DISPLAY}_down" 2>/dev/null)"; then
\t\t\tipv6_down_present="$(printf '%s\\n' "${ipv6_down_raw}" | /bin/grep "^-A ${SCRIPTNAME_DISPLAY}_down " | normalize_iptables_rules)"
\t\t\t[ -z "${ipv6_down_present}" ] || return 1
\t\tfi
\t\tif ipv6_up_raw="$(ip6tables -t mangle -S "${SCRIPTNAME_DISPLAY}_up" 2>/dev/null)"; then
\t\t\tipv6_up_present="$(printf '%s\\n' "${ipv6_up_raw}" | /bin/grep "^-A ${SCRIPTNAME_DISPLAY}_up " | normalize_iptables_rules)"
\t\t\t[ -z "${ipv6_up_present}" ] || return 1
\t\tfi
\tfi
''',
    "validate disabled IPv6 chains",
)

text = replace_once(
    text,
    '''\t\tip6tables -t mangle -A POSTROUTING -o "${lan}" -m mark --mark 0x80000000/0xc0000000 -j "${SCRIPTNAME_DISPLAY}_down"
\t\tip6tables -t mangle -A POSTROUTING -o "${wan}" -m mark --mark 0x40000000/0xc0000000 -j "${SCRIPTNAME_DISPLAY}_up"
\tfi
}
''',
    '''\t\tip6tables -t mangle -A POSTROUTING -o "${lan}" -m mark --mark 0x80000000/0xc0000000 -j "${SCRIPTNAME_DISPLAY}_down"
\t\tip6tables -t mangle -A POSTROUTING -o "${wan}" -m mark --mark 0x40000000/0xc0000000 -j "${SCRIPTNAME_DISPLAY}_up"
\telse
\t\t# Remove IPv6 static state left from a previous enabled configuration.
\t\tip6tables -t mangle -D OUTPUT -o "${wan}" -p udp -m multiport --dports 53,123 -j MARK --set-mark 0x40"${Net_mark}"0fff/0xc03f0fff >/dev/null 2>&1
\t\tip6tables -t mangle -D OUTPUT -o "${wan}" -p tcp -m multiport --dports 53,853 -j MARK --set-mark 0x40"${Net_mark}"0fff/0xc03f0fff >/dev/null 2>&1
\t\tip6tables -t mangle -D OUTPUT -o "${wan}" -p udp -m multiport ! --dports 53,123 -j MARK --set-mark 0x40"${OUTPUTCLS}"ffff/0xc03fffff >/dev/null 2>&1
\t\tip6tables -t mangle -D OUTPUT -o "${wan}" -p tcp -m multiport ! --dports 53,853 -j MARK --set-mark 0x40"${OUTPUTCLS}"ffff/0xc03fffff >/dev/null 2>&1
\t\twhile ip6tables -t mangle -D POSTROUTING -o "${lan}" -m mark --mark 0x80000000/0xc0000000 -j "${SCRIPTNAME_DISPLAY}_down" >/dev/null 2>&1; do :; done
\t\twhile ip6tables -t mangle -D POSTROUTING -o "${wan}" -m mark --mark 0x40000000/0xc0000000 -j "${SCRIPTNAME_DISPLAY}_up" >/dev/null 2>&1; do :; done
\tfi
}
''',
    "static IPv6 cleanup",
)
script.write_text(text)

test = Path("tests/test-iptables-rules.bats")
t = test.read_text()
t = replace_once(t, '    "get_class_mark",\n', '    "get_class_mark",\n    "iptables_static_rules",\n', "extract static rules")
t = replace_once(t, '  lan="br0"\n', '  lan="br0"\n  wan="eth0"\n', "WAN test interface")
t = replace_once(
    t,
    '  load_flexqos_functions\n}\n\nteardown()',
    '''  load_flexqos_functions
}

am_settings_get() {
  case "${1:-}" in
    flexqos_outputcls) printf '5\\n' ;;
    *) printf '\\n' ;;
  esac
}

teardown()''',
    "settings mock",
)

# Patch command mocks by function boundary instead of fragile indentation matching.
def add_delete_failure(block, binary):
    marker = f'''    *)\n      printf '{binary} %s\\n' "$*" >> "$IPTABLES_EXEC_LOG"\n      ;;'''
    replacement = f'''    "-t mangle -D POSTROUTING"*)\n      printf '{binary} %s\\n' "$*" >> "$IPTABLES_EXEC_LOG"\n      return 1\n      ;;\n    *)\n      printf '{binary} %s\\n' "$*" >> "$IPTABLES_EXEC_LOG"\n      ;;'''
    return replace_once(block, marker, replacement, f"{binary} delete mock")

start = t.index("iptables() {\n")
end = t.index("\n}\n\nip6tables() {", start) + 3
block = add_delete_failure(t[start:end], "iptables")
t = t[:start] + block + t[end:]

start = t.index("ip6tables() {\n")
end = t.index("\n}\n\nassert_equal()", start) + 3
block = add_delete_failure(t[start:end], "ip6tables")
t = t[:start] + block + t[end:]

t = replace_once(
    t,
    '''@test "generated apply file executes flushes and appends against command mocks" {
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
''',
    '''@test "generated apply file flushes both families before appending IPv4 rules" {
  iptables_rules='<>>tcp>>443>>5'
  write_iptables_rules validate
  : > "$IPTABLES_EXEC_LOG"

  # shellcheck source=/dev/null
  source "/tmp/${SCRIPTNAME}_iprules"

  [ "$(wc -l < "$IPTABLES_EXEC_LOG")" -eq 6 ]
  assert_equal 'iptables -t mangle -F FlexQoS_down' "$(sed -n '1p' "$IPTABLES_EXEC_LOG")"
  assert_equal 'iptables -t mangle -F FlexQoS_up' "$(sed -n '2p' "$IPTABLES_EXEC_LOG")"
  assert_equal 'ip6tables -t mangle -F FlexQoS_down' "$(sed -n '3p' "$IPTABLES_EXEC_LOG")"
  assert_equal 'ip6tables -t mangle -F FlexQoS_up' "$(sed -n '4p' "$IPTABLES_EXEC_LOG")"
  [[ "$(sed -n '5p' "$IPTABLES_EXEC_LOG")" == 'iptables -t mangle -A FlexQoS_down '* ]]
  [[ "$(sed -n '6p' "$IPTABLES_EXEC_LOG")" == 'iptables -t mangle -A FlexQoS_up '* ]]
}
''',
    "dual-stack apply order test",
)

t = replace_once(
    t,
    '''@test "empty configuration produces only IPv4 flushes when IPv6 is disabled" {
  local expected
  iptables_rules=""
  write_iptables_rules validate
  expected=$'iptables -t mangle -F FlexQoS_down 2>/dev/null\\niptables -t mangle -F FlexQoS_up 2>/dev/null'
  assert_equal "$expected" "$(canonical_file)"
}
''',
    '''@test "empty configuration flushes both managed families when IPv6 is disabled" {
  local expected
  iptables_rules=""
  write_iptables_rules validate
  expected=$'iptables -t mangle -F FlexQoS_down 2>/dev/null\\niptables -t mangle -F FlexQoS_up 2>/dev/null\\nip6tables -t mangle -F FlexQoS_down 2>/dev/null\\nip6tables -t mangle -F FlexQoS_up 2>/dev/null'
  assert_equal "$expected" "$(canonical_file)"
}
''',
    "disabled flush test",
)

extra = '''@test "validator rejects stale IPv6 chain rules after IPv6 is disabled" {
  IPv6_enabled="disabled"
  iptables_rules=""
  set_chain_counts 0 0 1 1
  run validate_iptables_rules
  assert_failure
}

@test "validator tolerates absent IPv6 managed chains while IPv6 is disabled" {
  IPv6_enabled="disabled"
  iptables_rules=""
  IP6TABLES_S_FAIL=2
  run validate_iptables_rules
  assert_success
}

@test "disabled IPv6 static reconciliation emits deletes and no adds" {
  IPv6_enabled="disabled"
  : > "$IPTABLES_EXEC_LOG"
  run iptables_static_rules
  assert_success
  grep -q '^ip6tables -t mangle -D OUTPUT ' "$IPTABLES_EXEC_LOG"
  grep -q '^ip6tables -t mangle -D POSTROUTING ' "$IPTABLES_EXEC_LOG"
  ! grep -q '^ip6tables -t mangle -A ' "$IPTABLES_EXEC_LOG"
  ! grep -q '^ip6tables -t mangle -N ' "$IPTABLES_EXEC_LOG"
}

'''
t = replace_once(
    t,
    '@test "validator fails closed when ip6tables state cannot be inspected" {',
    extra + '@test "validator fails closed when ip6tables state cannot be inspected" {',
    "IPv6 lifecycle tests",
)
test.write_text(t)
