let folderOptionsRevision='', folderMoveRevision='', folderRemoveConfirm=false;
let calendarDirty=false;
let calendarRevision='',calendarProviderRevision='';
let questionMeeting='',questionRevision='',questionSourceRevision='',lastScrolledSource='';
let chatHistoryRevision='',lastBackendQuestion=null;
let reviewRevision='',speakerRevision='';
let notebookID='',notebookDirty=false,replaceConfirmed=false,liveRevision='',catchRevision='',actionCardRevision='',readingRevisions={};
const $=id=>document.getElementById(id);let s={},previousLibrary='',previousSources='',current='',scrubbing=false;
const time=n=>{n=Math.max(0,Math.floor(n||0));return n>=3600?`${Math.floor(n/3600)}:${String(Math.floor(n/60)%60).padStart(2,'0')}:${String(n%60).padStart(2,'0')}`:`${String(Math.floor(n/60)).padStart(2,'0')}:${String(n%60).padStart(2,'0')}`;};
function emit(name,values={}){nero.emit(name,values).catch(e=>{$('error').hidden=false;$('error').textContent=e.message||'This control is unavailable.';});}
function parse(value){if(value&&typeof value==='object')return value;try{return JSON.parse(value||'[]');}catch{return[];}}
function list(){$('transcriptionSearchNotice').textContent=s.searchNotice||'';$('transcriptionSearchNotice').hidden=!s.searchNotice;$('library').replaceChildren();for(const m of parse(s.library)){const b=document.createElement('button');b.className=m.id===s.selected?'selected':'';b.disabled=s.busy;const title=document.createElement('strong');title.textContent=m.title;const info=document.createElement('small');info.textContent=`${m.date} · ${time(+m.duration)}${m.calendar?' · ▦ '+m.calendar:''}${m.transcriptionStatus?' · '+m.transcriptionStatus:''}`;b.append(title,info);b.onclick=()=>{if(notebookDirty){$('notesSave').textContent='Save your notes before switching meetings.';return;}emit('select',{id:m.id});};$('library').append(b);}}
$('record').onclick=()=>emit('record',{title:$('name').value,mic:$('mic').checked,source:$('source').value,live:$('liveEnabled').checked});
$('liveEnabled').onchange=()=>emit('process',{action:$('liveEnabled').checked?'live:on':'live:off'});
$('liveASR').onchange=()=>emit('process',{action:'asr:'+$('liveASR').value});$('prepareLive').onclick=()=>emit('process',{action:'prepareASR'});
$('cancelLivePrepare').onclick=()=>emit('process',{action:'cancel'});
$('catchUpButton').onclick=()=>emit('notebook',{command:'catchup',seconds:+$('catchUpSeconds').value});
$('stopCatchUp').onclick=()=>emit('notebook',{command:'cancelCatchup'});
$('showLive').onclick=()=>emit('process',{action:'showLive'});$('showRefined').onclick=()=>emit('process',{action:'showRefined'});
for(const name of ['new','refresh','pause','resume','stop','play','files','delete'])$(name).onclick=()=>{if(notebookDirty&&['new','delete'].includes(name)){$('notesSave').textContent='Save your notes before changing meetings.';return;}if(name==='refresh')emit('notebook',{command:'refresh'});else emit(name);};
$('clearSearch').onclick=()=>{clearTimeout(searchTimer);$('search').value='';emit('page',{number:0,scope:'library',query:''});$('search').focus();};
let searchTimer; $('search').oninput=()=>{clearTimeout(searchTimer);searchTimer=setTimeout(()=>emit('page',{number:0,scope:'library',query:$('search').value}),250);};$('title').onchange=()=>emit('rename',{title:$('title').value});$('seek').oninput=()=>{scrubbing=true;$('position').textContent=time(+$('seek').value);};$('seek').onchange=()=>{emit('seek',{time:+$('seek').value});scrubbing=false;};
nero.onState(next=>{window.NookAvatar?.setBusy?.(!!next.active||!!next.playing);s=next;if(document.activeElement!==$('search'))$('search').value=s.libraryQuery||'';const selected=!!s.selected,libraryChat=(parse(s.ask)||{}).scope==='library'&&s.notebookPage==='ask';document.body.classList.toggle('libraryChat',libraryChat);document.body.classList.toggle('savedMeeting',selected&&!s.active&&!libraryChat);$('create').hidden=selected||libraryChat;$('detail').hidden=!selected&&!libraryChat;$('badge').textContent=s.active?(s.phase==='paused'?'PAUSED':'● MEETING IN PROGRESS'):'RECORDING LIBRARY';$('badge').style.color=s.active?'#ffc0cb':'';
if(current!==s.selected){current=s.selected;$('title').value=s.title||'';$('error').hidden=true;}
if(document.activeElement!==$('title'))$('title').value=s.title||'';$('title').disabled=s.busy;$('clock').textContent=time(s.duration);$('micMeter').value=s.micLevel||0;$('systemMeter').value=s.systemLevel||0;document.querySelector('.meters').hidden=!s.active;
$('pause').hidden=s.phase!=='recording';$('resume').hidden=s.phase!=='paused';$('stop').hidden=!s.active;$('stop').disabled=s.phase==='finishing';$('bookmark').hidden=s.phase!=='recording';$('play').hidden=s.active;$('play').disabled=!s.hasAudio;$('play').textContent=s.playing?'Ⅱ Pause playback':'▶ Play recording';$('playback').hidden=s.active||!s.hasAudio;
if(!scrubbing){$('seek').max=Math.max(1,s.duration||0);$('seek').value=s.position||0;$('position').textContent=time(s.position);}$('total').textContent=time(s.duration);
for(const id of ['new','refresh','delete'])$(id).disabled=!!s.busy;$('files').disabled=s.active;$('status').textContent=s.status||'';$('issue').textContent=s.issue||'';$('issue').hidden=!s.issue;
if(previousLibrary!==s.library||list.selection!==s.selected||list.active!==s.busy){previousLibrary=s.library;list.selection=s.selected;list.active=s.busy;list();}
if(previousSources!==s.sources){previousSources=s.sources;const value=$('source').value;$('source').replaceChildren();for(const src of [{id:'none',name:'Microphone only'},{id:'all',name:'All system audio'},...parse(s.sources)]){const option=document.createElement('option');option.value=src.id;option.textContent=src.name;$('source').append(option);}$('source').value=Array.from($('source').options).some(x=>x.value===value)?value:'none';}
$('marks').replaceChildren();for(const mark of parse(s.bookmarks)){const b=document.createElement('button');b.textContent=`⚑ ${time(mark.time)}`;b.disabled=s.busy;b.onclick=()=>emit('seek',{time:mark.time});$('marks').append(b);}
renderCallAndSpeakers();renderReview();renderTranscriptionReview();renderNotebook();renderLive();renderQuestion();renderCalendar();renderOrganization();renderLibraryFeedback();scrollCitedPassage();
});
for(const [id,action] of [['transcribe','transcribe'],['prepareASR','prepareASR'],['prepareSpeakers','prepare'],['identify','speakers'],['cancelProcess','cancel']])$(id).onclick=()=>emit('process',{action});
$('asr').onchange=()=>emit('process',{action:'asr:'+$('asr').value});
$('previousPage').onclick=()=>emit('page',{number:(s.page||0)-1,scope:'transcript',query:''});$('nextPage').onclick=()=>emit('page',{number:(s.page||0)+1,scope:'transcript',query:''});
$('libraryPrevious').onclick=()=>emit('page',{number:(s.libraryPage||0)-1,scope:'library',query:$('search').value});
$('libraryNext').onclick=()=>emit('page',{number:(s.libraryPage||0)+1,scope:'library',query:$('search').value});
$('export').onclick=()=>emit('process',{action:'export'});
function renderReview(){
$('libraryPage').textContent=`${(s.libraryPage||0)+1} / ${s.libraryPages||1}`;$('libraryPrevious').disabled=s.busy||(s.libraryPage||0)<=0;$('libraryNext').disabled=s.busy||(s.libraryPage||0)+1>=(s.libraryPages||1);$('export').disabled=s.busy||!s.hasTranscript;

$('analysis').hidden=s.active||!s.hasAudio||s.notebookPage!=='transcript';$('asr').value=s.asrProvider||'apple';$('asr').disabled=s.busy;
$('prepareASR').hidden=s.asrProvider==='apple'||s.parakeetReady;$('prepareASR').disabled=s.busy;
$('transcribe').disabled=s.busy||s.transcriptComplete||(s.asrProvider!=='apple'&&!s.parakeetReady);
$('transcribe').textContent=s.transcriptComplete?'Transcript complete':s.hasTranscript?'Continue transcript':'Transcribe';
if(s.liveDraft&&!s.transcriptComplete)$('transcribe').textContent='Refine saved audio';
$('refinementNotice').textContent=s.refinementNotice||'';$('refinementNotice').hidden=!s.refinementNotice;
$('showLive').hidden=!s.hasLive;$('showRefined').hidden=!s.hasRefined;$('showLive').disabled=s.busy||s.liveDraft;$('showRefined').disabled=s.busy||!s.liveDraft;
$('asrHint').textContent=s.asrProvider!=='apple'?'The selected MLX model runs in Nero Voice after an explicit local-model download. It auto-detects supported languages. Your Apple Speech transcript and edits stay separate.':'Apple Speech runs on this Mac. Switching models preserves this transcript and its corrections.';
$('prepareSpeakers').hidden=s.speakersReady;$('prepareSpeakers').disabled=s.busy;$('identify').hidden=!s.speakersReady;$('identify').disabled=s.busy||!s.hasTranscript;$('cancelProcess').hidden=!s.processing;$('progress').hidden=!s.processing;if(s.progress>0)$('progress').value=s.progress;else $('progress').removeAttribute('value');
$('speakerHint').textContent=s.speakersReady?'Local analysis · Nemotron 3 · up to 8 speakers per track. Review labels; names are yours to assign.':'Prepare speakers downloads a 199 MB model. Recording and transcription stay on this Mac.';
$('pages').hidden=!s.hasTranscript;$('pageLabel').textContent=`${(s.page||0)+1} / ${s.pages||1}`;$('previousPage').disabled=(s.page||0)<=0;$('nextPage').disabled=(s.page||0)+1>=(s.pages||1);
const speakers=parse(s.speakers)||{};const key=(s.selected||'')+s.transcript+s.speakers+String(s.busy)+(s.highlight||'');
if(reviewRevision!==key&&!$('transcript').contains(document.activeElement)){
reviewRevision=key;$('transcript').replaceChildren();for(const line of parse(s.transcript)){
 const row=document.createElement('article');row.className='utterance'+(line.id===s.highlight?' highlighted':'');row.dataset.id=line.id;const head=document.createElement('div');head.className='utteranceHead';const seek=document.createElement('button');seek.textContent=time(+line.start);seek.title='Play from here';seek.onclick=()=>{emit('seek',{time:+line.start});if(!s.playing)emit('play');};const label=document.createElement('strong');label.textContent=(speakers[line.speaker]||`Unassigned · ${line.track==='mic'?'microphone':((parse(s.organization)||{}).origin?'imported audio':'call')}`)+(line.recognitionAlternative==='yes'?' · kept recognition version · may overlap':'')+(line.excerpt==='yes'?' · cited excerpt':'');const edit=document.createElement('button');edit.textContent='Edit';edit.disabled=s.busy;const body=document.createElement('p');body.textContent=line.text;head.append(seek,label,edit);row.append(head,body);
 edit.onclick=()=>{const text=document.createElement('textarea');text.value=line.text;text.readOnly=line.truncated==='yes';text.maxLength=4000;const select=document.createElement('select');for(const [id,name] of [['','Unassigned'],...['mic','system'].flatMap(track=>[0,1,2,3,4,5,6,7].map(n=>[`${track}-${n}`,speakers[`${track}-${n}`]||`${track==='mic'?'Mic':'Call'} speaker ${n+1}`]))]){const o=document.createElement('option');o.value=id;o.textContent=name;select.append(o);}select.value=line.speaker;const save=document.createElement('button');save.textContent='Save correction';save.onclick=()=>{emit('review',{id:line.id,text:text.value,speaker:select.value,editText:line.truncated!=='yes'});reviewRevision='';document.activeElement?.blur();};const cancel=document.createElement('button');cancel.textContent='Cancel';cancel.onclick=()=>{reviewRevision='';document.activeElement?.blur();renderReview();};body.replaceWith(text);edit.disabled=true;row.append(select,save,cancel);text.focus();};$('transcript').append(row);
}}
const namesKey=(s.selected||'')+s.speakers+String(s.busy);if(speakerRevision!==namesKey&&!$('speakers').contains(document.activeElement)){speakerRevision=namesKey;$('speakers').replaceChildren();for(const [id,name] of Object.entries(speakers)){const wrap=document.createElement('label');const input=document.createElement('input');input.value=name;input.maxLength=40;input.title='Rename speaker';input.disabled=s.busy;input.onchange=()=>emit('review',{id:'name:'+id,text:input.value,speaker:'',editText:false});wrap.append(input);$('speakers').append(wrap);}}
}

