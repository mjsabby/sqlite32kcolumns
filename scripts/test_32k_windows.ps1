$ErrorActionPreference = 'Stop'
$MaxColumn = $env:MAX_COLUMN; if (-not $MaxColumn) { $MaxColumn = '32767' }
$SqliteVersion = $env:SQLITE_VERSION; if (-not $SqliteVersion) { $SqliteVersion = '3540100' }
$Target    = $env:TARGET;    if (-not $Target)    { $Target    = 'windows-x64' }
$Py = Join-Path (Get-Location) "dist\python-$Target\python.exe"

& $Py -c @"
import sqlite3
version_id = sum(part * scale for part, scale in zip(
    sqlite3.sqlite_version_info, (1000000, 10000, 100, 1)))
print('sqlite version:', sqlite3.sqlite_version)
assert version_id == int('$SqliteVersion'), sqlite3.sqlite_version
con = sqlite3.connect(':memory:')
try:
    limit = con.getlimit(2)
    print('getlimit SQLITE_LIMIT_COLUMN =', limit)
    assert limit == int('$MaxColumn'), limit
except AttributeError:
    pass
N = 20000
cols = ','.join(f'c{i} INTEGER' for i in range(N))
con.execute(f'CREATE TABLE wide ({cols})')
count = con.execute("SELECT COUNT(*) FROM pragma_table_info('wide')").fetchone()[0]
print(f'created table with {count} columns')
assert count == N, count
assert count > 2000
print('OK: >2000 columns accepted')
"@
if ($LASTEXITCODE -ne 0) { throw "smoke test failed" }
