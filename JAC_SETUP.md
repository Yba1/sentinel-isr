# Jac toolchain — read this before writing any .jac

## The blocker

`jaclang` was not installed anywhere. When installed against the default interpreter
(anaconda Python 3.11.7) it resolves to **jaclang 0.10.2**, which then dies at import:

```
cannot import name 'override' from 'typing'
```

`typing.override` is Python **3.12+**. Every jaclang from 0.13.2 onward declares
`requires_python >= 3.12`, so pip silently back-solves to 0.10.2 on a 3.11 interpreter —
and 0.10.2 is broken there anyway. There is no jaclang that works on Python 3.11.

(`jaclang 2.0.0` exists on PyPI but is **yanked**. Do not use it.)

## The fix

Python 3.12.4 is already installed on this machine. Use it for everything.

```bash
C:/Users/raj_k/AppData/Local/Programs/Python/Python312/python.exe -m pip install jaclang==0.16.7 numpy scipy pytest
```

Interpreter: `C:\Users\raj_k\AppData\Local\Programs\Python\Python312\python.exe`
Jac CLI:     `C:\Users\raj_k\AppData\Local\Programs\Python\Python312\Scripts\jac.exe` (not on PATH)

The existing 122 tests pass unchanged on 3.12 with numpy 2.5.1, so the migration is clean —
nothing in `tracker/` needed touching.

First `jac run` takes ~2 minutes: it compiles and caches the Jac compiler, which is itself
written in Jac. That is normal. It is fast afterwards.

## Syntax that actually compiles on 0.16.7

Verified by running, not by reading docs. The snippet in the build-plan amendment does
**not** compile as written — see the bottom of this file.

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
    leaves = [root -->];
    print("ok", math.sqrt(4.0), len(leaves));
}
```

Confirmed working: `node` / `edge` / `walker` archetypes, `has` with defaults,
`can <name> with <Type> entry` abilities, `here` / `self` / `root`, `++>` and typed
`+>:Edge:+>` connects, `visit [->:Edge:->]`, `spawn`, `[root -->]` navigation,
`import` of Python modules and numpy interop.

## Two things that do NOT work

**Node type filters.** Both of these fail:

```jac
leaves = [root --> (`?Hypothesis)];   # error[E0105]: Unexpected character: '`'
leaves = [root --> (?Hypothesis)];    # ICE: Empty py_ast on FilterCompr
```

The second one crashes the compiler outright (internal compiler error), so it is not a
"wrong syntax" case — it is a compiler bug in 0.16.7. Use plain `[root -->]` and filter
in a Python helper, or keep the graph typed so a filter is unnecessary. **Ask Omar** whether
the workshop covered a working filter form; if the graph only ever holds one node type per
edge, this never comes up.

**The amendment's walker snippet.** As written:

```jac
walker Track {    has hyp_id: str;    ...
    can step with Frame entry {
        if ambiguous {
            spawn Track(hyp_id=new_id(), weight=w2) on here;
            here ++> Hypothesis(parent=self.hyp_id);
        }
    }
}
```

`spawn X() on here` is not the 0.16.7 spelling — it is `here spawn X()`. And
`Hypothesis(parent=...)` needs `parent` declared as a `has` field on the node.
Neither is a big change, but both fail to compile as-is.
