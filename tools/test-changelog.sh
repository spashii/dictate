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
- **Bold & brief.** Then <plain> text.
MD
out=$($root/tools/changelog.sh 1.0.0 $tmp/fixture.md 2>&1)
[[ $out == '<ul><li>Fish &amp; chips, and 1 &lt; 2.</li><li>A wrapped line.</li><li><b>Bold &amp; brief.</b> Then &lt;plain&gt; text.</li></ul>' ]] &&
  check "escapes & and <, joins wrapped bullets and turns **bold** into <b>" ok || check "escapes & and <, joins wrapped bullets and turns **bold** into <b>" "got: $out"

printf '# What'\''s new\n\n<!--\n## 9.9.9 (2026-02-02)\n\n- Draft.\n-->\n\n## 1.0.0 (2026-01-01)\n\n- Something.\n' > $tmp/draft.md
$root/tools/changelog.sh 9.9.9 $tmp/draft.md >/dev/null 2>&1 &&
  check "a commented-out draft heading is not published" "it printed an entry" ||
  check "a commented-out draft heading is not published" ok
$root/tools/changelog.sh 1.0.0 $tmp/draft.md >/dev/null 2>&1 &&
  check "entries after a comment block still print" ok || check "entries after a comment block still print" "failed"

printf '## 0.10 (2026-01-01)\n\n- Something.\n' > $tmp/ten.md
$root/tools/changelog.sh 0.1 $tmp/ten.md >/dev/null 2>&1 &&
  check "versions compare as text, so 0.1 is not 0.10" "it printed an entry" ||
  check "versions compare as text, so 0.1 is not 0.10" ok

mismatch=""
for heading in ${(f)"$(grep '^## ' $root/CHANGELOG.md | awk '{print $2}')"}; do
  html=$($root/tools/changelog.sh $heading 2>&1) || { mismatch+=" $heading(fails)"; continue }
  lis=$(print -r -- $html | grep -o '<li>' | wc -l | tr -d ' ')
  bullets=$(awk -v v="$heading" '/^## /{inside=($2 "" == v "");next} inside && /^- /{n++} END{print n+0}' $root/CHANGELOG.md)
  [[ $lis == $bullets ]] || mismatch+=" $heading($lis li, $bullets bullets)"
done
[[ -z $mismatch ]] && check "every real entry prints one li per bullet" ok ||
  check "every real entry prints one li per bullet" "$mismatch"

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