for(const [id,page] of [['tabTranscript','transcript'],['tabThoughts','thoughts'],['tabNotes','notes'],['tabAsk','ask']])$(id).onclick=()=>{if(notebookDirty){$('notesSave').textContent='Save your edits before changing tabs.';return;}emit('notebook',{command:'page',page});};
for(const id of ['thoughts','summary','decisions','actions','notesReviewed'])$(id).oninput=()=>{notebookDirty=true;$('notesSave').textContent='Unsaved edits';renderNoteEvidence();};
$('saveNotes').onclick=()=>{const values={thoughts:$('thoughts').value,summary:$('summary').value,decisions:$('decisions').value,actions:$('actions').value,reviewed:$('notesReviewed').checked};if(Object.values(values).some(v=>typeof v==='string'&&new TextEncoder().encode(v).length>2048)){$('notesSave').textContent='Keep each field under 2 KB.';return;}emit('notebook',{command:'save',...values});notebookDirty=false;$('notesSave').textContent='Saving…';};
$('summarize').onclick=()=>{if(notebookDirty){$('notesSave').textContent='Save your edits first.';return;}if(s.summary||s.decisions||s.actionItems){$('notesSave').textContent='Replace existing summary?';$('summarize').textContent='Replace summary draft';if(!replaceConfirmed){replaceConfirmed=true;return;}replaceConfirmed=false;}emit('notebook',{command:'summarize'});};
$('cancelSummary').onclick=()=>emit('notebook',{command:'cancel'});$('copyNotes').onclick=()=>emit('notebook',{command:'copy',personal:$('includePersonal').checked});
function renderNotebook(){
 const page=s.notebookPage||'transcript';$('notebook').hidden=!['thoughts','notes'].includes(page);$('personalNotes').hidden=page!=='thoughts';$('derivedNotes').hidden=page!=='notes';document.body.classList.toggle('showNotebook',page!=='transcript');
 for(const [id,key] of [['tabTranscript','transcript'],['tabThoughts','thoughts'],['tabNotes','notes'],['tabAsk','ask']])$(id).classList.toggle('selected',page===key);
 if(notebookID!==s.selected){notebookID=s.selected;notebookDirty=false;replaceConfirmed=false;$('notesSave').textContent='';$('includePersonal').checked=false;}
 if(!notebookDirty&&['thoughts','notes'].includes(page)){for(const [id,key] of [['thoughts','thoughts'],['summary','summary'],['decisions','decisions'],['actions','actionItems']]){if(document.activeElement!==$(id))$(id).value=s[key]||'';}$('notesReviewed').checked=!!s.notesReviewed;}
 $('saveNotes').disabled=!!s.summarizing;$('summarize').disabled=s.busy||!s.hasTranscript||!s.summaryAvailable;$('cancelSummary').hidden=!s.summarizing;
 $('summaryHint').textContent=s.summarizing?'Summarizing on this Mac…':s.notesStale?'Transcript changed — saved source links are stale. Regenerate to update them.':!s.summaryAvailable?'Enable Apple Intelligence for local summaries.':s.notesReviewed?'Reviewed notes':'AI drafts need your review. No recording is uploaded.';
 renderNoteEvidence();
 if(s.status==='Notes saved on this Mac'&&!notebookDirty)$('notesSave').textContent='Saved on this Mac';
}
function renderActionCards(){
 const tasks=parse(s.actionCards)||[],revision=String(s.selected)+':'+JSON.stringify(tasks);
 const structured=tasks.length>0&&!notebookDirty;
 $('actionCardPanel').hidden=!structured;$('actionCards').replaceChildren();
 $('taskChangesPanel').hidden=structured||!s.taskChanges||notebookDirty;$('taskChanges').textContent=s.taskChanges||'';
 $('actionCoverage').hidden=!s.actionCoverage||notebookDirty;$('actionCoverage').textContent=s.actionCoverage||'';
 if(actionCardRevision!==revision){actionCardRevision=revision;$('actionEditor').open=!structured;}
 if(notebookDirty)$('actionEditor').open=true;
 $('actionEditorLabel').textContent=tasks.length?'Edit action list':'Action items';
 if(!structured)return;
 for(const task of tasks){
  const card=document.createElement('article');card.className='actionCard';
  const title=document.createElement('strong');title.textContent=task.task;
  card.dataset.state=task.status||'active';
  const meta=document.createElement('small');
  meta.textContent=(task.status==='cancelled'?'Cancelled':task.status==='uncertain'?'Needs review':task.status==='active'?task.owner||'Unassigned':'Action item')+
   (task.status==='active'?(task.deadline?' · Due '+task.deadline:' · No deadline stated'):'');
  const words=document.createElement('details');const label=document.createElement('summary');label.textContent='Original words & changes';words.append(label);
  const sources=task.sources||[{id:task.id,quote:task.quote,start:task.start,track:task.track}];
  for(const item of sources){
   const quote=document.createElement('blockquote');quote.textContent=item.quote;
   const source=document.createElement('button');source.textContent=`Source · ${time(item.start)} · ${item.track==='mic'?'room':'call'}`;
   source.disabled=!!s.notesStale||!!s.busy||notebookDirty;
   source.onclick=()=>{if(s.notesStale||s.busy||notebookDirty)return;emit('notebook',{command:'noteSource',citation:item.id});};
   words.append(quote,source);
  }
  card.append(meta,title,words);$('actionCards').append(card);
 }
}
function renderNotesReading(){
 for(const id of ['summary','decisions']){
  const text=s[id]||'',revision=String(s.selected)+':'+text,edited=notebookDirty&&$(id).value!==text;
  const editor=$(id+'Editor'),reading=$(id+'Reading');
  if(readingRevisions[id]!==revision&&!notebookDirty){readingRevisions[id]=revision;editor.open=false;}
  reading.hidden=edited||!text;reading.textContent=text;
  if(edited)editor.open=true;
  $(id+'EditorLabel').textContent=(text?'Edit ':'Add ')+id;
 }
}
function renderNoteEvidence(){
 renderNotesReading();
 renderActionCards();
 const items=parse(s.noteEvidence)||[];$('noteEvidencePanel').hidden=!items.length;$('noteEvidence').replaceChildren();
 const paging=parse(s.noteEvidencePaging)||{};const page=+paging.page||0,pages=+paging.pages||1;
 $('noteEvidencePage').textContent=`${page+1} / ${pages}`;$('noteEvidencePrevious').disabled=page<=0||notebookDirty;$('noteEvidenceNext').disabled=page+1>=pages||notebookDirty;
 $('noteEvidencePrevious').onclick=()=>{if(!notebookDirty)emit('notebook',{command:'noteEvidencePage',offset:page-1});};$('noteEvidenceNext').onclick=()=>{if(!notebookDirty)emit('notebook',{command:'noteEvidencePage',offset:page+1});};
 $('noteEvidenceHint').textContent=s.notesStale?'These quotes belong to an earlier transcript. Regenerate to open current sources.':notebookDirty?'Save your edits before opening a source. Edited sections lose their generated links.':'Check each claim against the original words. Speaker labels do not establish a person’s identity.';
 for(const item of items){
  const card=document.createElement('article');card.className='noteEvidenceCard';
  const label=document.createElement('small');label.textContent=({summary:'Summary',decisions:'Decision',actions:'Action item'})[item.section]||'Note';
  const fact=document.createElement('p');fact.textContent=item.fact;
  const quote=document.createElement('blockquote');quote.textContent=item.quote;
  const source=document.createElement('button');source.textContent=`Open ${time(item.start)} · ${item.track==='mic'?'room audio':'call audio'}`;source.disabled=!!s.notesStale||!!s.busy||notebookDirty;
  source.onclick=()=>{if(notebookDirty||s.notesStale)return;emit('notebook',{command:'noteSource',citation:item.id});};
  card.append(label,fact,quote,source);$('noteEvidence').append(card);
 }
}

