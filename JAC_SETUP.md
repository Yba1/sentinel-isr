# Jac toolchain — read this before writing any .jac

## TL;DR — one command

```powershell
powershell -ExecutionPolicy Bypass -File .\setup_env.ps1
```
```bash
./setup_env.sh
```

Either one finds a Python >= 3.12, installs `requirements.txt`, prints the paths you need,
and runs `jac/smoke_interop.jac` as a pass/fail gate. If it says `SETUP OK`, you are done.

## Python 3.12 is mandatory

`jaclang` uses `typing.override`, which is **Python 3.12+ only**. On a 3.11 interpreter pip
silently back-solves to jaclang 0.10.2, which then dies at import with:

```
ImportError: cannot import name 'override' from 'typing'
```

Every jaclang from 0.13.2 onward declares `requires_python >= 3.12`. There is **no** jaclang
that works on 3.11. (`jaclang 2.0.0` exists on PyPI but is **yanked**. Do not use it.)

```
interpreter : C:\Users\raj_k\AppData\Local\Programs\Python\Python312\python.exe   (3.12.4)
jac CLI     : C:\Users\raj_k\AppData\Local\Programs\Python\Python312\Scripts\jac.exe
```

**`jac.exe` is not on PATH.** Call it by full path or add that `Scripts` dir yourself.

**The first `jac run` takes ~2 minutes.** The Jac compiler is itself written in Jac, so it gets
compiled and cached on first use. That is normal, not a hang. Later runs take seconds.

Anaconda 3.11 (`C:\Users\raj_k\anaconda3\python.exe`) is the default `python` on this box and
is **useless for Jac**. Don't install jaclang there — it was installed once, it broke numba,
and it has been removed. See "Anaconda cleanup" at the bottom.

## Running tests

`pytest.ini` sets `testpaths = tests` and registers a `jac` marker, but **it cannot pick an
interpreter**. You must invoke pytest with 3.12 explicitly:

```
C:\Users\raj_k\AppData\Local\Programs\Python\Python312\python.exe -m pytest
```

122 tests pass on 3.12 with numpy 2.5.1 — nothing in `tracker/` needed touching for the
migration. Mark anything that shells out to the Jac toolchain with `@pytest.mark.jac`;
skip those with `-m "not jac"`.

## Jac -> Python interop: PROVEN

`jac/smoke_interop.jac` is the reference. It imports the real tracker package, runs the
numpy/scipy assignment solver, and drives a walker over a Jac graph in one program. Copy its
header into any new `.jac` that needs `tracker.*`.

**`jac run` does NOT put the repo root on sys.path** — it uses the `.jac` file's own directory.
A bare `import from tracker.assoc {...}` fails with `No module named 'tracker'` *even from the
repo root*.

The fix, and it is the whole header of `smoke_interop.jac`:

```jac
import sys;
import os;

with entry {
    _repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)));
    if _repo_root not in sys.path {
        sys.path.insert(0, _repo_root);
    }
}

import from numpy { eye }
import from tracker.kalman { CVKalman }
import from tracker.assoc { Track, associate_global, DEFAULT_PARAMS }
```

**Jac executes top-level statements in source order — imports are NOT hoisted above `with
entry` blocks.** So a bootstrap entry block placed *before* the imports runs first and works.
(Verified by running. `__file__` is available inside an entry block.) Two `with entry` blocks
in one file is legal; they run in order.

This makes the file self-contained: no `PYTHONPATH`, works from any cwd. Setting `PYTHONPATH`
to the repo root is an equally valid alternative if you prefer it — but then teammates have to
remember. `tracker/` has no `__init__.py` and does not need one; namespace-package resolution
is fine once the root is on the path.

Interop confirmed in both directions: Python objects (`CVKalman`, `Track`, `AssocResult`
dataclasses, numpy arrays) construct, pass through, and read back from Jac with keyword args,
attribute access, `@property`, `@staticmethod`, and tuple/list indexing all intact.

`sys.exit(1)` from a `with entry` block **does** set the process exit code, so scripts can gate
on a `.jac` run. Verified by deliberately breaking an assertion.

## `root` is PERSISTENT across runs

