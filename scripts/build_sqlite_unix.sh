#!/usr/bin/env bash
# Build sqlite3 shared lib + CLI with SQLITE_MAX_COLUMN=32767.
# Produces debug info side by side with the binaries:
#   linux : split DWARF (.debug) files, linked back via --add-gnu-debuglink
#   macos : .dSYM bundles, linked to the Mach-O via LC_UUID
set -euo pipefail

TARGET="${1:?usage: build_sqlite_unix.sh <target>}"
SQLITE_VERSION="${SQLITE_VERSION:-3540100}"
SQLITE_YEAR="${SQLITE_YEAR:-2026}"
MAX_COLUMN="${MAX_COLUMN:-32767}"

ROOT="$(pwd)"
BUILD="$ROOT/build/sqlite-$TARGET"
OUT="$ROOT/dist/sqlite-$TARGET"
rm -rf "$BUILD" "$OUT"
mkdir -p "$BUILD" "$OUT"

URL="https://sqlite.org/${SQLITE_YEAR}/sqlite-amalgamation-${SQLITE_VERSION}.zip"
echo ">>> Downloading $URL"
curl -fL -o "$BUILD/amalg.zip" "$URL"
( cd "$BUILD" && unzip -q amalg.zip && mv "sqlite-amalgamation-${SQLITE_VERSION}"/* . )

cd "$BUILD"

# Defines applied everywhere the amalgamation is compiled.
DEFS=(
  -DSQLITE_MAX_COLUMN="$MAX_COLUMN"
  -DSQLITE_ENABLE_COLUMN_METADATA
  -DSQLITE_ENABLE_FTS5
  -DSQLITE_ENABLE_RTREE
  -DSQLITE_ENABLE_JSON1
  -DSQLITE_ENABLE_MATH_FUNCTIONS
  -DSQLITE_ENABLE_DBSTAT_VTAB
  -DSQLITE_ENABLE_LOAD_EXTENSION
  -DSQLITE_THREADSAFE=1
  -DHAVE_USLEEP=1
  -DHAVE_READLINE=0
)

# -g everywhere so DWARF/dSYM can be extracted after linking.
DEBUG_CFLAGS="-g -gdwarf-4"

# Split debug info for an ELF binary. Produces <bin>.debug next to <bin>
# and leaves a .gnu_debuglink pointing at it so gdb/lldb auto-load.
split_debug_linux() {
  local bin="$1"
  local dbg="${bin}.debug"
  objcopy --only-keep-debug "$bin" "$dbg"
  if [[ "$bin" == *.so* ]]; then
    objcopy --strip-debug "$bin"
  else
    strip --strip-debug --strip-unneeded "$bin"
  fi
  ( cd "$(dirname "$bin")" && objcopy --add-gnu-debuglink="$(basename "$dbg")" "$(basename "$bin")" )
  chmod 0644 "$dbg"
}

# Produce a .dSYM bundle next to a Mach-O and strip debug from the binary.
# dsymutil records LC_UUID so lldb finds the bundle automatically.
split_debug_macos() {
  local bin="$1"
  dsymutil "$bin" -o "${bin}.dSYM"
  strip -S "$bin"
}

case "$TARGET" in
  linux-*)
    SOEXT=so
    SONAME="libsqlite3.so.0"
    SOFULL="libsqlite3.so.0.8.6"
    CC=${CC:-cc}
    CFLAGS="-O2 -fPIC -pthread $DEBUG_CFLAGS"
    LDFLAGS="-shared -Wl,-soname,$SONAME -lm -ldl -lpthread"
    $CC $CFLAGS "${DEFS[@]}" -c sqlite3.c -o sqlite3.o
    $CC sqlite3.o -o "$SOFULL" $LDFLAGS
    ln -sf "$SOFULL" "$SONAME"
    ln -sf "$SONAME" "libsqlite3.$SOEXT"
    $CC $CFLAGS "${DEFS[@]}" shell.c sqlite3.c -o sqlite3 -lm -ldl -lpthread

    split_debug_linux "$SOFULL"
    split_debug_linux "sqlite3"

    cp "$SOFULL" "$SONAME" "libsqlite3.$SOEXT" sqlite3 \
       "${SOFULL}.debug" "sqlite3.debug" \
       sqlite3.h sqlite3ext.h "$OUT/"
    ;;
  macos-*)
    SOEXT=dylib
    DYFULL="libsqlite3.0.dylib"
    CC=${CC:-clang}
    CFLAGS="-O2 -fPIC -pthread -arch arm64 -mmacosx-version-min=11.0 $DEBUG_CFLAGS"
    $CC $CFLAGS "${DEFS[@]}" -c sqlite3.c -o sqlite3.o
    $CC sqlite3.o -dynamiclib -install_name "@rpath/$DYFULL" \
        -compatibility_version 9.0 -current_version 9.8.6 \
        -o "$DYFULL" -lpthread
    ln -sf "$DYFULL" "libsqlite3.$SOEXT"
    $CC $CFLAGS "${DEFS[@]}" shell.c sqlite3.c -o sqlite3 -lpthread

    split_debug_macos "$DYFULL"
    split_debug_macos "sqlite3"

    cp "$DYFULL" "libsqlite3.$SOEXT" sqlite3 sqlite3.h sqlite3ext.h "$OUT/"
    cp -R "${DYFULL}.dSYM" "sqlite3.dSYM" "$OUT/"
    ;;
  *)
    echo "unknown target: $TARGET" >&2; exit 1;;
esac

# Keep the source around — the Python build step reuses it.
cp sqlite3.c sqlite3.h sqlite3ext.h shell.c "$OUT/"

echo ">>> Verifying limit"
./sqlite3 :memory: "SELECT sqlite_version();"
./sqlite3 :memory: "SELECT compile_options FROM pragma_compile_options WHERE compile_options LIKE 'MAX_COLUMN=%';"

ls -la "$OUT"
