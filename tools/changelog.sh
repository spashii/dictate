#!/bin/zsh
# Prints the CHANGELOG.md entry for a version as HTML for the update feed: tools/changelog.sh VERSION [CHANGELOG]
#
# <ul><li>...</li></ul>, with & < > escaped. A bullet that wraps onto an indented line is joined
# with a space. Exits 1 when the version has no heading or no bullets, so a release can't go
# out without notes.
set -euo pipefail
root=${0:A:h:h}
version=${1:?usage: tools/changelog.sh VERSION [CHANGELOG]}
file=${2:-$root/CHANGELOG.md}
[[ -f $file ]] || { print -u2 "No $file."; exit 1 }

html=$(awk -v v="$version" '
  function flush() {
    if (item != "") {
      gsub(/&/, "\\&amp;", item); gsub(/</, "\\&lt;", item); gsub(/>/, "\\&gt;", item)
      out = out "<li>" item "</li>"; n++
    }
    item = ""
  }
  # HTML comments hold drafts and never publish. Cut them out of each line, across lines too,
  # the way the Swift parser does.
  {
    line = $0
    if (incomment) {
      e = index(line, "-->")
      if (!e) next
      line = substr(line, e + 3); incomment = 0
    }
    while ((s = index(line, "<!--")) > 0) {
      rest = substr(line, s + 4)
      e = index(rest, "-->")
      if (e) line = substr(line, 1, s - 1) substr(rest, e + 3)
      else { line = substr(line, 1, s - 1); incomment = 1 }
    }
    $0 = line
  }
  /^## / {
    flush()
    inside = ($2 "" == v "")
    next
  }
  !inside { next }
  /^- / { flush(); item = substr($0, 3); next }
  /^[ \t]+[^ \t]/ && item != "" { line = $0; sub(/^[ \t]+/, "", line); item = item " " line; next }
  END { flush(); if (n > 0) print "<ul>" out "</ul>" }
' "$file")

[[ -n $html ]] || { print -u2 "CHANGELOG.md has no entry for $version."; exit 1 }
print -r -- $html
