# 死神 vs 火影（macOS 可玩包）

在 macOS 上下载即可开始玩的《死神 vs 火影》启动包（Wine + Adobe AIR）。

游戏内容基于开源项目 [5DPLAY-Game-Studio/BleachVsNaruto](https://github.com/5DPLAY-Game-Studio/BleachVsNaruto)（GPL）。

## 下载

到 **[Releases](https://github.com/wwwcccsj-design/BleachvsNaruto/releases)** 下载最新的：

**`BleachVsNaruto-macOS.zip`**

## 安装与启动

1. 解压 zip，得到 `启动死神vs火影.app`
2. 若系统提示「已损坏 / 无法打开」，在终端执行：

```bash
xattr -cr ~/Downloads/启动死神vs火影.app
```

（把路径换成你解压后的实际位置）

3. 双击 `启动死神vs火影.app` 启动
4. 首次启动会初始化 Wine，可能稍慢；资源加载完成后点 **开始测试** 进入对战
5. 建议把界面里的 **帧率** 设为 **60** 再开战

## 操作说明

- 需要 **英文键盘布局**（启动器会尽量自动切换；若按键无反应，手动切到 ABC / U.S.）
- 右侧调试面板可隐藏；侧栏挡住时可能抢焦点导致键盘失灵
- 仅支持 **Apple Silicon / Intel Mac + macOS**，不提供 Windows / Android 安装包

## 系统要求

- macOS 14 或更新版本（更早版本未完整测试）
- 约 1.5 GB 可用磁盘（解压 + 首次运行缓存）
- 显示器建议 60Hz；Wine 下帧率可能波动属正常现象

## 仓库内容

| 内容 | 说明 |
|------|------|
| [Releases](https://github.com/wwwcccsj-design/BleachvsNaruto/releases) | 可下载的 macOS 游戏包 |
| `launcher/Launcher.m` | macOS 启动器源码 |
| 本 README | 使用说明 |

完整游戏源码与资源工程请见上游仓库；本仓库重点提供 **下载即玩** 的 macOS 发行包。

## 免责声明

本项目为爱好者打包发行，与原作官方无关。请自行承担使用风险；商业用途请遵守上游 GPL 与相关版权规定。
