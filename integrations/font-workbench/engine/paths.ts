import opentype from "opentype.js";

/** Parse the outline commands emitted by our tracers and base fonts. Fail
 * explicitly on malformed/unsupported commands instead of corrupting a font. */
export function parsePath(d: string): opentype.Path {
  const path = new opentype.Path();
  const tokens = d.match(/[a-zA-Z]|[-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?/g) ?? [];
  if (d.replace(/[a-zA-Z]|[-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?|[\s,]/g, "")) throw new Error("Invalid outline data");
  let i = 0, x = 0, y = 0, startX = 0, startY = 0, command = "";
  while (i < tokens.length) {
    if (/^[a-zA-Z]$/.test(tokens[i])) command = tokens[i++];
    const upper = command.toUpperCase();
    const relative = command !== upper;
    if (upper === "Z") {
      path.close(); x = startX; y = startY; command = ""; continue;
    }
    const count = ({ M: 2, L: 2, Q: 4, C: 6, H: 1, V: 1 } as Record<string, number>)[upper];
    if (!count) throw new Error(`Unsupported outline command: ${command}`);
    const values = tokens.slice(i, i + count).map(Number);
    if (values.length !== count || values.some(v => !Number.isFinite(v))) throw new Error("Incomplete outline command");
    i += count;
    if (upper === "H") { x = values[0] + (relative ? x : 0); path.lineTo(x, y); continue; }
    if (upper === "V") { y = values[0] + (relative ? y : 0); path.lineTo(x, y); continue; }
    for (let n = 0; n < count; n += 2) { values[n] += relative ? x : 0; values[n + 1] += relative ? y : 0; }
    x = values[count - 2]; y = values[count - 1];
    if (upper === "M") { path.moveTo(x, y); startX = x; startY = y; command = relative ? "l" : "L"; }
    if (upper === "L") path.lineTo(x, y);
    if (upper === "Q") path.quadraticCurveTo(values[0], values[1], x, y);
    if (upper === "C") path.curveTo(values[0], values[1], values[2], values[3], x, y);
  }
  return path;
}

export function transformPath(path: opentype.Path, sx: number, sy: number, dx = 0, dy = 0) {
  const out = new opentype.Path();
  for (const c of path.commands) {
    if (c.type === "Z") { out.close(); continue; }
    const x = c.x * sx + dx, y = c.y * sy + dy;
    if (c.type === "M") out.moveTo(x, y);
    if (c.type === "L") out.lineTo(x, y);
    if (c.type === "Q") out.quadraticCurveTo(c.x1 * sx + dx, c.y1 * sy + dy, x, y);
    if (c.type === "C") out.curveTo(c.x1 * sx + dx, c.y1 * sy + dy, c.x2 * sx + dx, c.y2 * sy + dy, x, y);
  }
  return out;
}
