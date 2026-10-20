const $=id=>document.getElementById(id);let state={};
function emit(name,values){nero.emit(name,values).catch(e=>{$('status').textContent=e.message||'Control unavailable';});}
$('provider').onchange=()=>emit('provider',{value:$('provider').value});
for(const id of ['qwenStudio','prepareQwen','releaseQwen','preload','release_preload','prepare','record','cancel','copy','clear','read','preview','speechSettings'])$(id).onclick=()=>{if(document.activeElement===$('text'))$('text').blur();emit('command',{value:id});};
$('text').oninput=()=>emit('edit',{text:$('text').value});
nero.onState(s=>{window.NookAvatar?.setBusy?.(!!s.busy||!!s.recording||(!!s.speaking&&!s.reactionSpeaking));state=s;$('inputMeter').hidden=!s.recording;$('inputMeter').value=s.recording ? (s.level||0):0;$('preload').disabled=s.busy||s.speaking||!s.ready||s.warmReady;$('release_preload').hidden=!s.warmReady&&!s.warmBusy;$('warmStatus').textContent=s.warmStatus||'Microphone off';$('provider').value=s.provider;$('provider').disabled=s.busy;$('model').hidden=s.ready;$('prepare').disabled=s.busy;$('shortcut').textContent=s.shortcut;$('hint').textContent=s.style==='hold'?'Hold, speak, release to paste.':'Press to start. Press again to paste.';if(document.activeElement!==$('text')||s.busy)$('text').value=s.text||'';$('text').disabled=s.busy;$('status').textContent=s.status;$('record').textContent=s.recording?'Stop dictation':'Record draft here';$('record').disabled=s.busy&&!s.recording||!s.ready;$('cancel').disabled=!s.busy;$('copy').disabled=s.busy||!s.text;$('clear').disabled=s.busy;});
nero.onState(s=>{$('speechVoice').textContent=s.speechVoice||'System voice';$('preview').textContent=s.speaking?'Stop reading':'Preview voice';$('read').textContent=s.speaking?'Stop reading':'Read draft';$('preview').disabled=s.busy;$('read').disabled=s.busy||(!s.speaking&&!s.text);$('speechSettings').disabled=s.busy;$('cancel').disabled=!s.busy&&!s.speaking;});

