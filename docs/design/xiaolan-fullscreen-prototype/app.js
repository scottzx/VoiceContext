'use strict';

const $ = (id) => document.getElementById(id);
const paths = {
  back:'<path d="m15 5-7 7 7 7"/>', close:'<path d="m6 6 12 12M18 6 6 18"/>',
  mic:'<rect x="9" y="3" width="6" height="12" rx="3"/><path d="M6 10v2a6 6 0 0 0 12 0v-2M12 18v3m-3 0h6"/>',
  grid:'<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/>',
  chat:'<path d="M21 11a8 8 0 0 1-8 8H8l-5 3 1-6a8 8 0 1 1 17-5Z"/>',
  calendar:'<rect x="4" y="5" width="16" height="16" rx="2"/><path d="M4 10h16M8 3v4m8-4v4M8 14h2m4 0h2"/>',
  check:'<rect x="3" y="3" width="18" height="18" rx="3"/><path d="m7 12 3 3 7-7"/>',
  record:'<path d="M4 9v6m4-10v14m4-16v18m4-16v14m4-10v6"/>',
  terminal:'<path d="m5 6 5 6-5 6m8 0h6"/>', globe:'<circle cx="12" cy="12" r="9"/><ellipse cx="12" cy="12" rx="4" ry="9"/><path d="M3 12h18"/>',
  book:'<path d="M12 5C8 3 5 3 3 4v15c3-1 6-1 9 1 3-2 6-2 9-1V4c-2-1-5-1-9 1v15"/>',
  cpu:'<rect x="5" y="5" width="14" height="14" rx="2"/><path d="M9 1v4m6-4v4M9 19v4m6-4v4M1 9h4m-4 6h4m14-6h4m-4 6h4"/>',
  person:'<circle cx="12" cy="8" r="4"/><path d="M4 21v-2a8 8 0 0 1 16 0v2"/>',
  link:'<path d="m9 15 6-6m-5-4 2-2a5 5 0 0 1 7 7l-2 2m-3 7-2 2a5 5 0 0 1-7-7l2-2"/>',
  settings:'<circle cx="12" cy="12" r="8"/><circle cx="12" cy="12" r="3"/><path d="M12 1v3m0 16v3M1 12h3m16 0h3"/>',
  plus:'<path d="M12 4v16M4 12h16"/>', arrow:'<path d="m9 5 7 7-7 7"/>',
};
const icon = (name) => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths[name] || paths.settings}</svg>`;
const tabs = [['chat','聊天','chat'],['meetings','会议','record'],['reminders','提醒','check'],['extensions','拓展','grid']];
const titles = { conversation:'语音任务 · 今天',tasks:'未完成待办',recording:'当前录音',text:'工作总结',image:'方案图片',chart:'本周完成事项',html:'项目简报' };
const points = [['周一',4],['周二',6],['周三',3],['周四',8],['周五',5]];
const state = {tab:'extensions',page:null,stack:[],voice:'off',phase:'idle',recording:'none',permission:true,message:'',ready:false,kind:'bar'};
let previousFocus = null;

function tile(name,symbol,action,extra='') { return `<button class="tile" data-action="${action}" aria-label="${name}${extra ? '，'+extra : ''}"><span class="tile-icon">${icon(symbol)}</span><span class="tile-name">${name}${extra ? `<small class="tile-state">${extra}</small>`:''}</span></button>`; }
function section(title,items) { return `<section class="extension-section"><h2>${title}</h2><div class="extension-grid">${items}</div></section>`; }
function row(title,meta,action,symbol='arrow') { return `<button class="flat-row" data-action="${action}"><span class="row-copy"><span class="row-title">${title}</span><span class="row-meta">${meta}</span></span>${icon(symbol)}</button>`; }
function voiceStatus() { return state.voice==='paused'?'已暂停':state.phase==='speaking'?'正在播报':'等待“小蓝同学”'; }
function chartMarkup() {
  const grid=[0,4,8].map(n=>`<line class="grid" x1="28" x2="332" y1="${184-n*18}" y2="${184-n*18}"/><text x="6" y="${188-n*18}">${n}</text>`).join('');
  const marks=state.kind==='line'?`<polyline class="line" points="${points.map(([,n],i)=>`${54+i*60},${184-n*18}`).join(' ')}"/>${points.map(([,n],i)=>`<circle class="point" cx="${54+i*60}" cy="${184-n*18}" r="3"/>`).join('')}`:points.map(([,n],i)=>`<rect class="bar" x="${38+i*60}" y="${184-n*18}" width="32" height="${n*18}" rx="2"/>`).join('');
  const labels=points.map(([day,n],i)=>`<text class="value" x="${54+i*60}" y="${174-n*18}" text-anchor="middle">${n}</text><text x="${54+i*60}" y="208" text-anchor="middle">${day}</text>`).join('');
  return `<svg class="chart" viewBox="0 0 344 222" role="img" aria-label="演示数据：周一4项、周二6项、周三3项、周四8项、周五5项。单位：项。">${grid}${marks}${labels}</svg>`;
}

function content() {
  if (!state.page) {
    if(state.tab==='extensions') return section('自定义功能',tile('项目看板','grid','html')+tile('添加','plus','placeholder'))+section('助手能力',tile('Skills','book','placeholder')+tile('模型与服务','cpu','placeholder')+tile('助手设定','person','placeholder')+tile('Memory','book','placeholder'))+section('工具连接',tile('MCP','link','placeholder')+tile('硬件设备','link','placeholder'))+section('工具',tile('终端','terminal','placeholder')+tile('浏览器','globe','html')+tile('语音模式','mic','voice',state.voice==='off'?'':state.voice==='paused'?'已暂停':'已开启'))+section('我的与设置',tile('设置','settings','placeholder'));
    if(state.tab==='chat') return `<p class="eyebrow">现有聊天列表 · 演示数据</p>${row('语音任务 · 今天','今天 · 文字与附件留在原有聊天中','conversation','chat')}${row('项目资料整理','昨天 · 方案与下一步','conversation','chat')}<p class="inline-note">语音模式从拓展开启，不新增小蓝首页或聊天页入口。</p>`;
    if(state.tab==='reminders') return `<p class="eyebrow">2026年10月17日 星期六 · 演示日程</p><h2 class="content-title">今天的日程</h2>${[['09:30','项目方案讨论'],['14:00','整理本周资料'],['16:30','一周工作复盘']].map(([time,title])=>`<div class="flat-row"><span class="time-label">${time}</span><span class="row-copy"><span class="row-title">${title}</span><span class="row-meta">Yima日历 · 演示安排</span></span></div>`).join('')}${row('查看未完成待办','进入已有待办列表','tasks','check')}`;
    return `<p class="eyebrow">录音列表 · 演示数据</p>${row(state.recording==='none'?'方案讨论记录':'当前录音',state.recording==='paused'?'录音已暂停，尚未结束':state.recording==='active'?'正在录音 · 12:36':'今天 · 12分钟','recording','record')}<div class="record-controls"><button class="record-button" data-action="start-recording" aria-label="开始录音"></button><span class="metadata">开始录音</span></div>`;
  }
  switch(state.page) {
    case 'conversation': return `<p class="eyebrow">已有聊天会话 · 演示数据</p><h2 class="content-title">已整理的内容</h2><p class="body-copy">这份总结、方案图和报告保存在同一会话里，可以继续查看。</p>${row('工作总结','文字 / Markdown','text')}${row('方案图片','本地演示图片','image')}${row('本周完成事项','图表 · 演示数据','chart')}${row('项目简报','HTML 文档','html')}`;
    case 'tasks': return `<p class="eyebrow">Yima待办 · 演示数据</p><h2 class="content-title">未完成待办</h2>${['整理讨论提纲','补充方案依据','确定复盘时间'].map(title=>`<div class="flat-row"><span class="task-circle" aria-hidden="true"></span><span class="row-copy"><span class="row-title">${title}</span><span class="row-meta">未安排 · Yima待办</span></span></div>`).join('')}`;
    case 'recording': return `<p class="eyebrow">现有录音详情 · 演示</p><h2 class="content-title">${state.recording==='none'?'录音已结束':'当前录音'}</h2><p class="timer">12:36</p><p class="body-copy muted">${state.recording==='paused'?'录音已暂停，仍需结束后才能开启语音模式。':state.recording==='active'?'录音进行中。开启独立语音前，请先结束录音。':'已保留录音。语音模式不会自动开启。'}</p>${state.recording!=='none'?`<div class="record-controls"><button class="secondary-button" data-action="pause-recording">${state.recording==='paused'?'继续录音':'暂停录音'}</button><button class="secondary-button destructive" data-action="end-recording">结束录音</button></div>`:''}`;
    case 'text': return `<p class="eyebrow">App 文档预览 · 演示内容</p><h2 class="content-title">把下一步说清楚。</h2><p class="body-copy">先确认已有依据，再决定下一步要完成什么。当前展示是会话中的文字产物。</p><h3 class="section-title">三项结论</h3><ol class="document-list"><li>整理已有资料，区分事实与待确认问题。</li><li>用图表和图片辅助讨论，保留数据来源。</li><li>未知的负责人和时间保持待确认。</li></ol>`;
    case 'image': return `<p class="eyebrow">App 图片预览 · 演示素材</p><button class="image-button" data-action="zoom" aria-label="放大项目讨论白板"><img src="assets/whiteboard.svg" alt="项目讨论白板：资料整理、方案讨论、下一步行动"></button><p class="metadata">1 / 1 · 点按查看完整图片</p>`;
    case 'chart': return `<p class="eyebrow">会话图表预览 · 演示数据</p><h2 class="content-title">本周完成了 26 项。</h2><p class="body-copy muted">周四完成最多，为 8 项。</p><div class="chart-controls" aria-label="图表类型"><button data-kind="bar" aria-pressed="${state.kind==='bar'}">柱状图</button><button data-kind="line" aria-pressed="${state.kind==='line'}">折线图</button></div><p class="metadata">每天完成事项 · 单位：项</p>${chartMarkup()}<details><summary>查看数据与来源</summary><table><caption class="metadata">来源：虚构演示数据</caption><thead><tr><th>日期</th><th>完成事项（项）</th></tr></thead><tbody>${points.map(([day,n])=>`<tr><th scope="row">${day}</th><td>${n}</td></tr>`).join('')}</tbody></table></details>`;
    case 'html': return `<p class="eyebrow">App 内网页预览 · 本地演示内容</p><h2 class="content-title">项目简报</h2><iframe id="html-report" class="html-frame" title="项目简报 HTML 演示" sandbox="" referrerpolicy="no-referrer"></iframe>`;
    default:return '';
  }
}

function mountHTML() {
  if(!$('html-report')) return;
  const dark=$('phone').dataset.theme==='dark';
  $('html-report').srcdoc=`<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><style>body{font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;margin:0;padding:24px 20px;line-height:1.8;background:${dark?'#1c1c1e':'#fff'};color:${dark?'#f2f2f7':'#1c1c1e'};font-size:${$('phone').classList.contains('large-type')?21:16}px}h1{font-size:24px;line-height:1.4}small{color:${dark?'#98989d':'#636366'}}summary{min-height:44px;padding:12px 0;cursor:pointer}details{border-top:1px solid #98989d;margin-top:24px}</style><small>项目简报 / HTML 演示</small><h1>从资料，到行动。</h1><p>页面由 App 内网页预览承接，没有独立小蓝外壳。</p><details><summary>展开下一步</summary><ol><li>确认资料范围</li><li>补充缺少的依据</li><li>安排一次复盘</li></ol></details><p><small>虚构示例，没有真实业务写入。</small></p></html>`;
}

