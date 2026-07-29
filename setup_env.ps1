# setup_env.ps1 -- one command to get a working Sentinel-ISR + Jac environment.
#
#   powershell -ExecutionPolicy Bypass -File .\setup_env.ps1
#
# Finds a Python >= 3.12, installs requirements.txt, and runs the Jac interop
# smoke test. Exits non-zero if anything fails.

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition

Write-Host "=== Sentinel-ISR environment setup ===" -ForegroundColor Cyan
Write-Host "repo root: $RepoRoot"

# ---------------------------------------------------------------- find python
function Test-Py312($exe, $prefixArgs) {
    if (-not $exe) { return $false }
    $args = @()
    if ($prefixArgs) { $args += $prefixArgs }
    $args += @('-c', 'import sys; sys.exit(0 if sys.version_info >= (3,12) else 1)')
    try { & $exe @args 2>$null | Out-Null } catch { return $false }
    return $LASTEXITCODE -eq 0
}

$Python = $null
$PyArgs = @()

# 1. the known-good path on the build machine
$Known = "C:\Users\raj_k\AppData\Local\Programs\Python\Python312\python.exe"
if ((Test-Path $Known) -and (Test-Py312 $Known $null)) {
    $Python = $Known
}

# 2. the py launcher
if (-not $Python) {
    $pyExe = (Get-Command py -ErrorAction SilentlyContinue)
    if ($pyExe -and (Test-Py312 $pyExe.Source @('-3.12'))) {
        $Python = $pyExe.Source; $PyArgs = @('-3.12')
    }
}

# 3. python3.12 on PATH
if (-not $Python) {
    $p312 = (Get-Command python3.12 -ErrorAction SilentlyContinue)
    if ($p312 -and (Test-Py312 $p312.Source $null)) { $Python = $p312.Source }
}

# 4. plain `python`, only if it happens to be >= 3.12
if (-not $Python) {
    $pl = (Get-Command python -ErrorAction SilentlyContinue)
    if ($pl -and (Test-Py312 $pl.Source $null)) { $Python = $pl.Source }
}

if (-not $Python) {
    Write-Host ""
    Write-Host "FATAL: no Python >= 3.12 found." -ForegroundColor Red
    Write-Host ""
    Write-Host "Python 3.11 will NOT work and there is no workaround. jaclang uses"
    Write-Host "typing.override, which only exists in Python 3.12+. On 3.11 pip"
    Write-Host "back-solves to jaclang 0.10.2, which dies at import with:"
    Write-Host "    ImportError: cannot import name 'override' from 'typing'"
    Write-Host "Every jaclang >= 0.13.2 requires_python >= 3.12. jaclang 2.0.0 is YANKED."
    Write-Host ""
    Write-Host "Install Python 3.12 from python.org, then re-run this script."
    exit 1
}

$PyVer = (& $Python @PyArgs -c "import sys; print('.'.join(map(str, sys.version_info[:3])))")
# $Python may be the `py` launcher, which is NOT the real interpreter. Resolve the
# actual executable so the paths we print and the Scripts dir we derive are correct.
$PyExe = (& $Python @PyArgs -c "import sys; print(sys.executable)")
Write-Host "python:    $PyExe  ($PyVer)" -ForegroundColor Green

# ---------------------------------------------------------------- install
Write-Host ""
Write-Host "--- installing requirements.txt ---"
& $Python @PyArgs -m pip install -r (Join-Path $RepoRoot 'requirements.txt')
if ($LASTEXITCODE -ne 0) { Write-Host "FATAL: pip install failed." -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------- locate jac
# Ask the interpreter itself where scripts land -- Split-Path on $Python is wrong when
# $Python is the `py` launcher (its dir has no Scripts\).
$Scripts = (& $Python @PyArgs -c "import sysconfig; print(sysconfig.get_path('scripts'))")
$JacExe  = Join-Path $Scripts 'jac.exe'
if (-not (Test-Path $JacExe)) {
    Write-Host "FATAL: jac.exe not found at $JacExe" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "interpreter : $PyExe"
Write-Host "jac CLI     : $JacExe"
Write-Host "NOTE: jac.exe is NOT on PATH. Always call it by full path, or add" -ForegroundColor Yellow
Write-Host "      $Scripts to PATH yourself." -ForegroundColor Yellow
Write-Host ""
Write-Host "NOTE: the FIRST 'jac run' takes ~2 MINUTES. The Jac compiler is itself" -ForegroundColor Yellow
Write-Host "      written in Jac, so it gets compiled and cached on first use." -ForegroundColor Yellow
Write-Host "      This is NORMAL, not a hang. Later runs are seconds." -ForegroundColor Yellow

# ---------------------------------------------------------------- smoke test
Write-Host ""
Write-Host "--- running jac/smoke_interop.jac (be patient on first run) ---"

# Belt-and-braces. smoke_interop.jac bootstraps its own sys.path from __file__, so it
# does NOT need this -- but `jac run` puts only the .jac file's own directory on
# sys.path, so any OTHER .jac that imports tracker.* and skips that bootstrap needs it.
$env:PYTHONPATH = $RepoRoot
Push-Location $RepoRoot
try {
    & $JacExe run (Join-Path 'jac' 'smoke_interop.jac')
    $smoke = $LASTEXITCODE
} finally {
    Pop-Location
}

Write-Host ""
if ($smoke -eq 0) {
    Write-Host "SETUP OK -- Jac <-> Python interop verified." -ForegroundColor Green
    Write-Host "Run the test suite with:"
    Write-Host "    $PyExe -m pytest"
    exit 0
} else {
    Write-Host "SETUP FAILED -- smoke test exited $smoke. See output above." -ForegroundColor Red
    exit 1
}
