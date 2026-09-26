import path from 'node:path';
import { writeFile } from 'node:fs/promises';
import { markupTheme } from './theme.mjs';
import { dependencies, fail, imageCommand, pngSize, readSafe, run, unsupported } from './system.mjs';

export function rect(value, width, height) {
  if (!Array.isArray(value) || value.length !== 4 || value.some(n => !Number.isInteger(n)) || value[0] < 0 || value[1] < 0 || value[2] <= 0 || value[3] <= 0 || value[0] + value[2] > width || value[1] + value[3] > height) fail('INVALID_ARGUMENTS', 'Rectangle must use integer pixels and fit inside the image/display.');
  return value;
}
export function parseMonitors(text, rootHeight) {
  return text.split('\n').flatMap(line => {
    const m = /^\s*(\d+):\s+([+*]*)(\S+)\s+(\d+)(?:\/\d+)?x(\d+)(?:\/\d+)?([+-]\d+)([+-]\d+)/.exec(line);
    if (!m) return [];
    const [, index, flags, name, w, h, x, y] = m;
    return [{ id: index, selector: `id:${index}`, name, is_main: flags.includes('*'), width: +w, height: +h, x: +x, y: +y, scale: 1, frame: [+x, rootHeight - (+y + +h), +w, +h] }];
  });
}
// Normalize compositor layout coordinates to a desktop image at scale 1.
// Keep the native origin for grim, including monitors left/above the primary.
export function waylandDesktop(outputs, compositor) {
  if (!Array.isArray(outputs)) fail('DISPLAY_UNAVAILABLE', 'Invalid compositor monitor response.');
  const monitors = outputs.filter(o => compositor === 'hyprland' ? !o.disabled : o.active).map((o, index) => {
    const rotated = Number(o.transform ?? 0) % 2 === 1;
    const scale = o.scale ?? 1;
    const r = compositor === 'sway' ? o.rect : {x:o.x,y:o.y,width:Math.round((rotated?o.height:o.width)/scale),height:Math.round((rotated?o.width:o.height)/scale)};
    if (!r || ![r.x,r.y,r.width,r.height].every(Number.isSafeInteger) || r.width <= 0 || r.height <= 0 || !Number.isFinite(scale) || scale <= 0 || typeof o.name !== 'string') fail('DISPLAY_UNAVAILABLE', 'Invalid compositor monitor geometry.');
    const id=String(o.id ?? index);
    return {id,selector:`id:${id}`,name:o.name,is_main:!!o.focused,x:r.x,y:r.y,width:r.width,height:r.height,scale:1,native_scale:scale};
  });
  if (!monitors.length) fail('DISPLAY_UNAVAILABLE', 'No active Wayland outputs.');
  const origin=[Math.min(...monitors.map(d=>d.x)),Math.min(...monitors.map(d=>d.y))];
  const width=Math.max(...monitors.map(d=>d.x+d.width))-origin[0],height=Math.max(...monitors.map(d=>d.y+d.height))-origin[1];
  if (!Number.isSafeInteger(width*height) || width*height>100_000_000) fail('IMAGE_TOO_LARGE', 'Desktop exceeds 100 million pixels.');
  const displays=monitors.map(d=>({...d,x:d.x-origin[0],y:d.y-origin[1],frame:[d.x-origin[0],height-(d.y-origin[1]+d.height),d.width,d.height]}));
  if (!displays.some(d=>d.is_main)) displays[0].is_main=true;
  return {displays,width,height,origin,session:'wayland',compositor,coordinates:'global bottom-left; display-local top-left (logical pixels, normalized desktop origin)',scale:1};
}
async function waylandScreens(deps) {
  let compositor, response;
  if (process.env.HYPRLAND_INSTANCE_SIGNATURE) {
    if (!deps.hyprctl) fail('DEPENDENCY_MISSING','Hyprland capture needs hyprctl (included with Hyprland).');
    compositor='hyprland';response=await run(deps.hyprctl,['-j','monitors']);
  } else if (process.env.SWAYSOCK) {
    if (!deps.swaymsg) fail('DEPENDENCY_MISSING','Sway capture needs swaymsg.');
    compositor='sway';response=await run(deps.swaymsg,['-r','-t','get_outputs']);
  } else unsupported('Wayland capture supports Hyprland (including Omarchy) and Sway. Run from that desktop session with its compositor environment.');
  let outputs;try {outputs=JSON.parse(response.stdout);}catch{fail('DISPLAY_UNAVAILABLE','Cannot read Wayland monitor geometry.');}
  return waylandDesktop(outputs,compositor);
}
export async function screens() {
  const deps = await dependencies();
  // Prefer the real Wayland desktop over its Xwayland compatibility display.
  if (process.env.WAYLAND_DISPLAY || process.env.XDG_SESSION_TYPE === 'wayland') return waylandScreens(deps);
  if (!process.env.DISPLAY) fail('DISPLAY_UNAVAILABLE', 'Set DISPLAY (and XAUTHORITY when required) to the X11 desktop or Xvfb server.');
  if (!deps.xdpyinfo) fail('DEPENDENCY_MISSING', 'Install x11-utils (xdpyinfo) for X11 display geometry.');
  const { stdout } = await run(deps.xdpyinfo, ['-display', process.env.DISPLAY]);
  const dimensions = /dimensions:\s+(\d+)x(\d+)\s+pixels/.exec(stdout);
  if (!dimensions) fail('DISPLAY_UNAVAILABLE', 'Could not read X11 root dimensions.');
  const width = +dimensions[1], height = +dimensions[2];
  if (width * height > 100_000_000) fail('IMAGE_TOO_LARGE', 'Desktop exceeds 100 million pixels.');
  let displays = [];
  if (deps.xrandr) {
    try { displays = parseMonitors((await run(deps.xrandr, ['--listmonitors'])).stdout, height); } catch {}
  }
  if (!displays.length) displays = [{ id: '0', selector: 'id:0', name: 'X11 desktop', is_main: true, width, height, x: 0, y: 0, frame: [0,0,width,height], scale: 1 }];
  if (!displays.some(d => d.is_main)) displays[0].is_main = true;
  return { displays, width, height, session: 'x11', coordinates: 'global bottom-left; display-local top-left', scale: 1 };
}
export function captureRect(args, desktop) {
  let display;
  if (args.display) {
    display = args.display === 'main' ? desktop.displays.find(d => d.is_main) : desktop.displays.find(d => d.selector === args.display || String(d.id) === args.display || d.name === args.display);
    if (!display) fail('INVALID_ARGUMENTS', 'Unknown display; use screens list.');
  }
  if (args.coordinates === 'display-local' && !display) fail('INVALID_ARGUMENTS', 'Display-local coordinates require --display.');
  if (!args.region) return display ? [display.x, display.y, display.width, display.height] : [0,0,desktop.width,desktop.height];
  let region;
  if ((args.coordinates ?? (display ? 'display-local' : 'global')) === 'display-local') {
    const [x,y,w,h] = rect(args.region, display.width, display.height);
    region = [display.x+x,display.y+y,w,h];
  } else {
    const [x,y,w,h] = args.region;
    region = rect([x,desktop.height-y-h,w,h], desktop.width, desktop.height);
  }
  const containing = desktop.displays.filter(d => region[0]>=d.x && region[1]>=d.y && region[0]+region[2]<=d.x+d.width && region[1]+region[3]<=d.y+d.height);
  if (!containing.length || (display && !containing.includes(display))) fail('INVALID_ARGUMENTS', 'A region must fit within one selected display.');
  return region;
}
export async function capture(args, work) {
  if (args.window_id || args.open_editor || args.clipboard || args.lease_id) unsupported('Window capture, editor UI, clipboard and leases are not supported on Linux.');
  const desktop = await screens();
  const region = captureRect(args, desktop);
  const deps = await dependencies(), im = await imageCommand();
  const backend = desktop.session === 'wayland' ? (deps.grim ? 'grim' : null) : deps.scrot ? 'scrot' : deps.import ? 'import' : deps.ffmpeg ? 'ffmpeg' : null;
  if (!backend) fail('DEPENDENCY_MISSING', desktop.session === 'wayland' ? 'Install grim for Hyprland/Omarchy or Sway screenshots.' : 'Install scrot, ImageMagick import, or ffmpeg for X11 screenshots.');
  const source = path.join(work, 'desktop.png'), output = path.join(work, 'capture.png');
  if (backend === 'grim') {
    const [x,y,w,h]=region;
    await run(deps.grim,['-s','1','-g',`${x+desktop.origin[0]},${y+desktop.origin[1]} ${w}x${h}`,source]);
    const size=pngSize(await readSafe(source,128*1024*1024));
    if(size.width!==w||size.height!==h) fail('DISPLAY_CHANGED','Wayland geometry changed during capture; no item was saved.');
    await run(im,[source,'-strip',output]);
    return {file:output,width:w,height:h,backend,scale:1};
  }
  if (backend === 'scrot') await run(deps.scrot, ['--overwrite', source]);
  if (backend === 'import') await run(deps.import, ['-window', 'root', source]);
  if (backend === 'ffmpeg') await run(deps.ffmpeg, ['-nostdin','-loglevel','error','-f','x11grab','-video_size',`${desktop.width}x${desktop.height}`,'-i',process.env.DISPLAY,'-frames:v','1','-y',source]);
  const size = pngSize(await readSafe(source, 128 * 1024 * 1024));
  if (size.width !== desktop.width || size.height !== desktop.height) fail('DISPLAY_CHANGED', 'Desktop dimensions changed during capture; no item was saved.');
  const [x,y,w,h] = region;
  await run(im, [source, '-crop', `${w}x${h}+${x}+${y}`, '+repage', '-strip', output]);
  return { file: output, width: w, height: h, backend, scale: 1 };
}
const xml = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&apos;'}[c]));
export function validateMarkup(args, width, height) {
  if (args.open_editor || args.clipboard || args.lease_id || args.background_color || args.corner_radius || (args.background && args.background !== 'none')) unsupported('Editor UI, clipboard, leases and backdrops are not supported on Linux.');
  if (args.dry_run && args.preview) fail('INVALID_ARGUMENTS', 'Choose preview or dry-run.');
  for (const op of args.annotations ?? []) {
    if (op.target_text || op.target_region || !['arrow','box','highlight','text','pixelate'].includes(op.type)) unsupported('Linux annotations support explicit arrow, box, highlight, text and pixelate geometry. OCR targeting and image/circle/callout overlays are unavailable.');
    if (op.type === 'arrow') {
      for (const point of [op.from,op.to]) if (!Array.isArray(point) || point.length !== 2 || point.some((n,i) => !Number.isFinite(n) || n < 0 || n >= [width,height][i])) fail('INVALID_ARGUMENTS', 'Arrow endpoints must fit inside the image.');
      if (op.from.every((v,i) => v===op.to[i])) fail('INVALID_ARGUMENTS', 'Arrow endpoints must differ.');
    } else rect(op.rect, width, height);
    if (op.type === 'text' && !op.text) fail('INVALID_ARGUMENTS', 'Text annotations require text.');
    if (op.path || op.number !== undefined) unsupported('Image paths and callout numbers are not supported on Linux.');
  }
  if (args.crop) rect(args.crop, width, height);
  return { width: args.crop?.[2] ?? width, height: args.crop?.[3] ?? height };
}
export async function annotate(source, args, work) {
  const { width, height } = pngSize(await readSafe(source, 128 * 1024 * 1024));
  const dimensions = validateMarkup(args, width, height);
  if (args.dry_run) return { dry_run: true, valid: true, ...dimensions };
  const im = await imageCommand();
  const theme = await markupTheme();
  let current = source;
  for (const [index,op] of (args.annotations ?? []).entries()) {
    const output = path.join(work, `markup-${index}.png`);
    const color = op.color || args.color || theme.colors[op.type] || '#FF375F';
    if (op.type === 'pixelate') {
      const [x,y,w,h] = op.rect;
      await run(im, [current,'(',current,'-crop',`${w}x${h}+${x}+${y}`,'+repage','-scale',`${Math.max(1,Math.ceil(w/12))}x${Math.max(1,Math.ceil(h/12))}!`,'-scale',`${w}x${h}!`,')','-geometry',`+${x}+${y}`,'-composite',`PNG32:${output}`]);
    } else if (op.type === 'text') {
      // Text stays an SVG overlay so user text is never parsed by ImageMagick's
      // -annotate/-draw escapes. Shapes use numeric -draw primitives, because
      // ImageMagick's internal MSVG renderer drops or fills stroke-only shapes.
      const [x,y] = op.rect, font = op.font_size ?? 24;
      const overlay = path.join(work, `overlay-${index}.svg`);
      await writeFile(overlay, `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}"><text x="${x}" y="${y+font}" font-family="DejaVu Sans" font-size="${font}" fill="${color}">${xml(op.text)}</text></svg>`, { mode: 0o600 });
      await run(im, [current,'-colorspace','sRGB','(','-background','none',`MSVG:${overlay}`,')','-compose','over','-composite',`PNG32:${output}`]);
    } else {
      let draw;
      if (op.type === 'arrow') {
        const [x,y] = op.to, [a,b] = op.from, angle = Math.atan2(y-b,x-a), length = Math.min(16,Math.hypot(x-a,y-b)/2);
        const points = [[x,y],[x-length*Math.cos(angle-.5),y-length*Math.sin(angle-.5)],[x-length*Math.cos(angle+.5),y-length*Math.sin(angle+.5)]];
        draw = ['-stroke',color,'-strokewidth','3','-fill','none','-draw',`line ${a},${b} ${x},${y}`,'-stroke','none','-fill',color,'-draw',`polygon ${points.map(p=>p.map(n=>n.toFixed(2)).join(',')).join(' ')}`];
      } else {
        const [x,y,w,h] = op.rect, box = `rectangle ${x},${y} ${x+w-1},${y+h-1}`;
        draw = op.type === 'highlight'
          ? ['-stroke','none','-fill',`${color}4D`,'-draw',box]
          : ['-stroke',color,'-strokewidth','3','-fill','none','-draw',box];
      }
      await run(im, [current,'-colorspace','sRGB',...draw,`PNG32:${output}`]);
    }
    current = output;
  }
  const output = path.join(work, 'annotated.png');
  const crop = args.crop ? ['-crop',`${args.crop[2]}x${args.crop[3]}+${args.crop[0]}+${args.crop[1]}`,'+repage'] : [];
  await run(im, [current,...crop,'-strip',output]);
  return { file: output, ...dimensions, scale: 1, ...(theme.source==='omarchy'?{theme:{name:theme.name,source:'omarchy'}}:{}) };
}
export async function ocr(file) {
  const tool = (await dependencies()).tesseract;
  if (!tool) return { status: 'unavailable', text: '' };
  try {
    const { stdout } = await run(tool, [file, 'stdout'], { timeout: 45_000, maxBuffer: 1024 * 1024 });
    return { status: 'ready', text: stdout.trim() };
  } catch { return { status: 'failed', text: '' }; }
}