$('bookmark').onclick=()=>emit('process',{action:'bookmark'});

function renderLive(){
 const provider=s.asrProvider||'apple';
 const model={apple:'Apple Speech',nemotron:'Nemotron 3.5',parakeet:'Parakeet'}[provider];
 let hint='Audio-only recording. Transcribe the saved audio afterward.';
 if(s.liveEnabled){
  if(!model)hint='Choose a supported speech model for live transcription.';
  else if(provider!=='apple'&&!s.parakeetReady)hint=`Download ${model} to enable live transcription. Otherwise, audio-only recording; no model fallback.`;
  else hint=provider==='parakeet'?'Parakeet updates at pauses or every 10 seconds.':'Live words · '+model+'.';
 }
 $('liveHint').textContent='Audio and words stay on this Mac. '+hint;
 $('liveEnabled').checked=!!s.liveEnabled;$('liveEnabled').disabled=s.busy;$('liveASR').value=s.asrProvider||'apple';$('liveASR').disabled=s.busy;
 $('prepareLive').hidden=s.asrProvider==='apple'||s.parakeetReady;$('prepareLive').disabled=s.busy;$('record').disabled=!!s.busy;
 $('cancelLivePrepare').hidden=!s.processing;
 const page=s.notebookPage||'transcript',show=s.active&&page==='transcript';document.body.classList.toggle('liveMeeting',!!s.active);
 $('livePanel').hidden=!show;$('liveStatus').textContent=s.liveStatus||'Audio-only recording';
 const key=(s.selected||'')+s.transcript+s.partials+s.speakers;
 if(liveRevision!==key){liveRevision=key;const follow=$('liveLines').scrollHeight-$('liveLines').scrollTop-$('liveLines').clientHeight<45;
  $('liveLines').replaceChildren();for(const line of parse(s.transcript)){const row=document.createElement('div');row.className='liveTurn';const head=document.createElement('small');head.textContent=`${time(+line.start)} · ${(parse(s.speakers)||{})[line.speaker]||(line.track==='mic'?'Room · unassigned':'Call · unassigned')}`;const body=document.createElement('p');body.textContent=line.text;row.append(head,body);$('liveLines').append(row);}if(follow)$('liveLines').scrollTop=$('liveLines').scrollHeight;
  $('livePartials').replaceChildren();for(const line of parse(s.partials)){const row=document.createElement('div');row.className='liveTurn partial';const head=document.createElement('small');head.textContent=`${line.track==='mic'?'Microphone':'Call audio'} · recognizing…`;const body=document.createElement('p');body.textContent=line.text;row.append(head,body);$('livePartials').append(row);}
 }
 const catchup=parse(s.catchUp)||{};$('catchUpControls').hidden=page!=='transcript';$('catchUpButton').disabled=!s.hasTranscript||catchup.busy==='yes'||s.processing||s.summarizing;
 $('stopCatchUp').hidden=catchup.busy!=='yes';$('catchUpStatus').textContent=catchup.status||'';
 const hasFacts=!!(catchup.summary||catchup.decisions||catchup.actions);$('catchUpCard').hidden=page!=='transcript'||!hasFacts;$('catchUpRange').textContent=catchup.range||'';
 if(catchRevision!==s.catchUp){catchRevision=s.catchUp;$('catchUpFacts').replaceChildren();for(const [key,label] of [['summary','What happened'],['decisions','Decisions'],['actions','Next steps']]){if(!catchup[key])continue;const group=document.createElement('div');const title=document.createElement('small');title.textContent=label;const facts=document.createElement('p');facts.textContent=catchup[key];group.append(title,facts);$('catchUpFacts').append(group);}}
}


