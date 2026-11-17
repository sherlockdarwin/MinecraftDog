<!-- ppt-master-schema: design-spec/v1 -->
# MinecraftDog 答辩 - Design Spec

## I. Project Information

| Item | Value |
| --- | --- |
| Project Name | MinecraftDog 决赛答辩 |
| Canvas Format | PPT 16:9 (1280×720) |
| Page Count | 11 |
| Primary Language | zh-CN |
| Target Audience | 全国大学生嵌入式芯片与系统设计竞赛 FPGA 赛道决赛评委（FPGA/嵌入式背景，熟悉竞赛规则，初次接触本作品） |
| Communication Intent | 先讲清作品是什么、整体架构；再依次深入讲透三个技术亮点（障碍识别与图像处理、避障决策算法、WAV 双路音频），最后用喂食摇尾互动与验证成果收束；让评委在 8 分钟内理解技术深度与创新点。 |
| Desired Audience Outcome | 评委能复述作品的三层分工（FPGA 全做决策、STM32 当接口、单目视觉避障）、避障流水线的关键两步（地面外观分类 + 车宽走廊选方向）、决策状态机的核心思路（目标航向 + 陀螺仪角度环 + 找出口）、双路 WAV 同时播放的架构；认可工程化验证的严谨。 |
| Core Message / Ask / Action | 一句话：感知、决策、控制全在国产安路 FPGA 上以纯硬件流水线实现，单目视觉避障无需深度传感器，整机已上车验证。 |
| Delivery Context | 主讲人现场答辩，8 分钟硬上限，投影 16:9；副用途：留档给评委翻阅。 |
| Artifact Afterlife | 留档 + 可作为后续宣传素材。 |
| Reading Mode | presentation（主讲人主导，每页一个核心论点，细节由演讲稿承载） |
| Content Strategy | balanced：以技术文档为事实源，重新组织成"是什么 → 怎么做 → 做出来怎样"的答辩叙事，保留全部技术实质但不在 slide 上堆文字。 |
| Design Style | Minecraft 方块像素风（克制版）：方块几何、草地方块绿与石头灰为主，红/蓝作为功能强调；保留我的世界辨识度但不花哨。 |
| AI Image Acquisition Path | not applicable（全部使用工程已有的实拍/技术配图） |
| Generation Mode | continuous |
| Spec Refinement | disabled |
| Speaker Notes | enabled — 答辩需要配套演讲稿，由用户主讲 |
| Custom Animations | disabled — 用户原话"夸张的动画效果可以删去"、希望更简洁；草案，待用户确认 |
| Narration Audio | disabled |
| Created Date | 2026-11-17 |

## II. Canvas Specification

| Property | Value |
| --- | --- |
| Format | PPT 16:9 |
| Dimensions | 1280 × 720 |
| viewBox | `0 0 1280 720` |
| Margins | 56 px |
| Content Area | x 56–1224, y 56–664 |

## III. Visual Theme

### Theme Style

- **Mode**: custom — 先"是什么"再"怎么做"再"做出来怎样"的答辩叙事金字塔，开场用作品定位抓注意，中段三个技术亮点逐一展开，收束于验证成果。
- **Visual style**: custom — Minecraft 方块像素风（克制版）：方块圆角几何、像素化英文标题、草地绿 + 石头灰主调、红框/蓝条作为功能语义色；大量留白，避免贴纸堆叠。
- **Theme**: MinecraftDog 方块世界
- **Tone**: 工程、克制、有童趣但不轻浮

### Color Scheme

| Role | HEX | Purpose |
| --- | --- | --- |
| Background | #F5F2E8 | 浅砂石暖白主背景，呼应我的世界白天的方块 |
| Secondary background | #E8E0CC | 卡片/分块的浅色底 |
| Primary | #5C8E3A | 草方块绿，标题、主结构、地面 |
| Accent | #C4362A | 障碍红框、关键强调 |
| Secondary accent | #3C6BBE | 数据/指标蓝，用于性能数字 |
| Body text | #2E3230 | 正文深石色 |
| Secondary text | #6B6E66 | 注释、副文字 |
| Divider | #D4CCB8 | 细分割线、方块描边 |

## IV. Typography System

### Font Plan

