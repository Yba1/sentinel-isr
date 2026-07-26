# Scenario roadmap

Ten scenarios the engine could run today with a new pack (no code changes), that
we chose not to build for JacHacks. Listed with the data source each would need,
so the gap reads as scope, not as a hole in the system.

1. **Ship-to-ship transfer (STS) detection** -- two vessels converge, loiter
   side by side for an hour or more, then separate. *Data:* AIS (existing
   pipeline); no new source, just a new pack with two loitering actors.

2. **Dark-fleet tanker resupply network** -- a sanctioned tanker meets a feeder
   vessel repeatedly at the same rendezvous point over weeks. *Data:*
   historical MarineCadastre AIS archives (months, not a single window) +
   OFAC SDN vessel list (already pulled, `geo/ofac_sdn_vessels_subset.csv`).

3. **Fishing inside a closed MPA during season closure** -- vessel behavior
   consistent with fishing (slow, winding track) inside a sanctuary during a
   NOAA-declared closure window. *Data:* NOAA/NMFS seasonal closure calendars
   per sanctuary (not yet pulled).

4. **Anchor-drag near a submarine cable route** -- a vessel's track crosses and
   lingers over a cable corridor with anomalous speed/heading changes.
   *Data:* submarine cable routes (already pulled,
   `geo/ca_submarine_cables.geojson`) + a per-vessel speed/heading anomaly
   detector (new logic, not just data).

5. **AIS destination-field falsification** -- a vessel's broadcast destination
   doesn't match its actual port of call. *Data:* AIS destination field
   (present in raw NOAA/MarineCadastre feeds, not currently ingested) + a port
   arrivals reference (NGA World Port Index or a port authority feed).

6. **Rapid re-flagging via IMO/MMSI churn** -- a hull changes registered flag
   and MMSI multiple times in a short period, a known sanctions-evasion
   pattern. *Data:* IMO GISIS vessel registry (subscription/registration
   required) cross-referenced against AIS MMSI history.

7. **High-seas STS sanctions evasion** -- a transfer occurring in international
   waters specifically timed with an AIS gap on one side. *Data:* OFAC
   advisories naming known evasion zones + AIS (existing pipeline).

8. **IUU fishing-effort loitering signature** -- vessel movement pattern
   matches known illegal-fishing kinematics (slow zigzag, no destination).
   *Data:* Global Fishing Watch fishing-effort API (attempted this session,
   Tier C, deferred -- needs an account token).

9. **Coordinated multi-vessel swarming near offshore infrastructure** -- three
   or more vessels converge on a platform or wind installation outside normal
   traffic patterns. *Data:* BOEM/BSEE offshore infrastructure GIS layers
   (not yet pulled) + AIS.

10. **GPS spoofing / jamming cluster** -- a group of vessels shows simultaneous,
    correlated position discontinuities consistent with GPS interference
    rather than independent AIS dropouts. *Data:* maritime GPS-interference
    advisories (e.g. USCG NAVCEN broadcast warnings) + AIS position
    discontinuity detection (new logic).

All ten reuse the existing scenario-pack format and replay engine unchanged --
the constraint on building them today was data acquisition and, for #4/#8/#10,
a purpose-built anomaly detector. Nothing here needs a new engine.
