# Build CPython from source on Windows with SQLITE_MAX_COLUMN=32767 baked in.
# Strategy: use CPython's own PCbuild system with the selected amalgamation
# and inject the define via the %CL% environment variable,
# which MSVC prepends to every compilation.
$ErrorActionPreference = 'Stop'

$PythonVersion = $env:PYTHON_VERSION; if (-not $PythonVersion) { $PythonVersion = '3.15.2' }
$SqliteVersion = $env:SQLITE_VERSION; if (-not $SqliteVersion) { $SqliteVersion = '3540100' }
$SqliteYear    = $env:SQLITE_YEAR;    if (-not $SqliteYear)    { $SqliteYear    = '2026' }
$MaxColumn     = $env:MAX_COLUMN;     if (-not $MaxColumn)     { $MaxColumn     = '32767' }
$Target        = $env:TARGET;         if (-not $Target)        { $Target        = 'windows-x64' }
$PcbuildArch   = $env:PCBUILD_ARCH;   if (-not $PcbuildArch)   { $PcbuildArch   = 'x64' }

# PCbuild drops binaries in a subfolder keyed to the target arch.
switch ($PcbuildArch) {
  'x64'   { $PcbuildOut = 'amd64' }
  'arm64' { $PcbuildOut = 'arm64' }
  default { throw "unsupported PCBUILD_ARCH: $PcbuildArch" }
}

$Root  = (Get-Location).Path
$Build = Join-Path $Root "build\python-$Target"
$Out   = Join-Path $Root "dist\python-$Target"
Remove-Item -Recurse -Force $Build,$Out -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $Build,$Out | Out-Null

$Tag = "v$PythonVersion"
Write-Host ">>> Cloning CPython $Tag"
git clone --depth 1 --branch $Tag https://github.com/python/cpython.git "$Build\cpython"

Push-Location "$Build\cpython"
try {
  Write-Host ">>> Fetching externals (includes sqlite amalgamation)"
  & .\PCbuild\get_externals.bat
  if ($LASTEXITCODE -ne 0) { throw "get_externals failed" }

  $SqliteUrl = "https://sqlite.org/$SqliteYear/sqlite-amalgamation-$SqliteVersion.zip"
  Write-Host ">>> Downloading $SqliteUrl"
  Invoke-WebRequest -Uri $SqliteUrl -OutFile "$Build\amalg.zip"
  Expand-Archive -Force "$Build\amalg.zip" -DestinationPath $Build
  $Amalgamation = Join-Path $Build "sqlite-amalgamation-$SqliteVersion"
  $VersionMatch = Select-String -Path "$Amalgamation\sqlite3.h" -Pattern '^#define SQLITE_VERSION\s+"([^"]+)"'
  $SqliteParts = $VersionMatch.Matches[0].Groups[1].Value.Split('.')
  while ($SqliteParts.Count -lt 4) { $SqliteParts += '0' }
  # PCbuild derives DLL resource versions from the SQLite directory name.
  $SqliteDir = Join-Path $Build ("sqlite-" + ($SqliteParts -join '.'))
  Move-Item -Path $Amalgamation -Destination $SqliteDir

  # Use x64 MSBuild even on ARM64, where the default lookup finds x86 MSBuild.
  $Vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
  $Vs = & $Vswhere -latest -prerelease -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
  if (-not $Vs) { throw "Visual Studio with VC tools not found" }
  $Msbuild = Join-Path $Vs 'MSBuild\Current\Bin\amd64\MSBuild.exe'
  if (-not (Test-Path $Msbuild)) { throw "x64 MSBuild not found: $Msbuild" }
  $env:MSBUILD = "`"$Msbuild`""
  Write-Host ">>> MSBUILD=$env:MSBUILD"

  # A global property prevents VC defaults from selecting 32-bit host tools.
  # The response file also avoids build.bat's equals-sign argument parsing.
  Set-Content -Path .\PCbuild\msbuild.rsp -Encoding ascii -Value '/p:PreferredToolArchitecture=x64'
  Write-Host ">>> PreferredToolArchitecture=x64 (MSBuild global property)"

  # Inject the compile-time limit into every cl.exe invocation. The sqlite3
  # project in PCbuild compiles the selected sqlite3.c with MSVC, so
  # this define propagates into sqlite3.dll and into _sqlite3.pyd's linkage.
  # PCbuild's Release config already compiles with /Zi and links with /DEBUG,
  # so every built binary (python.exe, pythonXY.dll, *.pyd, sqlite3.dll...)
  # gets a matching .pdb next to it in PCbuild\$PcbuildOut.
  $env:CL = "/DSQLITE_MAX_COLUMN=$MaxColumn"
  Write-Host ">>> CL=$env:CL"

  # MSBuild imports environment variables as properties; avoid batch-file
  # argument parsing splitting /p:sqlite3Dir=... at the equals sign.
  $env:sqlite3Dir = $SqliteDir
  Write-Host ">>> sqlite3Dir=$env:sqlite3Dir"
  Write-Host ">>> Building CPython ($PcbuildArch, Release)"
  & .\PCbuild\build.bat -e -p $PcbuildArch -c Release --no-tkinter
  if ($LASTEXITCODE -ne 0) { throw "build.bat failed" }

  Write-Host ">>> Laying out a redistributable install (with PDBs)"
  $Layout = Join-Path $Out "."
  # --include-symbols copies every matching .pdb next to its binary so the
  # layout is debuggable out of the box.
  & .\python.bat .\PC\layout\main.py `
      --source . `
      --build .\PCbuild\$PcbuildOut `
      --copy $Layout `
      --include-pip --include-stable --include-venv `
      --include-symbols
  if ($LASTEXITCODE -ne 0) { throw "layout failed" }

  # Provenance
  @"
target=$Target
python=$PythonVersion
sqlite_max_column=$MaxColumn
built=$([DateTime]::UtcNow.ToString("o"))
"@ | Out-File -Encoding ascii (Join-Path $Out "BUILD_INFO.txt")
}
finally { Pop-Location }

Write-Host ">>> Python built at $Out"
& "$Out\python.exe" -c "import sys,sqlite3; print(sys.version); print('sqlite',sqlite3.sqlite_version)"
