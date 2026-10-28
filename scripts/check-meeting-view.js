// Regression check for synchronous SDK bootstrap and citation event binding.
// A fake DOM only; this does not operate a browser or the user's computer.
const fs = require('fs'), vm = require('vm'), assert = require('assert');
const elements = new Map(), emitted = [];
function element(id='') {
  return {id, value:'', hidden:false, disabled:false, checked:false, children:[], dataset:{}, style:{}, textContent:'',
    classList:{toggle(){}}, scrollHeight:0,scrollTop:0,clientHeight:0,
    replaceChildren(...children){this.children=children;}, append(...children){this.children.push(...children);},
    get options(){return this.children;}, contains(){return false;}, scrollIntoView(){}, focus(){}, blur(){}, replaceWith(){},removeAttribute(){}};
}
const document={getElementById(id){if(!elements.has(id))elements.set(id,element(id));return elements.get(id);},
  createElement:element,querySelector(id){return this.getElementById(id);},body:element(),activeElement:null};
let callback;
const sources=[{id:'s1',label:'00:00:08 · Microphone',text:'Launch is Friday.'}];
const state={selected:'synthetic-meeting',hasTranscript:true,notebookPage:'ask',library:'[]',sources:'[]',transcript:'[]',speakers:'{}',
  ask:JSON.stringify({busy:false,question:'When is launch?',provider:'test.assistant/answer_evidence',providers:[{id:'test.assistant/answer_evidence',title:'Test assistant'}],prepared:true,coverage:'Full settled transcript',sources,
    answer:{disposition:'answered',statements:[{text:'Friday.',citations:['s1']}]}})};
const context={window:{},document,TextEncoder,setTimeout,clearTimeout,nero:{onState(fn){callback=fn;fn({});fn(state);},emit(name,values){emitted.push({name,values});return Promise.resolve();}}};
vm.runInNewContext(fs.readFileSync('Resources/Views/meetings/meeting.js','utf8'),context);
assert.equal(typeof elements.get('tabAsk').onclick,'function');
elements.get('tabAsk').onclick();assert.equal(emitted.pop().values.page,'ask');
elements.get('meetingQuestion').value='Different question';elements.get('meetingQuestion').oninput();assert.equal(elements.get('questionSend').disabled,true);
elements.get('meetingQuestion').value='When is launch?';elements.get('meetingQuestion').oninput();assert.equal(elements.get('questionSend').disabled,false);
const answer=elements.get('meetingAnswer'), citation=answer.children[1].children[1].children[0];citation.onclick();assert.equal(emitted.pop().values.citation,'s1');
callback({...state,ask:JSON.stringify({busy:false,providers:[],sources:[],prepared:false})});assert.equal(elements.get('meetingAnswer').hidden,true);
console.log('PASS: synchronous bootstrap, Ask control bindings, changed-question guard, citation events, no empty answer');

