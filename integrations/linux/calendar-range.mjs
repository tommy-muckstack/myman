export const calendarError = (code, message) => Object.assign(new Error(message), { code });
export function instant(value) {
  const match = typeof value === 'string' && /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,3})?(Z|[+-]\d{2}:\d{2})$/.exec(value);
  if (!match) return NaN;
  const [y,m,d,h,min,s] = match.slice(1,7).map(Number), date = new Date(0);
  date.setUTCFullYear(y,m-1,d); date.setUTCHours(h,min,s,0);
  if (y < 1 || date.getUTCFullYear() !== y || date.getUTCMonth()+1 !== m || date.getUTCDate() !== d || h > 23 || min > 59 || s > 59) return NaN;
  if (match[7] !== 'Z' && (Number(match[7].slice(1,3)) > 23 || Number(match[7].slice(4)) > 59)) return NaN;
  return Date.parse(value);
}
export function calendarRange({after, before}) {
  const start = instant(after), end = instant(before);
  if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start || end-start > 31*86400_000) {
    throw calendarError('INVALID_ARGUMENTS','after/before must be ISO 8601 timestamps with offsets spanning more than zero and at most 31 days.');
  }
  return {start,end};
}
export function busyResult(blocks, range) {
  const merged = [];
  for (const block of blocks.map(({start,end})=>({start:Math.max(start,range.start),end:Math.min(end,range.end)})).filter(b=>b.end>b.start).sort((a,b)=>a.start-b.start || a.end-b.end)) {
    const last = merged.at(-1);
    if (last && block.start <= last.end) last.end = Math.max(last.end,block.end);
    else merged.push({...block});
  }
  return {after:new Date(range.start).toISOString(),before:new Date(range.end).toISOString(),
    busy:merged.map(({start,end})=>({start:new Date(start).toISOString(),end:new Date(end).toISOString()})),
    source:'local_ics',scope:'own_calendar',complete:true,side_effects:false,teammate_availability:'unknown',
    freshness:'local_snapshot'};
}
