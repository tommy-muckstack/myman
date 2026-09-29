// Pure counterpart of PeopleResolution.swift. Shared fixtures keep CLI/MCP
// resolution deterministic across Mac and Linux; no I/O or inferred addresses.
import {BrainError} from './brain.mjs';
export const normalized = value => value.normalize('NFKD').replace(/\p{M}/gu,'').toLowerCase().replace(/[^\p{L}\p{N}]+/gu,' ').trim();
export function email(value) {
  if(typeof value!=='string')return undefined;
  value=value.trim().toLowerCase();
  if(Buffer.byteLength(value)>254 || !/^[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9]+(?:[.-][a-z0-9]+)*\.[a-z]{2,63}$/.test(value))return undefined;
  const local=value.split('@')[0];
  return local.startsWith('.') || local.endsWith('.') || local.includes('..') || Buffer.byteLength(local)>64 ? undefined : value;
}
const generic=name=>!normalized(name) || ['you','them','others','unknown','speaker','owner'].includes(normalized(name)) || /^speaker \d+$/.test(normalized(name));
const compare=(a,b)=>a<b?-1:a>b?1:0;
export function resolvePeople(names,records,limit=5) {
  if(!Array.isArray(names) || names.length<1 || names.length>20 || !Number.isInteger(limit) || limit<1 || limit>10 || names.some(n=>typeof n!=='string' || !n.length || n.length>200 || /[\p{Cc}\p{Cf}]/u.test(n) || !normalized(n)))throw new BrainError('INVALID_ARGUMENTS','Use 1–20 nonblank names up to 200 characters and a limit from 1 to 10.');
  if(records.length>10_000)throw new BrainError('PEOPLE_LIMIT_EXCEEDED','Too many saved people; no partial resolution was returned.');
  const identities=new Map(),kinds=['exact_email','exact_name','name_tokens','name_prefix'];
  for(const record of records){
    const name=record.name.trim();if(name.length>300 || /[\p{Cc}\p{Cf}]/u.test(name) || generic(name))continue;
    const address=email(record.email),key=address?'email:'+address:'name:'+normalized(name);
    const person=identities.get(key) || {names:new Set(),email:address,sources:new Set()};
    person.names.add(name);person.sources.add(record.source);identities.set(key,person);
  }
  return names.map(input=>{
    const query=normalized(input),address=email(input),matches=[];
    for(const identity of identities.values()){
      let rank=Infinity;
      if(input.includes('@')) {if(address && address===identity.email)rank=0;}
      else for(const alias of identity.names){
        const name=normalized(alias);
        rank=Math.min(rank,name===query?1:(' '+name+' ').includes(' '+query+' ')?2:Array.from(query).length>=2 && (' '+name).includes(' '+query)?3:Infinity);
      }
      if(!Number.isFinite(rank))continue;
      const name=[...identity.names].sort((a,b)=>b.length-a.length || compare(normalized(a),normalized(b)) || compare(a,b))[0];
      matches.push({rank,name,...(identity.email?{email:identity.email}:{}),sources:[...identity.sources].sort(),match:kinds[rank]});
    }
    matches.sort((a,b)=>a.rank-b.rank || compare(normalized(a.name),normalized(b.name)) || compare(a.email || '',b.email || ''));
    const status=!matches.length?'not_found':matches.length>1?'ambiguous':!matches[0].email?'missing_email':matches[0].rank===3?'needs_confirmation':'resolved';
    return {input,status,candidates:matches.slice(0,limit).map(({rank,...candidate})=>candidate),total:matches.length,truncated:matches.length>limit};
  });
}
