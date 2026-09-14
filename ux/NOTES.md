# UX 说明（重构落地指南）

> 已整合进 `GrokRecent.ps1` v1.9.0（WinForms 能落地的部分：配色、字体、按键行程、暗色标题栏、监视筛选/激光/LED、自定义步进器、状态回执）。HTML 里的 CSS 流光与圆角滚动条无法 1:1 复刻。继续改请往下追加。


本方案针对启动器进行系统级体验与视觉重构：**拔除低级感与陈旧感、消灭 Unicode Emoji、彻底摒弃 AI 幻彩紫色、引入工业精工黑曜石质感、建立按键物理触感反馈与平滑微动效体系**。

所有交互原型、独立页面与矢量线框已整理在 `ux/mockups/`：
- **主交互原型（包含全部三页与实时动效）**：[`mockups/index.html`](file:///d:/Project/Grok%E5%B7%A5%E4%BD%9C%E6%96%87%E4%BB%B6%E5%A4%B9/%E6%95%88%E7%8E%87%E5%B7%A5%E5%85%B7/Grok%E6%9C%80%E8%BF%91%E9%A1%B9%E7%9B%AE%E5%90%AF%E5%8A%A8%E5%99%A8/ux/mockups/index.html)（直接在浏览器中打开即可全功能试玩）
- **单页设计稿**：[`mockups/dashboard.html`](file:///d:/Project/Grok%E5%B7%A5%E4%BD%9C%E6%96%87%E4%BB%B6%E5%A4%B9/%E6%95%88%E7%8E%87%E5%B7%A5%E5%85%B7/Grok%E6%9C%80%E8%BF%91%E9%A1%B9%E7%9B%AE%E5%90%AF%E5%8A%A8%E5%99%A8/ux/mockups/dashboard.html)、[`mockups/projects.html`](file:///d:/Project/Grok%E5%B7%A5%E4%BD%9C%E6%96%87%E4%BB%B6%E5%A4%B9/%E6%95%88%E7%8E%87%E5%B7%A5%E5%85%B7/Grok%E6%9C%80%E8%BF%91%E9%A1%B9%E7%9B%AE%E5%90%AF%E5%8A%A8%E5%99%A8/ux/mockups/projects.html)、[`mockups/watch.html`](file:///d:/Project/Grok%E5%B7%A5%E4%BD%9C%E6%96%87%E4%BB%B6%E5%A4%B9/%E6%95%88%E7%8E%87%E5%B7%A5%E5%85%B7/Grok%E6%9C%80%E8%BF%91%E9%A1%B9%E7%9B%AE%E5%90%AF%E5%8A%A8%E5%99%A8/ux/mockups/watch.html)
- **矢量架构线框图**：[`mockups/wireframe-overview.svg`](file:///d:/Project/Grok%E5%B7%A5%E4%BD%9C%E6%96%87%E4%BB%B6%E5%A4%B9/%E6%95%88%E7%8E%87%E5%B7%A5%E5%85%B7/Grok%E6%9C%80%E8%BF%91%E9%A1%B9%E7%9B%AE%E5%90%AF%E5%8A%A8%E5%99%A8/ux/mockups/wireframe-overview.svg)、[`mockups/wireframe-projects.svg`](file:///d:/Project/Grok%E5%B7%A5%E4%BD%9C%E6%96%87%E4%BB%B6%E5%A4%B9/%E6%95%88%E7%8E%87%E5%B7%A5%E5%85%B7/Grok%E6%9C%80%E8%BF%91%E9%A1%B9%E7%9B%AE%E5%90%AF%E5%8A%A8%E5%99%A8/ux/mockups/wireframe-projects.svg)、[`mockups/wireframe-watch.svg`](file:///d:/Project/Grok%E5%B7%A5%E4%BD%9C%E6%96%87%E4%BB%B6%E5%A4%B9/%E6%95%88%E7%8E%87%E5%B7%A5%E5%85%B7/Grok%E6%9C%80%E8%BF%91%E9%A1%B9%E7%9B%AE%E5%90%AF%E5%8A%A8%E5%99%A8/ux/mockups/wireframe-watch.svg)
- **设计规范令牌**：[`mockups/design-tokens.css`](file:///d:/Project/Grok%E5%B7%A5%E4%BD%9C%E6%96%87%E4%BB%B6%E5%A4%B9/%E6%95%88%E7%8E%87%E5%B7%A5%E5%85%B7/Grok%E6%9C%80%E8%BF%91%E9%A1%B9%E7%9B%AE%E5%90%AF%E5%8A%A8%E5%99%A8/ux/mockups/design-tokens.css)

---

## 全局（导航、设计语言、按键反馈、动效与窗口）

### 1. 调色系统：从“泥泞黄褐”转向“黑曜石工业精工 (Obsidian + Slate + Titanium Amber)”
- **现在什么样**：背景用 `$bg = (14, 14, 12)`、面板用 `$panel = (26, 24, 21)`、边框用 `$line = (52, 46, 38)`、点缀用 `$accent = (212, 154, 64)`。整体泛着泥土黄褐色，对比度低、发闷发灰，有老式简陋终端的低级感。
- **希望什么样**：
  - 画布底色重构为冷黑曜石深色：`#0c0e12`（RGB 12, 14, 18）。
  - 面板卡片层：`#131720`（RGB 19, 23, 32），微带板岩冷灰，带来清晰结构分层。
  - 悬停/激活层：`#1a202c`（RGB 26, 32, 44）与 `#222938`。
  - 亚像素边框：`#232936`（RGB 35, 41, 54）或 `rgba(255, 255, 255, 0.07)`。
  - 品牌点睛色升级为**钛金暖琥珀**：`#f59e0b`（RGB 245, 158, 11），悬停 `#fbbf24`，按压 `#d97706`；兼顾品牌记忆与高对比度，干净明亮而不刺眼。
  - 功能状态色：工作翡翠绿 `#10b981`、就绪冰蓝 `#38bdf8`、空闲灰板岩 `#64748b`、危险/终止红 `#f43f5e`。
  - **红线底线**：严禁任何紫色（杜绝劣质 AI 渐变）、严禁花哨杂色。见 `mockups/design-tokens.css`。
- **为什么**：顶尖生产力工具（如 Linear、Raycast、JetBrains Fleet、Warp）均采用冷峻深黑打底，配合高精度单一原色聚焦。去掉泥土褐色后，整体质感立现严谨、专业的工业精密仪器感。

### 2. 排版字体：告别错位衬线，拥抱工控现代无衬线与等宽数字
- **现在什么样**：大标题与 KPI 数字使用传统古板的 `Georgia, 18/22, Bold` 衬线体，与界面中的 YaHei UI 及等宽路径严重脱节，有生硬的旧式排版感；数字不是等宽制表体，左右参差不齐。
- **希望什么样**：
  - 界面标题全面切换为无衬线工控字阶：`Segoe UI Variable Display` / `Segoe UI`（降级使用 `Microsoft YaHei UI`，粗细 600/Bold，字距缩紧 -0.02em）。
  - 关键度量、Token 统计、PID、时间戳、文件路径统一采用等宽字体：`Cascadia Code` / `JetBrains Mono` / `Consolas`，开启等宽对齐（Tabular Figures）。
- **为什么**：启动器是开发者的高频效率工具，衬线体在低分辨渲染下易发虚、显老派；现代无衬线配合等宽数字能够保证数据垂直对齐不抖动，阅读效率显著提升。

### 3. 导航切换：从“瞬移线段”升级为“一体化胶囊滑块（Segmented Pill Slider）”
- **现在什么样**：顶部导航是一排分散的 Flat Button，点击后仅文字变色，底部的 2px `$navLine` 突兀地瞬移到对应按钮下方，没有平滑过渡；右侧缺少状态数量感知。
- **希望什么样**：
  - 导航做成一体化深色胶囊底座（Segmented Control），内嵌滑动胶囊高亮块（`mockups/index.html` 中的 `#tabIndicator`）。
  - 点击或切换时，指示块平滑滑入选中项（180ms cubic-bezier）；页面内容伴随轻微平滑渐变与 4px 垂直微位移。
  - 在“监视”标签右侧增加微型状态徽章（如绿底深色的 `4`），直观提示后台活动窗口数。
- **为什么**：平滑移动的胶囊指示器能赋予界面极强的“实体感”和操作连贯性，消除生硬的跳变。

### 4. 切换与按键物理回弹动效（Tactile Key Feedback）
- **现在什么样**：按钮悬停仅轻微换色，按下（Click）毫无行程位移感，操作反馈极其迟钝软绵。
- **希望什么样**：
  - **Hover 态**：按键表面微提亮并伴随极细高光轮廓（border-color 高亮，鼠标为手型 Hand）。
  - **Active 态（按下刹那）**：引入“微型物理机械行程”反馈。在 CSS/原型中实现为 `transform: translateY(1px) scale(0.97)`；在 WinForms 中通过 `MouseDown` 将按钮 Padding 下移 1px 并绘制轻微深色遮罩，松开时反弹。
  - **操作完成提示**：点击任意功能键（如继续会话、恢复、终止），底部状态栏立刻以暖琥珀色短暂停留闪烁“已拉起终端会话...”并在 2 秒后平滑复原，给用户明确的操作确认闭环。
- **为什么**：实体按键行程反馈与状态栏回执是消除“脚本粗糙感”的最有效手段，带来清脆利落的操作手感。

### 5. 图标与符号：严禁 Unicode Emoji，全面采用纯矢量线条与工控几何
- **现在什么样**：使用字符 `★`、`☆`、`⌕`、`▸`、`▾`、`●`，不同机器由于字体回退机制，会导致星标发灰、搜索符不对齐、三角符号忽大忽小。
- **希望什么样**：
  - 彻底封杀任何彩色 Unicode Emoji（无 🚀、🤖、⭐ 等）。
  - 搜索栏改用标准 14px 细线放大镜矢量图形，右侧带极客徽章 `Ctrl+F`。
  - 置顶星标使用纯几何矢量星（未置顶为细边框线条，置顶为钛金暖琥珀实心填充，并带弹跳回弹动效）。
  - 折叠展开三角使用 14px 矢量 Chevron，展开时顺畅旋转 90 度。
- **为什么**：矢量图形在任何 Windows 缩放比例下都保持绝对清晰一致，杜绝字符集兼容性问题。

---

## 仪表盘（Dashboard）

见原型：[`mockups/dashboard.html`](file:///d:/Project/Grok%E5%B7%A5%E4%BD%9C%E6%96%87%E4%BB%B6%E5%A4%B9/%E6%95%88%E7%8E%87%E5%B7%A5%E5%85%B7/Grok%E6%9C%80%E8%BF%91%E9%A1%B9%E7%9B%AE%E5%90%AF%E5%8A%A8%E5%99%A8/ux/mockups/dashboard.html) 及架构图 [`mockups/wireframe-overview.svg`](file:///d:/Project/Grok%E5%B7%A5%E4%BD%9C%E6%96%87%E4%BB%B6%E5%A4%B9/%E6%95%88%E7%8E%87%E5%B7%A5%E5%85%B7/Grok%E6%9C%80%E8%BF%91%E9%A1%B9%E7%9B%AE%E5%90%AF%E5%8A%A8%E5%99%A8/ux/mockups/wireframe-overview.svg)

### 1. 顶部 5 张度量指标卡（KPI Cards）
- **现在什么样**：5 个平板色块横排，无内外边框分界，大号 Georgia 字体显得笨拙，信息没有呼吸感。
- **希望什么样**：
  - 每张卡片拥有独立的 `#131720` 背景与 `#232936` 亚像素边框，四角 6px 圆角。
  - 第一张 Hero 卡片（近 7 天总量）增加 `rgba(245, 158, 11, 0.05)` 径向极弱微光，大数字采用 26pt 加粗等宽制表体，底部配有翡翠绿的环比趋势徽章（如 `↑ 14.2%` 较上周同期）。
  - 鼠标悬停时，边框平滑高亮并微浮 1px。
- **为什么**：首屏第一眼建立视觉聚焦点，主指标与副指标层级分明，呈现如监控大屏般的高级质感。

### 2. Token 趋势图表区（Usage Chart）
- **现在什么样**：图表柱子是暗黄单色块，峰值柱仅仅是浅黄棕；时间范围切换是右侧散放的四个按钮；悬停 Tooltip 是固定在右上角生硬的黑框。
- **希望什么样**：
  - 时间范围切换（今天 / 7天 / 30天 / 全部）升级为一体化紧凑微型胶囊。
  - 柱状图：普通柱子采用板岩深灰（`#2d3546`），今日/峰值柱采用**暖琥珀垂直微渐变**（`#fbbf24` -> `#b45309`），柱顶增加 2px 微圆角。
  - 悬停浮层：采用带有亚像素细边框的浮动半透明暗色卡片，清晰罗列：精确日期、总量、输入与占比、输出与占比、环比增长率，悬停柱子微发亮。
- **为什么**：突出峰值与今日关键数据，防止整张图表淹没在一片暗色中；微渐变与圆角让 GDI+ 自绘具备现代图形的精致感。

### 3. 项目用量排行（Rank）与最近会话（Recent Sessions）
- **现在什么样**：
  - 左侧排行榜每行只有一根暗黄横条，排名数字无标识，显得单调空洞。
  - 右侧最近会话使用原生 Windows 微调框（NumericUpDown），白色上下箭头极其突兀，右侧跟一个大黄块按钮。
- **希望什么样**：
  - 左侧排行榜：增加等宽序列徽章（`01`, `02`...），进度条底槽使用深度暗轨（`#1c222e`），前景条使用微渐变金琥珀填充，加载时宽度平滑展开。
  - 右侧最近会话：剔除原生微调框，定制扁平无缝步进器（`[−] 5 [+]`）；“恢复最近 5 个会话”改为带矢量播放箭头的实体高光按钮，悬停微亮、按压下沉。
  - 会话行：悬停背景平滑提亮，右侧显示对齐的等宽时间（如 `18 分钟前`），双击即可快速拉起对应会话。
- **为什么**：彻底清除原生 WinForms 控件破坏暗黑整体风格的死角，步进器与高亮操作键大幅提升桌面启动操作效率。

### 4. 自适应高度与消灭原生白底滚动条（Scrollbar & Layout Tuning）
- **现在什么样**：当排行榜或列表产生轻微纵向溢出时，浏览器或操作系统直接调用 Windows 原生 17px 宽粗白色滚动条（白底灰滑块配上下箭头），硬生生横切在暗黑卡片中间，极其突兀廉价（见反馈截图）。
- **希望什么样**：
  - **高度预算与紧凑排版**：行内边距从 `8px 12px` 优化为 `6px 10px`，行间距调至 `4px`，外层框架高度设为 `760px`（最小 `680px`），使 TOP 4 排名与 5 个活跃会话在标准分辨率下**舒适舒展、完全不触发多余滚动条**。
  - **全局暗黑极简滚动条规范**：全局声明 `color-scheme: dark;`，并定制 5px 细致半透明滚动条（`scrollbar-width: thin; scrollbar-color: #2b3345 transparent;`），滑块使用圆角暗岩色 `#252d3d`（悬停微亮 `#3b465c`），彻底杜绝任何白底控件外露。
- **为什么**：暗黑主题下哪怕露出一像素传统白底控件，都会瞬间打破极客控制台的高级质感；自适应消除不必要滚动条，辅以 5px 超薄深色滑动条，整体观感纯净流畅。

---

## 项目（Projects）

见原型：[`mockups/projects.html`](file:///d:/Project/Grok%E5%B7%A5%E4%BD%9C%E6%96%87%E4%BB%B6%E5%A4%B9/%E6%95%88%E7%8E%87%E5%B7%A5%E5%85%B7/Grok%E6%9C%80%E8%BF%91%E9%A1%B9%E7%9B%AE%E5%90%AF%E5%8A%A8%E5%99%A8/ux/mockups/projects.html) 及架构图 [`mockups/wireframe-projects.svg`](file:///d:/Project/Grok%E5%B7%A5%E4%BD%9C%E6%96%87%E4%BB%B6%E5%A4%B9/%E6%95%88%E7%8E%87%E5%B7%A5%E5%85%B7/Grok%E6%9C%80%E8%BF%91%E9%A1%B9%E7%9B%AE%E5%90%AF%E5%8A%A8%E5%99%A8/ux/mockups/wireframe-projects.svg)

### 1. 顶部操作栏与搜索交互（Toolbar）
- **现在什么样**：搜索栏是一块生硬的内凹框，字符 `⌕` 不美观；按钮横排挤在一起，“继续最近会话”是大面积实心黄块，其余按钮是灰框线，视觉层级过于扁平或失衡。
- **希望什么样**：
  - 搜索框内嵌极细放大镜 SVG，右侧附带暗色快捷键徽章 `Ctrl+F`，输入框聚焦时边框发光点亮。
  - 搜索框旁增加高对比度的“已选择项目”状态胶囊（例如 `已选择: shop-web`），未选中时显示浅灰色“未选择”，给用户清晰的上下文状态。
  - 按钮层级重塑：
    - **主行动键（继续最近会话）**：暖琥珀色填充，字体加粗，微带光晕，按下具备 1px 机械下沉反馈。
    - **次级行动键（新建会话、指定文件夹、打开终端、资源管理器、刷新）**：统一为板岩暗色微边框按钮，鼠标悬停时平滑提亮，图标与文字保持严格 6px 间距。
- **为什么**：高频核心动作突出，辅助功能收敛，用户在 0.5 秒内就能本能按下最需要的按键，无需费神寻找。

### 2. 项目表格（Data Table）
- **现在什么样**：使用 DataGridView 默认黑黄相间的斑马纹（Alternating Rows），选中行整行变为刺眼的亮黄褐色，星标是纯文本符号 `★` 和 `☆`。
- **希望什么样**：
  - **移除斑马纹**：统一行背景色，行间改用 1px 极低透明度分隔线（`rgba(255, 255, 255, 0.03)`），告别表格切割感。
  - **优雅选中态**：行左侧边缘保留 3px 钛金暖琥珀指示光条，整行底色叠加 8% 极淡琥珀冷调（`rgba(245, 158, 11, 0.08)`），文字高亮为纯白，既醒目又护眼。
  - **星标置顶动画**：改用纯矢量星标；点击置顶时触发轻微弹性缩放（1.2x Spring Pop），置顶状态保持纯金琥珀色，未置顶保持微暗轮廓线。
  - 列宽与排版：项目名称加粗、路径采用等宽淡灰色并支持悬停 Tooltip 完整显示。
- **为什么**：淘汰传统斑马纹是现代桌面端设计的一致趋势，精细的悬停与左侧选中条让长列表浏览更清爽利落。

---

## 监视（Watch）

见原型：[`mockups/watch.html`](file:///d:/Project/Grok%E5%B7%A5%E4%BD%9C%E6%96%87%E4%BB%B6%E5%A4%B9/%E6%95%88%E7%8E%87%E5%B7%A5%E5%85%B7/Grok%E6%9C%80%E8%BF%91%E9%A1%B9%E7%9B%AE%E5%90%AF%E5%8A%A8%E5%99%A8/ux/mockups/watch.html) 及架构图 [`mockups/wireframe-watch.svg`](file:///d:/Project/Grok%E5%B7%A5%E4%BD%9C%E6%96%87%E4%BB%B6%E5%A4%B9/%E6%95%88%E7%8E%87%E5%B7%A5%E5%85%B7/Grok%E6%9C%80%E8%BF%91%E9%A1%B9%E7%9B%AE%E5%90%AF%E5%8A%A8%E5%99%A8/ux/mockups/wireframe-watch.svg)

### 1. 状态指示器、顶栏分类筛选与活跃呼吸动效
- **现在什么样**：顶部仅有一行纯文本字符；卡片上的状态只是一个静态无感纯色字符圆点 `●`；无法根据工作状态分类筛选。
- **希望什么样**：
  - 顶部重塑为卡片化状态汇总条（Summary Strip），内置【全部 4】、【工作中 1】、【空闲 2】、【刚创建 1】四档可切换胶囊筛选键，点击瞬时过滤卡片列表。
  - 状态指示灯引入**多级呼吸脉冲动效**：
    - 工作中（Working）：翠绿圆点外层叠加柔和的扩散光环脉冲（`pulse-ring` 动效，2 秒扩散波纹），直观表达进程正在高频运转。
    - 刚创建（Created）：清澈冰蓝常亮，提示新拉起就绪。
    - 空闲（Idle）：低调板岩灰常亮。
- **为什么**：动效在这里具备至关重要的功能性——无需看文字，用户用余光就能在多任务并发时一眼捕捉哪些进程正在写代码、哪些已就绪等待。

### 2. 活跃卡片顶边缘激光掠扫流光（Laser Shimmer Sweep）
- **现在什么样**：活跃卡片与静止卡片边框完全相同，缺乏层次与生命力，静态界面像“卡死”了一样。
- **希望什么样**：
  - 在当前处于“工作中”的进程卡片顶边缘（Top Edge），嵌入一条 2px 高精激光流光槽（`card-laser-track`）。
  - 一束由翡翠绿过渡到钛金琥珀的渐变光斑以 `2.2s` 周期在卡片顶端极速掠过（`@keyframes laser-sweep`），并带有轻微的向外漫反射微光（Ambient Glow）。
- **为什么**：赋予正在执行长耗时任务（如大型代码重构、全库检索）的会话强烈的“实体仪器运行感”，消除用户的等待焦虑。

### 3. 工具状态胶囊与微型旋转技术陀螺（Technical Rotating Spinner）
- **现在什么样**：仅在文本中简单罗列 `正在执行: search_replace`，静态呆板，无法区分是正在执行中还是已执行完。
- **希望什么样**：
  - 当前正在调用的工具名以板岩深色芯片包裹（`badge-chip working`），左侧内嵌一个极细矢量弧线 Spinner（`spin-icon`），以 `1.4s` 匀速无级旋转。
  - 配合实时跳动的运行秒数（如 `已运行 04:18` 每秒递增），直观展示当前任务执行已持续时长。
- **为什么**：微型旋转动效是现代极客开发工具（如 VS Code Copilot, Warp, Cursor）的标准动作语言，给用户强烈的即时反馈。

### 4. 节点式横向调用流水线（Execution Flow Pipeline）与能量流动虚线
- **现在什么样**：点击展开后，仅在右侧散乱堆砌几个纯文本词，无法获知完整的处理步骤处于什么阶段。
- **希望什么样**：
  - 展开卡片顶部横向铺设一条结构化的**调用流程节点链**：
    `[1. 接收需求 ✓] ──▶ [2. read_file ✓] ──▶ [3. ripgrep ✓] ──▶ [4. search_replace (执行中 ⟳)] ──▶ [5. 终端验证 ⋯]`
  - **已完成节点**：翠绿细边框与绿勾 `✓`，背景带有 8% 极淡翡翠绿。
  - **正在执行节点**：钛金暖琥珀边框，内嵌旋转 Spinner，伴随 `pulse-amber-glow` 呼吸光晕。
  - **前后节点连接箭头**：由第 3 步指向第 4 步的箭头线段采用流光虚线动画（`flow-line`），虚线以 `0.8s` 速度向前流动（`stroke-dashoffset`），形成明显的“能量正在注入执行步骤”的视觉流动感。
  - **未开始节点**：半透明灰度与省略号 `⋯`。
- **为什么**：用户无需逐字阅读冗长日志，单看这一条横向流水线就能对 Grok“卡在哪一步、做了哪些前置检索、接下来要做什么”一目了然。

### 5. 10 段式实体感 Context 容量槽（Segmented Context Meter）
- **现在什么样**：用纯文本打印 `Context: 62%` 或普通细进度条，容易让用户误以为是“任务进度条”。
- **希望什么样**：
  - 将上下文占用升级为**10 格微型工业 LED 物理刻度槽**（`[■■■■■■□□□□]`）：
    - 0%~30%：前 3 格使用翠绿 LED（健康安全）。
    - 31%~70%：中间 4 格使用钛金暖琥珀 LED（高负荷提醒）。
    - 71%~100%：末尾 3 格使用警示橙红 LED（需留意截断风险）。
    - 未占用格保持暗灰微凹槽。
  - 旁边清晰标注百分比与绝对 Token 数：`62% (124K/200K)`，鼠标悬停显示精确 Tooltip。
- **为什么**：彻底消除“Context = 任务进度”的认知混淆，物理分段 LED 槽直观传递硬件/资源负荷状态。

### 6. 实时等宽控制台流（Live Monospace Terminal Stream）与跳动光标
- **现在什么样**：卡片展开后是一个生硬的原生只读多行文本框（TextBox），文字密密麻麻挤成一坨。
- **希望什么样**：
  - 展开区右栏升级为沉浸式纯黑终端活动流（`#liveConsoleStream`），采用等宽工控字体，记录带有精准时间戳与状态标签的日志（`[INIT]`, `[TOOL]`, `[EXEC]`, `[TEST]`, `[SYNC]`）。
  - 最新的正在执行行末尾附带琥珀色闪烁光标 `▌`（`@keyframes blink-cursor` 0.9s 周期闪烁）。
  - 随着时间推移，新日志流平滑自动滚入，始终呈现鲜活、跳动的命令行工作站氛围。
- **为什么**：控制台流呈现出黑客级的精细质感，让后台复杂的脚本行为透明化、可视化。

### 7. 操作按钮与防误触机制（打开 / 终端 / 结束）
- **现在什么样**：“打开”是黄色块，“终端”是灰框，“结束”是红字黑框；点击“结束”直接弹出系统 Message Box。
- **希望什么样**：
  - “打开”和“终端”统一为精致的工控微型按键，悬停微亮，按压有 1px 物理机械行程反馈。
  - “结束”按键默认采用危险红细线轮廓，鼠标悬停时背景泛起微红，点击后就地触发确认，防止误触杀掉关键会话。
- **为什么**：危险操作需要视觉隔离与心理缓冲，统一按键规格让界面井然有序。

---

## WinForms / PowerShell 具体落地实现策略（给整合者的代码指导）

在整合修改 `GrokRecent.ps1` 时，可直接参考以下免踩坑技术方案：

### 1. 窗口暗色标题栏（DWM Dark Titlebar）
WinForms 默认标题栏为白色，在加载窗体后通过 P/Invoke 调用 DWM 即可无痛将系统标题栏变为真正的纯黑：
```powershell
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class DwmUtil {
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
}
"@
# 在 $form 句柄创建后调用 (attr 20 = DWMWA_USE_IMMERSIVE_DARK_MODE)
$darkMode = 1
[DwmUtil]::DwmSetWindowAttribute($form.Handle, 20, [ref]$darkMode, [System.Runtime.InteropServices.Marshal]::SizeOf([type][int]))
```

### 2. 双缓冲与抗锯齿绘制（消除闪烁与毛边）
- 所有自定义绘制的 Panel 或 Form 务必开启双缓冲：
  ```powershell
  $type = $grid.GetType()
  $prop = $type.GetProperty("DoubleBuffered", [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic)
  $prop.SetValue($grid, $true, $null)
  ```
- GDI+ 绘图设置：
  ```powershell
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
  ```

### 3. 按键物理下沉动效（MouseDown / MouseUp 行程反馈）
在 `New-BarButton` 中统一挂载按下与松开事件，无需复杂代码即可产生机械按键般的 1px 物理回弹：
```powershell
$b.Add_MouseDown({
    $this.Padding = New-Object System.Windows.Forms.Padding(0, 2, 0, 0)
})
$b.Add_MouseUp({
    $this.Padding = New-Object System.Windows.Forms.Padding(0, 0, 0, 0)
})
```

### 4. 底部状态栏操作回执闪烁（Feedback Toast）
定义一个轻量状态提示函数：
```powershell
function Show-StatusFeedback {
    param([string]$Msg)
    $status.ForeColor = $accent
    $status.Text = $Msg
    # 2 秒后复原为默认提示文字
    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = 2200
    $t.Add_Tick({
        $status.ForeColor = $muted
        $status.Text = $script:defaultStatusText
        $this.Stop(); $this.Dispose()
    })
    $t.Start()
}
```

### 5. 监视页动画落地：轻量 Timer 驱动 GDI+ 激光扫掠（Laser Sweep）
在 WinForms 中无需引入复杂的第三方动画库，利用轻量级的 UI 刷新 Timer（如 50ms 周期，仅在有工作进程时激活）：
```powershell
$animTimer = New-Object System.Windows.Forms.Timer
$animTimer.Interval = 50
$script:laserPhase = 0.0

$animTimer.Add_Tick({
    $script:laserPhase += 0.04
    if ($script:laserPhase -gt 1.5) { $script:laserPhase = -0.5 }
    # 局部无效化工作卡片顶边缘 2px 区域，触发重绘且不浪费 CPU
    $activeCardTopStrip.Invalidate()
})

$activeCardTopStrip.Add_Paint({
    param($sender, $e)
    $g = $e.Graphics
    $w = $sender.Width
    $beamW = [int]($w * 0.4)
    $startX = [int]($w * $script:laserPhase)
    $rect = New-Object System.Drawing.Rectangle($startX, 0, $beamW, 2)
    if ($rect.Right -gt 0 -and $rect.Left -lt $w) {
        $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
            $rect,
            [System.Drawing.Color]::FromArgb(0, 16, 185, 129),
            [System.Drawing.Color]::FromArgb(255, 245, 158, 11),
            [System.Drawing.Drawing2D.LinearGradientMode]::Horizontal
        )
        $g.FillRectangle($brush, $rect)
        $brush.Dispose()
    }
})
```

### 6. 10 段式 LED Context 刻度槽 GDI+ 极简自绘
在卡片头部绘制规整对齐的 10 段物理槽：
```powershell
$ctxPanel.Add_Paint({
    param($sender, $e)
    $g = $e.Graphics
    $slots = 10
    $filledSlots = [Math]::Min(10, [Math]::Max(0, [int][Math]::Round($currentRatio * 10)))
    for ($i = 0; $i -lt 10; $i++) {
        $x = $i * 6
        $c = if ($i -lt $filledSlots) {
            if ($i -lt 3) { [System.Drawing.Color]::FromArgb(16, 185, 129) } # 绿
            elseif ($i -lt 7) { [System.Drawing.Color]::FromArgb(245, 158, 11) } # 琥珀
            else { [System.Drawing.Color]::FromArgb(244, 63, 94) } # 橙红
        } else {
            [System.Drawing.Color]::FromArgb(28, 34, 46) # 暗槽底色
        }
        $b = New-Object System.Drawing.SolidBrush($c)
        $g.FillRectangle($b, $x, 2, 4, 6)
        $b.Dispose()
    }
})
```

---

## 不要改的

- **不要往监控站加功能**：保持本地 Launcher 与 Sessions 数据轻量读取的纯粹定位。
- **交稿/审核不在这个启动器里**：不增加任何与任务评审相关的多余业务逻辑。
