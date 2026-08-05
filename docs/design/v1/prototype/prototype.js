const app = document.querySelector('#app');

const state = {
  route: 'records',
  active: false,
  isMeeting: false,
  background: false,
  paused: false,
  retained: false,
  gallery: 'permission',
  selectedDate: 3,
  started: false,
  selectedRecord: 'personal',
};

const badge = (kind, text) => `<span class="badge ${kind}">${text}</span>`;
const icon = (value) => `<span aria-hidden="true">${value}</span>`;
const topbar = (title, back = '') => `
  <header class="topbar ${back ? '' : 'topbar-root'}">
    ${back ? `<button class="back" data-go="${back}" aria-label="返回">‹ 返回</button>` : '<span class="topbar-spacer" aria-hidden="true"></span>'}
    <h2>${title}</h2>
    ${back ? '<span class="topbar-spacer" aria-hidden="true"></span>' : '<button class="icon-button profile" data-go="profile" aria-label="打开我的">我</button>'}
  </header>`;
const capture = () => !state.active || state.route === 'recording' ? '' : `
  <section class="capture" aria-label="正在录音。当前记录，12 分 48 秒。">
    <button class="capture-info" data-go="recording">
      <strong>${badge(state.paused ? 'processing' : 'recording', state.paused ? '已暂停' : '● 正在录音')} 当前记录 · 00:12:48</strong>
      <small>${state.background ? '录音继续，转写待前台处理 · 18 项' : '本地转写中 · 待处理 4 项'}</small>
    </button>
    <button class="capture-stop" data-action="stop">停止</button>
  </section>`;
const screen = (title, body, back = '', footer = '') => `<section class="screen">${topbar(title, back)}${capture()}<main class="content">${body}</main>${footer}</section>`;
const action = (symbol, title, subtitle, go, status = '') => `
  <button class="setting-row" data-go="${go}">
    <span class="setting-icon">${symbol}</span><span class="setting-copy"><strong>${title}</strong><small>${subtitle}</small></span>${status}<span class="chevron" aria-hidden="true">›</span>
  </button>`;

function onboarding() {
  return screen('欢迎', `
    <div class="onboarding-mark">⌁</div>
    <p class="eyebrow">VOICECONTEXT</p><h3>把一个念头，留在你的设备上。</h3>
    <p class="muted">个人灵感、现场对话或一场会议，都从同一个「开始记录」进入。</p>
    <div class="bullets">
      <div class="bullet"><b>●</b><span>原始音频默认仅保留 7 天；需要时可单独长期保留。</span></div>
      <div class="bullet"><b>●</b><span>iCloud 只同步文本与结构化文档，不同步原始音频。</span></div>
      <div class="bullet"><b>●</b><span>开始录音前会单独说明麦克风权限。</span></div>
    </div>
    <button class="primary" data-go="permission">继续</button>
    <button class="text-button" data-go="records">暂时跳过</button>`);
}

function permission() {
  return screen('麦克风权限', `
    <div class="hero"><p class="eyebrow">第 1 步，共 3 步</p><h3>让 VoiceContext 听见你主动开始的记录。</h3><p class="muted">只有点「开始记录」后才采集麦克风。你可以稍后在系统设置中更改。</p></div>
    <div class="notice info"><strong>本地优先</strong><br>录音和转写不需要业务账号；拒绝权限后仍可浏览现有文稿。</div>
    <button class="primary" data-action="grant">允许麦克风</button>
    <button class="secondary" data-action="deny">暂不允许</button>`, 'onboarding');
}

