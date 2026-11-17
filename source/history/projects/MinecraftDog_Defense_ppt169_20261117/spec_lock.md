<!-- ppt-master-schema: spec-lock/v1 -->
# Execution Lock

## canvas
- viewBox: 0 0 1280 720
- format: PPT 16:9

## communication
- primary_language: zh-CN
- audience: 全国大学生嵌入式芯片与系统设计竞赛 FPGA 赛道决赛评委
- objective: 在 8 分钟内让评委理解 MinecraftDog 的技术亮点：单目视觉避障流水线、目标航向决策状态机、双路 WAV 音频，以及所有决策全在国产安路 FPGA 纯硬件实现的核心价值。
- core_message: 感知、决策、控制全在国产安路 PH1P35 FPGA 以纯硬件流水线实现；单目视觉避障无需深度传感器；整机已上车验证。
- consumption_mode: presentation

## mode
- mode: custom
- mode_behavior: 答辩叙事金字塔：封面定位 → 系统总览建立心智模型 → 三个技术亮点逐层展开（避障感知 / 避障决策 / 音频交互）→ 验证成果与指标收束。

## visual_style
- visual_style: custom
- visual_style_behavior: Minecraft 方块像素风克制版：顶部 12 px 草绿条锚定每页；像素英文（Press Start 2P）作为技术标签；主调砂石暖白背景 + 草地绿主色 + 障碍红 + 数据蓝；卡片圆角 4 px；大量留白，避免贴纸堆叠；技术图居中展示，文字注释精简。

## colors
- background: #F5F2E8
- secondary_background: #E8E0CC
- primary: #5C8E3A
- accent: #C4362A
- secondary_accent: #3C6BBE
- body_text: #2E3230
- secondary_text: #6B6E66
- divider: #D4CCB8

## typography
- title_family: 等线, DengXian, SimHei, Arial
- body_family: 微软雅黑, Microsoft YaHei, SimHei, Arial
- font_family: 微软雅黑, Microsoft YaHei, SimHei, Arial
- display_family: Press Start 2P, Arial Black, Arial
- body: 22
- title: 40
- subtitle: 28
- display: 52
- annotation: 16
- footnote: 14
- badge_label: 10
- badge_small: 11
- micro: 9

## icons
- library: none
- inventory: none

## page_rhythm
- P01: anchor
- P02: dense
- P03: dense
- P04: dense
- P05: dense
- P06: breathing
- P07: dense
- P08: dense
- P09: breathing
- P10: breathing
- P11: anchor

## pptx_structure
- mode: flat

## images
- dog_front: images/dog_front.png | source=user | crop=no-crop
- fig_system: images/fig_system.png | source=user | crop=no-crop
- fig_obs: images/fig_obs.png | source=user | crop=no-crop
- fig_corridor: images/fig_corridor.png | source=user | crop=no-crop
- fig_follow: images/fig_follow.png | source=user | crop=no-crop
- chart_follow: images/chart_follow.png | source=user | crop=no-crop
- fig_audio: images/fig_audio.png | source=user | crop=no-crop
- fig_behavior: images/fig_behavior.png | source=user | crop=no-crop
- field1: images/field1.jpg | source=user | crop=no-crop

## forbidden
- `mask`, `<style>`, `class`, external CSS, `<foreignObject>`, `textPath`, `@font-face`, `<animate*>`, `<set>`, `<script>` / event attributes, `<iframe>`
- HTML named entities in text; write typography as raw Unicode and escape XML reserved characters
