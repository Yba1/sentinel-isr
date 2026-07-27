/* SF Bay PPI radar scope — one scene, drives everything off the scene clock. */
const { SceneStage, useScene } = window;

const W = 1920, H = 1080;
const CX = 720, CY = 566, RR = 424;
const S = 0.82, BX = 560, BY = 400;           // bay-space -> scope transform
const PERIOD = 3.0;                            // seconds per revolution
const NM_AT_EDGE = 16;

const GREEN = [59, 245, 138], RED = [255, 74, 58];
const mix = (a, b, k) => `rgb(${a.map((v, i) => Math.round(v + (b[i] - v) * k)).join(',')})`;
const rgba = (c, k, al) => {
  const m = c.map((v, i) => Math.round(v + (RED[i] - v) * k));
  return `rgba(${m[0]},${m[1]},${m[2]},${al})`;
};
const clamp = (v, a, b) => Math.max(a, Math.min(b, v));

const LAND = [
  '0.0,0.0 237.5,0.0 308.7,110.0 364.1,174.0 430.6,216.0 451.2,184.0 482.9,136.0 467.0,84.0 522.5,40.0 554.1,0.0',
  '430.6,226.0 554.1,224.0 577.9,284.0 566.8,356.0 620.6,428.0 664.9,530.0 744.1,640.0 839.1,736.0 981.6,880.0 981.6,1000.0 364.1,1000.0 375.2,840.0 391.1,680.0 408.5,520.0 378.4,394.0 381.6,290.0',
  '601.6,0.0 672.9,44.0 704.5,116.0 720.4,240.0 791.6,376.0 870.8,476.0 981.6,600.0 1092.4,740.0 1219.1,900.0 1266.6,1000.0 1520,1000.0 1520,0.0'
];

const SHIPS = [
  { n: 'KESTREL',    x: 386, y: 214 },
  { n: 'SABLE ROCK', x: 520, y: 206, target: true },
  { n: 'AURORA',     x: 664, y: 182 },
  { n: 'PACIFIC 7',  x: 744, y: 268 },
  { n: 'TIDEWAY',    x: 300, y: 272 },
  { n: 'MARIA T',    x: 236, y: 418 },
  { n: 'OSPREY',     x: 186, y: 556 },
  { n: 'CV NORDIC',  x: 860, y: 520 },
  { n: 'GRAY BIRD',  x: 900, y: 600 },
  { n: 'HALIBUT',    x: 940, y: 690 },
  { n: 'FERRY 3',    x: 596, y: 316 },
  { n: 'LODESTAR',   x: 262, y: 356 },
  { n: 'ANTARES',    x: 90,  y: 470 },
  { n: 'CORMORANT',  x: 760, y: 402 }
];

const px = s => CX + (s.x - BX) * S;
const py = s => CY + (s.y - BY) * S;
const ang = s => Math.atan2(py(s) - CY, px(s) - CX) * 180 / Math.PI;   // 0 = east, cw
const rad = s => Math.hypot(px(s) - CX, py(s) - CY);

const START = -90;
const firstPass = a => (((a - START) % 360) + 360) % 360 / 360 * PERIOD;

const target = SHIPS.find(s => s.target);
const LAST_PAINT = firstPass(ang(target)) + PERIOD;      // last time the sweep saw it
const ALERT_T = LAST_PAINT + PERIOD * 0.94;              // the revolution that finds nothing

function Blip({ s, t, k }) {
  const a = ang(s);
  const since = (((t - firstPass(a)) % PERIOD) + PERIOD) % PERIOD;
  const lost = s.target && t > LAST_PAINT;
  const age = lost ? t - LAST_PAINT : since;
  const al = clamp(1 - age / 2.6, 0, 1);
  if (al <= 0.02) return null;
  const x = px(s), y = py(s);
  return (
    <g opacity={al}>
      <circle cx={x} cy={y} r={5.5} fill={rgba(GREEN, k, 0.95)} />
      <circle cx={x} cy={y} r={13} fill="none" stroke={rgba(GREEN, k, 0.35 * al)} strokeWidth="1.5" />
      <text x={x + 17} y={y + 5} fontFamily="'IBM Plex Mono', monospace" fontSize="17"
            letterSpacing="1.4" fill={rgba(GREEN, k, 0.8)}>{s.n}</text>
    </g>
  );
}

