---
name: default-meeting-minutes
slug: default-meeting-minutes
description: VoiceContext 默认会议纪要模板；只根据逐字稿归纳，不虚构决定或负责人。
---

# {{title}}

## 元数据
- 来源 recording_id: {{recording_id}}
- 来源 revision: {{revision}}
- 模板: {{template_slug}}
- 生成时间: {{generated_at}}
- 会议时间: {{started_at}} – {{ended_at}}
- 时区: {{timezone}}
- 语言: {{language}}
- 标签: {{tags}}

## 参与人
{{speakers_section}}

## 摘要
{{summary_section}}

## 讨论要点
{{discussion_section}}

## 决定
{{decisions_section}}

## 行动项
{{actions_section}}

## 未决问题
{{open_questions_section}}

## 来源摘录
{{excerpts_section}}
