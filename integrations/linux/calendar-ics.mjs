import ICAL from 'ical.js';
import { busyResult, calendarError, instant } from './calendar-range.mjs';

const invalid = () => { throw calendarError('INVALID_ICS','Invalid ICS calendar; no partial result was returned.'); };
const unsupported = () => { throw calendarError('ICS_UNSUPPORTED','Unsupported or ambiguous ICS date, time zone or recurrence. Export a bounded calendar snapshot; no partial result was returned.'); };
const limit = () => { throw calendarError('CALENDAR_LIMIT_EXCEEDED','ICS has too many events or recurrence instances. Use a smaller calendar snapshot; no partial result was returned.'); };
const value = (component,name) => component.getFirstPropertyValue(name);
const floating = time => time.zone.tzid === 'floating';
const utcWall = (y,m,d,h,min,s) => {
  const date=new Date(0); date.setUTCFullYear(y,m-1,d); date.setUTCHours(h,min,s,0); return date.getTime();
};

export function parseICS(text,range,defaultZone,ownerEmail) {
  if (text.includes('\0')) invalid();
  // Do not let a permissive parser silently normalize invalid/unknown rules
  // (for example INTERVAL=0 or an unsupported RSCALE/SKIP extension).
  const ruleKeys=new Set(['FREQ','UNTIL','COUNT','INTERVAL','WKST','BYSECOND','BYMINUTE','BYHOUR','BYDAY','BYMONTHDAY','BYYEARDAY','BYWEEKNO','BYMONTH','BYSETPOS']);
  for (const line of text.replace(/\r?\n[ \t]/g,'').split(/\r?\n/)) {
    const match=/^RRULE(?:;[^:]*)?:(.*)$/i.exec(line);
    if (!match) continue;
    const seen=new Set();
    for (const part of match[1].toUpperCase().split(';')) {
      const [key,content,...extra]=part.split('=');
      if (!ruleKeys.has(key) || seen.has(key) || !content || extra.length) unsupported();
      seen.add(key);
      if (['COUNT','INTERVAL'].includes(key) && (!/^\d+$/.test(content) || +content<1 || +content>2147483647)) invalid();
      if (['BYMONTHDAY','BYYEARDAY','BYWEEKNO','BYSETPOS'].includes(key) && content.split(',').some(v=>+v===0)) invalid();
      if (key==='BYSECOND' && content.split(',').some(v=>+v===60)) unsupported();
      if (key==='UNTIL') {
        const date=/^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})Z?)?$/.exec(content);
        if (!date || !Number.isFinite(instant(`${date[1]}-${date[2]}-${date[3]}T${date[4] || '00'}:${date[5] || '00'}:${date[6] || '00'}Z`))) invalid();
      }
    }
    if (!seen.has('FREQ') || seen.has('COUNT') && seen.has('UNTIL')) invalid();
  }
  const root = new ICAL.Component(ICAL.parse(text));
  if (root.name !== 'vcalendar' || value(root,'version') !== '2.0') invalid();
  if (value(root,'method') && value(root,'method').toUpperCase() !== 'PUBLISH') unsupported();
  if (root.getAllSubcomponents().some(c=>!['vevent','vtimezone','vfreebusy','vtodo','vjournal'].includes(c.name))) unsupported();
  const components = root.getAllSubcomponents('vevent');
  if (components.length > 10_000) limit();
  const formats = new Map(), blocks = [];
  let iterations = 0;
  function wallInstant(time,zone,end) {
    let formatter = formats.get(zone);
    if (!formatter) {
      try { formatter = new Intl.DateTimeFormat('en-US',{timeZone:zone,year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',second:'2-digit',hourCycle:'h23'}); }
      catch { unsupported(); }
      formats.set(zone,formatter);
    }
    const wall = utcWall(time.year,time.month,time.day,time.hour,time.minute,time.second);
    const partsAt = ms => Object.fromEntries(formatter.formatToParts(ms).map(p=>[p.type,p.value]));
    const candidates = new Set();
    // Sample both sides of a transition. Repeated local times conservatively
    // cover the earlier start through the later end; nonexistent times fail.
    for (const delta of [-36,-12,0,12,36]) {
      const sample = wall+delta*3600_000, p = partsAt(sample);
      const offset = utcWall(+p.year,+p.month,+p.day,+p.hour,+p.minute,+p.second)-sample;
      const candidate = wall-offset, q = partsAt(candidate);
      if (+q.year===time.year && +q.month===time.month && +q.day===time.day && +q.hour===time.hour && +q.minute===time.minute && +q.second===time.second) candidates.add(candidate);
    }
    if (!candidates.size) unsupported();
    return end ? Math.max(...candidates) : Math.min(...candidates);
  }
  function timestamp(time,component,end=false,property='dtstart') {
    if (!time) invalid();
    if (time.isDate) return wallInstant(time,defaultZone,end);
    if (!floating(time)) return time.toUnixTime()*1000;
    const zone = component.getFirstProperty(property)?.getParameter('tzid') || component.getFirstProperty('dtstart')?.getParameter('tzid') || defaultZone;
    return wallInstant(time,zone,end);
  }
  function isBusy(component,master=component) {
    if (String(value(component,'status') || value(master,'status')).toUpperCase()==='CANCELLED' ||
        String(value(component,'transp') || value(master,'transp')).toUpperCase()==='TRANSPARENT') return false;
    if (ownerEmail) {
      const attendees = component.hasProperty('attendee') ? component.getAllProperties('attendee') : master.getAllProperties('attendee');
      if (attendees.some(p=>String(p.getFirstValue()).replace(/^mailto:/i,'').toLowerCase()===ownerEmail.toLowerCase() && String(p.getParameter('partstat')).toUpperCase()==='DECLINED')) return false;
    }
    return true;
  }
  function add(start,end) {
    if (!Number.isFinite(start) || !Number.isFinite(end) || end<start) invalid();
    if (end>range.start && start<range.end && end>start) blocks.push({start,end});
    if (blocks.length>10_000) limit();
  }
  function validate(component) {
    for (const name of ['dtstart','dtend','duration','recurrence-id','uid','status','transp']) if (component.getAllProperties(name).length>1) invalid();
    if (!value(component,'uid') || component.hasProperty('dtend') && component.hasProperty('duration')) invalid();
    if (component.hasProperty('exrule') || component.getFirstProperty('recurrence-id')?.getParameter('range')) unsupported();
    for (const p of component.getAllProperties()) {
      if (!['dtstart','dtend','recurrence-id','rdate','exdate'].includes(p.name)) continue;
      if (!['date','date-time'].includes(p.type)) unsupported();
      // Validate raw jCal before Time normalizes bad dates (e.g. February 30).
      for (const raw of p.jCal.slice(3)) {
        const rawInstant = p.type==='date' ? raw+'T00:00:00Z' : raw.replace(/Z$/,'')+'Z';
        if (!Number.isFinite(instant(rawInstant))) invalid();
      }
      const tzid = p.getParameter('tzid');
      if (tzid && !root.getTimeZoneByID(tzid)) {
        try { new Intl.DateTimeFormat('en-US',{timeZone:tzid}); } catch { unsupported(); }
      }
      if (['rdate','exdate'].includes(p.name)) {
        const start = component.getFirstProperty('dtstart');
        if (!start || p.type !== start.type || (tzid || '') !== (start.getParameter('tzid') || '') ||
            p.jCal.slice(3).some(raw=>raw.endsWith('Z') !== start.jCal[3].endsWith('Z'))) unsupported();
      }
    }
    if (component.hasProperty('dtend') && value(component,'dtstart')?.isDate !== value(component,'dtend')?.isDate) invalid();
    const start=component.getFirstProperty('dtstart'), end=component.getFirstProperty('dtend');
    if (start && end && ((start.getParameter('tzid') || '') !== (end.getParameter('tzid') || '') || start.jCal[3].endsWith('Z') !== end.jCal[3].endsWith('Z'))) unsupported();
    for (const rule of component.getAllProperties('rrule')) {
      const until=rule.getFirstValue().until;
      if (!until) continue;
      const startTime=value(component,'dtstart'), tzid=start?.getParameter('tzid');
      if (!startTime || until.isDate !== startTime.isDate) invalid();
      if (!until.isDate && (tzid || !floating(startTime)) && until.zone.tzid!=='UTC') invalid();
      // ICAL cannot compare UTC UNTIL against an IANA wall time unless the
      // export supplies VTIMEZONE. Never silently drop the final occurrence.
      if (floating(startTime) && until.zone.tzid==='UTC') unsupported();
    }
  }
  const masters = new Map(), exceptions = new Map();
  for (const component of components) {
    validate(component);
    const uid = value(component,'uid');
    if (component.hasProperty('recurrence-id')) {
      const list=exceptions.get(uid) || []; list.push(component); exceptions.set(uid,list);
    } else { if(masters.has(uid)) unsupported(); masters.set(uid,component); }
  }
  for (const [uid,component] of masters) {
    const overrides=exceptions.get(uid) || [], event=new ICAL.Event(component,{exceptions:[],strictExceptions:true}), seen=new Set();
    for (const override of overrides) {
      const id=value(override,'recurrence-id').toString();
      if (seen.has(id)) unsupported(); seen.add(id);
      // A different recurrence-ID zone can silently miss an override for a
      // floating/IANA series. Reject rather than leave its old slot falsely free.
      const original=value(override,'recurrence-id'), start=event.startDate;
      if (original.isDate!==start.isDate || original.zone.tzid!==start.zone.tzid ||
          (override.getFirstProperty('recurrence-id').getParameter('tzid') || '') !== (component.getFirstProperty('dtstart')?.getParameter('tzid') || '')) unsupported();
      // Include moved exceptions even if their original occurrence falls
      // outside the query; their replacement is not found by a bounded iterator.
      if (isBusy(override,component)) {
        const changed=new ICAL.Event(override,{exceptions:[]});
        add(timestamp(changed.startDate,override),timestamp(changed.endDate,override,true,'dtend'));
      }
    }
    if (!isBusy(component)) continue;
    if (!event.startDate) invalid();
    const iterator=event.iterator();
    for (let next; (next=iterator.next());) {
      if (++iterations>20_000) limit();
      if (timestamp(next,component)>=range.end) break;
      // Overrides were handled above, including cancellations without DTSTART
      // or DTEND. Asking ICAL for their endDate would require a missing start.
      if (seen.has(next.toString())) continue;
      const detail=event.getOccurrenceDetails(next);
      if (isBusy(detail.item.component,component)) add(timestamp(detail.startDate,detail.item.component),timestamp(detail.endDate,detail.item.component,true,'dtend'));
    }
  }
  for (const [uid] of exceptions) if (!masters.has(uid)) unsupported();
  for (const component of root.getAllSubcomponents('vfreebusy')) {
    for (const property of component.getAllProperties('freebusy')) {
      if (property.type!=='period') invalid();
      for (const raw of property.jCal.slice(3)) {
        if (!Array.isArray(raw) || !raw[0]?.endsWith('Z') || !Number.isFinite(instant(raw[0]))) invalid();
        if (!/^[+-]?P/.test(raw[1]) && (!raw[1]?.endsWith('Z') || !Number.isFinite(instant(raw[1])))) invalid();
      }
      if (String(property.getParameter('fbtype') || 'BUSY').toUpperCase()==='FREE') continue;
      for (const period of property.getValues()) {
        if (++iterations>20_000) limit();
        if (period.start.isDate || floating(period.start) || floating(period.getEnd())) unsupported();
        add(period.start.toUnixTime()*1000,period.getEnd().toUnixTime()*1000);
      }
    }
  }
  return busyResult(blocks,range);
}