function records() {
  const dates = [['周五', 1], ['周六', 2], ['今天', 3], ['周一', 4], ['周二', 5], ['周三', 6], ['周四', 7]];
  const recordRows = state.selectedDate === 3 ? `
    <div class="record-list">
      <button class="record-card voice-capsule" data-action="openPersonal"><span class="record-copy"><span class="record-title"><strong>一个关于 onboarding 的想法</strong><span class="chevron">›</span></span><small>“也许首次引导只需要三步，先让用户说第一句话……”</small><span class="record-meta"><span>10:18</span><span>47 秒</span><span>个人语音</span></span></span></button>
      <button class="record-card" data-action="openMeeting"><span class="record-title"><strong>产品周会</strong><span>${badge('complete', '已完成')} <span class="chevron">›</span></span></span><span class="record-meta"><span>09:30</span><span>42 分钟</span><span>4 位参与人</span><span>会议</span></span></button>
      <button class="record-card" data-go="processing"><span class="record-title"><strong>办公室讨论</strong><span>${badge('processing', '处理中')} <span class="chevron">›</span></span></span><span class="record-meta"><span>14:42</span><span>6 项待处理</span></span></button>
      <button class="record-card" data-action="openCleaned"><span class="record-title"><strong>研究笔记</strong><span>${badge('attention', '音频已清理')} <span class="chevron">›</span></span></span><span class="record-meta"><span>16:05</span><span>文稿仍可阅读</span></span></button>
    </div>` : `
    <div class="empty"><div class="empty-icon">⌁</div><h3>这一天还没有记录</h3><p class="muted">说一句，把此刻收进来。</p></div>`;
  const recordDock = state.active
    ? `<footer class="record-dock active"><button class="record-resume" data-go="recording"><span class="record-active-dot" aria-hidden="true"></span><span><strong>返回当前录音</strong><small>${state.paused ? '已暂停' : '正在录音'} · 00:12:48</small></span><span class="chevron" aria-hidden="true">›</span></button></footer>`
    : `<footer class="record-dock"><button class="record-launch" data-go="start" aria-label="开始录音。会议、对话，或一个念头。"><span class="record-orb" aria-hidden="true"><i></i></span><span class="record-dock-label"><strong>开始录音</strong><small>会议、对话，或一个念头</small></span></button></footer>`;
  return screen('记录', `
    <div class="row date-heading"><div><p class="eyebrow">2026 年 8 月</p><h4>8 月 ${state.selectedDate} 日</h4></div><button class="icon-button" data-action="calendar" aria-label="打开完整日历">▦</button></div>
    <div class="calendar" aria-label="日期选择">${dates.map(([label, day]) => `<button class="day ${day === state.selectedDate ? 'selected' : ''} ${day === 3 ? 'today' : ''}" data-date="${day}" aria-pressed="${day === state.selectedDate}"><span>${label}</span><strong>${day}</strong>${day < 5 ? '<i class="day-dot"></i>' : '<i class="day-dot" style="visibility:hidden"></i>'}</button>`).join('')}</div>
    <h4>当日记录</h4>${recordRows}
    <div class="notice neutral"><strong>音频默认保留 7 天</strong><br>在任意记录详情中可选择长期保留；清理音频不会删除文稿或日历记录。</div>
    <button class="text-button" data-go="states">查看状态画廊（设计评审）</button>
    <button class="text-button" data-go="onboarding">查看首次引导</button>`, '', recordDock);
}