let personalState={}, appRevision='', snippetListRevision='', historyRevision='', selectedSnippetID='', selectedHistoryID='', snippetDirty=false, appToneDirty=false, appSeen='', snippetRemoval=false;
const parse=value=>{if(value&&typeof value==='object')return value;try{return JSON.parse(value||'{}');}catch{return{};}};
const list=value=>{const parsed=parse(value);return Array.isArray(parsed)?parsed:[];};
function personal(command,values={}){emit('personal',{command,...values});}
for(const [id,page] of [['tabDictate','dictate'],['tabStyles','styles'],['tabSnippets','snippets'],['tabHistory','history']])$(id).onclick=()=>{if(snippetDirty){$('snippetDirty').textContent='Save your snippet edits before changing pages.';return;}personal('page',{page});};
$('defaultTone').onchange=()=>personal('defaultTone',{tone:$('defaultTone').value});
$('appSelect').onchange=()=>{appToneDirty=false;personal('appSelect',{app:$('appSelect').value});};
$('appTone').onchange=()=>{appToneDirty=true;};
let appSearchTimer;$('appSearch').oninput=()=>{clearTimeout(appSearchTimer);appSearchTimer=setTimeout(()=>personal('appSearch',{name:$('appSearch').value}),200);};
$('chooseApp').onclick=()=>personal('chooseApp');$('appSave').onclick=()=>personal('appSave',{app:$('appSelect').value,tone:$('appTone').value});$('appRemove').onclick=()=>{appToneDirty=false;personal('appRemove',{app:$('appSelect').value});};
$('applyDraft').onclick=()=>{if(document.activeElement===$('text'))$('text').blur();personal('applyDraft');};
$('snippetNew').onclick=()=>{if(snippetDirty){$('snippetDirty').textContent='Save your edits first.';return;}selectedSnippetID='';$('snippetName').value='';$('snippetText').value='';personal('snippetSelect',{id:''});};
for(const id of ['snippetName','snippetText'])$(id).oninput=()=>{snippetDirty=true;snippetRemoval=false;$('snippetDirty').textContent='Unsaved snippet';$('snippetPhrase').textContent='Say: insert snippet '+$('snippetName').value;};
$('snippetSave').onclick=()=>personal('snippetSave',{id:personalState.snippetID||'',name:$('snippetName').value,text:$('snippetText').value});
$('snippetUse').onclick=()=>{if(snippetDirty){$('snippetDirty').textContent='Save your edits first.';return;}personal('snippetUse',{id:personalState.snippetID});};
$('snippetRemove').onclick=()=>{if(!snippetRemoval){snippetRemoval=true;$('snippetRemove').textContent='Confirm removal';return;}snippetRemoval=false;personal('snippetRemove',{id:personalState.snippetID});};
function historyPreference(){personal('history',{enabled:$('historyEnabled').checked,days:+$('historyDays').value});}
$('historyEnabled').onchange=$('historyDays').onchange=historyPreference;$('historyClear').onclick=()=>personal('historyClear');
$('historyLoad').onclick=()=>personal('historyLoad',{id:personalState.historyID});$('historyOriginal').onclick=()=>{$('historyRaw').hidden=!$('historyRaw').hidden;};
$('personalPrevious').onclick=()=>personal('listPage',{offset:Math.max(0,+personalState.listPage-1)});$('personalNext').onclick=()=>personal('listPage',{offset:+personalState.listPage+1});
function renderPersonalization(s){
 const p=parse(s.personal)||{};personalState=p;const page=p.page||'dictate';
 for(const [id,key] of [['dictatePage','dictate'],['stylesPage','styles'],['snippetsPage','snippets'],['historyPage','history']])$(id).hidden=page!==key;
 for(const [id,key] of [['tabDictate','dictate'],['tabStyles','styles'],['tabSnippets','snippets'],['tabHistory','history']]){$(id).classList.toggle('selected',page===key);$(id).disabled=!!s.busy&&key!=='dictate'&&key!=='history';}
 $('tabHistory').textContent=p.historyEnabled==='yes'?'History · '+p.historyCount:'History · off';$('defaultTone').value=p.defaultTone||'Clean';$('defaultTone').disabled=!!s.busy;
 $('resolvedStyle').textContent=p.app?'Draft preview · '+p.appName+' · '+p.resolvedStyle:'App styles follow your shortcut destination';$('applyDraft').disabled=!!s.busy||!s.text;
 $('personalStatus').textContent=p.status||'';
 const apps=list(p.apps),appsKey=JSON.stringify(apps);if(appRevision!==appsKey){appRevision=appsKey;$('appSelect').replaceChildren();for(const app of apps.length?apps:[{appID:'',name:'Choose an app'}]){const option=document.createElement('option');option.value=app.appID;option.textContent=app.name;$('appSelect').append(option);}}
 $('appSelect').value=p.app||'';if(appSeen!==p.app){appSeen=p.app;appToneDirty=false;}if(p.status==='App style saved'&&$('appTone').value===p.appTone)appToneDirty=false;if(!appToneDirty)$('appTone').value=p.appTone||p.defaultTone||'Clean';
 $('appName').textContent=p.appName||'Choose an app';$('appRuleHint').textContent=p.appHasRule==='yes'?'Saved override · '+p.appTone:'Uses default · '+p.defaultTone;if(document.activeElement!==$('appSearch'))$('appSearch').value=p.appQuery||'';
 for(const id of ['appSelect','appSearch','appTone','chooseApp','appSave'])$(id).disabled=!!s.busy||(!p.app&&id==='appSave');$('appRemove').disabled=!!s.busy||p.appHasRule!=='yes';
 if(selectedSnippetID!==(p.snippetID||'')){selectedSnippetID=p.snippetID||'';snippetDirty=false;snippetRemoval=false;$('snippetName').value=p.snippetName||'';$('snippetText').value=p.snippetText||'';}
 if(p.status?.startsWith('Snippet saved')&&$('snippetName').value===p.snippetName&&$('snippetText').value===p.snippetText)snippetDirty=false;
 if(!snippetDirty){$('snippetName').value=p.snippetName||'';$('snippetText').value=p.snippetText||'';$('snippetDirty').textContent='';}$('snippetPhrase').textContent='Say: insert snippet '+($('snippetName').value||'your snippet name');if(!snippetRemoval)$('snippetRemove').textContent='Remove snippet';
 for(const id of ['snippetName','snippetText','snippetSave','snippetNew'])$(id).disabled=!!s.busy;for(const id of ['snippetUse','snippetRemove'])$(id).disabled=!!s.busy||!p.snippetID;
 const snippets=list(p.snippets),snipKey=JSON.stringify(snippets)+p.snippetID+String(s.busy);if(snippetListRevision!==snipKey){snippetListRevision=snipKey;$('snippetList').replaceChildren();for(const snippet of snippets){const b=document.createElement('button');b.textContent=snippet.name;b.classList.toggle('selected',snippet.id===p.snippetID);b.disabled=!!s.busy;b.onclick=()=>{if(snippetDirty){$('snippetDirty').textContent='Save your edits first.';return;}personal('snippetSelect',{id:snippet.id});};$('snippetList').append(b);}}
 $('historyEnabled').checked=p.historyEnabled==='yes';$('historyEnabled').disabled=!!s.busy&&p.historyEnabled!=='yes';$('historyDays').value=p.days||'7';$('historyDays').disabled=!!s.busy;$('historyClear').disabled=!!s.busy||!(+p.historyCount>0);$('historyHint').textContent=p.historyEnabled==='yes'?'Up to 200 completed dictations · expires after '+p.days+' days.':'Saving is off. Existing entries remain until they expire or you erase them.';
 const history=list(p.history),histKey=JSON.stringify(history)+p.historyID+String(s.busy);if(historyRevision!==histKey){historyRevision=histKey;$('historyList').replaceChildren();for(const entry of history){const b=document.createElement('button');b.classList.toggle('selected',entry.id===p.historyID);const preview=document.createElement('strong');preview.textContent=entry.preview;const label=document.createElement('small');label.textContent=entry.app+' · '+entry.when+' · '+entry.tone+' · '+entry.outcome;b.append(preview,label);b.disabled=!!s.busy;b.onclick=()=>personal('historySelect',{id:entry.id});$('historyList').append(b);}if(!history.length){const empty=document.createElement('p');empty.textContent='No saved dictation.';$('historyList').append(empty);}}
 if(selectedHistoryID!==p.historyID){selectedHistoryID=p.historyID;$('historyRaw').hidden=true;}$('historyText').textContent=p.historyText||'Select a saved dictation to recover its text.';$('historyRaw').textContent=p.historyRaw||'';for(const id of ['historyLoad','historyOriginal'])$(id).disabled=!!s.busy||!p.historyID;
 $('personalPagination').hidden=!['snippets','history'].includes(page)||!(+p.pages>1);$('personalPageLabel').textContent=(+p.listPage+1)+' / '+p.pages;$('personalPrevious').disabled=s.busy||!(+p.listPage>0);$('personalNext').disabled=s.busy||+p.listPage+1>=+p.pages;
}
nero.onState(renderPersonalization);

