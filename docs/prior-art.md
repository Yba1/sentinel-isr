# Prior art

We are not claiming a new tracking algorithm. We're claiming a better substrate
to build one in. Own that framing every time this comes up on stage or in Q&A.

## The line to have memorized (Raj, this is yours)

> "This is Reid's MHT from 1979, standard in defense systems. What's new isn't
> the algorithm — it's that hypothesis branching is native to Jac. A fork is a
> walker spawn."

Say it close to verbatim. It does two things at once: it shows we know the
field, and it points the "what's new" question at the one honest answer we
have (the language, not the math).

## Academic foundations

- **Reid, D. B. (1979).** "An algorithm for tracking multiple targets."
  *IEEE Transactions on Automatic Control*, 24(6), 843–854. The original
  multiple hypothesis tracking (MHT) paper — maintains multiple data
  association hypotheses over time instead of committing to one. This is the
  algorithm family our hypothesis-per-walker design implements.
- **Kuhn, H. W. (1955).** "The Hungarian method for the assignment problem."
  *Naval Research Logistics Quarterly*, 2(1–2), 83–97, and **Munkres, J.
  (1957).** "Algorithms for the assignment problem and transportation
  problems." *Journal of the Society for Industrial and Applied Mathematics*,
  5(1), 32–38. The assignment-problem solution (Kuhn–Munkres / Hungarian
  algorithm) underlying optimal measurement-to-track association.
- **Bar-Shalom, Y., Li, X. R., & Kirubarajan, T.** *Estimation with
  Applications to Tracking and Navigation.* Wiley. Standard reference for the
  Kalman filtering and gating math underneath the association layer.
- **Blackman, S., & Popoli, R. (1999).** *Design and Analysis of Modern
  Tracking Systems.* Artech House. The standard MHT systems-engineering
  reference — track lifecycle, gating, pruning strategy.

## Deployed / commercial systems in this space

Naming these openly is the point — it shows we've looked, and it pre-empts
"has this been done before" from being framed as us not knowing.

- **Global Fishing Watch** — public AIS-based fishing activity tracking.
- **Skylight** — dark-vessel detection for illegal fishing enforcement.
- **Windward** — maritime risk analytics on AIS + satellite data.
- **Spire** — satellite AIS data provider, feeds many of the above.
- **Starboard** — maritime domain awareness / dark-target detection.
- **Palantir** — Gotham/Maven-class fusion platforms used in maritime
  domain awareness contexts.
- **Anduril Lattice** — sensor-fusion and autonomy platform, multi-domain
  including maritime.

## What is actually new here

The tracking math (MHT, Kalman gating, Hungarian assignment) is 45–70 years
old and is not the pitch. The pitch is that in Jac, a tracking hypothesis is a
first-class graph citizen: spawning a new hypothesis on ambiguous
association *is* a walker spawn, not a manually-managed list of hypothesis
objects. Pruning is walker lifecycle, not a hand-rolled garbage collector.
That's a language-level fit we can point at directly, and it's honest.

## What NOT to say

- Never "we invented tracking" or any phrasing that implies novel tracking
  theory. The sponsor's CTO works in ML/computer vision — this room has
  people who will know Reid 1979 by name.
- Never "proven smuggling," "confirmed illegal activity," or similar language
  about any tracked vessel. We show "anomalous movement pattern." Movement
  data cannot establish what cargo moved or whether a crime occurred.
- Never imply we're competing with Skylight/Windward/Palantir on data
  coverage or production maturity. We are a one-day proof of concept of a
  substrate idea, not a fielded system.
