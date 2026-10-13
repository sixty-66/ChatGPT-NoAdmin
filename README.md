# ChatGPT-NoAdmin

一个用于 Windows 的 ChatGPT 免安装启动工具：从 OpenAI 官方地址获取当前最新的完整 MSIX 包，验证签名后提取应用文件，并配置普通用户可以使用的启动入口。

适合没有管理员权限、但允许在用户目录运行应用的场景。下载完整项目后双击即可使用，无需输入命令，也无需 Microsoft Store、Python 或额外解压软件。

这里的“免管理员”通过直接运行解压后的桌面程序实现，进程仍使用当前用户权限。它不等同于正式注册 MSIX 包；依赖系统服务或包注册的功能可能需要管理员完成正式安装。下载的完整离线包也不包含离线模型，登录和对话仍需网络。

项目 Git 链接：[sixty-66/ChatGPT-NoAdmin](https://github.com/sixty-66/ChatGPT-NoAdmin)。

## 快速开始

### 获取项目

已安装 Git 时，在 PowerShell 中运行：

```powershell
git clone https://github.com/sixty-66/ChatGPT-NoAdmin.git
cd ChatGPT-NoAdmin
```

项目会下载到运行 `git clone` 时所在目录的 `ChatGPT-NoAdmin` 子文件夹。想放到指定位置，先切换到一个已有、可写的目录，再运行上面的命令。例如，已有 `D:\AI-coding` 时，可以先运行 `Set-Location 'D:\AI-coding'`，项目就会保存到 `D:\AI-coding\ChatGPT-NoAdmin`。

没有 Git 时，打开 [GitHub 项目页面](https://github.com/sixty-66/ChatGPT-NoAdmin)，点击 **Code → Download ZIP**，或直接 [下载项目 ZIP](https://github.com/sixty-66/ChatGPT-NoAdmin/archive/refs/heads/main.zip)。保存到任意可写目录，右键 ZIP 选择“全部解压”，然后打开解压得到的 `ChatGPT-NoAdmin-main` 文件夹。请完整解压后再运行，不能直接在 ZIP 内启动；保留 `install.cmd`、`Start-ChatGPT.vbs` 和 `src/` 的相对位置。

### 双击启动

1. 确认应用保存目录所在磁盘至少有 **5 GB 可用空间，推荐 10 GB**；详细占用见下方“磁盘空间”。
2. 双击项目根目录中的 **`Start-ChatGPT.vbs`**，打开中文进度窗口。也可双击 `install.cmd` 打开相同界面。
3. 等待下载、验证与配置完成。看到绿色的成功提示后，流程已完成并发出 ChatGPT 启动请求；失败时窗口会显示失败原因。
4. 以后直接双击桌面或开始菜单中的 **ChatGPT（免安装）**；要检查更新，再双击项目中的 `Start-ChatGPT.vbs`。

首次使用时，应用默认保存到 `%LOCALAPPDATA%\ChatGPT-NoAdmin`，通常在 **C 盘**，与克隆或解压项目的位置独立。已用过本项目时，会复用记住的保存目录、当前用户快捷方式指向的目录或当前项目已有的 `_local`，继续使用原来的应用和登录配置。需要保存到其他磁盘时，使用下方的 `-StorageRoot` 参数指定目录。

“配置成功”表示官方包与主程序已验证、应用文件和启动入口已准备好。“已发出启动请求”表示已请求运行应用；请确认 ChatGPT 窗口实际打开。更新前若应用已在运行，请先退出旧实例，再用快捷方式启动新版。

## 使用条件

- Windows x64 或 Arm64；最低系统版本由当次官方包的清单决定。
- Windows PowerShell 5.1、.NET 和系统 `curl.exe`。
- 当前用户能够写入保存目录；下载时能够访问 `persistent.oaistatic.com`。
- 保存目录所在磁盘有足够的可用空间，具体要求如下。

目前已实测 Windows x64 的下载、验证和窗口启动；Arm64 分支尚未实测。这个免安装方法基于应用当前的文件布局，未来版本的兼容性需要继续确认。

脚本会核对 MSIX 签名、发布者、包标识、架构、最低 Windows 版本和文件布局，再验证提取后的 `ChatGPT.exe`；检查失败就停止。流程不提权、不注册包、不安装服务，也不添加关闭沙箱的启动参数。更新配置前保留备份，提交失败时尝试恢复。

### 磁盘空间

请检查**应用保存目录所在磁盘**的可用空间；首次默认目录通常在 C 盘，即使项目源码放在 D 盘，应用仍可能保存到 C 盘。

| 场景 | 可用空间要求 |
| --- | --- |
| 首次准备 | 至少 **5 GB**，推荐 **10 GB**，用于下载、解压和临时文件。 |
| 更新应用 | 在现有占用之外，再预留至少 **5 GB 可用空间**；新旧下载包和程序版本会暂时共存。 |
| 保留额外旧版本 | 每多保留一个旧版本，约增加 **2.5 GB** 占用；实际大小随版本和架构变化。 |
| 持续使用 | 登录配置、缓存等用户数据会增长，应继续保留余量。 |

以当前官方 x64 包实测：下载约 **0.95 GB**，解压后的应用约 **2.32 GB**，合计约 **3.27 GB**，未计临时文件、用户数据和保留的旧版本。这里的 GB 按 10 亿字节计算，Windows 显示的容量数字可能不同；后续版本的大小也会变化。

## 命令行使用（可选）

需要指定保存目录或其他参数时，在项目根目录打开 PowerShell，例如：

```powershell
& '.\install.cmd' -Launch
```

带参数运行会使用命令行，默认输出简短中文结果；添加 `-OutputJson` 可查看诊断 JSON，保存目录中的 `active.json` 仍保留完整记录。只准备文件和启动入口时，使用其他参数并省略 `-Launch`，例如 `& '.\install.cmd' -NoShortcuts`。**不带参数时进入图形界面并自动启动应用。**

若设备禁用了 VBS，使用上面的带参数命令。受组织管理的脚本限制应按组织流程处理。查看参数帮助：

```powershell
& '.\install.cmd' -Help
```

## 下载、启动与更新

### 保存到其他用户可写目录

例如，把运行文件保存到当前用户的另一个目录：

```powershell
& '.\install.cmd' -StorageRoot (Join-Path $env:USERPROFILE 'Apps\ChatGPT-NoAdmin') -Launch
```

`-StorageRoot` 接受相对路径或绝对路径；相对路径按当前 PowerShell 工作目录解析。成功配置后会记住这个目录，后续不带 `-StorageRoot` 的命令也会复用它，包括从另一份项目源码执行或使用 `-NoShortcuts` 的情况。

保存目录按以下顺序选择：

1. 显式指定的 `-StorageRoot`。
2. `%LOCALAPPDATA%\ChatGPT-NoAdmin\storage-root.json` 中记录的已有保存目录。
3. 当前用户桌面或开始菜单中 **ChatGPT（免安装）** 快捷方式指向的本项目运行目录。
4. 当前项目根目录已有的旧版 `_local` 运行目录。
5. 固定默认目录 `%LOCALAPPDATA%\ChatGPT-NoAdmin`。

如果记住的目录已不存在，会继续通过快捷方式和当前项目旧版 `_local` 寻找已有配置；仍找不到时停止，并提示重新连接原目录或用 `-StorageRoot` 指明新位置，避免另建一份登录配置。目录存在但校验失败时，也会停在原目录等待处理。

脚本不会全盘搜索，也不会自动合并、移动或删除其他保存目录。若电脑上原本已有多份，使用 `-StorageRoot` 指定希望继续使用的那一份；成功后它会成为后续默认目录。复用时继续使用原来的 `portable-profile`，不会重新建立一份登录配置。

### 更新版本

再次双击项目中的 `Start-ChatGPT.vbs` 或 `install.cmd`，或运行 `& '.\install.cmd' -Launch` 即可。脚本会复用记住的保存目录并重新查询官方地址；只有当前下载仍匹配且验证通过时才复用缓存。

脚本不会结束已运行的应用。相同用户配置目录可能让新的启动请求转交给旧实例，更新后请退出旧实例，再使用快捷方式启动新版。

启动配置提交成功后，默认清理同一保存目录 `versions` 中已完成且未运行的旧版本，只保留活动版本。正在运行、无法确认运行状态、链接或无法识别的目录会跳过并提示；退出旧实例后再次运行脚本，可再尝试清理。清理不会触及 `portable-profile` 或其他保存目录，也不会强制结束应用。

需要保留旧版本时，使用：

```powershell
& '.\install.cmd' -KeepOldVersions -Launch
```

内置更新行为不属于这个脚本的保证范围；需要通过免安装方式更新时，重新运行脚本。

### 使用已下载的完整包

```powershell
& '.\install.cmd' -PackagePath '.\ChatGPT-x64.msix' -NoShortcuts
```

本地包模式不查询在线最新版本，仍须通过签名和清单检查。Windows 证书验证可能需要网络，具体取决于本机的证书链和验证缓存。

## 参数

| 参数 | 作用 |
| --- | --- |
| `-StorageRoot <路径>` | 指定保存目录，并在成功配置后记住它；默认复用已有目录，首次使用为 `%LOCALAPPDATA%\ChatGPT-NoAdmin`。 |
| `-Architecture auto\|x64\|arm64` | 默认按 Windows 架构自动选择；也可手动指定。 |
| `-PackagePath <MSIX路径>` | 使用本地包，不查询在线最新版本。 |
| `-ForceDownload` | 重新下载官方包，不复用下载缓存；不能与 `-PackagePath` 同时使用。 |
| `-NoShortcuts` | 跳过桌面和开始菜单快捷方式，只配置保存目录中的启动文件。 |
| `-KeepOldVersions` | 保留同一保存目录中的旧版本，跳过默认的旧版本清理。 |
| `-Launch` | 完成配置后启动应用。 |
| `-OutputJson` | 在命令行结果后显示完整诊断 JSON；默认只显示简短中文结果。 |
| `-SignatureTimeoutSeconds <秒数>` | 每次验签的超时时间，默认 `180`，允许 `10`～`1800`。 |
| `-Help` | 显示使用帮助，不下载或配置应用。 |

## 项目与运行目录

```text
ChatGPT-NoAdmin/
├── README.md
├── install.cmd
├── Start-ChatGPT.vbs
├── src/
│   ├── Install-ChatGPTPortable.ps1
│   └── Start-ChatGPT.ps1
├── tests/
│   ├── Verify-PortableLifecycle.ps1
│   └── Verify-GraphicalEntry.ps1
├── .gitignore
└── .gitattributes
```

首次使用的默认运行目录独立于源码目录：

```text
%LOCALAPPDATA%\ChatGPT-NoAdmin/
├── downloads/                      # 官方 MSIX、缓存记录和待验证包
├── versions/                       # 活动版本及暂未清理的旧版本
├── portable-profile/               # 登录状态、用户配置等个人数据
├── configuration-backups/          # 旧启动配置的备份
├── staging/                        # 本次处理的临时目录
├── pipeline.lock
├── Start-ChatGPT.cmd
├── active.json
└── storage-root.json               # 固定默认目录内保存的目录记忆
```

`active.json` 记录配置的版本、文件校验值和本机运行路径。它与用户配置、快捷方式、日志一样属于运行产物，不应上传。

显式指定目录或复用旧版 `_local` 时，运行文件保存在选定目录；目录记忆仍写入固定默认目录内的 `storage-root.json`。

移动运行目录后，使用新位置的 `-StorageRoot` 重新执行脚本，更新快捷方式、目录记忆和记录中的绝对路径。原目录不在且无法发现新位置时，默认命令会提示指定目录，不会另建一份。移动后使用本地包模式可复用已有下载。

## 常见问题

| 现象 | 处理方式 |
| --- | --- |
| 验签超时 | 重试；确需更长等待时使用 `-SignatureTimeoutSeconds 600`。完整待验证下载会保留，匹配官方元数据时可重新验证。 |
| 包签名、发布者或布局检查失败 | 保留报错；下载缓存可用 `-ForceDownload` 重新获取。若官方发布方式发生变化，需要核对并更新工具后再使用。 |
| 解压目录缺文件或内容被改动 | 脚本停止复用该目录。修复报错中的版本目录后，在原来的 `-StorageRoot` 重试，继续使用原用户配置。 |
| 更新后旧版本仍占用空间 | 退出旧实例后再次运行脚本；运行状态不明或无法识别的目录会保留，按提示检查。使用 `-KeepOldVersions` 时不清理。 |
| 无法创建快捷方式 | 使用 `-NoShortcuts`，从保存目录中的 `Start-ChatGPT.cmd` 启动。 |
| 提示另一流程正在运行 | 等同一保存目录的流程结束；不要同时更新同一个目录。 |
| 双击提示 VBS 被禁用 | 在 PowerShell 中运行 `& '.\install.cmd' -Launch`；组织管理的脚本策略按组织流程处理。 |
| 下载 ZIP 后脚本被标记为来自互联网 | 先审阅源码。在设备策略允许的情况下，通过文件属性确认信任该文件；受组织管理的脚本策略应按组织流程处理。 |
| 普通用户下某些本地功能不可用 | 这些功能可能需要正式安装的系统服务或包身份；有管理员权限时使用官方部署方法。 |

`install.cmd` 的退出码 `0` 表示配置成功，使用启动模式时也已发出启动请求；`1` 表示流程失败。若配置已保存但启动失败，会明确提示，保留已有配置以便重试。配置成功不代表所有应用功能均已验证。

## 本地验证

维护脚本后，可用 Windows PowerShell 5.1 运行离线夹具，检查目录复用、旧版本清理、中文结果和图形入口。测试不会下载或启动真实应用，也不修改已有用户配置：

```powershell
& '.\tests\Verify-PortableLifecycle.ps1'
& '.\tests\Verify-GraphicalEntry.ps1'
```

## 方法原理与官方来源

官方包和正式部署说明见 [OpenAI Windows deployment](https://learn.chatgpt.com/docs/enterprise/windows-deployment)。本项目是独立工具，免安装方法的实测结果不代表 OpenAI 官方支持便携部署。

## 分享项目

本项目可以作为一个独立文件夹使用。分享源码时保留 README、脚本、测试、`.gitignore` 和 `.gitattributes`，不需要携带下载包或运行配置。`docs/` 只在本地保留，不再由 Git 跟踪或推送。

新的默认运行目录位于源码之外。旧版 `_local/` 及常见安装包、用户配置、快捷方式和运行记录已加入忽略规则。自定义保存目录也应放在待分享的源码之外；上传前检查将要提交的文件列表，避免包含本机路径或个人数据。

手动压缩源码时也要排除 `_local` 和其他运行目录；`.gitignore` 只控制 Git 的文件选择，不会筛选压缩包内容。

维护脚本时保持 Windows PowerShell 5.1 兼容性；`.ps1` 使用 UTF-8 BOM 和 CRLF，生成的 `.cmd` 使用 UTF-8 无 BOM 和 CRLF，项目入口 `install.cmd` 使用 ASCII 和 CRLF，`.vbs` 使用 UTF-16LE BOM 和 CRLF。
