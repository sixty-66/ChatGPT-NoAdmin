# ChatGPT-NoAdmin 使用指南

[返回 README](../README.md)

## 使用条件

- Windows x64 或 Arm64；最低系统版本由当次官方包的清单决定。
- Windows PowerShell 5.1、.NET 和系统 `curl.exe`。
- 当前用户能够写入保存目录；下载时能够访问 `persistent.oaistatic.com`。
- 保存目录所在磁盘至少有 **5 GB 可用空间，推荐 10 GB**。

目前已实测 Windows x64 的下载、验证和窗口启动；Arm64 分支尚未实测。这个免安装方法基于应用当前的文件布局，未来版本的兼容性需要继续确认。

脚本会核对 MSIX 签名、发布者、包标识、架构、最低 Windows 版本和文件布局，再验证提取后的 `ChatGPT.exe`；检查失败就停止。流程不提权、不注册包、不安装服务，也不添加关闭沙箱的启动参数。更新配置前保留备份，提交失败时尝试恢复。

### 命令行使用（可选）

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

| 参数                                | 作用                                                                                                 |
| ----------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `-StorageRoot <路径>`             | 指定保存目录，并在成功配置后记住它；默认复用已有目录，首次使用为`%LOCALAPPDATA%\ChatGPT-NoAdmin`。 |
| `-Architecture auto\|x64\|arm64`    | 默认按 Windows 架构自动选择；也可手动指定。                                                          |
| `-PackagePath <MSIX路径>`         | 使用本地包，不查询在线最新版本。                                                                     |
| `-ForceDownload`                  | 重新下载官方包，不复用下载缓存；不能与`-PackagePath` 同时使用。                                    |
| `-NoShortcuts`                    | 跳过桌面和开始菜单快捷方式，只配置保存目录中的启动文件。                                             |
| `-KeepOldVersions`                | 保留同一保存目录中的旧版本，跳过默认的旧版本清理。                                                   |
| `-Launch`                         | 完成配置后启动应用。                                                                                 |
| `-OutputJson`                     | 在命令行结果后显示完整诊断 JSON；默认只显示简短中文结果。                                            |
| `-SignatureTimeoutSeconds <秒数>` | 每次验签的超时时间，默认`180`，允许 `10`～`1800`。                                             |
| `-Help`                           | 显示使用帮助，不下载或配置应用。                                                                     |

## 项目与运行目录

```text
ChatGPT-NoAdmin/
├── README.md
├── docs/
│   └── usage-guide.md
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

| 现象                              | 处理方式                                                                                                      |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| 验签超时                          | 重试；确需更长等待时使用`-SignatureTimeoutSeconds 600`。完整待验证下载会保留，匹配官方元数据时可重新验证。  |
| 包签名、发布者或布局检查失败      | 保留报错；下载缓存可用`-ForceDownload` 重新获取。若官方发布方式发生变化，需要核对并更新工具后再使用。       |
| 解压目录缺文件或内容被改动        | 脚本停止复用该目录。修复报错中的版本目录后，在原来的`-StorageRoot` 重试，继续使用原用户配置。               |
| 更新后旧版本仍占用空间            | 退出旧实例后再次运行脚本；运行状态不明或无法识别的目录会保留，按提示检查。使用`-KeepOldVersions` 时不清理。 |
| 无法创建快捷方式                  | 使用`-NoShortcuts`，从保存目录中的 `Start-ChatGPT.cmd` 启动。                                             |
| 提示另一流程正在运行              | 等同一保存目录的流程结束；不要同时更新同一个目录。                                                            |
| 双击提示 VBS 被禁用               | 在 PowerShell 中运行`& '.\install.cmd' -Launch`；组织管理的脚本策略按组织流程处理。                         |
| 下载 ZIP 后脚本被标记为来自互联网 | 先审阅源码。在设备策略允许的情况下，通过文件属性确认信任该文件；受组织管理的脚本策略应按组织流程处理。        |
| 普通用户下某些本地功能不可用      | 这些功能可能需要正式安装的系统服务或包身份；有管理员权限时使用官方部署方法。                                  |

`install.cmd` 的退出码 `0` 表示配置成功，使用启动模式时也已发出启动请求；`1` 表示流程失败。若配置已保存但启动失败，会明确提示，保留已有配置以便重试。配置成功不代表所有应用功能均已验证。

## 方法原理与官方来源

官方包和正式部署说明见 [OpenAI Windows deployment](https://learn.chatgpt.com/docs/enterprise/windows-deployment)。本项目是独立工具，免安装方法的实测结果不代表 OpenAI 官方支持便携部署。
