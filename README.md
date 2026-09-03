# Morse Runner — 跨平台版 (Cross-Platform)

> 本项目由 **BH5HIE** 维护。基于 [w7sst/MorseRunner](https://github.com/w7sst/MorseRunner)
> （Morse Runner Community Edition，MPL-2.0）的 Swift 跨平台重构。

[原项目](https://github.com/w7sst/MorseRunner)（Morse Runner Community Edition）是 Delphi/Pascal + Windows VCL 编写的业余无线电 CW 比赛模拟器，**只能在 Windows 上运行**。
本仓库用 **Swift 重新实现**了它的引擎和界面，目标是在 **macOS / Linux / Windows** 上运行：

| 平台 | 状态 |
|------|------|
| macOS | ✅ 原生 GUI（AppKit + AVAudioEngine），`dist/MorseRunner.app`（arm64 + x86_64 通用） |
| Linux | ✅ 引擎 + 终端 UI（纯 Foundation，无第三方依赖）；音频输出待接入 PortAudio |
| Windows | 🚧 引擎/终端 UI 可构建（Swift on Windows）；GUI 待开发 |

## 功能

- **全部 12 个比赛**：CQ WPX、CQ WW、ARRL DX、ARRL Field Day、ARRL Sweepstakes、NCJ NAQP、CWOPS CWT、K1USN SST（Farnsworth）、JARL ALL JA、JARL ACAG、IARU HF、HST
- 完整的模拟引擎：DX 台站生成/呼叫/通联状态机、LID/鬼影、QSB/QRM/QRN/Flutter、序列号生成（WPX 分布）、计分/校验/错误纠正
- DSP 链路：CW 包络（Blackman-Harris 平滑）、滤波器、调制器、AGC、自监听（原版算法逐行移植）
- 数据文件：`Resources/` 下的 DXCC.LIST、Master.dta、各比赛历史文件（与原版一致）

## 构建

环境要求：**Swift 6+**（macOS 自带；Linux 安装 [swift.org](https://www.swift.org/download/) 工具链）。

```bash
# 全部 target（调试）
swift build

# macOS 应用（release + 打包 .app）
./make-app.sh            # 生成 dist/MorseRunner.app

# 终端 UI（macOS / Linux 通用）
swift run MorseRunnerTUI --call VE3NEA --contest 0 --duration 10 --wav run.wav

# 无头引擎测试（CI 也用这个）
swift test
```

### Linux

```bash
sudo apt-get install -y binutils git gnupg2 libc6-dev libcurl4-openssl-dev \
     libedit2 libgcc-13-dev libpython3-dev libstdc++-13-dev libxml2-dev \
     libncurses-dev pkg-config tzdata unzip zlib1g-dev   # swift 依赖
swift build
.build/debug/MorseRunnerTUI --help
```

### 无音频/CI 模式

设置 `MORSE_RUNNER_NO_AUDIO=1` 后，模拟仍按真实时间推进（512 采样/块 @ 11025 Hz ≈ 46 ms），只是不发声，适合测试、CI 和无声练习。

## 使用

### macOS GUI

- 顶部选择比赛、我的呼号、发送交换字、运行模式（Pile-Up / Single Calls / COMPETITION / H S T）
- 输入区：`Call | RST | Exch` 三个输入框（RST 栏多数比赛自动填充，可手工修改）
- 波段条：CW 速度、音高、带宽、活动度、时长，以及 **RxMax / RxMin**（对应原版菜单
  Settings → CW Max/Min Rx Speed，取值 0/1/2/4/6/8/10，0 = 与发送速度一致）
- 快捷键：`F1` CQ、`F2` NR、`F3` TU、`F4` MyCall、`F5` HisCall、`F6` B4、`F7` ?、`F8` NIL、`F11` 清空、`Esc` 中止、`.`/`,`/`+`/`[` 保存 QSO、`;` 发呼号+序号、`Ctrl-W` 清空
- Tab / Space：**运行中** `Tab` 在 Call / Exch1 / Exch2 之间循环切换；`Space` 在 Callsign 与 NR 之间切换（停止时 Tab 为系统默认行为）
- Touch Bar（MacBook Pro）：Run/Stop、CQ、Exch、TU、MyCall、HisCall、? 一键操作；输入框不占候选词条
- 主音量滑杆解决原版"20k/32k 满幅"过响问题（采样已归一化到 -1..1）

> 关于"只有噪音"：`Run` 后未发 CQ 时的"沙沙"声是模拟接收机底噪（原版
> 同样如此，AGC 后约 -30 dBFS）。发 CQ 后约 0.5 秒内应有 DX 台站回应；
> 若第一次 CQ 无人回应（约 37% 概率，原版 `Poisson(Activity/2)` 行为），
> 再次按 CQ 即可。DX 台站音高在 ±300 Hz 内随机偏移是原版设计（模拟不同
> 电台的调谐差异），听起来与自己的侧音略不同属正常现象。

### Terminal UI（跨平台）

```
<呼号> 回车    录入呼号（与 GUI 相同流程）
r / s          运行 / 停止
m <mode>       模式: pileup|single|wpx|hst
cq nr tu my his b4 qm nil   功能键消息
.               发送 TU 并保存 QSO
;               发送 <his> <#>
esc             中止发送
w <wpm>  d <min>  a <n>  速度/时长/活动度
--wav out.wav   把本次运行录音为 WAV
```

## 架构

```
Sources/
  MorseRunnerCore/   引擎核心：DSP / Morse / Sim / Contest / Support
                     —— 只依赖 Foundation，macOS/Linux/Windows 通用
  MorseRunnerMac/    macOS 原生应用：AppKit UI + AVAudioEngine 后端
  MorseRunnerTUI/    终端 UI（纯 Foundation，跨平台）
  EngineTest/        无头端到端引擎测试（`swift test`，30+ 项断言）
```

音频通过 `AudioBackend` 协议抽象（对应原版 `SndOut.pas` 的 waveOut 推块模型）：

- `SilentAudioBackend` —— 无设备时仍按时钟推进模拟（默认，测试/CI）
- `AVAudioBackend` —— macOS 的 AVAudioEngine 实现
- Linux 可扩展 PortAudio 后端，接入 `AudioBackend` 即可

## 与原始 Delphi 项目的对应

| 本仓库 | 原项目 |
|--------|--------|
| `Contest/*.swift`（12 个比赛类） | `*.pas`（CqWpx.pas 等） |
| `Sim/`（Station/DxStation/DxOperator/…） | `Station.pas`、`DxStn.pas`、`DxOper.pas`、`StnColl.pas` 等 |
| `DSP/`（Filters/Modulator/VolumeControl/Keyer） | `VCL/Mixers.pas`、`VCL/VolumCtl.pas`、`VCL/MorseKey.pas` 等 |
| `Support/Log.swift`、`Support/Settings.swift` | `Log.pas`、`Ini.pas` |
| `Resources/` | 仓库根目录的数据文件 |

移植约定与过程记录保留在开发历史中。

## 已修复的关键问题（早期 Swift 尝试的 bug）

### 第十四轮修改（社区贡献：PR #2 / PR #3）

**PR #3（[wzh06 / Lewis](https://github.com/wzh06)）**

1. **结果窗新增 QSO 计数**：窗口右上角的 Raw / Verified 两列表格新增首行
  `Qso`；Raw 列显示当前日志中的初始 QSO 数量，Verified 列显示已验证（无错误）
  的 QSO 数量，并随统计结果实时更新。
2. **允许提前按回车发送**：呼号尚未完全输入时即可按下回车开始发送，发送过程中仍可继续修改呼号；已发出的部分保持不变，尚未发送的部分会实时更新。
3. **降低回车后的发送延迟**：调整音频发送队列和轮询间隔，使按下回车后能更快开始发射，目标延迟控制在约 50 ms，同时保持无音频设备时的正常模拟时钟速度。
4. **顺带修复两个崩溃点**：发送中修改呼号时 `envelope` 已排空/变短的越界访问，
  以及 `pieces` 为空时 `1..<0` 无效区间导致的 trap；并新增回归测试覆盖。

**PR #2（[YitsunChu](https://github.com/YitsunChu)）**

5. **Touch Bar 显示问题修复**：WPM 输入框改用无候选词条的 `NoCandidateTextField`；
   `CallInputFormatter`（统一大写、禁中文输入、关闭自动补全）扩展到我的呼号、
   发送交换字与 WPM 输入框；开始编辑输入框时重新挂载窗口 Touch Bar，避免
   Touch Bar 被系统清掉或被候选词条顶掉后不再显示。

### 第十三轮修复（合入 PR #1 + 用户实测反馈）

1. **Touch Bar 支持**（PR #1）：MacBook Pro Touch Bar 上提供 Run/Stop、CQ、Exch、TU、
   MyCall、HisCall、? 按钮，运行状态自动刷新；输入时不再弹出系统候选词条。
2. **CW 速度直接键盘输入**（PR #1）：速度框可点击输入（10-120 wpm），回车生效，
   加减号同步。同时修复了合入后加减号/快捷键改速被输入框旧值覆盖的问题（现在按触发
   来源取值：加减号以 stepper 为准，输入框以文本为准）。
3. **空格键切换焦点**（PR #1）：在 Callsign 输入框按空格切到 NR（Exch2），再按切回，
   光标停在末尾、不清空内容。
4. **输入限制**（PR #1）：Callsign/Exch 输入框只允许 A-Z、0-9、/ 和空格，禁用中文
   输入法，小写自动转大写；回车后不再全选已有文本。
5. **运行中 Tab 循环切换**：Run 后 `Tab` 只在 Call / Exch1 / Exch2 之间循环，光标
   停在末尾；停止时保持系统默认 Tab 行为。
6. **TUI 跨平台构建修复**：移除终端版误引入的 AppKit 死代码，Linux/Windows 构建恢复。
7. **Universal 双架构构建**：macOS `.app` 同时包含 arm64（Apple Silicon）与 x86_64（Intel）
   两种架构，Intel Mac 可直接运行。

### 第十二轮修复（用户实测反馈）

1. **训练时间到后程序无响应（已确认修复）**：到期后 `getAudio()`（运行在音频泵
   的 timer 回调里）同步调用 `AVAudioEngine.stop()`，主线程等待音频渲染线程而
   渲染线程等待主线程，形成死锁、界面冻结。现在音频停止改为**异步执行**（离开
   回调后再 stop，若用户已重新开始则跳过），到期处理只触发一次、后续返回静音。
2. **新增应用图标**：`tools/make-icon.swift` 生成（深蓝圆角 + CW 波形
   `MR` = `-- .-.`），打包时自动合成 `.icns`。

### 第十一轮修复（界面优化）

- **记分改为带边框的两列表格**（Raw | Verified，各含 Pts/Mult/Score），
  固定 250pt 宽，位于右侧、不再溢出/穿模（修复了左侧列宽度约束冲突）。
- **Rate / Pile-Up / HST 移到最底部状态栏右侧**，与时钟同一行。

### 第十轮修复（界面优化）

- **记分回到右侧传统显示**：Raw/Verified 分数（Pts/Mult/Score）、Rate、
  Pile-Up 以多行形式显示在右侧固定宽度侧栏（190pt），从波段条下方延伸到
  记分表区域，窗口宽度不再跳动；顶部第一行保持简短。

### 第九轮修复（界面优化）

- **记分移至右上角**：Raw/Ver 分数、速率、Pile-Up 合并为紧凑横条，固定在
  窗口右上（原右侧独立列导致窗口宽度跳动）；记分表占满剩余宽度。

### 第八轮修复（用户实测反馈）

1. **呼号持久化真正生效**：`setContest` 之前用控制器初始化时的旧呼号覆盖了
   刚从磁盘加载的值；现在改为应用 `Settings.call`（已加载），输入呼号后
   重启保持。
2. **交换字验证/短码修复**：`run()` 会重建 Me（`initContest`），把发送交换
   类型重置为 `undef`，导致 `Invalid exchange` 报错、发送长码。现在 run 后
   恢复交换类型并重新应用交换字：CQ WW 默认 `5NN 3`、WPX `5NN #` 均正常
   验证，发送短码 `5NNTT1`。

### 第七轮修复（用户实测反馈）

1. **记分表恢复显示**：上一轮的自适应宽度约束形成了循环依赖，导致表格被
   压缩消失；改为安全的方式（最小 560pt + 低 hugging 拉伸 + 列加宽），
   表格填满窗口且正常显示。
2. **WPX 序号**：修复 `SetMyExch1`（cut-number 还原 E→5/N→9、同步
   `Me.Exch1`）后，RST 正确为 599，发送短码 `5NNTT1`；序号从 001 开始、
   每个保存的 QSO 后递增（端到端测试验证 001→002→003）。
3. **CQ WW 交换**：根因同 `SetMyExch1`——之前 `Me.Exch1` 未同步，发送的是
   initStation 默认的 `3A OR`。现在发送 `5NN 3`（RST + CQ Zone）。
4. **WPX 短码**：RST 用短码 `5NN`，数字序号按原版 cut-number 规则（0→T、
   9→N），不再发送长码。

### 第六轮修复（用户实测反馈）

1. **重新训练清空历史记录**：点击 Run 开始新一轮时，记分表自动清空。
2. **错误呼号/交换标注**：QSO 保存后若与 DX 台站实际数据不符，日志行实时
   刷新出 `NIL`/`CALL`/`NR` 等标注（原版 ScoreTableUpdateCheck）。
3. **WPX 序号正确递增**：Start of Contest + `#` 从 001 开始，每个保存的 QSO
   后递增（002、003…）；修正了 `SetMyExch2` 的 cut-number 转换（`T/O/N`
   映射）与"#" 语义，以及 run 后序号被错误重置的问题。
4. **CW 速度改填空 + 上下键**：对齐原版 SpinEdit（数字框 + 步进按钮，
   F9/F10/PgUp/PgDn 同样可用）。
5. **F2 标签改为 EXCH**：与原版 `'F2  <exch>'` 一致（实际发送内容仍按比赛
   是序号或交换字）。
6. **记分表自适应宽度**：表格拉伸填满右侧空白，不再留大块空白。

### 第五轮修复（用户实测反馈）

1. **布局修复**：Exch/Activity/Duration 输入框与音量滑块改为固定宽度，
   Self Monitor / Output 滑块各 120pt，不再被压缩。
2. **呼号持久化加强**：输入呼号/交换字时**边输入边保存**（原版 Edit4Change
   dirty 语义），关闭窗口也不会丢。
3. **焦点不再乱跳**：实现原版 `MustAdvance` 机制——只有按回车后才会把焦点
   移到交换框并自动填 599；**在呼号框打字时不会再被抢焦点**。QSO 保存后
   输入框与 RST 一并清空。
4. **界面菜单化（对齐原版）**：主窗口只保留比赛/呼号/交换/Run/模式、速度/
   音高/带宽、条件与音量；**Activity、Duration、CW Max/Min Rx Speed、
   Serial NR 全部移入菜单栏 Settings 菜单**。
5. **Serial NR 按比赛启用**：只有使用序号交换的比赛（CQ WPX、HST）才可用；
   CQ WW（CQ Zone）等比赛下菜单自动禁用。

### 第四轮修复（用户实测反馈）

1. **我的呼号持久化**：之前 `SetMyCall` 返回交换字校验失败时跳过保存；现在
   无条件保存（等价原版 `Edit4Exit`），输入呼号回车/失焦即存。
2. **错误 QSO 不再计入 Verified 分**：`UpdateStats(True)` 现在重算 verified
   分数，只累计无错误（`Err='   '`）的 QSO 与 multiplier（原版行为）。
3. **F5/His Call 使用当前输入的呼号**：发送任何消息前先同步输入框内容，
   不再发上一个 QSO 的旧呼号。
4. **QSO 保存后清空输入与状态**：`SaveQso` 现在等价原版调用完整 `WipeBoxes`
   （清空呼号/RST/交换输入框，重置 CallSent/NrSent）。之前 599 和 NR 残留，
   导致下一个呼号回车时直接用残留值误保存（Nr 空着也记 1）。

### 第三轮修复（用户实测反馈）

1. **CW 流不再默认显示在状态栏**：原版只有开启 Debug → CW Decoder 才显示发送/接收的
   Morse 文本；现在默认关闭（`Settings.debugCwDecoder`），界面右下角干净了。
2. **RST 自动填 599 + 短码**：输入对方呼号回车后，RST 栏自动填 599（原版
   `Advance` 行为，HST 除外）；自己发送的交换字用短码（`5NN001`，测试验证）。
3. **交换字回车保存 QSO**：之前 Exch 输入框回车走的是"发呼号+序号"路径，
   不发送 TU 也不保存；已改为完整回车流程（验证 → TU → 记入日志）。
4. **界面加宽**：Exch/Activity/Duration 等控件不再被压缩（窗口 1190pt）。
5. **呼号/交换字持久化**：输入我的呼号或发送交换字后立即保存，重启不再恢复
   默认值（含每个比赛的交换字表）。
6. **Serial NR 设置恢复**：新增下拉框（Start of Contest / Mid-Contest /
   End of Contest / Custom），Custom 弹窗输入范围（如 `01-99`），对应原版
   Settings → Serial NR 菜单。

### 第二轮修复（用户实测反馈）

1. **Single Calls 模式崩溃（SIGSEGV）**：`Log.updateSbar()` 用 `String(format: "%-45s ...")`
   给 `%s` 传了 Swift String——`%s` 期望 C 字符串指针，release 下直接坏指针崩溃（指针认证
   失败）。DX 台站一开始发送就触发 `debugCwStream` → `updateSbar` → 崩溃。已改为手动
   padding（跨平台安全）。
2. **底噪"潮汐"波动（cv 38%）**：`filt2.points` 没同步（保持默认 129），而主滤波器是
   15 点；每 10 blocks 的 `SwapFilters` 让带宽在 500Hz/85Hz 之间跳变，底噪周期性涨落。
   修复后 cv = 4%，底噪均匀连续（与原版一致）。
3. **DX 呼号内字母间延迟**：`AVAudioBackend` 原来靠 buffer completion 回调（异步回主队列）
   计数未播放块，主线程稍忙就计数虚高 → 播放缓冲断流 → 字符间多出停顿。改为基于
   `playerTime` 真实播放位置调度，彻底消除 completion 延迟影响。
4. **训练时长无法修改**：界面有 `Duration (min)` 输入框但没接线。已接线（1-180 分钟，
   自动持久化）。
5. **输入不自动大写**：原版呼号/交换字输入自动转大写。已加 `UpperCaseFormatter`（边输入
   边转大写，等价 Delphi `OnChange`）。

### 早期 Swift 尝试的 bug

1. **音量爆炸**：原版把 ±32767 整数采样转成 16-bit PCM 播放；移植版直接把整数标度写进 float PCM（要求 -1..1），等于全程满幅削波。现在除以 32768 归一化。
2. **功能完全异常**：
   - 发送文本拼接的是替换前的原始串（含 `<exch1>` 等字面标记），导致发出去的是乱码 CW；改为拼接替换后的文本。
   - AppKit 输入框在**失焦时也会触发 action**（`textDidEndEditing`），点 Run 会莫名自动发 CQ；改为 `sendsActionOnEndEditing = false`，只在回车时触发，等价 Delphi `OnKeyPress`。
   - 无音频环境下 `AVAudioPlayerNode` 初始化直接崩溃（Objetive-C 异常无法捕获）；改为懒加载 + 静音后端，无设备也能跑。
3. **停止后无法重启**：回归测试覆盖 run→stop→run→stop 全流程。

## 已知限制 / Roadmap

- [ ] Linux 实时音频（PortAudio 后端，`AudioBackend` 协议已预留）
- [ ] Windows GUI（Swift on Windows 的 WinUI/终端方案探索中）
- [ ] 频谱/瀑布显示（原版 TWaterfall 控件）
- [ ] WAV 播放（已有录音 `--wav`，播放器待做）
- [ ] 与 N1MM / DXLog 的 UDP 接口
- [ ] `swift test` 单元测试目标（目前是独立的 EngineTest 可执行）

## 贡献者 (Contributors)

| 贡献者 | 角色 / 贡献 |
|--------|-------------|
| [BH5HIE](https://github.com/net3pang) | 项目维护者；Swift 跨平台重构与逐轮修复 |
| [YitsunChu](https://github.com/YitsunChu) | PR #1 Touch Bar 支持与输入优化；PR #2 Touch Bar 显示问题修复 |
| [wzh06 / Lewis](https://github.com/wzh06) | PR #3 结果窗 QSO 计数、发送中改呼号、发送延迟优化与崩溃修复 |

感谢所有通过 PR、实测反馈和建议帮助改进项目的朋友。欢迎 Fork + PR！

## 许可

Mozilla Public License 2.0（与原项目一致，见 `Resources/LICENSE.md`）。
原始 Morse Runner 作者：Alex Shovkoplyas VE3NEA；Community Edition 维护者：Mike W7SST 及社区。
