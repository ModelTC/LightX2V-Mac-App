# 1K / 2K 生成参数设计与实现计划

**Goal:** 支持 Qwen-Image-2.1 的 14 个尺寸预设，默认 1K、1:1，兼顾紧凑排版、直观选择和自定义宽高。

**Architecture:** LightX2VCore 统一管理分辨率档位、比例与准确宽高；AppStore 保留实际宽高作为推理和历史的数据来源。SwiftUI 展示预设状态，Python bridge 按 HEIGHT WIDTH 原样传递尺寸，不改用户的推理 config。

**Tech Stack:** SwiftUI / AppKit、Swift Package、Python 标准库桥接。

## 设计

选用两档分段控件配合七个比例图形按钮。相比包含 14 项的下拉菜单，常用操作无需展开菜单；相比 14 张卡片，切换档位保留比例，节省空间。延续暖白背景、深灰文字，使用现有赤陶色强调选中比例；按钮拥有悬停、键盘焦点和无障碍选中状态。

侧栏稍增至 280 点，水平边距 20，比例使用四列网格，图形按实际长宽比绘制。控件间距 12–18 点、卡片圆角 8，标签字号 10–11、输入值 12–13，沿用系统字体与数字等宽字体。宽、高始终可编辑，中间的交换按钮保留实际尺寸；自定义尺寸时没有比例误选，显示「自定义」。切换档位时，自定义尺寸采用最接近的比例预设。随机种子保留输入与每次随机开关，不新增推理详情。

首次打开与「新建创作」恢复 1K、1:1。复用历史保留实际尺寸，匹配到预设时同步档位和比例，否则维持自定义尺寸。非法宽高在输入区域就近提示，阻止生成；生成期间仍允许准备下一次参数，不影响已提交请求。

## 实现与验收

1. `Sources/LightX2VCore/GenerationSize.swift`：定义 7 比例、2 档准确映射、默认值、切换/交换/恢复逻辑。1K 使用本地 LightX2V 的 image_dimensions(1024, ratio) 计算结果；2K 使用 QwenLM/Qwen-Image-2.1 README 的官方推荐表，不能简单把 1K 翻倍。
2. `Sources/LightX2VApp/AppStore.swift`：接入尺寸状态、默认重置、历史复用、尺寸有效性。`Models.swift` 与 `Resources/bridge.py`：单边限制由 2048 调整为 2752，继续要求不小于 256 且为 32 的倍数。
3. `Sources/LightX2VApp/GenerationParametersView.swift`：实现紧凑参数面板；`SettingsView.swift` 移除旧预设，`Views.swift` 调整侧栏宽度。
4. 扩展 `Tests/LightX2VCoreTests/ModelTests.swift` 验证全部映射、默认、档位切换、横竖交换、自定义和复用。扩展 `Tests/test_bridge.py` 验证 14 组尺寸和 2K 横竖图的 HEIGHT WIDTH 顺序及输出验证。
5. 执行 `swift run LightX2VCoreChecks`、`/opt/miniconda3/envs/torch/bin/python -B -m unittest discover -s Tests -v`、`bash scripts/build.sh`。隔离状态启动 APP，检查默认、1K/2K切换、横竖交换、输入、历史复用、最小窗口和键盘交互。
6. 更新 README，提交并推送 main，确认 GitHub 自动构建和 latest 包更新成功。

本次不以真实 2K 模型推理的性能或画质为验收依据；使用隔离 CLI 完整验证参数传递和 PNG 尺寸，不声称已实测全部尺寸的模型推理。

## 验证结果

- Swift 6 组核心检查、Python 14 项测试全部通过；涵盖所有 14 个尺寸预设及 2K 横竖输出的协议集成。
- arm64 Release 构建、签名验证、ZIP 解压后的签名和内容检查通过。
- 隔离工作空间实测：默认 1K 1:1、4:3 跨档位切换、2K 9:16 与横竖互换、手动尺寸、空白/非数字/不对齐值禁用生成、恢复预设、新建默认值、2K 和自定义历史复用、每次随机开关均通过。
- Tab 聚焦比例按钮、空格选择通过；缩小到接近最小窗口后，控件未横向截断，底部种子可滚动访问。
