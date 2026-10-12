# ChatGPT Windows：离线包安装与普通用户免安装启动

安装 ChatGPT Windows 桌面应用时，下载渠道和管理员权限会分别影响结果。商店打不开，可以从官方地址获取完整安装包；没有管理员权限，则需要进一步判断包中的桌面程序能否直接运行。

本文按这两种情况介绍可用的方法。这里的“离线包”是可以提前下载、复制到另一台电脑使用的完整应用包，不包含可离线运行的 ChatGPT 模型。桌面应用的登录、对话和其他云端功能仍需要网络。

## 方向一：有管理员权限，但商店打不开或下载更新困难

OpenAI 在 [Windows 部署文档](https://learn.chatgpt.com/docs/enterprise/windows-deployment) 中提供了完整 MSIX 包和离线许可证。MSIX 是 Windows 的应用打包格式，其中包含程序文件以及安装时需要交给系统处理的配置。通过下面的地址获取文件，可以跳过商店界面的下载流程：

| 文件 | 官方下载地址 | 用途 |
| --- | --- | --- |
| x64 MSIX | [ChatGPT-x64.msix](https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix) | 用于通常搭载 Intel 或 AMD 64 位处理器的 Windows 电脑。 |
| Arm64 MSIX | [ChatGPT-arm64.msix](https://persistent.oaistatic.com/codex-app-prod/ChatGPT-arm64.msix) | 用于搭载 ARM 64 位处理器的 Windows 电脑。 |
| 许可证 XML | [ChatGPT-License.xml](https://persistent.oaistatic.com/codex-app-prod/ChatGPT-License.xml) | 用于下面的官方离线部署流程，与所选 MSIX 一起保存。 |

x64 和 Arm64 表示程序面向的处理器架构，关系到电脑能否运行其中的机器指令。可在 Windows 设置的“系统类型”中确认架构；通常优先选择与系统架构匹配的包。

这些固定链接提供对应架构的最新 Microsoft Store 签名包。可以在网络正常的电脑上下载，再把文件复制到目标电脑。所选 MSIX 下载后重命名为 `ChatGPT.msix`，与 `ChatGPT-License.xml` 放在同一文件夹。

在这个文件夹中，以管理员身份打开 Windows PowerShell，执行：

```powershell
Add-AppxProvisionedPackage -Online `
    -PackagePath .\ChatGPT.msix `
    -LicensePath .\ChatGPT-License.xml `
    -Regions all
```

`-Online` 指对正在运行的 Windows 系统操作，不表示安装包必须在线下载；此命令使用的是本地文件夹中的包。它会预配应用，使应用在用户登录时完成注册。如果安装后没有出现应用入口，可注销后重新登录，再打开 ChatGPT。正式安装仍需要管理员权限；下载完整包解决的是获取安装文件的问题。

后续需要更新时，可以从相同固定链接获取新包，再按管理员部署流程处理。官方说明也支持安装后通过应用检查更新，需要允许访问 `persistent.oaistatic.com`。截至本文核对时间，官方提供上述 MSIX 离线部署包，没有独立 MSI 或非 Store EXE 包。

## 方向二：没有管理员权限，尝试普通用户免安装启动

有些桌面程序可以从用户可写目录直接运行。ChatGPT 的当前 Windows 包中也包含这样的程序文件，因此可以把它们完整取出，再配置普通用户启动入口。这种方式仍使用当前账户的权限，没有完成 MSIX 系统安装；需要系统服务的功能可能不可用。

下面的三种思路分别适合直接使用自动化工具、借助本机 AI agent，以及自己理解并复现整个过程。

### 思路一：用本项目自动下载、更新和启动

**Git 仓库链接：[sixty-66/ChatGPT-NoAdmin](https://github.com/sixty-66/ChatGPT-NoAdmin)。**

取得项目后，在项目根目录打开 Windows PowerShell，运行一行命令：

```powershell
& '.\install.cmd' -Launch
```

入口脚本会自动识别系统架构，从官方固定地址获取最新完整包，验证签名和内容，解压应用文件，配置启动入口及当前用户的桌面、开始菜单快捷方式，然后启动应用。运行需要 Windows PowerShell 5.1、.NET 和系统 `curl.exe`，不需要 Python 或额外的解压软件。

下载包、解压版本、启动文件和用户数据目录默认保存在项目根目录的 `_local` 中。之后可以使用 **ChatGPT（免安装）** 快捷方式，或双击 `_local\Start-ChatGPT.cmd`。再次运行同一行命令会检查官方下载地址，按需要准备新版本；应用已经运行时，应先退出旧实例，再启动新版本。

不希望立即启动时，去掉 `-Launch`。`-StorageRoot` 可以指定保存目录，`-NoShortcuts` 可以跳过快捷方式创建和更新，`-PackagePath` 可以使用已下载的官方 MSIX；本地包模式不会检查线上最新版本。完整参数与使用方式见 [项目使用说明](../README.md)，实现可查看 [一行入口](../install.cmd) 和 [PowerShell 脚本](../src/Install-ChatGPTPortable.ps1)。

### 思路二：让能操作本机的 AI agent 按本文完成配置

**本文发布链接：[ChatGPT Windows：离线包安装与普通用户免安装启动](https://github.com/sixty-66/ChatGPT-NoAdmin/blob/main/docs/chatgpt-windows-offline-and-noadmin.md)。**

可以把本文链接，或直接把文章内容交给具备本机操作能力的 AI agent，例如配置好本机工具的 VS Code Codex 插件。它需要能够执行 PowerShell、下载文件、读写目录并检查程序启动结果；只能进行文字对话的工具无法直接完成这些操作。

向 agent 说明目标是：从官方地址获取适合系统架构的最新完整包，在指定的用户可写目录中配置免安装启动，并报告已经验证的结果。要求它检查包与程序签名，保留原始应用文件，设置正确的工作目录和用户数据目录，最后验证窗口能否打开。已有运行实例、签名验证失败或系统策略限制，也应写进结果。

提供管理员凭据并不是这条路径的前提。agent 应按下文的文件提取与普通用户启动流程处理；依赖系统服务的功能，仍需要由管理员通过正式安装配置。

### 思路三：理解免安装启动的原理与完整流程

MSIX 同时承担两件事：保存文件，以及描述 Windows 应如何安装它们。它的文件容器可以由 ZIP 读取接口打开，包内的 `AppxManifest.xml` 则是安装清单，说明包标识、版本、架构、程序入口和系统集成方式。

本次检查的包显示名称为 `ChatGPT`，包标识为 `OpenAI.Codex`，主程序位于 `app/ChatGPT.exe`。安装清单还声明了一个后台服务，并指定它使用 Windows 系统账户（LocalSystem）运行：

```xml
<desktop6:Service Name="CodexSandboxService.OpenAI.Codex"
                  StartupType="auto"
                  StartAccount="localSystem" />
```

安装包中的此类服务需要管理员权限，因此普通用户正式安装时会遇到 `0x80073D28`。Microsoft 将这个错误定义为 `ERROR_PACKAGED_SERVICE_REQUIRES_ADMIN_PRIVILEGES`，OpenAI 的部署文档也说明了这一情况。[Microsoft 错误码说明](https://learn.microsoft.com/en-us/windows/win32/appxpkg/troubleshooting)

直接启动应用走的是另一条执行路径：完整取出 `app/` 下的桌面程序和资源，由当前用户进程运行 `ChatGPT.exe`。Windows 不会在这一步按 MSIX 清单注册系统服务，所以不会因安装这个服务而要求提权。应用是否能在没有包注册的情况下工作，仍取决于当前版本的实现，需要实际验证。

完整流程如下：

1. **获取适合架构的官方包。** 根据系统选择 x64 或 Arm64，从官方固定地址下载完整 MSIX。直接运行应用不使用离线部署许可证 XML；许可证用于前面的正式部署流程。
2. **先检查包，再使用内容。** 用 Windows `Get-AuthenticodeSignature` 确认包签名有效，核对证书主体与清单中的发布者一致。本项目还固定核对预期的 `OpenAI.Codex` 包标识及已验证的发布者标识，并检查架构、最低 Windows 版本和所需文件布局。如果新包声明了额外的运行框架依赖，会停止处理，需要重新评估免安装方式。签名不通过时同样停止处理，不继续解压并启动。
3. **原样提取完整的应用目录。** 解压 `app/` 下的所有程序、动态链接库（DLL，即程序运行时加载的代码文件）和资源，保留相对路径。例如 `app/resources/app.asar` 应仍处于应用目录的 `resources/` 下。只取出 `ChatGPT.exe` 会缺少运行所需文件。解压前把目标路径转为绝对路径，确认每个文件都位于目标目录内；完成后再检查 `ChatGPT.exe` 的 OpenAI 签名。
4. **设置工作目录和用户数据目录。** 启动时把工作目录设为解压后的应用目录，使用 `--user-data-dir` 指定外置的用户数据目录，再以当前用户权限运行。工作目录帮助程序找到相对路径资源；用户数据与版本文件分开，则可以在切换程序版本时继续使用原有配置。
5. **检查更新并复用经过验证的缓存。** 本项目先用 HTTP `HEAD` 请求读取版本、长度及 `ETag`，无需先下载整个包。`ETag` 是服务器提供的文件版本标记；缓存匹配时仍重新验签并核对 SHA-256，后者是按文件内容计算的校验值。已有解压目录还会逐一与已验证包中的文件对比校验值，确认完整且未被改动后复用。
6. **完整准备后再切换启动配置。** 本项目把版本保存为独立目录，用户数据保存在 `_local/portable-profile`，用 `_local/active.json` 记录当前版本。启动文件和快捷方式在检查通过后写入，旧配置保留备份；配置提交失败时尝试回退。更新保留旧版本和用户数据，不会结束已经运行的应用实例。

下面的片段用于解释启动参数如何配合：从项目根目录读取活动配置，以普通用户权限运行对应程序。它对应完整流程的启动部分；下载、验签和解压路径检查应由前述项目脚本先完成。实际使用可直接运行 `install.cmd`：

```powershell
$state = Get-Content '.\_local\active.json' -Raw -Encoding UTF8 | ConvertFrom-Json
Start-Process -FilePath $state.Executable `
    -WorkingDirectory (Split-Path -Parent $state.Executable) `
    -ArgumentList ('--user-data-dir="' + $state.ProfileDirectory + '"')
```

本项目的 Windows 验签在独立子进程中执行，默认每次等待最多 180 秒，可通过 `-SignatureTimeoutSeconds` 在 10～1800 秒范围内调整。超时会结束该验签子进程并停止处理，尚未验证的版本不会成为启动目标。已经完整下载的待验包会保留在 `downloads/`；再次运行时，如果官方版本标记和长度仍匹配，就重新验证后复用，不会把“下载完成”当成“验证通过”。

更新时还要考虑正在运行的实例。同一用户数据目录可能使新启动的进程转交给已有实例，因此点击新版入口不一定立刻得到新版窗口。退出旧实例后再启动，才能明确验证所选版本；本项目不会自动结束用户正在运行的应用。

这种方式没有修改包、破解签名、提升账户权限或加入关闭沙箱的启动参数，也不会注册 MSIX 或安装 `CodexSandboxService.OpenAI.Codex`。依赖系统服务、包身份、协议关联、应用执行别名或资源管理器扩展的功能可能受限。系统的应用控制、网络和脚本策略同样继续生效。

2026 年 10 月 10 日，Windows x64 上的 `26.1007.2314.0` 已通过官方包和主程序签名检查，并验证普通用户能够打开响应正常的 ChatGPT 窗口；没有逐项验证全部功能，也没有在 Arm64 设备上实测。OpenAI 官方未在所引用的部署说明中承诺支持这种便携方式；未来版本如果更换发布者、改变文件布局或依赖包身份，应重新检查适用性。

### 参考资料

- [OpenAI：Deploy the Windows app](https://learn.chatgpt.com/docs/enterprise/windows-deployment)：官方完整包、离线许可证、管理员部署、更新与权限错误说明。
- [Microsoft：Windows 应用打包与部署故障排查](https://learn.microsoft.com/en-us/windows/win32/appxpkg/troubleshooting)：`0x80073D28` 的错误定义。
- [项目使用说明](../README.md)、[启动入口](../install.cmd)、[实现脚本](../src/Install-ChatGPTPortable.ps1)：本项目的使用方法和可复现实现。

官方下载入口截至 2026 年 10 月 10 日已核对。文中的服务信息来自对应 MSIX 的安装清单，免安装启动的范围来自上述实测。