function RadarScene() {
  const { localTime: t } = useScene();
  const sweep = START + (t / PERIOD) * 360;
  const k = clamp((t - ALERT_T) / 0.55, 0, 1);            // green -> red
  const lost = t > LAST_PAINT + 0.4;
  const line = mix(GREEN, RED, k);

  const wedge = [];
  for (let i = 0; i < 14; i++) {
    const a0 = (sweep - i * 4.2) * Math.PI / 180, a1 = (sweep - (i + 1) * 4.2) * Math.PI / 180;
    wedge.push(
      <path key={i} d={`M${CX} ${CY} L${CX + RR * Math.cos(a0)} ${CY + RR * Math.sin(a0)} A${RR} ${RR} 0 0 0 ${CX + RR * Math.cos(a1)} ${CY + RR * Math.sin(a1)} Z`}
            fill={rgba(GREEN, k, 0.075 * (1 - i / 14))} />
    );
  }

  const rings = [0.25, 0.5, 0.75, 1].map((f, i) => (
    <circle key={i} cx={CX} cy={CY} r={RR * f} fill="none" stroke={rgba(GREEN, k, 0.22)} strokeWidth="1.2" />
  ));
  const spokes = [0, 45, 90, 135].map((d, i) => {
    const a = d * Math.PI / 180;
    return <line key={i} x1={CX - RR * Math.cos(a)} y1={CY - RR * Math.sin(a)}
                 x2={CX + RR * Math.cos(a)} y2={CY + RR * Math.sin(a)}
                 stroke={rgba(GREEN, k, 0.14)} strokeWidth="1.2" />;
  });

  const sx = CX + RR * Math.cos(sweep * Math.PI / 180), sy = CY + RR * Math.sin(sweep * Math.PI / 180);
  const rows = SHIPS.slice(0, 7);
  const lostR = Math.max(0, (t - LAST_PAINT)) * 9;

  return (
    <div style={{ position: 'absolute', inset: 0, background: '#04070a',
                  fontFamily: "'IBM Plex Mono', monospace" }}>
      <svg width={W} height={H} style={{ position: 'absolute', inset: 0 }}>
        <defs>
          <clipPath id="scope"><circle cx={CX} cy={CY} r={RR} /></clipPath>
          <radialGradient id="glow">
            <stop offset="0%" stopColor={rgba(GREEN, k, 0.10)} />
            <stop offset="70%" stopColor={rgba(GREEN, k, 0.03)} />
            <stop offset="100%" stopColor="rgba(0,0,0,0)" />
          </radialGradient>
        </defs>

        <circle cx={CX} cy={CY} r={RR} fill="#05100c" />
        <circle cx={CX} cy={CY} r={RR} fill="url(#glow)" />

        <g clipPath="url(#scope)">
          <g transform={`translate(${CX},${CY}) scale(${S}) translate(${-BX},${-BY})`}>
            {LAND.map((p, i) => (
              <polygon key={i} points={p} fill={rgba(GREEN, k, 0.055)}
                       stroke={rgba(GREEN, k, 0.42)} strokeWidth="1.6" vectorEffect="non-scaling-stroke" />
            ))}
            <circle cx="518.5" cy="186.6" r="5" fill="none" stroke={rgba(GREEN, k, 0.35)} vectorEffect="non-scaling-stroke" />
            <circle cx="502.5" cy="113" r="8" fill="none" stroke={rgba(GREEN, k, 0.35)} vectorEffect="non-scaling-stroke" />
          </g>
          {rings}{spokes}
          {wedge}
          {SHIPS.map((s, i) => <Blip key={i} s={s} t={t} k={k} />)}
          {lost && (
            <g>
              <circle cx={px(target)} cy={py(target)} r={lostR} fill="rgba(255,74,58,0.10)"
                      stroke="rgba(255,74,58,0.85)" strokeWidth="2.5" strokeDasharray="9 8" />
              <path d={`M${px(target) - 12} ${py(target)} h24 M${px(target)} ${py(target) - 12} v24`}
                    stroke="rgba(255,74,58,0.9)" strokeWidth="2" />
            </g>
          )}
          <line x1={CX} y1={CY} x2={sx} y2={sy} stroke={line} strokeWidth="3" opacity="0.95" />
        </g>

        <circle cx={CX} cy={CY} r={RR} fill="none" stroke={rgba(GREEN, k, 0.55)} strokeWidth="2" />
        {[[0, 'N'], [90, 'E'], [180, 'S'], [270, 'W']].map(([d, l], i) => {
          const a = (d - 90) * Math.PI / 180;
          return <text key={i} x={CX + (RR + 26) * Math.cos(a)} y={CY + (RR + 26) * Math.sin(a) + 7}
                       textAnchor="middle" fontSize="19" letterSpacing="2"
                       fill={rgba(GREEN, k, 0.6)}>{l}</text>;
        })}
        {[0.25, 0.5, 0.75, 1].map((f, i) => (
          <text key={i} x={CX + 8} y={CY - RR * f + 20} fontSize="14" letterSpacing="1.5"
                fill={rgba(GREEN, k, 0.4)}>{(NM_AT_EDGE * f).toFixed(0)} NM</text>
        ))}
      </svg>

      {/* header */}
      <div style={{ position: 'absolute', left: 60, top: 40 }}>
        <div style={{ fontSize: 15, letterSpacing: '.42em', color: rgba(GREEN, k, 0.55) }}>SENTINEL — ISR</div>
        <div style={{ fontSize: 30, letterSpacing: '.14em', color: rgba(GREEN, k, 0.95), marginTop: 10 }}>
          SAN FRANCISCO BAY · PPI SURVEILLANCE
        </div>
      </div>

      {/* right column */}
      <div style={{ position: 'absolute', left: 1300, top: 170, width: 550 }}>
        <div style={{ fontSize: 14, letterSpacing: '.28em', color: rgba(GREEN, k, 0.5),
                      borderBottom: `1px solid ${rgba(GREEN, k, 0.25)}`, paddingBottom: 12 }}>
          SURFACE CONTACTS
        </div>
        {rows.map((s, i) => {
          const gone = s.target && lost;
          const col = gone ? 'rgb(255,120,105)' : rgba(GREEN, k, 0.82);
          return (
            <div key={i} style={{ display: 'flex', alignItems: 'baseline', gap: 18, padding: '13px 12px',
                                  borderBottom: `1px solid ${rgba(GREEN, k, 0.12)}`,
                                  background: gone ? 'rgba(255,74,58,0.14)' : 'transparent' }}>
              <span style={{ width: 10, height: 10, background: col, flex: '0 0 auto' }}></span>
              <span style={{ fontSize: 21, letterSpacing: '.08em', color: col, flex: '1 1 auto' }}>{s.n}</span>
              <span style={{ fontSize: 18, color: gone ? 'rgb(255,120,105)' : rgba(GREEN, k, 0.5) }}>
                {gone ? 'NO RETURN' : `${String(Math.round((ang(s) + 450) % 360)).padStart(3, '0')}° · ${(rad(s) / RR * NM_AT_EDGE).toFixed(1)} NM`}
              </span>
            </div>
          );
        })}
      </div>

      <div style={{ position: 'absolute', left: 1300, top: 690, fontSize: 17, lineHeight: 2,
                    letterSpacing: '.1em', color: rgba(GREEN, k, 0.45) }}>
        <div>SWEEP {Math.round(60 / PERIOD)} RPM · RANGE {NM_AT_EDGE} NM</div>
        <div>REVOLUTION {Math.floor(t / PERIOD) + 1}</div>
        <div>MODE X-BAND · 9.41 GHz</div>
      </div>

      {lost && (
        <div style={{ position: 'absolute', left: 1300, top: 850, width: 550, padding: '20px 22px',
                      background: 'rgba(60,10,7,0.9)', border: '2px solid rgb(255,74,58)' }}>
          <div style={{ fontSize: 15, letterSpacing: '.26em', color: 'rgb(255,120,105)' }}>◆ CONTACT LOST</div>
          <div style={{ fontSize: 27, letterSpacing: '.06em', color: '#ffd9d4', marginTop: 10 }}>MV SABLE ROCK</div>
          <div style={{ fontSize: 17, letterSpacing: '.08em', color: 'rgb(226,150,140)', marginTop: 8 }}>
            NO RETURN ON LAST SWEEP · TRANSPONDER DARK
          </div>
        </div>
      )}
    </div>
  );
}

window.RadarPiece = function RadarPiece() {
  return (
    <SceneStage width={W} height={H} scenes={window.OM_SCENES} playback={window.OM_PLAYBACK} bg="#04070a">
      {{ Radar: RadarScene }}
    </SceneStage>
  );
};