const noteItem={id:'authored-note-id',section:'decisions',fact:'Thursday was agreed.',quote:'We agreed Thursday.',start:13,track:'system'};
const noteState={...state,notebookPage:'notes',noteEvidence:JSON.stringify([noteItem]),noteEvidencePaging:JSON.stringify({page:0,pages:2,count:7}),notesStale:false,summaryAvailable:true};
callback(noteState);
let noteCard=elements.get('noteEvidence').children[0];
assert.equal(noteCard.children[1].textContent,noteItem.fact);assert.equal(noteCard.children[2].textContent,noteItem.quote);
noteCard.children[3].onclick();assert.equal(emitted.pop().values.citation,noteItem.id);
elements.get('noteEvidenceNext').onclick();assert.equal(emitted.pop().values.offset,1);
callback({...noteState,notesStale:true,summaryAvailable:false});
assert.equal(elements.get('noteEvidence').children[0].children[3].disabled,true);
assert(elements.get('summaryHint').textContent.includes('stale'));
callback(noteState);elements.get('summary').value='My manual revision';elements.get('summary').oninput();
assert.equal(elements.get('noteEvidence').children[0].children[3].disabled,true);
const beforeDirtyClick=emitted.length;elements.get('noteEvidence').children[0].children[3].onclick();assert.equal(emitted.length,beforeDirtyClick);
elements.get('saveNotes').onclick();
console.log('PASS: structured note source event, stale/unavailable precedence, unsaved edit navigation guard');
const task={id:'task-source',task:'Dana will send the draft on Friday.',quote:'I will send the draft on Friday.',start:8,track:'system'};
const taskState={...noteState,selected:'task-meeting',actionCards:JSON.stringify([task]),actionItems:'[00:08] Dana will send the draft on Friday.'};
callback(taskState);let taskCard=elements.get('actionCards').children[0];
assert.equal(elements.get('actionCardPanel').hidden,false);assert.equal(elements.get('actionEditor').open,false);
assert.equal(taskCard.children[1].textContent,task.task);assert.equal(taskCard.children[2].children[1].textContent,task.quote);
taskCard.children[2].children[2].onclick();assert.equal(emitted.pop().values.citation,'task-source');
callback({...taskState,notesStale:true});taskCard=elements.get('actionCards').children[0];assert.equal(taskCard.children[2].children[2].disabled,true);
let taskEvents=emitted.length;taskCard.children[2].children[2].onclick();assert.equal(emitted.length,taskEvents);
callback({...taskState,busy:true});elements.get('actionCards').children[0].children[2].children[2].onclick();assert.equal(emitted.length,taskEvents);
callback(taskState);elements.get('actions').value='Manual revision';elements.get('actions').oninput();
assert.equal(elements.get('actionCardPanel').hidden,true);assert.equal(elements.get('actionEditor').open,true);
elements.get('saveNotes').onclick();callback({...taskState,selected:'legacy-notes',actionCards:'[]'});
assert.equal(elements.get('actionCardPanel').hidden,true);assert.equal(elements.get('actionEditor').open,true);
console.log('PASS: action-source identity and exact quote, stale/busy guards, manual-edit and legacy fallback');
// A changed source/date must not leave selectable rows from the previous list.
const calendar={open:true,busy:false,day:'2026-10-13',provider:'test.calendar/list',providers:[{id:'test.calendar/list',title:'Test calendar'},{id:'test.other/list',title:'Other calendar'}],events:[{id:'0',title:'Design review',when:'9 AM',calendar:'Test'}],status:'Choose the exact meeting occurrence.',next:6,total:7};
callback({...state,calendar:JSON.stringify(calendar)});
const calendarButton=()=>elements.get('calendarEvents').children[0].children[1];
assert.equal(calendarButton().disabled,false);
elements.get('calendarProvider').value='test.other/list';elements.get('calendarProvider').onchange();
assert.equal(calendarButton().disabled,true);assert.equal(elements.get('calendarMore').disabled,true);
calendarButton().onclick();assert.notEqual(emitted.at(-1)?.values.command,'calendarLink');
elements.get('calendarList').onclick();assert.equal(emitted.pop().values.provider,'test.other/list');
callback({...state,calendar:JSON.stringify({...calendar,provider:'test.other/list',status:'Calendar unavailable. Saved link kept.'})});
assert.equal(elements.get('calendarStatus').textContent,'Calendar unavailable. Saved link kept.');
assert.equal(calendarButton().disabled,false);
elements.get('calendarDay').value='2026-10-14';elements.get('calendarDay').oninput();assert.equal(calendarButton().disabled,true);
callback({...state,calendar:JSON.stringify({...calendar,provider:'test.other/list',day:'2026-10-14',events:[],next:-1,total:0,status:'No events on this day. Choose another date.'})});
assert.equal(elements.get('calendarStatus').textContent,'No events on this day. Choose another date.');
assert.equal(elements.get('calendarEvents').children.length,0);
console.log('PASS: stale calendar rows/pagination blocked, updated source/date status appears in the same state update');
const storedTurn={id:'saved-turn-id',question:'What changed?',when:'Oct 13',status:'Saved',sources:[{id:'s1',label:'Launch review · 00:08',text:''}],answer:{disposition:'answered',statements:[{text:'Launch moved to Monday.',citations:['s1']}]}};
const chat={busy:false,question:'',provider:'test.assistant/answer_evidence_chat',providers:[],scope:'library',thread:'library',canAsk:true,history:[storedTurn],historyPage:0,historyPages:2,historyCount:3,context:[]};
callback({...state,selected:'',hasTranscript:false,ask:JSON.stringify(chat)});
assert.equal(elements.get('detail').hidden,false);assert.equal(elements.get('create').hidden,true);assert.equal(elements.get('questionPreview').disabled,false);
const history=elements.get('chatHistory');history.children[0].children[2].children[1].children[0].onclick();
const navigation=emitted.pop().values;assert.equal(navigation.event,'saved-turn-id');assert.equal(navigation.citation,'s1');
history.children[0].children[3].onclick();assert.equal(emitted.pop().values.command,'chatTurn');
elements.get('chatEarlier').onclick();assert.equal(emitted.pop().values.offset,1);
callback({...state,selected:'',ask:JSON.stringify({...chat,busy:true})});assert.equal(elements.get('chatHistory').children[0].children[3].disabled,true);
callback({...state,selected:'',ask:JSON.stringify({...chat,prepared:true,question:'What changed?',history:[],context:[{question:'When is launch?',answer:'Friday.'}]})});
assert.equal(elements.get('questionContext').children[0].textContent,'Recent context · You: When is launch?\nNero: Friday.');
callback({...state,selected:'',ask:JSON.stringify(chat)});assert.equal(elements.get('meetingQuestion').value,'');
console.log('PASS: persistent history navigation carries exchange plus source ID, library chat works without a selected transcript, history locks while asking, explicit follow-up context and composer reset');

