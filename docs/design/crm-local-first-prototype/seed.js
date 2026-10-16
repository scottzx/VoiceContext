/* 全部公司、人物、联系方式与业务内容均为虚构演示数据。 */
window.CRM_DEMO = {
  today: '2026-10-16',
  companies: [
    {
      id: 'hexu',
      name: '禾序科技',
      industry: '企业服务 · 演示公司',
      website: 'https://hexu.example',
      notes: '希望理顺客户服务的受理、分派和回访流程，先在一个服务小组试行。'
    }
  ],
  customers: [
    {
      id: 'lin',
      name: '林知远',
      companyId: 'hexu',
      title: '客户服务负责人',
      phone: '000-0000-0101（演示）',
      email: 'lin@hexu.example',
      tags: ['主要联系人', '服务流程'],
      notes: '关注方案能否减少重复登记，以及团队能否快速上手。沟通前先准备具体流程示例。',
      contactState: '已关联通讯录（演示）'
    },
    {
      id: 'chen',
      name: '陈映',
      companyId: 'hexu',
      title: '服务运营经理',
      phone: '000-0000-0102（演示）',
      email: 'chen@hexu.example',
      tags: ['业务对接', '培训支持'],
      notes: '负责现有流程材料和试行人员安排。下次讨论需要带上两份脱敏工单样例。',
      contactState: '未关联通讯录'
    }
  ],
  opportunities: [
    {
      id: 'opp-service',
      title: '客户服务流程优化',
      companyId: 'hexu',
      customerIds: ['lin', 'chen'],
      stage: '方案/报价',
      amount: 68000,
      currency: 'CNY',
      expectedDate: '2026-11-06',
      summary: '统一客户诉求的受理入口，明确分派与升级规则，并保留处理记录。先以一个服务小组验证，再决定是否扩大范围。'
    },
    {
      id: 'opp-support',
      title: '服务团队培训支持',
      companyId: 'hexu',
      customerIds: ['chen', 'lin'],
      stage: '沟通中',
      amount: null,
      currency: 'CNY',
      expectedDate: '',
      summary: '围绕试行后的服务操作和复盘方式安排一次小组培训。范围与时间尚未确认，暂不报价。'
    }
  ],
  tasks: [
    {
      id: 'task-personal',
      title: '整理本周读书笔记',
      companyId: '',
      customerIds: [],
      opportunityId: '',
      due: '2026-10-17',
      completed: false,
      source: 'Yima待办',
      notes: '把本周划线和想法整理到个人笔记。'
    },
    {
      id: 'task-proposal',
      title: '发出流程优化方案初稿',
      companyId: 'hexu',
      customerIds: ['lin'],
      opportunityId: 'opp-service',
      due: '2026-10-16T18:00:00+08:00',
      completed: false,
      source: 'Yima待办',
      notes: '补充受理到回访的流程图，标明试行范围与尚待确认的内容。发送前再核对一次附件。',
      activityId: 'note-call'
    },
    {
      id: 'task-materials',
      title: '向陈映确认试行材料',
      companyId: 'hexu',
      customerIds: ['chen'],
      opportunityId: 'opp-service',
      due: '2026-10-19T12:00:00+08:00',
      completed: false,
      source: 'Yima待办',
      notes: '需要两份脱敏工单样例和当前分派规则，用于周二方案讨论。',
      activityId: 'meeting-review'
    },
    {
      id: 'task-recap',
      title: '整理首次需求沟通纪要',
      companyId: 'hexu',
      customerIds: ['lin', 'chen'],
      opportunityId: 'opp-service',
      due: '2026-10-13T18:00:00+08:00',
      completed: true,
      source: 'Yima待办',
      notes: '已核对参与人、当前问题和待补材料，作为下一次需求复核的输入。',
      activityId: 'meeting-discovery'
    }
  ],
  events: [
    {
      id: 'event-review',
      title: '流程优化方案讨论',
      companyId: 'hexu',
      customerIds: ['lin', 'chen'],
      opportunityId: 'opp-service',
      start: '2026-10-20T15:00:00+08:00',
      end: '2026-10-20T16:00:00+08:00',
      location: '线上会议',
      source: 'Yima日历',
      notes: '核对试行范围、流程节点和方案初稿，带上两份脱敏工单样例。'
    },
    {
      id: 'event-discovery',
      title: '客户服务需求沟通',
      companyId: 'hexu',
      customerIds: ['lin', 'chen'],
      opportunityId: 'opp-service',
      start: '2026-10-12T14:00:00+08:00',
      end: '2026-10-12T15:00:00+08:00',
      location: '禾序科技会议室（演示）',
      source: 'Yima日历',
      notes: '讨论现有受理、分派和回访方式；会后整理当前问题和待补材料。'
    }
  ],
  activities: [
    {
      id: 'photo-proposal',
      type: 'photo',
      title: '方案摘要草案',
      companyId: 'hexu',
      customerIds: ['lin'],
      opportunityId: 'opp-service',
      occurredAt: '2026-10-16T11:20:00+08:00',
      addedAt: '2026-10-16T11:20:00+08:00',
      timeBasis: '添加时间',
      summary: '内部整理的方案摘要，尚未发出。',
      body: '保存一份便于会前核对的方案摘要。此处按添加时间展示，不表示已经与客户沟通。',
      images: [
        { src: 'assets/proposal.svg', alt: '演示资料：客户服务流程优化方案摘要草案', caption: '方案摘要 · 草案 v1 · 演示资料' }
      ]
    },
    {
      id: 'note-call',
      type: 'note',
      title: '确认方案初稿的重点',
      companyId: 'hexu',
      customerIds: ['lin'],
      opportunityId: 'opp-service',
      occurredAt: '2026-10-16T10:15:00+08:00',
      addedAt: '2026-10-16T10:35:00+08:00',
      timeBasis: '沟通时间',
      summary: '林知远希望先看到完整流程和试行边界，今天发出初稿。',
      body: '电话确认：初稿先讲清楚“诉求如何进入、交给谁、何时回访”。报价作为独立部分保留，试行小组和正式启动时间仍需在下次讨论中确认。\n\n下一步：今天发送初稿，周二一起核对流程节点。',
      images: []
    },
    {
      id: 'photo-flow',
      type: 'photo',
      title: '服务流程草图',
      companyId: 'hexu',
      customerIds: ['lin', 'chen'],
      opportunityId: 'opp-service',
      occurredAt: '2026-10-15T16:45:00+08:00',
      addedAt: '2026-10-15T17:05:00+08:00',
      timeBasis: '拍摄时间',
      summary: '会后整理的流程草图，待下次逐项确认。',
      body: '草图覆盖受理、分类、处理与回访四个节点，升级条件还没有定稿。下次讨论逐项核对负责人与处理时限。',
      images: [
        { src: 'assets/flow-notes.svg', alt: '演示资料：受理、分类、处理、回访四步服务流程草图', caption: '服务流程草图 · 节点待确认 · 演示资料' }
      ]
    },
    {
      id: 'meeting-review',
      type: 'meeting',
      title: '服务流程需求复核',
      companyId: 'hexu',
      customerIds: ['lin', 'chen'],
      opportunityId: 'opp-service',
      occurredAt: '2026-10-15T15:30:00+08:00',
      addedAt: '2026-10-15T17:15:00+08:00',
      timeBasis: '沟通时间',
      summary: '确认统一受理和处理记录是首要需求；升级规则与试行材料待补。',
      body: '林知远确认先解决重复登记和责任不清的问题。陈映将准备脱敏工单样例，帮助核对分类和升级规则。\n\n下次讨论将结合方案初稿，确认一个服务小组的试行范围。',
      images: [],
      minutes: {
        title: '服务流程需求复核 · 会议纪要',
        recordingTitle: '禾序科技 · 需求复核',
        revision: 2,
        generatedAt: '2026-10-15T17:00:00+08:00',
        body: '参与人：林知远、陈映。\n\n已确认：\n1. 先统一客户诉求受理方式，减少重复登记。\n2. 处理记录需要能回溯责任人与下一步。\n3. 方案初稿用一个服务小组作试行示例。\n\n待确认：\n1. 升级条件与超时后的处理规则。\n2. 试行人员、正式启动时间。\n\n下一步：准备两份脱敏工单；发送方案初稿；10 月 20 日讨论方案。'
      }
    },
    {
      id: 'meeting-discovery',
      type: 'meeting',
      title: '首次客户服务需求沟通',
      companyId: 'hexu',
      customerIds: ['lin', 'chen'],
      opportunityId: 'opp-service',
      occurredAt: '2026-10-12T14:00:00+08:00',
      addedAt: '2026-10-12T16:30:00+08:00',
      timeBasis: '沟通时间',
      summary: '了解现有受理、分派和回访方式，约定先梳理流程再讨论工具。',
      body: '当前诉求来自电话和多个工作群，运营人员要重复整理。希望先明确处理流程，再决定需要哪些工具支持。金额与启动时间在本次沟通中没有确认。',
      images: [],
      minutes: {
        title: '客户服务需求沟通 · 会议纪要',
        recordingTitle: '禾序科技 · 首次需求沟通',
        revision: 1,
        generatedAt: '2026-10-12T16:10:00+08:00',
        body: '参与人：林知远、陈映。\n\n现状：客户诉求分散在多个入口，分派依赖人工，回访记录不够集中。\n\n诉求：先梳理一条可试行的流程，明确受理、分派、升级和回访。\n\n约定：陈映整理现有资料；下一次沟通复核流程节点。\n\n未确认：方案金额、试行人数、启动时间。'
      }
    },
    {
      id: 'photo-workshop',
      type: 'photo',
      title: '培训需求梳理',
      companyId: 'hexu',
      customerIds: ['chen'],
      opportunityId: 'opp-support',
      occurredAt: '2026-10-08T11:40:00+08:00',
      addedAt: '2026-10-08T12:05:00+08:00',
      timeBasis: '拍摄时间',
      summary: '保存培训需求讨论的纸面整理资料。',
      body: '先围绕试行操作、交接和周复盘三个主题做小组培训。人数、时长和时间都待后续确认。',
      images: [
        { src: 'assets/workshop-notes.svg', alt: '演示资料：试行操作、交接、复盘三个培训主题与待确认事项', caption: '培训需求梳理 · 范围待确认 · 演示资料' }
      ]
    },
    {
      id: 'note-requirements',
      type: 'note',
      title: '了解团队培训的安排',
      companyId: 'hexu',
      customerIds: ['chen'],
      opportunityId: 'opp-support',
      occurredAt: '2026-10-08T11:00:00+08:00',
      addedAt: '2026-10-08T12:00:00+08:00',
      timeBasis: '沟通时间',
      summary: '陈映希望在试行流程确定后安排小组培训，先保留需求。',
      body: '沟通内容：培训重点是服务操作和交接方式，暂不安排全员培训。等流程优化方案确认后，再讨论参与人数、时长和日期。\n\n当前不创建有期限的培训任务，也不填入未经确认的报价。',
      images: []
    }
  ]
};
