import {Brain,BrainError} from '../brain/brain.mjs';
import {resolvePeople} from '../brain/people.mjs';
import {rootPath} from './system.mjs';

// people.md contains only visible People rows exported by the Mac. Meeting
// exports lack a hidden-person ledger, so do not resurrect names from them.
export function peopleExport(text) {
  if(!text.startsWith('# People\n'))throw new BrainError('PEOPLE_SOURCE_INVALID','Expected the MyMan people.md export.');
  const records=[];
  for(const line of text.split('\n')) {
    if(!line.startsWith('- '))continue;
    const match=/^- \*\*(.{1,300}?)\*\*(?: — (.+?))? — \d+ meetings?, last .+$/.exec(line);
    if(!match)throw new BrainError('PEOPLE_SOURCE_INVALID','A saved person is malformed; no partial resolution was returned.');
    records.push({name:match[1],email:match[2],source:'people'});
    if(records.length>10_000)throw new BrainError('PEOPLE_LIMIT_EXCEEDED','Too many saved people; no partial resolution was returned.');
  }
  return records;
}
export async function resolve(args) {
  // Validate before accessing source data. Grants/scopes are checked by service.
  resolvePeople(args.names,[],args.limit);
  let doc;
  try {doc=await new Brain(rootPath()).load('people.md');}
  catch(error) {
    if(['DOCUMENT_NOT_FOUND','BRAIN_NOT_FOUND'].includes(error.code))throw new BrainError('unsupported_on_platform','No local people.md export is available. Export People from MyMan on Mac; Contacts lookup is not implemented.');
    throw error;
  }
  return {results:resolvePeople(args.names,peopleExport(doc.text),args.limit),source:'people_export',contacts_accessed:false,side_effects:false};
}
