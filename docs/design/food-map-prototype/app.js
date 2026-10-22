'use strict';
(() => {
  const $ = (selector, root = document) => root.querySelector(selector);
  const screen = $('#screen'), phone = $('#phone'), sheet = $('#sheet'), layer = $('#sheet-layer');
  const STORAGE = 'yima-food-map-prototype-v1';
  const defaultTags = ['想去', '去过', '面食', '咖啡', '朋友推荐'];
  const seeds = [
    { id: 'demo-1', name: '河畔面馆 · 文一路店', short: '河畔面馆', address: '杭州市西湖区文一路 168 号（演示地址）', tags: ['想去', '面食', '朋友推荐'], x: 30, y: 38, icon: 'bowl' },
    { id: 'demo-2', name: '小院食堂', short: '小院食堂', address: '杭州市西湖区翠柏路 32 号（演示地址）', tags: ['去过'], x: 72, y: 29, icon: 'fork' },
    { id: 'demo-3', name: '慢半拍咖啡', short: '慢半拍咖啡', address: '杭州市西湖区教工路 210 号（演示地址）', tags: ['想去', '咖啡'], x: 65, y: 66, icon: 'coffee' },
    { id: 'demo-4', name: '麦香小馆', short: '麦香小馆', address: '杭州市西湖区文二路 86 号（演示地址）', tags: ['去过', '面食'], x: 24, y: 76, icon: 'bowl' },
    { id: 'demo-5', name: '桥边甜铺', short: '桥边甜铺', address: '杭州市西湖区学院路 58 号（演示地址）', tags: ['想去', '朋友推荐'], x: 78, y: 89, icon: 'fork' }
  ];
  let places = structuredClone(seeds), addedTags = [], emptyPlaces = [];
  const view = { page: 'food', mode: 'map', tag: '全部', query: '', offline: false, locationDenied: false, empty: false, dark: false, large: false };
  let activeID = null, modal = null, draft = null, previousFocus = null, toastTimer, persistenceAvailable = true;
  try {
    const saved = JSON.parse(localStorage.getItem(STORAGE));
    if (saved && Array.isArray(saved.places) && saved.places.every(p => p && typeof p.id === 'string' && typeof p.name === 'string' && typeof p.address === 'string' && Array.isArray(p.tags) && p.tags.every(t => typeof t === 'string') && Number.isFinite(p.x) && Number.isFinite(p.y))) {
      places = saved.places;
      addedTags = Array.isArray(saved.tags) ? saved.tags.filter(t => typeof t === 'string') : [];
    }
  } catch { storageNotice(); }
  function storageNotice() { persistenceAvailable = false; const note = $('#storage-note'); note.hidden = false; note.textContent = '浏览器存储不可用，修改只在本次预览保留。'; }
  function saveData() { try { localStorage.setItem(STORAGE, JSON.stringify({ places, tags: addedTags })); persistenceAvailable = true; $('#storage-note').hidden = true; return true; } catch { storageNotice(); return false; } }
  const storageFailure = '仅在本次预览中更新，浏览器未能保存，刷新后可能丢失。';
  const source = () => view.empty ? emptyPlaces : places;
  const esc = value => String(value).replace(/[&<>"']/g, c => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[c]));
  function icon(name, size = 22, extra = '') {
    const paths = {
      chevron: '<path d="m14 5-7 7 7 7"/>', right: '<path d="m9 5 7 7-7 7"/>', plus: '<path d="M12 4v16M4 12h16"/>', close: '<path d="m6 6 12 12M6 18 18 6"/>', search: '<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 4 4"/>', more: '<circle cx="5" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/>',
      pin: '<path d="M19 10c0 5-7 11-7 11S5 15 5 10a7 7 0 1 1 14 0Z"/><circle cx="12" cy="10" r="2.5"/>', locate: '<path d="m21 3-7.5 18-2.7-7.8L3 10.5 21 3Z"/>', check: '<path d="m5 12 4 4L19 6"/>', arrow: '<path d="M12 21V3m-6 7 6-7 6 7"/>', map: '<path d="m3 6 6-3 6 3 6-3v15l-6 3-6-3-6 3V6Z"/><path d="M9 3v15m6-12v15"/>', list: '<path d="M8 6h13M8 12h13M8 18h13M3 6h.1M3 12h.1M3 18h.1"/>',
      coffee: '<path d="M4 8h12v7a5 5 0 0 1-5 5H9a5 5 0 0 1-5-5V8Z"/><path d="M16 9h2a3 3 0 0 1 0 6h-2M7 3v2m5-2v2"/>', bowl: '<path d="M3 11h18a9 9 0 0 1-18 0Zm5 9h8M7 3v4m5-4v4m5-4v4"/>', fork: '<path d="M6 3v7a3 3 0 0 0 6 0V3M9 3v18m11 0V3c-4 3-4 10 0 10"/>',
      book: '<path d="M5 3h14v18H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2Zm0 14h14M7 7h8"/>', chip: '<rect x="5" y="5" width="14" height="14" rx="3"/><path d="M9 1v4m6-4v4M9 19v4m6-4v4M1 9h4m-4 6h4m14-6h4m-4 6h4"/>', user: '<circle cx="12" cy="8" r="3.5"/><path d="M5 21v-2a7 7 0 0 1 14 0v2"/>', memory: '<path d="M9 4a4 4 0 0 0-6 4c-3 3-2 7 1 8a4 4 0 0 0 7 4V4a3 3 0 0 0-2 0Zm6 0a4 4 0 0 1 6 4c3 3 2 7-1 8a4 4 0 0 1-7 4V4a3 3 0 0 1 2 0Z"/>',
      stack: '<path d="m12 2 10 6-10 6L2 8l10-6Zm-9 11 9 5 9-5M3 18l9 5 9-5"/>', hardware: '<circle cx="12" cy="12" r="2"/><path d="M7 7a7 7 0 0 0 0 10m10-10a7 7 0 0 1 0 10M4 4a11 11 0 0 0 0 16M20 4a11 11 0 0 1 0 16"/>', terminal: '<rect x="2" y="4" width="20" height="16" rx="2"/><path d="m6 9 4 3-4 3m7 0h5"/>', globe: '<circle cx="12" cy="12" r="10"/><ellipse cx="12" cy="12" rx="4" ry="10"/><path d="M2 12h20"/>', headset: '<path d="M3 14v-2a9 9 0 0 1 18 0v2M3 13H2v7h4v-7H3Zm18 0h1v7h-4v-7h3Z"/>', mic: '<rect x="8" y="2" width="8" height="13" rx="4"/><path d="M5 11v1a7 7 0 0 0 14 0v-1M12 19v3m-4 0h8"/>', gear: '<path d="m10 2-.5 3-3 1L4 4l-2 4 2.5 2v4L2 16l2 4 2.5-2 3 1 .5 3h4l.5-3 3-1 2.5 2 2-4-2.5-2v-4L22 8l-2-4-2.5 2-3-1L14 2h-4Z"/><circle cx="12" cy="12" r="3"/>', chat: '<path d="M21 11a9 9 0 0 1-9 9H3l1.5-5A9 9 0 1 1 21 11Z"/>', calendar: '<rect x="3" y="4" width="18" height="18" rx="2"/><path d="M7 2v5m10-5v5M3 10h18m-13 5h.1M12 15h.1M16 15h.1"/>', reminder: '<rect x="5" y="3" width="14" height="19" rx="2"/><path d="m8 10 2 2 5-5M8 17h7"/>', grid: '<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/>'
    };
    return `<svg ${extra} width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths[name] || paths.pin}</svg>`;
  }
  function allTags() { return [...new Set([...defaultTags, ...addedTags, ...source().flatMap(p => p.tags)])]; }
  function filtered() { const q = view.query.trim().toLocaleLowerCase(); return source().filter(p => (view.tag === '全部' || p.tags.includes(view.tag)) && (!q || `${p.name} ${p.address}`.toLocaleLowerCase().includes(q))); }
  function announce(message) { $('#announcement').textContent = message; }
  function toast(message) { clearTimeout(toastTimer); const t = $('#toast'); t.textContent = message; t.hidden = false; announce(message); toastTimer = setTimeout(() => { t.hidden = true; }, message.length > 26 ? 6500 : 3200); }
  function nav(title, back = false) { return `<header class="nav">${back ? `<button class="nav-back" data-action="extensions" aria-label="返回拓展">${icon('chevron',24)}拓展</button>` : '<div></div>'}<h1 class="nav-title">${title}</h1><div class="nav-right">${back ? `<button class="icon-button" data-action="add" aria-label="添加收藏地点">${icon('plus',25)}</button>` : ''}</div></header>`; }
  function render() {
    if (view.tag !== '全部' && !allTags().includes(view.tag)) view.tag = '全部';
    phone.classList.toggle('dark', view.dark); phone.classList.toggle('large', view.large);
    screen.innerHTML = view.page === 'extensions' ? extensionsHTML() : foodHTML();
  }
  function foodHTML() {
    const results = filtered();
    return `${nav('美食地图', true)}<div class="toolbar"><div class="segments" role="group" aria-label="查看收藏的方式"><button data-action="mode" data-mode="map" aria-pressed="${view.mode === 'map'}">地图</button><button data-action="mode" data-mode="list" aria-pressed="${view.mode === 'list'}">收藏 <span aria-hidden="true">${source().length}</span></button></div><label class="searchbox">${icon('search',19)}<span class="sr-only">搜索店名或地址</span><input id="search" type="search" placeholder="搜索店名或地址" value="${esc(view.query)}" autocomplete="off"><button class="clear-search" type="button" data-action="clear-query" aria-label="清除搜索" ${!view.query ? 'hidden' : ''}>${icon('close',15)}</button></label></div><div class="filters" role="group" aria-label="按标签筛选，单选">${['全部', ...allTags()].map(tag => `<button class="filter" data-action="filter" data-tag="${esc(tag)}" aria-pressed="${view.tag === tag}">${esc(tag)}<span class="filter-count">${tag === '全部' ? source().length : source().filter(p => p.tags.includes(tag)).length}</span></button>`).join('')}</div><div class="content" id="content">${contentHTML(results)}</div>`;
  }
  function contentHTML(results) {
    let notices = '';
    if (view.offline) notices += '<div class="status-note"><strong>网络不可用</strong> · 收藏仍可查看，在线查找与导航暂不可用。</div>';
    if (view.locationDenied) notices += '<div class="status-note"><strong>定位不可用</strong> · 可继续按店名和地址管理收藏。</div>';
    if (!source().length) return notices + `<div class="empty">${icon('map',38)}<h2>把想去的地方留在这里</h2><p>告诉助手店名或地址，<br>保存后就能在地图和收藏中找到。</p><button class="primary" data-action="add">添加第一个地点</button></div>`;
    if (!results.length) return notices + `<div class="empty">${icon('search',34)}<h2>没有符合条件的收藏</h2><p>${view.query ? `试试其他店名或地址${view.tag !== '全部' ? '，或更换标签' : ''}。` : '这个标签下还没有地点。'}</p><button class="secondary" data-action="clear-filters">查看全部收藏</button></div>`;
    if (view.mode === 'list') return notices + `<div class="list-scroll"><p class="list-caption">${view.tag === '全部' ? '全部收藏' : esc(view.tag)} · ${results.length} 个地点</p><ul class="place-list">${results.map(p => `<li><button class="place-row" data-action="detail" data-id="${esc(p.id)}" aria-label="查看${esc(p.name)}，${esc(p.address)}"><span class="row-icon">${icon(p.icon,23)}</span><span class="row-copy"><span class="row-name">${esc(p.name)}</span><span class="row-address">${esc(p.address)}</span><span class="row-tags">${p.tags.length ? esc(p.tags.join(' · ')) : '无标签'}</span></span><span class="row-arrow">${icon('right',16)}</span></button></li>`).join('')}</ul></div>`;
    return notices + `<div class="map-wrap" aria-label="虚构街区示意图，地图地点也可在收藏列表访问">${mapSVG()}<p class="map-heading">文一路周边 · 虚构街区</p><div class="map-compass" aria-hidden="true">N${icon('arrow',17)}</div><div class="markers">${results.map(p => marker(p)).join('')}</div><p class="map-footnote">示意底图 · 非真实位置</p><button class="location-button" data-action="locate" aria-label="查看当前位置演示">${icon('locate',21)}</button></div><div class="map-summary"><div><strong>${results.length} 个${view.tag !== '全部' ? `「${esc(view.tag)}」` : ''}收藏地点</strong><p>轻点图钉，查看地址和标签</p></div><button class="summary-action" data-action="mode" data-mode="list">查看列表</button></div>`;
  }
  function marker(p) { return `<button class="marker" style="left:${p.x}%;top:${p.y}%" data-action="detail" data-id="${esc(p.id)}" aria-label="查看${esc(p.name)}，${esc(p.tags.join('、'))}"><svg class="pin" viewBox="0 0 36 44" aria-hidden="true"><path class="pin-fill" d="M18 42C15 37 3 26 3 18a15 15 0 0 1 30 0c0 8-12 19-15 24Z"/><circle cx="18" cy="18" r="5" fill="none" class="pin-symbol" stroke-width="2"/></svg><span class="marker-name">${esc(p.short || p.name)}</span></button>`; }
  function mapSVG() { return `<svg class="map-art" viewBox="0 0 390 520" preserveAspectRatio="xMidYMid slice" aria-hidden="true"><rect width="390" height="520" fill="var(--map)"/><g class="block"><rect x="-12" y="-10" width="86" height="86" rx="5"/><rect x="95" y="-10" width="106" height="86" rx="5"/><rect x="221" y="-10" width="84" height="86" rx="5"/><rect x="326" y="-10" width="80" height="86" rx="5"/><rect x="-12" y="97" width="86" height="74" rx="5"/><rect x="95" y="97" width="106" height="74" rx="5"/><rect x="221" y="97" width="84" height="74" rx="5"/><rect x="326" y="97" width="80" height="74" rx="5"/><rect x="-12" y="204" width="86" height="100" rx="5"/><rect x="95" y="204" width="106" height="100" rx="5"/><rect x="221" y="204" width="84" height="100" rx="5"/><rect x="326" y="204" width="80" height="100" rx="5"/><rect x="-12" y="344" width="86" height="87" rx="5"/><rect x="95" y="344" width="106" height="87" rx="5"/><rect x="326" y="344" width="80" height="87" rx="5"/><rect x="-12" y="457" width="86" height="75" rx="5"/><rect x="95" y="457" width="106" height="75" rx="5"/><rect x="221" y="457" width="84" height="75" rx="5"/><rect x="326" y="457" width="80" height="75" rx="5"/></g><path class="park" d="M220 343h85v87h-85z"/><g fill="none" class="road"><path d="M0 188h390" stroke-width="29"/><path d="M0 324h390" stroke-width="28"/><path d="M84 0v520M211 0v520M316 0v520" stroke-width="14"/><path d="M0 86h390M0 444h390" stroke-width="14"/></g><path class="water" d="M-15 240C36 254 7 320 57 350S72 452 35 535H4C43 447 31 402 18 376s-33-29-33-29Z"/><path d="M-10 324h81" stroke="var(--road)" stroke-width="15"/><g><text x="138" y="192">文 一 路</text><text x="143" y="328">文 二 路</text><text x="248" y="88">翠 柏 路</text><text x="318" y="252" transform="rotate(90 318 252)">教 工 路</text><text x="86" y="259" transform="rotate(90 86 259)">学 院 路</text><text class="park-name" x="238" y="391">翠柏小园</text><text class="water-name" x="27" y="407" transform="rotate(77 27 407)">溪 流</text></g><path d="M239 361c21 14 14 36 43 51" stroke="#b5c9ae" stroke-width="3" fill="none"/><g fill="var(--park)"><circle cx="245" cy="359" r="8"/><circle cx="290" cy="413" r="7"/><circle cx="237" cy="413" r="5"/></g></svg>`; }
  function extensionsHTML() {
    const sections = [ ['自定义功能', [['添加','plus']]], ['助手能力', [['Skills','book'],['模型与服务','chip'],['助手设定','user'],['Memory','memory']]], ['工具连接', [['MCP','stack'],['硬件设备','hardware']]], ['工具', [['终端','terminal'],['浏览器','globe'],['儿童故事机','headset'],['语音模式','mic'],['美食地图','map']]], ['我的与设置', [['设置','gear']]] ];
    return `${nav('拓展')}<div class="extension-scroll">${sections.map(([title, items]) => `<section class="extension-section"><h2>${title}</h2><div class="extension-grid">${items.map(([label,symbol]) => `<button class="extension-tile" data-action="${label === '美食地图' ? 'food' : 'boundary'}" data-label="${esc(label)}"><span class="tile-icon">${icon(symbol,27)}</span><span>${esc(label)}</span></button>`).join('')}</div></section>`).join('')}</div><nav class="tabbar" aria-label="主导航">${[['聊天','chat'],['会议','calendar'],['提醒','reminder'],['拓展','grid']].map(([label,symbol]) => `<button data-action="${label === '拓展' ? 'extensions' : 'boundary'}" data-label="${label}" ${label === '拓展' ? 'aria-current="page"' : ''}>${icon(symbol,22)}${label}</button>`).join('')}</nav>`;
  }
  function showSheet(type, content) {
    if (!modal) previousFocus = document.activeElement;
    modal = type; sheet.innerHTML = content; layer.hidden = false; screen.inert = true; $('#toast').hidden = true;
    requestAnimationFrame(() => { sheet.scrollTop = 0; sheet.focus({preventScroll:true}); });
  }
  function closeSheet() { layer.hidden = true; modal = null; draft = null; activeID = null; screen.inert = false; if (previousFocus?.isConnected) previousFocus.focus({preventScroll:true}); else $('.nav-back, .nav-title', screen)?.focus(); }
  function sheetNav(title, left = '取消', leftAction = 'close-sheet', right = '') { return `<div class="grabber" aria-hidden="true"></div><div class="sheet-nav"><button class="text-button" data-action="${leftAction}">${left}</button><h2 id="sheet-title">${title}</h2><div class="nav-end">${right}</div></div>`; }
  function currentPlace() { return source().find(p => p.id === activeID); }
  function showDetail(id) {
    activeID = id; const p = currentPlace(); if (!p) return;
    showSheet('detail', `${sheetNav('地点详情','关闭','close-sheet',`<button class="icon-button" data-action="more" aria-label="更多地点操作">${icon('more',23)}</button>`)}<div class="sheet-body"><h3 class="sheet-title">${esc(p.name)}</h3><p class="detail-address">${icon('pin',18)}<span>${esc(p.address)}</span></p><div class="detail-tag-section"><div class="tag-copy"><span class="section-label">我的标签</span><p class="tag-text">${p.tags.length ? esc(p.tags.join(' · ')) : '暂未添加标签'}</p></div><button class="edit-tags" data-action="edit-tags">编辑标签</button></div><button class="primary navigate" data-action="navigate">${icon('arrow',20)}用苹果地图导航</button><p class="fine-note">导航将由苹果地图承接。</p><p class="detail-meta">${view.empty ? '空收藏演示 · 修改仅在本次预览保留' : persistenceAvailable ? '已保存在 Yima · 虚构演示收藏' : '浏览器未能保存 · 修改仅在本次预览保留'}</p></div>`);
  }
  function tagEditorHTML(kind) {
    return `${sheetNav(kind === 'add' ? '添加标签' : '编辑标签',kind === 'add' ? '上一步' : '取消',kind === 'add' ? 'back-candidates' : 'back-detail')}<div class="sheet-body">${kind === 'add' ? `<p class="step-label">3 / 3 · 保存到美食地图</p><div class="selected-place"><b>${esc(draft.selected.name)}</b><p>${esc(draft.selected.address)}</p></div>` : '<p class="help">可以选择多个标签，也可以不加标签。</p>'}<span class="field-label">选择标签</span><div class="tag-options">${[...new Set([...allTags(), ...draft.extraTags])].map(tag => `<button class="tag-option" data-action="draft-tag" data-tag="${esc(tag)}" aria-pressed="${draft.tags.includes(tag)}">${draft.tags.includes(tag) ? icon('check',15) : ''}${esc(tag)}</button>`).join('')}</div><label class="field-label" for="new-tag">新建标签</label><form id="new-tag-form" class="new-tag-row"><input class="text-input" id="new-tag" placeholder="例如：周末去" maxlength="12" autocomplete="off"><button type="submit">添加</button></form><div id="tag-error" class="error-text" role="status"></div><button class="primary" data-action="${kind === 'add' ? 'save-place' : 'save-tags'}">${kind === 'add' ? '保存收藏' : '保存标签'}</button></div>`;
  }
  function editTags() { const p = currentPlace(); if (!p) return; draft = {kind:'edit', tags:[...p.tags],extraTags:[]}; showSheet('edit-tags',tagEditorHTML('edit')); }
  function startAdd() { draft = {kind:'add',text:'',tags:['面食','想去'],extraTags:[],selected:null,candidates:[]}; addInput(); }
  function addInput() {
    showSheet('add-input', `${sheetNav('添加地点')}<div class="sheet-body"><p class="step-label">1 / 3 · 告诉助手想收藏哪里</p><label class="field-label" for="place-request">店名或地址，以及想加的标签</label><textarea class="input-area" id="place-request" placeholder="例如：收藏巷口面馆，标签是面食、想去。">${esc(draft.text)}</textarea><button class="preset" data-action="preset">${icon('chat',18)}填入一段演示口述</button><p class="help">本原型用文字代替口述，并展示虚构候选，不查询真实地点。</p>${view.offline ? '<p class="error-text">网络不可用，暂时无法查找新地点。输入会保留。</p>' : ''}<p id="input-error" class="error-text" role="status"></p><button class="primary" data-action="find-candidates">查找地点</button></div>`);
  }
  function buildCandidates() {
    const text = draft.text.trim();
    const freeName = text.replace(/^(把|收藏|保存|请收藏|帮我收藏|帮我保存)+/,'').split(/[，,。；;\n]|标签|保存到/)[0].trim().slice(0,24);
    const name = text.includes('河畔') ? '河畔面馆' : (freeName || '河畔面馆');
    const tagPhrase = text.match(/标签(?:是|为|[:：])?\s*([^。；;\n]+)/)?.[1] || '';
    const spokenTags = tagPhrase.split(/[、，,]/).map(t => t.trim().slice(0, 12)).filter(Boolean);
    draft.tags = [...new Set(spokenTags)];
    draft.extraTags = spokenTags.filter(t => !allTags().includes(t));
    draft.candidates = [
      {id:'candidate-wenyi',name:`${name} · 文一路店`,short:name,address:'杭州市西湖区文一路 256 号（演示地址）',x:48,y:52,icon:'bowl'},
      {id:'candidate-wener',name:`${name} · 文二路店`,short:name,address:'杭州市西湖区文二路 226 号（演示地址）',x:51,y:89,icon:'bowl'}
    ];
    const occupied = source().map(p => ({x:p.x,y:p.y}));
    for (const candidate of draft.candidates) {
      const existing = source().find(p => p.name === candidate.name && p.address === candidate.address);
      if (existing) { candidate.x=existing.x; candidate.y=existing.y; continue; }
      const slots = [candidate,{x:15,y:24},{x:50,y:25},{x:85,y:50},{x:12,y:58},{x:46,y:74},{x:45,y:94}];
      const clearance = point => Math.min(...occupied.map(p => Math.hypot(p.x-point.x,p.y-point.y)),Infinity);
      const point = slots.find(p => clearance(p)>18) || slots.reduce((a,b) => clearance(a)>clearance(b)?a:b);
      candidate.x=point.x; candidate.y=point.y; occupied.push({x:point.x,y:point.y});
    }
    draft.selected = null; showCandidates();
  }
  function showCandidates() {
    showSheet('candidates', `${sheetNav('核对地点','上一步','back-input')}<div class="sheet-body"><p class="step-label">2 / 3 · 先选定具体分店</p><h3 class="sheet-title">你说的是哪一家？</h3><p class="help">以下均为演示候选，请核对分店和完整地址。</p><ul class="candidate-list">${draft.candidates.map(p=>`<li><button class="candidate" data-action="select-candidate" data-id="${p.id}" aria-pressed="${draft.selected?.id === p.id}"><span class="radio" aria-hidden="true"></span><span><b>${esc(p.name)}</b><small>${esc(p.address)}</small></span></button></li>`).join('')}</ul><button class="primary" data-action="candidate-next" ${draft.selected ? '' : 'disabled'}>继续，添加标签</button><p class="fine-note">未选定候选前，不会保存收藏。</p></div>`);
  }
  function navigate() {
    const p = currentPlace(); if (!p) return;
    showSheet('navigate', `${sheetNav('苹果地图导航','返回','back-detail')}<div class="sheet-body navigation-receipt"><div class="receipt-icon">${icon('arrow',30)}</div><h3 class="sheet-title">${view.offline ? '暂时无法发起导航' : '将交给苹果地图'}</h3><p class="help">${esc(p.name)}<br>${esc(p.address)}</p><p class="help">${view.offline ? '网络不可用。收藏仍在，可以恢复网络后重试。' : '正式功能会用这个地点作为目的地，交给苹果地图选择路线。'}</p><button class="primary" data-action="back-detail">返回地点</button><p class="fine-note">原型演示回执 · 没有打开真实导航。</p></div>`);
  }
  function messageSheet(title,text,action='close-sheet',label='知道了') { showSheet('message',`${sheetNav(title,'关闭')}<div class="sheet-body"><p class="help">${esc(text)}</p><button class="primary" data-action="${action}">${label}</button></div>`); }
  function persistAndRender() { const persisted = view.empty ? true : saveData(); render(); return persisted; }
  function handleAction(action,button) {
    switch(action) {
      case 'extensions': view.page='extensions'; render(); break;
      case 'food': view.page='food'; render(); break;
      case 'mode': { view.mode=button.dataset.mode; render(); screen.querySelector(`[data-action="mode"][data-mode="${view.mode}"]`)?.focus({preventScroll:true}); break; }
      case 'filter': { view.tag=button.dataset.tag; const left=$('.filters').scrollLeft; render(); $('.filters').scrollLeft=left; [...screen.querySelectorAll('.filter')].find(b=>b.dataset.tag===view.tag)?.focus({preventScroll:true}); announce(`筛选${view.tag}，${filtered().length}个收藏`); break; }
      case 'clear-query': view.query=''; render(); $('#search').focus(); break;
      case 'clear-filters': view.query='';view.tag='全部';render();break;
      case 'detail': showDetail(button.dataset.id);break;
      case 'close-sheet':closeSheet();break;
      case 'back-detail': showDetail(activeID);draft=null;break;
      case 'edit-tags':editTags();break;
      case 'draft-tag': { const tag=button.dataset.tag; draft.tags=draft.tags.includes(tag)?draft.tags.filter(t=>t!==tag):[...draft.tags,tag]; const pos=sheet.scrollTop; sheet.innerHTML=tagEditorHTML(draft.kind); sheet.scrollTop=pos; Array.from(sheet.querySelectorAll('[data-action="draft-tag"]')).find(b=>b.dataset.tag===tag)?.focus(); break; }
      case 'save-tags': { const p=currentPlace(); if(!p)return; p.tags=[...draft.tags];addedTags=[...new Set([...addedTags,...draft.extraTags])];const persisted=persistAndRender();draft=null;showDetail(p.id);toast(persisted?'标签已更新，地图与收藏同步显示':storageFailure);break; }
      case 'more': { const p=currentPlace();if(!p)return;showSheet('more',`${sheetNav('更多操作','返回','back-detail')}<div class="sheet-body"><p class="help">${esc(p.name)}</p><button class="secondary" data-action="edit-tags">编辑标签</button><button class="text-button" style="color:var(--danger);width:100%;margin-top:12px" data-action="delete-confirm">删除收藏</button></div>`);break; }
      case 'delete-confirm':{ const p=currentPlace();if(!p)return;showSheet('delete',`${sheetNav('删除收藏？','取消','back-detail')}<div class="sheet-body"><h3 class="sheet-title">删除这个地点？</h3><p class="help">${esc(p.name)}<br>仅从美食地图移除这条演示收藏。</p><div class="confirm-actions"><button class="primary destructive" data-action="delete-place">删除收藏</button><button class="secondary" data-action="back-detail">保留收藏</button></div></div>`);break; }
      case 'delete-place':{ const p=currentPlace();if(!p)return;if(view.empty)emptyPlaces=emptyPlaces.filter(x=>x.id!==p.id);else places=places.filter(x=>x.id!==p.id);const persisted=persistAndRender();closeSheet();toast(persisted?'已删除这条演示收藏':storageFailure);break; }
      case 'navigate':navigate();break;
      case 'locate':messageSheet(view.locationDenied?'定位不可用':'当前位置演示',view.locationDenied?'无法显示当前位置。仍可用店名或地址收藏地点，已有收藏也能继续查看。':'本原型不请求定位，也不显示虚构的当前位置。正式功能将在你允许后显示当前位置。');break;
      case 'boundary':messageSheet('原型范围',`「${button.dataset.label}」仅展示现有入口。本轮可点击体验集中在美食地图。`);break;
      case 'add':startAdd();break;
      case 'preset':draft.text='收藏巷口面馆，标签是面食、想去。';$('#place-request').value=draft.text;$('#place-request').focus();break;
      case 'find-candidates':draft.text=$('#place-request').value;if(!draft.text.trim()){$('#input-error').textContent='请先输入店名或地址，或填入演示口述。';$('#place-request').focus();return;}if(view.offline){addInput();return;}buildCandidates();break;
      case 'select-candidate':{ const pos=sheet.scrollTop;draft.selected=draft.candidates.find(p=>p.id===button.dataset.id);showCandidates();sheet.scrollTop=pos;break; }
      case 'back-input':addInput();break;
      case 'back-candidates':showCandidates();break;
      case 'candidate-next':if(draft.selected)showSheet('add-tags',tagEditorHTML('add'));break;
      case 'save-place':{
        if(!draft.selected)return;
        const match=source().find(p=>p.name===draft.selected.name&&p.address===draft.selected.address);
        let saved;
        if(match){match.tags=[...new Set([...match.tags,...draft.tags])];saved=match;}
        else{saved={...draft.selected,id:`demo-${Date.now()}`,tags:[...draft.tags]};if(view.empty)emptyPlaces.push(saved);else places.push(saved);}
        addedTags=[...new Set([...addedTags,...draft.extraTags])];view.query='';view.tag='全部';const persisted=persistAndRender();draft=null;showDetail(saved.id);toast(persisted?(match?'已在收藏中，标签已合并':'演示地点已保存到地图与收藏'):storageFailure);break;
      }
    }
  }
  document.addEventListener('click',event=>{const button=event.target.closest('[data-action]');if(button&&!button.disabled)handleAction(button.dataset.action,button);});
  screen.addEventListener('input',event=>{if(event.target.id!=='search')return;view.query=event.target.value;$('#content').innerHTML=contentHTML(filtered());$('.clear-search').hidden=!view.query;announce(`${filtered().length}个收藏`);});
  sheet.addEventListener('input',event=>{if(event.target.id==='place-request'&&draft)draft.text=event.target.value;});
  sheet.addEventListener('submit',event=>{
    if(event.target.id!=='new-tag-form')return;event.preventDefault();const input=$('#new-tag'),tag=input.value.trim();
    if(!tag){$('#tag-error').textContent='请先输入标签名称。';input.focus();return;}
    if(!allTags().includes(tag)&&!draft.extraTags.includes(tag))draft.extraTags.push(tag);
    if(!draft.tags.includes(tag))draft.tags.push(tag);
    const pos=sheet.scrollTop;sheet.innerHTML=tagEditorHTML(draft.kind);sheet.scrollTop=pos;$('#new-tag').focus();announce(`已选中标签${tag}，保存后生效`);
  });
  document.addEventListener('keydown',event=>{
    if(!modal)return;
    if(event.key==='Escape'){event.preventDefault();closeSheet();return;}
    if(event.key!=='Tab')return;
    const focusable=[...sheet.querySelectorAll('button:not(:disabled),input,textarea,[tabindex="0"]')].filter(e=>!e.hidden&&e.getClientRects().length);
    if(!focusable.length){event.preventDefault();sheet.focus();return;}
    const first=focusable[0],last=focusable.at(-1);
    if(event.shiftKey&&(document.activeElement===first||document.activeElement===sheet||!sheet.contains(document.activeElement))){event.preventDefault();last.focus();}
    else if(!event.shiftKey&&(document.activeElement===last||document.activeElement===sheet||!sheet.contains(document.activeElement))){event.preventDefault();first.focus();}
  });
  document.addEventListener('click',event=>{
    const button=event.target.closest('[data-review]');if(!button)return;
    if(button.dataset.review==='reset'){
      places=structuredClone(seeds);addedTags=[];emptyPlaces=[];view.empty=false;view.offline=false;view.locationDenied=false;view.query='';view.tag='全部';view.page='food';view.mode='map';
      ['empty-state','offline-state','location-state'].forEach(id=>{$('#'+id).checked=false;});const persisted=saveData();closeSheet();render();toast(persisted?'演示收藏已重置':storageFailure);
    }else{view.dark=button.dataset.review==='dark';document.querySelectorAll('[data-review="light"],[data-review="dark"]').forEach(b=>b.setAttribute('aria-pressed',String((b.dataset.review==='dark')===view.dark)));render();}
  });
  $('#large-text').addEventListener('change',event=>{view.large=event.target.checked;render();});
  $('#empty-state').addEventListener('change',event=>{closeSheet();view.empty=event.target.checked;view.query='';view.tag='全部';render();});
  $('#offline-state').addEventListener('change',event=>{view.offline=event.target.checked;render();if(modal==='add-input')addInput();else if(modal==='navigate')navigate();});
  $('#location-state').addEventListener('change',event=>{view.locationDenied=event.target.checked;render();});
  render();
})();
