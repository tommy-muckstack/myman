import { spawn } from 'node:child_process';
import path from 'node:path';
import { atomic, readSafe, statePath } from './system.mjs';
import * as recording from './recording.mjs';

// Makes agent capture visible to the person at the machine. Every screenshot
// and recording change raises a desktop notification (any freedesktop
// notifier: mako on Omarchy, dunst, GNOME, KDE), and `myman indicator`
// prints Waybar-style JSON for a bar module. This is deliberately not
// configurable by agents: there is no flag or variable that hides it.
const RECENT_SECONDS = 8;
const stateFile = () => path.join(statePath(), 'indicator.json');

function detached(command, args) {
  try {
    const child = spawn(command, args, { detached: true, stdio: 'ignore', env: process.env });
    child.on('error', () => {}); child.unref();
  } catch {}
}
export function notify(summary, body, { urgency = 'low', icon = 'camera-photo', timeout = 4000, tag } = {}) {
  // A shared tag lets dunst and mako replace the sticky recording notice when it ends.
  const hints = tag ? [`--hint=string:x-dunst-stack-tag:${tag}`, `--hint=string:x-canonical-private-synchronous:${tag}`] : [];
  detached('notify-send', ['--app-name=MyMan', `--urgency=${urgency}`, `--icon=${icon}`, `--expire-time=${timeout}`, ...hints, summary, body]);
}
function refreshBars() {
  // Waybar custom modules can listen on a signal; Omarchy's bar polls.
  if (process.env.MYMAN_WAYBAR_SIGNAL && /^\d{1,2}$/.test(process.env.MYMAN_WAYBAR_SIGNAL)) detached('pkill', [`-RTMIN+${process.env.MYMAN_WAYBAR_SIGNAL}`, 'waybar']);
}
const clock = s => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}`;

// Called after a successful capture or recording change; never throws.
export async function announce(action, result) {
  try {
    if (action === 'screenshot.capture') {
      await atomic(stateFile(), JSON.stringify({ last_capture_at: new Date().toISOString(), last_capture_id: result?.id ?? null }));
      notify('An agent took a screenshot', result?.window?.app ? `Window: ${result.window.app}. Saved to your MyMan Brain.` : 'Saved to your MyMan Brain.');
    } else if (action === 'recording.start') {
      notify('An agent is recording your screen', `Video only, up to ${clock(result?.max_duration ?? 300)}. Stop it: myman record stop --session-id ${result?.session_id}`, { urgency: 'critical', icon: 'media-record', timeout: 0, tag: 'myman-recording' });
    } else if (action === 'recording.stop') {
      notify('Screen recording stopped', `Saved to your MyMan Brain${result?.duration ? ` (${clock(result.duration)})` : ''}.`, { icon: 'media-playback-stop', tag: 'myman-recording' });
    } else if (action === 'recording.pause') {
      notify('Screen recording paused', `Nothing is being recorded. Resume: myman record resume --session-id ${result?.session_id}`, { icon: 'media-playback-pause', tag: 'myman-recording' });
    } else if (action === 'recording.resume') {
      notify('An agent is recording your screen again', `Video only, ${clock(result?.remaining ?? 0)} left. Stop it: myman record stop --session-id ${result?.session_id}`, { urgency: 'critical', icon: 'media-record', timeout: 0, tag: 'myman-recording' });
    } else if (action === 'recording.cancel') {
      notify('Screen recording canceled', 'Nothing was saved.', { icon: 'media-playback-stop', tag: 'myman-recording' });
    } else return;
    refreshBars();
  } catch {}
}

// Waybar-compatible status: {text, tooltip, class, alt}. Empty text hides it.
export async function indicator() {
  const now = Date.now();
  let active = null;
  try { active = (await recording.status()).active; } catch {}
  if (active?.state === 'paused') return {
    ok: true, text: `❚❚ REC ${clock(active.elapsed)}`, alt: 'paused', class: 'paused', active: true,
    tooltip: `An agent paused a screen recording (${clock(active.remaining)} left).\nResume: myman record resume --session-id ${active.session_id}\nStop: myman record stop --session-id ${active.session_id}`,
    session_id: active.session_id, elapsed: active.elapsed, remaining: active.remaining,
  };
  if (active) return {
    ok: true, text: `● REC ${clock(active.elapsed)}`, alt: 'recording', class: 'recording', active: true,
    tooltip: `An agent is recording your screen (${clock(active.remaining)} left).\nStop: myman record stop --session-id ${active.session_id}`,
    session_id: active.session_id, elapsed: active.elapsed, remaining: active.remaining,
  };
  let last = null;
  try { last = JSON.parse((await readSafe(stateFile(), 16 * 1024, true)).toString()); } catch {}
  const age = last?.last_capture_at ? (now - Date.parse(last.last_capture_at)) / 1000 : Infinity;
  if (age >= 0 && age < RECENT_SECONDS) return { ok: true, text: '● SHOT', alt: 'capture', class: 'capture', active: true, tooltip: 'An agent just took a screenshot.', last_capture_at: last.last_capture_at, last_capture_id: last.last_capture_id };
  return { ok: true, text: '', alt: 'idle', class: 'idle', active: false, tooltip: last?.last_capture_at ? `No agent capture right now. Last screenshot: ${last.last_capture_at}` : 'No agent capture right now.', last_capture_at: last?.last_capture_at ?? null };
}