const organization={scope:'work',name:'Work',member:'unfiled',options:JSON.stringify([{id:'all',name:'All meetings',count:'3'},{id:'unfiled',name:'Unfiled',count:'2'},{id:'work',name:'Work',count:'1'}]),locked:'no',failed:'no',canUndo:'yes',importing:'no',importStatus:'',origin:''};
callback({...state,organization:JSON.stringify(organization)});
elements.get('folder').value='work';elements.get('folder').onchange();assert.equal(emitted.pop().values.event,'work');
elements.get('folderName').value='Projects';elements.get('folderCreate').onclick();assert.equal(emitted.pop().values.question,'Projects');
elements.get('moveFolder').value='work';elements.get('moveFolder').onchange();assert.equal(emitted.pop().values.command,'folderMove');
const count=emitted.length;elements.get('folderRemove').onclick();assert.equal(emitted.length,count);elements.get('folderRemove').onclick();assert.equal(emitted.pop().values.command,'folderRemove');
callback({...state,busy:true,organization:JSON.stringify({...organization,locked:'yes',importing:'yes',importStatus:'Importing fixture.wav…',progress:'0.5'})});
assert.equal(elements.get('folder').disabled,true);assert.equal(elements.get('importRecording').disabled,true);assert.equal(elements.get('cancelImport').hidden,false);assert.equal(elements.get('importProgress').value,0.5);
elements.get('cancelImport').onclick();assert.equal(emitted.pop().values.command,'cancelImport');
callback({...state,ask:JSON.stringify(chat),organization:JSON.stringify({...organization,origin:'fixture.wav'})});
assert.equal(elements.get('chatHeading').textContent,'Ask Work');assert.equal(elements.get('importOrigin').textContent,'Imported · fixture.wav');
console.log('PASS: folder selection and move events, removal confirmation, import progress/cancel and busy locks, folder-scoped chat label');

const call={enabled:'yes',id:'exact-offer-id',app:'Teams in Chrome',title:'Teams call detected',scope:'Microphone + browser audio (all tabs)'};
callback({...state,callOffer:JSON.stringify(call),speakerState:JSON.stringify({enabled:'yes',ready:'yes',status:'Live Room / Call speakers'})});
assert.equal(elements.get('callOffer').hidden,false);assert.match(elements.get('callScope').textContent,/all tabs/);
elements.get('callStart').onclick();assert.equal(emitted.at(-1).name,'notebook');assert.equal(emitted.pop().values.event,'exact-offer-id');
elements.get('callDismiss').onclick();assert.equal(emitted.pop().values.command,'callDismiss');
elements.get('teamsOffers').checked=false;elements.get('teamsOffers').onchange();assert.equal(emitted.pop().values.enabled,false);
elements.get('separateSpeakers').checked=false;elements.get('separateSpeakers').onchange();assert.equal(emitted.pop().values.command,'speakerOptions');
callback({...state,busy:true,callOffer:JSON.stringify(call)});assert.equal(elements.get('callOffer').hidden,true);assert.equal(elements.get('separateSpeakers').disabled,true);
callback({...state,callOffer:JSON.stringify({...call,id:'',title:'Teams microphone in use'})});assert.equal(elements.get('callOffer').hidden,true);
console.log('PASS: empty SDK bootstrap, exact call offer identity, browser-wide disclosure, opt-out controls and busy locks');

