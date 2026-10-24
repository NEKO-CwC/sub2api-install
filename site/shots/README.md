# 截图清单

页面里的 16 个截图位。除 `linux-open-terminal.png` 外都已上传。按下面的文件名把图片放进 `site/shots/`，然后跑 `./deploy/apply.sh` 就会自动替换占位图。

## 建议规格

- 格式：PNG
- 宽度：1200–1600px（页面里最宽约 500px 显示，2x 屏够用）
- 不要包含真实 API Key、完整邮箱、头像等个人信息
- 终端截图建议把窗口调窄一点，保留提示符那一行

## 清单

### 1. `windows-open-terminal.png`

Win+X 菜单（或开始菜单搜索）里「终端 / Windows PowerShell」的位置。
最好能同时看到菜单项和它被选中的状态。

### 2. `mac-open-terminal.png`

聚焦搜索（⌘+空格）输入「终端」或 `Terminal` 时的画面，能看到终端图标。

### 3. `linux-open-terminal.png`

一个打开的终端窗口，显示提示符即可。任意发行版都行。

### 4. `keys-create.png`

Sub2API 的 Keys 页面，标出「创建 API Key」按钮的位置。用带注释的截图（箭头 / 红框）效果最好。

### 5. `terminal-paste-key.png`

终端里脚本已经打印出「请粘贴 Sub2API Key（输入不会显示）」这一行、等待输入的状态。
**注意：不要截到已经输入的 Key。**

### 6. `usage-verify.png`

Sub2API 的「用量明细」页面，能看到一条刚产生的调用记录。
可以打码具体的 token 数和金额，保留时间、模型、状态这几列即可。

## 补充说明

- 如果某张图暂时没有，直接跳过——页面会保留虚线占位，不会破版。
- 想改占位文案，改 `site/index.html` 里对应 `<figure class="shot" data-shot="...">` 下的 `<figcaption>`。
- 新增截图位：在 HTML 里加一个 `<figure class="shot" data-shot="新名字">`，把图片放成 `site/shots/新名字.png` 即可，不需要改 JS。
