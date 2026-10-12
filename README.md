# ChatGPT-NoAdmin

一个用于 Windows 的 ChatGPT 免安装启动工具：从 OpenAI 官方地址获取当前最新的完整 MSIX 包，验证签名后提取应用文件，并配置普通用户可以使用的启动入口。

适合没有管理员权限、但允许在用户目录运行应用的场景。只需下载完整项目并运行一行命令，无需 Microsoft Store、Python 或额外解压软件。

这里的“免管理员”通过直接运行解压后的桌面程序实现，进程仍使用当前用户权限。它不等同于正式注册 MSIX 包；依赖系统服务或包注册的功能可能需要管理员完成正式安装。下载的完整离线包也不包含离线模型，登录和对话仍需网络。

项目 Git 链接：[sixty-66/ChatGPT-NoAdmin](https://github.com/sixty-66/ChatGPT-NoAdmin)。

## 功能

- 从官方固定地址获取当前最新版本，自动选择 x64 或 Arm64 架构。
- 核对 MSIX 签名、发布者、包标识、架构、Windows 最低版本和文件布局。
- 原样提取应用文件，再验证 `ChatGPT.exe` 的 OpenAI 签名。
- 生成启动脚本、当前用户桌面和开始菜单快捷方式。
- 复用下载缓存及完整解压目录，更新时保留旧版本和独立用户配置。
- 验签设有超时；检查失败时停止配置，已完成的待验证下载可留到下次重试。
- 更新启动配置前保留备份，提交失败时尝试恢复原配置。

## 使用条件

- Windows x64 或 Arm64；最低系统版本由当次官方包的清单决定。
- Windows PowerShell 5.1、.NET 和系统 `curl.exe`。
- 当前用户能够写入保存目录；下载时能够访问 `persistent.oaistatic.com`。
- 预留数 GB 的磁盘空间，保存多个版本时需要更多空间。

目前已实测 Windows x64 的下载、验证和窗口启动；Arm64 分支尚未实测。这个免安装方法基于应用当前的文件布局，未来版本的兼容性需要继续确认。

## 快速开始

通过 Git 克隆或下载整个项目文件夹，保留 `install.cmd` 和 `src/` 的相对位置。在项目根目录打开 PowerShell，运行：

```powershell
& '.\install.cmd' -Launch
```

脚本会查询官方当前版本、下载或复用完整包、验证并解压，最后创建快捷方式并启动应用。默认保存到项目根目录下的 `_local`，与外层仓库名称和目录结构无关。

完成后，可双击桌面或开始菜单中的 **ChatGPT（免安装）**，也可运行：

```powershell
& '.\_local\Start-ChatGPT.cmd'
```

只准备文件和启动入口时，省略 `-Launch`。查看参数帮助：

```powershell
& '.\install.cmd' -Help
```

## 下载、启动与更新

### 保存到其他用户可写目录

例如，把运行文件保存到当前用户的本地应用数据目录：

```powershell
& '.\install.cmd' -StorageRoot (Join-Path $env:LOCALAPPDATA 'ChatGPT-NoAdmin') -Launch
```

`-StorageRoot` 接受相对路径或绝对路径；相对路径按当前 PowerShell 工作目录解析。后续更新时使用同一个保存目录。

### 更新版本

再次运行首次准备时的命令即可。脚本会重新查询官方地址；只有当前下载仍匹配且验证通过时才复用缓存。

脚本不会结束已运行的应用。相同用户配置目录可能让新的启动请求转交给旧实例，更新后请退出旧实例，再使用快捷方式启动新版。

更新流程不会删除旧版本，也不会清空 `portable-profile`。内置更新行为不属于这个脚本的保证范围；需要通过免安装方式更新时，重新运行脚本。

### 使用已下载的完整包

```powershell
& '.\install.cmd' -PackagePath '.\_local\downloads\ChatGPT-x64.msix' -NoShortcuts
```

本地包模式不查询在线最新版本，仍须通过签名和清单检查。Windows 证书验证可能需要网络，具体取决于本机的证书链和验证缓存。

## 参数

| 参数 | 作用 |
| --- | --- |
| `-StorageRoot <路径>` | 下载、版本文件、用户配置和启动入口的保存目录，默认是项目根 `_local`。 |
| `-Architecture auto\|x64\|arm64` | 默认按 Windows 架构自动选择；也可手动指定。 |
| `-PackagePath <MSIX路径>` | 使用本地包，不查询在线最新版本。 |
| `-ForceDownload` | 重新下载官方包，不复用下载缓存；不能与 `-PackagePath` 同时使用。 |
| `-NoShortcuts` | 跳过桌面和开始菜单快捷方式，只配置保存目录中的启动文件。 |
| `-Launch` | 完成配置后启动应用。 |
| `-SignatureTimeoutSeconds <秒数>` | 每次验签的超时时间，默认 `180`，允许 `10`～`1800`。 |
| `-Help` | 显示使用帮助，不下载或配置应用。 |

## 项目与运行目录

```text
ChatGPT-NoAdmin/
├── README.md
├── install.cmd
├── src/
│   └── Install-ChatGPTPortable.ps1
├── docs/
│   └── chatgpt-windows-offline-and-noadmin.md
├── .gitignore
├── .gitattributes
└── _local/                         # 运行时生成，Git 忽略
    ├── downloads/                  # 官方 MSIX、缓存记录和待验证包
    ├── versions/                   # 按版本保存的原始应用文件
    ├── portable-profile/           # 登录状态、用户配置等个人数据
    ├── configuration-backups/      # 旧启动配置的备份
    ├── staging/                    # 本次处理的临时目录
    ├── pipeline.lock
    ├── Start-ChatGPT.cmd
    └── active.json
```

`active.json` 记录配置的版本、文件校验值和本机运行路径。它与用户配置、快捷方式、日志一样属于运行产物，不应上传。

移动运行目录后，使用新位置的 `-StorageRoot` 重新执行脚本，更新快捷方式和记录中的绝对路径。移动后使用本地包模式可复用已有下载。

## 常见问题

| 现象 | 处理方式 |
| --- | --- |
| 验签超时 | 重试；确需更长等待时使用 `-SignatureTimeoutSeconds 600`。完整待验证下载会保留，匹配官方元数据时可重新验证。 |
| 包签名、发布者或布局检查失败 | 保留报错；下载缓存可用 `-ForceDownload` 重新获取。若官方发布方式发生变化，需要核对并更新工具后再使用。 |
| 解压目录缺文件或内容被改动 | 脚本停止复用该目录。保留原目录，使用另一个可写的 `-StorageRoot` 重新准备。 |
| 无法创建快捷方式 | 使用 `-NoShortcuts`，从保存目录中的 `Start-ChatGPT.cmd` 启动。 |
| 提示另一流程正在运行 | 等同一保存目录的流程结束；不要同时更新同一个目录。 |
| 下载 ZIP 后脚本被标记为来自互联网 | 先审阅源码。在设备策略允许的情况下，通过文件属性确认信任该文件；受组织管理的脚本策略应按组织流程处理。 |
| 普通用户下某些本地功能不可用 | 这些功能可能需要正式安装的系统服务或包身份；有管理员权限时使用官方部署方法。 |

退出码 `0` 表示准备与配置成功；`1` 表示流程失败。配置成功不代表所有应用功能均已验证。

## 方法原理与官方来源

[科普文章：ChatGPT Windows 离线下载与免管理员启动](docs/chatgpt-windows-offline-and-noadmin.md) 分别介绍有管理员权限时的官方离线安装，以及没有管理员权限时的三种实践思路，并解释免安装方法的工作原理。

官方包和正式部署说明见 [OpenAI Windows deployment](https://learn.chatgpt.com/docs/enterprise/windows-deployment)。本项目是独立工具，免安装方法的实测结果不代表 OpenAI 官方支持便携部署。

## 分享项目

本项目可以作为一个独立文件夹使用。分享源码时保留 README、脚本、文章、`.gitignore` 和 `.gitattributes`，不需要携带下载包或运行配置。

默认 `_local/` 及常见安装包、用户配置、快捷方式和运行记录已加入忽略规则。自定义保存目录也应放在待分享的源码之外；上传前检查将要提交的文件列表，避免包含本机路径或个人数据。

手动压缩源码时也要排除 `_local` 和其他运行目录；`.gitignore` 只控制 Git 的文件选择，不会筛选压缩包内容。

维护脚本时保持 Windows PowerShell 5.1 兼容性与 `.ps1` 的 UTF-8 BOM；`.cmd` 使用 ASCII 和 CRLF。项目源码与科普文章均发布在本 Git 仓库中。
