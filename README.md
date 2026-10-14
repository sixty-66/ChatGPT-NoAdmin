# ChatGPT-NoAdmin

一个用于 Windows 的 ChatGPT 免安装启动工具：从 OpenAI 官方地址获取当前最新的完整 MSIX 包，验证签名后提取应用文件，并配置普通用户可以使用的启动入口，无需使用管理员权限。

适合没有管理员权限、但允许在用户目录运行应用的场景。下载完整项目后双击即可使用，无需输入命令，也无需 Microsoft Store、Python 或额外解压软件。

这里的“免管理员”通过直接运行解压后的桌面程序实现，进程仍使用当前用户权限。它不等同于正式注册 MSIX 包；依赖系统服务或包注册的功能可能需要管理员完成正式安装。

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

1. 确认应用保存目录所在磁盘至少有 **5 GB 可用空间，推荐 10 GB。**
2. 双击项目根目录中的 **`Start-ChatGPT.vbs`**，打开中文进度窗口。也可双击 `install.cmd` 打开相同界面。
3. 等待下载、验证与配置完成。看到绿色的成功提示后，流程已完成并发出 ChatGPT 启动请求；失败时窗口会显示失败原因。
4. 以后直接双击桌面或开始菜单中的 **ChatGPT（免安装）**；要检查更新，再双击项目中的 `Start-ChatGPT.vbs`。

首次使用时，应用默认保存到 `%LOCALAPPDATA%\ChatGPT-NoAdmin`，通常在 **C 盘**，与克隆或解压项目的位置独立。已用过本项目时，会复用记住的保存目录、当前用户快捷方式指向的目录或当前项目已有的 `_local`，继续使用原来的应用和登录配置。需要保存到其他磁盘时，使用指南中的 [`-StorageRoot` 参数](docs/usage-guide.md#保存到其他用户可写目录)指定目录。

“配置成功”表示官方包与主程序已验证、应用文件和启动入口已准备好。“已发出启动请求”表示已请求运行应用；请确认 ChatGPT 窗口实际打开。更新前若应用已在运行，请先退出旧实例，再用快捷方式启动新版。

使用条件、命令行参数、更新说明和常见问题见 [使用指南](docs/usage-guide.md)。