$('questionEvidenceToggle').onclick=()=>{$('questionSources').hidden=!$('questionSources').hidden;};
$('questionPreview').onclick=()=>{if(notebookDirty){$('questionStatus').textContent='Save your notes before asking.';return;}emit('notebook',{command:'questionPreview',question:$('meetingQuestion').value});};
$('questionSend').onclick=()=>emit('notebook',{command:'questionSend'});
$('questionStop').onclick=()=>emit('notebook',{command:'questionStop'});
$('questionProvider').onchange=()=>emit('notebook',{command:'questionProvider',provider:$('questionProvider').value});
$('askLibrary').onclick=$('chatLibrary').onclick=()=>{if(!notebookDirty)emit('notebook',{command:'chatScope',page:'library'});};
$('chatCurrent').onclick=()=>emit('notebook',{command:'chatScope',page:'meeting'});
$('chatNew').onclick=()=>emit('notebook',{command:'chatNew'});$('chatRestore').onclick=()=>emit('notebook',{command:'chatRestore'});
$('chatDismiss').onclick=()=>emit('notebook',{command:'chatDismiss'});
$('chatFilter').onchange=()=>emit('notebook',{command:'chatFilter',question:$('chatFilter').value});
$('chatEarlier').onclick=()=>emit('notebook',{command:'chatPage',offset:((parse(s.ask)||{}).historyPage||0)+1});
$('chatLater').onclick=()=>emit('notebook',{command:'chatPage',offset:Math.max(0,((parse(s.ask)||{}).historyPage||0)-1)});
$('meetingQuestion').oninput=()=>{const a=parse(s.ask)||{};$('questionSend').disabled=a.busy||$('meetingQuestion').value.trim()!==a.question||!a.provider;};
function renderQuestion(){
 const a=parse(s.ask)||{}, page=s.notebookPage||'transcript';$('askMeeting').hidden=page!=='ask';
 if(questionMeeting!==(a.thread||s.selected)){questionMeeting=a.thread||s.selected;$('meetingQuestion').value=a.question||'';$('questionSources').hidden=true;lastBackendQuestion=a.question||'';}
 if(lastBackendQuestion!==a.question&&!a.busy){$('meetingQuestion').value=a.question||'';lastBackendQuestion=a.question;}
 if(document.activeElement!==$('meetingQuestion')&&!$('meetingQuestion').value)$('meetingQuestion').value=a.question||'';
 $('meetingQuestion').disabled=!!a.busy;$('questionPreview').disabled=!!a.busy||a.canAsk===false||s.processing||s.summarizing||s.phase==='finishing'||s.phase==='preparing';$('questionStop').hidden=!a.busy;
 $('chatHeading').textContent=a.scope==='library'?'Ask saved meetings':'Ask this meeting';$('askLibrary').disabled=!!s.busy;$('chatCurrent').disabled=a.busy||!s.selected;$('chatLibrary').disabled=a.busy||s.active;$('chatCurrent').classList.toggle('selected',a.scope!=='library');$('chatLibrary').classList.toggle('selected',a.scope==='library');
 $('chatFilterLabel').hidden=a.scope!=='library';$('chatFilter').disabled=!!a.busy;if(document.activeElement!==$('chatFilter'))$('chatFilter').value=a.filter||'';
 $('chatNew').disabled=a.busy||!a.historyCount||s.active;$('chatRestore').disabled=a.busy||s.active||!a.canRestore;$('chatDismiss').disabled=!!a.busy;
 $('chatCount').textContent=(a.historyCount||0)+' saved '+(a.historyCount===1?'exchange':'exchanges');$('chatPages').hidden=!!a.prepared||!(a.historyCount>2);$('chatEarlier').disabled=a.busy||(a.historyPage||0)+1>=(a.historyPages||1);$('chatLater').disabled=a.busy||!(a.historyPage>0);$('chatPageLabel').textContent=((a.historyPage||0)+1)+' / '+(a.historyPages||1);
 renderChatHistory(a);
 const providers=parse(a.providers)||[];const keys=JSON.stringify(providers);if($('questionProvider').dataset.revision!==keys){$('questionProvider').dataset.revision=keys;$('questionProvider').replaceChildren();for(const p of providers.length?providers:[{id:'',title:'Allow an assistant in Nook Settings'}]){const o=document.createElement('option');o.value=p.id;o.textContent=p.title;$('questionProvider').append(o);}}$('questionProvider').value=a.provider||'';$('questionProvider').disabled=!!a.busy||!providers.length;
 $('questionPreviewCard').hidden=!a.prepared;$('questionCoverage').textContent=a.coverage||'';$('questionSend').disabled=!!a.busy||!a.provider||$('meetingQuestion').value.trim()!==a.question;
 $('questionStatus').textContent=a.status||(!providers.length?'Connect Voice to a cited-answer assistant in Nook Settings → Modules.':'Start with a question. Preview selects the exact text to send.');
 const sources=parse(a.sources)||[];if(questionSourceRevision!==JSON.stringify(a.sources)){questionSourceRevision=JSON.stringify(a.sources);$('questionSources').replaceChildren();for(const source of sources){const row=document.createElement('article');row.dataset.source=source.id;const label=document.createElement('small');label.textContent=source.label;const p=document.createElement('p');p.textContent=source.text;row.append(label,p);$('questionSources').append(row);}}
 $('questionContext').replaceChildren();for(const exchange of a.context||[]){const p=document.createElement('p');p.className='chatContext';p.textContent='Recent context · You: '+exchange.question+'\nNero: '+exchange.answer;$('questionContext').append(p);}
 if(a.highlight){$('questionSources').hidden=false;for(const row of $('questionSources').children)row.classList.toggle('highlighted',row.dataset.source===a.highlight);const row=Array.from($('questionSources').children).find(x=>x.dataset.source===a.highlight);if(s.active)row?.scrollIntoView({block:'center'});}
 const answer=a.answer?parse(a.answer):null;$('meetingAnswer').hidden=!answer;
 if(questionRevision!==JSON.stringify(a.answer)){questionRevision=JSON.stringify(a.answer);$('meetingAnswer').replaceChildren();if(answer){const label=document.createElement('small');label.textContent='NERO · TRANSCRIPT ANSWER';$('meetingAnswer').append(label);if(answer.disposition==='insufficient'){const p=document.createElement('p');p.textContent='This excerpt does not contain enough information to answer. Try a more specific question or inspect the transcript.';$('meetingAnswer').append(p);}for(const statement of answer.statements||[]){const row=document.createElement('article');const p=document.createElement('p');p.textContent=statement.text;const links=document.createElement('div');links.className='citationLinks';for(const id of statement.citations||[]){const source=sources.find(x=>x.id===id);if(!source)continue;const b=document.createElement('button');b.textContent=source.label;b.title='Open transcript source '+id;b.onclick=()=>emit('notebook',{command:'questionSource',citation:id});links.append(b);}row.append(p,links);$('meetingAnswer').append(row);}}}
}

