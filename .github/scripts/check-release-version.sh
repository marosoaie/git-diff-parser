#!/usr/bin/env bash
# Checks that the version in $1 can be released, given the repository's tag
# names, one per line, on standard input: it must be MAJOR.MINOR.PATCH,
# with no leading zeros and no `v` (the release workflow adds it), untagged
# in either form, and greater than every version tagged so far, with or
# without the `v`. Pre-release and other tags don't count.
#
# The release workflow pipes `git ls-remote --tags --refs origin` into it;
# locally:
#   git ls-remote --tags --refs origin | sed 's|.*refs/tags/||' \
#     | .github/scripts/check-release-version.sh 0.4.0
#
# It runs nothing but bash: no here-strings, whose temporary file can fail
# to be made, and no other programs, whose failure a condition would read
# as "no such tag".
set -euo pipefail
export LC_ALL=C

version=${1-}
number='(0|[1-9][0-9]*)'
if [[ ! "$version" =~ ^$number\.$number\.$number$ ]]; then
  printf 'Not MAJOR.MINOR.PATCH, without a v: %q\n' "$version" >&2
  exit 1
fi
v1=${BASH_REMATCH[1]} v2=${BASH_REMATCH[2]} v3=${BASH_REMATCH[3]}

# Prints -1, 0 or 1 as the decimal number $1 is less than, equal to or
# greater than $2, at any length and with any leading zeros.
compare() {
  local a=$1 b=$2
  while [[ $a == 0?* ]]; do a=${a#0}; done
  while [[ $b == 0?* ]]; do b=${b#0}; done
  if (( ${#a} != ${#b} )); then
    if (( ${#a} < ${#b} )); then echo -1; else echo 1; fi
  elif [[ $a < $b ]]; then
    echo -1
  elif [[ $a > $b ]]; then
    echo 1
  else
    echo 0
  fi
}

# Prints -1, 0 or 1 as the version $1.$2.$3 is less than, equal to or
# greater than $4.$5.$6, field by field.
order() {
  local result
  result=$(compare "$1" "$4")
  [[ $result != 0 ]] || result=$(compare "$2" "$5")
  [[ $result != 0 ]] || result=$(compare "$3" "$6")
  echo "$result"
}

# Each MAJOR.MINOR.PATCH tag, with or without the v, is compared as it's
# read, and anything but "greater" refuses: a comparison that fails, in a
# subshell -e doesn't reach, refuses too.
count=0
while IFS= read -r tag || [[ -n $tag ]]; do
  if [[ $tag == "$version" || $tag == "v$version" ]]; then
    echo "$version is already tagged, as $tag" >&2
    exit 1
  fi
  if [[ $tag =~ ^v?([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    if [[ $(order "$v1" "$v2" "$v3" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}") != 1 ]]; then
      echo "$version isn't greater than $tag, a version already tagged" >&2
      exit 1
    fi
    count=$((count + 1))
  fi
done

echo "v$version can be released: it's greater than every version tagged ($count)."
