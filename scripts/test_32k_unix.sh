#!/usr/bin/env bash
# Verify SQLITE_MAX_COLUMN took effect in the rebuilt Python.
set -euo pipefail
TARGET="${1:?}"
MAX_COLUMN="${MAX_COLUMN:-32767}"
SQLITE_VERSION="${SQLITE_VERSION:-3540100}"
PY="$(pwd)/dist/python-$TARGET/bin/python3"

"$PY" - <<PY
import sqlite3
version_id = sum(part * scale for part, scale in zip(
    sqlite3.sqlite_version_info, (1000000, 10000, 100, 1)))
print("sqlite version:", sqlite3.sqlite_version)
assert version_id == int("$SQLITE_VERSION"), sqlite3.sqlite_version
con = sqlite3.connect(":memory:")
# SQLITE_LIMIT_COLUMN == 2
limit = con.getlimit(2) if hasattr(con, "getlimit") else None
print("compile-time limit reported by getlimit():", limit)
assert limit == int("$MAX_COLUMN"), limit

# Prove it for real: create a 20,000-column table.
N = 20000
cols = ",".join(f"c{i} INTEGER" for i in range(N))
con.execute(f"CREATE TABLE wide ({cols})")
(count,) = con.execute("SELECT COUNT(*) FROM pragma_table_info('wide')").fetchone()
print(f"created table with {count} columns")
assert count == N, count

# And confirm >2000 (the stock sqlite default) works.
assert count > 2000
print("OK: >2000 columns accepted")
PY