function start() {
  return screen('开始记录', `
    <div class="hero"><p class="eyebrow">新的 RECORDING</p><h3>现在，想说什么？</h3><p class="muted">一个念头也值得完整留下。无需标题、无需选类型，点一下就开始。</p></div>
    <button class="capture-launch" data-action="begin"><span class="capture-launch-icon" aria-hidden="true"><i></i></span><span><strong>直接开始录音</strong><small>开始后立即采集并在本地处理</small></span><span class="chevron" aria-hidden="true">›</span></button>
    <div class="quick-note"><strong>先说出来，稍后再整理</strong><p class="muted">标题、参与人、标签和会议字段都可以在录音中或结束后补充。</p></div>
    <h4>开始前补充（可选）</h4>
    <label class="field">标题<input placeholder="例如：一个关于 onboarding 的想法"></label>
    <label class="field">参与人<input placeholder="个人独白可以留空"></label>
    <label class="field">标签<input placeholder="例如：灵感、复盘、研发"></label>
    <button class="meeting-toggle" aria-pressed="${state.isMeeting}" data-action="toggleMeeting"><span class="check">${state.isMeeting ? '✓' : ''}</span><span><strong>作为会议整理</strong><small>可选增加主题、参与人和纯文本议程</small></span></button>
    ${state.isMeeting ? `<div class="card"><label class="field">会议主题（可选）<input placeholder="例如：v1 发布评审"></label><label class="field">议程文本（可选）<textarea placeholder="输入议程文本；v1 不添加实体文件。"></textarea></label><p class="muted small">会议只增加结构化字段，不改变录音、处理、详情或 7 天默认保留。</p></div>` : ''}
    <button class="text-button" data-action="lowStorage">查看低存储状态</button>`, 'records');
}

function recording() {
  const controls = `<footer class="record-controls"><div><span>${state.paused ? '已暂停' : '录音中'} · 00:12:48</span></div><div class="record-control-actions"><button class="pause-control" data-action="pause">${state.paused ? '▶ 继续' : 'Ⅱ 暂停'}</button><button class="end-control" data-action="stop">结束</button></div></footer>`;
  return screen('正在记录', `
    <div class="row"><div>${badge(state.paused ? 'processing' : 'recording', state.paused ? '已暂停' : '● 正在录音')} ${state.isMeeting ? '<span class="muted small">已作为会议整理</span>' : '<span class="muted small">个人语音也可以</span>'}</div><button class="text-button" data-action="interrupt">模拟中断</button></div>
    <div class="timer">00:12:48</div><div class="level" aria-label="音频输入有声音">▂ ▅ ▇ ▅ ▃</div>
    <p class="recording-prompt">就像说给未来的自己听。停顿没有关系，我们会保留时间。</p>
    <div class="notice ${state.background ? 'info' : 'neutral'}">${state.background ? '<strong>录音继续，转写待前台处理</strong><br>为了保护录音完整性，回到前台后会补齐 18 项处理。' : '<strong>正在本地转写</strong><br>停止后将继续完成说话人聚类与文档生成。'}</div>
    <div class="live-note"><span class="section-label">实时文稿</span><p>${state.isMeeting ? '我们先确认一下本次发布范围，然后讨论录音可靠性……' : '也许首次引导只需要三步。第一步先让用户说出第一句话，再解释整理方式……'}</p><small>${state.background ? '18 项等待回到前台处理' : '正在设备上转写'}</small></div>
    <button class="secondary" data-action="background">${state.background ? '模拟回到前台' : '模拟进入后台后返回'}</button>`, 'records', controls);
}

function stop() {
  return screen('停止确认', `
    <div class="hero"><p class="eyebrow">安全保存</p><h3>要停止当前记录吗？</h3><p class="muted">这会关闭当前音频分片，并把余下的本地任务转入处理队列。</p></div>
    <div class="notice neutral"><strong>不会丢失已经录到的内容</strong><br>处理完成前，这条 Recording 会明确显示为「处理中」。</div>
    <button class="danger" data-action="confirmStop">停止并开始处理</button><button class="secondary" data-go="recording">继续录音</button>`, 'recording');
}

function processing() {
  return screen('处理中', `
    <div class="hero"><p class="eyebrow">当前 RECORDING</p><h3>正在整理你的记录</h3><p>${badge('processing', '处理中')} 还有 6 项待完成</p></div>
    <div class="progress" aria-label="处理进度 64%"><span></span></div>
    <div class="card"><div class="stage"><i class="stage-dot">✓</i><div><strong>安全保存音频分片</strong><p class="muted small">已完成</p></div></div><div class="stage"><i class="stage-dot">2</i><div><strong>离线转写</strong><p class="muted small">正在处理最后一段</p></div></div><div class="stage pending"><i class="stage-dot">3</i><div><strong>说话人聚类与文档</strong><p class="muted small">将原子生成 Markdown 与 JSON</p></div></div></div>
    <button class="primary" data-action="finish">模拟处理完成</button>
    <button class="secondary" data-action="transcription">模拟转写失败</button>
    <button class="secondary" data-action="trial">模拟试用耗尽</button>
    <button class="text-button" data-go="records">稍后查看</button>`, 'records');
}

