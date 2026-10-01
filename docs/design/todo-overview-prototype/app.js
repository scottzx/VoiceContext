const today = '2026-10-01';
let selected = today, year = 2026, month = 9, expanded = true, page = 'home', preview = 'normal', filtersOpen = false, showCompleted = false;
let homeContext;
const reminderLists = [{id:'work',title:'工作'}, {id:'personal',title:'个人'}];
const eventLists = [{id:'work-calendar',title:'工作日历'}, {id:'holidays',title:'节假日'}];
const selectedReminderLists = new Set(reminderLists.map(list=>list.id));
const selectedEventLists = new Set(eventLists.map(list=>list.id));
const reminders = [
 {id:1,date:today,time:'10:00',title:'确认会议纪要中的下一步',source:'工作',listID:'work',done:false},
 {id:2,date:today,time:'',title:'整理这周的录音笔记',source:'个人',listID:'personal',done:false},
 {id:3,date:'2026-10-02',time:'09:00',title:'发送项目更新',source:'工作',listID:'work',done:false},
 {id:4,date:'2026-09-30',time:'',title:'核对报销材料',source:'个人',listID:'personal',done:false},
 {id:5,date:null,time:'',title:'整理待读文章',source:'个人',listID:'personal',done:false}
];
const events = [
 {id:11,date:today,start:'14:00',end:'15:00',title:'产品方案讨论',source:'工作日历',listID:'work-calendar'},
 {id:12,date:today,start:'',end:'',title:'国庆节',source:'节假日',listID:'holidays'},
 {id:13,date:'2026-10-02',start:'16:00',end:'17:00',title:'每周项目同步',source:'工作日历',listID:'work-calendar'},
 {id:14,date:'2026-10-06',start:'10:00',end:'11:00',title:'设计评审',source:'工作日历',listID:'work-calendar'}
];
const screen = document.querySelector('#screen'), navigation = document.querySelector('#navigation');
const key = date => `${date.getFullYear()}-${String(date.getMonth()+1).padStart(2,'0')}-${String(date.getDate()).padStart(2,'0')}`;
const parse = str => new Date(`${str}T12:00:00`);
const escapeHTML = str => String(str).replace(/[&<>"']/g, char => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
function filteredReminders() {
 return preview==='empty'?[]:reminders.filter(item=>
  (page!=='all'||selectedReminderLists.has(item.listID))&&
  (!item.done||(page==='all'&&showCompleted)));
}
function dayItems(date) {
 return {tasks:filteredReminders().filter(item=>item.date===date&&!item.done),agenda:preview==='normal'?events.filter(item=>item.date===date):[]};
}
function calendarHTML() {
 const first = new Date(year, month, 1, 12), start = new Date(first), offset = (first.getDay()+6)%7;
 start.setDate(1-offset);
 let count = Math.ceil((offset+new Date(year,month+1,0).getDate())/7)*7;
 if (!expanded) {start.setTime(parse(selected).getTime());start.setDate(start.getDate()-(start.getDay()+6)%7);count=7;}
 const days = Array.from({length:count},(_,i)=>{
  const d=new Date(start); d.setDate(start.getDate()+i);const date=key(d), data=dayItems(date);
  const state=preview==='permission'?'，日历未授权':preview==='error'?'，日历读取失败':'';
  return `<button class="date ${date===selected?'selected':''} ${date===today?'today':''} ${d.getMonth()!==month?'outside':''}" data-date="${date}" aria-pressed="${date===selected}" aria-label="${d.getFullYear()}年${d.getMonth()+1}月${d.getDate()}日${date===today?'，今天':''}，${data.tasks.length}项待办，${data.agenda.length}项已读取日程${state}"><span class="number">${d.getDate()}</span><span class="dots" aria-hidden="true"><span class="dot task-dot ${data.tasks.length?'':'none'}"></span><span class="dot event-dot ${data.agenda.length?'':'none'}"></span></span></button>`;
 }).join('');
 return `<section class="calendar" tabindex="0" aria-label="日期选择，左右滑动或按左右方向键切换月份或周"><div class="month-header"><button class="month-title" data-action="expand" aria-expanded="${expanded}" aria-label="${expanded?'收起为周历':'展开月历'}">${year}.${String(month+1).padStart(2,'0')} <span class="chevron">${expanded?'⌃':'⌄'}</span></button><button class="calendar-today" data-action="today" aria-label="回到今天">今天</button></div><div class="weekdays" aria-hidden="true">${['一','二','三','四','五','六','日'].map(d=>`<span>周${d}</span>`).join('')}</div><div class="days">${days}</div><div class="calendar-legend"><span><i class="dot task-dot" aria-hidden="true"></i>待办</span><span><i class="dot event-dot" aria-hidden="true"></i>日程</span></div></section>`;
}
function taskHTML(item) {
 return `<div class="row ${item.done?'done':''}"><button class="check" data-toggle="${item.id}" aria-label="${item.done?'恢复':'完成'}待办：${escapeHTML(item.title)}">${item.done?'☑':'○'}</button><button class="row-body" data-detail="${item.id}"><span class="row-title">${escapeHTML(item.title)}</span><span class="meta">${item.time||'无指定时间'} · ${escapeHTML(item.source)}${item.done?' · 已完成':''}</span></button></div>`;
}
function eventHTML(item) {
 return `<div class="row"><div class="event-time">${item.start||'全天'}${item.end?`<small>${item.end}</small>`:''}</div><button class="row-body" data-detail="${item.id}"><span class="row-title">${escapeHTML(item.title)}</span><span class="meta">${escapeHTML(item.source)}</span></button><span class="disclosure" aria-hidden="true">›</span></div>`;
}
function eventState() {
 if(preview==='permission')return '<div class="message">允许读取系统日历后，可在这里查看日程。<br><button data-action="allow">允许访问日历</button></div>';
 if(preview==='error')return '<div class="message">暂时无法读取日历，待办仍可使用。<br><button data-action="retry">重试</button></div>';
 return '';
}
function agendaHTML(date) {
 const data=dayItems(date);
 const tasks=`<div class="group-header">待办<span>${data.tasks.length} 项</span></div>${data.tasks.map(taskHTML).join('')||'<div class="empty">这天没有待办。</div>'}`;
 const agenda=`<div class="group-header">日程<span>${preview==='permission'||preview==='error'?'未读取':`${data.agenda.length} 项`}</span></div>${eventState()||data.agenda.map(eventHTML).join('')||'<div class="empty">这天没有日程。</div>'}`;
 return tasks+agenda;
}
function render() {
 navigation.innerHTML = page==='home'?'<span></span><strong>待办事项</strong><span></span>':'<button class="back" data-action="back">‹ 返回</button><strong>全部事项</strong><button class="trailing" data-action="filter" aria-label="筛选全部事项">≡</button>';
 const d=parse(selected), label=selected===today?'今日事项':`${d.getMonth()+1}月${d.getDate()}日 · 周${['日','一','二','三','四','五','六'][d.getDay()]}`;
 if(page==='home')screen.innerHTML = `${calendarHTML()}<section aria-label="当日事项"><div class="section-header"><h2>${label}</h2><div class="section-actions"><button class="all" data-action="all">全部 ›</button><button class="add" data-action="add" aria-label="新增待办">＋</button></div></div>${agendaHTML(selected)}<div class="helper">${reminders.filter(item=>item.date&&item.date<today&&!item.done).length} 项逾期待办 · 在“全部”中查看</div></section>`;
 else {
  const filterHTML=filtersOpen?`<div class="filter-menu"><fieldset><legend>日历列表</legend>${eventLists.map(list=>`<label><input type="checkbox" data-event-list="${list.id}" ${selectedEventLists.has(list.id)?'checked':''}> ${escapeHTML(list.title)}</label>`).join('')}</fieldset><fieldset><legend>待办列表</legend>${reminderLists.map(list=>`<label><input type="checkbox" data-reminder-list="${list.id}" ${selectedReminderLists.has(list.id)?'checked':''}> ${escapeHTML(list.title)}</label>`).join('')}</fieldset><label><input id="completed" type="checkbox" ${showCompleted?'checked':''}> 显示已完成待办</label></div>`:'';
   const tasks=filteredReminders();
   const agenda=preview!=='normal'?[]:events.filter(item=>selectedEventLists.has(item.listID));
   const groups=[['逾期',tasks.filter(item=>item.date&&item.date<today),[]],['今天',tasks.filter(item=>item.date===today),agenda.filter(item=>item.date===today)],['未来',tasks.filter(item=>item.date>today),agenda.filter(item=>item.date>today)],['未安排',tasks.filter(item=>!item.date),[]]];
   const content=groups.map(([title,t,e])=>{
    const rows=[...t.map(item=>({date:item.date||'',time:item.time,html:taskHTML(item)})),...e.map(item=>({date:item.date,time:item.start,html:eventHTML(item)}))].sort((a,b)=>a.date.localeCompare(b.date)||(a.time||'99:99').localeCompare(b.time||'99:99'));
    return `<div class="group-header">${title}<span>${rows.length} 项</span></div>${rows.map(row=>`${title==='未来'?`<span class="meta">${row.date}</span>`:''}${row.html}`).join('')||'<div class="empty">没有事项</div>'}`;
   }).join('')+(selectedEventLists.size?eventState():'');
  screen.innerHTML=filterHTML+(selectedReminderLists.size||selectedEventLists.size?content:'<div class="empty">尚未选择列表，请在筛选中勾选要展示的日历或待办列表。</div>');
 }
}
function detail(title,body) {
 document.querySelector('#detail-content').innerHTML=`<h2>${escapeHTML(title)}</h2>${body}`;
 document.querySelector('#detail').showModal();
}
function action(name) {
 if(name==='all'){homeContext={selected,year,month,expanded,scroll:screen.scrollTop};page='all';screen.scrollTop=0;}
 if(name==='back'){page='home';filtersOpen=false;({selected,year,month,expanded}=homeContext);}
 if(name==='today'){selected=today;year=2026;month=9;}
 if(name==='expand')expanded=!expanded;
 if(name==='filter')filtersOpen=!filtersOpen;
 if(name==='prev'||name==='next'){
  const step=name==='next'?1:-1;
  if(expanded){const d=new Date(year,month+step,1,12);year=d.getFullYear();month=d.getMonth();}
  else{const d=parse(selected);d.setDate(d.getDate()+step*7);selected=key(d);year=d.getFullYear();month=d.getMonth();}
 }
 if(name==='add')return detail('新增待办',`<p>正式版复用当前系统提醒事项编辑表单。</p><p>首页入口预填日期：${page==='home'?selected:'不指定'}。用户可修改或关闭日期；通知单独设置。</p><p>此设计原型不会创建系统记录。</p>`);
 if(name==='allow')return detail('日历访问说明','<p>设计提案：由用户主动授权，只用于展示日期上的安排。网页不会申请系统权限。</p>');
 if(name==='retry'){preview='normal';document.querySelector('#preview').value=preview;}
 render();
 if(name==='back')screen.scrollTop=homeContext.scroll;
}
let swipeStart, suppressSwipeClick = false;
screen.addEventListener('pointerdown',event=>{
 if(event.isPrimary&&event.button===0&&event.target.closest('.days'))swipeStart={x:event.clientX,y:event.clientY,id:event.pointerId};
});
screen.addEventListener('pointercancel',()=>{swipeStart=undefined;});
screen.addEventListener('pointerup',event=>{
 if(!swipeStart||event.pointerId!==swipeStart.id)return;
 const dx=event.clientX-swipeStart.x, dy=event.clientY-swipeStart.y;
 swipeStart=undefined;
 if(Math.abs(dx)<48||Math.abs(dx)<=Math.abs(dy)*1.5)return;
 // A completed swipe must not also select the date beneath the pointer.
 suppressSwipeClick=true;
 setTimeout(()=>{suppressSwipeClick=false;},0);
 action(dx<0?'next':'prev');
});
screen.addEventListener('keydown',event=>{
 if(!event.target.closest('.calendar')||!['ArrowLeft','ArrowRight'].includes(event.key))return;
 event.preventDefault();
 action(event.key==='ArrowRight'?'next':'prev');
 screen.querySelector('.calendar').focus({preventScroll:true});
});
document.addEventListener('click',event=>{
 if(suppressSwipeClick){event.preventDefault();return;}
 const button=event.target.closest('button');if(!button)return;
 if(button.dataset.action)action(button.dataset.action);
 if(button.dataset.date){selected=button.dataset.date;const d=parse(selected);year=d.getFullYear();month=d.getMonth();render();}
 if(button.dataset.toggle){const item=reminders.find(item=>item.id===Number(button.dataset.toggle));item.done=!item.done;render();}
 if(button.dataset.detail){const item=[...reminders,...events].find(item=>item.id===Number(button.dataset.detail));detail(item.title,`<p>${item.date||'未安排日期'} · ${escapeHTML(item.source)}</p><p>${item.id<10?'待办正文在正式版打开已有编辑 Sheet，可修改标题、备注、列表、日期和独立提醒。':'日程显示起止时间、地点与来源；原型仅演示查看，不提供完成操作。'}</p><p>这是虚构的设计示例。</p>`);}
});
document.addEventListener('change',event=>{
 if(event.target.dataset.reminderList){
  const id=event.target.dataset.reminderList;
  if(event.target.checked)selectedReminderLists.add(id);else selectedReminderLists.delete(id);
  render();
 }
 if(event.target.dataset.eventList){
  const id=event.target.dataset.eventList;
  if(event.target.checked)selectedEventLists.add(id);else selectedEventLists.delete(id);
  render();
 }
 if(event.target.id==='completed'){showCompleted=event.target.checked;render();}
});
document.querySelector('#theme').onclick=event=>{const phone=document.querySelector('.phone');phone.dataset.theme=phone.dataset.theme==='dark'?'light':'dark';event.target.textContent=phone.dataset.theme==='dark'?'切换浅色':'切换深色';};
document.querySelector('#preview').onchange=event=>{preview=event.target.value;render();};
render();