function render(keepScroll=false) {
  const scroll=keepScroll?$('screen').scrollTop:0;
  $('page-title').textContent=state.page?titles[state.page]:tabs.find(t=>t[0]===state.tab)[1];
  $('back').hidden=!state.page;
  $('page-content').innerHTML=content();
  $('notice').textContent=state.message; $('notice').hidden=!state.message;
  $('ready-notice').hidden=!state.ready;
  $('session-control').hidden=state.voice==='off'&&state.recording==='none';
  $('session-control').innerHTML=icon(state.recording!=='none'?'record':'mic');
  $('session-control').setAttribute('aria-label',state.recording!=='none'?`当前录音，${state.recording==='paused'?'已暂停':'录音中'}`:`语音模式：${voiceStatus()}，管理`);
  $('tabbar').hidden=!!state.page;
  $('tabbar').innerHTML=tabs.map(([id,title,symbol])=>`<button data-tab="${id}" ${state.tab===id?'aria-current="page"':''}>${icon(symbol)}<span>${title}</span></button>`).join('');
  mountHTML(); $('screen').scrollTop=scroll;
}
function feedback(text) { $('review-feedback').textContent=text; }
function notify(text) {state.message=text;render(true);feedback(text);}
function selectTab(tab) {state.tab=tab;state.page=null;state.stack=[];state.message='';render();}
function navigate(page,tab='chat') {
  if(state.tab!==tab) {state.tab=tab;state.page=null;state.stack=[];}
  if(!state.page&&['text','image','chart','html'].includes(page)) {state.stack.push(null);state.page='conversation';}
  state.stack.push(state.page);state.page=page;state.message='';render();$('screen').focus({preventScroll:true});
}
function back() {if(!$('sheet-layer').hidden){closeSheet();return;}if(!state.page){notify('当前已在根页面，没有上一页。');return;}state.page=state.stack.pop()||null;state.message='';render();$('screen').focus({preventScroll:true});}
function openSheet(title,html) {previousFocus=document.activeElement;$('sheet-title').textContent=title;$('sheet-content').innerHTML=html;$('sheet-layer').hidden=false;$('app-shell').inert=true;($('sheet-content').querySelector('input,button')||$('sheet-close')).focus();}
function closeSheet() {$('sheet-layer').hidden=true;$('app-shell').inert=false;if(previousFocus?.isConnected)previousFocus.focus({preventScroll:true});}
function alertSheet(title,body,action,label) {openSheet(title,`<p class="body-copy">${body}</p><div class="sheet-actions"><button class="primary-button" data-action="${action}">${label}</button><button class="secondary-button" data-action="cancel">取消</button></div>`);}
function activateVoice() {
  if(state.recording!=='none'){alertSheet('请先关闭录音','当前有一条未结束的录音。请先结束录音，再开启语音模式。','go-recording','前往当前录音');return;}
  if(!state.permission){alertSheet('麦克风未授权','语音模式尚未开启。正式版本可前往系统设置授权；原型不申请真实权限。','cancel','知道了');return;}
  state.voice='active';state.phase='idle';notify('语音模式已开启。说“小蓝同学”后交代任务。');
}
function voiceMenu() {
  if(state.voice==='off'){activateVoice();return;}
  openSheet('语音模式',`<p class="metadata">${voiceStatus()} · 演示状态</p>${state.phase==='speaking'?'<button class="flat-row" data-action="stop-speech">停止播报</button>':''}${state.voice==='active'?'<button class="flat-row" data-action="say">点击说话（模拟）</button><button class="flat-row" data-action="pause-voice">暂停语音</button>':'<button class="flat-row" data-action="resume-voice">继续语音</button>'}<button class="flat-row" data-action="close-voice">关闭语音模式</button>`);
}
function startRecording() {
  if(state.voice!=='off'){alertSheet('请先关闭语音模式','当前正在使用语音模式。请先关闭语音模式，再开始录音。','manage-voice','管理语音模式');return;}
  if(state.recording==='none')state.recording='active';navigate('recording','meetings');
}
function runCommand(raw) {
  const command=raw.trim().replace(/^小蓝同学[，,、\s]*/,'');if(!command)return;
  if(!$('sheet-layer').hidden){feedback('请先处理或关闭当前面板，再继续模拟语音。');return;}
  if(state.voice!=='active'){notify('请先从「拓展 → 语音模式」开启或继续语音。');return;}
  if(state.phase==='speaking'){feedback('请先通过页头语音菜单停止播报，再模拟下一句语音。');return;}
  if(/关闭语音|退出语音/.test(command)){state.voice='off';state.phase='idle';notify('语音模式已关闭，当前页面保留。');return;}
  if(/返回|上一页/.test(command)){back();return;}
  if(/开始录音/.test(command)){startRecording();return;}
  if(/日程|安排/.test(command)){selectTab('reminders');}
  else if(/待办/.test(command)){navigate('tasks','reminders');}
  else if(/记录|录音/.test(command)){selectTab('meetings');}
  else if(/放大.*图/.test(command)){if(state.page!=='image')navigate('image');zoom();}
  else if(/图片/.test(command)){navigate('image');}
  else if(/HTML|报告|看板/i.test(command)){navigate('html',/看板/.test(command)?'extensions':'chat');}
  else if(/图|数据/.test(command)){state.kind=/折线/.test(command)?'line':'bar';if(state.page!=='chart')navigate('chart');else render(true);}
  else if(/文字|总结/.test(command)){navigate('text');}
  else {notify(`未找到“${command}”对应的页面，当前内容保留。`);return;}
  feedback(`模拟指令：${command}。已使用 App 导航，不创建小蓝专用页面。`);
}
function zoom(){openSheet('图片放大查看','<p class="metadata">演示完整图片，正式版本复用原有图片缩放。</p><img class="expanded-image" src="assets/whiteboard.svg" alt="完整项目讨论白板">');}
function say(){openSheet('模拟说一句','<p class="metadata">输入文字代替语音；不启用真实麦克风。</p><form id="say-form"><input id="say-input" aria-label="模拟语音内容" placeholder="打开今天的日程" autocomplete="off"><button class="primary-button" type="submit">模拟说完</button></form>');$('say-form').addEventListener('submit',event=>{event.preventDefault();const value=$('say-input').value;if(!value.trim())return;closeSheet();runCommand(value);});}
function scenario(kind){
  if(!$('sheet-layer').hidden)closeSheet();
  if(kind==='recording'||kind==='paused-recording'){state.voice='off';state.phase='idle';state.recording=kind==='recording'?'active':'paused';selectTab('extensions');feedback('模拟已有未结束录音。点击拓展中的语音模式检查阻止提示。');return;}
  if(kind==='normal'){state.permission=true;state.recording='none';state.voice='off';state.phase='idle';selectTab('extensions');return;}
  if(kind==='permission'){state.permission=false;state.voice='off';state.recording='none';selectTab('extensions');feedback('点击语音模式查看权限说明。');return;}
  if(kind==='background'){if(state.voice!=='off')state.voice='paused';state.phase='idle';notify('模拟进入后台：监听和播报暂停，回到前台后需主动继续。');return;}
  if(kind==='late'){if(state.voice==='off'){feedback('语音模式已关闭，迟到结果只保留在原会话，不切换页面。');return;}state.ready=true;render(true);feedback('旧任务已完成，当前 App 页保持不变。');return;}
  if(kind==='speaking'){if(state.voice!=='active'){feedback('请先在拓展开启语音模式。');return;}state.phase='speaking';notify('模拟播报中。可通过页头语音菜单停止播报。');}
}
function reset(){if(!$('sheet-layer').hidden)closeSheet();Object.assign(state,{tab:'extensions',page:null,stack:[],voice:'off',phase:'idle',recording:'none',permission:true,message:'',ready:false,kind:'bar'});$('command').value='';render();feedback('演示已重置：拓展首页，语音和录音均关闭。');}

