(function () {
  'use strict';

  const TODAY = '2026-10-16';
  const STAGES = ['待了解', '沟通中', '方案/报价', '成交', '失单'];
  const original = JSON.parse(JSON.stringify(window.CRM_DEMO));
  let data = JSON.parse(JSON.stringify(original));
  const screen = document.getElementById('screen');
  const navigation = document.getElementById('navigation');
  const phone = document.querySelector('#phone');
  const dialog = document.getElementById('sheet');
  const sheetContent = document.getElementById('sheet-content');
  const toastElement = document.getElementById('toast');
  const states = Object.create(null);
  let route = '';
  let trail = [];
  let sheetData = null;
  let toastTimer;
  let imageUrls = [];

  const $ = (selector, base = document) => base.querySelector(selector);
  const esc = value => String(value == null ? '' : value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const find = (kind, id) => data[kind].find(item => item.id === id);
  const uid = prefix => prefix + '-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 7);
  const currentState = () => states[route] || (states[route] = { scroll: 0, search: '', filter: 'all' });
  const datePart = value => value ? String(value).slice(0, 10) : '';
  const dateLabel = value => {
    if (!value) return '时间待确认';
    const date = datePart(value);
    if (date === TODAY) return '今天 · 10月16日';
    if (date === '2026-10-15') return '昨天 · 10月15日';
    return Number(date.slice(5, 7)) + '月' + Number(date.slice(8, 10)) + '日';
  };
  const timeLabel = value => value && value.includes('T') ? value.slice(11, 16) : '';
  const fullDate = value => value ? dateLabel(value) + (timeLabel(value) ? ' ' + timeLabel(value) : '') : '未设定日期';
  const dueLabel = value => value ? (datePart(value) < TODAY ? '已逾期 · ' : '') + dateLabel(value) : '未设期限';
  const money = item => item.amount == null || item.amount === '' ? '金额未定' : (item.currency === 'CNY' ? '¥' : (item.currency || '') + ' ') + Number(item.amount).toLocaleString('zh-CN');

  const paths = {
    back: '<path d="m14 5-7 7 7 7"/>',
    chevron: '<path d="m9 5 7 7-7 7"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    more: '<circle cx="5" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/>',
    close: '<path d="m6 6 12 12M18 6 6 18"/>',
    search: '<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 4 4"/>',
    company: '<rect x="5" y="3" width="14" height="18" rx="1"/><path d="M9 7h1m4 0h1M9 11h1m4 0h1M9 15h1m4 0h1M10 21v-3h4v3"/>',
    customer: '<circle cx="12" cy="8" r="4"/><path d="M5 21v-2a7 7 0 0 1 14 0v2"/>',
    opportunity: '<rect x="3" y="7" width="18" height="14" rx="2"/><path d="M8 7V5a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2M3 12a22 22 0 0 0 18 0M10 12h4v3h-4z"/>',
    task: '<rect x="4" y="3" width="16" height="18" rx="2"/><path d="m8 9 2 2 5-5M8 16h8"/>',
    calendar: '<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M7 3v4m10-4v4M3 11h18M7 15h2m4 0h2m-8 3h2"/>',
    communication: '<path d="M21 11a8 8 0 0 1-8 8H7l-5 3 2-6a8 8 0 0 1-1-5 9 9 0 0 1 18 0Z"/><path d="M7 10h10M7 14h7"/>',
    album: '<rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8" cy="8" r="1.5"/><path d="m3 17 6-6 4 4 3-3 5 5"/>',
    check: '<path d="m5 12 4 4L19 6"/>',
    unchecked: '<circle cx="12" cy="12" r="9"/>',
    checked: '<circle cx="12" cy="12" r="9"/><path d="m7 12 3 3 7-7"/>',
    link: '<path d="m10 13 4-4m-6 6-2 2a4 4 0 0 1-6-6l4-4a4 4 0 0 1 6 0m4 2 2-2a4 4 0 0 1 6 6l-4 4a4 4 0 0 1-6 0" transform="translate(1 0)"/>',
    clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    edit: '<path d="m15 4 5 5M4 16 16 4a2 2 0 0 1 3 3L7 19l-4 1z"/>',
    document: '<path d="M14 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9zM14 3v6h6M8 13h8M8 17h6"/>',
    photo: '<rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8" cy="8" r="1.5"/><path d="m3 17 6-6 4 4 3-3 5 5"/>',
    phone: '<path d="M21 16v3a2 2 0 0 1-2 2A18 18 0 0 1 3 5a2 2 0 0 1 2-2h3l2 5-3 2a14 14 0 0 0 7 7l2-3z"/>',
    mail: '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="m3 6 9 7 9-7"/>',
    sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2m0 16v2M2 12h2m16 0h2M5 5l1 1m12 12 1 1M5 19l1-1M18 6l1-1"/>',
    arrow: '<path d="M5 12h14m-5-5 5 5-5 5"/>',
    location: '<path d="M19 9c0 5-7 12-7 12S5 14 5 9a7 7 0 0 1 14 0Z"/><circle cx="12" cy="9" r="2"/>',
    restore: '<path d="M3 10a9 9 0 1 1 2 8M3 4v6h6M12 7v5l3 2"/>'
  };
  function icon(name, extra = '') {
    return '<svg class="icon ' + extra + '" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + (paths[name] || paths.document) + '</svg>';
  }
  function navButton(action, name, label, attributes = '') {
    return '<button class="icon-button" data-action="' + action + '" aria-label="' + esc(label) + '" ' + attributes + '>' + icon(name) + '</button>';
  }
  function header(title, options = {}) {
    navigation.innerHTML = '<button class="back-button" data-action="back" aria-label="' + (route === 'home' ? '返回拓展' : '返回上一页') + '">' + icon('back') + '<span>' + (route === 'home' ? '拓展' : '返回') + '</span></button><div class="nav-title">' + esc(title) + '</div><div class="nav-actions">' + (options.actions || '') + '</div>';
    const reviewCurrent = document.getElementById('review-current');
    if (reviewCurrent) reviewCurrent.textContent = title;
  }
  function row(title, meta, destination, name = '', trailing = '') {
    return '<button class="list-row" data-route="' + esc(destination) + '">' + (name ? '<span class="row-icon">' + icon(name) + '</span>' : '') + '<span class="row-main"><span class="row-title">' + esc(title) + '</span>' + (meta ? '<span class="row-meta">' + esc(meta) + '</span>' : '') + '</span><span class="row-trailing">' + (trailing ? '<span>' + esc(trailing) + '</span>' : '') + icon('chevron', 'chevron') + '</span></button>';
  }
  function section(title, action = '') {
    return '<div class="section-header"><h2>' + esc(title) + '</h2>' + action + '</div>';
  }
  function actionText(text, action, attrs = '') {
    return '<button class="text-button" data-action="' + action + '" ' + attrs + '>' + esc(text) + '</button>';
  }
  function empty(text, action = '') {
    return '<div class="empty-state"><p>' + esc(text) + '</p>' + action + '</div>';
  }
  function property(label, value, destination = '') {
    const content = '<span class="property-label">' + esc(label) + '</span><span class="property-value">' + esc(value) + (destination ? icon('chevron', 'chevron') : '') + '</span>';
    return destination ? '<button class="property-row" data-route="' + esc(destination) + '">' + content + '</button>' : '<div class="property-row">' + content + '</div>';
  }
  function companyName(id) { return find('companies', id)?.name || '独立客户'; }
  function customerNames(ids) { return (ids || []).map(id => find('customers', id)?.name).filter(Boolean).join('、'); }
  function ctxFrom(type, id) {
    if (type === 'customer') {
      const customer = find('customers', id);
      return { companyId: customer?.companyId || '', customerIds: [id], opportunityId: '', type, id };
    }
    if (type === 'opportunity') {
      const item = find('opportunities', id);
      return { companyId: item?.companyId || '', customerIds: item?.customerIds || [], opportunityId: id, type, id };
    }
    if (type === 'company') return { companyId: id, customerIds: [], opportunityId: '', type, id };
    return { companyId: '', customerIds: [], opportunityId: '', type: type === 'crm' ? 'crm' : 'all', id: '' };
  }
  function ctxOf(item) {
    if (item?.opportunityId) return ctxFrom('opportunity', item.opportunityId);
    if (item?.customerIds?.length) return ctxFrom('customer', item.customerIds[0]);
    if (item?.companyId) return ctxFrom('company', item.companyId);
    return ctxFrom('all', '');
  }
  function ctxRoute(ctx) { return ['all', 'crm'].includes(ctx.type) ? 'home' : ctx.type + ':' + ctx.id; }
  function ctxName(ctx) {
    if (ctx.type === 'customer') return find('customers', ctx.id)?.name || '客户';
    if (ctx.type === 'opportunity') return find('opportunities', ctx.id)?.title || '商机';
    if (ctx.type === 'company') return companyName(ctx.id);
    return ctx.type === 'crm' ? 'CRM 相关' : '全部个人事项';
  }
  function hasBusinessContext(item) { return Boolean(item.companyId || item.opportunityId || item.customerIds?.length); }
  function matches(item, ctx) {
    if (ctx.type === 'crm') return hasBusinessContext(item);
    if (ctx.type === 'customer') return (item.customerIds || []).includes(ctx.id);
    if (ctx.type === 'opportunity') return item.opportunityId === ctx.id;
    if (ctx.type === 'company') return item.companyId === ctx.id || find('opportunities', item.opportunityId)?.companyId === ctx.id;
    return true;
  }
  function routeCtx() {
    const parts = route.split(':');
    if (['tasks', 'calendar', 'communications', 'album'].includes(parts[0]) || route === 'timeline:crm') return listContext();
    if (parts[0] === 'timeline') return ctxFrom(parts[1], parts[2]);
    if (['company', 'customer', 'opportunity'].includes(parts[0])) return ctxFrom(parts[0], parts[1]);
    if (['activity', 'minutes'].includes(parts[0])) return ctxOf(find('activities', parts[1]));
    if (parts[0] === 'task') return ctxOf(find('tasks', parts[1]));
    if (parts[0] === 'event') return ctxOf(find('events', parts[1]));
    return ctxFrom('crm', '');
  }
  function listContext() {
    const scope = currentState().scope || route.split(':').slice(1).join(':') || 'crm';
    const [type, id] = scope.split(':');
    return ctxFrom(type, id);
  }
  function scopeKey(ctx) { return ['all', 'crm'].includes(ctx.type) ? ctx.type : ctx.type + ':' + ctx.id; }
  function scopedRoute(kind, ctx) { return kind + ':' + scopeKey(ctx); }
  function scopePicker(ctx, personal = false) {
    const options = [['crm', 'CRM 相关']];
    if (personal) options.push(['all', '全部个人待办']);
    options.push(...data.companies.map(item => ['company:' + item.id, item.name]),
      ...data.customers.map(item => ['customer:' + item.id, item.name]),
      ...data.opportunities.map(item => ['opportunity:' + item.id, item.title]));
    return '<label class="list-filter scope-picker">范围<select data-scope aria-label="展示范围">' + options.map(([value, title]) => '<option value="' + esc(value) + '" ' + (value === scopeKey(ctx) ? 'selected' : '') + '>' + esc(title) + '</option>').join('') + '</select></label>';
  }
  function contextCopy(ctx) {
    return { companyId: ctx.companyId || '', customerIds: [...ctx.customerIds], opportunityId: ctx.opportunityId || '' };
  }
  function entityIdentity(type, item) {
    const customer = type === 'customer';
    const title = customer || type === 'company' ? item.name : item.title;
    const subtitle = customer ? [item.title, companyName(item.companyId)].filter(Boolean).join(' · ') : type === 'company' ? item.industry : companyName(item.companyId);
    return '<div class="identity"><div class="avatar ' + (customer ? '' : 'entity-avatar') + '">' + (customer ? esc(item.name.slice(-2)) : icon(type)) + '</div><div class="identity-copy"><h1 class="identity-title">' + esc(title) + '</h1><p class="identity-subtitle">' + esc(subtitle || '') + '</p>' + (customer ? '<div class="identity-tags">' + (item.tags || []).map(tag => '<span>' + esc(tag) + '</span>').join('') + '</div>' : '') + '</div></div>';
  }
  function segmented(ctx, active) {
    return '<div class="segmented" aria-label="详情内容"><button class="' + (active === 'overview' ? 'active' : '') + '" data-route="' + esc(ctxRoute(ctx)) + '" aria-pressed="' + (active === 'overview') + '">概览</button><button class="' + (active === 'timeline' ? 'active' : '') + '" data-route="timeline:' + ctx.type + ':' + ctx.id + '" aria-pressed="' + (active === 'timeline') + '">往来</button></div>';
  }
  function taskRows(tasks) {
    return '<div class="list">' + tasks.map(task => '<div class="task-row ' + (task.completed ? 'task-completed' : '') + '"><button class="check-button" data-action="toggle-task" data-id="' + esc(task.id) + '" role="checkbox" aria-checked="' + Boolean(task.completed) + '" aria-label="' + esc((task.completed ? '标为未完成：' : '完成：') + task.title) + '">' + icon(task.completed ? 'checked' : 'unchecked') + '</button><button class="task-main" data-route="task:' + esc(task.id) + '"><span class="row-title">' + esc(task.title) + '</span><span class="row-meta">' + esc((task.completed ? '已完成' : dueLabel(task.due)) + ' · ' + task.source) + '</span></button>' + icon('chevron', 'chevron') + '</div>').join('') + '</div>';
  }
  function upcoming(ctx) {
    const tasks = data.tasks.filter(item => matches(item, ctx) && !item.completed).sort((a, b) => (a.due || 'z').localeCompare(b.due || 'z'));
    const events = data.events.filter(item => matches(item, ctx) && datePart(item.start) >= TODAY).sort((a, b) => a.start.localeCompare(b.start));
    const actions = '<div class="section-actions"><button class="text-button" data-route="' + esc(scopedRoute('tasks', ctx)) + '">全部待办</button>' + actionText('新建跟进', 'new-task') + '</div>';
    return section('下一步', actions) + (tasks.length ? taskRows(tasks.slice(0, 3)) : empty('暂无待跟进事项', actionText('添加一个跟进任务', 'new-task'))) + (events.length ? section('将来安排', '<button class="text-button" data-route="' + esc(scopedRoute('calendar', ctx)) + '">查看全部</button>') + '<div class="list">' + events.slice(0, 2).map(item => row(item.title, fullDate(item.start) + ' · ' + item.source, 'event:' + item.id, 'calendar')).join('') + '</div>' : '');
  }
  function timelineItems(ctx, filter = 'all') {
    let items = data.activities.filter(item => matches(item, ctx));
    if (filter === 'communication') items = items.filter(item => item.type !== 'photo');
    if (filter === 'images') items = items.filter(item => item.images?.length);
    return items.sort((a, b) => (b.occurredAt || '').localeCompare(a.occurredAt || '') || a.id.localeCompare(b.id));
  }
  function activityType(item) { return item.type === 'meeting' ? '会议纪要' : item.type === 'photo' ? '图片往来' : '手工沟通'; }
  function timelineHTML(ctx, filter = 'all', limit = 0, query = '') {
    let items = timelineItems(ctx, filter);
    if (query) items = items.filter(item => [item.title, item.summary, item.body].join(' ').toLowerCase().includes(query.toLowerCase()));
    if (limit) items = items.slice(0, limit);
    if (!items.length) return empty(filter === 'images' ? '还没有图片往来' : '暂无往来记录', actionText(filter === 'images' ? '添加图片' : '添加沟通', filter === 'images' ? 'add-images' : 'add-communication'));
    let previousDate = null;
    return items.map(item => {
      const date = datePart(item.occurredAt);
      const heading = date !== previousDate ? '<h3 class="date-heading">' + esc(dateLabel(item.occurredAt)) + '</h3>' : '';
      previousDate = date;
      return heading + '<article class="timeline-entry"><div class="timeline-rail">' + icon(item.type === 'photo' ? 'photo' : item.type === 'meeting' ? 'document' : 'communication') + '</div><div class="timeline-body"><button class="entry-open" data-route="activity:' + esc(item.id) + '"><span class="entry-meta">' + esc([activityType(item), timeLabel(item.occurredAt)].filter(Boolean).join(' · ')) + '</span><span class="entry-title">' + esc(item.title) + '</span><span class="entry-excerpt">' + esc(item.summary || item.body || '') + '</span></button>' + (item.images?.length ? '<div class="entry-images">' + item.images.slice(0, 3).map((image, index) => '<button class="image-thumb" data-action="preview-image" data-id="' + esc(item.id) + '" data-index="' + index + '" aria-label="查看图片：' + esc(image.alt) + '"><img src="' + esc(image.src) + '" alt="' + esc(image.alt) + '" loading="lazy"></button>').join('') + '</div>' : '') + '<div class="entry-meta scope-label">' + esc(customerNames(item.customerIds) || companyName(item.companyId)) + (item.opportunityId ? ' · ' + esc(find('opportunities', item.opportunityId)?.title || '') : '') + '</div></div></article>';
    }).join('');
  }
  function timelineFilters() {
    const filter = currentState().filter;
    return '<div class="segmented timeline-filters" aria-label="往来类型">' + [['all', '全部'], ['communication', '沟通'], ['images', '图片']].map(([key, title]) => '<button data-action="timeline-filter" data-value="' + key + '" class="' + (filter === key ? 'active' : '') + '" aria-pressed="' + (filter === key) + '">' + title + '</button>').join('') + '</div>';
  }

  function renderHome() {
    header('CRM', { actions: navButton('new-menu', 'plus', '新增 CRM 内容') });
    const modules = [
      ['company', '公司', 'companies', data.companies.length], ['customer', '客户', 'customers', data.customers.length],
      ['opportunity', '商机', 'opportunities', data.opportunities.length]
    ];
    const ctx = ctxFrom('crm');
    const dueTasks = data.tasks.filter(item => matches(item, ctx) && !item.completed).sort((a, b) => (a.due || 'z').localeCompare(b.due || 'z')).slice(0, 3);
    const nextEvent = data.events.filter(item => matches(item, ctx) && datePart(item.start) >= TODAY).sort((a, b) => a.start.localeCompare(b.start))[0];
    screen.innerHTML = '<div class="page-intro"><p class="home-date">10月16日 星期五</p><h1 class="page-title">客户管理</h1><p class="subtitle">客户、商机与下一步</p></div><div class="module-grid">' + modules.map(([name, title, destination, count]) => '<button class="module-button" data-route="' + destination + '"><span class="module-icon">' + icon(name) + '</span><span class="module-name">' + title + '</span><span class="module-count">' + count + '</span></button>').join('') + '</div>' + section('待跟进', '<button class="text-button" data-route="tasks:crm">查看全部</button>') + (dueTasks.length ? taskRows(dueTasks) : empty('当前没有待跟进任务')) + (nextEvent ? section('下一次约见', '<button class="text-button" data-route="calendar:crm">查看全部</button>') + '<div class="list">' + row(nextEvent.title, fullDate(nextEvent.start) + ' · ' + customerNames(nextEvent.customerIds), 'event:' + nextEvent.id, 'calendar') + '</div>' : '') + section('最近往来', '<button class="text-button" data-route="timeline:crm">查看全部</button>') + timelineHTML(ctx, 'all', 2);
  }
  function renderExtensions() {
    header('拓展');
    screen.innerHTML = '<div class="page-intro"><h1 class="page-title">拓展</h1></div><div class="list">' + row('CRM · 客户管理', '公司、客户、商机与往来', 'home', 'customer') + '</div>';
  }
  function renderCustomer(item) {
    if (!item) return renderMissing();
    const ctx = ctxFrom('customer', item.id);
    header('客户详情', { actions: navButton('entity-menu', 'more', '客户操作', 'data-type="customer" data-id="' + item.id + '"') });
    const opportunities = data.opportunities.filter(o => o.customerIds.includes(item.id));
    const recent = timelineItems(ctx, 'communication').find(a => a.occurredAt);
    screen.innerHTML = entityIdentity('customer', item) + '<div class="identity-actions"><button class="secondary-button" data-action="contact" data-id="' + item.id + '">' + icon('link') + '通讯录资料</button><button class="secondary-button" data-action="add-communication">' + icon('communication') + '添加沟通</button></div>' + segmented(ctx, 'overview') + upcoming(ctx) + section('关联商机', actionText('新建', 'new-opportunity')) + (opportunities.length ? '<div class="list">' + opportunities.map(o => row(o.title, o.stage + ' · ' + money(o), 'opportunity:' + o.id, 'opportunity')).join('') + '</div>' : empty('暂无关联商机')) + section('最近往来', '<button class="text-button" data-route="timeline:customer:' + item.id + '">查看全部</button>') + timelineHTML(ctx, 'all', 2) + section('基本资料') + '<div class="property-list">' + (item.companyId ? property('当前公司', companyName(item.companyId), 'company:' + item.companyId) : property('当前公司', '未关联公司')) + property('电话', item.phone || '未填写') + property('邮箱', item.email || '未填写') + property('最近联系', recent ? fullDate(recent.occurredAt) : '暂无明确时间的沟通') + '</div>' + (item.notes ? '<p class="note-text">' + esc(item.notes) + '</p>' : '');
  }
  function renderCompany(item) {
    if (!item) return renderMissing();
    const ctx = ctxFrom('company', item.id);
    header('公司详情', { actions: navButton('entity-menu', 'more', '公司操作', 'data-type="company" data-id="' + item.id + '"') });
    const customers = data.customers.filter(c => c.companyId === item.id);
    const opportunities = data.opportunities.filter(o => o.companyId === item.id);
    screen.innerHTML = entityIdentity('company', item) + segmented(ctx, 'overview') + '<div class="property-list">' + property('行业', item.industry || '未填写') + property('网站', item.website || '未填写') + '</div>' + (item.notes ? '<p class="note-text">' + esc(item.notes) + '</p>' : '') + section('联系人', actionText('新建客户', 'new-customer')) + '<div class="list">' + customers.map(c => row(c.name, c.title || '客户', 'customer:' + c.id, 'customer')).join('') + '</div>' + section('商机', actionText('新建', 'new-opportunity')) + '<div class="list">' + opportunities.map(o => row(o.title, o.stage + ' · ' + money(o), 'opportunity:' + o.id, 'opportunity')).join('') + '</div>' + upcoming(ctx) + section('最近往来', '<button class="text-button" data-route="timeline:company:' + item.id + '">查看全部</button>') + timelineHTML(ctx, 'all', 2);
  }
  function renderOpportunity(item) {
    if (!item) return renderMissing();
    const ctx = ctxFrom('opportunity', item.id);
    header('商机详情', { actions: navButton('entity-menu', 'more', '商机操作', 'data-type="opportunity" data-id="' + item.id + '"') });
    const index = STAGES.indexOf(item.stage);
    screen.innerHTML = entityIdentity('opportunity', item) + '<div class="section-header stage-header"><h2>当前阶段 · ' + esc(item.stage) + '</h2>' + actionText('更新阶段', 'update-stage', 'data-id="' + item.id + '"') + '</div><div class="stage-track" aria-label="商机阶段：' + esc(item.stage) + '">' + STAGES.slice(0, 4).map((stage, stageIndex) => '<div class="stage-step ' + (index >= stageIndex && index < 4 ? 'active' : '') + '" ' + (item.stage === stage ? 'aria-current="step"' : '') + '><small>' + esc(stage) + '</small></div>').join('') + '</div>' + segmented(ctx, 'overview') + upcoming(ctx) + section('最近往来', '<button class="text-button" data-route="timeline:opportunity:' + item.id + '">查看全部</button>') + timelineHTML(ctx, 'all', 2) + '<div class="identity-actions"><button class="secondary-button" data-action="add-communication">' + icon('communication') + '添加沟通</button><button class="secondary-button" data-action="add-images">' + icon('photo') + '添加图片</button></div>' + section('商机资料') + '<div class="property-list">' + (item.companyId ? property('公司', companyName(item.companyId), 'company:' + item.companyId) : '') + property('金额', money(item)) + property('预计日期', item.expectedDate ? dateLabel(item.expectedDate) : '未设定') + '</div>' + section('需求摘要') + '<p class="body-text">' + esc(item.summary || '暂未填写需求摘要') + '</p>' + section('参与客户') + '<div class="list">' + item.customerIds.map(id => find('customers', id)).filter(Boolean).map(c => row(c.name, c.title || '', 'customer:' + c.id, 'customer')).join('') + '</div>';
  }
  function renderTimeline(ctx) {
    if (ctx.type === 'crm') {
      header('往来', { actions: navButton('timeline-menu', 'plus', '添加往来') });
      const scope = listContext();
      screen.innerHTML = '<div class="page-intro"><h1 class="page-title">往来</h1><p class="subtitle">沟通、会议纪要和图片资料</p></div>' + scopePicker(scope) + timelineFilters() + '<div class="timeline-group">' + timelineHTML(scope, currentState().filter) + '</div>';
      return;
    }
    const item = ctx.type === 'customer' ? find('customers', ctx.id) : ctx.type === 'company' ? find('companies', ctx.id) : find('opportunities', ctx.id);
    if (!item) return renderMissing();
    header('往来时间轴', { actions: navButton('timeline-menu', 'plus', '添加往来') });
    screen.innerHTML = entityIdentity(ctx.type, item) + segmented(ctx, 'timeline') + timelineFilters() + '<p class="status-note">按实际往来时间排列，未来安排显示在概览中</p><div class="timeline-group">' + timelineHTML(ctx, currentState().filter) + '</div>';
  }
  function searchBox(placeholder) {
    return '<label class="search-field">' + icon('search') + '<input type="search" data-search placeholder="' + esc(placeholder) + '" aria-label="' + esc(placeholder) + '" value="' + esc(currentState().search) + '"></label>';
  }
  function renderList(kind) {
    const labels = { companies: ['公司', 'company'], customers: ['客户', 'customer'], opportunities: ['商机', 'opportunity'] };
    const [title, type] = labels[kind];
    header(title, { actions: navButton('new-' + type, 'plus', '新建' + title) });
    const query = currentState().search.toLowerCase();
    let items = data[kind].filter(item => !item.archived && [item.name, item.title, item.phone, item.email, item.summary, item.notes].join(' ').toLowerCase().includes(query));
    if (kind === 'opportunities' && currentState().filter !== 'all') items = items.filter(item => item.stage === currentState().filter);
    screen.innerHTML = '<div class="page-intro"><h1 class="page-title">' + title + '</h1><p class="subtitle">' + data[kind].filter(item => !item.archived).length + ' 个' + title + '</p></div>' + searchBox('搜索' + title + (kind === 'customers' ? '或联系方式' : '名称')) + (kind === 'opportunities' ? '<label class="list-filter">阶段<select data-action="opportunity-filter" aria-label="按商机阶段筛选"><option value="all">全部阶段</option>' + STAGES.map(stage => '<option value="' + esc(stage) + '" ' + (currentState().filter === stage ? 'selected' : '') + '>' + stage + '</option>').join('') + '</select></label>' : '') + '<div class="list" id="search-results">' + (items.length ? items.map(item => row(item.name || item.title, kind === 'companies' ? item.industry : kind === 'customers' ? [item.title, companyName(item.companyId)].filter(Boolean).join(' · ') : [companyName(item.companyId), item.stage, money(item)].join(' · '), type + ':' + item.id, type)).join('') : empty('没有匹配的' + title)) + '</div>';
  }
  function renderTasks() {
    header('待办', { actions: navButton('new-task', 'plus', '新建待办') });
    const ctx = listContext();
    const filter = currentState().filter;
    const query = currentState().search.toLowerCase();
    const tasks = data.tasks.filter(task => matches(task, ctx) && (filter === 'completed' ? task.completed : !task.completed) && [task.title, task.notes].join(' ').toLowerCase().includes(query)).sort((a, b) => (a.due || 'z').localeCompare(b.due || 'z'));
    screen.innerHTML = '<div class="page-intro"><h1 class="page-title">待办</h1><p class="subtitle">' + esc(ctx.type === 'all' ? '个人事项与客户跟进' : ctxName(ctx) + '的跟进事项') + '</p></div>' + scopePicker(ctx, true) + searchBox('搜索待办') + '<div class="segmented" aria-label="完成状态"><button data-action="task-filter" data-value="all" class="' + (filter !== 'completed' ? 'active' : '') + '" aria-pressed="' + (filter !== 'completed') + '">待完成</button><button data-action="task-filter" data-value="completed" class="' + (filter === 'completed' ? 'active' : '') + '" aria-pressed="' + (filter === 'completed') + '">已完成</button></div>' + (tasks.length ? taskRows(tasks) : empty(query ? '没有匹配的待办' : filter === 'completed' ? '当前范围没有已完成待办' : '当前范围没有待完成事项'));
  }
  function renderTask(task) {
    if (!task) return renderMissing();
    header('待办详情', { actions: navButton('edit-task', 'edit', '编辑待办', 'data-id="' + task.id + '"') });
    screen.innerHTML = '<div class="page-intro"><p class="eyebrow">' + esc(task.source) + '</p><h1 class="page-title">' + esc(task.title) + '</h1></div><div class="property-list">' + property('期限', task.due ? fullDate(task.due) : '未设期限') + property('状态', task.completed ? '已完成' : '待完成') + '</div>' + (task.notes ? '<p class="body-text">' + esc(task.notes) + '</p>' : '') + relatedContext(task) + '<button class="primary-button" data-action="toggle-task" data-id="' + esc(task.id) + '">' + icon('check') + (task.completed ? '标为未完成' : '完成任务') + '</button><p class="status-note">CRM 与 Yima 待办引用同一个事项。</p>';
  }
  function renderCalendar() {
    header('日历', { actions: navButton('new-event', 'plus', '新建日程') });
    const ctx = listContext();
    const selected = currentState().day || '';
    const weekNames = ['五', '六', '日', '一', '二', '三', '四'];
    const events = data.events.filter(event => matches(event, ctx) && (!selected || datePart(event.start) === selected)).sort((a, b) => a.start.localeCompare(b.start));
    screen.innerHTML = '<div class="page-intro"><h1 class="page-title">日历</h1><p class="subtitle">关联的日程与会议</p></div>' + scopePicker(ctx) + '<div class="section-header"><h2>2026年10月</h2>' + actionText('全部日程', 'calendar-day', 'data-day=""') + '</div><div class="calendar-strip">' + weekNames.map((name, index) => {
      const date = '2026-10-' + (16 + index);
      const count = data.events.filter(item => matches(item, ctx) && datePart(item.start) === date).length;
      return '<button class="calendar-day ' + (selected === date ? 'active' : '') + '" data-action="calendar-day" data-day="' + date + '" aria-label="10月' + (16 + index) + '日，' + count + '个日程" aria-pressed="' + (selected === date) + '"><span>' + name + '</span><strong>' + (16 + index) + '</strong><i class="' + (count ? 'event-dot' : '') + '"></i></button>';
    }).join('') + '</div>' + section(selected ? dateLabel(selected) : '日程安排') + (events.length ? '<div class="list">' + events.map(event => row(event.title, fullDate(event.start) + '–' + timeLabel(event.end) + ' · ' + event.source, 'event:' + event.id, 'calendar')).join('') + '</div>' : empty('这一天没有关联日程', actionText('新建日程', 'new-event')));
  }
  function renderEvent(event) {
    if (!event) return renderMissing();
    header('日程详情', { actions: navButton('edit-event', 'edit', '编辑日程', 'data-id="' + event.id + '"') });
    screen.innerHTML = '<div class="page-intro"><p class="eyebrow">' + esc(event.source) + '</p><h1 class="page-title">' + esc(event.title) + '</h1></div><div class="property-list">' + property('开始', fullDate(event.start)) + property('结束', fullDate(event.end)) + property('地点', event.location || '未填写') + '</div>' + (event.notes ? '<p class="body-text">' + esc(event.notes) + '</p>' : '') + relatedContext(event) + '<p class="status-note">计划日程不代表实际沟通已发生。</p>';
  }
  function renderCommunications() {
    header('沟通', { actions: navButton('add-communication', 'plus', '添加沟通') });
    const ctx = listContext();
    screen.innerHTML = '<div class="page-intro"><h1 class="page-title">沟通</h1><p class="subtitle">会议纪要与手工沟通记录</p></div>' + scopePicker(ctx) + searchBox('搜索沟通内容') + '<div class="timeline-group" id="search-results">' + timelineHTML(ctx, 'communication', 0, currentState().search) + '</div>';
  }
  function renderAlbum() {
    header('相册', { actions: navButton('add-images', 'plus', '添加图片往来') });
    const ctx = listContext();
    screen.innerHTML = '<div class="page-intro"><h1 class="page-title">图片往来</h1><p class="subtitle">按往来日期查看，保留图片与业务归属</p></div>' + scopePicker(ctx) + '<div class="timeline-group">' + timelineHTML(ctx, 'images') + '</div>';
  }
  function relatedContext(item) {
    if (!hasBusinessContext(item)) return '<p class="status-note">个人事项 · 尚未关联客户或商机</p>';
    return section('业务归属') + '<div class="list">' + (item.companyId ? row(companyName(item.companyId), '公司', 'company:' + item.companyId, 'company') : '') + (item.customerIds || []).map(id => find('customers', id)).filter(Boolean).map(customer => row(customer.name, '客户 · ' + (customer.title || ''), 'customer:' + customer.id, 'customer')).join('') + (item.opportunityId ? row(find('opportunities', item.opportunityId)?.title || '来源商机不可用', '商机', 'opportunity:' + item.opportunityId, 'opportunity') : '') + '</div>';
  }
  function renderActivity(item) {
    if (!item) return renderMissing();
    header(item.type === 'photo' ? '图片往来' : '沟通详情', { actions: navButton('activity-menu', 'more', '沟通操作', 'data-id="' + item.id + '"') });
    screen.innerHTML = '<div class="page-intro"><p class="eyebrow">' + activityType(item) + '</p><h1 class="page-title">' + esc(item.title) + '</h1><p class="subtitle">' + esc(fullDate(item.occurredAt)) + '</p></div>' + '<p class="body-text">' + esc(item.body || item.summary || '') + '</p>' + (item.images.length ? '<div class="photo-grid">' + item.images.map((image, index) => '<button class="photo-button" data-action="preview-image" data-id="' + esc(item.id) + '" data-index="' + index + '"><img src="' + esc(image.src) + '" alt="' + esc(image.alt) + '"><span>' + esc(image.caption || image.alt) + '</span></button>').join('') + '</div>' : '') + (item.minutes ? section('所选会议纪要') + '<div class="list">' + row(item.minutes.title, '文稿 ' + item.minutes.revision + ' · ' + fullDate(item.minutes.generatedAt), 'minutes:' + item.id, 'document') + '</div>' : '') + '<div class="property-list">' + property('时间依据', item.timeBasis || '用户确认的沟通时间') + property('添加时间', fullDate(item.addedAt)) + '</div>' + relatedContext(item) + section('后续事项', actionText('新建跟进', 'new-task', 'data-activity-id="' + item.id + '"')) + (data.tasks.some(t => t.activityId === item.id) ? taskRows(data.tasks.filter(t => t.activityId === item.id)) : empty('暂无由本次沟通创建的跟进任务'));
  }
  function renderMinutes(item) {
    if (!item?.minutes) return renderMissing();
    header('会议纪要');
    screen.innerHTML = '<div class="page-intro"><p class="eyebrow">会议资料 · 文稿 ' + esc(item.minutes.revision) + '</p><h1 class="page-title">' + esc(item.minutes.title) + '</h1><p class="subtitle">' + esc(fullDate(item.minutes.generatedAt)) + ' 生成</p></div><div class="property-list">' + property('源录音', item.minutes.recordingTitle) + property('文稿版本', item.minutes.revision) + '</div><div class="content-block body-text">' + esc(item.minutes.body).replace(/\n/g, '<br>') + '</div>' + '<button class="secondary-button" data-action="return-activity" data-id="' + esc(item.id) + '">查看关联沟通</button>';
  }
  function renderMeetings() {
    header('会议资料');
    const meetings = data.activities.filter(item => item.minutes);
    screen.innerHTML = '<div class="page-intro"><h1 class="page-title">会议资料</h1><p class="subtitle">录音来源与已生成的会议纪要</p></div><div class="list">' + meetings.map(item => row(item.minutes.recordingTitle, item.minutes.title + ' · 文稿 ' + item.minutes.revision, 'minutes:' + item.id, 'document')).join('') + '</div>';
  }
  function renderMissing() {
    header('记录不可用');
    screen.innerHTML = empty('这条记录当前不可用', '<button class="primary-button" data-route="home">返回 CRM</button>');
  }
  function render() {
    const parts = route.split(':');
    const renderers = {
      home: renderHome, extensions: renderExtensions,
      companies: () => renderList('companies'), customers: () => renderList('customers'), opportunities: () => renderList('opportunities'),
      company: () => renderCompany(find('companies', parts[1])), customer: () => renderCustomer(find('customers', parts[1])), opportunity: () => renderOpportunity(find('opportunities', parts[1])),
      timeline: () => renderTimeline(ctxFrom(parts[1], parts[2])),
      tasks: renderTasks, task: () => renderTask(find('tasks', parts[1])), calendar: renderCalendar, event: () => renderEvent(find('events', parts[1])),
      communications: renderCommunications, album: renderAlbum, meetings: renderMeetings,
      activity: () => renderActivity(find('activities', parts[1])), minutes: () => renderMinutes(find('activities', parts[1]))
    };
    (renderers[parts[0]] || renderMissing)();
    requestAnimationFrame(() => { screen.scrollTop = currentState().scroll || 0; updateSheetPosition(); });
  }
  function saveScroll() { if (route) currentState().scroll = screen.scrollTop; }
  function navigate(next) {
    const parts = next.split(':');
    const list = ['tasks', 'calendar', 'communications', 'album'].includes(parts[0]) || next === 'timeline:crm';
    const scope = parts.slice(1).join(':') || 'crm';
    const resetScope = list && states[next]?.scope && states[next].scope !== scope;
    if (resetScope) { states[next].scope = scope; states[next].scroll = 0; }
    if (next === route) { closeSheet(); if (resetScope) render(); return; }
    saveScroll();
    closeSheet();
    location.hash = next;
  }
  function routeChanged() {
    saveScroll();
    const next = decodeURIComponent(location.hash.slice(1) || 'home');
    if (trail.length > 1 && next === trail[trail.length - 2]) trail.pop();
    else if (trail[trail.length - 1] !== next) trail.push(next);
    route = next;
    closeSheet();
    render();
  }
  function goBack() {
    if (route === 'home') return navigate('extensions');
    if (route === 'extensions') return navigate('home');
    if (trail.length > 1) history.back();
    else navigate('home');
  }
  function rerender() { saveScroll(); render(); }
  function toast(message) {
    clearTimeout(toastTimer);
    toastElement.textContent = message;
    toastElement.classList.add('visible');
    toastTimer = setTimeout(() => toastElement.classList.remove('visible'), 3000);
  }
  function updateSheetPosition() {
    const rect = phone.getBoundingClientRect();
    document.documentElement.style.setProperty('--phone-left', rect.left + 'px');
    document.documentElement.style.setProperty('--phone-width', rect.width + 'px');
    document.documentElement.style.setProperty('--phone-bottom', rect.bottom + 'px');
  }
  function revealPreview() {
    if (innerWidth <= 780) phone.scrollIntoView({ block: 'start' });
    updateSheetPosition();
  }
  function openSheet(title, content, payload = {}) {
    sheetData = payload;
    sheetContent.innerHTML = '<div class="sheet-header"><h2>' + esc(title) + '</h2>' + navButton('close-sheet', 'close', '关闭') + '</div><div class="sheet-body">' + content + '</div>';
    updateSheetPosition();
    if (!dialog.open) dialog.showModal();
    requestAnimationFrame(() => {
      const first = $('input:not([type="file"]), textarea, select, button', $('.sheet-body', sheetContent));
      if (first) first.focus({ preventScroll: true });
    });
  }
  function closeSheet() {
    if (dialog.open) dialog.close();
    sheetData = null;
  }
  function menuButton(label, name, action, attrs = '') {
    return '<button class="list-row" data-action="' + action + '" ' + attrs + '><span class="row-icon">' + icon(name) + '</span><span class="row-main"><span class="row-title">' + esc(label) + '</span></span>' + icon('chevron', 'chevron') + '</button>';
  }
  function newMenu() {
    openSheet('新增', '<div class="action-list">' + menuButton('公司', 'company', 'new-company') + menuButton('客户', 'customer', 'new-customer') + menuButton('商机', 'opportunity', 'new-opportunity') + menuButton('跟进任务', 'task', 'new-task') + menuButton('日程', 'calendar', 'new-event') + menuButton('沟通记录', 'communication', 'add-communication') + menuButton('图片往来', 'photo', 'add-images') + '</div>');
  }
  function contextOptions(ctx, personal = false) {
    const selected = ctx.type === 'all' && personal ? 'all' : ['all', 'crm'].includes(ctx.type) ? '' : ctx.type + ':' + ctx.id;
    const options = [['', '请选择业务归属']].concat(data.customers.filter(c => !c.archived).map(c => ['customer:' + c.id, c.name + ' · ' + companyName(c.companyId)]), data.opportunities.filter(o => !o.archived).map(o => ['opportunity:' + o.id, o.title + '（商机）']), data.companies.filter(c => !c.archived).map(c => ['company:' + c.id, c.name + '（公司）']));
    if (personal) options.splice(1, 0, ['all', '个人事项（不关联客户）']);
    return '<label class="field"><span>业务归属</span><select name="context" required>' + options.map(([value, label]) => '<option value="' + esc(value) + '" ' + (value === selected ? 'selected' : '') + '>' + esc(label) + '</option>').join('') + '</select></label>';
  }
  function contextFromForm(form) {
    const value = form.get('context') || '';
    const parts = value.split(':');
    return ctxFrom(parts[0], parts[1]);
  }
  function field(label, name, value = '', type = 'text', required = false) {
    return '<label class="field"><span>' + esc(label) + (required ? '<span class="required-mark"> *</span>' : '') + '</span><input name="' + esc(name) + '" type="' + type + '" value="' + esc(value) + '" ' + (required ? 'required' : '') + '></label>';
  }
  function textarea(label, name, value = '', required = false) {
    return '<label class="field"><span>' + esc(label) + '</span><textarea name="' + name + '" rows="4" ' + (required ? 'required' : '') + '>' + esc(value) + '</textarea></label>';
  }
  function saveButton(text = '保存') { return '<p class="form-error" role="alert"></p><button class="primary-button" type="submit">' + esc(text) + '</button>'; }
  function openTask(id = '', activityId = '') {
    const task = find('tasks', id);
    const ctx = task ? ctxOf(task) : routeCtx();
    openSheet(task ? '编辑待办' : ctx.type === 'all' ? '新建待办' : '新建跟进', '<form data-form="task"><p class="status-note">保存到 Yima 待办</p>' + field('任务标题', 'title', task?.title || '', 'text', true) + field('到期日期（可选）', 'due', datePart(task?.due), 'date') + contextOptions(ctx, true) + textarea('补充说明（可选）', 'notes', task?.notes || '') + saveButton(task ? '保存修改' : '保存待办') + '</form>', { id, activityId });
  }
  function openEvent(id = '') {
    const event = find('events', id);
    const ctx = event ? ctxOf(event) : routeCtx();
    openSheet(event ? '编辑日程' : '新建日程', '<form data-form="event"><p class="status-note">保存到 Yima 日历</p>' + field('日程标题', 'title', event?.title || '', 'text', true) + field('开始', 'start', event?.start?.slice(0, 16) || TODAY + 'T10:00', 'datetime-local', true) + field('结束', 'end', event?.end?.slice(0, 16) || TODAY + 'T11:00', 'datetime-local', true) + field('地点（可选）', 'location', event?.location || '') + contextOptions(ctx) + textarea('说明（可选）', 'notes', event?.notes || '') + saveButton(event ? '保存修改' : '保存日程') + '</form>', { id });
  }
  function openEntity(type, id = '') {
    const kind = { company: 'companies', customer: 'customers', opportunity: 'opportunities' }[type];
    const item = find(kind, id);
    const ctx = routeCtx();
    let fields = '';
    if (type === 'company') fields = field('公司名称', 'name', item?.name || '', 'text', true) + field('行业（可选）', 'industry', item?.industry || '') + field('网站（可选）', 'website', item?.website || '') + textarea('备注', 'notes', item?.notes || '');
    if (type === 'customer') fields = field('姓名', 'name', item?.name || '', 'text', true) + field('职位（可选）', 'title', item?.title || '') + field('电话（可选）', 'phone', item?.phone || '', 'tel') + field('邮箱（可选）', 'email', item?.email || '', 'email') + companySelect(item?.companyId || ctx.companyId) + textarea('备注', 'notes', item?.notes || '');
    if (type === 'opportunity') fields = field('商机标题', 'title', item?.title || '', 'text', true) + companySelect(item?.companyId || ctx.companyId) + '<div class="field"><span>参与客户</span>' + data.customers.map(c => '<label class="choice-row"><input type="checkbox" name="customerIds" value="' + esc(c.id) + '" ' + ((item?.customerIds || ctx.customerIds).includes(c.id) ? 'checked' : '') + '><span class="choice-label">' + esc(c.name) + '<small>' + esc(companyName(c.companyId)) + '</small></span></label>').join('') + '</div><label class="field"><span>阶段</span><select name="stage">' + STAGES.map(stage => '<option ' + ((item?.stage || '待了解') === stage ? 'selected' : '') + '>' + stage + '</option>').join('') + '</select></label>' + field('金额 · 人民币（可选）', 'amount', item?.amount ?? '', 'number') + field('预计日期（可选）', 'expectedDate', datePart(item?.expectedDate), 'date') + textarea('需求摘要', 'summary', item?.summary || '');
    const label = { company: '公司', customer: '客户', opportunity: '商机' }[type];
    openSheet((id ? '编辑' : '新建') + label, '<form data-form="entity">' + fields + saveButton() + '</form>', { type, id });
  }
  function companySelect(value) {
    return '<label class="field"><span>公司（可选）</span><select name="companyId"><option value="">未关联公司</option>' + data.companies.map(c => '<option value="' + c.id + '" ' + (value === c.id ? 'selected' : '') + '>' + esc(c.name) + '</option>').join('') + '</select></label>';
  }
  function openCommunicationMenu() {
    openSheet('添加沟通', '<div class="action-list">' + menuButton('关联会议纪要', 'document', 'select-minutes') + menuButton('手工记录沟通', 'edit', 'new-note') + '</div><p class="status-note">选择本次沟通的内容，并在保存前核对业务归属。</p>');
  }
  function openNote() {
    const ctx = routeCtx();
    openSheet('记录沟通', '<form data-form="note">' + field('标题', 'title', '', 'text', true) + textarea('沟通内容', 'body', '', true) + field('发生时间（可选）', 'occurredAt', TODAY + 'T10:00', 'datetime-local') + contextOptions(ctx) + saveButton('核对并保存') + '</form>');
  }
  function selectMinutes() {
    const meetings = data.activities.filter(item => item.minutes);
    openSheet('选择会议纪要', '<p class="status-note">只展示已生成的纪要；选择后核对所选版本及业务归属。</p><div class="action-list">' + meetings.map(item => menuButton(item.minutes.title, 'document', 'confirm-minutes', 'data-id="' + item.id + '"') + '<p class="status-note">' + esc(fullDate(item.occurredAt) + ' · ' + item.minutes.revision) + '</p>').join('') + '</div>');
  }
  function confirmMinutes(id) {
    const item = find('activities', id);
    if (!item?.minutes) return;
    const ctx = routeCtx();
    const selectedCtx = ctx.type === 'all' ? ctxOf(item) : ctx;
    openSheet('核对纪要关联', '<form data-form="minutes"><h3>' + esc(item.minutes.title) + '</h3><div class="property-list">' + property('源录音', item.minutes.recordingTitle) + property('文稿版本', item.minutes.revision) + property('生成时间', fullDate(item.minutes.generatedAt)) + '</div><p class="body-text">' + esc(item.summary) + '</p>' + field('沟通发生时间', 'occurredAt', item.occurredAt?.slice(0, 16) || '', 'datetime-local') + contextOptions(selectedCtx) + '<p class="status-note">已有关联时复用同一条沟通；选择其他商机会更新其主要商机关联。保留所选版本与摘要，不覆盖原纪要。</p>' + saveButton('确认关联') + '</form>', { id });
  }
  function openImages() {
    const ctx = routeCtx();
    openSheet('添加图片往来', '<form data-form="images"><label class="field"><span>从照片或文件选择</span><input type="file" name="images" accept="image/*" multiple required></label><div class="file-status" role="status">尚未选择图片</div><div class="entry-images" id="import-previews"></div>' + field('说明', 'title', '', 'text', true) + field('往来时间（可选）', 'occurredAt', TODAY + 'T10:00', 'datetime-local') + '<p class="status-note">请核对真实往来时间；截图中的沟通可能早于图片拍摄时间。</p>' + contextOptions(ctx) + saveButton('确认添加') + '</form>', { importedImages: [] });
  }
  function previewImage(id, index) {
    const item = find('activities', id);
    if (!item?.images?.[index]) return;
    const image = item.images[index];
    openSheet('图片 ' + (index + 1) + ' / ' + item.images.length, '<img class="preview-image" src="' + esc(image.src) + '" alt="' + esc(image.alt) + '"><p class="body-text">' + esc(image.caption || image.alt) + '</p><p class="status-note">' + esc(item.title + ' · ' + fullDate(item.occurredAt)) + '</p>' + (item.images.length > 1 ? '<div class="identity-actions"><button class="secondary-button" data-action="preview-image" data-id="' + id + '" data-index="' + ((index - 1 + item.images.length) % item.images.length) + '">上一张</button><button class="secondary-button" data-action="preview-image" data-id="' + id + '" data-index="' + ((index + 1) % item.images.length) + '">下一张</button></div>' : '') + '<button class="secondary-button" data-route="activity:' + esc(id) + '">查看图片往来</button>');
  }
  function openContact(id) {
    const item = find('customers', id);
    if (!item) return;
    openSheet('通讯录资料', '<p class="status-note">' + esc(item.contactState || '尚未关联') + '</p><div class="property-list">' + property('姓名', item.name) + property('电话', item.phone || '未填写') + property('邮箱', item.email || '未填写') + property('公司', companyName(item.companyId)) + '</div><p class="body-text">CRM 保存已确认资料；更新前先核对所选联系人字段。</p><button class="primary-button" data-action="confirm-contact" data-id="' + id + '">确认这份资料</button>');
  }
  function openStage(id) {
    const item = find('opportunities', id);
    openSheet('更新商机阶段', '<div class="action-list">' + STAGES.map(stage => '<button class="list-row" data-action="save-stage" data-id="' + id + '" data-stage="' + esc(stage) + '"><span class="row-main"><span class="row-title">' + stage + '</span></span>' + (stage === item.stage ? icon('check') : '') + '</button>').join('') + '</div><p class="status-note">更改阶段不会自动完成跟进任务。</p>');
  }

  document.addEventListener('click', event => {
    const target = event.target.closest('[data-route], [data-action], [data-preview-route]');
    if (!target) return;
    if (target.dataset.previewRoute) { navigate(target.dataset.previewRoute); revealPreview(); return; }
    if (target.dataset.route) return navigate(target.dataset.route);
    const action = target.dataset.action;
    const id = target.dataset.id;
    if (action === 'back') return goBack();
    if (action === 'return-activity') {
      const destination = 'activity:' + id;
      return trail[trail.length - 2] === destination ? goBack() : navigate(destination);
    }
    if (action === 'close-sheet') return closeSheet();
    if (action === 'new-menu') return newMenu();
    if (action === 'new-task') return openTask('', target.dataset.activityId || '');
    if (action === 'edit-task') return openTask(id);
    if (action === 'new-event') return openEvent();
    if (action === 'edit-event') return openEvent(id);
    if (action === 'new-company') return openEntity('company');
    if (action === 'new-customer') return openEntity('customer');
    if (action === 'new-opportunity') return openEntity('opportunity');
    if (action === 'edit-entity') return openEntity(target.dataset.type, id);
    if (action === 'add-communication') return openCommunicationMenu();
    if (action === 'new-note') return openNote();
    if (action === 'select-minutes') return selectMinutes();
    if (action === 'confirm-minutes') return confirmMinutes(id);
    if (action === 'add-images') return openImages();
    if (action === 'preview-image') return previewImage(id, Number(target.dataset.index));
    if (action === 'contact') return openContact(id);
    if (action === 'confirm-contact') {
      find('customers', id).contactState = '已关联 · 资料已核对';
      closeSheet(); rerender(); return toast('通讯录资料已确认');
    }
    if (action === 'update-stage') return openStage(id);
    if (action === 'save-stage') {
      find('opportunities', id).stage = target.dataset.stage;
      closeSheet(); rerender(); return toast('商机阶段已更新为' + target.dataset.stage);
    }
    if (action === 'toggle-task') {
      const task = find('tasks', id);
      task.completed = !task.completed;
      task.completedAt = task.completed ? TODAY + 'T10:30:00+08:00' : '';
      closeSheet(); rerender(); return toast(task.completed ? '任务已完成' : '任务已标为未完成');
    }
    if (action === 'timeline-filter' || action === 'task-filter') {
      currentState().filter = target.dataset.value;
      return rerender();
    }
    if (action === 'calendar-day') {
      currentState().day = target.dataset.day;
      return rerender();
    }
    if (action === 'timeline-menu') return openSheet('添加往来', '<div class="action-list">' + menuButton('添加沟通', 'communication', 'add-communication') + menuButton('添加图片', 'photo', 'add-images') + menuButton('新建跟进', 'task', 'new-task') + '</div>');
    if (action === 'entity-menu') {
      return openSheet('操作', '<div class="action-list">' + menuButton('编辑资料', 'edit', 'edit-entity', 'data-type="' + target.dataset.type + '" data-id="' + id + '"') + menuButton('添加沟通', 'communication', 'add-communication') + menuButton('添加图片', 'photo', 'add-images') + menuButton('新建跟进', 'task', 'new-task') + '</div>');
    }
    if (action === 'activity-menu') return openSheet('沟通操作', '<div class="action-list">' + menuButton('新建跟进任务', 'task', 'new-task', 'data-activity-id="' + id + '"') + '</div>');
  });

  document.addEventListener('input', event => {
    if (!event.target.matches('[data-search]')) return;
    const caret = event.target.selectionStart;
    currentState().search = event.target.value;
    const scroll = screen.scrollTop;
    render();
    const input = $('[data-search]', screen);
    if (input) { input.focus({ preventScroll: true }); input.setSelectionRange(caret, caret); }
    screen.scrollTop = scroll;
  });
  document.addEventListener('change', event => {
    if (event.target.matches('[data-scope]')) {
      currentState().scope = event.target.value;
      currentState().scroll = 0;
      return render();
    }
    if (event.target.matches('[data-action="opportunity-filter"]')) {
      currentState().filter = event.target.value;
      return rerender();
    }
    if (event.target.type !== 'file' || !event.target.closest('[data-form="images"]')) return;
    const files = [...event.target.files];
    const accepted = files.filter(file => file.type.startsWith('image/'));
    sheetData.importedImages = accepted.map(file => {
      const url = URL.createObjectURL(file);
      imageUrls.push(url);
      return { src: url, alt: file.name, caption: file.name };
    });
    $('.file-status', sheetContent).textContent = accepted.length + ' 张图片已选择' + (files.length > accepted.length ? '；' + (files.length - accepted.length) + ' 个文件不是图片' : '');
    $('#import-previews', sheetContent).innerHTML = sheetData.importedImages.map(image => '<span class="image-thumb"><img src="' + esc(image.src) + '" alt="' + esc(image.alt) + '"></span>').join('');
  });
  document.addEventListener('submit', event => {
    const formElement = event.target.closest('[data-form]');
    if (!formElement) return;
    event.preventDefault();
    const form = new FormData(formElement);
    const formType = formElement.dataset.form;
    const payload = sheetData || {};
    const fail = message => { $('.form-error', formElement).textContent = message; };
    let message = '';
    let destination = '';
    if (formType === 'task') {
      const task = find('tasks', payload.id);
      const due = form.get('due') || '';
      const context = task && form.get('context') === ctxRoute(ctxOf(task)) ? contextCopy(task) : contextCopy(contextFromForm(form));
      const fields = { title: String(form.get('title')).trim(), due: task && due === datePart(task.due) ? task.due : due, notes: String(form.get('notes') || '').trim(), ...context };
      if (!fields.title) return fail('请填写任务标题');
      if (task) Object.assign(task, fields);
      else data.tasks.push({ id: uid('task'), ...fields, completed: false, source: 'Yima待办', activityId: payload.activityId || '' });
      message = task ? '跟进任务已更新' : '跟进任务已保存到 Yima 待办';
    }
    if (formType === 'event') {
      const start = String(form.get('start'));
      const end = String(form.get('end'));
      if (end <= start) return fail('结束时间需晚于开始时间');
      const item = find('events', payload.id);
      const context = item && form.get('context') === ctxRoute(ctxOf(item)) ? contextCopy(item) : contextCopy(contextFromForm(form));
      const fields = { title: String(form.get('title')).trim(), start: start + ':00+08:00', end: end + ':00+08:00', location: form.get('location') || '', notes: form.get('notes') || '', ...context };
      if (item) Object.assign(item, fields);
      else data.events.push({ id: uid('event'), ...fields, source: 'Yima日历' });
      message = item ? '日程已更新' : '日程已保存到 Yima 日历';
    }
    if (formType === 'entity') {
      const kind = { company: 'companies', customer: 'customers', opportunity: 'opportunities' }[payload.type];
      const existing = find(kind, payload.id);
      let fields;
      if (payload.type === 'company') fields = { name: String(form.get('name')).trim(), industry: form.get('industry') || '', website: form.get('website') || '', notes: form.get('notes') || '' };
      if (payload.type === 'customer') fields = { name: String(form.get('name')).trim(), title: form.get('title') || '', phone: form.get('phone') || '', email: form.get('email') || '', companyId: form.get('companyId') || '', notes: form.get('notes') || '', tags: existing?.tags || [], contactState: existing?.contactState || '尚未关联通讯录' };
      if (payload.type === 'opportunity') {
        const companyId = form.get('companyId') || '';
        const customerIds = form.getAll('customerIds');
        if (!companyId && !customerIds.length) return fail('请至少关联一家公司或一位客户');
        fields = { title: String(form.get('title')).trim(), companyId, customerIds, stage: form.get('stage'), amount: form.get('amount') === '' ? null : Number(form.get('amount')), currency: 'CNY', expectedDate: form.get('expectedDate') || '', summary: form.get('summary') || '' };
        if (fields.amount !== null && fields.amount < 0) return fail('金额不能小于零');
      }
      if (!(fields.name || fields.title)) return fail('请填写名称');
      const id = existing?.id || uid(payload.type);
      if (existing) Object.assign(existing, fields);
      else data[kind].push({ id, ...fields });
      destination = payload.type + ':' + id;
      message = '资料已保存';
    }
    if (formType === 'note') {
      const title = String(form.get('title')).trim();
      const body = String(form.get('body')).trim();
      if (!title || !body) return fail('请填写沟通标题和内容');
      const occurred = String(form.get('occurredAt') || '');
      const draft = { id: uid('note'), type: 'note', title, body, summary: body, occurredAt: occurred ? occurred + ':00+08:00' : '', addedAt: TODAY + 'T10:30:00+08:00', timeBasis: occurred ? '用户确认的沟通时间' : '时间待确认', images: [], ...contextCopy(contextFromForm(form)) };
      return openSheet('确认沟通记录', '<h3>' + esc(draft.title) + '</h3><p class="body-text">' + esc(draft.body) + '</p><div class="property-list">' + property('发生时间', fullDate(draft.occurredAt)) + property('业务归属', ctxName(ctxOf(draft))) + '</div><form data-form="confirm-note">' + saveButton('确认保存') + '</form>', { draft });
    }
    if (formType === 'confirm-note') {
      data.activities.push(payload.draft);
      message = '沟通记录已保存';
    }
    if (formType === 'minutes') {
      const source = find('activities', payload.id);
      const ctx = contextFromForm(form);
      const occurrence = String(form.get('occurredAt') || '');
      const existing = data.activities.find(item => item.minutes && item.minutes.recordingTitle === source.minutes.recordingTitle && item.minutes.revision === source.minutes.revision && matches(item, ctx));
      if (existing) {
        closeSheet(); navigate('activity:' + existing.id); return toast('所选纪要已关联，已打开沟通记录');
      }
      const next = {
        companyId: ctx.type === 'customer' ? source.companyId || ctx.companyId : ctx.companyId || source.companyId,
        customerIds: [...new Set([...(source.customerIds || []), ...ctx.customerIds])],
        opportunityId: ctx.opportunityId || source.opportunityId
      };
      const conflict = (source.companyId && next.companyId && source.companyId !== next.companyId) || (source.opportunityId && next.opportunityId && source.opportunityId !== next.opportunityId);
      if (conflict) {
        return openSheet('确认调整业务归属', '<h3>' + esc(source.title) + '</h3><div class="property-list">' + property('当前公司', companyName(source.companyId)) + property('调整为公司', companyName(next.companyId)) + property('当前商机', find('opportunities', source.opportunityId)?.title || '未关联') + property('调整为商机', find('opportunities', next.opportunityId)?.title || '未关联') + property('保留参与人', customerNames(next.customerIds)) + '</div><p class="status-note">这条沟通将从原商机移到所选商机；已有客户关联保留。原会议纪要不受影响。</p><form data-form="confirm-minutes-change">' + saveButton('确认调整') + '</form>', { id: source.id, next, occurredAt: occurrence ? occurrence + ':00+08:00' : '' });
      }
      Object.assign(source, next, { occurredAt: occurrence ? occurrence + ':00+08:00' : '' });
      message = '会议纪要关联已更新，已有参与人保留';
    }
    if (formType === 'confirm-minutes-change') {
      Object.assign(find('activities', payload.id), payload.next, { occurredAt: payload.occurredAt });
      message = '会议纪要的业务归属已调整';
    }
    if (formType === 'images') {
      if (!payload.importedImages?.length) return fail('请选择至少一张可用图片');
      const title = String(form.get('title')).trim();
      if (!title) return fail('请填写这组图片的说明');
      const occurred = String(form.get('occurredAt') || '');
      data.activities.push({ id: uid('photo'), type: 'photo', title, summary: title, body: title, occurredAt: occurred ? occurred + ':00+08:00' : '', addedAt: TODAY + 'T10:30:00+08:00', timeBasis: occurred ? '用户确认的往来时间' : '时间待确认 · 添加于10月16日', images: payload.importedImages, ...contextCopy(contextFromForm(form)) });
      message = payload.importedImages.length + ' 张图片已加入往来';
    }
    closeSheet();
    if (destination && destination !== route) navigate(destination);
    else rerender();
    toast(message);
  });

  dialog.addEventListener('click', event => {
    if (event.target !== dialog) return;
    const rect = dialog.getBoundingClientRect();
    if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) closeSheet();
  });
  dialog.addEventListener('cancel', () => { sheetData = null; });
  window.addEventListener('hashchange', routeChanged);
  window.addEventListener('resize', updateSheetPosition);
  document.getElementById('theme-toggle')?.addEventListener('click', () => {
    const dark = phone.dataset.theme !== 'dark';
    phone.dataset.theme = dark ? 'dark' : 'light';
    dialog.dataset.theme = dark ? 'dark' : 'light';
    const button = document.getElementById('theme-toggle');
    button.setAttribute('aria-pressed', String(dark));
    button.textContent = dark ? '切换浅色' : '切换深色';
    revealPreview();
  });
  document.getElementById('reset-demo')?.addEventListener('click', () => {
    closeSheet();
    imageUrls.forEach(url => URL.revokeObjectURL(url)); imageUrls = [];
    data = JSON.parse(JSON.stringify(original));
    Object.keys(states).forEach(key => delete states[key]);
    trail = [];
    if (route !== 'home') navigate('home'); else render();
    revealPreview();
    toast('示例资料已恢复');
  });
  window.addEventListener('beforeunload', () => imageUrls.forEach(url => URL.revokeObjectURL(url)));
  routeChanged();
})();