function renderChatHistory(a){
 const key=JSON.stringify(a.history)+String(a.busy);if(chatHistoryRevision===key)return;chatHistoryRevision=key;$('chatHistory').replaceChildren();
 for(const turn of a.history||[]){const exchange=document.createElement('article');exchange.className='chatExchange';const question=document.createElement('p');question.className='chatUser';question.textContent=turn.question;const stamp=document.createElement('small');stamp.textContent=turn.when+' · '+turn.status;exchange.append(question,stamp);
  if(turn.answer){if(turn.answer.disposition==='insufficient'){const p=document.createElement('p');p.textContent='The selected transcripts did not contain enough evidence to answer.';exchange.append(p);}
   for(const statement of turn.answer.statements||[]){const row=document.createElement('div');row.className='chatAssistant';const p=document.createElement('p');p.textContent=statement.text;const links=document.createElement('div');links.className='citationLinks';for(const id of statement.citations||[]){const source=(turn.sources||[]).find(x=>x.id===id);if(!source)continue;const button=document.createElement('button');button.textContent=source.label;button.title='Open original transcript passage';button.onclick=()=>emit('notebook',{command:'questionSource',citation:id,event:turn.id});links.append(button);}row.append(p,links);exchange.append(row);}}
  const inspect=document.createElement('button');inspect.className='chatInspect';inspect.textContent='Review sent excerpt';inspect.disabled=!!a.busy;inspect.onclick=()=>emit('notebook',{command:'chatTurn',event:turn.id});exchange.append(inspect);$('chatHistory').append(exchange);
 }
}

