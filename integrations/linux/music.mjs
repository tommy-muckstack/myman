// Built-in demo music, composed by code at render time. No recorded samples
// or third-party audio are involved: each track is a deterministic function
// of this file, so every machine renders the same audio and there is nothing
// to license. The generated audio is dedicated to the public domain (CC0 1.0).
// Each track is one seamless loop (note tails and reverb wrap around), which
// polish repeats and trims to the video's length.
export const RATE = 44100;
export const VERSION = 1;
export const LICENSE = 'CC0-1.0 (composed by MyMan from code; no samples)';
export const TRACKS = {
  upbeat: { bpm: 116, bars: 16, about: 'Bright and energetic: plucked synth arpeggio, soft four-on-the-floor beat, warm pad.' },
  calm: { bpm: 84, bars: 16, about: 'Relaxed and friendly: electric piano chords, gentle pad and bass, no drums.' },
  cinematic: { bpm: 72, bars: 16, about: 'Big and building: low strings, pulsing octaves, deep hits and swells.' },
};

const hz = m => 440 * 2 ** ((m - 69) / 12);
const TAU = 2 * Math.PI;
function rng(seed) { return () => { seed = (seed + 0x6D2B79F5) | 0; let t = Math.imul(seed ^ (seed >>> 15), 1 | seed); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; }

// A stereo bus of one loop. add() writes a voice, wrapping past the end so the loop is seamless.
class Bus {
  constructor(n) { this.n = n; this.l = new Float32Array(n); this.r = new Float32Array(n); }
  add(t0, seconds, gain, pan, fn) {
    const s0 = Math.round(t0 * RATE), len = Math.round(seconds * RATE), gl = gain * Math.cos((pan + 1) * Math.PI / 4), gr = gain * Math.sin((pan + 1) * Math.PI / 4);
    // Every voice fades over its last 8ms, so a cut-off tail never clicks.
    const fade = Math.min(len, Math.round(0.008 * RATE));
    for (let i = 0; i < len; i++) { const v = fn(i / RATE) * (i >= len - fade ? (len - i) / fade : 1); const k = (s0 + i) % this.n; this.l[k] += v * gl; this.r[k] += v * gr; }
  }
  mix(other, gain = 1) { for (let i = 0; i < this.n; i++) { this.l[i] += other.l[i] * gain; this.r[i] += other.r[i] * gain; } }
}
// Schroeder reverb run over the loop twice so its tail wraps into the start.
function reverb(bus, size = 1, damp = 0.35) {
  const out = new Bus(bus.n), combs = [1557, 1617, 1491, 1422].map(d => Math.round(d * size)), aps = [225, 556];
  for (const [src, dst, spread] of [[bus.l, out.l, 0], [bus.r, out.r, 23]]) {
    const acc = new Float32Array(bus.n);
    for (const d0 of combs) {
      const d = d0 + spread, line = new Float32Array(d); let p = 0, lp = 0;
      for (let pass = 0; pass < 2; pass++) for (let i = 0; i < bus.n; i++) { const y = line[p]; lp = y * (1 - damp) + lp * damp; line[p] = src[i] + lp * 0.84; p = (p + 1) % d; if (pass) acc[i] += y; }
    }
    for (const d0 of aps) {
      const d = d0 + spread, line = new Float32Array(d); let p = 0;
      const tmp = Float32Array.from(acc);
      for (let pass = 0; pass < 2; pass++) for (let i = 0; i < bus.n; i++) { const b = line[p], y = -tmp[i] + b; line[p] = tmp[i] + b * 0.5; p = (p + 1) % d; if (pass) acc[i] = y; }
    }
    for (let i = 0; i < bus.n; i++) dst[i] = acc[i] * 0.06;
  }
  return out;
}
const env = (t, a, d, len, rel = 0.05) => (t < a ? t / a : 1) * (t > len ? Math.max(0, 1 - (t - len) / rel) : 1) * (d ? Math.exp(-t * d) : 1);
// Voices. Each returns a function of time (seconds since the note started).
const pluck = (f, bright = 1) => t => env(t, 0.003, 0, 9) * (Math.sin(TAU * f * t) * Math.exp(-t * 4) + 0.45 * bright * Math.sin(TAU * 2 * f * t) * Math.exp(-t * 9) + 0.2 * bright * Math.sin(TAU * 3 * f * t) * Math.exp(-t * 14));
const epiano = f => t => env(t, 0.004, 0, 9) * (Math.sin(TAU * f * t + 1.1 * Math.exp(-t * 5) * Math.sin(TAU * f * t)) * Math.exp(-t * 1.3) + 0.18 * Math.sin(TAU * 4.02 * f * t) * Math.exp(-t * 8));
const pad = (f, len, attack, cents, harmonics = 7, tilt = 0.35) => { const g = 2 ** (cents / 1200); return t => { let v = 0; for (let k = 1; k <= harmonics; k++) v += Math.sin(TAU * k * f * g * t + k) * Math.exp(-k * tilt) / k; return v * env(t, attack, 0, len, 1.2); }; };
const bass = (f, len) => t => (Math.sin(TAU * f * t) + 0.3 * Math.sin(TAU * 2 * f * t)) * env(t, 0.006, 0, len, 0.06) * (0.75 + 0.25 * Math.exp(-t * 6));
const kick = () => { let ph = 0, last = 0; return t => { const f = 45 + 80 * Math.exp(-t * 28); ph += TAU * f * (t - last); last = t; return Math.sin(ph) * Math.exp(-t * 8); }; };
const noise = (seed, hp) => { const r = rng(seed); let prev = 0; return () => { const x = r() * 2 - 1, y = hp ? x - prev : x; prev = x; return y; }; };
const clap = seed => { const n = noise(seed, true); return t => (n() * Math.exp(-t * 16) * 0.9 + Math.sin(TAU * 190 * t) * Math.exp(-t * 22) * 0.4); };
const hat = seed => { const n = noise(seed, true); return t => n() * Math.exp(-t * 42); };
const boom = () => t => Math.sin(TAU * (32 + 18 * Math.exp(-t * 3)) * t) * Math.exp(-t * 1.4);
const riser = (seed, len) => { const n = noise(seed, false); let lp = 0; return t => { const c = 0.01 + 0.25 * (t / len) ** 2; lp += (n() - lp) * c; return lp * (t / len) ** 1.5 * env(t, 0.01, 0, len, 0.02); }; };

const CHORDS = {
  upbeat: [[48, [60, 64, 67, 72]], [43, [59, 62, 67, 71]], [45, [60, 64, 69, 72]], [41, [60, 65, 69, 72]]],
  calm: [[48, [59, 64, 67, 71]], [45, [60, 64, 67, 69]], [41, [57, 60, 64, 65]], [43, [59, 62, 64, 67]]],
  cinematic: [[45, [57, 60, 64]], [41, [57, 60, 65]], [48, [55, 60, 64]], [43, [55, 59, 62]]],
};

export function compose(name) {
  const spec = TRACKS[name]; if (!spec) throw new Error(`unknown track ${name}`);
  const beat = 60 / spec.bpm, bar = beat * 4, n = Math.round(spec.bars * bar * RATE);
  const dry = new Bus(n), wet = new Bus(n), prog = CHORDS[name];
  for (let b = 0; b < spec.bars; b++) {
    const [root, notes] = prog[b % 4], t = b * bar, section = Math.floor(b / 4); // four-bar sections build a little
    if (name === 'upbeat') {
      notes.forEach((m, i) => wet.add(t, bar + 1.3, 0.05, i % 2 ? 0.4 : -0.4, pad(hz(m), bar - 0.05, 0.25, i % 2 ? 7 : -7, 6, 0.5)));
      const arp = [0, 1, 2, 3, 2, 1, 2, 3];
      for (let s = 0; s < 8; s++) { const m = notes[arp[s]] + 12, v = pluck(hz(m), 0.9); dry.add(t + s * beat / 2, beat * 1.5, 0.11, s % 2 ? 0.35 : -0.35, v); wet.add(t + s * beat / 2, beat * 1.5, 0.05, 0, v); }
      for (let s = 0; s < 8; s++) dry.add(t + s * beat / 2, beat / 2, 0.2, 0, bass(hz(root), beat / 2 - 0.04));
      for (let q = 0; q < 4; q++) dry.add(t + q * beat, 0.4, 0.5, 0, kick());
      if (section > 0) for (const q of [1, 3]) { const c = clap(b * 9 + q); dry.add(t + q * beat, 0.35, 0.11, 0, c); wet.add(t + q * beat, 0.35, 0.07, 0, c); }
      for (let q = 0; q < 4; q++) dry.add(t + q * beat + beat / 2, 0.12, 0.035, 0.25, hat(b * 13 + q));
    } else if (name === 'calm') {
      notes.forEach((m, i) => { const v = epiano(hz(m)); dry.add(t + i * 0.012, bar * 1.6, 0.075, (i - 1.5) * 0.25, v); wet.add(t + i * 0.012, bar * 1.6, 0.06, 0, v); });
      const hits = [[1.5, 2], [2.5, 3], [3.5, 1]];
      if (section % 2) hits.forEach(([q, i]) => { const v = epiano(hz(notes[i] + 12)); dry.add(t + q * beat, bar, 0.045, 0.3, v); wet.add(t + q * beat, bar, 0.05, 0, v); });
      notes.slice(0, 3).forEach((m, i) => wet.add(t, bar + 1.3, 0.035, i - 1, pad(hz(m), bar - 0.1, 0.8, i % 2 ? 6 : -6, 5, 0.7)));
      dry.add(t, bar, 0.2, 0, bass(hz(root), bar - 0.1));
      dry.add(t + 2.5 * beat, beat * 1.4, 0.12, 0, bass(hz(root + 7), beat * 1.2));
    } else {
      notes.forEach((m, i) => { wet.add(t, bar + 1.3, 0.06, i - 1, pad(hz(m - 12), bar - 0.05, 1.4, (i - 1) * 8, 8, 0.28)); wet.add(t, bar + 1.3, 0.035, 1 - i, pad(hz(m), bar - 0.05, 1.6, (1 - i) * 6, 6, 0.4)); });
      if (section > 0) for (let s = 0; s < 8; s++) { const m = (s % 2 ? root + 12 : root) + 12, v = pad(hz(m), beat / 2 - 0.06, 0.01, 0, 6, 0.45); dry.add(t + s * beat / 2, beat / 2, 0.07 + 0.02 * section, s % 2 ? 0.3 : -0.3, v); wet.add(t + s * beat / 2, beat / 2, 0.05, 0, v); }
      dry.add(t, bar + 0.1, 0.22, 0, bass(hz(root - 12), bar - 0.05));
      if (b % 4 === 0) { dry.add(t, 3, 0.55, 0, boom()); wet.add(t, 3, 0.3, 0, boom()); }
      if (b % 4 === 3) { const r = riser(b * 17, bar); wet.add(t, bar + 0.03, 0.5, 0, r); dry.add(t, bar + 0.03, 0.35, 0, r); }
      if (section >= 2) for (const q of [0, 2.5, 3]) dry.add(t + q * beat, 0.5, 0.3, 0, kick());
    }
  }
  dry.mix(reverb(wet, name === 'cinematic' ? 1.3 : 1), 1); dry.mix(wet, 0.25);
  // Level to about -18 dBFS RMS, then a soft limiter.
  let sum = 0; for (let i = 0; i < n; i++) sum += dry.l[i] ** 2 + dry.r[i] ** 2;
  const g = 0.126 / Math.sqrt(sum / (2 * n) || 1);
  for (let i = 0; i < n; i++) { dry.l[i] = Math.tanh(dry.l[i] * g * 1.2) / 1.2; dry.r[i] = Math.tanh(dry.r[i] * g * 1.2) / 1.2; }
  return { left: dry.l, right: dry.r, seconds: n / RATE };
}
// 16-bit stereo WAV bytes.
export function wav({ left, right }) {
  const n = left.length, buf = Buffer.alloc(44 + n * 4);
  buf.write('RIFF', 0); buf.writeUInt32LE(36 + n * 4, 4); buf.write('WAVEfmt ', 8); buf.writeUInt32LE(16, 16); buf.writeUInt16LE(1, 20); buf.writeUInt16LE(2, 22);
  buf.writeUInt32LE(RATE, 24); buf.writeUInt32LE(RATE * 4, 28); buf.writeUInt16LE(4, 32); buf.writeUInt16LE(16, 34); buf.write('data', 36); buf.writeUInt32LE(n * 4, 40);
  for (let i = 0; i < n; i++) { buf.writeInt16LE(Math.round(Math.max(-1, Math.min(1, left[i])) * 32767), 44 + i * 4); buf.writeInt16LE(Math.round(Math.max(-1, Math.min(1, right[i])) * 32767), 46 + i * 4); }
  return buf;
}