`jac run` writes the root graph to `.jac/data/<name>.db` **in the current working directory**.
It is reloaded on the next run, so `len([root -->])` grows by one every time you run the same
file. **Never assert on counts reachable from `root`.** Delete `.jac/data/` to reset.

Two untracked dirs get created and are build/state junk, not source:
`.jac/data/` (repo root) and `jac/.jac/cache/`. They are **not** in `.gitignore` yet — someone
who owns that file should add them.

## Syntax that actually compiles on 0.16.7

Verified by running, not by reading docs.

```jac
import math;
import from numpy { array }

node Hypothesis {
    has hyp_id: str;
    has weight: float = 1.0;
    has depth: int = 0;
    has alive: bool = True;
}

edge Fork {}

walker Splitter {
    has budget: int = 3;
    has made: list = [];

    can split with Hypothesis entry {
        if self.budget <= 0 { return; }
        self.budget -= 1;
        kid = Hypothesis(hyp_id=here.hyp_id + "a",
                         weight=here.weight * 0.61,
                         depth=here.depth + 1);
        here +>:Fork:+> kid;          # typed edge
        self.made.append(kid.hyp_id);
        visit [->:Fork:->];           # traverse typed edge
    }
}

with entry {
    root ++> Hypothesis(hyp_id="h_00", weight=1.0);
    root spawn Splitter();
    print("ok", math.sqrt(4.0), len([root -->]));
}
```

Confirmed: `node` / `edge` / `walker` archetypes; `has` with defaults; `can <name> with <Type>
entry` abilities; `here` / `self` / `root`; `++>` and typed `+>:Edge:+>` connects;
`visit [->:Edge:->]`; `root spawn W()` and `here spawn W()`; `[root -->]` and `[somenode -->]`;
`for x in y {}`; `if`/`or` with `{}` blocks; `str()` concatenation; Python and numpy imports.

`spawn` returns the walker object, so you can read its `has` fields afterwards:
`rep = up spawn Reporter(); print(rep.seen);`

## Things that do NOT work — don't burn time on them

**Node type filters.** Both forms fail:

```jac
leaves = [root --> (`?Hypothesis)];   # error[E0105]: Unexpected character: '`'
leaves = [root --> (?Hypothesis)];    # ICE: Empty py_ast on FilterCompr
```

The second crashes the compiler outright — a 0.16.7 compiler bug, not a syntax mistake. Use
plain `[root -->]` and filter in a Python helper, or keep the graph typed so no filter is
needed. **Ask Omar** whether the workshop covered a working filter form.

**`spawn X() on here`** is not 0.16.7 spelling. It is `here spawn X()`.

**`with entry :__main__: { ... }`** — that spelling is a parse error in 0.16.7
(`error[E0002]: Missing '}'`). Just use plain `with entry { ... }`.

**Running `jac` from a non-writable cwd.** jac creates a `.jac/` dir in the *current working
directory* for its session db. From e.g. `C:\Program Files\Git` you get
`PermissionError: [WinError 5] Access is denied`. Run from the repo.

**The build-plan amendment's walker snippet** does not compile as written: it uses
`spawn Track(...) on here`, and `Hypothesis(parent=...)` without `parent` declared as a `has`
field on the node. Both are small fixes, but neither compiles as-is.

## Anaconda cleanup (already done — don't redo it)

jaclang 0.10.2 had been installed into anaconda 3.11, where it cannot run. Installing it also
bumped `llvmlite` 0.42.0 -> 0.48.0, which **broke numba 0.59.0**: `import numba` still
succeeded, but any actual `@njit` compile raised
`RuntimeError: llvmlite.binding.initialize() is deprecated`.

Fixed by:

```
C:\Users\raj_k\anaconda3\python.exe -m pip uninstall -y jaclang
C:\Users\raj_k\anaconda3\python.exe -m pip install "llvmlite==0.42.0"
rm -rf C:\Users\raj_k\anaconda3\Lib\site-packages\jaclang     # stale __pycache__ left a
                                                              # namespace pkg pip didn't remove
```

numba 0.59.0 + llvmlite 0.42.0 now JIT-compiles correctly again. **Do not `pip install jaclang`
with the default `python` on this machine** — that is anaconda 3.11 and you will break numba
again.