function scrollCitedPassage(){
 const key=(s.selected||'')+'|'+(s.highlight||'')+'|'+(s.page||0);
 if(s.notebookPage==='transcript'&&s.highlight&&lastScrolledSource!==key){
  const target=Array.from($('transcript').children).find(x=>x.dataset.id===s.highlight);
  if(target){lastScrolledSource=key;target.scrollIntoView({block:'center'});}
 }
 if(s.notebookPage!=='transcript'||!s.highlight)lastScrolledSource='';
}

$('calendarChoose').onclick=()=>{if(notebookDirty){$('notesSave').textContent='Save your notes before choosing a calendar meeting.';return;}emit('notebook',{command:'calendarOpen'});};
$('calendarClose').onclick=()=>{calendarDirty=false;emit('notebook',{command:'calendarClose'});};
function calendarPage(offset){emit('notebook',{command:'calendarList',date:$('calendarDay').value,provider:$('calendarProvider').value,offset});}
$('calendarProvider').onchange=$('calendarDay').oninput=()=>{calendarDirty=true;$('calendarStatus').textContent='Choose Show meetings to load this date and calendar.';renderCalendar();};
$('calendarList').onclick=()=>calendarPage(0);$('calendarMore').onclick=()=>calendarPage((parse(s.calendar)||{}).next||0);$('calendarFirst').onclick=()=>calendarPage(0);
$('calendarUnlink').onclick=()=>emit('notebook',{command:'calendarUnlink'});$('calendarVerify').onclick=()=>emit('notebook',{command:'calendarVerify'});$('calendarEvent').onclick=()=>emit('notebook',{command:'calendarEvent'});
function renderCalendar(){
 const c=parse(s.calendar)||{};document.body.classList.toggle('choosingCalendar',!!c.open);$('calendarPicker').hidden=!c.open;
 $('calendarChoose').textContent=c.linked?'▦ '+c.linked.title:'▦ Link calendar meeting';$('calendarChoose').title=c.linked?'Change linked calendar meeting':'Choose a calendar meeting';$('calendarChoose').disabled=c.busy||(parse(s.ask)||{}).busy||s.processing||s.summarizing;
 $('calendarLinkedWhen').textContent=c.linked?c.linked.when+' · '+c.linked.calendar:'';$('calendarVerify').hidden=!c.linked;$('calendarVerify').disabled=c.busy||!c.canVerify;$('calendarEvent').hidden=!c.linked||!c.canOpen;$('calendarEvent').disabled=c.busy||!c.canVerify;$('calendarUnlink').hidden=!c.linked;$('calendarUnlink').disabled=c.busy;
 const providers=c.providers||[],key=JSON.stringify(providers);if(calendarProviderRevision!==key){calendarProviderRevision=key;$('calendarProvider').replaceChildren();for(const p of providers.length?providers:[{id:'',title:'Allow Calendar reads in Nook Settings'}]){const o=document.createElement('option');o.value=p.id;o.textContent=p.title;$('calendarProvider').append(o);}}
 if(calendarDirty&&c.provider===$('calendarProvider').value&&c.day===$('calendarDay').value)calendarDirty=false;
 $('calendarStatus').textContent=calendarDirty?'Choose Show meetings to load this date and calendar.':c.status||'';
 if(!calendarDirty&&document.activeElement!==$('calendarProvider'))$('calendarProvider').value=c.provider||'';if(!calendarDirty&&document.activeElement!==$('calendarDay'))$('calendarDay').value=c.day||'';
 for(const id of ['calendarProvider','calendarDay','calendarList'])$(id).disabled=!!c.busy;const rowsKey=JSON.stringify(c.events)+String(c.busy)+String(calendarDirty);
 if(calendarRevision!==rowsKey){calendarRevision=rowsKey;$('calendarEvents').replaceChildren();for(const event of c.events||[]){const row=document.createElement('article');const body=document.createElement('div');const title=document.createElement('strong');title.textContent=event.title;const detail=document.createElement('small');detail.textContent=event.when+' · '+event.calendar;body.append(title,detail);const link=document.createElement('button');link.textContent='Link meeting';link.disabled=c.busy||calendarDirty;link.onclick=()=>{if(!calendarDirty)emit('notebook',{command:'calendarLink',event:event.id});};row.append(body,link);$('calendarEvents').append(row);}}
 $('calendarCount').textContent=(c.events||[]).length+' shown · '+(c.total||0)+' on this day';$('calendarMore').disabled=c.busy||calendarDirty||c.next<0;$('calendarFirst').disabled=c.busy;
 if(!s.selected&&c.linked&&!$('name').value)$('name').value=c.linked.title;
}