function detail() {
  const meeting = state.isMeeting;
  const cleaned = state.selectedRecord === 'cleaned';
  const personal = !meeting && !cleaned;
  const title = meeting ? '产品周会' : cleaned ? '研究笔记' : '一个关于 onboarding 的想法';
  const duration = meeting ? '42:16' : cleaned ? '13:20' : '00:47';
  const transcript = meeting
    ? `<button class="transcript" data-go="speakers"><span class="transcript-top">${badge('suspected', '疑似 王明')}<time>00:04:12</time></span><p>我们先确认一下本次发布范围。</p></button><button class="transcript" data-go="speakers"><span class="transcript-top">${badge('unknown', '说话人 2')}<time>00:04:28</time></span><p>录音可靠性需要优先于实时转写。</p></button>`
    : `<button class="transcript personal-transcript" data-action="edit"><span class="transcript-top">${badge('personal', '个人语音')}<time>00:00</time></span><p>也许首次引导只需要三步。第一步先让用户说出第一句话，再解释整理方式。</p></button><button class="transcript personal-transcript" data-action="edit"><span class="transcript-top"><span class="muted small">继续</span><time>00:31</time></span><p>这样应用会更像一个随手可用的语言记事本，而不只是会议工具。</p></button>`;
  const player = cleaned ? `<div class="audio-unavailable"><strong>原始音频已清理</strong><p>文稿、日历记录与导出仍可使用。</p></div>` : `<div class="audio-player"><div class="audio-times"><span>00:00</span><span>${duration}</span></div><div class="audio-track"><i></i></div><div class="player-controls"><button data-action="play" aria-label="后退 15 秒">↶<small>15</small></button><button class="play-main" data-action="play" aria-label="播放录音">▶</button><button data-action="play" aria-label="前进 15 秒">↷<small>15</small></button><button class="speed" data-action="play" aria-label="播放速度 1 倍">1×</button></div></div>`;
  return screen('记录详情', `
    <div class="detail-hero"><div class="row"><div><p class="eyebrow">8 月 3 日 · ${meeting ? '09:30' : '10:18'}</p><h3>${title}</h3><p class="muted">${personal ? '个人语音 · 灵感' : meeting ? '4 位参与人 · 会议' : '标签：研究'} · revision 3</p></div>${badge('complete', '已完成')}</div></div>
    ${player}
    <div class="detail-tabs" aria-label="记录详情内容"><button class="active">文稿</button><button data-action="segments">片段</button><button data-go="speakers">说话人</button></div>
    <span class="section-label">逐字稿 · revision 3</span>${transcript}
    <div class="card retention"><div class="switch-row"><span><strong>原始音频</strong><br><small class="muted">${cleaned ? '已按保留策略清理' : state.retained ? '已长期保留' : '默认保留至 8 月 10 日'}</small></span>${cleaned ? '' : `<button class="switch" aria-label="${state.retained ? '关闭' : '开启'}长期保留" aria-pressed="${state.retained}" data-action="retain"></button>`}</div></div>
    <button class="meeting-toggle" aria-pressed="${meeting}" data-action="toggleDetailMeeting"><span class="check">${meeting ? '✓' : ''}</span><span><strong>作为会议整理</strong><small>仅显示可选会议字段，不会改变保留策略</small></span></button>
    ${meeting ? `<div class="card"><strong>会议结构</strong><p>主题：v1 发布评审</p><p>参与人：张三、李四、王明</p><p>议程：确认范围、风险与下一步。</p><button class="text-button" data-action="editMeeting">编辑会议字段</button></div>` : ''}
    <button class="secondary" data-action="edit">编辑文字、标题与标签</button>${personal ? '' : '<button class="secondary" data-go="speakers">管理说话人</button>'}<button class="primary" data-go="export">导出 Markdown / JSON</button>${meeting ? '<button class="text-button" data-action="skill">查看 Codex Skill 纪要说明</button>' : ''}`, 'records');
}