$('shortcutChoice').onchange=()=>emit('shortcut',{value:$('shortcutChoice').value});
$('captions').onchange=()=>emit('captions',{value:$('captions').value});
nero.onState(s=>{$('shortcutChoice').value=s.shortcutPreset||'custom';$('shortcutChoice').disabled=!!s.busy;$('captions').value=s.captionPlacement||'nook';$('captions').disabled=!!s.busy;});

$('speechBackend').onchange=()=>emit('speech',{backend:$('speechBackend').value});
$('qwenSpeaker').onchange=()=>emit('speech',{speaker:$('qwenSpeaker').value});
nero.onState(s=>{
 $('speechBackend').value=s.speechBackend||'apple';$('speechBackend').disabled=!!s.busy;
 $('qwenControls').hidden=s.speechBackend!=='qwen';$('qwenSpeaker').value=s.qwenSpeaker||'Ryan';$('qwenSpeaker').disabled=!!s.busy||!!s.qwenMode&&s.qwenMode!=='preset';$('qwenStudio').disabled=!!s.busy;
 $('prepareQwen').textContent=s.qwenReady?'Prepare Qwen':'Download Qwen · 3.08 GB';$('prepareQwen').disabled=!!s.busy||(!!s.speaking&&!s.reactionSpeaking);
 $('releaseQwen').disabled=!!s.busy||(!!s.speaking&&!s.reactionSpeaking);
 const unavailable=s.speechBackend==='qwen'&&!s.qwenReady;
 $('preview').disabled=!!s.busy||unavailable;$('read').disabled=!!s.busy||(!s.speaking&&(!s.text||unavailable));
});

$('stopDictation').onclick=()=>emit('command',{value:'record'});
$('microphoneChoice').onchange=()=>emit('microphone',{value:$('microphoneChoice').value});
nero.onState(s=>{
 let devices=[];try{devices=JSON.parse(s.microphones||'[]');}catch{}
 const key=JSON.stringify(devices);if($('microphoneChoice').dataset.devices!==key){$('microphoneChoice').dataset.devices=key;$('microphoneChoice').replaceChildren(new Option('System default',''));for(const d of devices)$('microphoneChoice').add(new Option(d.name,d.id));}
 $('microphoneChoice').value=s.microphone||'';$('microphoneChoice').disabled=!!s.busy;
 $('dictationHeading').textContent=s.recording?'Listening…':s.busy?'Finishing your words…':'Your voice, in any app.';
 $('text').hidden=!s.recording&&!s.text;$('draftActions').hidden=!!s.busy||!s.text;
 $('stopDictation').hidden=!s.recording;$('cancel').hidden=!s.busy&&!s.speaking;
 $('status').hidden=!s.busy&&!s.speaking&&!/(error|failed|unavailable|permission|allow|could not|download|needed|not ready)/i.test(s.status||'');
});
for(const id of ['tabDictate','tabStyles','tabSnippets','tabHistory','speechSettings','record']){const handler=$(id).onclick;$(id).onclick=()=>{$('dictationMenu').open=false;handler();};}
