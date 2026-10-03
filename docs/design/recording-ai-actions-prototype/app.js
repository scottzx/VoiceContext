'use strict';

const $ = (selector) => document.querySelector(selector);
const escapeText = (value) => String(value ?? '').replace(/[&<>"']/g, (c) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const lists = {
  'icloud-work': {account:'iCloud', name:'工作', writable:true},
  'company-work': {account:'公司', name:'工作', writable:true},
  'icloud-personal': {account:'iCloud', name:'个人', writable:true},
  'shared-readonly': {account:'公司', name:'共享资料', writable:false}
};
const initialActions = () => [
  {id:'a1', title:'整理访谈提纲', owner:'李明（原文明确提及）', due:'', time:'', alarm:'', list:'icloud-work', notes:'负责人信息仅来自原文，不表示向他人分配。', selected:false},
  {id:'a2', title:'核对预算口径', owner:'待确认', due:'', time:'', alarm:'', list:'icloud-work', notes:'原文“下周”：依据录音发生时间 2026-10-02、Asia/Shanghai；具体日期待确认。', selected:false},
  {id:'a3', title:'约一次产品评审', owner:'待确认', due:'', time:'', alarm:'', list:'icloud-work', notes:'与已有建议可能相似，请核对原文；不能按同标题自动合并。', selected:false}
];
let state = {scenario:'normal', route:'meetings', history:[], contentTab:'transcript', tab:'meetings', actions:initialActions(), request:null, running:false, result:false, receipt:[], retained:false, revoked:false, longRetention:false, textTree:false};
let opener = null;
const actionButton = (label, action, cls='', attributes='') => `<button type="button" class="${cls}" data-action="${action}" ${attributes}>${label}</button>`;
const row = (title, subtitle, action, cls='') => `<button class="row ${cls}" data-action="${action}"><span>${title}<span class="metadata">${subtitle}</span></span><span class="chevron" aria-hidden="true">›</span></button>`;
const announce = (text) => {$('#announcement').textContent = text; $('#review-status').textContent = text;};
const isSourceGone = () => state.revoked || ['sourceDeleted','cleanupFailed'].includes(state.scenario);
const currentRevision = () => state.scenario === 'sourceUpdated' ? 13 : 12;
const noText = () => ['silence','emptyASR','noText'].includes(state.scenario);
const isPartial = () => state.scenario === 'partial';
const sourceInfo = () => {
  if (state.scenario === 'unknown') return '完整性信息未记录 · 不能自动标为完整';
  if (state.scenario === 'processing') return '处理中 · 已有 00:00–08:20 的文字；后续范围尚未完成';
  if (isPartial()) return '部分可用 · 08:20–09:00 音频缺失；处理已结束';
  if (state.scenario === 'silence') return '正常静音 · 没有需要转写的语音';
  if (state.scenario === 'emptyASR') return '检测到声音，但没有识别出文字；可重试或手工补充';
  if (state.scenario === 'noText') return '文字尚未就绪 · 仍在读取 / 处理';
  return '已校对 · 3 段人工修改；当前文稿覆盖完整';
};
const summaryClass = () => state.scenario==='unknown' ? 'completenessUnknown' : state.scenario==='processing' ? 'preliminary' : isPartial() ? 'withMissingContent' : 'formal';
const summaryTitle = (kind) => ({completenessUnknown:'完整性未确认的整理',preliminary:'临时整理',withMissingContent:'含缺失的纪要',formal:'会议纪要'}[kind]);
const resultClass = () => state.artifact?.summaryClass || summaryClass();
const resultName = () => summaryTitle(resultClass());
const resultRevision = () => state.artifact?.revision || 12;
const sourceStatusClass = () => ['normal','sourceUpdated','audioExpired','offline'].includes(state.scenario) ? 'metadata' : 'status';
const times = (item) => `<div class="times"><span>到期：${escapeText(item.due || '无日期')}${item.time ? ` ${escapeText(item.time)}` : ''}</span><span>提醒：${escapeText(item.alarm ? item.alarm.replace('T',' ') : '未设置')}</span></div>`;
const listText = (id) => `${lists[id].account} · ${lists[id].name}`;
const audio = () => state.scenario === 'audioExpired' || isSourceGone()
  ? '<section class="player"><h2>音频不可用</h2><p class="metadata">音频已过期或来源已删除。已有文字仍可阅读；不能重新转写这份音频。</p></section>'
  : `<section class="player" aria-label="音频播放器示意"><div class="player-time metadata"><span>00:00</span><span>18:42</span></div><div class="track"></div><div class="player-controls">${actionButton('后退 15 秒','play')}${actionButton('播放','play')}${actionButton('前进 15 秒','play')}${actionButton('1×','play')}</div><p class="compact">网页没有音频，播放器只表示位置与顺序。</p></section>`;

function navigate(route, replace=false) {
  if (!replace && route !== state.route) state.history.push(state.route);
  state.route = route;
  render();
  $('#screen').focus();
  window.scrollTo({top:0});
}
function showSheet(title, content) {
  opener = document.activeElement;
  $('#sheet').dataset.theme = $('#phone').dataset.theme;
  $('#sheet').classList.toggle('large', $('#phone').classList.contains('large'));
  $('#sheet-body').innerHTML = `<div class="sheet-header"><h2 id="sheet-title" tabindex="-1">${title}</h2>${actionButton('取消','close')}</div>${content}`;
  $('#sheet').showModal();
  $('#sheet-title').focus();
}
function closeSheet() {
  $('#sheet').close();
  if (opener?.isConnected) opener.focus();
}
function render() {
  const titles = {meetings:'会议', detail:'会议详情', draft:'新聊天', running:'智能体产物', results:'智能体产物', minutes:'产物信息', history:'历史结果', actions:'行动建议', confirm:'核对所选事项', receipt:'创建结果', source:'会议详情', candidate:'比较识别候选', reminder:'编辑待办', tasks:'待办事项', tasksAll:'全部事项', extensions:'拓展', retention:'音频保留', deleted:'删除结果', tree:'思维导图 · P1'};
  if (['draft'].includes(state.route)) state.tab='chat';
  else if (['reminder','tasks','tasksAll'].includes(state.route)) state.tab='tasks';
  else if (state.route==='extensions') state.tab='extensions';
  else if (['meetings','detail','source','candidate','retention','deleted'].includes(state.route)) state.tab='meetings';
  const sheetRoot=['results','running'].includes(state.route);
  const left=state.route==='meetings' ? actionButton('文件夹','folders') : sheetRoot ? actionButton('完成','detail') : actionButton(state.route==='draft' ? '聊天' : '返回','back');
  const right=state.route==='detail' || state.route==='source' ? actionButton('•••','more','','aria-label="更多操作"') : state.route==='draft' ? actionButton('•••','chatMenu','','aria-label="会话菜单"') : state.route==='reminder' ? actionButton('保存','mockSave') : state.route==='meetings' ? actionButton('•••','listMenu','','aria-label="列表菜单"') : '<span class="nav-spacer"></span>';
  $('#navigation').innerHTML=`${left}<strong>${titles[state.route]}</strong>${right}`;
  const screens={meetings:meetingsScreen, detail:detailScreen, draft:draftScreen, running:runningScreen, results:resultsScreen, minutes:minutesScreen, history:historyScreen, actions:actionsScreen, confirm:confirmScreen, receipt:receiptScreen, source:sourceScreen, candidate:candidateScreen, reminder:reminderScreen, tasks:tasksScreen, tasksAll:tasksAllScreen, extensions:extensionsScreen, retention:retentionScreen, deleted:deletedScreen, tree:treeScreen};
  $('#screen').innerHTML=screens[state.route]();
  $('#dock').innerHTML=['detail','source'].includes(state.route) && !isSourceGone() ? audio() : state.route==='meetings' ? '<div class="recording-dock">'+actionButton('●','record','record-control','aria-label="开始录音（示意）"')+'</div>' : '';
  $('#app-tabs').innerHTML=[['chat','聊天'],['meetings','会议'],['tasks','待办事项'],['extensions','拓展']].map(([id,title])=>actionButton(title,'tab:'+id,'',state.tab===id ? 'aria-current="page"' : '')).join('');
  // The existing conversation hides the root Tab bar; return through its back control.
  $('#app-tabs').hidden=['draft','results','running','minutes','history','actions','confirm','receipt','tree','reminder'].includes(state.route);
  const existing={meetings:'沿用会议列表、日期条和底部录音按钮；删除仍从录音行菜单发起。',detail:'沿用标题、四内容 Tab、更多菜单及底部播放器；仅在文稿进度区补完整性。',draft:'沿用现有聊天模型 / 工具与预填输入；只新增固定来源摘要，原发送按钮执行。',results:'沿用智能体产物 Sheet、文件列表与 QuickLook；补版本 / 完整性索引和处理记录。',running:'新增处理记录子页，入口在原产物 Sheet；实际执行继续在已有聊天。',minutes:'复用文件预览；新增最小来源 / 行动信息子页，未设计独立富文本阅读器。',tasks:'沿用月 / 周日历、待办 / 日程分组与全部入口；不另造待办管理首页。',reminder:'沿用原 ReminderEditor 字段与权限保护；尾部只补来源关联。',source:'沿用录音详情逐字稿定位及底部播放器；旧版本需只读快照承接。',extensions:'沿用主目录最新拓展分组与统一设置入口；不新增整理设置中心。'};
  $('#screen-basis').textContent=existing[state.route] || '本轮新增的最小子流程；返回现有产物、录音或系统待办入口。';
}
function detailTabs() {
  return `<nav class="content-tabs" aria-label="详情内容">${[['transcript','逐字稿'],['speakers','参会人与声纹'],['info','详细信息'],['memo','备忘录']].map(([id,title])=>actionButton(title,'content:'+id,'',state.contentTab===id ? 'aria-current="page"' : '')).join('')}</nav>`;
}
function meetingsScreen() {
  return `<h1>会议</h1><div class="calendar-strip" aria-label="日期选择示意">${['1 四','2 五','3 六','4 日','5 一'].map((d,i)=>actionButton(d,'date','',i===1?'aria-current="date"':'')).join('')}</div><p class="metadata">2026年10月2日</p><div class="recording-list-row">${row('产品访谈复盘','18:42 · 会议 · '+(isSourceGone() ? '来源已删除' : '已就绪'),'detail')}${actionButton('•••','recordMenu','','aria-label="管理产品访谈复盘"')}</div><p class="metadata" style="margin-top:16px"></p>`;
}
function moreSheet() {
  showSheet('更多操作', `<div class="list">${row('交给智能体','选择范围与模板','organize')}${row('智能体产物','文件与处理记录','results')}${row('增录音频…','','existing')}${row('编辑录音信息…','','existing')}${row('导出与分享…','','existing')}${row('复制全文逐字稿','','existing')}${row('重新转写 / 分析','先检查可处理音频','retranscribe')}${row('重新识别说话人…','','existing')}</div>`);
}
function tasksScreen() {
  const saved=state.receipt.filter(item=>['saved','differences'].includes(item.status) && item.due==='2026-10-03');
  return `<h1>待办事项</h1><div class="calendar-strip" aria-label="待办日期示意">${['1 四','2 五','3 六','4 日','5 一'].map((d,i)=>actionButton(d,'date','',i===2?'aria-current="date"':'')).join('')}</div><div class="section-actions"><h2>今日事项</h2>${actionButton('全部 ›','allTasks')}${actionButton('+','existing','','aria-label="新增待办事项"')}</div><section><h2>待办 · ${saved.length}</h2>${saved.length ? saved.map(item=>row(escapeText(item.title),escapeText(listText(item.list))+' · 未完成','reminder:'+item.id)).join('') : '<p class="metadata">这天没有待办；未安排日期的事项可在「全部」中查看。</p>'}</section><section><h2>日程</h2><p class="metadata">这天没有日程。</p></section>`;
}
function tasksAllScreen() {
  const saved=state.receipt.filter(item=>['saved','differences'].includes(item.status));
  return `<p class="metadata"></p>${['逾期','今天','未来','未安排'].map((title,index)=>'<section><h2>'+title+'</h2>'+saved.filter(item=>index===3 ? !item.due : index===1 ? item.due==='2026-10-03' : index===2 ? item.due>'2026-10-03' : item.due && item.due<'2026-10-03').map(item=>row(escapeText(item.title),escapeText(listText(item.list)),'reminder:'+item.id)).join('')+'</section>').join('')}`;
}
function extensionsScreen() {
  return `<section><h2>助手能力</h2>${row('Skills','','settings')}${row('模型与服务','','settings')}${row('助手设定','','settings')}${row('Memory','','settings')}</section><section><h2>工具连接</h2>${row('MCP Integrations','','settings')}${row('Hardware Devices','','settings')}</section><section><h2>工具</h2>${row('终端','','settings')}${row('浏览器','','settings')}</section><section><h2>我的与设置</h2>${row('设置','统一设置入口','settings')}</section>`;
}
function detailScreen() {
  if (isSourceGone()) return deletedScreen();
  const transcript=`<section><p class="${sourceStatusClass()}">${sourceInfo()}</p><p class="metadata">版本 ${currentRevision()} · ${state.scenario==='sourceUpdated' ? '旧结果仍使用版本 12' : '3 段人工校对已保存'}</p>${noText() ? '<p class="metadata">当前没有可整理的文字。</p>' : '<div class="segment"><span class="metadata">说话人 1 · 已校对</span><p>我们先整理访谈提纲，再核对预算口径。预算还没有确定，下周再讨论。</p>'+actionButton('00:42 · 选句 / 定位','sentence','text-button')+'</div><div class="segment"><span class="metadata">说话人 2</span><p>已决定本轮先保护录音和校对文字。产品评审时间还没有确定。</p>'+actionButton('16:30 · 选句 / 定位','sentence','text-button')+'</div>'}</section>`;
  const content={transcript, speakers:'<section><h2>参会人与声纹</h2><p class="metadata"></p>'+row('说话人 1','姓名待确认','existing')+row('说话人 2','姓名待确认','existing')+'</section>',info:'<section><h2>详细信息</h2><p class="metadata"></p>'+row('音频保留',state.longRetention ? '已明确长期保留' : '默认 7 天；到期后无法重新转写','retention')+row('相关文件','录音关联资料','existing')+'</section>',memo:'<section><h2>备忘录</h2><label class="field"><span>复听想法与要点</span><textarea placeholder="记录复听想法、转录要点或关键决策…"></textarea></label></section>'};
  return `<h1>产品访谈复盘</h1><p class="metadata">2026年10月2日 · 18:42 · 中文 · 会议</p>${detailTabs()}${content[state.contentTab]}`;
}
function organizeSheet() {
  if ($('#sheet').open) closeSheet();
  const blocked = noText() || state.scenario==='noModel' || isSourceGone();
  showSheet('整理录音', `<p class="${sourceStatusClass()}">${sourceInfo()}</p><p class="metadata">来源版本 ${currentRevision()} · 本次仅处理这条录音</p><form id="organize-form"><label class="field"><span>结果类型</span><select name="kind"><option value="minutes">${summaryTitle(summaryClass())}</option><option value="actions">行动建议</option><option value="tree">思维导图（P1 独立提案）</option></select></label><label class="field"><span>模板</span><select name="template"><option>默认会议整理</option><option>我的模板（示例，保留用户编辑）</option></select></label><label class="field"><span>输入范围</span><select name="scope" id="scope"><option value="all">整份当前文稿</option><option value="range">指定两段来源文字（00:42 / 16:30，示例）</option></select></label><p class="metadata" style="margin-top:12px">模型服务：${state.scenario==='noModel' ? '未配置可用模型' : '用户已配置的云模型服务（示例）'}</p><p class="metadata">发送所选文字、必要时间 / 说话人 / 完整性元数据和模板；不包含其他录音、原始音频或附件。云模型会处理这些文字。</p><p class="compact">关联与处理记录仅保存在本机；不默认同步 iCloud。</p>${blocked ? '<p class="status">'+(state.scenario==='noModel' ? '请先配置可用模型。' : '没有可用的来源文字，不能准备整理请求。')+'</p>' : ''}${state.scenario==='noModel' ? actionButton('打开模型设置','settings','system text-button') : ''}${actionButton('准备聊天草稿','prepare','primary',blocked ? 'disabled' : '')}</form>`);
}
function draftScreen() {
  const request=state.request || {revision:12,scope:'整份文稿',template:'默认会议整理',kind:'minutes'};
  if (state.running) return `<div class="chat-thread"><p class="metadata">用户已发送</p><p>请依据固定版本 ${request.revision} 整理重点和下一步。</p><section><p class="status">正在处理 · 新结果尚未校验与提交</p><p class="metadata">运行继续在原聊天，输入范围保持 ${request.scope}。没有推测完成百分比。</p></section></div><div class="chat-composer">${actionButton('停止','stop','secondary')}${actionButton('查看智能体产物与处理记录','results','text-button')}${actionButton('返回录音','detail','text-button')}</div>`;
  return `<div class="chat-thread" aria-label="现有会话消息区域"><p class="metadata">新对话 · 尚未发送</p><p class="metadata"></p></div><div class="chat-composer"><div class="composer-tools">${actionButton('已配置模型 ▾','model')}${actionButton('工具','chatMenu')}</div><details open><summary>产品访谈复盘 · 固定版本 ${request.revision}</summary><p class="metadata">范围：${request.scope}<br>模板：${request.template}<br>发送所选文字、必要来源元数据与模板；不含其他录音、音频或附件。</p><p class="${request.summaryClass==='formal' ? 'metadata' : 'status'}">${request.sourceInfo || sourceInfo()}</p>${currentRevision()!==request.revision ? '<p class="status">当前文稿已更新为 13；本草稿仍使用版本 12。</p>'+actionButton('改用新版重新准备','organize','text-button') : ''}</details><label class="field"><span>整理指令</span><textarea id="chat-prompt">请基于这份固定文稿整理重点和下一步。区分已决定事项、讨论建议与未解决问题；未知负责人或日期保留待确认。先给行动建议，只有我明确确认具体事项后才创建系统提醒事项。</textarea></label>${state.scenario==='offline' ? '<p class="status">模型服务不可用；本地草稿仍保留。</p>' : ''}<div class="composer-actions">${actionButton('+','existing','','aria-label="现有附件菜单（示意）"')}<span class="metadata">准备草稿尚未执行</span>${actionButton('↑','send','send-control',state.scenario==='offline' ? 'disabled aria-label="发送（模型服务不可用）"' : 'aria-label="发送"')}</div></div>`;
}
function runningScreen() {
  const interrupted = state.scenario==='interrupted';
  return `<h1>${interrupted ? '处理已中断' : '正在整理来源文字'}</h1><p class="status">${interrupted ? '尚未提交新结果；旧结果仍可阅读。' : '输入已固定为版本 '+(state.request?.revision || 12)+'，尚未完成校验与提交。'}</p><p class="metadata">不提供推测百分比。生成中的文件不会出现在正式结果列表。</p>${actionButton('打开关联聊天','chat','secondary')}${actionButton('返回录音','detail','secondary')}${actionButton(interrupted ? '核对并恢复处理' : '停止本次整理',interrupted ? 'resume' : 'stop','secondary')}<p class="compact" style="margin-top:16px">原型运行由画布外「演示：提交整理结果」推进。</p>`;
}
function resultsScreen() {
  if (isSourceGone() && !state.retained) return deletedScreen();
  const invalid=state.scenario==='invalidResult';
  return `${state.scenario==='sourceUpdated' ? '<p class="status">来源已更新 · 结果按所绑定版本查看。</p>' : ''}${isSourceGone() ? '<p class="status">来源已删除；仅保留明确选择的派生结果。</p>' : ''}<section><h2>文件</h2>${invalid ? '<p class="status">新输出未通过格式 / 来源校验，不能作为正式结果。</p>'+row('未校验输出 · 原文件','保留可读降级入口','legacy') : '<div class="list">'+row(resultName()+'.md','已提交 · 来源版本 '+resultRevision()+' · 覆盖信息可查看','previewFile')+row('行动建议.json','已提交 · 3 项未确认建议','actions')+row('思维导图.md · P1','独立范围，保留文件预览','tree')+'</div>'}${row('旧 generated 纪要.md','历史文件 · 来源版本 / 完成状态未记录','legacy')}</section><section><h2>处理记录</h2>${row(state.running ? '正在处理 · 尚无新提交' : state.scenario==='interrupted' ? '处理已中断' : '查看关联运行','查看状态与关联聊天','running')}${row('历史结果','旧版本与历史文件','history')}</section>${actionButton('基于当前版本重新整理','organize','secondary',isSourceGone() ? 'disabled' : '')}`;
}
function minutesScreen() {
  if (isSourceGone() && !state.retained) return deletedScreen();
  return `<h1>产品访谈复盘</h1><p class="metadata">产物来源与行动信息 · ${resultName()} · 来源版本 ${resultRevision()}</p>${resultClass()==='completenessUnknown' ? '<p class="status">原文完整性未记录；此结果不能标为正式完整纪要。</p>' : ''}${state.scenario==='sourceUpdated' ? '<p class="status">来源已更新；此结果仍基于旧版本。</p>' : ''}${resultClass()==='withMissingContent' ? '<p class="status">含缺失：08:20–09:00 音频不可恢复，没有补写缺失内容。</p>' : ''}${resultClass()==='preliminary' ? '<p class="status">临时整理仅覆盖已有文字，不代表完整会议原文。</p>' : ''}${isSourceGone() ? '<p class="status">来源已删除，不能回到原文或重新整理。</p>' : ''}<section><h2>主题 / 摘要</h2><p>讨论本轮录音整理的交付范围及尚未确定的预算、评审时间。</p><h2>讨论要点</h2><p>访谈提纲需要整理；预算口径仍是待讨论方案。</p>${sourceButton('原文 00:42–01:20')}</section><section><h2>已明确决策</h2><p>本轮优先保护录音可靠性和已校对文字。</p>${sourceButton('原文 16:30–16:45','decision')}</section><section><h2>未解决问题</h2><p>预算金额、行动负责人及产品评审具体日期尚未确定。</p><p class="metadata">覆盖：${state.artifact?.scope || '00:00–18:42'}${isPartial() ? '，不含 08:20–09:00 缺失范围' : ''}。来源引用按版本 ${resultRevision()} 定位。</p></section>${actionButton('查看行动建议 · 尚未创建','actions','primary',isSourceGone() ? 'disabled' : '')}${actionButton('分享当前纪要','share','secondary')}${actionButton('历史结果','history','secondary')}${actionButton('打开关联聊天','chat','secondary')}`;
}
const sourceButton = (label, segment='discussion') => actionButton(isSourceGone() ? '来源已删除' : label,'source:'+segment,'source-link',isSourceGone() ? 'disabled' : '');
function historyScreen() {
  if (isSourceGone() && !state.retained) return deletedScreen();
  return `<h1>历史结果</h1><div class="list">${row('会议纪要 · 来源版本 '+resultRevision(),'已提交 · '+(currentRevision()===13 ? '来源已更新' : '当前来源'),'minutes')}${row('会议纪要 · 来源版本 11','历史已提交结果，不覆盖新版','oldResult')}${row('旧 generated 纪要.md','历史文件 · 来源版本 / 运行状态未记录','legacy')}</div><section><h2>未发布的处理</h2><p class="metadata">已取消 · 无新提交<br>校验失败 · 格式 / 来源不可核对<br>已中断 · 待核对恢复</p>${actionButton('查看中断与恢复','running','text-button')}</section>`;
}
function actionsScreen() {
  const gone = isSourceGone();
  if (gone) return `<h1>来源已删除</h1><p class="metadata">未确认建议已失去创建能力；系统事项仍保留。</p>${actionButton('查看已关联系统事项','reminder','secondary')}`;
  return `<h1>行动建议</h1><p class="metadata">建议需具体确认。只创建你选择并明确确认的内容。</p>${gone ? '<p class="status">来源已删除，未确认建议不能再创建。</p>' : ''}${state.scenario==='permission' ? '<p class="status">系统提醒事项权限不可用，候选仍保留。</p>'+actionButton('前往系统权限设置','settings','system text-button') : ''}<div>${state.actions.map((item) => `<div class="action"><label class="choice"><input type="checkbox" data-select="${item.id}" aria-label="选择 ${escapeText(item.title)}" ${item.selected ? 'checked' : ''} ${gone || item.writeStatus ? 'disabled' : ''}></label><div><h3>${escapeText(item.title)}</h3><p class="${item.writeStatus==='saved' ? 'success' : 'metadata'}">${{saved:'已创建系统事项',differences:'已创建 · 系统设置有差异',failed:'创建失败 · 在创建结果页重试',uncertain:'结果待核实 · 不能重新创建'}[item.writeStatus] || '尚未创建系统事项'}</p><p class="metadata">负责人：${escapeText(item.owner)}</p>${times(item)}<p class="metadata">${escapeText(listText(item.list))}</p>${item.id==='a3' ? '<p class="status">可能重复 · 需核对来源；未自动合并</p>' : ''}${item.id==='a2' ? '<p class="compact">“下周”以录音发生时间 / 时区解释，具体日期尚未确认。</p>' : ''}${item.writeStatus ? actionButton('查看创建结果','receipt','text-button') : actionButton('编辑候选','edit:'+item.id,'text-button',gone ? 'disabled' : '')}${sourceButton('查看原文出处')}</div></div>`).join('')}</div>${actionButton('核对所选 '+state.actions.filter((a)=>a.selected).length+' 项','confirm','primary',!state.actions.some((a)=>a.selected) || gone ? 'disabled' : '')}<p class="compact" style="margin-top:12px">编辑与取消都不写入系统。负责人字段不是他人分配权限。</p>`;
}
function editSheet(id) {
  const item = state.actions.find((a)=>a.id===id);
  showSheet('编辑行动建议', `<form id="edit-form" data-id="${id}"><label class="field"><span>标题</span><input name="title" value="${escapeText(item.title)}" required></label><label class="field"><span>负责人信息（来源事实，非分配权限）</span><input name="owner" value="${escapeText(item.owner)}"></label><label class="field"><span>账户 / 系统列表</span><select name="list">${Object.entries(lists).map(([key,list])=>`<option value="${key}" ${item.list===key ? 'selected' : ''}>${list.account} · ${list.name}${list.writable ? '' : '（只读）'}</option>`).join('')}</select></label><label class="field"><span>到期日期（可不设置）</span><input type="date" name="due" value="${escapeText(item.due)}"></label><label class="field"><span>到期时间（可不设置；Asia/Shanghai）</span><input type="time" name="time" value="${escapeText(item.time)}"></label><label class="field"><span>独立定时提醒（可不设置；Asia/Shanghai）</span><input type="datetime-local" name="alarm" value="${escapeText(item.alarm)}"></label><p class="metadata" style="margin-top:12px">到期只设置事项属性，不自动通知。定时提醒独立；不填写就不会设置定时提醒。</p><label class="field"><span>备注 / 相对日期解释</span><textarea name="notes">${escapeText(item.notes)}</textarea></label>${id==='a3' ? actionButton(item.another ? '已明确：这是另一件事' : '这是另一件事','another','secondary') : ''}<p class="compact">重复 / 位置 / 多提醒等复杂组合沿用系统编辑保护，不降级写入。</p>${actionButton('保存候选','saveEdit','primary')}</form>`);
}
function confirmScreen() {
  const selected = state.actions.filter((a)=>a.selected);
  const readonly = state.scenario==='readonly' || selected.some((a)=>!lists[a.list].writable);
  const invalid = state.scenario==='invalidDate' || selected.some((a)=>a.time && !a.due);
  const permission = state.scenario==='permission';
  return `<h1>确认这 ${selected.length} 项</h1><p class="metadata">一次确认仅授权下列具体内容。关联与处理记录仅保存在本机。</p>${selected.map((item)=>`<section><h2>${escapeText(item.title)}</h2><p class="metadata">${escapeText(listText(item.list))}<br>负责人信息：${escapeText(item.owner)}</p>${times(item)}<p class="compact">时区：Asia/Shanghai<br>${escapeText(item.notes)}</p>${sourceButton('来源：版本 '+resultRevision()+' · 原文出处')}</section>`).join('')}${readonly ? '<p class="status">目标列表只读，不能创建；请返回换列表，不会回退默认列表。</p>' : ''}${invalid ? '<p class="status">日期 / 时间无效，请返回编辑。不会创建半配置事项。</p>' : ''}${permission ? '<p class="status">尚无提醒事项写入权限。候选仍保留，请授权后继续。</p>'+actionButton('前往系统权限设置','settings','system text-button') : ''}${actionButton('确认创建 '+selected.length+' 项','create','primary',!selected.length || readonly || invalid || permission || isSourceGone() ? 'disabled' : '')}${actionButton('返回修改 / 取消','actions','secondary')}<p class="compact" style="margin-top:12px">只设到期不会产生定时通知；已设置定时提醒不代表通知已到达。</p>`;
}
function receiptScreen() {
  return `<h1>逐项创建结果</h1><p class="metadata">成功项不会再次提交；结果不明先核实。</p>${state.receipt.map((item)=>`<section><h2>${escapeText(item.title)}</h2><p class="${item.status==='saved' ? 'success' : 'status'}">${{saved:'已创建 · 读取到保存后系统回执',differences:'已创建 · 系统设置与确认内容有差异',failed:'创建失败 · 保存前检查失败',uncertain:'结果待核实 · 保存后回执中断'}[item.status]}</p><p class="metadata">${escapeText(listText(item.list))}</p>${times(item)}${item.status==='differences' ? '<p class="status">确认的提醒时间：2026-10-05 10:00；系统实际保存：10:05。该项已创建，请查看或编辑现有事项，不再次创建。</p>' : ''}${['saved','differences'].includes(item.status) ? `<details><summary>查看保存回执</summary><p class="compact">实际系统 ID：demo-reminder-${item.id}<br>确认 ID：demo-confirmation-${item.id}</p></details>${actionButton('在待办事项查看','reminder:'+item.id,'system text-button')}` : item.status==='failed' ? '<p class="metadata">本项尚未保存。候选仍在，可只重试此项。</p>'+actionButton('只重试此失败项','retry:'+item.id,'secondary') : '<p class="metadata">先查询来源标记和已有映射；不能按名称盲目新建。</p>'+actionButton('核实结果，不重新创建','reconcile:'+item.id,'secondary')}${sourceButton('查看来源')}</section>`).join('')}${!state.receipt.length ? '<p class="metadata">尚未确认任何创建。返回建议后选择具体项。</p>' : ''}${actionButton('返回行动建议','actions','secondary')}`;
}
function sourceScreen() {
  if (isSourceGone()) return '<h1>来源已删除</h1><p class="metadata">派生结果保留不等于保留原文，不能恢复原文回跳。</p>';
  const decision=state.sourceSegment==='decision';
  const overview=state.sourceSegment==='overview';
  return `<h1>产品访谈复盘</h1>${detailTabs()}<p class="metadata">产品访谈复盘 · 版本 ${resultRevision()}<br>${overview ? '00:42–01:20；16:30–16:45 · 两个来源段' : decision ? '16:30–16:45 · 说话人 2' : '00:42–01:20 · 说话人 1 · 已校对'}</p>${currentRevision()!==resultRevision() ? '<p class="status">当前为版本 '+currentRevision()+'；此引用仍定位已绑定版本 '+resultRevision()+'。</p>' : ''}<section><h2>所定位的文字</h2><p>${overview ? '00:42：我们先整理访谈提纲，再核对预算口径。预算还没有确定，下周再讨论。<br><br>16:30：已决定本轮先保护录音和校对文字。产品评审时间还没有确定。' : decision ? '已决定本轮先保护录音和校对文字。产品评审时间还没有确定。' : '我们先整理访谈提纲，再核对预算口径。预算还没有确定，下周再讨论。'}</p><p class="compact">引用定位旧快照，不使用当前新版的相似句替代。</p></section>${actionButton('返回纪要','minutes','secondary')}`;
}
function preflightSheet() {
  if ($('#sheet').open) closeSheet();
  const unavailable = state.scenario==='audioExpired' || isSourceGone();
  showSheet('重转写音频预检', `<p class="status">${unavailable ? '音频已过期 / 不可用，不能重新转写。' : isPartial() ? '仅 00:00–08:20、09:00–18:42 音频可读。' : '00:00–18:42 音频可读。'}</p><p>当前版本 ${currentRevision()} 与 3 段人工校对将保留。新的识别结果先作为候选，不直接替换当前文稿。</p>${unavailable ? '<p class="metadata">现有文字仍可阅读；不会先清空旧稿。</p>' : isPartial() ? '<p class="metadata">08:20–09:00 缺失，不能重试；只处理可用范围。</p>' : ''}${actionButton(isPartial() ? '仅重试可用范围，生成候选' : '生成识别候选','makeCandidate','primary',unavailable ? 'disabled' : '')}${actionButton('保留旧稿，返回阅读','close','secondary')}`);
}
function candidateScreen() {
  return `<h1>比较识别候选</h1><p class="metadata">旧版本 ${currentRevision()} 完整保留；采纳后才产生新版本。</p><section><h2>00:42–01:20 · 已校对</h2><p class="compact">当前文字</p><p>我们先整理访谈提纲，再核对预算口径。</p><p class="compact">新识别候选</p><p>我们先整理访谈大纲，再核对预算。</p><p class="status">默认保留人工校对。</p></section><section><h2>16:30–16:45 · 未校对</h2><p>候选：本轮先保护录音可靠性和已校对文字。</p><p class="metadata">可稳定映射，可选择采纳。</p></section><section><h2>17:20–17:40 · 来源无法稳定映射</h2><p class="status">需要逐段核对，不自动采纳或继承校对标记。</p></section>${actionButton('保留校对，采纳其他可映射段','adopt','primary')}${actionButton('整份替换，包括人工校对…','replace','secondary danger')}${actionButton('取消，继续阅读旧稿','detail','secondary')}`;
}
function reminderScreen() {
  if (state.scenario==='permission') return `<h1>暂不可读取系统事项</h1><p class="status">权限已撤销，这不表示事项已删除。</p>${actionButton('前往系统权限设置','settings','system secondary')}${actionButton('刷新真实状态','refresh','secondary')}`;
  if (state.scenario==='externalDeleted') return `<h1>系统事项已删除</h1><p class="metadata">录音和文稿仍保留，不会自动补建事项。</p>${actionButton('明确另建一件事项','newReminder','secondary')}${sourceButton('查看录音来源')}`;
  const item=state.reminder || initialActions()[0];
  return `<section><label class="field"><span>标题</span><input value="${state.scenario==='externalChanged' ? '访谈提纲 · 系统中已改名' : escapeText(item.title)}"></label><label class="field"><span>备注</span><textarea>${escapeText(item.notes)}</textarea></label><div class="row"><span>列表<span class="metadata">${escapeText(listText(item.list))}</span></span><span>›</span></div></section><section><div class="row"><span>到期日期</span><span>${escapeText(item.due || '关闭')}</span></div>${item.due ? '<div class="row"><span>到期时间</span><span>'+escapeText(item.time || '关闭')+'</span></div>' : ''}<p class="metadata">到期日期用于安排待办；通知请单独设置定时提醒。</p><div class="row"><span>定时提醒</span><span>${escapeText(item.alarm ? item.alarm.replace('T',' ') : '关闭')}</span></div><p class="metadata">通知由系统提醒事项发送，是否提示取决于系统通知设置。</p></section><section><h2>来源关联</h2><p class="metadata">系统实际状态：${state.scenario==='externalChanged' ? '已完成（外部变更）' : '未完成'}。内容与完成状态以系统读取为准。</p>${isSourceGone() ? '<p class="status">来源已删除；系统事项仍保留。</p>' : sourceButton('产品访谈复盘 · 来源版本 '+resultRevision())}${actionButton('刷新系统状态','refresh','text-button')}</section>${actionButton('删除待办事项','existing','text-button danger')}`;
}
function retentionScreen() {
  return `<h1>音频保留</h1><p>默认保留 7 天；示例音频将在 2026年10月9日过期。</p><p class="status">待处理 / 失败片段可能在音频到期后无法重试。正在处理不会自动延期。</p><p class="metadata">音频到期只清理音频；文字、纪要与系统事项仍保留。</p>${actionButton(state.longRetention ? '已明确选择长期保留' : '长期保留这份音频','keepAudio','primary',state.longRetention ? 'disabled' : '')}<p class="compact" style="margin-top:12px">这是用户明确的保留选择，网页仅演示，不修改设备存储。</p>`;
}
function deleteSheet() {
  showSheet('删除这条录音？', `<p>请核对删除范围。此提案默认一并删除派生结果，仍待评审。</p><div class="list"><div class="row"><span>音频与原文<span class="metadata">主文稿、公开文稿副本、每日汇总与智能体输入副本</span></span><span>删除</span></div><div class="row"><span>全部受管原文版本<span class="metadata">AI 输入快照、旧校对版本、重转写候选</span></span><span>始终删除</span></div><div class="row"><span>关联运行<span class="metadata">取消并撤销继续读取 / 提交</span></span><span>停止</span></div><div class="row"><span>已创建系统提醒事项<span class="metadata">关联显示来源已删除</span></span><span>保留</span></div></div><label class="choice"><input type="checkbox" id="retain-results">明确保留摘要 / 导图（来源将不可回跳）</label><p class="metadata">未确认建议不能继续创建。保留摘要不保留完整原文、快照或全文附件。</p><p class="compact">本次清理限 App 受管资料；不能承诺撤回已导出文件或已发送第三方模型的内容。</p>${actionButton('删除录音与受管原文','deleteNow','primary destructive')}`);
}
function deletedScreen() {
  const failed = state.scenario==='cleanupFailed';
  return `<h1>${failed ? '清理尚未完成' : '来源已删除'}</h1><p class="status">${failed ? '录音与主文稿已移除；每日汇总的文稿副本清理失败。' : '受管原文、快照、旧校对版本与候选已清理（示例）。'}</p><p class="metadata">来源继续读取 / 提交已撤销，残留不能再交给智能体。系统提醒事项保留。</p>${failed ? actionButton('继续清理未完成副本','cleanup','primary') : ''}${state.retained ? row('查看明确保留的摘要 / 导图','来源已删除；不能回到原文','results') : '<p class="metadata">派生结果按默认提案一并删除。</p>'}${row('查看已关联系统事项','保留实际系统事项与来源已删除说明','reminder')}`;
}
function treeScreen() {
  if (isSourceGone() && !state.retained) return deletedScreen();
  if (state.scenario==='invalidTree') return `<h1>导图结构无法读取</h1><p class="status">节点循环 / 非法来源或层级超限，不能作为正式导图。</p><p class="metadata">原文与已完成纪要不受影响。</p>${actionButton('查看可读文字降级','legacy','secondary')}${actionButton('返回纪要','minutes','secondary')}`;
  return `<h1>产品访谈复盘</h1><p class="metadata">P1 独立提案 · 来源版本 ${resultRevision()}<br>分类层级不表示原文因果关系。</p>${actionButton(state.textTree ? '切换折叠树' : '文字等价阅读','toggleTree','secondary')}${state.textTree ? `<section><h2>主题：产品访谈复盘</h2><p>一、讨论：访谈提纲、预算口径。<br>二、已明确决策：优先保护录音与校对文字。<br>三、行动建议：整理提纲、核对预算、约产品评审。<br>四、未解决问题：负责人和具体日期待确认。</p>${sourceButton('来源：00:42–01:20 / 16:30–16:45','overview')}${actionButton('进入行动建议确认','actions','text-button',isSourceGone() ? 'disabled' : '')}</section>` : `<section><details open><summary>产品访谈复盘 · 主题</summary><details><summary>讨论 · 访谈提纲与预算</summary><p class="metadata">预算仍是待讨论方案。</p>${sourceButton('原文 00:42–01:20')}</details><details><summary>已明确决策 · 优先保护可靠性</summary><p>保护录音和已校对文字。</p>${sourceButton('原文 16:30–16:45','decision')}</details><details><summary>行动建议 · 尚未创建</summary>${actionButton('进入具体确认','actions','text-button',isSourceGone() ? 'disabled' : '')}</details><details><summary>未解决问题 · 日期与负责人</summary><p class="metadata">均保留待确认。</p></details></details></section>`}<section><h2>导出当前导图</h2><p class="metadata">包含节点层级与来源对应，不包含原始音频或整份原文。</p>${actionButton('导出 Markdown 示例','exportMD','secondary')}${actionButton('导出 Mermaid 图描述示例','exportMermaid','secondary')}</section>`;
}

function download(format) {
  const provenance = '虚构示例 recordingID: 11111111-1111-4111-8111-111111111111，revision: 12；节点 discussion → segmentID 22222222-2222-4222-8222-222222222222（00:42–01:20），decision → segmentID 33333333-3333-4333-8333-333333333333（16:30–16:45）。';
  const text = format==='md' ? '# 产品访谈复盘\n\n'+provenance+'\n\n- 讨论\n  - 访谈提纲与预算口径\n- 已明确决策\n  - 优先保护录音与校对文字\n- 行动建议（未创建）\n  - 整理提纲\n  - 核对预算\n- 未解决问题\n  - 日期与负责人待确认\n' : 'flowchart TD\n  topic[产品访谈复盘] --> discussion[讨论：提纲与预算]\n  topic --> decision[决策：保护可靠性]\n  topic --> actions[行动建议：尚未创建]\n  topic --> open[未决：日期与负责人]\n\n%% '+provenance+'\n';
  const url = URL.createObjectURL(new Blob([text],{type:'text/plain;charset=utf-8'}));
  const anchor = document.createElement('a'); anchor.href=url; anchor.download='recording-map-demo.'+(format==='md' ? 'md' : 'mmd'); anchor.click(); URL.revokeObjectURL(url);
  announce('已下载虚构导图示例；层级和来源随文件保留。');
}
document.addEventListener('change', (event)=> {
  if (event.target.matches('[data-select]')) {
    state.actions.find((a)=>a.id===event.target.dataset.select).selected=event.target.checked;
    const id=event.target.dataset.select;
    render();
    $(`[data-select="${id}"]`).focus();
  }
});
document.addEventListener('click', (event)=> {
  const button=event.target.closest('[data-action]');
  if (!button || button.disabled) return;
  const [action,id]=button.dataset.action.split(':');
  if (action==='close') return closeSheet();
  if (action==='back') return navigate(state.history.pop() || 'meetings',true);
  if (action==='more') return moreSheet();
  if (action==='content') {state.contentTab=id;return navigate('detail',true);}
  if (action==='tab') return navigate({chat:'draft',meetings:'meetings',tasks:'tasks',extensions:'extensions'}[id]);
  if (action==='recordMenu') return showSheet('管理录音',row('编辑名称','','existing')+row('移动到文件夹','','existing')+row('删除录音','检查删除范围','delete','danger'));
  if (action==='delete' && $('#sheet').open) closeSheet();
  if (action==='previewFile') return showSheet('系统文件预览（示意）','<h2>'+resultName()+'.md</h2><p class="metadata">正式版继续使用现有 QuickLook 查看此文件。</p><p>主题摘要、讨论、已明确决策、行动建议与未解决问题来自同一已提交文件。</p><p class="metadata">文件内容完整性：'+(state.artifact?.sourceInfo || sourceInfo())+'</p>'+actionButton('查看来源与行动信息','minutes','primary'));
  if (action==='allTasks') return navigate('tasksAll');
  if (['existing','folders','listMenu','date','record','sentence','chatMenu','model','mockSave'].includes(action)) return announce('这是已有页面的结构示意；本轮原型只演示新增固定输入与行动闭环。');
  if (action==='source') {state.contentTab='transcript';state.sourceSegment=id;return navigate('source');}
  if (action==='reminder') {state.reminder=state.receipt.find((item)=>item.id===id);return navigate('reminder');}
  if (['meetings','tasks','tasksAll','extensions','detail','results','minutes','history','actions','confirm','receipt','reminder','retention','running','tree'].includes(action)) {if ($('#sheet').open) closeSheet();return navigate(action);}
  if (action==='organize') return organizeSheet();
  if (action==='prepare') {
    const form=new FormData($('#organize-form'));
    state.request={revision:currentRevision(), scope:form.get('scope')==='range' ? '00:42–01:20；16:30–16:45（实际所选 2 段）' : '整份文稿', template:form.get('template'), kind:form.get('kind'), summaryClass:summaryClass(), sourceInfo:sourceInfo()};
    state.running=false;closeSheet();navigate('draft');return announce('已固定虚构输入版本 '+state.request.revision+'；尚未发送。');
  }
  if (action==='send' || action==='resume') {state.running=true; navigate('draft'); return announce('演示运行进入处理中；真实服务没有收到请求。');}
  if (action==='stop') {state.running=false;state.scenario='interrupted';render();return announce('演示已停止；旧结果保留，未提交新结果。');}
  if (action==='edit') return editSheet(id);
  if (action==='another') {const form=$('#edit-form');state.actions.find((a)=>a.id===form.dataset.id).another=true;button.textContent='已明确：这是另一件事';return announce('已明确另建意图；尚未确认系统写入。');}
  if (action==='saveEdit') {
    const form=$('#edit-form');if (!form.reportValidity()) return;
    const values=Object.fromEntries(new FormData(form));
    const item=state.actions.find((a)=>a.id===form.dataset.id);Object.assign(item,values);
    closeSheet();render();return announce('候选已更新；未写入系统事项。');
  }
  if (action==='create') {
    state.receipt=state.actions.filter((a)=>a.selected).map((a,index)=>({...a,status:['saved','failed','uncertain'][index]}));
    state.receipt.forEach((item)=>{Object.assign(state.actions.find((a)=>a.id===item.id),{selected:false,writeStatus:item.status});});
    navigate('receipt');return announce('演示回执已显示：逐项成功、失败或待核实；没有调用 EventKit。');
  }
  if (action==='retry' || action==='reconcile') {
    if (state.scenario==='permission') return announce('权限不可用，不能核实；不会推断删除或重新创建。');
    state.receipt.find((a)=>a.id===id).status='saved';state.actions.find((a)=>a.id===id).writeStatus='saved';render();
    return announce(action==='retry' ? '仅失败项演示重试成功，其他成功项未重新提交。' : '已核对原系统对象的演示回执，没有重新创建。');
  }
  if (action==='retranscribe') return preflightSheet();
  if (action==='makeCandidate') {closeSheet();navigate('candidate');return announce('识别候选演示已生成，旧稿仍保留。');}
  if (action==='replace') return showSheet('整份替换包括人工校对？', `<p>本次将替换包括人工校对在内的全部文字。旧版本仍保留，可恢复。</p>${actionButton('确认整份替换','replaceNow','primary destructive')}${actionButton('取消，保留当前文字','close','secondary')}`);
  if (action==='adopt' || action==='replaceNow') {if ($('#sheet').open) closeSheet();state.scenario='sourceUpdated';$('#scenario').value='sourceUpdated';navigate('detail');return announce('采纳演示产生版本 13；旧版本及旧结果保留。无法映射段仍需核对。');}
  if (action==='delete') return deleteSheet();
  if (action==='deleteNow') {state.retained=$('#retain-results').checked;state.revoked=true;closeSheet();navigate('deleted');return announce('演示来源已撤销；系统事项保留，受管原文清理范围已显示。');}
  if (action==='cleanup') {state.scenario='sourceDeleted';$('#scenario').value='sourceDeleted';render();return announce('演示已继续清理失败副本；来源不能再次桥接。');}
  if (action==='keepAudio') {state.longRetention=true;render();return announce('演示已记录用户明确的长期保留选择。');}
  if (action==='toggleTree') {state.textTree=!state.textTree;render();return;}
  if (action==='exportMD' || action==='exportMermaid') return download(action==='exportMD' ? 'md' : 'mmd');
  if (action==='newReminder') {state.actions.push({...initialActions()[0],id:'a'+(state.actions.length+1),another:true});navigate('actions');return announce('请选择并确认新的具体事项；外部删除不会触发自动补建。');}
  if (action==='chat') return navigate('draft');
  const messages = {
    play:'这里仅是播放器示意；网页未加载或播放音频。',settings:'正式版复用现有模型 / 系统权限设置入口；网页不打开或修改系统设置。',
    chat:'正式版打开原有 Agent 对话；网页不启动真实模型运行。',share:'正式版系统分享当前纪要及引用元数据，不自动包含原始音频或全文。',
    oldResult:'示例历史结果：来源版本 11，已提交；不会覆盖来源版本 12 的结果。',legacy:'历史 / 降级文件可阅读，但来源版本或完成状态未记录，不伪造正式结果。',
    refresh:'正式版从 EventKit 刷新真实状态；网页未读取本机提醒事项。'
  };
  if (messages[action]) showSheet('演示说明', `<p>${messages[action]}</p>${actionButton('返回','close','primary')}`);
});
$('#scenario').addEventListener('change',(event)=> {
  state.scenario=event.target.value;state.artifact=null;state.revoked=false;state.retained=state.scenario==='sourceDeleted';
  const routes={interrupted:'running', invalidResult:'results', permission:'actions', readonly:'actions', invalidDate:'actions', savedDifferences:'receipt', externalChanged:'reminder', externalDeleted:'reminder', sourceDeleted:'deleted', cleanupFailed:'deleted', invalidTree:'tree'};
  if (state.scenario==='savedDifferences') {state.receipt=[{...initialActions()[0],alarm:'2026-10-05T10:05',status:'differences'}];state.actions[0].writeStatus='differences';}
  navigate(routes[state.scenario] || 'detail',true);
  announce('评审场景：'+event.target.selectedOptions[0].textContent+'；未连接真实服务。');
});
$('#theme').addEventListener('click',()=> {
  const dark=$('#phone').dataset.theme!=='dark';$('#phone').dataset.theme=dark ? 'dark' : 'light';$('#sheet').dataset.theme=$('#phone').dataset.theme;$('#theme').textContent=dark ? '切换浅色' : '切换深色';
});
$('#large').addEventListener('click',()=> {
  const large=$('#phone').classList.toggle('large');$('#sheet').classList.toggle('large',large);$('#large').setAttribute('aria-pressed',String(large));$('#large').textContent=large ? '恢复默认字号' : '大字预览';
});
$('#finish').addEventListener('click',()=> {state.running=false;state.result=true;state.artifact={revision:state.request?.revision || 12,scope:state.request?.scope || '00:00–18:42',sourceInfo:state.request?.sourceInfo || sourceInfo(),summaryClass:state.request?.summaryClass || summaryClass()};navigate('results');announce('已模拟来源 / 格式校验后提交；真实模型没有运行。');});
$('#reset').addEventListener('click',()=> {state={scenario:'normal',route:'meetings',history:[],contentTab:'transcript',tab:'meetings',actions:initialActions(),request:null,running:false,result:false,receipt:[],retained:false,revoked:false,longRetention:false,textTree:false};$('#scenario').value='normal';render();announce('虚构数据已重置；未发送任何真实请求。');});
$('#sheet').addEventListener('cancel',()=> {announce('已取消；未新增系统写入。');});
render();
