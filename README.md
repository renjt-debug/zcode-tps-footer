# ZCode-TPS-Footer

给 ZCode 桌面版（macOS / Windows）的每条回答下方加上 DeepSeek 风格的统计徽章：

```
⚡ 70 tok/s | Σ 4.8k tok · 68s · 峰值 109
```

徽章为胶囊造型，颜色取自 ZCode 主题变量（`--color-card` / `--color-border` /
`--color-foreground` / `--color-trajectory-reasoning`），自动跟随深浅色与 Skin Manager 皮肤：

- **大数字（均速）**：平均解码速率 = Σ测速样本 token ÷ Σ测速样本解码时间。测速样本 =
  本轮中 timing 齐备（TTFT 与时长都有、差值为正）的模型调用，每次调用的解码时间已扣除
  该次的首 token 等待；timing 缺失的调用不计入，避免均值虚高
- **Σ tok · Xs**：同一测速样本的 token 数与解码总时长（各次调用耗时之和），与均速可互相换算；
  悬停可见整轮总输出 token（含未参与测速的调用）
- **峰值**：单步最高均速——最快一次调用的平均速度，不是瞬时采样值
- 悬停可看精确数值与完整信息：时间 · 整轮用时（含工具时段）· 首 token 延迟（从提问到
  第一个 token 的整轮延迟）· 均速换算式 · 总输出 · 模型
- 无解码数据的回合（失败/取消）退化为纯文本统计行；仅展示已结束回合，
  最近 24 小时内的历史回答滚动回看时自动补上（服务端查询窗口 24h，前端最多取 800 轮）

## 如何使用

安装成功后日常**无需任何操作**，按需了解以下几点即可：

1. **看统计**：每条回答结束后的底部右侧出现胶囊徽章；鼠标悬停可看精确数值
   （均速换算式 `X tok / Y ms`、整轮总输出、单步峰值、首 token 延迟、模型）。
2. **数据自动就绪**：统计读自 ZCode CLI 的本地数据库，数据服务开机自启
   （macOS：launchd `com.zcode-tps-footer.server`；Windows：任务计划程序
   `ZCodeTPSFooterServer`），仅监听 `127.0.0.1:3117`，无需手动启动。
3. **回看历史**：会话内往回滚动，最近 24 小时内的历史回答会自动补上徽章。
4. **ZCode 升级后**：整包更新会覆盖 app.asar，统计行消失属正常现象，重跑一次
   安装脚本即可恢复（数据服务不受影响）。
5. **个性化**：编辑 `~/.zcode/tps-inject/inject.js` 的 `render()` 可调整字段与样式
   （脚本从磁盘加载，改完重启 ZCode 生效，无需重打 asar）。
6. **关闭/回滚**：运行对应平台的卸载脚本，恢复原生 ZCode 并清理自启项。

## 原理

ZCode 的 CLI 每次模型调用都会把 timing 落进本地 SQLite（`~/.zcode/cli/db/db.sqlite` 的
`model_usage` / `turn_usage` 表，两平台同库同表）。本工具三件套：

1. **数据服务**：常驻的本地小服务（127.0.0.1:3117，仅本机可访问），只读方式
   按回合折叠数据库，吐 JSON。常驻机制：macOS 用 launchd，Windows 用任务计划程序
   （失败时依次退到 schtasks、启动文件夹）。
2. **注入脚本**：安装时在渲染层 `index.html` 加一行 `<script>` 标签（重打包 app.asar，
   原包自动备份），脚本监听界面消息节点，按"用户消息 ID"桥接数据库回合，把统计行
   画在每条回答底部。
3. **安装/卸载脚本**：macOS 为 `install.command` / `uninstall.sh`；Windows 为
   `install.bat`（`install.ps1`）/ `uninstall.bat`（`uninstall.ps1`）。一键装、一键还原。

核心的 `inject.js` 与 `tps_stats_server.py` 两平台共用、一字不改；平台差异全部收敛在
安装脚本里。不动 ZCode 任何业务代码，注入脚本异常全部静默吞掉，最坏情况就是统计行不显示。

## 安装（macOS）

```bash
git clone https://github.com/renjt-debug/zcode-tps-footer.git
cd zcode-tps-footer
bash install.command    # 或 macOS 下直接双击 install.command
# 然后完全退出 ZCode（Cmd+Q）再打开
```

前置要求：macOS + ZCode 桌面版装在 /Applications + Node.js（npx 可用，用于解/打包 asar）。