function organizationEvent(command,extra={}){if(notebookDirty){$('notesSave').textContent='Save your notes before organizing meetings.';return;}emit('notebook',{command,...extra});}
$('folder').onchange=()=>{folderRemoveConfirm=false;organizationEvent('folderSelect',{event:$('folder').value});};
$('folderManage').onclick=()=>{$('folderManager').hidden=!$('folderManager').hidden;folderRemoveConfirm=false;renderOrganization();};
$('folderCreate').onclick=()=>organizationEvent('folderCreate',{question:$('folderName').value});
$('folderRename').onclick=()=>organizationEvent('folderRename',{event:(parse(s.organization)||{}).scope,question:$('folderName').value});
$('folderRemove').onclick=()=>{if(!folderRemoveConfirm){folderRemoveConfirm=true;$('folderRemove').textContent='Confirm · keep recordings';return;}folderRemoveConfirm=false;organizationEvent('folderRemove',{event:(parse(s.organization)||{}).scope});};
$('folderUndo').onclick=()=>organizationEvent('folderUndo');
$('moveFolder').onchange=()=>organizationEvent('folderMove',{event:$('moveFolder').value});
$('importRecording').onclick=()=>organizationEvent('importRecording');$('cancelImport').onclick=()=>emit('notebook',{command:'cancelImport'});
function renderOrganization(){
 const o=parse(s.organization)||{}, options=parse(o.options)||[], key=JSON.stringify(options),locked=o.locked==='yes'||!!s.busy, failed=o.failed==='yes';
 if(folderOptionsRevision!==key){folderOptionsRevision=key;$('folder').replaceChildren();for(const f of options){const e=document.createElement('option');e.value=f.id;e.textContent=f.name+' · '+f.count;$('folder').append(e);}}
 $('folder').value=o.scope||'all';$('folder').disabled=locked||failed;
 if(folderMoveRevision!==key){folderMoveRevision=key;$('moveFolder').replaceChildren();for(const f of options.filter(f=>f.id!=='all')){const e=document.createElement('option');e.value=f.id;e.textContent=f.name;$('moveFolder').append(e);}}
 $('moveFolder').value=o.member||'unfiled';$('moveFolder').disabled=locked||failed;
 const custom=options.some(f=>f.id===o.scope)&&!['all','unfiled'].includes(o.scope);$('folderCreate').disabled=locked||failed;$('folderRename').disabled=locked||failed||!custom;$('folderRemove').disabled=locked||failed||!custom;$('folderUndo').disabled=locked||o.canUndo!=='yes';$('folderName').disabled=locked||failed;
 $('folderStatus').textContent=o.status||'Removing a folder keeps its recordings.';if(!folderRemoveConfirm)$('folderRemove').textContent='Remove folder';
 $('importRecording').disabled=!!s.busy||failed;for(const id of ['thoughts','summary','decisions','actions','notesReviewed','copyNotes'])$(id).disabled=o.importing==='yes';$('saveNotes').disabled=!!s.summarizing||o.importing==='yes';for(const id of ['calendarChoose','calendarVerify','calendarEvent','calendarUnlink']){if(o.importing==='yes')$(id).disabled=true;}if(o.importing==='yes')$('questionPreview').disabled=true;$('importPanel').hidden=!o.importStatus;$('importStatus').textContent=o.importStatus||'';$('importProgress').hidden=o.importing!=='yes';$('importProgress').value=+o.progress||0;$('cancelImport').hidden=o.importing!=='yes';$('cancelImport').disabled=o.importStatus==='Cancelling import…';
 $('importOrigin').textContent=o.origin?'Imported · '+o.origin:'';$('importOrigin').title=o.origin||'';
 if((parse(s.ask)||{}).scope==='library')$('chatHeading').textContent=o.scope&&o.scope!=='all'?'Ask '+o.name:'Ask saved meetings';
}

// These controls tolerate the SDK's initial empty state.
$('teamsOffers').onchange=()=>emit('notebook',{command:'callOffers',enabled:$('teamsOffers').checked});
$('separateSpeakers').onchange=()=>emit('notebook',{command:'speakerOptions',enabled:$('separateSpeakers').checked});
$('prepareMeetingSpeakers').onclick=()=>emit('process',{action:'prepare'});
$('callStart').onclick=()=>{if(notebookDirty){$('notesSave').textContent='Save your notes before starting another meeting.';return;}emit('notebook',{command:'callStart',event:(parse(s.callOffer)||{}).id||''});};
$('callDismiss').onclick=()=>emit('notebook',{command:'callDismiss',event:(parse(s.callOffer)||{}).id||''});
function renderCallAndSpeakers(){
 const call=parse(s.callOffer)||{},speakers=parse(s.speakerState)||{};
 $('callTitle').textContent=call.title||'Teams call detected';$('callOffer').hidden=!call.id||!!s.busy;$('callScope').textContent=(call.app||'Teams')+' · '+(call.scope||'')+' · Saved on this Mac';
 $('callStart').disabled=!!s.busy;$('teamsOffers').checked=call.enabled==='yes';
 $('separateSpeakers').checked=speakers.enabled==='yes';$('separateSpeakers').disabled=!!s.busy;
 $('prepareMeetingSpeakers').hidden=speakers.ready==='yes';$('prepareMeetingSpeakers').disabled=!!s.busy;
 $('speakerStatus').textContent=(speakers.enabled==='yes'?(s.asrProvider==='apple'?'Live provisional labels with Apple Speech. ':'Speaker labels after Stop · one MLX model at a time. '):'')+(speakers.status||'');
}

