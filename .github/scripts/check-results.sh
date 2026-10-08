#!/usr/bin/env bash
# check-results.sh FILE...
# Reads the output of `mariadb --table` and fails if any check in it failed:
#   - test.sql's "N / M passed" summary must have N = M
#   - every row of a self-check table (columns: test, pass) must have pass = 1
#   - every row of with_vs_without.sql's report 4b must have groups_that_differ = 0
# It also fails if a file contains no checks at all, so a script that stopped early is caught.
set -euo pipefail

for file in "$@"; do
  echo "== $file"
  awk -F'|' '
    # Headers of the tables we check; their rows start after the next border line.
    /^\| test +\| pass \|$/                         { kind = "pass";   border = 0; next }
    /\| groups_compared \| groups_that_differ \|$/  { kind = "differ"; border = 0; next }
    kind != "" && /^\+/                              { if (++border == 2) kind = ""; next }

    kind == "pass" {
      n_pass++; v = $(NF - 1); gsub(/ /, "", v)
      if (v != "1") { failed++; print "FAILED self-check:" $2 }
    }
    kind == "differ" {
      n_differ++; v = $(NF - 1); gsub(/ /, "", v)
      if (v != "0") { failed++; print "FAILED comparison:" $0 }
    }
    /^\| [0-9]+ \/ [0-9]+ passed +\|$/ {
      n_suite++; split($2, a, " ")
      if (a[1] != a[3]) { failed++; print "FAILED test.sql:" $2 }
    }

    END {
      printf "test.sql summaries: %d, self-checks: %d, with/without comparisons: %d, failed: %d\n",
             n_suite, n_pass, n_differ, failed
      if (n_suite + n_pass + n_differ == 0) { print "No checks found in the output"; exit 1 }
      exit failed > 0
    }
  ' "$file"
done
