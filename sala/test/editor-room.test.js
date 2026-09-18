import {test} from 'node:test';
import assert from 'node:assert/strict';
import {promises as fs} from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import {editorRoom} from '../lib/editor-room.js';

test('room discovery verifies live project and process, rejects reused ports and dead handles', async()=>{
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'sf-room-'));
 let health={ok:true,pid:process.pid,project:dir};
 const server=http.createServer((req,res)=>{res.setHeader('Content-Type','application/json');res.end(JSON.stringify(health));});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 try {
  assert.equal((await editorRoom(dir)).state,'closed');
  const handle={pid:process.pid,port:server.address().port};
  await fs.writeFile(path.join(dir,'sala-handle.json'),JSON.stringify(handle));
  const live=await editorRoom(dir);
  assert.equal(live.state,'live');assert.equal(live.identity_check,'project-and-process');
  health={...health,pid:process.pid+1};assert.equal((await editorRoom(dir)).state,'stale');
  health={ok:true,pid:process.pid,project:os.tmpdir()};assert.equal((await editorRoom(dir)).state,'stale');
  health={ok:true,pid:process.pid};assert.equal((await editorRoom(dir)).identity_check,'legacy-process');
  server.closeAllConnections();await new Promise(r=>server.close(r));
  assert.equal((await editorRoom(dir)).state,'closed');
 } finally {server.closeAllConnections();server.close();await fs.rm(dir,{recursive:true,force:true});}
});