$('back').innerHTML=icon('back');$('sheet-close').innerHTML=icon('close');
$('back').addEventListener('click',back);$('sheet-close').addEventListener('click',closeSheet);
$('sheet-layer').addEventListener('click',event=>{if(event.target===$('sheet-layer'))closeSheet();});
$('session-control').addEventListener('click',()=>state.recording!=='none'?navigate('recording','meetings'):voiceMenu());
$('command-form').addEventListener('submit',event=>{event.preventDefault();runCommand($('command').value);});
document.addEventListener('click',event=>{
  const tab=event.target.closest('[data-tab]');if(tab){selectTab(tab.dataset.tab);return;}
  const cmd=event.target.closest('[data-command]');if(cmd){$('command').value=cmd.dataset.command;runCommand(cmd.dataset.command);return;}
  const condition=event.target.closest('[data-scenario]');if(condition){scenario(condition.dataset.scenario);return;}
  const kind=event.target.closest('[data-kind]');if(kind){state.kind=kind.dataset.kind;render(true);return;}
  const action=event.target.closest('[data-action]')?.dataset.action;
  if(action==='voice')voiceMenu();
  if(action==='cancel')closeSheet();
  if(action==='go-recording'){closeSheet();navigate('recording','meetings');}
  if(action==='start-recording')startRecording();
  if(action==='manage-voice'){closeSheet();voiceMenu();}
  if(action==='pause-recording'){state.recording=state.recording==='paused'?'active':'paused';render(true);}
  if(action==='end-recording')alertSheet('结束录音？','将结束并保留这条录音。语音模式不会自动开启。','confirm-end','结束并保存');
  if(action==='confirm-end'){closeSheet();state.recording='none';notify('录音已结束并保留。请回拓展主动开启语音模式。');}
  if(action==='pause-voice'){closeSheet();state.voice='paused';notify('语音已暂停，可从原生菜单继续或关闭。');}
  if(action==='resume-voice'){closeSheet();activateVoice();}
  if(action==='close-voice'){closeSheet();state.voice='off';state.phase='idle';state.ready=false;notify('语音模式已关闭，当前页面保留。');}
  if(action==='stop-speech'){closeSheet();state.phase='idle';notify('播报已停止。');}
  if(action==='say'){closeSheet();state.phase='idle';say();}
  if(action==='view-ready'){state.ready=false;navigate('text');}
  if(action==='zoom')zoom();
  if(['conversation','tasks','recording','text','image','chart','html'].includes(action)){navigate(action,action==='tasks'?'reminders':action==='recording'?'meetings':action==='html'&&state.tab==='extensions'?'extensions':'chat');}
  if(action==='placeholder')feedback('此既有工具入口不在本轮原型交互范围。');
});
document.addEventListener('keydown',event=>{
  if($('sheet-layer').hidden)return;
  if(event.key==='Escape'){event.preventDefault();closeSheet();}
  if(event.key==='Tab'){const elements=[...$('sheet-layer').querySelectorAll('button,input,a[href]')].filter(e=>!e.disabled&&e.getClientRects().length);const first=elements[0],last=elements.at(-1);if(event.shiftKey&&document.activeElement===first){event.preventDefault();last.focus();}else if(!event.shiftKey&&document.activeElement===last){event.preventDefault();first.focus();}}
});
$('theme').addEventListener('click',()=>{const dark=$('phone').dataset.theme!=='dark';$('phone').dataset.theme=dark?'dark':'light';$('theme').textContent=dark?'切换浅色':'切换深色';mountHTML();});
$('text-size').addEventListener('click',()=>{const large=$('phone').classList.toggle('large-type');$('text-size').textContent=large?'恢复字号':'放大字号';mountHTML();});
$('reset').addEventListener('click',reset);
render();
