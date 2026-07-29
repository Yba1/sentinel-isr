#!/usr/bin/env bash
# setup_env.sh -- one command to get a working Sentinel-ISR + Jac environment.
#
#   ./setup_env.sh          (git-bash on Windows, or any bash)
#
# Finds a Python >= 3.12, installs requirements.txt, and runs the Jac interop
# smoke test. Exits non-zero if anything fails.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Sentinel-ISR environment setup ==="
echo "repo root: $REPO_ROOT"

# ---------------------------------------------------------------- find python
is_py312() {
    # "$@" is the full command, e.g. `py -3.12`
    command -v "$1" >/dev/null 2>&1 || return 1
    "$@" -c 'import sys; sys.exit(0 if sys.version_info >= (3,12) else 1)' >/dev/null 2>&1
}

PYTHON=()
KNOWN="/c/Users/raj_k/AppData/Local/Programs/Python/Python312/python.exe"

if [[ -x "$KNOWN" ]] && is_py312 "$KNOWN"; then
    PYTHON=("$KNOWN")
elif is_py312 py -3.12; then
    PYTHON=(py -3.12)
elif is_py312 python3.12; then
    PYTHON=(python3.12)
elif is_py312 python; then
    PYTHON=(python)
fi

if [[ ${#PYTHON[@]} -eq 0 ]]; then
    cat >&2 <<'EOF'

FATAL: no Python >= 3.12 found.

Python 3.11 will NOT work and there is no workaround. jaclang uses
typing.override, which only exists in Python 3.12+. On 3.11 pip back-solves to
jaclang 0.10.2, which dies at import with:

    ImportError: cannot import name 'override' from 'typing'

Every jaclang >= 0.13.2 declares requires_python >= 3.12. jaclang 2.0.0 is YANKED.

Install Python 3.12 from python.org, then re-run this script.
EOF
    exit 1
fi

PY_VER="$("${PYTHON[@]}" -c "import sys; print('.'.join(map(str, sys.version_info[:3])))")"
PY_EXE="$("${PYTHON[@]}" -c "import sys; print(sys.executable)")"
echo "python:    $PY_EXE  ($PY_VER)"

# ---------------------------------------------------------------- install
echo
echo "--- installing requirements.txt ---"
"${PYTHON[@]}" -m pip install -r "$REPO_ROOT/requirements.txt"

# ---------------------------------------------------------------- locate jac
# Derive Scripts/ (Windows) or bin/ (POSIX) from the interpreter we actually used.
SCRIPTS_DIR="$("${PYTHON[@]}" -c "import sysconfig; print(sysconfig.get_path('scripts'))")"
JAC_EXE="$SCRIPTS_DIR/jac.exe"
[[ -x "$JAC_EXE" ]] || JAC_EXE="$SCRIPTS_DIR/jac"

if [[ ! -x "$JAC_EXE" ]]; then
    echo "FATAL: jac executable not found in $SCRIPTS_DIR" >&2
    exit 1
fi

cat <<EOF

interpreter : $PY_EXE
jac CLI     : $JAC_EXE
NOTE: the jac CLI is NOT on PATH. Call it by full path, or add
      $SCRIPTS_DIR
      to PATH yourself.

NOTE: the FIRST 'jac run' takes ~2 MINUTES. The Jac compiler is itself written
      in Jac, so it gets compiled and cached on first use. This is NORMAL, not a
      hang. Later runs take seconds.

EOF

# ---------------------------------------------------------------- smoke test
echo "--- running jac/smoke_interop.jac (be patient on first run) ---"

# Belt-and-braces. smoke_interop.jac bootstraps its own sys.path from __file__, so
# it does NOT need this -- but `jac run` puts only the .jac file's own directory on
# sys.path, so any OTHER .jac that imports tracker.* and skips that bootstrap needs it.
# On git-bash the interpreter is a native Windows exe, so PYTHONPATH must be a
# Windows path (C:\...), not the /c/... form bash reports.
if command -v cygpath >/dev/null 2>&1; then
    export PYTHONPATH="$(cygpath -w "$REPO_ROOT")"
else
    export PYTHONPATH="$REPO_ROOT"
fi

set +e
( cd "$REPO_ROOT" && "$JAC_EXE" run jac/smoke_interop.jac )
SMOKE=$?
set -e

echo
if [[ $SMOKE -eq 0 ]]; then
    echo "SETUP OK -- Jac <-> Python interop verified."
    echo "Run the test suite with:"
    echo "    $PY_EXE -m pytest"
    exit 0
else
    echo "SETUP FAILED -- smoke test exited $SMOKE. See output above." >&2
    exit 1
fi