function speakers() {
  return screen('说话人确认', `
    <div class="hero"><p class="eyebrow">说话人 1</p><h3>确认身份</h3><p>${badge('suspected', '疑似 王明')} <span class="muted">尚未写入长期声纹档案。</span></p></div>
    <div class="notice info">只有你明确确认后，才将这次身份用于后续匹配。系统不会把「疑似」当成「已确认」。</div>
    <button class="primary" data-action="speaker">确认是王明</button><button class="secondary" data-action="speaker">否认匹配，保持未知</button>
    <div class="card"><p>${badge('unknown', '未知')} 无可靠历史身份</p><p>${badge('confirmed', '已确认')} 用户确认后才可使用合格档案</p></div>`, 'detail');
}

function profile() {
  return screen('我的', `
    <div class="hero"><p class="eyebrow">数据与使用</p><h3>你的记录，你的控制权。</h3><p class="muted">本地处理始终可用；同步和购买不会阻塞录音。</p></div>
    <div class="card"><div class="row"><div><strong>转写试用</strong><p class="muted">已使用 58 / 60 分钟</p></div>${badge('processing', '即将耗尽')}</div><div class="progress"><span style="width:96%"></span></div></div>
    <div class="setting-list">${action('◈', '试用额度与永久解锁', '购买或恢复购买', 'purchase')}${action('☁', 'iCloud 文本同步', '当前不可用；文档仍在本机', 'icloud', badge('offline', '不可用'))}${action('◷', '音频保留与存储', '默认 7 天，可逐条长期保留', 'storage')}${action('⌁', 'Codex Skill', '仅已完成的会议可生成纪要', 'skill')}${action('◌', '隐私与权限', '录音边界与麦克风权限', 'privacy')}${action('ⓘ', '第三方许可与归因', '离线可读', 'licenses')}</div>
    <button class="text-button" data-go="states">打开状态画廊（评审）</button>`, 'records');
}

function purchase() {
  return screen('永久解锁与恢复购买', `
    <div class="hero"><p class="eyebrow">转写额度</p><h3>继续处理已保存的音频。</h3><p class="muted">额度耗尽后依然能录音；转写会等到解锁后继续。</p></div>
    <div class="card"><strong>已使用 58 / 60 分钟</strong><div class="progress"><span style="width:96%"></span></div><p class="muted">这是一次性永久解锁，不是订阅。</p></div>
    <button class="primary" data-action="purchase">永久解锁 · ¥58</button><button class="secondary" data-action="restore">恢复购买</button><button class="text-button" data-action="storeOffline">模拟商店离线</button>`, 'profile');
}

function icloud() {
  return screen('iCloud 文本同步', `
    <div class="hero"><p class="eyebrow">公开文档</p><h3>同步文本，不同步原始音频。</h3><p class="muted">关闭 iCloud 后，应用继续使用本机 Documents 的同构目录。</p></div>
    <div class="notice info"><strong>当前 iCloud 不可用</strong><br>你的记录和文档仍保存在本机。稍后可以重试同步，或通过 Files 导出。</div>
    <div class="card"><strong>可同步</strong><p class="muted">Markdown、JSON、模板与派生纪要</p><strong>不会同步</strong><p class="muted">原始音频、未经用户确认的明文声纹</p></div>
    <button class="primary" data-action="retryCloud">重试同步</button><button class="secondary" data-go="export">导出本地文档</button>`, 'profile');
}

