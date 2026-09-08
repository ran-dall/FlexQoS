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
    "\tEND { exit(valid ? 0 : 1) }\n",
    "\tEND { exit(valid && NR == 1 ? 0 : 1) }\n",
    "single-record bwrates validation",
)
script.write_text(text)

test = Path("tests/test-config.bats")
text = test.read_text()
text = replace_once(
    text,
    "SET_BANDWIDTH='<5>20>15>10>10>30>5>5<100>100>100>100>100>100>100>100<5>20>15>10>10>10>5>30<100>100>100>100>100>100>100>100'",
    "SET_BANDWIDTH='<5>20>15>10>10>30>5>5<100>100>100>100>100>100>100>100<5>20>15>30>10>10>5>5<100>100>100>100>100>100>100>100'",
    "legacy default fixture",
)
test.write_text(text)
