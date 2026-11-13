#!/bin/zsh
# Checks tools/changelog.sh and that tools/release.sh stops before building when the version
# has no CHANGELOG.md entry: tools/test-changelog.sh
set -uo pipefail
root=${0:A:h:h}
tmp=$(mktemp -d)
trap 'rm -rf $tmp' EXIT
failed=0

check() {
  if [[ $2 == ok ]]; then print "PASS $1"; else print "FAIL $1: $2"; failed=1; fi
}

out=$($root/tools/changelog.sh $(<$root/VERSION) 2>&1)
[[ $out == '<ul><li>'* && $out == *'</li></ul>' ]] && check "the real file has an entry for VERSION" ok ||
  check "the real file has an entry for VERSION" "got: $out"

cat > $tmp/fixture.md <<'MD'
# What's new

## 1.0.0 (2026-01-01)

- Fish & chips, and 1 < 2.
- A wrapped
  line.
MD
out=$($root/tools/changelog.sh 1.0.0 $tmp/fixture.md 2>&1)
[[ $out == '<ul><li>Fish &amp; chips, and 1 &lt; 2.</li><li>A wrapped line.</li></ul>' ]] &&
  check "escapes & and < and joins wrapped bullets" ok || check "escapes & and < and joins wrapped bullets" "got: $out"

mkdir -p $tmp/tree/tools
cp $root/tools/release.sh $root/tools/changelog.sh $tmp/tree/tools/
print 9.9.9 > $tmp/tree/VERSION
printf '# What'\''s new\n\n## 1.0.0 (2026-01-01)\n\n- Something.\n' > $tmp/tree/CHANGELOG.md
err=$(zsh $tmp/tree/tools/release.sh 2>&1 >/dev/null)
code=$?
if [[ $code -ne 0 && $err == *"no entry for 9.9.9"* && ! -e $tmp/tree/build ]]; then
  check "release.sh refuses a version with no entry, before building" ok
else
  check "release.sh refuses a version with no entry, before building" "exit $code, stderr: $err, build exists: $([[ -e $tmp/tree/build ]] && print yes || print no)"
fi

exit $failed
