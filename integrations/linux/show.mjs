// `myman show`: the person at the computer picks part of the screen and saves
// it to the Brain for their agents, e.g. from an Omarchy key binding. It is a
// person's action, not an agent tool: selection needs someone to drag a
// rectangle (slurp on Wayland, slop or scrot -s on X11), it is never in the
// action catalog, MCP or app server, and it refuses to run inside an agent.
import { mkdtemp, rm } from 'node:fs/promises';
import path from 'node:path';
import { command, directory, fail, pngSize, readSafe, run, statePath } from './system.mjs';
import { saveCapture } from './library.mjs';
import { notify } from './indicator.mjs';

export async function show({ note } = {}) {
  if (process.env.MYMAN_AGENT_TOKEN) fail('HUMAN_REQUIRED', 'myman show is for the person at this computer. Agents capture with myman screenshot --json.');
  const wayland = !!process.env.WAYLAND_DISPLAY;
  if (!wayland && !process.env.DISPLAY) fail('DESKTOP_UNAVAILABLE', 'Run myman show inside the desktop session (it needs WAYLAND_DISPLAY or DISPLAY).');
  const work = await mkdtemp(path.join(await directory(path.join(statePath(), 'work'), true, true), 'show-'));
  const file = path.join(work, 'shown.png');
  try {
    let backend;
    const cancelled = () => fail('CANCELLED', 'Nothing was selected, so nothing was saved.');
    if (wayland) {
      const slurp = await command('slurp'), grim = await command('grim');
      if (!slurp || !grim) fail('DEPENDENCY_MISSING', 'Install slurp and grim (sudo pacman -S --needed slurp grim).');
      let geometry; try { geometry = (await run(slurp, [])).stdout.trim(); } catch { cancelled(); }
      if (!/^-?\d+,-?\d+ \d+x\d+$/.test(geometry)) cancelled();
      await run(grim, ['-g', geometry, file]); backend = 'grim';
    } else {
      const slop = await command('slop'), scrot = await command('scrot');
      if (slop) {
        let g; try { g = (await run(slop, ['-f', '%wx%h+%x+%y'])).stdout.trim(); } catch { cancelled(); }
        const imp = await command('import'); if (!imp) fail('DEPENDENCY_MISSING', 'Install ImageMagick.');
        await run(imp, ['-window', 'root', '-crop', g, '+repage', file]); backend = 'slop';
      } else if (scrot) {
        try { await run(scrot, ['--select', '--overwrite', file]); } catch { cancelled(); }
        backend = 'scrot';
      } else fail('DEPENDENCY_MISSING', 'Install slop or scrot to select a region on X11.');
    }
    const { width, height } = pngSize(await readSafe(file, 128 * 1024 * 1024));
    const saved = await saveCapture({ file, width, height, backend }, undefined, { region: [0, 0, width, height], shown: true, note });
    const safe = String(note ?? '').replace(/[&<>]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' })[c]).slice(0, 160);
    notify('Saved for your agents', `${saved.id}${safe ? `: ${safe}` : ''}. Ask an agent to look at your latest shown screenshot.`, { tag: 'myman-show' });
    return { ...saved, shown_by: 'person', next: 'Agents can open it with myman library read --id ' + saved.id + ' --json, or find it with myman library search --query shown --json.' };
  } finally { await rm(work, { recursive: true, force: true }); }
}
