#!/usr/bin/env bash
# Build CPython from source, linking the _sqlite3 extension against our patched libsqlite3.
set -euo pipefail

TARGET="${1:?usage: build_python_unix.sh <target>}"
PYTHON_VERSION="${PYTHON_VERSION:-3.15.2}"
MAX_COLUMN="${MAX_COLUMN:-32767}"

ROOT="$(pwd)"
SQLITE_DIR="$ROOT/dist/sqlite-$TARGET"        # from previous job
BUILD="$ROOT/build/python-$TARGET"
PREFIX="$ROOT/dist/python-$TARGET"
rm -rf "$BUILD" "$PREFIX"
mkdir -p "$BUILD" "$PREFIX"

if [ ! -f "$SQLITE_DIR/sqlite3.h" ]; then
  echo "missing SQLite artifacts at $SQLITE_DIR" >&2; exit 1
fi

# Stage SQLite into a sysroot-style layout Python's configure can find.
SQLROOT="$ROOT/build/sqlite-sysroot-$TARGET"
rm -rf "$SQLROOT"
mkdir -p "$SQLROOT/include" "$SQLROOT/lib" "$SQLROOT/bin"
cp "$SQLITE_DIR"/sqlite3.h "$SQLITE_DIR"/sqlite3ext.h "$SQLROOT/include/"
case "$TARGET" in
  linux-*)
    cp "$SQLITE_DIR"/libsqlite3.so* "$SQLROOT/lib/"
    ;;
  macos-*)
    cp "$SQLITE_DIR"/libsqlite3*.dylib "$SQLROOT/lib/"
    ;;
esac
cp "$SQLITE_DIR/sqlite3" "$SQLROOT/bin/" || true

# Install OS build deps.
case "$TARGET" in
  linux-*)
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends \
      build-essential pkg-config \
      libssl-dev zlib1g-dev libbz2-dev libreadline-dev \
      libncursesw5-dev libffi-dev liblzma-dev uuid-dev tk-dev \
      libgdbm-dev libnss3-dev xz-utils curl ca-certificates
    ;;
  macos-*)
    brew update
    brew install openssl@3 xz gdbm tcl-tk || true
    ;;
esac

URL="https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tar.xz"
echo ">>> Downloading $URL"
curl -fL -o "$BUILD/Python.tar.xz" "$URL"
tar -xf "$BUILD/Python.tar.xz" -C "$BUILD"
cd "$BUILD/Python-${PYTHON_VERSION}"

export CPPFLAGS="-I$SQLROOT/include ${CPPFLAGS:-}"
export LDFLAGS="-L$SQLROOT/lib ${LDFLAGS:-}"
export PKG_CONFIG_PATH="$SQLROOT/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

# Force -g into every compile so we can split DWARF/dSYM after install.
# CFLAGS_NODIST is appended to CFLAGS by Python's Makefile without being
# recorded into distutils/sysconfig, exactly what we want for debug info.
export CFLAGS_NODIST="-g -gdwarf-4 ${CFLAGS_NODIST:-}"

CONFIGURE_ARGS=(
  --prefix="$PREFIX"
  --enable-optimizations
  --with-ensurepip=install
  --enable-loadable-sqlite-extensions
)

case "$TARGET" in
  linux-*)
    # Embed rpath so _sqlite3.so finds our libsqlite3.so.0 next to it.
    export LDFLAGS="$LDFLAGS -Wl,-rpath,\$ORIGIN/../lib -Wl,-rpath,$SQLROOT/lib"
    ;;
  macos-*)
    CONFIGURE_ARGS+=( --with-openssl="$(brew --prefix openssl@3)" )
    export LDFLAGS="$LDFLAGS -Wl,-rpath,@loader_path/../lib -Wl,-rpath,$SQLROOT/lib"
    ;;
esac

./configure "${CONFIGURE_ARGS[@]}"
make -j"$(getconf _NPROCESSORS_ONLN || echo 2)"
make install