function storage() {
  return screen('音频保留与存储', `
    <div class="hero"><p class="eyebrow">音频生命周期</p><h3>默认保留 7 天。</h3><p class="muted">你可以对任意记录或片段开启长期保留；会议标记不会自动永久保存音频。</p></div>
    <div class="card"><strong>预计可清理 1.2 GB</strong><p class="muted">清理只移除超过保留期且未长期保留的原始音频。</p><p class="notice success"><strong>文稿仍保留</strong><br>日期、逐字稿、会议字段和导出文档不会被清理。</p></div>
    <button class="secondary" data-action="lowStorage">查看低存储保护</button>`, 'profile');
}

function exportView() {
  return screen('导出', `
    <div class="hero"><p class="eyebrow">开放文档</p><h3>交给你常用的工具。</h3><p class="muted">Markdown 与 JSON 可在无 iCloud 时通过 Files、分享或 AirDrop 导出。</p></div>
    <div class="notice info"><strong>文档仍保存在本机</strong><br>iCloud 不可用不会影响本地导出。</div>
    <button class="primary" data-action="share">导出 transcript.md</button><button class="secondary" data-action="share">导出 transcript.json</button>`, 'detail');
}

function skill() {
  return screen('Codex Skill', `
    <div class="hero"><p class="eyebrow">本地派生内容</p><h3>会议纪要由你主动生成。</h3><p class="muted">只有「已完成」且标记为会议的 Recording 可使用 <code>generate-meeting-minutes</code>。</p></div>
    <div class="card"><strong>不会覆盖原文</strong><p class="muted">Skill 从当前 revision 的结构化文档生成派生纪要，并写入 generated 目录。</p></div>
    <div class="notice ${state.isMeeting ? 'success' : 'info'}">${state.isMeeting ? '<strong>此记录符合条件</strong><br>在 Mac 的 Codex 中选择模板生成纪要。' : '<strong>普通记录仍可导出</strong><br>标记为会议并处理完成后才显示纪要入口。'}</div>`, 'profile');
}

function privacy() {
  return screen('隐私与权限', `
    <div class="hero"><p class="eyebrow">录音边界</p><h3>只在你主动开始后录音。</h3><p class="muted">VoiceContext 不监听，不录制电话或其他 App 的系统音频。</p></div>
    <div class="setting-list">${action('◉', '麦克风权限', '已允许；可在系统设置中更改', 'permission')}${action('⌁', '后台录音', '录音继续，转写回前台补齐', 'recording')}${action('☁', 'iCloud 文本同步', '原始音频从不进入公开 iCloud', 'icloud')}</div>`, 'profile');
}

function licenses() {
  return screen('第三方许可与归因', `
    <div class="hero"><p class="eyebrow">离线可读</p><h3>模型与运行时来源。</h3><p class="muted">商业发布前仍需完成模型许可的法律审核。</p></div>
    <div class="card"><strong>SenseVoice / FunASR</strong><p class="muted">模型来源与商业许可审核状态</p></div><div class="card"><strong>transcribe.cpp · sherpa-onnx</strong><p class="muted">本地转写与运行时依赖</p></div><div class="card"><strong>Silero VAD · CAM++ / 3D-Speaker</strong><p class="muted">端侧语音活动与说话人处理</p></div>`, 'profile');
}

const gallery = {
  permission: ['权限受限', '尚未获得麦克风权限。你仍可浏览记录；开始时可前往系统设置授权。', 'info'],
  interruption: ['系统中断', '已记录 gap 与中断时间，不把前后音频显示为连续记录。', 'error'],
  backlog: ['后台积压', '录音继续，转写待前台处理 · 18 项。回到前台后补齐。', 'info'],
  storage: ['低存储', '空间不足，无法安全开始新记录；现有音频不会被静默删除。', 'error'],
  icloud: ['iCloud 不可用 / 冲突', '文档仍保存在本机；发生冲突时保留双方副本。', 'info'],
  transcription: ['转写失败', '转写未完成，音频已保存。你可以稍后重试。', 'error'],
  trial: ['试用耗尽', '音频已保存，转写等待解锁。', 'info'],
  speakers: ['说话人身份', '未知、疑似与已确认使用清晰文字、图标和可执行操作区分。', 'info'],
};