| Role | Character (Reference) | Primary | English if non-English | Fallback tail |
| --- | --- | --- | --- | --- |
| Title | 像素感英文 / 中文黑体 | 等线 | Press Start 2P | SimHei, Arial |
| Body | 现代无衬线中文 | 微软雅黑 | Arial | SimHei |
| Display | 像素英文标题 | Press Start 2P | Press Start 2P | Arial Black |

- **Title stack**: `Press Start 2P, 等线, SimHei, Arial`
- **Body stack**: `微软雅黑, Microsoft YaHei, Arial`

### Font Size Hierarchy

| Purpose | Anchor Size (px) |
| --- | ---: |
| Body | 22 |
| Title | 40 |
| Subtitle | 28 |
| Display (像素英文大标题) | 56 |
| Annotation | 16 |
| Footnote | 14 |

## V. Layout Principles

### Deck-wide Direction

- **Hierarchy direction**: 自上而下：像素英文小标题 → 中文大标题 → 主体内容 → 底部页脚与来源。
- **Composition tendency**: 左右分栏或图上文下，避免居中堆叠卡片网格；技术页以"一张大图 + 简短说明"为主。
- **Cross-page continuity**: 顶部 12 px 草绿条 + 像素英文页码作为跨页锚点；障碍红框、走廊示意、波形等沿用同一几何语言。
- **Spacing posture**: variable — 封面/章页 breathing，技术页 dense，成果页 breathing。
- **Spacing anchors**: 页边 56 px、块间距 32 px、列缝 40 px、圆角 8 px、正文行高 1.45。

## VI. Icon Usage Specification

- **Primary bundled library**: none（语义用方块/圆点 + 文字标签代替图标库，保持像素方块感）

## VIII. Image Resource List

| Filename | Dimensions | Ratio | Purpose | Type | Image pattern | Crop Policy | Acquire Via | Status | Reference | text_policy | page_role |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| dog_front.png | 900×954 | 0.94 | 封面作品正面实拍 | Photo | 封面左侧单图 | no-crop | user | Existing | 作品实拍 | none | cover |
| fig_system.png | 2828×1576 | 1.79 | 系统整体框图 | Diagram | 页面主体大图 | no-crop | user | Existing | 技术文档图 2-1 | embedded | content |
| fig_obs.png | 2310×1932 | 1.20 | 避障流水线框图 | Diagram | 右侧大图 | no-crop | user | Existing | 技术文档图 2-13 | embedded | content |
| fig_corridor.png | 2100×1764 | 1.19 | 车宽走廊示意 | Diagram | 左侧大图 | no-crop | user | Existing | 技术文档图 2-14 | embedded | content |
| fig_follow.png | 3080×2464 | 1.25 | 决策状态流程 | Diagram | 页面主体大图 | no-crop | user | Existing | 技术文档图 2-15 | embedded | content |
| chart_follow.png | 2800×1344 | 2.08 | 跟随闭环仿真曲线 | Chart image | 页面主体证据图 | no-crop | user | Existing | 技术文档图 2-16 | embedded | content |
| fig_audio.png | 2828×1036 | 2.73 | 音频子系统框图 | Diagram | 左侧大图 | no-crop | user | Existing | 技术文档图 2-19 | embedded | content |
| fig_behavior.png | 2828×1176 | 2.40 | 行为层与尾巴序列 | Diagram | 左侧大图 | no-crop | user | Existing | 技术文档图 2-18 | embedded | content |
| field1.jpg | 826×465 | 1.78 | 演示现场照片 | Photo | 左侧证据照片 | no-crop | user | Existing | 技术文档图 3-7 | none | content |

## IX. Content Outline

### Part 1: 作品是什么

#### Slide 01 - 封面

- **Audience move**: 不认识作品 → 知道作品名、定位与赛道
- **Relationships**: none
- **Title**: MinecraftDog
- **Core message**: 感知、决策、控制全在国产 FPGA 纯硬件实现
- **Content**: 作品名 · 中文副标 · 赛道 · 一句定位

#### Slide 02 - 系统总览

