#!/usr/bin/env node
// Explicit writes only. No implicit migration during GET/catalog browsing.
import { initIdentity, recordRun, readRuns } from '../lib/project-history.js';
try {
  const [action,project]=process.argv.slice(2);
  if(!project || !['init','record','list'].includes(action))throw new Error('uso: project-history.js init|record|list <project> [JSON por stdin para record]');
  let result;
  if(action==='init')result=await initIdentity(project);
  else if(action==='list')result=await readRuns(project);
  else {let input='';for await(const chunk of process.stdin)input+=chunk;result=await recordRun(project,JSON.parse(input));}
  console.log(JSON.stringify(result,null,2));
}catch(e){console.error(e.message);process.exitCode=1;}