function states() {
  const [title, copy, tone] = gallery[state.gallery];
  return screen('状态画廊', `
    <div class="hero"><p class="eyebrow">高保真状态评审</p><h3>${title}</h3><p class="muted">每种状态都说明事实、保留的数据与下一步。</p></div>
    <div class="state-example"><div class="notice ${tone}"><strong>${title}</strong><br>${copy}</div></div>
    <div class="state-grid">${Object.entries(gallery).map(([key, value]) => `<button data-gallery="${key}" aria-pressed="${state.gallery === key}">${value[0]}</button>`).join('')}</div>`, 'records');
}

function render() {
  const views = { onboarding, permission, records, start, recording, stop, processing, detail, speakers, profile, purchase, icloud, storage, export: exportView, skill, privacy, licenses, states };
  app.innerHTML = (views[state.route] || records)();
  app.focus({ preventScroll: true });
}

app.addEventListener('click', (event) => {
  const button = event.target.closest('button');
  if (!button) return;
  const { go, action: selectedAction, gallery: choice, date } = button.dataset;
  if (choice) { state.gallery = choice; state.route = 'states'; }
  else if (date) state.selectedDate = Number(date);
  else if (go === 'start') { state.isMeeting = false; state.selectedRecord = 'personal'; state.route = 'start'; }
  else if (go) state.route = go;
  else if (selectedAction === 'toggleMeeting' || selectedAction === 'toggleDetailMeeting') state.isMeeting = !state.isMeeting;
  else if (selectedAction === 'begin') { state.active = true; state.background = false; state.paused = false; state.started = true; state.selectedRecord = state.isMeeting ? 'meeting' : 'personal'; state.route = 'recording'; }
  else if (selectedAction === 'stop') state.route = 'stop';
  else if (selectedAction === 'confirmStop') { state.active = false; state.route = 'processing'; }
  else if (selectedAction === 'finish') { state.selectedRecord = state.isMeeting ? 'meeting' : 'personal'; state.route = 'detail'; }
  else if (selectedAction === 'background') state.background = !state.background;
  else if (selectedAction === 'openPersonal') { state.isMeeting = false; state.selectedRecord = 'personal'; state.route = 'detail'; }
  else if (selectedAction === 'openMeeting') { state.isMeeting = true; state.selectedRecord = 'meeting'; state.route = 'detail'; }
  else if (selectedAction === 'openCleaned') { state.isMeeting = false; state.selectedRecord = 'cleaned'; state.route = 'detail'; }
  else if (selectedAction === 'retain') state.retained = !state.retained;
  else if (selectedAction === 'grant') state.route = 'records';
  else if (selectedAction === 'deny') { state.gallery = 'permission'; state.route = 'states'; }
  else if (selectedAction === 'interrupt') { state.gallery = 'interruption'; state.route = 'states'; }
  else if (selectedAction === 'lowStorage') { state.gallery = 'storage'; state.route = 'states'; }
  else if (selectedAction === 'transcription') { state.gallery = 'transcription'; state.route = 'states'; }
  else if (selectedAction === 'trial') { state.gallery = 'trial'; state.route = 'states'; }
  else if (selectedAction === 'storeOffline') { state.gallery = 'trial'; state.route = 'states'; }
  else if (selectedAction === 'pause') state.paused = !state.paused;
  else if (['play', 'segments', 'edit', 'editMeeting', 'speaker', 'skill', 'share', 'purchase', 'restore', 'calendar', 'retryCloud'].includes(selectedAction)) window.alert('原型交互：该操作的最终行为、数据边界和 SwiftUI 标注已记录在 docs/design/v1/design-system.md。');
  render();
});

render();
