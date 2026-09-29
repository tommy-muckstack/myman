import { parentPort, workerData } from 'node:worker_threads';
import { parseICS } from './calendar-ics.mjs';
try { parentPort.postMessage({result:parseICS(workerData.text,workerData.range,workerData.zone,workerData.ownerEmail)}); }
catch(error) { parentPort.postMessage({error:{code:error.code || 'INVALID_ICS',message:error.code ? error.message : 'Invalid ICS calendar; no partial result was returned.'}}); }
