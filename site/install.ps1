#Requires -Version 5.1
<#
  Sub2API 客户端接入脚本（Windows PowerShell）

  用法（交互式）:
    & ([scriptblock]::Create((irm https://install.ncuos.com/install.ps1))) -Client claude-code

  设计原则:
    - API Key 只在本机终端输入，不经过浏览器、不写入日志、不出现在命令行参数里
    - 修改任何配置文件前先备份，随时可以 -Restore 回滚
    - 只改目标工具自己的配置文件，不动系统环境变量
#>

[CmdletBinding()]
param(
  [ValidateSet('claude-code', 'codex', 'opencode')]
  [string]$Client,

  [string]$BaseUrl = 'https://sub2api.ncuos.com',

  [string]$ApiKey,

  [string]$Model,

  [switch]$InstallCli,
  [switch]$Smoke,
  [switch]$DryRun,
  [switch]$Restore
)

$ErrorActionPreference = 'Stop'

$script:DefaultBaseUrl = 'https://sub2api.ncuos.com'

# ---------- 输出 ----------
function Write-Info { param([string]$Message) Write-Host ":: $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "OK $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "!  $Message" -ForegroundColor Yellow }
function Write-Dim  { param([string]$Message) Write-Host "   $Message" -ForegroundColor DarkGray }
function Stop-WithError { param([string]$Message) Write-Host "X  $Message" -ForegroundColor Red; exit 1 }

# ---------- 交互补全 ----------
if (-not $Client) {
  Write-Host ''
  Write-Host '选择要接入的客户端:' -ForegroundColor White
  Write-Host '  1) Claude Code'
  Write-Host '  2) Codex CLI'
  Write-Host '  3) OpenCode'
  Write-Host ''
  do {
    $choice = Read-Host '输入序号 (1-3)'
  } while ($choice -notin @('1', '2', '3'))
  $Client = @{ '1' = 'claude-code'; '2' = 'codex'; '3' = 'opencode' }[$choice]
}

$BaseUrl = ($BaseUrl -replace '/+$', '')
if (-not $BaseUrl) { $BaseUrl = $script:DefaultBaseUrl }

# ---------- 路径 ----------
$ClaudeDir      = Join-Path $HOME '.claude'
$ClaudeSettings = Join-Path $ClaudeDir 'settings.json'

$CodexHome   = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$CodexConfig = Join-Path $CodexHome 'config.toml'

$OpenCodeDir    = Join-Path $HOME '.config\opencode'
$OpenCodeConfig = Join-Path $OpenCodeDir 'opencode.json'

# ---------- 工具函数 ----------
function Get-Timestamp { Get-Date -Format 'yyyyMMdd-HHmmss' }

function Backup-ConfigFile {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  $dest = "$Path.bak.sub2api-$(Get-Timestamp)"
  Copy-Item -LiteralPath $Path -Destination $dest -Force
  return $dest
}

function Read-SecretText {
  param([string]$Prompt)
  $secure = Read-Host -Prompt $Prompt -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
  } finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  }
}

function Write-TextFile {
  param([string]$Path, [string]$Content)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Read-TextFile {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  return [System.IO.File]::ReadAllText($Path)
}

# ---------- JSON 深度合并 ----------
function Merge-JsonObject {
  param($Target, $Patch)

  foreach ($prop in $Patch.PSObject.Properties) {
    $name = $prop.Name
    $value = $prop.Value
    $existing = $null
    $hasExisting = $false

    if ($Target -is [System.Collections.IDictionary]) {
      $hasExisting = $Target.Contains($name)
      if ($hasExisting) { $existing = $Target[$name] }
    } else {
      $existingProp = $Target.PSObject.Properties[$name]
      if ($existingProp) { $hasExisting = $true; $existing = $existingProp.Value }
    }

    $isPatchObject = ($value -is [pscustomobject]) -or ($value -is [System.Collections.IDictionary])
    $isExistingObject = ($existing -is [pscustomobject]) -or ($existing -is [System.Collections.IDictionary])

    if ($isPatchObject -and $hasExisting -and $isExistingObject) {
      $null = Merge-JsonObject -Target $existing -Patch $value
    } else {
      if ($Target -is [System.Collections.IDictionary]) {
        $Target[$name] = $value
      } else {
        if ($hasExisting) {
          $Target.$name = $value
        } else {
          $Target | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force | Out-Null
        }
      }
    }
  }
  return $Target
}

function Update-JsonConfig {
  param([string]$Path, [string]$JsonPatch)

  $current = $null
  $raw = Read-TextFile -Path $Path
  if ($raw -and $raw.Trim()) {
    try { $current = $raw | ConvertFrom-Json } catch { $current = $null }
  }
  if ($null -eq $current -or $current -isnot [pscustomobject]) {
    $current = [pscustomobject]@{}
  }

  $patchObj = $JsonPatch | ConvertFrom-Json
  $merged = Merge-JsonObject -Target $current -Patch $patchObj

  $json = $merged | ConvertTo-Json -Depth 20
  Write-TextFile -Path $Path -Content ($json + "`n")
}

# ---------- Codex TOML 改写 ----------
function Update-CodexToml {
  param([string]$Path, [string]$ModelName, [string]$Base, [string]$Key)

  $existing = Read-TextFile -Path $Path
  if ($null -eq $existing) { $existing = '' }
  $lines = $existing -split "`r?`n"

  $out = New-Object System.Collections.Generic.List[string]
  $headerDone = $false
  $modelWritten = $false
  $providerWritten = $false
  $skipping = $false

  $escapeToml = {
    param([string]$s)
    $s = $s -replace '\\', '\\\\'
    $s = $s -replace '"', '\"'
    return $s
  }

  foreach ($line in $lines) {
    $trimmed = $line.Trim()

    if (-not $headerDone -and $trimmed.StartsWith('[')) {
      if (-not $providerWritten) { $out.Add("model_provider = `"sub2api`""); $providerWritten = $true }
      if (-not $modelWritten)    { $out.Add("model = `"$ModelName`""); $modelWritten = $true }
      $out.Add('')
      $headerDone = $true
    }

    if (-not $headerDone) {
      if ($trimmed -match '^model_provider\s*=') {
        $out.Add("model_provider = `"sub2api`"")
        $providerWritten = $true
        continue
      }
      if ($trimmed -match '^model\s*=') {
        $out.Add("model = `"$ModelName`"")
        $modelWritten = $true
        continue
      }
    }

    if ($trimmed -match '^\[model_providers\.sub2api\]\s*$') {
      $skipping = $true
      continue
    }
    if ($skipping -and $trimmed.StartsWith('[')) { $skipping = $false }
    if ($skipping) { continue }

    $out.Add($line)
  }

  if (-not $providerWritten) { $out.Add("model_provider = `"sub2api`"") }
  if (-not $modelWritten)    { $out.Add("model = `"$ModelName`"") }

  $out.Add('')
  $out.Add('# Added by Sub2API installer. Remove this table to undo.')
  $out.Add('[model_providers.sub2api]')
  $out.Add('name = "Sub2API"')
  $out.Add("base_url = `"$Base/v1`"")
  $out.Add('wire_api = "responses"')
  $out.Add('requires_openai_auth = false')
  $out.Add('supports_websockets = false')
  $out.Add("experimental_bearer_token = `"$(& $escapeToml $Key)`"")

  Write-TextFile -Path $Path -Content (($out -join "`n") + "`n")
}

# ---------- API 调用 ----------
function Invoke-ApiGet {
  param([string]$Url)

  $headers = @{ Authorization = "Bearer $ApiKey"; Accept = 'application/json' }
  try {
    return Invoke-RestMethod -Uri $Url -Headers $headers -Method Get -TimeoutSec 25 -UseBasicParsing
  } catch {
    $status = $null
    if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
    return [pscustomobject]@{ __error = $true; __status = $status; __message = $_.Exception.Message }
  }
}

function Test-ApiKey {
  $result = Invoke-ApiGet -Url "$BaseUrl/v1/models"

  if ($result.__error) {
    switch ($result.__status) {
      401 { Stop-WithError "Key 无效或没有权限（HTTP 401）。请到 $BaseUrl/keys 重新复制。" }
      403 { Stop-WithError "Key 没有权限（HTTP 403）。请确认 Key 已分配到分组。" }
      $null { Stop-WithError "无法连接 $BaseUrl。请检查网络或地址是否正确。" }
      default { Stop-WithError "Key 校验失败（HTTP $($result.__status)）：$($result.__message)" }
    }
  }
  return $result
}

function Get-ModelIds {
  param($ModelsResponse)

  $ids = New-Object System.Collections.Generic.List[string]
  if ($ModelsResponse.data) {
    foreach ($m in $ModelsResponse.data) {
      if ($m.id -and -not $ids.Contains([string]$m.id)) { $ids.Add([string]$m.id) }
    }
  }
  return $ids
}

function Select-PreferredModel {
  param([System.Collections.Generic.List[string]]$Models, [string]$Prefer)

  if ($Prefer) {
    foreach ($m in $Models) {
      if ($m.ToLower().Contains($Prefer.ToLower())) { return $m }
    }
  }
  if ($Models.Count -gt 0) { return $Models[0] }
  return $null
}

function Show-Billing {
  $info = Invoke-ApiGet -Url "$BaseUrl/v1/sub2api/billing"
  if ($info.__error) { return }
  if ($null -ne $info.effective_rate_multiplier) {
    Write-Dim "当前计费倍率: $($info.effective_rate_multiplier)x"
  }
}

function Invoke-SmokeTest {
  param([string]$ModelName)

  if (-not $ModelName) { Write-Warn '没有可用模型，跳过测试请求'; return }

  $path = if ($Client -eq 'claude-code') { '/v1/messages' } else { '/v1/chat/completions' }
  $body = @{
    model      = $ModelName
    max_tokens = 16
    messages   = @(@{ role = 'user'; content = 'Reply with exactly SUB2API_OK.' })
  } | ConvertTo-Json -Depth 10

  Write-Info "发送测试请求 ($path) ..."

  $headers = @{ Authorization = "Bearer $ApiKey"; 'Content-Type' = 'application/json' }
  try {
    $null = Invoke-RestMethod -Uri "$BaseUrl$path" -Headers $headers -Method Post -Body $body -TimeoutSec 60 -UseBasicParsing
    Write-Ok '测试请求成功。到「用量明细」可以看到这次调用。'
  } catch {
    $status = $null
    if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
    Write-Warn "测试请求返回错误（HTTP $status）。配置已写入，可稍后在用量页确认。"
  }
}

function Install-ClientCli {
  param([string]$Package)

  if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    Write-Warn '没有找到 npm，跳过 CLI 安装。'
    Write-Dim '安装 Node.js: https://nodejs.org/'
    return
  }
  if ($DryRun) {
    Write-Info "[dry-run] npm install -g $Package"
    return
  }
  Write-Info "安装 $Package ..."
  & npm install -g $Package
  if ($LASTEXITCODE -ne 0) { Stop-WithError "npm install -g $Package 失败" }
  Write-Ok "已安装 $Package"
}

# ---------- 恢复 ----------
function Restore-Latest {
  param([string]$Dir, [string]$FileName, [string]$Label)

  $pattern = Join-Path $Dir "$FileName.bak.sub2api-*"
  $backups = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending

  if (-not $backups -or $backups.Count -eq 0) {
    Stop-WithError "没有找到 $Label 的备份（$pattern）"
  }

  $latest = $backups[0]
  $target = Join-Path $Dir $FileName

  if ($DryRun) {
    Write-Info "[dry-run] 将用 $($latest.FullName) 覆盖 $target"
    return
  }

  Copy-Item -LiteralPath $latest.FullName -Destination $target -Force
  Write-Ok "已恢复 $Label`: $target"
  Write-Dim "  来源: $($latest.FullName)"
}

if ($Restore) {
  switch ($Client) {
    'claude-code' { Restore-Latest -Dir $ClaudeDir -FileName 'settings.json' -Label 'Claude Code' }
    'codex'       { Restore-Latest -Dir $CodexHome -FileName 'config.toml' -Label 'Codex CLI' }
    'opencode'    { Restore-Latest -Dir $OpenCodeDir -FileName 'opencode.json' -Label 'OpenCode' }
  }
  exit 0
}

# ---------- 主流程 ----------
if (-not $ApiKey) {
  $ApiKey = Read-SecretText -Prompt '请粘贴 Sub2API Key（输入不会显示）'
}

$ApiKey = ($ApiKey -replace '\s', '')
if (-not $ApiKey) { Stop-WithError 'Key 不能为空' }
if ($ApiKey -notlike 'sk-*') { Write-Warn 'Key 不以 sk- 开头，仍继续尝试。' }

$psVersion = $PSVersionTable.PSVersion.ToString()
Write-Info "平台: Windows PowerShell $psVersion    客户端: $Client    地址: $BaseUrl"

$modelsResponse = Test-ApiKey
$models = Get-ModelIds -ModelsResponse $modelsResponse
Write-Ok "Key 有效，可见 $($models.Count) 个模型"

if ($models.Count -gt 0) {
  $models | Select-Object -First 6 | ForEach-Object { Write-Host "    $_" }
  if ($models.Count -gt 6) { Write-Dim "    ... 共 $($models.Count) 个" }
}

if (-not $Model) {
  $prefer = switch ($Client) {
    'claude-code' { 'claude' }
    'codex'       { 'gpt' }
    default       { '' }
  }
  $Model = Select-PreferredModel -Models $models -Prefer $prefer
}
if ($Model) { Write-Dim "  选用模型: $Model" }

if ($InstallCli) {
  switch ($Client) {
    'claude-code' { Install-ClientCli -Package '@anthropic-ai/claude-code' }
    'codex'       { Install-ClientCli -Package '@openai/codex' }
    'opencode'    { Install-ClientCli -Package 'opencode-ai' }
  }
}

switch ($Client) {
  'claude-code' {
    $patch = @{
      env = @{
        ANTHROPIC_BASE_URL                       = $BaseUrl
        ANTHROPIC_AUTH_TOKEN                     = $ApiKey
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'
      }
    } | ConvertTo-Json -Depth 10

    if ($DryRun) {
      Write-Info "[dry-run] 将写入 $ClaudeSettings"
      Write-Host $patch
    } else {
      if (-not (Test-Path -LiteralPath $ClaudeDir)) {
        New-Item -ItemType Directory -Path $ClaudeDir -Force | Out-Null
      }
      $bak = Backup-ConfigFile -Path $ClaudeSettings
      if ($bak) { Write-Dim "  已备份: $bak" }
      Update-JsonConfig -Path $ClaudeSettings -JsonPatch $patch
      Write-Ok "已写入 $ClaudeSettings"
    }
  }

  'codex' {
    if ($DryRun) {
      Write-Info "[dry-run] 将写入 $CodexConfig"
      Write-Dim '  model_provider = "sub2api"'
      Write-Dim "  model = `"$Model`""
      Write-Dim "  [model_providers.sub2api] base_url = `"$BaseUrl/v1`""
    } else {
      if (-not (Test-Path -LiteralPath $CodexHome)) {
        New-Item -ItemType Directory -Path $CodexHome -Force | Out-Null
      }
      $bak = Backup-ConfigFile -Path $CodexConfig
      if ($bak) { Write-Dim "  已备份: $bak" }
      Update-CodexToml -Path $CodexConfig -ModelName $Model -Base $BaseUrl -Key $ApiKey
      Write-Ok "已写入 $CodexConfig"
    }
  }

  'opencode' {
    $patch = @{
      '$schema' = 'https://opencode.ai/config.json'
      provider  = @{
        sub2api = @{
          npm     = '@ai-sdk/openai-compatible'
          name    = 'Sub2API'
          options = @{
            baseURL = "$BaseUrl/v1"
            apiKey  = $ApiKey
          }
          models  = @{
            $Model = @{ name = $Model }
          }
        }
      }
    } | ConvertTo-Json -Depth 10

    if ($DryRun) {
      Write-Info "[dry-run] 将写入 $OpenCodeConfig"
      Write-Host $patch
    } else {
      if (-not (Test-Path -LiteralPath $OpenCodeDir)) {
        New-Item -ItemType Directory -Path $OpenCodeDir -Force | Out-Null
      }
      $bak = Backup-ConfigFile -Path $OpenCodeConfig
      if ($bak) { Write-Dim "  已备份: $bak" }
      Update-JsonConfig -Path $OpenCodeConfig -JsonPatch $patch
      Write-Ok "已写入 $OpenCodeConfig"
    }
  }
}

Show-Billing

if ($Smoke -and -not $DryRun) {
  Invoke-SmokeTest -ModelName $Model
}

if (-not $DryRun) {
  Write-Host ''
  Write-Ok '配置完成'
  switch ($Client) {
    'claude-code' { Write-Dim '  下一步: 新开一个 PowerShell 窗口，运行 claude' }
    'codex'       { Write-Dim '  下一步: 新开一个 PowerShell 窗口，运行 codex' }
    'opencode'    { Write-Dim '  下一步: 新开一个 PowerShell 窗口，运行 opencode' }
  }
  Write-Dim "  回滚: 重新运行脚本并加 -Restore"
  Write-Dim "  用量: $BaseUrl/keys"
}