# Copy the patched libsqlite3 alongside the interpreter so the install is portable.
mkdir -p "$PREFIX/lib"
case "$TARGET" in
  linux-*)   cp -a "$SQLROOT"/lib/libsqlite3.so*    "$PREFIX/lib/";;
  macos-*)   cp -a "$SQLROOT"/lib/libsqlite3*.dylib "$PREFIX/lib/";;
esac
cp "$SQLROOT/bin/sqlite3" "$PREFIX/bin/sqlite3" || true

# Bring the SQLite debug info along too so every native binary in the tree
# has a matching symbol file right next to it.
case "$TARGET" in
  linux-*)
    cp -a "$SQLITE_DIR"/*.debug "$PREFIX/lib/" 2>/dev/null || true
    # The stripped CLI's .gnu_debuglink expects sqlite3.debug next to sqlite3.
    if [ -f "$SQLITE_DIR/sqlite3.debug" ]; then
      cp -a "$SQLITE_DIR/sqlite3.debug" "$PREFIX/bin/"
    fi
    ;;
  macos-*)
    cp -R "$SQLITE_DIR"/libsqlite3*.dylib.dSYM "$PREFIX/lib/" 2>/dev/null || true
    cp -R "$SQLITE_DIR"/sqlite3.dSYM          "$PREFIX/bin/" 2>/dev/null || true
    ;;
esac

# --- Split debug info for the Python install tree -------------------------
# After this pass every ELF/Mach-O binary in $PREFIX has either a sibling
# .debug file (Linux, linked via .gnu_debuglink) or a sibling .dSYM bundle
# (macOS, linked via LC_UUID).
echo ">>> Splitting debug info in $PREFIX"

split_debug_linux() {
  local bin="$1"
  local dbg="${bin}.debug"
  # Skip if already split or not an ELF with debug info.
  if ! file "$bin" | grep -q 'ELF'; then return 0; fi
  if ! readelf -S "$bin" 2>/dev/null | grep -qE '\.debug_info|\.zdebug_info'; then
    return 0
  fi
  objcopy --only-keep-debug "$bin" "$dbg"
  if [[ "$bin" == *.so* || "$bin" == *.so ]]; then
    objcopy --strip-debug "$bin"
  else
    strip --strip-debug --strip-unneeded "$bin" 2>/dev/null || objcopy --strip-debug "$bin"
  fi
  ( cd "$(dirname "$bin")" && objcopy --add-gnu-debuglink="$(basename "$dbg")" "$(basename "$bin")" )
  chmod 0644 "$dbg"
}

split_debug_macos() {
  local bin="$1"
  if ! file "$bin" | grep -q 'Mach-O'; then return 0; fi
  # dsymutil is a no-op if there's no DWARF; skip the strip in that case too.
  if dsymutil "$bin" -o "${bin}.dSYM" 2>/dev/null; then
    if [ -d "${bin}.dSYM" ]; then
      strip -S "$bin" || true
    fi
  fi
}

case "$TARGET" in
  linux-*)
    # python3 executable, libpython, all C extensions (.so).
    while IFS= read -r -d '' f; do split_debug_linux "$f"; done < <(
      find "$PREFIX" \( -type f -perm -u+x -o -name '*.so' -o -name '*.so.*' \) -print0
    )
    ;;
  macos-*)
    while IFS= read -r -d '' f; do split_debug_macos "$f"; done < <(
      find "$PREFIX" \( -type f -perm -u+x -o -name '*.dylib' -o -name '*.so' \) -print0
    )
    ;;
esac

# Provenance file
cat > "$PREFIX/BUILD_INFO.txt" <<EOF
target=$TARGET
python=$PYTHON_VERSION
sqlite_max_column=$MAX_COLUMN
built=$(date -u +%FT%TZ)
EOF

echo ">>> Python built at $PREFIX"
"$PREFIX/bin/python3" -c "import sqlite3,sys; print(sys.version); print('sqlite',sqlite3.sqlite_version)"