## 安装（Windows）

```powershell
git clone https://github.com/renjt-debug/zcode-tps-footer.git
cd zcode-tps-footer
# 完全退出 ZCode（含托盘图标）后，双击 install.bat；或在终端执行：
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
```

- **自动探测安装目录**：依次尝试运行中的 ZCode 进程 → 注册表卸载信息 → 常见安装路径；
  装在自定义位置时加参数 `-ZCodeDir "<ZCode 安装目录>"`。
- **演练模式**：`-DryRun` 只走探测/解包/注入/重打包，不替换正式包、不装服务，
  适合先验证可行性。
- 双击 `.bat` 被 SmartScreen 拦截时：右键文件 → 属性 → 勾选"解除锁定"，或改用上面的终端命令。
- 首次安装会自动备份原包为 `app.asar.tps-bak`，随时可回滚。

前置要求：Windows 10/11 + ZCode 桌面版 + Python 3（`python` 在 PATH，脚本会优先用
`pythonw.exe` 避免弹控制台窗口）+ Node.js（npx 可用）。

## 卸载

```bash
# macOS
bash uninstall.sh
```

```powershell
# Windows（完全退出 ZCode 后双击 uninstall.bat，或）
powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1
```

两者都做同一件事：恢复原始 app.asar + 卸载数据服务与自启项，重启 ZCode 即纯原生。

## ZCode 更新后

整包更新会覆盖 app.asar（统计行消失，不影响使用）。**重新跑一次安装脚本即可恢复**
（macOS 双击 `install.command`，Windows 双击 `install.bat`，脚本自动检测并重打）。

## 兼容性说明

- 仅适配 ZCode 3.11.x（Electron 41）；大版本更新后若界面消息节点结构变了，
  需要更新 `inject.js` 里的选择器（`section[data-turn-id]`，其值为用户消息 ID）。
- Windows 3.11.2 已实测：数据库表结构、渲染层 `data-turn-id` 锚点、`</head>` 注入点
  与 macOS 一致；数据服务、任务计划自启、asar 解/注/打包、卸载清理全链路跑通。
- Windows 版注意：注入用 `file:///C:/...` 三斜杠 URI；asar 内路径是反斜杠
  （`out\renderer\index.html`）；替换 app.asar 前必须完全退出 ZCode（文件锁）。
- 统计口径对齐 deepseek-ai/deepseek-harness（MIT）的 `turn-metrics.ts` 语义。

## 常见问题

- **统计行没出现**：`curl http://127.0.0.1:3117/healthz` 看数据服务是否在跑。
- **排障日志**：`~/.zcode/tps-inject/server.log`（macOS 由 launchd 重定向，Windows 由
  `start-server.cmd` 重定向）。Windows 下服务未起时可手动运行
  `~/.zcode/tps-inject/start-server.cmd` 观察报错；服务的管理入口是任务计划程序里的
  `ZCodeTPSFooterServer`（登录时自启，无崩溃自动拉起，服务挂了重启系统或手动再跑一次）。
- **想关掉某个字段**：编辑 `~/.zcode/tps-inject/inject.js` 的 `render()`，重启 ZCode 生效
  （脚本从磁盘加载，不需要重打 asar）。

## 开源声明

### 许可证

MIT，详见 [LICENSE](LICENSE)。

### 免责声明

- 本项目按"原样"（AS IS）提供，不附带任何明示或默示的保证，使用风险由使用者自行承担。
- 本项目是社区第三方工具，**与 Z.ai / ZCode 官方无关**，未获得官方认可或支持；
  "ZCode" 名称及商标归其 respective 所有者所有。
- 本工具的工作方式是重打包 ZCode 应用包（app.asar，原包自动备份），可能不符合
  ZCode 用户协议的相关条款，请自行评估后再使用。
- ZCode 版本更新可能改变界面结构导致统计行失效；最坏情况仅统计行不显示，
  不影响 ZCode 本身，随时可用卸载脚本恢复原生。

### 数据与隐私

- 对 `~/.zcode/cli/db/db.sqlite` 仅**只读**访问（SQLite `mode=ro`），不写入、不修改。
- 数据服务仅绑定本机回环地址 `127.0.0.1`，不对外网开放；**不收集、不上传任何数据**，
  无遥测、无统计上报。

### 致谢

- 统计口径与注入思路参考 [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)（MIT）。