// Feedback describes the returned filter, never a half-typed query or stale selection.
function renderLibraryFeedback(){
 const empty=parse(s.library).length===0, query=(s.libraryQuery||'').trim(), o=parse(s.organization)||{};
 $('libraryEmpty').hidden=!empty;
 $('emptyTitle').textContent=query?'No matching meetings':o.scope&&o.scope!=='all'?'This folder is empty':'No meetings yet';
 $('emptyDetail').textContent=query?'Try a different word, or clear your search.':o.scope&&o.scope!=='all'?'Move a meeting here, or import a recording.':'Record or import a conversation to get started.';
 $('clearSearch').hidden=!query;$('clearSearch').disabled=!!s.busy;
 document.querySelector('.libraryPages').hidden=empty;
}

// Each closure captures the exact displayed tuple. A later render does not retarget it.
function renderTranscriptionReview(){
 const view=parse(s.transcriptionReview)||{},shown=(+view.count||0)>0;
 document.body.classList.toggle('transcriptionReviewMode',shown&&!!view.open);
 $('transcriptionReviewPanel').hidden=!shown;
 if(!shown)return;
 $('transcriptionComparison').hidden=!view.open;$('transcriptionReviewClose').hidden=!view.open;$('transcriptionReviewOpen').hidden=!!view.open;
 $('transcriptionReviewHeading').textContent=(view.processing?'Recognition in progress':view.recognitionComplete?'Recognition complete':'Recognition incomplete')+' · '+view.count+' passages need review';
 $('transcriptionReviewStatus').textContent=view.status||'Your corrections are retained.';
 $('transcriptionReviewStop').hidden=!view.processing;$('transcriptionReviewStop').disabled=!view.processing;
 $('transcriptionReviewProgress').hidden=!view.processing;if(+view.progress>0)$('transcriptionReviewProgress').value=+view.progress;else $('transcriptionReviewProgress').removeAttribute('value');
 // Existing cancel action retains the current original processing owner/task guard.
 $('transcriptionReviewStop').onclick=()=>{if((parse(s.transcriptionReview)||{}).processing)emit('process',{action:'cancel'});};
 $('transcriptionProtectedTitle').textContent=view.protectedTitle||'';$('transcriptionCandidateTitle').textContent=view.candidateTitle||'';$('transcriptionCandidateOrigin').textContent=[view.modelRevision,view.runtimeRevision,view.attempt?'Attempt '+view.attempt:''].filter(Boolean).join(' · ');
 $('transcriptionCandidateText').textContent=view.candidateText||'';$('transcriptionProtectedText').textContent=view.protectedText||'';
 $('transcriptionProtectedPage').textContent=(+view.protectedRow+1)+' / '+(+view.protectedRows||1);
 const tuple={meeting:view.meeting,provider:view.provider,revision:view.revision,candidate:view.candidate,digest:view.digest};
 const captured=JSON.stringify(tuple);
 const send=(choice,source='candidate',row=0,offset=0,candidate=tuple.candidate)=>{
  const current=parse(s.transcriptionReview)||{};
  if(current.busy||s.busy||(['keepCorrection','keepBoth'].includes(choice)&&!current.open)||JSON.stringify({meeting:current.meeting,provider:current.provider,revision:current.revision,candidate:current.candidate,digest:current.digest})!==captured)return;
  emit('transcriptionReview',{...tuple,candidate,choice,source,row,offset});
 };
 $('transcriptionReviewOpen').onclick=()=>send('open');$('transcriptionReviewClose').onclick=()=>send('close');
 $('transcriptionCandidateFirst').onclick=()=>send('page','candidate',0,0);
 $('transcriptionCandidateMore').onclick=()=>{if(view.candidateMore)send('page','candidate',0,+view.candidateNext);};
 $('transcriptionProtectedFirst').onclick=()=>send('page','protected',+view.protectedRow,0);
 $('transcriptionProtectedMore').onclick=()=>{if(view.protectedMore)send('page','protected',+view.protectedRow,+view.protectedNext);};
 $('transcriptionProtectedPrevious').onclick=()=>{if(+view.protectedRow>0)send('page','protected',+view.protectedRow-1,0);};
 $('transcriptionProtectedNext').onclick=()=>{if(+view.protectedRow+1<+view.protectedRows)send('page','protected',+view.protectedRow+1,0);};
 $('transcriptionCandidatePrevious').onclick=()=>{if(view.previousCandidate)send('page','candidate',0,0,view.previousCandidate);};
 $('transcriptionCandidateNext').onclick=()=>{if(view.nextCandidate)send('page','candidate',0,0,view.nextCandidate);};
 $('transcriptionKeepCorrection').onclick=()=>send('keepCorrection');$('transcriptionKeepBoth').onclick=()=>send('keepBoth');
 for(const id of ['transcriptionReviewOpen','transcriptionReviewClose','transcriptionKeepCorrection','transcriptionKeepBoth','transcriptionCandidateFirst','transcriptionProtectedFirst'])$(id).disabled=!!view.busy;
 $('transcriptionCandidateMore').disabled=!!view.busy||!view.candidateMore;$('transcriptionProtectedMore').disabled=!!view.busy||!view.protectedMore;
 $('transcriptionProtectedPrevious').disabled=!!view.busy||!(+view.protectedRow>0);$('transcriptionProtectedNext').disabled=!!view.busy||!(+view.protectedRow+1<+view.protectedRows);
 $('transcriptionCandidatePrevious').disabled=!!view.busy||!view.previousCandidate;$('transcriptionCandidateNext').disabled=!!view.busy||!view.nextCandidate;
}