- **Audience move**: 不清楚分工 → 建立"FPGA 决策、STM32 当接口"的心智模型
- **Relationships**: FPGA 五个子系统 membership；STM32 与 FPGA link
- **Title**: 系统总览
- **Core message**: 所有感知与决策在 FPGA 硬件完成，STM32 只当传感器与电机接口
- **Content**: 系统框图 · 视频通路 / 避障流水线 / 决策执行三点注脚

### Part 2: 障碍识别与避障

#### Slide 03 - 单目障碍识别

- **Audience move**: 不知道怎么避障 → 理解地面外观法与流水线
- **Relationships**: 地面样本与障碍 contrast；流水线九步 order
- **Title**: 单目障碍识别
- **Core message**: 用颜色判地面与障碍，纯流水线不占 DDR
- **Content**: 核心思路 · 九步流水线 · 只用片内 RAM、约 0.01 ms 出结果

#### Slide 04 - 车宽走廊选方向

- **Audience move**: 知道判障碍 → 理解怎么选方向与 STOP
- **Relationships**: 9 个方向 membership；挡路与不挡路 contrast
- **Title**: 车宽走廊选方向
- **Core message**: 按 30 cm 车宽走廊算每个方向能走多远
- **Content**: ±17° 9 方向 · 横向 15 cm 内才挡路 · 最远方向，不足 60 cm 则 STOP

#### Slide 05 - 跟随避障决策

- **Audience move**: 知道感知结果 → 理解决策状态机
- **Relationships**: 决策状态 order；代价函数两项 parent 绕行方向
- **Title**: 跟随避障决策
- **Core message**: 决策只定目标航向，陀螺仪角度环执行
- **Content**: 状态流程图 · 代价函数 · 找出口 · 角度环

#### Slide 06 - 闭环仿真验证

- **Audience move**: 听完算法 → 看到量化证据
- **Relationships**: 仿真曲线 order
- **Title**: 闭环仿真验证
- **Core message**: 偏 30° 约 1 s 对准，误差 ±1° 内
- **Content**: 仿真曲线 · 两条结论 · 车模型参数

### Part 3: 声音与互动

#### Slide 07 - 双路 WAV 混音

- **Audience move**: 不知道音频怎么做 → 理解双路同时播放
- **Relationships**: 背景音乐与音效 contrast；SD 控制器 parent 两路读文件
- **Title**: 双路 WAV 混音
- **Core message**: 无软核 FAT32，背景音乐与音效左右声道互不打断
- **Content**: 音频框图 · 双路共享仲裁 · FAT32 · 重采样

#### Slide 08 - 喂食 · 摇尾 · 狗叫

- **Audience move**: 看到互动 → 理解背后的实现
- **Relationships**: 霍尔 → 行为层 → 音效与尾巴 order
- **Title**: 喂食 · 摇尾 · 狗叫
- **Core message**: 行为层三条规则驱动音效与尾巴
- **Content**: 霍尔检测 · 三条规则 · 步进电机摇尾序列

### Part 4: 成果

#### Slide 09 - 上板验证成果

- **Audience move**: 怀疑是否真能跑 → 确认整机已上车验证
- **Relationships**: 验证项 membership
- **Title**: 上板验证成果
- **Core message**: 六项功能上车验证，33 个测试台全部通过
- **Content**: 现场照片 · 上车验证清单 · 仿真结果

#### Slide 10 - 资源与时序

- **Audience move**: 看过功能 → 认可工程硬指标
- **Relationships**: 资源指标 membership
- **Title**: 资源与时序
- **Core message**: 40 个 DSP 的芯片上时序零违例
- **Content**: LUT / DSP / ERAM / 时序 / 测试台指标

#### Slide 11 - 总结与展望

- **Audience move**: 听完全部 → 带走完整印象
- **Relationships**: 已实现与可扩展 contrast
- **Title**: 总结与展望
- **Core message**: 国产 FPGA 纯硬件实现完整的视觉跟随避障机器狗
- **Content**: 已实现 · 可扩展 · 结尾一句

## X. Speaker Notes Requirements

- **Generation**: enabled
- **Filename**: match each SVG filename under `notes/`
- **Content**: 以技术文档为事实源，主讲人口吻，不引入新事实
- **Total duration**: 8 分钟以内
- **Notes style**: conversational
- **Presentation purpose**: 让评委理解避障、决策、音频三个技术亮点与上车验证结果
