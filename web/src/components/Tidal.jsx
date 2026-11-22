/**
 * TIDAL · website hero, made NotchFlow's
 *
 * The first screen of the site. A live map of flowing lines fills the screen:
 * isotherms (lines of equal temperature, every half degree) drawn in canvas
 * over a faint heat field, coloured from cold blue to warm coral. The front
 * meanders, warm and cold rings drift, and the lines part and swirl around the
 * pointer like water around a hand. A probe follows the pointer, and the card
 * is a small NotchFlow panel: one line typed into the notch and where it went.
 *
 * One file, React only, its CSS inside it. The typefaces come from Google Fonts
 * (loaded in the CSS).
 *
 *   <Tidal onCta={download} logo="/icon.png" />
 *
 * Props
 *   region     which current the map draws        "gulf-stream" | "kuroshio" | "agulhas"   ("gulf-stream")
 *   interval   degrees between two isotherms      0.25 | 0.5 | 1                            (0.5)
 *   brand      the wordmark                        "NotchFlow"
 *   logo       the mark's image URL (36 px)        optional; a wave mark is drawn without it
 *   links      nav links                           [[label, href], …]
 *   aside      the link at the nav's right         [label, href]
 *   cta        the main button                     "Download for macOS"
 *   onCta      called when the button is pressed
 *   more       the secondary link                  [label, href]
 *   sound      a sonar tick each time the probe crosses an isotherm, and on the button   true
 *
 * Fills its container's width; height is var(--design-h, 100svh), never under
 * 640px. Responsive by container query. Paused off screen. Reduced motion: one
 * still frame of the map, the probe rests, nothing drifts, the card stays put.
 */

import { useCallback, useEffect, useRef, useState } from "react";

// Each current: a seed for its meanders, and which side the warm water is on.
const REGIONS = {
  "gulf-stream": { south: false, seed: 0.4 },
  kuroshio: { south: false, seed: 2.1 },
  agulhas: { south: true, seed: 4.7 },
};

// Cold to warm: abyssal blue, cyan, pale sand, coral.
const RAMP = [
  [4, 32, 84, 160],
  [10, 41, 150, 196],
  [16, 96, 214, 208],
  [21, 236, 226, 170],
  [25, 255, 160, 110],
  [29, 255, 102, 84],
];
function ramp(t) {
  if (t <= RAMP[0][0]) return [RAMP[0][1], RAMP[0][2], RAMP[0][3]];
  for (let i = 1; i < RAMP.length; i++) {
    const [b, r1, g1, bl1] = RAMP[i];
    if (t <= b) {
      const [a, r0, g0, bl0] = RAMP[i - 1];
      const k = (t - a) / (b - a);
      return [r0 + (r1 - r0) * k, g0 + (g1 - g0) * k, bl0 + (bl1 - bl0) * k];
    }
  }
  const l = RAMP[RAMP.length - 1];
  return [l[1], l[2], l[3]];
}

// The ocean: a meandering front between cold and warm water, drifting rings, fine texture.
// u, v are 0..1 across and down the map; a is the map's width / height; t is seconds.
function front(u, t, seed) {
  return 0.7 - 0.42 * u + 0.075 * Math.sin(u * 6.4 + t * 0.11 + seed) + 0.032 * Math.sin(u * 14.5 - t * 0.17 + seed * 2.3);
}
function sea(u, v, a, t, seed, south) {
  const s = south ? -1 : 1;
  const f = front(u, t, seed);
  let T = 16.4 + 8.6 * Math.tanh((v - f) * 7.5 * s) + s * (v - 0.5) * 3.2;
  // Warm rings pinched off north of the front, cold rings south of it.
  for (let i = 0; i < 4; i++) {
    const eu = 0.18 + i * 0.24 + 0.03 * Math.sin(t * 0.05 + i * 1.7 + seed);
    const warm = i % 2 === 0;
    const ev = front(eu, t, seed) + (warm ? -0.17 : 0.18) * s + 0.02 * Math.cos(t * 0.04 + i);
    const dx = (u - eu) * a;
    const dy = v - ev;
    T += (warm ? 3.4 : -3.1) * Math.exp(-(dx * dx + dy * dy) / 0.0065);
  }
  T += 0.42 * Math.sin(u * a * 21 + v * 8 + t * 0.32) * Math.sin(v * 17 - u * a * 6 - t * 0.21);
  return T;
}

