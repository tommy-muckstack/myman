import {calendarError, calendarRange, instant} from './calendar-range.mjs';
import {freeBusy} from './calendar.mjs';

const invalid = () => calendarError('INVALID_ARGUMENTS', 'Provide a title, IANA time_zone, duration_minutes (1–480), limit (1–20), and optional guest labels or proposed_starts.');
export function proposalRequest(args) {
  const range = calendarRange(args);
  const label = value => {
    if (typeof value !== 'string' || !value.trim() || [...value].length > 200 || /\p{Cc}|\p{Cf}/u.test(value)) throw invalid();
    return value.trim();
  };
  const integer = (key, fallback, max) => {
    const n = args[key] === undefined ? fallback : args[key];
    if (!Number.isInteger(n) || n < 1 || n > max) throw invalid();
    return n;
  };
  const title = label(args.title), zone = args.time_zone;
  if (typeof zone !== 'string' || !(zone === 'UTC' || /^[A-Za-z_]+(?:\/[A-Za-z0-9_+\-]+)+$/.test(zone))) throw invalid();
  let formatter;
  try { formatter = new Intl.DateTimeFormat('en-US', {timeZone:zone, year:'numeric', month:'2-digit', day:'2-digit', hour:'2-digit', minute:'2-digit', second:'2-digit', hourCycle:'h23'}); }
  catch { throw invalid(); }
  const duration = integer('duration_minutes', 30, 480), limit = integer('limit', 5, 20);
  const guests = args.guests === undefined ? [] : args.guests;
  if (!Array.isArray(guests) || guests.length > 20) throw invalid();
  let proposed;
  if (args.proposed_starts !== undefined) {
    if (!Array.isArray(args.proposed_starts) || !args.proposed_starts.length || args.proposed_starts.length > 100) throw invalid();
    proposed = args.proposed_starts.map(value => { const date = instant(value); if (!Number.isFinite(date)) throw invalid(); return date; });
  }
  return {range, title, zone, formatter, duration, limit, guests:guests.map(label), proposed};
}

// Pure engine; the public action always gets its availability from freeBusy.
// No caller-supplied clock or busy intervals are accepted by the action schema.
export function proposalResult(request, availability, now) {
  if (availability.complete !== true || availability.scope !== 'own_calendar' || !Array.isArray(availability.busy) || availability.busy.length > 10_000) {
    throw calendarError('INCOMPLETE_AVAILABILITY', 'A complete own-calendar read is required before proposing times.');
  }
  const busy = availability.busy.map(block => {
    const start = instant(block.start), end = instant(block.end);
    if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) throw calendarError('INCOMPLETE_AVAILABILITY', 'Invalid busy interval; no proposal was returned.');
    return {start, end};
  }).sort((a,b)=>a.start-b.start || a.end-b.end);
  const {range, duration, limit, formatter} = request, milliseconds = duration * 60_000;
  let starts;
  if (request.proposed) starts = [...new Set(request.proposed)].sort((a,b)=>a-b);
  else {
    starts = [];
    const parts = date => Object.fromEntries(formatter.formatToParts(date).filter(p=>p.type!=='literal').map(p=>[p.type, Number(p.value)]));
    for (let start = Math.ceil(Math.max(range.start, now) / 60_000) * 60_000; start + milliseconds <= range.end; start += 60_000) {
      const a = parts(start);
      if (a.hour < 9 || a.hour >= 18 || a.minute % 15 || a.second) continue;
      const b = parts(start + milliseconds);
      if (a.year === b.year && a.month === b.month && a.day === b.day && b.hour*60+b.minute <= 18*60 && !b.second) starts.push(start);
    }
  }
  let cursor = 0;
  const candidates = starts.filter(start => {
    const end = start + milliseconds;
    if (start < now || start < range.start || end > range.end) return false;
    while (cursor < busy.length && busy[cursor].end <= start) cursor++;
    return cursor === busy.length || busy[cursor].start >= end;
  });
  const slots = candidates.slice(0,limit).map(start => ({start:new Date(start).toISOString(), end:new Date(start+milliseconds).toISOString()}));
  return {slots, candidate_count:candidates.length, truncated:candidates.length>limit,
    preview:{title:request.title, start:slots[0]?.start ?? null, end:slots[0]?.end ?? null, time_zone:request.zone,
      duration_minutes:duration, guests:request.guests, guest_count:request.guests.length, calendar_scope:'own_calendar',
      send_invitations:false, requires_human_book:true, video_link:null, complete:slots.length>0},
    availability, dry_run:true, side_effects:false, booked:false, booking_supported:false, teammate_availability:'unknown',
    slot_source:request.proposed ? 'proposed_starts' : 'workday_grid'};
}

export async function propose(args) {
  const request = proposalRequest(args);
  const availability = await freeBusy(args);
  return proposalResult(request, availability, Date.now());
}