callback({...state,library:'[]',libraryQuery:'unmatched',organization:JSON.stringify(organization)});
assert.equal(elements.get('libraryEmpty').hidden,false);assert.equal(elements.get('emptyTitle').textContent,'No matching meetings');
assert.equal(elements.get('clearSearch').hidden,false);elements.get('clearSearch').onclick();
assert.equal(emitted.at(-1).values.query,'');assert.equal(emitted.pop().values.scope,'library');
callback({...state,library:'[]',libraryQuery:'',organization:JSON.stringify(organization)});
assert.equal(elements.get('emptyTitle').textContent,'This folder is empty');assert.equal(elements.get('clearSearch').hidden,true);
callback({...state,library:'[]',libraryQuery:'',organization:JSON.stringify({...organization,scope:'all'})});
assert.equal(elements.get('emptyTitle').textContent,'No meetings yet');
callback({...state,library:JSON.stringify([{id:'fixture',title:'Fixture',date:'Today',duration:3}]),libraryQuery:'',organization:JSON.stringify(organization)});
assert.equal(elements.get('libraryEmpty').hidden,true);assert.equal(elements.get('.libraryPages').hidden,false);
console.log('PASS: search, folder and first-use empty feedback; clear search uses the existing local filter contract; results restore pagination');
callback({...state,active:true,phase:'recording'});
assert.equal(elements.get('pause').hidden,false);assert.equal(elements.get('resume').hidden,true);assert.equal(elements.get('stop').hidden,false);assert.equal(elements.get('play').hidden,true);
callback({...state,active:true,phase:'paused'});assert.equal(elements.get('pause').hidden,true);assert.equal(elements.get('resume').hidden,false);assert.equal(elements.get('stop').hidden,false);
callback({...state,active:true,phase:'finishing'});assert.equal(elements.get('stop').disabled,true);
console.log('PASS: recording, paused and finishing transports retain visible Stop and the correct pause/resume controls');

// Source-grounded current tasks retain each independent original/change source.
const chain={id:'original',task:'prepare the launch checklist',owner:'Omar',deadline:'Wednesday',status:'active',
 sources:[{id:'original',quote:'I will prepare the launch checklist by Monday.',start:0,track:'mic'},
 {id:'takeover',quote:'I will take over and finish Wednesday.',start:10,track:'system'}]};
callback({...taskState,selected:'resolved-tasks',actionCards:JSON.stringify([chain])});
let resolvedCard=elements.get('actionCards').children[0];
assert.equal(resolvedCard.children[0].textContent,'Omar · Due Wednesday');
assert.equal(resolvedCard.children[2].children[3].textContent,chain.sources[1].quote);
resolvedCard.children[2].children[4].onclick();assert.equal(emitted.pop().values.citation,'takeover');
callback({...taskState,selected:'cancelled-task',actionCards:JSON.stringify([{...chain,status:'cancelled'}])});
assert.equal(elements.get('actionCards').children[0].children[0].textContent,'Cancelled');
callback({...taskState,selected:'fallback-task-changes',actionCards:'[]',taskChanges:'Cancelled · launch checklist'});
assert.equal(elements.get('taskChangesPanel').hidden,false);
assert.equal(elements.get('taskChanges').textContent,'Cancelled · launch checklist');
console.log('PASS: current owner/deadline, original + change navigation, cancelled state and bounded-card fallback');

callback({...taskState,selected:'no-explicit-tasks',actionCards:'[]',actionCoverage:'Action draft · explicit English commitments. Check other phrasing in the transcript.'});
assert.equal(elements.get('actionCoverage').hidden,false);
assert.ok(elements.get('actionCoverage').textContent.includes('Check other phrasing'));
console.log('PASS: limited-language coverage remains visible even with no automatic tasks');