// What the card shows: one line typed into the notch, and where NotchFlow sent it.
const SCENES = [
  { tab: "Ask", prompt: "18% tip on 284.60 split 3 ways", value: "111.94", unit: "", side: "each", note: "+51.23 tip", warm: true, input: "Ask anything" },
  { tab: "Note", prompt: "Idea: a weekly digest of agent runs", value: "Saved", unit: "", side: "Notes", note: "Apple Notes", warm: false, input: "Save a thought" },
  { tab: "Remind", prompt: "Call the dentist tomorrow at 10", value: "10:00", unit: "AM", side: "Tomorrow", note: "Reminders", warm: true, input: "Set a reminder" },
  { tab: "Agent", prompt: "Fix the flaky login test", value: "Codex", unit: "", side: "Working", note: "in ~/code/app", warm: false, input: "Describe a task" },
];

const NAV = [["Features", "#features"], ["Agents", "#agents"], ["Install", "#install"], ["FAQ", "#faq"]];

export default function Tidal({
  region = "gulf-stream",
  interval = 0.5,
  brand = "NotchFlow",
  logo,
  links = NAV,
  aside = ["GitHub", "https://github.com/sidhxntt/notchflow"],
  cta = "Download for macOS",
  onCta,
  more = ["See what it does", "#features"],
  sound = true,
}) {
  const R = REGIONS[region] ?? REGIONS["gulf-stream"];
  const root = useRef(null);
  const canvas = useRef(null);
  const card = useRef(null);
  const probe = useRef(null);
  const tick = useTick(sound);
  const press = () => {
    tick(640, 0.05, 0.045, "triangle");
    onCta?.();
  };
  const [dot, setDot] = useState(18.4);
  const [scene, setScene] = useState(0);
  const [held, setHeld] = useState(false);

  // The card steps through the four destinations, like the notch would.
  useEffect(() => {
    if (held || window.matchMedia("(prefers-reduced-motion: reduce)").matches) return undefined;
    const id = setInterval(() => setScene((s) => (s + 1) % SCENES.length), 4200);
    return () => clearInterval(id);
  }, [held]);

  useEffect(() => {
    const el = root.current;
    const cv = canvas.current;
    const pr = probe.current;
    if (!el || !cv || !pr) return;
    const ctx = cv.getContext("2d");
    if (!ctx) return;
    const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const heat = document.createElement("canvas");
    const hctx = heat.getContext("2d");
    const torch = document.createElement("canvas"); // the lit circle around the probe
    const tctx = torch.getContext("2d");
    if (!hctx || !tctx) return;

    let W = 0, H = 0, dpr = 1, G = 10, cols = 0, rows = 0;
    let field = new Float32Array(0);
    let img = null;
    let anchor = { x: 0, y: 0 }; // where the leader line meets the card
    const resize = () => {
      const r = el.getBoundingClientRect();
      W = Math.max(1, r.width);
      H = Math.max(1, r.height);
      dpr = Math.min(2, window.devicePixelRatio || 1);
      cv.width = Math.round(W * dpr);
      cv.height = Math.round(H * dpr);
      G = W < 600 ? 8 : 10;
      cols = Math.ceil(W / G) + 1;
      rows = Math.ceil(H / G) + 1;
      field = new Float32Array(cols * rows);
      heat.width = cols;
      heat.height = rows;
      img = hctx.createImageData(cols, rows);
      const c = card.current?.getBoundingClientRect();
      anchor = c ? { x: c.left - r.left + (W < 600 ? c.width * 0.72 : 0), y: c.top - r.top + (W < 600 ? 0 : 22) } : { x: W * 0.8, y: H * 0.7 };
    };
    resize();
    const ro = new ResizeObserver(() => {
      resize();
      if (still) draw();
    });
    ro.observe(el);

    // Pointer: eased, with a strength that fades in on hover and out on leave.
    const rest = () => ({ x: W * (W < 600 ? 0.58 : 0.62), y: H * (W < 600 ? 0.6 : 0.47) });
    let m = rest();
    let target = rest();
    // The lens is half on at rest, fully on under the pointer.
    const REST_ON = 0.5;
    let on = REST_ON;
    let onTarget = REST_ON;
    const move = (e) => {
      const r = el.getBoundingClientRect();
      target = { x: e.clientX - r.left, y: e.clientY - r.top };
      onTarget = 1;
    };
    const leave = () => {
      target = rest();
      onTarget = REST_ON;
    };
    if (!still) {
      el.addEventListener("pointermove", move);
      el.addEventListener("pointerleave", leave);
    }

    let t = 8;
    const a = () => W / H;
    const draw = () => {
      const A = a();
      const lens = Math.min(W, H) * 0.15;
      const stone = W < 600 ? 34 : 44;
      const L2 = lens * lens;
      // 1. Sample the ocean on the grid, through the pointer's lens (magnify + swirl).
      for (let j = 0; j < rows; j++) {
        for (let i = 0; i < cols; i++) {
          let x = i * G;
          let y = j * G;
          if (on > 0.001) {
            // Water around a stone: potential flow past a disc of radius Rs (p' = d(1 − Rs²/r²)),
            // plus a gentle swirl that fades with distance. Inside the disc there are no lines.
            const dx = x - m.x;
            const dy = y - m.y;
            const r2 = dx * dx + dy * dy;
            const Rs2 = stone * stone * on * on;
            const sc = r2 <= Rs2 ? 0 : 1 - Rs2 / r2;
            const th = 0.7 * on * Math.exp(-r2 / L2);
            const c = Math.cos(th), s = Math.sin(th);
            x = m.x + (dx * c - dy * s) * sc;
            y = m.y + (dx * s + dy * c) * sc;
          }
          field[j * cols + i] = sea(x / W, y / H, A, t, R.seed, R.south);
        }
      }
      // 2. The heat underneath: one pixel per grid node, stretched and smoothed, kept dark.
      if (img) {
        const d = img.data;
        for (let p = 0; p < field.length; p++) {
          const [r, g, b] = ramp(field[p]);
          d[p * 4] = 3 + r * 0.24;
          d[p * 4 + 1] = 12 + g * 0.2;
          d[p * 4 + 2] = 22 + b * 0.3;
          d[p * 4 + 3] = 255;
        }
        hctx.putImageData(img, 0, 0);
      }
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.imageSmoothingEnabled = true;
      ctx.drawImage(heat, 0, 0, cols * G * dpr, rows * G * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

      // 3. Isotherms by marching squares, one path per level.
      const step = interval > 0 ? interval : 0.5;
      const paths = new Map();
      const ex = new Float32Array(8);
      for (let j = 0; j < rows - 1; j++) {
        for (let i = 0; i < cols - 1; i++) {
          const v0 = field[j * cols + i];
          const v1 = field[j * cols + i + 1];
          const v2 = field[(j + 1) * cols + i + 1];
          const v3 = field[(j + 1) * cols + i];
          const lo = Math.min(v0, v1, v2, v3);
          const hi = Math.max(v0, v1, v2, v3);
          const x0 = i * G, y0 = j * G;
          for (let n = Math.ceil(lo / step); n * step <= hi; n++) {
            const L = n * step;
            let c = 0;
            // crossings on top, right, bottom, left
            if ((v0 - L) * (v1 - L) < 0) { ex[c++] = x0 + ((L - v0) / (v1 - v0)) * G; ex[c++] = y0; }
            if ((v1 - L) * (v2 - L) < 0) { ex[c++] = x0 + G; ex[c++] = y0 + ((L - v1) / (v2 - v1)) * G; }
            if ((v3 - L) * (v2 - L) < 0) { ex[c++] = x0 + ((L - v3) / (v2 - v3)) * G; ex[c++] = y0 + G; }
            if ((v0 - L) * (v3 - L) < 0) { ex[c++] = x0; ex[c++] = y0 + ((L - v0) / (v3 - v0)) * G; }
            if (c < 4) continue;
            let p = paths.get(n);
            if (!p) { p = new Path2D(); paths.set(n, p); }
            p.moveTo(ex[0], ex[1]);
            p.lineTo(ex[2], ex[3]);
            if (c === 8) { p.moveTo(ex[4], ex[5]); p.lineTo(ex[6], ex[7]); }
          }
        }
      }
      ctx.lineCap = "round";
      const majorEvery = Math.max(1, Math.round(2 / step));
      for (const [n, p] of paths) {
        const L = n * step;
        const [r, g, b] = ramp(L);
        const major = n % majorEvery === 0;
        ctx.strokeStyle = `rgba(${r | 0},${g | 0},${b | 0},${major ? 0.92 : 0.42})`;
        ctx.lineWidth = major ? 1.25 : 0.7;
        ctx.stroke(p);
      }

      // 4. The torch: the same lines again, brighter, inside a soft circle around the probe.
      const s = lens * 1.15;
      const ts = Math.ceil(s * 2 * dpr);
      if (torch.width !== ts) { torch.width = ts; torch.height = ts; }
      tctx.globalCompositeOperation = "source-over";
      tctx.setTransform(1, 0, 0, 1, 0, 0);
      tctx.clearRect(0, 0, ts, ts);
      tctx.setTransform(dpr, 0, 0, dpr, (s - m.x) * dpr, (s - m.y) * dpr);
      tctx.lineCap = "round";
      for (const [n, p] of paths) {
        const [r, g, b] = ramp(n * step);
        tctx.strokeStyle = `rgb(${Math.min(255, r + 40) | 0},${Math.min(255, g + 40) | 0},${Math.min(255, b + 40) | 0})`;
        tctx.lineWidth = n % majorEvery === 0 ? 1.8 : 1.1;
        tctx.stroke(p);
      }
      tctx.setTransform(1, 0, 0, 1, 0, 0);
      tctx.globalCompositeOperation = "destination-in";
      const rg = tctx.createRadialGradient(ts / 2, ts / 2, 0, ts / 2, ts / 2, ts / 2);
      rg.addColorStop(0, "rgba(0,0,0,1)");
      rg.addColorStop(0.55, "rgba(0,0,0,.55)");
      rg.addColorStop(1, "rgba(0,0,0,0)");
      tctx.fillStyle = rg;
      tctx.fillRect(0, 0, ts, ts);
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.globalAlpha = Math.min(1, on * 1.4);
      ctx.drawImage(torch, Math.round((m.x - s) * dpr), Math.round((m.y - s) * dpr));
      ctx.globalAlpha = 1;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

      // 5. The leader from the probe to the card.
      ctx.strokeStyle = "rgba(230,246,244,.38)";
      ctx.lineWidth = 1;
      ctx.setLineDash([2, 4]);
      ctx.beginPath();
      ctx.moveTo(m.x, m.y);
      ctx.lineTo(anchor.x, anchor.y);
      ctx.stroke();
      ctx.setLineDash([]);
      pr.style.transform = `translate3d(${m.x.toFixed(1)}px, ${m.y.toFixed(1)}px, 0)`;
    };

    // The probe reads the water under it twice a second: its dot takes that colour.
    let band = NaN; // which isotherm band the probe is in; a tick when it changes under the hand
    const sample = () => {
      const T = sea(m.x / W, m.y / H, a(), t, R.seed, R.south);
      const b = Math.floor(T / (interval > 0 ? interval : 0.5));
      if (b !== band && onTarget === 1 && !Number.isNaN(band)) tick(520 + T * 34, 0.04, 0.03, "sine");
      band = b;
      setDot(T);
    };
    draw();
    sample();
    if (still) return () => ro.disconnect();

    let raf = 0;
    let last = performance.now();
    let acc = 0;
    let visible = true;
    const frame = (now) => {
      const dt = Math.min(0.05, (now - last) / 1000);
      last = now;
      t += dt;
      m = { x: m.x + (target.x - m.x) * 0.09, y: m.y + (target.y - m.y) * 0.09 };
      on += (onTarget - on) * 0.06;
      draw();
      acc += dt;
      if (acc > 0.5) { acc = 0; sample(); }
      if (visible) raf = requestAnimationFrame(frame);
    };
    raf = requestAnimationFrame(frame);
    const io = new IntersectionObserver(([e]) => {
      visible = e.isIntersecting;
      cancelAnimationFrame(raf);
      if (visible) { last = performance.now(); raf = requestAnimationFrame(frame); }
    });
    io.observe(el);
    return () => {
      cancelAnimationFrame(raf);
      io.disconnect();
      ro.disconnect();
      el.removeEventListener("pointermove", move);
      el.removeEventListener("pointerleave", leave);
    };
  }, [region, interval, R, tick]);

  const [r, g, b] = ramp(dot);
  const legendStops = RAMP.map(([tt, rr, gg, bb]) => `rgb(${rr},${gg},${bb}) ${(((tt - 4) / 25) * 100).toFixed(0)}%`).join(", ");
  const s = SCENES[scene];

  return (
    <div ref={root} className="td-root" id="top" style={{ "--td-dot": `rgb(${r | 0},${g | 0},${b | 0})` }}>
      <style>{css}</style>
      <canvas ref={canvas} className="td-map" aria-hidden />
      <div className="td-shade" aria-hidden />
      <div ref={probe} className="td-probe" aria-hidden>
        <span />
      </div>

      <header className="td-nav">
        <a className="td-brand" href="#top" aria-label={`${brand} home`}>
          {logo ? (
            <img src={logo} alt="" />
          ) : (
            <svg viewBox="0 0 24 24" aria-hidden>
              <path d="M2.5 8.5c3-2.4 6-2.4 9.5 0s6.5 2.4 9.5 0" />
              <path d="M2.5 13c3-2.4 6-2.4 9.5 0s6.5 2.4 9.5 0" opacity=".7" />
              <path d="M2.5 17.5c3-2.4 6-2.4 9.5 0s6.5 2.4 9.5 0" opacity=".4" />
            </svg>
          )}
          {brand}
        </a>
        <nav className="td-links" aria-label="Main">
          {links.map(([label, href]) => <a key={href} href={href}>{label}</a>)}
        </nav>
        <a className="td-signin" href={aside[1]} target="_blank" rel="noreferrer">{aside[0]}</a>
      </header>

      <div className="td-copy">
        <h1 className="td-title">
          <span>A small notch </span>
          <span>that does the most.</span>
        </h1>
        <p className="td-sub">
          Type into the notch. NotchFlow answers, saves notes, sets reminders and runs your coding agents, then folds back
          into the black bar.
        </p>
        <div className="td-actions">
          <button type="button" className="td-btn" onClick={press}>
            {cta}
            <svg viewBox="0 0 16 16" aria-hidden>
              <path d="M3 8h10M9 4l4 4-4 4" />
            </svg>
          </button>
          <a className="td-link" href={more[1]}>
            {more[0]}
          </a>
        </div>
      </div>

      <aside ref={card} className="td-card" aria-label={`${brand} preview: ${s.tab}`} onPointerEnter={() => setHeld(true)}>
        <div className="td-card-head">
          <span className="td-live" aria-hidden />
          <span>In your notch · {s.tab}</span>
        </div>
        <div className="td-scene" key={scene}>
          <p className="td-coord">{s.prompt}</p>
          <div className="td-reading">
            <p className="td-temp" aria-live="polite">
              {s.value}
              {s.unit && <span>{s.unit}</span>}
            </p>
            <p className={s.warm ? "td-anom td-warm" : "td-anom"}>
              {s.side}
              <span>{s.note}</span>
            </p>
          </div>
        </div>
        <div className="td-input" aria-hidden>
          <span>{s.input}</span>
          <b>↵</b>
        </div>
        <div className="td-spark-axis" role="group" aria-label="Destinations">
          {SCENES.map((x, i) => (
            <button
              type="button"
              key={x.tab}
              className={i === scene ? "td-tab td-tab-on" : "td-tab"}
              aria-pressed={i === scene}
              onClick={() => { setScene(i); setHeld(true); }}
            >
              {x.tab}
            </button>
          ))}
        </div>
        <p className="td-src">Hover the notch or press your shortcut</p>
      </aside>

      <div className="td-legend" aria-hidden>
        <span>small</span>
        <i style={{ background: `linear-gradient(90deg, ${legendStops})` }} />
        <span>does the most</span>
        <em>7-day free trial · macOS 14+ · Apple silicon</em>
      </div>
    </div>
  );
}

const css = `
@import url('https://fonts.googleapis.com/css2?family=Geologica:wght@300;400;500&family=Martian+Mono:wdth,wght@87.5,400&display=swap');

.td-root {
  container-type: inline-size;
  position: relative; isolation: isolate; overflow: hidden;
  width: 100%; height: var(--design-h, 100svh); min-height: 640px;
  background: #030f15; color: #e7f3f1;
  font-family: "Geologica", ui-sans-serif, system-ui, "Segoe UI", Roboto, sans-serif;
  -webkit-font-smoothing: antialiased;
}
.td-map { position: absolute; inset: 0; width: 100%; height: 100%; z-index: -3; }
.td-shade {
  position: absolute; inset: 0; z-index: -2; pointer-events: none;
  background:
    linear-gradient(90deg, rgba(2,10,14,.82) 0%, rgba(2,10,14,.6) 30%, rgba(2,10,14,.1) 56%, rgba(2,10,14,0) 70%),
    linear-gradient(180deg, rgba(2,10,14,.7) 0%, rgba(2,10,14,0) 16%, rgba(2,10,14,0) 82%, rgba(2,10,14,.6) 100%);
}
.td-probe {
  position: absolute; left: 0; top: 0; z-index: -1; width: 0; height: 0; pointer-events: none;
  will-change: transform;
}
.td-probe::before, .td-probe::after {
  content: ""; position: absolute; left: -15px; top: -15px; width: 30px; height: 30px; border-radius: 50%;
  border: 1px solid rgba(240,250,248,.9);
}
.td-probe::after { animation: td-ring 2.6s cubic-bezier(.2,.6,.3,1) infinite; border-color: var(--td-dot); }
.td-probe span {
  position: absolute; left: -4px; top: -4px; width: 8px; height: 8px; border-radius: 50%;
  background: var(--td-dot); box-shadow: 0 0 0 2px #030f15;
}
@keyframes td-ring { from { transform: scale(.6); opacity: .9; } to { transform: scale(2.4); opacity: 0; } }

.td-nav { position: absolute; inset: 26px 40px auto; display: flex; align-items: center; gap: 32px; }
.td-brand {
  display: inline-flex; align-items: center; gap: 10px; color: inherit; text-decoration: none;
  font-size: 20px; font-weight: 500; letter-spacing: -.02em;
}
.td-brand svg { width: 36px; height: 36px; fill: none; stroke: #62d7cf; stroke-width: 1.8; stroke-linecap: round; }
.td-brand img { width: 36px; height: 36px; display: block; border-radius: 8px; object-fit: cover; }
.td-links { display: flex; gap: 28px; margin-left: 24px; font-size: 15px; }
.td-links a, .td-signin { color: rgba(231,243,241,.74); text-decoration: none; transition: color .2s; }
.td-links a:hover, .td-signin:hover { color: #fff; }
.td-signin { margin-left: auto; font-size: 15px; }
.td-links a:focus-visible, .td-signin:focus-visible, .td-brand:focus-visible, .td-link:focus-visible, .td-tab:focus-visible { outline: 2px solid #62d7cf; outline-offset: 4px; border-radius: 4px; }

.td-copy { position: absolute; left: 40px; bottom: 13%; width: min(760px, 56%); }
.td-title {
  margin: 0; font-weight: 300; font-size: clamp(44px, 5.5cqi, 88px);
  line-height: .98; letter-spacing: -.045em;
}
.td-title span { display: block; animation: td-rise 1.1s cubic-bezier(.2,.8,.2,1) both; }
.td-title span + span { animation-delay: .1s; color: #f2e4b0; }
@keyframes td-rise { from { opacity: 0; transform: translateY(24px); } }
.td-sub {
  margin: 24px 0 0; max-width: 470px; font-size: 17px; line-height: 1.5; font-weight: 300; color: rgba(231,243,241,.8);
  animation: td-rise 1.1s .2s cubic-bezier(.2,.8,.2,1) both;
}
.td-actions {
  display: flex; align-items: center; flex-wrap: wrap; gap: 14px 26px; margin-top: 30px;
  animation: td-rise 1.1s .3s cubic-bezier(.2,.8,.2,1) both;
}
.td-btn {
  display: inline-flex; align-items: center; gap: 10px; height: 48px; padding: 0 22px; border: 0; border-radius: 6px;
  font: inherit; font-size: 15px; font-weight: 500; cursor: pointer; color: #04161b; background: #e9f7f3;
  box-shadow: inset 0 -2px 0 rgba(4,22,27,.14);
  transition: transform .25s cubic-bezier(.3,1.4,.5,1), background .2s;
}
.td-btn:hover { background: #fff; transform: translateY(-1px); }
.td-btn:active { transform: scale(.97); }
.td-btn:focus-visible { outline: 2px solid #62d7cf; outline-offset: 3px; }
.td-btn svg { width: 16px; height: 16px; fill: none; stroke: currentColor; stroke-width: 1.6; stroke-linecap: round; stroke-linejoin: round; transition: transform .25s; }
.td-btn:hover svg { transform: translateX(3px); }
.td-link {
  color: #e7f3f1; font-size: 15px; text-decoration: none;
  background: linear-gradient(currentColor, currentColor) 0 100% / 100% 1px no-repeat; padding-bottom: 3px;
  opacity: .82; transition: opacity .2s;
}
.td-link:hover { opacity: 1; }

.td-card {
  position: absolute; right: 40px; bottom: 12%; width: 304px; padding: 18px 20px 16px;
  border-radius: 10px; color: #e7f3f1;
  background: rgba(3,16,22,.78);
  box-shadow: inset 0 0 0 1px rgba(98,215,207,.22), 0 24px 50px -24px rgba(0,0,0,.9);
  backdrop-filter: blur(12px); -webkit-backdrop-filter: blur(12px);
  animation: td-rise 1.2s .45s cubic-bezier(.2,.8,.2,1) both;
}
.td-card-head { display: flex; align-items: center; gap: 9px; font-size: 13px; color: rgba(231,243,241,.72); }
.td-live { width: 7px; height: 7px; border-radius: 50%; background: var(--td-dot); transition: background .4s; }
.td-scene { animation: td-swap .45s cubic-bezier(.2,.8,.2,1) both; }
@keyframes td-swap { from { opacity: 0; transform: translateY(4px); } }
.td-coord {
  margin: 12px 0 0; font-family: "Martian Mono", ui-monospace, "SF Mono", Menlo, monospace;
  font-size: 12px; color: rgba(231,243,241,.66); font-variant-numeric: tabular-nums;
  white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
}
.td-reading { display: flex; align-items: baseline; justify-content: space-between; gap: 12px; margin-top: 4px; }
.td-temp {
  margin: 0; font-size: 54px; font-weight: 300; letter-spacing: -.05em; line-height: 1.05;
  font-variant-numeric: tabular-nums; white-space: nowrap;
}
.td-temp span { font-size: 20px; letter-spacing: 0; margin-left: 4px; color: rgba(231,243,241,.6); }
.td-temp { min-width: 0; }
.td-anom {
  flex: none; margin: 0; text-align: right; font-size: 17px; font-weight: 400; color: #8fd8f0; font-variant-numeric: tabular-nums;
}
.td-anom.td-warm { color: #ff9a76; }
.td-anom span { display: block; font-size: 12px; color: rgba(231,243,241,.56); margin-top: 2px; white-space: nowrap; }
.td-input {
  display: flex; align-items: center; justify-content: space-between; height: 34px; margin-top: 12px; padding: 0 6px 0 12px;
  border-radius: 7px; box-shadow: inset 0 0 0 1px rgba(98,215,207,.2); background: rgba(231,243,241,.03);
  font-size: 12px; color: rgba(231,243,241,.5);
}
.td-input b {
  width: 22px; height: 22px; display: grid; place-items: center; border-radius: 5px;
  background: var(--td-dot); color: #04161b; font-size: 12px; font-weight: 500; transition: background .4s;
}
.td-spark-axis { display: flex; justify-content: space-between; margin-top: 4px; font-size: 12px; color: rgba(231,243,241,.5); }
.td-tab {
  border: 0; background: none; padding: 6px 0 0; font: inherit; font-size: 12px; color: rgba(231,243,241,.5);
  cursor: pointer; transition: color .2s;
}
.td-tab:hover, .td-tab-on { color: #e7f3f1; }
.td-tab-on { box-shadow: 0 1px 0 var(--td-dot); }
.td-src {
  margin: 12px 0 0; padding-top: 12px; border-top: 1px solid rgba(98,215,207,.16);
  font-size: 12px; color: rgba(231,243,241,.6);
}

.td-legend {
  position: absolute; left: 40px; bottom: 28px; display: flex; align-items: center; gap: 10px;
  font-family: "Martian Mono", ui-monospace, "SF Mono", Menlo, monospace; font-size: 12px; color: rgba(231,243,241,.6);
  font-variant-numeric: tabular-nums;
}
.td-legend i { display: block; width: 150px; height: 4px; border-radius: 2px; }
.td-legend em { font-style: normal; margin-left: 12px; }

@container (max-width: 980px) {
  .td-links { display: none; }
  .td-copy { width: auto; right: 40px; bottom: auto; top: 120px; }
  .td-card { bottom: 72px; }
}
@container (max-width: 560px) {
  .td-nav { inset: 18px 20px auto; }
  .td-brand { font-size: 18px; }
  .td-shade {
    background: linear-gradient(180deg, rgba(2,10,14,.9) 0%, rgba(2,10,14,.78) 42%, rgba(2,10,14,.1) 64%, rgba(2,10,14,.2) 78%, rgba(2,10,14,.7) 100%);
  }
  .td-copy { left: 20px; right: 20px; top: 84px; }
  .td-title { font-size: 39px; letter-spacing: -.04em; text-wrap: balance; }
  .td-title span { display: inline; }
  .td-sub { font-size: 15px; margin-top: 16px; }
  .td-actions { margin-top: 22px; gap: 12px 20px; }
  .td-btn { height: 46px; padding: 0 18px; }
  .td-card { left: 20px; right: 20px; width: auto; bottom: 52px; padding: 14px 16px 12px; }
  .td-temp { font-size: 38px; }
  .td-coord { margin-top: 8px; }
  .td-input { height: 30px; margin-top: 8px; }
  .td-src { display: none; }
  .td-legend { left: 20px; bottom: 18px; }
  .td-legend i { width: 96px; }
  .td-legend em { display: none; }
}
@media (prefers-reduced-motion: reduce) {
  .td-title span, .td-sub, .td-actions, .td-card, .td-scene { animation: none; }
  .td-probe::after { animation: none; opacity: 0; }
}
`;

// Sound: one tiny synthesized tick (an oscillator through a 4 ms attack and a short
// exponential tail; no files). Silent with sound={false}, while the page is muted
// (<html data-cd-mute="1">) and before the visitor's first click or key. The
// AudioContext is created lazily on the first sound and closed on unmount.
function useTick(on) {
  const ac = useRef(null);
  const enabled = useRef(on);
  useEffect(() => {
    enabled.current = on;
  }, [on]);
  useEffect(
    () => () => {
      void ac.current?.close();
      ac.current = null;
    },
    [],
  );
  return useCallback((freq = 1100, len = 0.035, peak = 0.04, wave = "sine") => {
    if (!enabled.current || document.documentElement.dataset.cdMute === "1") return;
    const ua = navigator.userActivation;
    if (ua && !ua.hasBeenActive) return;
    const AC = window.AudioContext ?? window.webkitAudioContext;
    if (!AC) return;
    try {
      const ctx = ac.current ?? (ac.current = new AC());
      if (ctx.state === "suspended") void ctx.resume();
      const t = ctx.currentTime;
      const o = ctx.createOscillator();
      const g = ctx.createGain();
      o.type = wave;
      o.frequency.setValueAtTime(freq, t);
      o.frequency.exponentialRampToValueAtTime(freq * 0.55, t + len);
      g.gain.setValueAtTime(0.0001, t);
      g.gain.exponentialRampToValueAtTime(Math.min(peak, 0.06), t + 0.004);
      g.gain.exponentialRampToValueAtTime(0.0001, t + Math.min(len, 0.06));
      o.connect(g);
      g.connect(ctx.destination);
      o.start(t);
      o.stop(t + Math.min(len, 0.06) + 0.02);
    } catch {
      /* sound is a nicety; never break the page for it */
    }
  }, []);
}
