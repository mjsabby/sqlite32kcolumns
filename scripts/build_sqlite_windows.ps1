# Build sqlite3.dll + sqlite3.exe with SQLITE_MAX_COLUMN=32767 (MSVC x64)
$ErrorActionPreference = 'Stop'

$SqliteVersion = $env:SQLITE_VERSION; if (-not $SqliteVersion) { $SqliteVersion = '3540100' }
$SqliteYear    = $env:SQLITE_YEAR;    if (-not $SqliteYear)    { $SqliteYear    = '2026' }
$MaxColumn     = $env:MAX_COLUMN;     if (-not $MaxColumn)     { $MaxColumn     = '32767' }
$Target        = $env:TARGET;         if (-not $Target)        { $Target        = 'windows-x64' }

$Root  = (Get-Location).Path
$Build = Join-Path $Root "build\sqlite-$Target"
$Out   = Join-Path $Root "dist\sqlite-$Target"
Remove-Item -Recurse -Force $Build,$Out -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $Build,$Out | Out-Null

$Url = "https://sqlite.org/$SqliteYear/sqlite-amalgamation-$SqliteVersion.zip"
Write-Host ">>> Downloading $Url"
Invoke-WebRequest -Uri $Url -OutFile "$Build\amalg.zip"
Expand-Archive -Force "$Build\amalg.zip" -DestinationPath $Build
Get-ChildItem "$Build\sqlite-amalgamation-$SqliteVersion" |
  Move-Item -Destination $Build -Force

Push-Location $Build
try {
  $Defs = @(
    "/DSQLITE_MAX_COLUMN=$MaxColumn",
    "/DSQLITE_ENABLE_COLUMN_METADATA",
    "/DSQLITE_ENABLE_FTS5",
    "/DSQLITE_ENABLE_RTREE",
    "/DSQLITE_ENABLE_JSON1",
    "/DSQLITE_ENABLE_MATH_FUNCTIONS",
    "/DSQLITE_ENABLE_DBSTAT_VTAB",
    "/DSQLITE_ENABLE_LOAD_EXTENSION",
    "/DSQLITE_THREADSAFE=1",
    "/DSQLITE_API=__declspec(dllexport)"
  )

  # /Zi  -> full debug info in a PDB
  # /FS  -> serialize PDB writes (safe with parallel cl, harmless otherwise)
  # /Zo  -> richer debug info for optimized code
  $DebugCFlags = @("/Zi", "/FS", "/Zo")
  # /DEBUG:FULL embeds the PDB path into the image so WinDbg/VS can locate it.
  # /OPT:REF,ICF restore the optimizations that /DEBUG would otherwise disable.
  $DllLinkDbg = @("/DEBUG:FULL", "/OPT:REF", "/OPT:ICF", "/PDB:sqlite3.pdb")
  $ExeLinkDbg = @("/DEBUG:FULL", "/OPT:REF", "/OPT:ICF", "/PDB:sqlite3.exe.pdb")

  # Shared library
  cl /nologo /O2 /MD @DebugCFlags @Defs /LD sqlite3.c /Fe:sqlite3.dll /link /IMPLIB:sqlite3.lib @DllLinkDbg
  if ($LASTEXITCODE -ne 0) { throw "cl (dll) failed" }

  # CLI executable (statically linked to amalgamation)
  $CliDefs = $Defs | Where-Object { $_ -ne "/DSQLITE_API=__declspec(dllexport)" }
  cl /nologo /O2 /MD @DebugCFlags @CliDefs shell.c sqlite3.c /Fe:sqlite3.exe /link @ExeLinkDbg
  if ($LASTEXITCODE -ne 0) { throw "cl (exe) failed" }

  Copy-Item sqlite3.dll, sqlite3.lib, sqlite3.exp, sqlite3.exe, `
            sqlite3.pdb, sqlite3.exe.pdb, `
            sqlite3.h, sqlite3ext.h, sqlite3.c, shell.c $Out -ErrorAction SilentlyContinue
}
finally { Pop-Location }

Write-Host ">>> Verifying"
& "$Out\sqlite3.exe" ":memory:" "SELECT sqlite_version();"
& "$Out\sqlite3.exe" ":memory:" "SELECT compile_options FROM pragma_compile_options WHERE compile_options LIKE 'MAX_COLUMN=%';"
Get-ChildItem $Out
