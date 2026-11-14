Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
Add-Type -Namespace Win32 -Name Window -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindowAsync(System.IntPtr hWnd, int nCmdShow);' -ErrorAction SilentlyContinue
if (-not ('TikTokHelper.ProcessOutputBridge' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;

namespace TikTokHelper {
  public static class ProcessOutputBridge {
    private static readonly ConcurrentQueue<string> Messages = new ConcurrentQueue<string>();
    public static readonly DataReceivedEventHandler Stdout = OnStdout;
    public static readonly DataReceivedEventHandler Stderr = OnStderr;
    private static void OnStdout(object sender, DataReceivedEventArgs e) { Messages.Enqueue(e.Data == null ? "OX" : "O" + e.Data); }
    private static void OnStderr(object sender, DataReceivedEventArgs e) { Messages.Enqueue(e.Data == null ? "EX" : "E" + e.Data); }
    public static bool TryDequeue(out string message) { return Messages.TryDequeue(out message); }
    public static void Clear() { string message; while (Messages.TryDequeue(out message)) { } }
  }
}
'@
}
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:AppDir = Join-Path $script:Root 'app'
$script:DataDir = 'E:\商品资料'
$script:ConfigDir = Join-Path $script:AppDir 'config'
$script:CandidatesPath = Join-Path $script:DataDir '商品候选资料.json'
$script:SourceWatchPath = Join-Path $script:DataDir '来源状态复核.json'
$script:ReadyPath = Join-Path $script:DataDir 'TikTok待上架.json'
$script:ReportPath = Join-Path $script:AppDir 'runs\preflight-report.json'
$script:ConfigPath = Join-Path $script:ConfigDir 'tiktok-jp.json'
$script:NodePath = Join-Path $script:Root 'runtime\node\node.exe'
$script:StatusById = @{}
$script:Candidates = @()
$script:SourceWatches = @()
$script:ReadyCandidates = @()
$script:CurrentIndex = -1
$script:Task = $null
$script:TaskKind = ''
$script:TaskTimer = $null
$script:TaskStdoutEnded = $false
$script:TaskStderrEnded = $false

foreach ($dir in @($script:DataDir, (Join-Path $script:DataDir '商品图片'), $script:ConfigDir, (Join-Path $script:Root 'runs'), (Join-Path $script:Root '.auth'))) {
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $script:CandidatesPath)) { [System.IO.File]::WriteAllText($script:CandidatesPath, '[]' + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding -ArgumentList $false)) }
if (-not (Test-Path -LiteralPath $script:SourceWatchPath)) { [System.IO.File]::WriteAllText($script:SourceWatchPath, '[]' + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding -ArgumentList $false)) }

function New-Label($text, $x, $y, $width = 130) {
  $control = New-Object System.Windows.Forms.Label
  $control.Text = $text
  $control.Location = New-Object System.Drawing.Point($x, $y)
  $control.Size = New-Object System.Drawing.Size($width, 24)
  $control.TextAlign = 'MiddleLeft'
  return $control
}

function New-TextBox($x, $y, $width, $height = 25, $multiline = $false) {
  $control = New-Object System.Windows.Forms.TextBox
  $control.Location = New-Object System.Drawing.Point($x, $y)
  $control.Size = New-Object System.Drawing.Size($width, $height)
  $control.Multiline = $multiline
  if ($multiline) { $control.ScrollBars = 'Vertical' }
  return $control
}

function New-Check($text, $x, $y, $width = 215) {
  $control = New-Object System.Windows.Forms.CheckBox
  $control.Text = $text
  $control.Location = New-Object System.Drawing.Point($x, $y)
  $control.Size = New-Object System.Drawing.Size($width, 25)
  return $control
}

function New-Combo($items, $x, $y, $width) {
  $control = New-Object System.Windows.Forms.ComboBox
  $control.Location = New-Object System.Drawing.Point($x, $y)
  $control.Size = New-Object System.Drawing.Size($width, 26)
  $control.DropDownStyle = 'DropDownList'
  [void]$control.Items.AddRange([object[]]$items)
  if ($control.Items.Count -gt 0) { $control.SelectedIndex = 0 }
  return $control
}

function Add-Button($parent, $text, $x, $y, $width, $handler) {
  $button = New-Object System.Windows.Forms.Button
  $button.Text = $text
  $button.Location = New-Object System.Drawing.Point($x, $y)
  $button.Size = New-Object System.Drawing.Size($width, 34)
  $button.Add_Click($handler)
  $parent.Controls.Add($button)
  return $button
}

function Write-Log($text) {
  $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $text"
  if ($script:LogBox) {
    $script:LogBox.AppendText("[$(Get-Date -Format 'HH:mm:ss')] $text`r`n")
  }
  try {
    $logPath = Join-Path $script:Root 'app\runs\assistant-ui.log'
    [System.IO.File]::AppendAllText($logPath, $entry + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding -ArgumentList $false))
  } catch { }
}

function Read-Candidates {
  try {
    $loaded = Get-Content -LiteralPath $script:CandidatesPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $loaded) { $script:Candidates = @() }
    elseif ($loaded -is [array]) { $script:Candidates = @($loaded) }
    else { $script:Candidates = @($loaded) }
  } catch {
    [System.Windows.Forms.MessageBox]::Show("商品资料文件格式错误：$($_.Exception.Message)", '无法读取商品资料', 'OK', 'Error') | Out-Null
    $script:Candidates = @()
  }
}

function Save-Candidates {
  $json = ConvertTo-Json -InputObject @($script:Candidates) -Depth 20
  [System.IO.File]::WriteAllText($script:CandidatesPath, $json + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding -ArgumentList $false))
}

function Read-SourceWatches {
  if (-not (Test-Path -LiteralPath $script:SourceWatchPath)) { $script:SourceWatches = @(); return }
  try {
    $loaded = Get-Content -LiteralPath $script:SourceWatchPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $loaded) { $script:SourceWatches = @() } else { $script:SourceWatches = @($loaded) }
  } catch { throw "来源复核文件无法读取：$($_.Exception.Message)" }
}

function Save-SourceWatches {
  $json = ConvertTo-Json -InputObject @($script:SourceWatches) -Depth 20
  [System.IO.File]::WriteAllText($script:SourceWatchPath, $json + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding -ArgumentList $false))
}

function Refresh-SourceWatchGrid {
  if (-not $script:WatchGrid) { return }
  Read-SourceWatches
  $script:WatchGrid.Rows.Clear()
  $now = [DateTime]::UtcNow
  foreach ($watch in $script:SourceWatches) {
    $dueAt = [DateTime]::MinValue
    try { $dueAt = [DateTime]::Parse([string]$watch.nextReviewAt).ToUniversalTime() } catch { }
    $dueText = if ($dueAt -le $now) { '已到期' } else { $dueAt.ToLocalTime().ToString('yyyy-MM-dd HH:mm') }
    $statusText = switch ([string]$watch.sourceStatus) {
      'IN_STOCK' { '有货' }
      'OUT_OF_STOCK' { '缺货待处理' }
      'SOURCE_UNAVAILABLE_CANDIDATE' { '疑似下架待确认' }
      'SOURCE_DELISTED_CONFIRMED' { '确认下架待处理' }
      'MANUAL_REVIEW' { '需人工复核' }
      default { '待复核' }
    }
    $rowIndex = $script:WatchGrid.Rows.Add([string]$watch.asin, [string]$watch.title, [string]$watch.tiktokProductId, $dueText, $statusText)
    $script:WatchGrid.Rows[$rowIndex].Tag = [string]$watch.asin
    if ($dueAt -le $now -or [string]$watch.sourceStatus -in @('OUT_OF_STOCK', 'SOURCE_UNAVAILABLE_CANDIDATE', 'SOURCE_DELISTED_CONFIRMED', 'MANUAL_REVIEW')) {
      $script:WatchGrid.Rows[$rowIndex].DefaultCellStyle.ForeColor = $script:Palette.Gold
    }
  }
  $dueCount = @($script:SourceWatches | Where-Object {
    try { [DateTime]::Parse([string]$_.nextReviewAt).ToUniversalTime() -le $now } catch { $true }
  }).Count
  if ($script:WatchSummary) { $script:WatchSummary.Text = "监控 $($script:SourceWatches.Count) 件　|　到期 $dueCount 件　|　复核周期 3 天" }
}

function Get-SelectedSourceWatch {
  if (-not $script:WatchGrid -or $script:WatchGrid.SelectedRows.Count -eq 0) { throw '先在复核列表中选择一个商品。' }
  $asin = [string]$script:WatchGrid.SelectedRows[0].Tag
  $watch = @($script:SourceWatches | Where-Object { $_.asin -eq $asin }) | Select-Object -First 1
  if (-not $watch) { throw '所选商品已不在复核记录中，请刷新列表。' }
  return $watch
}

function Record-SourceReview($watch, $status, $note) {
  $now = [DateTime]::UtcNow
  $previousStatus = [string]$watch.sourceStatus
  $watch.sourceStatus = $status
  $watch.lastCheckedAt = $now.ToString('o')
  $watch.nextReviewAt = $now.AddDays(3).ToString('o')
  $watch.lastFinding = $note
  if ($status -eq 'OUT_OF_STOCK') {
    $watch.actionRequired = if ($watch.actionCompletedForStatus -eq 'OUT_OF_STOCK') { 'NONE' } else { 'SET_TIKTOK_STOCK_ZERO' }
  }
  elseif ($status -eq 'SOURCE_UNAVAILABLE_CANDIDATE') { $watch.actionRequired = 'MANUAL_CONFIRM_SOURCE_STATUS' }
  elseif ($status -eq 'SOURCE_DELISTED_CONFIRMED') {
    $watch.actionRequired = if ($watch.actionCompletedForStatus -eq 'SOURCE_DELISTED_CONFIRMED') { 'NONE' } else { 'DELIST_TIKTOK' }
  }
  elseif ($status -eq 'IN_STOCK' -and ($previousStatus -eq 'OUT_OF_STOCK' -or $watch.actionRequired -eq 'SET_TIKTOK_STOCK_ZERO')) { $watch.actionRequired = 'REVIEW_RESTOCK' }
  elseif ($status -eq 'IN_STOCK') { $watch.actionRequired = 'NONE' }
  $history = @($watch.history) + @([pscustomobject]@{ checkedAt = $now.ToString('o'); status = $status; note = $note })
  $watch.history = $history
  Save-SourceWatches
  Refresh-SourceWatchGrid
}

function Refresh-Grid {
  if (-not $script:Grid) { return }
  Read-Candidates
  $script:StatusById = @{}
  if (Test-Path -LiteralPath $script:ReportPath) {
    try {
      $reports = Get-Content -LiteralPath $script:ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($item in @($reports)) { $script:StatusById[[string]$item.id] = [string]$item.status }
    } catch { }
  }
  $script:Grid.Rows.Clear()
  for ($i = 0; $i -lt $script:Candidates.Count; $i++) {
    $candidate = $script:Candidates[$i]
    $status = $script:StatusById[[string]$candidate.id]
    if (-not $status) { $status = '未筛查' }
    $row = $script:Grid.Rows[$script:Grid.Rows.Add([string]$candidate.id, [string]$candidate.title, $status)]
    $row.Tag = $i
  }
  if ($script:Grid.Rows.Count -gt 0) {
    $selectIndex = if ($script:CurrentIndex -ge 0 -and $script:CurrentIndex -lt $script:Grid.Rows.Count) { $script:CurrentIndex } else { 0 }
    $script:Grid.Rows[$selectIndex].Selected = $true
  }
}

function Set-FormFromCandidate($candidate, $index) {
  $script:CurrentIndex = $index
  $script:ProductId.Text = [string]$candidate.id
  $script:SourceUrl.Text = [string]$candidate.sourceUrl
  $script:SourceMethod.SelectedItem = [string]$candidate.sourceMethod
  if (-not $script:SourceMethod.SelectedItem) { $script:SourceMethod.SelectedIndex = 0 }
  $script:ProductTitle.Text = [string]$candidate.title
  $script:Category.Text = [string]$candidate.category
  $script:Price.Text = [string]$candidate.price
  $script:BrandName.Text = [string]$candidate.brandName
  $script:Description.Text = [string]$candidate.description
  $script:Images.Text = (@($candidate.productImages) -join ';')
  $script:BrandStatus.SelectedItem = [string]$candidate.brandStatus
  if (-not $script:BrandStatus.SelectedItem) { $script:BrandStatus.SelectedIndex = 0 }
  $script:InventoryOwned.Checked = $candidate.inventoryOwnedAndAvailable -ne $false
  $script:LocaleReviewed.Checked = $candidate.japanLocaleReviewed -eq $true
  $script:Sku.Text = [string]$candidate.sku
  $script:Stock.Text = if ([string]::IsNullOrWhiteSpace([string]$candidate.stock)) { '100' } else { [string]$candidate.stock }
  $script:Color.Text = [string]$candidate.attributes.'颜色'
  $script:Size.Text = [string]$candidate.attributes.'尺寸'
  $script:Material.Text = [string]$candidate.attributes.'材质'
  if ($candidate.attributes -is [System.Collections.IDictionary]) {
    $extra = foreach ($key in $candidate.attributes.Keys) { if ($key -notin @('颜色', '尺寸', '材质')) { "$key=$($candidate.attributes[$key])" } }
  } else {
    $extra = foreach ($entry in $candidate.attributes.PSObject.Properties) { if ($entry.Name -notin @('颜色', '尺寸', '材质')) { "$($entry.Name)=$($entry.Value)" } }
  }
  $script:AdditionalAttributes.Text = (@($extra) -join [Environment]::NewLine)
  $script:Fulfillment.SelectedItem = [string]$candidate.fulfillmentPlan.method
  if (-not $script:Fulfillment.SelectedItem) { $script:Fulfillment.SelectedIndex = 0 }
  $script:ReadyDays.Text = [string]$candidate.fulfillmentPlan.readyToShipWithinBusinessDays
  $script:Carrier.Text = [string]$candidate.fulfillmentPlan.trackingCarrier
  $script:CarrierApproved.Checked = $candidate.fulfillmentPlan.carrierApprovedByTikTok -eq $true
}

function Clear-ProductForm {
  $id = [guid]::NewGuid().ToString('N').Substring(0, 12)
  $empty = [pscustomobject]@{
    id = $id; sourceUrl = ''; sourceMethod = 'miaoshou_browser_plugin'; title = ''; price = ''; description = ''; category = '';
    brandName = ''; brandStatus = 'unknown';
    productImages = @();
    japanLocaleReviewed = $false; sku = ''; stock = '100'; packageWeightG = 100; packageDimensionsCm = @{ length = 10; width = 10; height = 10 }; attributes = @{};
    inventoryOwnedAndAvailable = $true;
    fulfillmentPlan = @{ method = 'amazon_mcf'; readyToShipWithinBusinessDays = 2; trackingCarrier = ''; carrierApprovedByTikTok = $false }
  }
  Set-FormFromCandidate $empty -1
}

function Save-CurrentProduct {
  $existingCandidate = $null
  if ($script:CurrentIndex -ge 0 -and $script:CurrentIndex -lt $script:Candidates.Count) { $existingCandidate = $script:Candidates[$script:CurrentIndex] }
  $images = @($script:Images.Text -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $days = 0
  if (-not [int]::TryParse($script:ReadyDays.Text, [ref]$days)) { throw '履约准备天数请填写整数。' }
  $attrs = @{}
  if ($script:Color.Text.Trim()) { $attrs['颜色'] = $script:Color.Text.Trim() }
  if ($script:Size.Text.Trim()) { $attrs['尺寸'] = $script:Size.Text.Trim() }
  if ($script:Material.Text.Trim()) { $attrs['材质'] = $script:Material.Text.Trim() }
  foreach ($line in ($script:AdditionalAttributes.Text -split "`r?`n")) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $pair = $line -split '=', 2
    if ($pair.Count -ne 2 -or [string]::IsNullOrWhiteSpace($pair[0]) -or [string]::IsNullOrWhiteSpace($pair[1])) {
      throw "商品属性格式错误：$line（每行写成 属性名=属性值）"
    }
    $attrs[$pair[0].Trim()] = $pair[1].Trim()
  }
  $brandStatus = [string]$script:BrandStatus.SelectedItem
  if ([string]::IsNullOrWhiteSpace($script:BrandName.Text) -and $brandStatus -eq 'identified_brand') { $brandStatus = 'unknown' }
  $candidate = @{
    id = $script:ProductId.Text.Trim(); sourceUrl = $script:SourceUrl.Text.Trim(); sourceMethod = [string]$script:SourceMethod.SelectedItem;
    title = $script:ProductTitle.Text.Trim(); price = $script:Price.Text.Trim(); description = $script:Description.Text.Trim(); category = $script:Category.Text.Trim();
    brandName = $script:BrandName.Text.Trim(); brandStatus = $brandStatus;
    inventoryOwnedAndAvailable = $script:InventoryOwned.Checked;
    productImages = $images; japanLocaleReviewed = $script:LocaleReviewed.Checked;
    sku = $script:Sku.Text.Trim(); stock = $(if ([string]::IsNullOrWhiteSpace($script:Stock.Text)) { '100' } else { $script:Stock.Text.Trim() }); packageWeightG = 100; packageDimensionsCm = @{ length = 10; width = 10; height = 10 }; attributes = $attrs;
    sourcePriceCny = $existingCandidate.sourcePriceCny; priceFormula = $existingCandidate.priceFormula; importMeta = $existingCandidate.importMeta; variants = $existingCandidate.variants;
    sourceWeightG = $existingCandidate.sourceWeightG; sourceProductDimensionsCm = $existingCandidate.sourceProductDimensionsCm;
    fulfillmentPlan = @{ method = [string]$script:Fulfillment.SelectedItem; readyToShipWithinBusinessDays = $days; trackingCarrier = $script:Carrier.Text.Trim(); carrierApprovedByTikTok = $script:CarrierApproved.Checked }
  }
  if (-not $candidate.id) { throw '商品 ID 不能为空。' }
  if ($script:CurrentIndex -ge 0 -and $script:CurrentIndex -lt $script:Candidates.Count) {
    $script:Candidates[$script:CurrentIndex] = [pscustomobject]$candidate
  } else {
    $script:Candidates += [pscustomobject]$candidate
    $script:CurrentIndex = $script:Candidates.Count - 1
  }
  Save-Candidates
  $script:StatusById = @{}
  $script:ReadyCandidates = @()
  foreach ($generated in @($script:ReadyPath, $script:ReportPath)) {
    if (Test-Path -LiteralPath $generated) { Remove-Item -LiteralPath $generated -Force }
  }
  Refresh-Grid
  Write-Log "已保存商品 $($candidate.id)。"
}

function Handle-TaskOutput([string]$line) {
  Write-Log $line
  if ($line -match '^LOGIN_REQUIRED\s+') { $script:Status.Text = '请在打开的妙手 ERP 页面完成登录，再继续。'; $script:ContinueButton.Text = '继续妙手 ERP 操作'; $script:ContinueButton.Enabled = $true }
  if ($line -match '^CODEX_REVIEW_REQUIRED\s+(\S+)\s+') { $script:FlowAsin.Text = $Matches[1]; $script:Status.Text = '资料已准备好，等待 Codex 复核。完成后点“刷新复核状态”。'; $script:RefreshReviewButton.Enabled = $true }
  if ($line -match '^CODEX_STARTED\s+') { $script:Status.Text = 'Codex 已启动，正在准备流程…'; $script:FlowStateHeadline.Text = 'Codex 已连接' }
  if ($line -match '^CODEX_WORKING\s+') { $script:Status.Text = $line -replace '^CODEX_WORKING\s+', ''; $script:FlowStateHeadline.Text = '正在选品采集'; $script:FlowStateHeadline.ForeColor = $script:Palette.Gold }
  if ($line -match '^CODEX_REVIEW\s+') { $script:Status.Text = '商品已自动编辑，Codex 正在复核资料与图片。'; $script:FlowStateHeadline.Text = 'Codex 复核中'; $script:FlowGateHeadline.Text = '检查资料中' }
  if ($line -match '^PRODUCT_ASIN\s+(\S+)') { $script:FlowAsin.Text = $Matches[1]; $script:FlowProductHeadline.Text = $Matches[1]; $script:Status.Text = "妙手助手正在处理商品 $($Matches[1])…"; $script:FlowStateHeadline.Text = '助手处理中' }
  if ($line -match '^CODEX_REVIEWED\s+(\S+)') { $script:FlowAsin.Text = $Matches[1]; $script:PublishFlowButton.Enabled = $true; $script:Status.Text = 'Codex 复核已通过。确认资料后可提交到 TikTok。'; $script:FlowStateHeadline.Text = '复核通过'; $script:FlowStateHeadline.ForeColor = $script:Palette.Green; $script:FlowGateHeadline.Text = '等待你确认' }
  if ($line -match '^CODEX_REVIEW_PENDING\s+') { $script:PublishFlowButton.Enabled = $false; $script:Status.Text = $line -replace '^CODEX_REVIEW_PENDING\s+', 'Codex 复核未通过：'; $script:FlowGateHeadline.Text = '需要补充'; $script:FlowGateHeadline.ForeColor = $script:Palette.Red }
  if ($line -match '^AUTOMATION_PAUSED\s+') { $script:PauseFlowButton.Text = '继续运行'; $script:PauseFlowButton.Enabled = $true; $script:Status.Text = '流程已暂停。点“继续运行”可接着处理。'; $script:FlowStateHeadline.Text = '已暂停'; $script:FlowStateHeadline.ForeColor = $script:Palette.Muted }
  if ($line -match '^AUTOMATION_RESUMED\s+') { $script:PauseFlowButton.Text = '一键暂停'; $script:PauseFlowButton.Enabled = $true; $script:Status.Text = '流程已继续。'; $script:FlowStateHeadline.Text = '正在运行'; $script:FlowStateHeadline.ForeColor = $script:Palette.Gold }
  if ($line -match '^PAUSE_REQUESTED\s+') { $script:Status.Text = '正在暂停当前步骤…' }
  if ($line -match '^FLOW_PAUSED\s+') { $script:PauseFlowButton.Text = '继续运行'; $script:PauseFlowButton.Enabled = $true; $script:Status.Text = '妙手流程已在安全检查点暂停。'; $script:FlowStateHeadline.Text = '已暂停'; $script:FlowStateHeadline.ForeColor = $script:Palette.Muted }
  if ($line -match '^FLOW_RESUMED\s+') { $script:PauseFlowButton.Text = '一键暂停'; $script:PauseFlowButton.Enabled = $true; $script:Status.Text = '妙手流程已继续。'; $script:FlowStateHeadline.Text = '正在运行'; $script:FlowStateHeadline.ForeColor = $script:Palette.Gold }
  if ($line -match '^AUTOMATION_COMPLETED\s+') { $script:Status.Text = $line -replace '^AUTOMATION_COMPLETED\s+', '' }
  if ($line -match '^CODEX_ERROR\s+') { $script:Status.Text = $line -replace '^CODEX_ERROR\s+', '' }
  if ($line -match '^(COLLECTION_NEEDS_HELP|HELPER_STOPPED)\s+') { $script:Status.Text = $line -replace '^(COLLECTION_NEEDS_HELP|HELPER_STOPPED)\s+', '' }
  if ($line -match '^SUBMITTED\s+(\S+)\s+') { $script:Status.Text = '已提交到 TikTok；妙手处理完成后请检查发布状态。'; $script:PublishFlowButton.Enabled = $false }
  if ($line -match '^FLOW_ERROR\s+') { $script:Status.Text = $line -replace '^FLOW_ERROR\s+', '' }
  if ($line -match '^PUBLISH_CONFIRM_REQUIRED\s+(\S+)\s+(.+)$') {
    $candidateId = $Matches[1]; $screenshot = $Matches[2]
    $answer = [System.Windows.Forms.MessageBox]::Show("商品 $candidateId 已填入浏览器。提交前截图：`r`n$screenshot`r`n`r`n请核对全部字段、授权、库存和物流。现在提交吗？", '最终发布确认', 'YesNo', 'Warning')
    if ($answer -eq 'Yes') { $script:Task.StandardInput.WriteLine('PUBLISH') } else { $script:Task.StandardInput.WriteLine('') }
  }
}

function Complete-NodeTask([int]$exitCode) {
  $script:Status.Text = if ($exitCode -eq 0) { '任务完成。' } else { "任务结束（代码 $exitCode），请查看日志。" }
  $script:ContinueButton.Enabled = $false
  if ($script:TaskKind -eq 'codex-workflow') { $script:StartCodexButton.Enabled = $true; $script:PauseFlowButton.Enabled = $false; $script:PauseFlowButton.Text = '一键暂停'; if ($script:PublishFlowButton.Enabled) { $script:Status.Text = 'Codex 已复核商品。检查资料后可提交。' } }
  if ($script:TaskKind -eq 'miaoshou-publish' -and $exitCode -eq 0) { $script:Status.Text = '已提交到 TikTok；请在妙手查看异步发布结果。' }
  if ($script:TaskKind -eq 'preflight') {
    if (Test-Path -LiteralPath $script:ReadyPath) { $script:ReadyCandidates = @(Get-Content -LiteralPath $script:ReadyPath -Raw -Encoding UTF8 | ConvertFrom-Json); Write-Log "筛查通过商品：$($script:ReadyCandidates.Count) 个。" }
    Refresh-Grid
  }
  if ($script:TaskKind -eq 'miaoshou-publish' -and $exitCode -ne 0) { $script:PublishFlowButton.Enabled = $true }
  if ($script:TaskKind -eq 'miaoshou-prepare' -and $exitCode -eq 0) {
    try {
      $queue = Get-Content -LiteralPath (Join-Path $script:DataDir 'Codex复核队列.json') -Raw -Encoding UTF8 | ConvertFrom-Json
      $pending = @($queue | Where-Object { $_.asin -eq $script:FlowAsin.Text -and $_.status -eq 'CODEX_REVIEW_REQUIRED' })
      $reviewed = @($queue | Where-Object { $_.asin -eq $script:FlowAsin.Text -and $_.status -eq 'CODEX_REVIEWED' })
      if ($pending.Count -gt 0) { $script:RefreshReviewButton.Enabled = $true; $script:Status.Text = '商品资料已准备好，等待 Codex 复核。' }
      if ($reviewed.Count -gt 0) { $script:PublishFlowButton.Enabled = $true; $script:Status.Text = 'Codex 已复核。检查店铺和商品后可提交。' }
    } catch { }
  }
}

function Start-NodeTask([string[]]$Arguments, [string]$Kind) {
  if (-not (Test-Path -LiteralPath $script:NodePath)) { throw "缺少内置 Node.js：$script:NodePath" }
  if ($script:Task -and -not $script:Task.HasExited) { throw '当前任务仍在运行，请等待它结束。' }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $script:NodePath; $psi.WorkingDirectory = $script:AppDir; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
  $psi.EnvironmentVariables['PLAYWRIGHT_BROWSERS_PATH'] = Join-Path $script:Root 'runtime\pw-browsers'
  $quoted = foreach ($arg in $Arguments) { '"' + ([string]$arg).Replace('"', '\"') + '"' }; $psi.Arguments = $quoted -join ' '
  $script:Task = New-Object System.Diagnostics.Process; $script:Task.StartInfo = $psi; $script:TaskKind = $Kind
  $script:TaskStdoutEnded = $false; $script:TaskStderrEnded = $false
  [TikTokHelper.ProcessOutputBridge]::Clear()
  $script:ContinueButton.Enabled = $false; $script:Status.Text = '正在运行…'
  if ($script:FlowStateHeadline) { $script:FlowStateHeadline.Text = '正在运行'; $script:FlowStateHeadline.ForeColor = $script:Palette.Gold }
  $script:Task.add_OutputDataReceived([TikTokHelper.ProcessOutputBridge]::Stdout)
  $script:Task.add_ErrorDataReceived([TikTokHelper.ProcessOutputBridge]::Stderr)
  [void]$script:Task.Start(); $script:Task.BeginOutputReadLine(); $script:Task.BeginErrorReadLine()
  if (-not $script:TaskTimer) {
    $script:TaskTimer = New-Object System.Windows.Forms.Timer; $script:TaskTimer.Interval = 100
    $script:TaskTimer.Add_Tick({
      $message = $null
      while ([TikTokHelper.ProcessOutputBridge]::TryDequeue([ref]$message)) {
        if ($message -eq 'OX') { $script:TaskStdoutEnded = $true; continue }
        if ($message -eq 'EX') { $script:TaskStderrEnded = $true; continue }
        if ($message.Length -gt 1) { Handle-TaskOutput $message.Substring(1) }
      }
      if ($script:Task -and $script:Task.HasExited -and $script:TaskStdoutEnded -and $script:TaskStderrEnded) {
        $script:TaskTimer.Stop(); Complete-NodeTask $script:Task.ExitCode
      }
    })
  }
  $script:TaskTimer.Start()
  Write-Log "已启动 $Kind。"
}

$script:Form = New-Object System.Windows.Forms.Form
$script:Form.Text = 'TikTok 日本商品上架助手'
$script:Form.Size = New-Object System.Drawing.Size(1360, 1010)
$script:Form.MinimumSize = New-Object System.Drawing.Size(1220, 900)
$script:Form.StartPosition = 'CenterScreen'
$script:Form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$script:Palette = @{
  Background = [System.Drawing.Color]::FromArgb(13, 20, 29)
  Surface = [System.Drawing.Color]::FromArgb(20, 29, 40)
  Raised = [System.Drawing.Color]::FromArgb(27, 39, 52)
  Input = [System.Drawing.Color]::FromArgb(12, 18, 26)
  Border = [System.Drawing.Color]::FromArgb(49, 64, 79)
  Text = [System.Drawing.Color]::FromArgb(229, 235, 240)
  Muted = [System.Drawing.Color]::FromArgb(145, 161, 175)
  Gold = [System.Drawing.Color]::FromArgb(229, 184, 75)
  GoldDim = [System.Drawing.Color]::FromArgb(89, 70, 31)
  Green = [System.Drawing.Color]::FromArgb(80, 197, 157)
  Red = [System.Drawing.Color]::FromArgb(221, 115, 105)
}
$script:Form.BackColor = $script:Palette.Background
$script:Form.ForeColor = $script:Palette.Text

$title = New-Object System.Windows.Forms.Label
$title.Text = 'TikTok 日本商品上架助手'
$title.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 19, [System.Drawing.FontStyle]::Bold)
$title.Location = New-Object System.Drawing.Point(24, 13)
$title.Size = New-Object System.Drawing.Size(760, 36)
$title.ForeColor = $script:Palette.Text
$script:Form.Controls.Add($title)
$subtitle = New-Label '从 Amazon.co.jp 选品采集，经妙手编辑和 Codex 复核后，再由你确认提交。' 26 51 1190
$subtitle.ForeColor = $script:Palette.Muted
$script:Form.Controls.Add($subtitle)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(20, 83)
$tabs.Size = New-Object System.Drawing.Size(1310, 790)
$tabs.Appearance = 'FlatButtons'
$tabs.SizeMode = 'Fixed'
$tabs.ItemSize = New-Object System.Drawing.Size(128, 34)
$tabs.BackColor = $script:Palette.Background
$tabs.ForeColor = $script:Palette.Text
$tabs.DrawMode = 'OwnerDrawFixed'
$tabs.Add_DrawItem({
  param($sender, $eventArgs)
  $page = $sender.TabPages[$eventArgs.Index]
  $active = ($sender.SelectedIndex -eq $eventArgs.Index)
  $back = if ($active) { $script:Palette.Surface } else { $script:Palette.Background }
  $fore = if ($active) { $script:Palette.Gold } else { $script:Palette.Muted }
  $brush = New-Object System.Drawing.SolidBrush($back)
  $eventArgs.Graphics.FillRectangle($brush, $eventArgs.Bounds)
  $brush.Dispose()
  [System.Windows.Forms.TextRenderer]::DrawText($eventArgs.Graphics, $page.Text, $sender.Font, $eventArgs.Bounds, $fore, [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter)
})
$script:Form.Controls.Add($tabs)
$productTab = New-Object System.Windows.Forms.TabPage
$productTab.Text = '高级资料'
$settingsTab = New-Object System.Windows.Forms.TabPage
$settingsTab.Text = '流程说明'
$script:FlowTab = New-Object System.Windows.Forms.TabPage
$script:FlowTab.Text = '一键上架'
$sourceWatchTab = New-Object System.Windows.Forms.TabPage
$sourceWatchTab.Text = '来源库存复核'
$tabs.TabPages.Add($script:FlowTab)
$tabs.TabPages.Add($sourceWatchTab)
$tabs.TabPages.Add($productTab)
$tabs.TabPages.Add($settingsTab)

$watchTitle = New-Label 'Amazon 来源状态 · 三天复核' 26 20 800
$watchTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 17, [System.Drawing.FontStyle]::Bold)
$sourceWatchTab.Controls.Add($watchTitle)
$script:WatchSummary = New-Label '读取复核记录…' 28 60 700
$script:WatchSummary.ForeColor = $script:Palette.Gold
$sourceWatchTab.Controls.Add($script:WatchSummary)
$watchHelp = New-Label 'Codex 到期后检查来源商品并记录 TikTok 商品 ID。缺货/确认下架的商品会列为待处理；接口无法确认时转人工复核。' 28 88 1200
$watchHelp.ForeColor = $script:Palette.Muted
$sourceWatchTab.Controls.Add($watchHelp)

$script:WatchGrid = New-Object System.Windows.Forms.DataGridView
$script:WatchGrid.Location = New-Object System.Drawing.Point(24, 122)
$script:WatchGrid.Size = New-Object System.Drawing.Size(1230, 430)
$script:WatchGrid.ReadOnly = $true
$script:WatchGrid.AllowUserToAddRows = $false
$script:WatchGrid.AllowUserToDeleteRows = $false
$script:WatchGrid.MultiSelect = $false
$script:WatchGrid.SelectionMode = 'FullRowSelect'
$script:WatchGrid.RowHeadersVisible = $false
[void]$script:WatchGrid.Columns.Add('Asin', 'Amazon ASIN')
[void]$script:WatchGrid.Columns.Add('Title', '商品标题')
[void]$script:WatchGrid.Columns.Add('TikTokId', 'TikTok 商品 ID')
[void]$script:WatchGrid.Columns.Add('Due', '下次复核 / 到期')
[void]$script:WatchGrid.Columns.Add('Status', '来源状态 / 待办')
$script:WatchGrid.Columns[0].Width = 120
$script:WatchGrid.Columns[1].Width = 535
$script:WatchGrid.Columns[2].Width = 180
$script:WatchGrid.Columns[3].Width = 180
$script:WatchGrid.Columns[4].Width = 190
$sourceWatchTab.Controls.Add($script:WatchGrid)

$sourceWatchTab.Controls.Add((New-Label 'Amazon ASIN / 链接' 28 570 150))
$script:WatchAsin = New-TextBox 180 568 210
$sourceWatchTab.Controls.Add($script:WatchAsin)
$sourceWatchTab.Controls.Add((New-Label 'TikTok 在线商品 ID' 410 570 160))
$script:WatchTikTokId = New-TextBox 570 568 220
$sourceWatchTab.Controls.Add($script:WatchTikTokId)
$sourceWatchTab.Controls.Add((New-Label '商品名称（备注）' 810 570 145))
$script:WatchProductTitle = New-TextBox 955 568 285
$sourceWatchTab.Controls.Add($script:WatchProductTitle)

Add-Button $sourceWatchTab '从当前商品带入' 28 610 150 {
  try {
    if ($script:CurrentIndex -lt 0 -or $script:CurrentIndex -ge $script:Candidates.Count) { throw '请先在“高级资料”中选择一件商品。' }
    $candidate = $script:Candidates[$script:CurrentIndex]
    $source = [string]$candidate.sourceUrl
    $asin = [string]$candidate.id
    if ($source -match '(?i)(?:/dp/|/gp/product/)([A-Z0-9]{10})') { $asin = $Matches[1].ToUpper() }
    elseif ($asin -notmatch '^[A-Za-z0-9]{10}$') { throw '当前资料没有有效 Amazon ASIN，请手动填写。' }
    $script:WatchAsin.Text = $asin
    $script:WatchProductTitle.Text = [string]$candidate.title
    $script:WatchTikTokId.Clear()
    [System.Windows.Forms.MessageBox]::Show('已带入来源 ASIN 和标题。TikTok 在线商品 ID 需从已发布商品详情中填写；采集箱 ID 不能代替在线商品 ID。','登记复核商品','OK','Information') | Out-Null
  } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '无法带入商品', 'OK', 'Warning') | Out-Null }
} | Out-Null

Add-Button $sourceWatchTab '登记已上架商品' 190 610 160 {
  try {
    $asinInput = $script:WatchAsin.Text.Trim()
    if ($asinInput -match '(?i)(?:/dp/|/gp/product/)([A-Z0-9]{10})') { $asinInput = $Matches[1].ToUpper() }
    if ($asinInput -notmatch '^[A-Z0-9]{10}$') { throw '请输入 Amazon.co.jp 商品链接或 10 位 ASIN。' }
    $liveId = $script:WatchTikTokId.Text.Trim()
    if ($liveId -notmatch '^\d{8,30}$') { throw '请输入 TikTok 已发布商品的在线商品 ID。采集箱 ID 不适用。' }
    $existing = @($script:SourceWatches | Where-Object { $_.asin -eq $asinInput -or $_.tiktokProductId -eq $liveId })
    if ($existing.Count -gt 0) { throw '该 ASIN 或 TikTok 商品 ID 已在复核列表中。' }
    $confirm = [System.Windows.Forms.MessageBox]::Show("確認商品已在 TikTok 店铺上架？`r`nASIN：$asinInput`r`nTikTok 商品 ID：$liveId", '登记三天复核', 'YesNo', 'Question')
    if ($confirm -ne 'Yes') { return }
    $now = [DateTime]::UtcNow
    $watch = [pscustomobject]@{
      asin = $asinInput; sourceUrl = "https://www.amazon.co.jp/dp/$asinInput"; tiktokProductId = $liveId
      title = $script:WatchProductTitle.Text.Trim(); listedConfirmedAt = $now.ToString('o'); lastCheckedAt = $now.ToString('o')
      nextReviewAt = $now.AddDays(3).ToString('o'); sourceStatus = 'PENDING'; actionRequired = 'NONE'; lastFinding = '等待首次复核'; history = @()
    }
    $script:SourceWatches = @($script:SourceWatches) + @($watch)
    Save-SourceWatches
    Refresh-SourceWatchGrid
    $script:Status.Text = "已登记 $asinInput；首次复核到期：$($now.AddDays(3).ToLocalTime().ToString('yyyy-MM-dd HH:mm'))。"
    Write-Log "已登记来源复核：$asinInput / TikTok $liveId。"
  } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '无法登记', 'OK', 'Warning') | Out-Null }
} | Out-Null

Add-Button $sourceWatchTab '刷新复核列表' 360 610 140 { try { Refresh-SourceWatchGrid } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '刷新失败', 'OK', 'Error') | Out-Null } } | Out-Null
Add-Button $sourceWatchTab '复制 Amazon 来源' 510 610 160 {
  try {
    $watch = Get-SelectedSourceWatch
    Set-Clipboard -Value ([string]$watch.sourceUrl)
    $script:Status.Text = '已复制 Amazon 来源链接；请手动在浏览器中打开。'
  } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '无法复制来源链接', 'OK', 'Warning') | Out-Null }
} | Out-Null
Add-Button $sourceWatchTab '标记有货' 680 610 110 {
  try { $watch = Get-SelectedSourceWatch; Record-SourceReview $watch 'IN_STOCK' '页面可正常购买；由人工/Codex 确认。' }
  catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '无法记录', 'OK', 'Warning') | Out-Null }
} | Out-Null
Add-Button $sourceWatchTab '标记缺货' 800 610 110 {
  try {
    $watch = Get-SelectedSourceWatch
    $confirmText = '确认 Amazon 页面明确显示缺货？' + [Environment]::NewLine + 'TikTok 商品 ID：' + [string]$watch.tiktokProductId + [Environment]::NewLine + '记录后会加入库存设为 0 的待处理清单。'
    $confirm = [System.Windows.Forms.MessageBox]::Show($confirmText, '确认来源缺货', 'YesNo', 'Warning')
    if ($confirm -eq 'Yes') { Record-SourceReview $watch 'OUT_OF_STOCK' 'Amazon 页面明确显示当前不可购买；TikTok 库存需设为 0。' }
  } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '无法记录', 'OK', 'Warning') | Out-Null }
} | Out-Null
Add-Button $sourceWatchTab '标记疑似下架' 920 610 140 {
  try {
    $watch = Get-SelectedSourceWatch
    $confirmText = '仅在来源商品页明确显示商品已不存在/已下架时选择。访问失败、验证码、地区配送限制都不能当作下架。' + [Environment]::NewLine + 'TikTok 商品 ID：' + [string]$watch.tiktokProductId + [Environment]::NewLine + '是否记录为待确认下架？'
    $confirm = [System.Windows.Forms.MessageBox]::Show($confirmText, '来源下架需复核', 'YesNo', 'Warning')
    if ($confirm -eq 'Yes') { Record-SourceReview $watch 'SOURCE_UNAVAILABLE_CANDIDATE' '来源页被标记为疑似下架；需复查后才处理 TikTok。' }
  } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '无法记录', 'OK', 'Warning') | Out-Null }
} | Out-Null
Add-Button $sourceWatchTab '复制 TikTok 商品管理' 1070 610 180 {
  try { $null = Get-SelectedSourceWatch; Set-Clipboard -Value 'https://seller-jp.tiktok.com/product/listing?shop_region=JP'; $script:Status.Text = '已复制 TikTok 商品管理链接；请手动在浏览器中打开。' }
  catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '无法打开商品管理', 'OK', 'Warning') | Out-Null }
} | Out-Null
$watchFooter = New-Label 'Codex 定时复核会写入状态和待办 ID；妙手没有在线商品修改接口时，将打开 TikTok 商品管理页供人工完成。下架需再次核实，接口/页面异常不会自动下架。' 28 660 1210
$watchFooter.ForeColor = $script:Palette.Muted
$sourceWatchTab.Controls.Add($watchFooter)
Add-Button $sourceWatchTab '确认来源确已下架' 28 695 170 {
  try {
    $watch = Get-SelectedSourceWatch
    if ($watch.sourceStatus -ne 'SOURCE_UNAVAILABLE_CANDIDATE') { throw '先将该商品标记为“疑似下架”，并完成二次核查。' }
    $confirmText = '再次确认：来源 ASIN ' + [string]$watch.asin + ' 确实已下架/删除？' + [Environment]::NewLine + '确认后会将 TikTok 商品 ' + [string]$watch.tiktokProductId + ' 列为下架待办；页面访问异常、验证码或配送限制不算下架。'
    $confirm = [System.Windows.Forms.MessageBox]::Show($confirmText, '确认下架状态', 'YesNo', 'Warning')
    if ($confirm -eq 'Yes') { Record-SourceReview $watch 'SOURCE_DELISTED_CONFIRMED' '人工二次确认来源商品已下架；TikTok 商品需下架。' }
  } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '无法确认', 'OK', 'Warning') | Out-Null }
} | Out-Null
Add-Button $sourceWatchTab '导出待处理商品 ID' 210 695 170 {
  try {
    Read-SourceWatches
    $pending = @($script:SourceWatches | Where-Object { $_.actionRequired -and $_.actionRequired -ne 'NONE' } | Select-Object asin, tiktokProductId, title, sourceStatus, actionRequired, lastCheckedAt, lastFinding)
    $exportPath = Join-Path $script:DataDir '来源复核待处理.csv'
    if ($pending.Count -gt 0) { $pending | Export-Csv -LiteralPath $exportPath -NoTypeInformation -Encoding UTF8 }
    else { '"asin","tiktokProductId","title","sourceStatus","actionRequired","lastCheckedAt","lastFinding"' | Set-Content -LiteralPath $exportPath -Encoding UTF8 }
    [System.Windows.Forms.MessageBox]::Show("待处理商品：$($pending.Count)`r`n文件：$exportPath", '已导出待办 ID', 'OK', 'Information') | Out-Null
  } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '导出失败', 'OK', 'Error') | Out-Null }
} | Out-Null
Add-Button $sourceWatchTab '标记所选操作已完成' 392 695 190 {
  try {
    $watch = Get-SelectedSourceWatch
    if (-not $watch.actionRequired -or $watch.actionRequired -eq 'NONE') { throw '所选商品当前没有待处理操作。' }
    $confirm = [System.Windows.Forms.MessageBox]::Show("确认已在 TikTok Seller Center/妙手完成 $($watch.actionRequired)？`r`n商品 ID：$($watch.tiktokProductId)", '确认操作完成', 'YesNo', 'Question')
    if ($confirm -eq 'Yes') {
      $watch.actionRequired = 'NONE'
      $watch.actionCompletedAt = [DateTime]::UtcNow.ToString('o')
      $watch.actionCompletedForStatus = [string]$watch.sourceStatus
      $watch.history = @($watch.history) + @([pscustomobject]@{ checkedAt = [DateTime]::UtcNow.ToString('o'); status = [string]$watch.sourceStatus; note = '人工确认 TikTok 端待办操作已完成。' })
      Save-SourceWatches
      Refresh-SourceWatchGrid
    }
  } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '无法更新', 'OK', 'Warning') | Out-Null }
} | Out-Null

$flowCardSpecs = @(
  @{ X = 28; Title = '流程状态'; Value = '待命'; Hint = 'Codex 与妙手助手就绪' },
  @{ X = 438; Title = '当前商品'; Value = '尚未选择'; Hint = '等待 Codex 筛选' },
  @{ X = 848; Title = '发布检查'; Value = '等待复核'; Hint = '由你确认提交' }
)
foreach ($spec in $flowCardSpecs) {
  $card = New-Object System.Windows.Forms.Panel
  $card.Location = New-Object System.Drawing.Point($spec.X, 92)
  $card.Size = New-Object System.Drawing.Size(396, 78)
  $card.BackColor = $script:Palette.Surface
  $card.BorderStyle = 'FixedSingle'
  $script:FlowTab.Controls.Add($card)
  $heading = New-Object System.Windows.Forms.Label
  $heading.Text = $spec.Title
  $heading.Location = New-Object System.Drawing.Point(16, 10)
  $heading.Size = New-Object System.Drawing.Size(160, 20)
  $heading.ForeColor = $script:Palette.Muted
  $card.Controls.Add($heading)
  $value = New-Object System.Windows.Forms.Label
  $value.Text = $spec.Value
  $value.Location = New-Object System.Drawing.Point(16, 31)
  $value.Size = New-Object System.Drawing.Size(240, 31)
  $value.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 16, [System.Drawing.FontStyle]::Bold)
  $value.ForeColor = $script:Palette.Text
  $card.Controls.Add($value)
  $hint = New-Object System.Windows.Forms.Label
  $hint.Text = $spec.Hint
  $hint.Location = New-Object System.Drawing.Point(250, 36)
  $hint.Size = New-Object System.Drawing.Size(132, 23)
  $hint.ForeColor = $script:Palette.Muted
  $hint.TextAlign = 'MiddleRight'
  $card.Controls.Add($hint)
  if ($spec.Title -eq '流程状态') { $script:FlowStateHeadline = $value }
  if ($spec.Title -eq '当前商品') { $script:FlowProductHeadline = $value }
  if ($spec.Title -eq '发布检查') { $script:FlowGateHeadline = $value }
}

$pipeline = New-Object System.Windows.Forms.Panel
$pipeline.Location = New-Object System.Drawing.Point(28, 184)
$pipeline.Size = New-Object System.Drawing.Size(1216, 84)
$pipeline.BackColor = $script:Palette.Surface
$pipeline.BorderStyle = 'FixedSingle'
$script:FlowTab.Controls.Add($pipeline)
$pipelineSteps = @('选品与采集', '认领与编辑', 'Codex 复核', '人工确认', '提交发布')
$stepX = @(20, 263, 506, 749, 992)
for ($i = 0; $i -lt $pipelineSteps.Count; $i++) {
  $step = New-Object System.Windows.Forms.Label
  $step.Text = "$(($i + 1).ToString('00'))  $($pipelineSteps[$i])"
  $step.Location = New-Object System.Drawing.Point($stepX[$i], 22)
  $step.Size = New-Object System.Drawing.Size(205, 30)
  $step.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
  $step.ForeColor = if ($i -eq 0) { $script:Palette.Gold } else { $script:Palette.Muted }
  $pipeline.Controls.Add($step)
  if ($i -lt $pipelineSteps.Count - 1) {
    $connector = New-Object System.Windows.Forms.Label
    $connector.Text = '›'
    $connector.Location = New-Object System.Drawing.Point(($stepX[$i] + 207), 20)
    $connector.Size = New-Object System.Drawing.Size(24, 32)
    $connector.Font = New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Regular)
    $connector.ForeColor = $script:Palette.GoldDim
    $pipeline.Controls.Add($connector)
  }
}

$flowInfoPanel = New-Object System.Windows.Forms.Panel
$flowInfoPanel.Location = New-Object System.Drawing.Point(28, 470)
$flowInfoPanel.Size = New-Object System.Drawing.Size(1216, 148)
$flowInfoPanel.BackColor = $script:Palette.Surface
$flowInfoPanel.BorderStyle = 'FixedSingle'
$script:FlowTab.Controls.Add($flowInfoPanel)

$flowTitle = New-Label 'Amazon 日本站 → TikTok Shop 日本' 28 18 1000
$flowTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 17, [System.Drawing.FontStyle]::Bold)
$script:FlowTab.Controls.Add($flowTitle)
$script:FlowTab.Controls.Add((New-Label 'Codex 按关键词筛选候选商品并调用妙手插件采集，之后由助手自动认领和编辑。' 30 55 1120))
$script:FlowTab.Controls.Add((New-Label '选品关键词或类目' 30 294 180))
$script:SearchCriteria = New-TextBox 220 289 800
$script:SearchCriteria.Text = '家居收纳'
$script:FlowTab.Controls.Add($script:SearchCriteria)
$searchAmazon = New-Object System.Windows.Forms.Button
$searchAmazon.Text = '复制 Amazon 搜索链接'
$searchAmazon.Location = New-Object System.Drawing.Point(1045, 287)
$searchAmazon.Size = New-Object System.Drawing.Size(180, 34)
$searchAmazon.Add_Click({
  try {
    $criteria = $script:SearchCriteria.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($criteria)) { throw '先填写产品关键词或类目，例如“デスク下収納”。' }
    $searchUrl = 'https://www.amazon.co.jp/s?k=' + [System.Uri]::EscapeDataString($criteria)
    Set-Clipboard -Value $searchUrl
    $script:Status.Text = '已复制 Amazon 搜索链接；请在助手专用 Chrome 中手动打开。'
    Write-Log '已复制 Amazon 搜索链接；不会自动打开网页。'
  } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '无法搜索商品', 'OK', 'Warning') | Out-Null }
})
$script:FlowTab.Controls.Add($searchAmazon)
$script:FlowTab.Controls.Add((New-Label '已采集商品链接或 ASIN' 30 341 180))
$script:FlowAsin = New-TextBox 220 336 800
$script:FlowTab.Controls.Add($script:FlowAsin)
$openAmazon = New-Object System.Windows.Forms.Button
$openAmazon.Text = '复制商品链接'
$openAmazon.Location = New-Object System.Drawing.Point(1045, 334)
$openAmazon.Size = New-Object System.Drawing.Size(180, 34)
$openAmazon.Add_Click({
  try {
    $value = $script:FlowAsin.Text.Trim()
    if ($value -match '(?i)(?:/dp/|/gp/product/)([A-Z0-9]{10})') { $value = "https://www.amazon.co.jp/dp/$($Matches[1].ToUpper())" }
    elseif ($value -match '^[A-Za-z0-9]{10}$') { $value = "https://www.amazon.co.jp/dp/$($value.ToUpper())" }
    if ($value -notmatch '^https://www\.amazon\.co\.jp/') { throw '请输入 Amazon.co.jp 商品链接或 10 位 ASIN。' }
    Set-Clipboard -Value $value
    $script:Status.Text = '已复制 Amazon 商品链接；请在助手专用 Chrome 中手动打开。'
    Write-Log '已复制 Amazon.co.jp 商品链接；不会自动打开网页。'
  } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '无法复制商品链接', 'OK', 'Warning') | Out-Null }
})
$script:FlowTab.Controls.Add($openAmazon)
$script:FlowTab.Controls.Add((New-Label '点击“一键启动”准备专用 Chrome；请在该窗口手动打开 Amazon/妙手页面并登录，再点继续运行。最终提交仍由你确认。' 30 379 1120))
$script:StartCodexButton = New-Object System.Windows.Forms.Button
$script:StartCodexButton.Text = '一键启动 Codex 流程'
$script:StartCodexButton.Location = New-Object System.Drawing.Point(28, 410)
$script:StartCodexButton.Size = New-Object System.Drawing.Size(238, 44)
$script:StartCodexButton.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
$script:StartCodexButton.Add_Click({
  try {
    $criteria = $script:SearchCriteria.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($criteria)) { throw '先填写选品关键词或类目。' }
    $script:StartCodexButton.Enabled = $false
    $script:PauseFlowButton.Enabled = $true
    $script:PauseFlowButton.Text = '一键暂停'
    $script:PublishFlowButton.Enabled = $false
    Start-NodeTask @('src\codex-orchestrator.mjs', '--criteria', $criteria) 'codex-workflow'
  } catch {
    $script:StartCodexButton.Enabled = $true
    $script:PauseFlowButton.Enabled = $false
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '无法启动流程', 'OK', 'Warning') | Out-Null
  }
})
$script:FlowTab.Controls.Add($script:StartCodexButton)
$script:PauseFlowButton = New-Object System.Windows.Forms.Button
$script:PauseFlowButton.Text = '一键暂停'
$script:PauseFlowButton.Location = New-Object System.Drawing.Point(278, 410)
$script:PauseFlowButton.Size = New-Object System.Drawing.Size(155, 44)
$script:PauseFlowButton.Enabled = $false
$script:PauseFlowButton.Add_Click({
  if (-not $script:Task -or $script:Task.HasExited -or $script:TaskKind -ne 'codex-workflow') { return }
  try {
    if ($script:PauseFlowButton.Text -eq '继续运行') {
      $script:Task.StandardInput.WriteLine('RESUME')
      $script:PauseFlowButton.Enabled = $false
      $script:Status.Text = '正在继续流程…'
    } else {
      $script:Task.StandardInput.WriteLine('PAUSE')
      $script:PauseFlowButton.Enabled = $false
      $script:Status.Text = '正在暂停流程…'
    }
  } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '无法控制流程', 'OK', 'Warning') | Out-Null }
})
$script:FlowTab.Controls.Add($script:PauseFlowButton)
$prepareFlow = New-Object System.Windows.Forms.Button
$prepareFlow.Text = '处理已采集商品'
$prepareFlow.Location = New-Object System.Drawing.Point(445, 410)
$prepareFlow.Size = New-Object System.Drawing.Size(190, 44)
$prepareFlow.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
$prepareFlow.Add_Click({
  try {
    $value = $script:FlowAsin.Text.Trim()
    if ($value -match '(?i)(?:/dp/|/gp/product/)([A-Z0-9]{10})') { $value = $Matches[1].ToUpper() }
    if ($value -notmatch '^[A-Za-z0-9]{10}$') { throw '请输入 Amazon.co.jp 商品链接或 10 位 ASIN。' }
    $script:FlowAsin.Text = $value.ToUpper()
    $script:PublishFlowButton.Enabled = $false
    Start-NodeTask @('src\miaoshou-flow.mjs', '--prepare', '--asin', $value.ToUpper()) 'miaoshou-prepare'
  } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '无法开始处理', 'OK', 'Warning') | Out-Null }
})
$script:FlowTab.Controls.Add($prepareFlow)
$script:PublishFlowButton = New-Object System.Windows.Forms.Button
$script:RefreshReviewButton = New-Object System.Windows.Forms.Button
$script:RefreshReviewButton.Text = '刷新 Codex 复核状态'
$script:RefreshReviewButton.Location = New-Object System.Drawing.Point(650, 410)
$script:RefreshReviewButton.Size = New-Object System.Drawing.Size(220, 44)
$script:RefreshReviewButton.Enabled = $false
$script:RefreshReviewButton.Add_Click({
  try {
    $queuePath = Join-Path $script:DataDir 'Codex复核队列.json'
    if (-not (Test-Path -LiteralPath $queuePath)) { throw '还没有生成复核队列。' }
    $queue = Get-Content -LiteralPath $queuePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $row = @($queue | Where-Object { $_.asin -eq $script:FlowAsin.Text.Trim().ToUpper() }) | Select-Object -First 1
    if (-not $row) { throw '复核队列中没有当前商品。' }
    if ($row.status -eq 'CODEX_REVIEWED') {
      $script:PublishFlowButton.Enabled = $true
      $script:Status.Text = 'Codex 已复核。检查店铺和商品后可提交。'
      Write-Log "Codex 已复核 $($row.asin)。"
    } else {
      $script:PublishFlowButton.Enabled = $false
      $script:Status.Text = '还未收到 Codex 已复核标记。请先让 Codex 核对商品资料。'
    }
  } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '复核状态', 'OK', 'Information') | Out-Null }
})
$script:FlowTab.Controls.Add($script:RefreshReviewButton)
$script:PublishFlowButton = New-Object System.Windows.Forms.Button
$script:PublishFlowButton.Text = '提交到 TikTok'
$script:PublishFlowButton.Location = New-Object System.Drawing.Point(886, 410)
$script:PublishFlowButton.Size = New-Object System.Drawing.Size(200, 44)
$script:PublishFlowButton.Enabled = $false
$script:PublishFlowButton.Add_Click({
  $asin = $script:FlowAsin.Text.Trim().ToUpper()
$answer = [System.Windows.Forms.MessageBox]::Show("确认将 $asin 提交到 TikTok 店铺「ひよりセレクト」吗？提交后由妙手异步处理。", '确认提交', 'YesNo', 'Warning')
  if ($answer -eq 'Yes') {
    try { $script:PublishFlowButton.Enabled = $false; Start-NodeTask @('src\miaoshou-flow.mjs', '--publish', '--asin', $asin) 'miaoshou-publish' }
    catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '无法提交', 'OK', 'Warning') | Out-Null }
  }
})
$script:FlowAsin.Add_TextChanged({ $script:PublishFlowButton.Enabled = $false; $script:RefreshReviewButton.Enabled = $false })
$script:FlowTab.Controls.Add($script:PublishFlowButton)
$flowNote = New-Object System.Windows.Forms.Label
$flowNote.Text = [String]::Join([Environment]::NewLine, @(
  '自动应用的设置',
  '店铺：ひよりセレクト（日本）　库存：每个 SKU 100　包裹：100g / 10 × 10 × 10cm',
  '售价：人民币采集价 × 2.5 × 运行时 CNY/JPY 汇率　　描述删除产地和商品 ID',
  '',
  '流程会拦截化妆品、食品、医药类和检测到的一线品牌。类目、翻译、价格依据或商品信息不明确时会暂停，交给 Codex 复核。',
  '一键启动会调用本机 Codex 并准备专用 Chrome 空白窗口；请在其中手动登录、启用妙手插件并打开 Amazon/妙手页面。浏览器资料保存在 E:\TikTok商品上架助手\runtime\browser-profile。',
  '一键暂停会中断 Codex，妙手编辑会停在安全检查点。登录凭据和验证码由你手动处理；助手不会自动发布。',
  '遇到验证码或风控提示就停止，不做规避。Codex 复核通过并由你确认后才提交发布。'
))
$flowNote.Location = New-Object System.Drawing.Point(16, 12)
$flowNote.Size = New-Object System.Drawing.Size(1180, 126)
$flowNote.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
$flowInfoPanel.Controls.Add($flowNote)

$script:Grid = New-Object System.Windows.Forms.DataGridView
$script:Grid.Location = New-Object System.Drawing.Point(14, 12)
$script:Grid.Size = New-Object System.Drawing.Size(1145, 130)
$script:Grid.ReadOnly = $true
$script:Grid.AllowUserToAddRows = $false
$script:Grid.AllowUserToDeleteRows = $false
$script:Grid.MultiSelect = $false
$script:Grid.SelectionMode = 'FullRowSelect'
$script:Grid.RowHeadersVisible = $false
[void]$script:Grid.Columns.Add('Id', '商品 ID')
[void]$script:Grid.Columns.Add('Title', '商品标题')
[void]$script:Grid.Columns.Add('Status', '筛查状态')
$script:Grid.Columns[0].Width = 180
$script:Grid.Columns[1].Width = 770
$script:Grid.Columns[2].Width = 150
$productTab.Controls.Add($script:Grid)

$productTab.Controls.Add((New-Label '商品 ID' 15 153 90))
$script:ProductId = New-TextBox 105 153 180
$productTab.Controls.Add($script:ProductId)
$productTab.Controls.Add((New-Label '来源链接（仅记录）' 300 153 150))
$script:SourceUrl = New-TextBox 450 153 475
$productTab.Controls.Add($script:SourceUrl)
$productTab.Controls.Add((New-Label '资料来源' 935 153 70))
$script:SourceMethod = New-Combo @('miaoshou_browser_plugin', 'manual', 'authorized_export', 'authorized_sp_api') 1005 153 155
$productTab.Controls.Add($script:SourceMethod)

$productTab.Controls.Add((New-Label '日文标题' 15 188 90))
$script:ProductTitle = New-TextBox 105 188 490
$productTab.Controls.Add($script:ProductTitle)
$productTab.Controls.Add((New-Label '类目' 605 188 55))
$script:Category = New-TextBox 660 188 240
$productTab.Controls.Add($script:Category)
$productTab.Controls.Add((New-Label '价格（日元）' 910 188 95))
$script:Price = New-TextBox 1005 188 155
$productTab.Controls.Add($script:Price)

$productTab.Controls.Add((New-Label '商品描述' 15 223 90))
$script:Description = New-TextBox 105 223 650 88 $true
$productTab.Controls.Add($script:Description)
$productTab.Controls.Add((New-Label '品牌名' 770 223 70))
$script:BrandName = New-TextBox 840 223 320
$productTab.Controls.Add($script:BrandName)
$productTab.Controls.Add((New-Label '品牌状态' 770 258 70))
$script:BrandStatus = New-Combo @('unknown', 'confirmed_unbranded', 'china_generic_brand', 'platform_owned_brand', 'identified_brand', 'counterfeit_or_infringing') 840 258 320
$productTab.Controls.Add($script:BrandStatus)

$productTab.Controls.Add((New-Label '商品图片路径（用分号分隔）' 15 321 190))
$script:Images = New-TextBox 205 321 805 50 $true
$productTab.Controls.Add($script:Images)
$browseImages = New-Object System.Windows.Forms.Button
$browseImages.Text = '选择图片…'
$browseImages.Location = New-Object System.Drawing.Point(1020, 321)
$browseImages.Size = New-Object System.Drawing.Size(140, 32)
$browseImages.Add_Click({
  $dialog = New-Object System.Windows.Forms.OpenFileDialog
  $dialog.Multiselect = $true
  $dialog.InitialDirectory = Join-Path $script:DataDir '商品图片'
  $dialog.Filter = '图片文件|*.jpg;*.jpeg;*.png;*.webp;*.bmp|所有文件|*.*'
  if ($dialog.ShowDialog() -eq 'OK') {
    $existing = @($script:Images.Text -split ';' | Where-Object { $_ })
    $script:Images.Text = (@($existing + $dialog.FileNames | Select-Object -Unique) -join ';')
  }
})
$productTab.Controls.Add($browseImages)

$script:InventoryOwned = New-Check '商品有自有且可售库存' 15 378 260
$script:InventoryOwned.Checked = $true
$productTab.Controls.Add($script:InventoryOwned)
$script:LocaleReviewed = New-Check '日文内容已人工核对' 15 408 230
$productTab.Controls.Add($script:LocaleReviewed)

$productTab.Controls.Add((New-Label 'SKU' 260 408 50))
$script:Sku = New-TextBox 310 408 150
$productTab.Controls.Add($script:Sku)
$productTab.Controls.Add((New-Label '库存数' 475 408 65))
$script:Stock = New-TextBox 540 408 120
$productTab.Controls.Add($script:Stock)
$productTab.Controls.Add((New-Label '颜色' 675 408 50))
$script:Color = New-TextBox 725 408 130
$productTab.Controls.Add($script:Color)
$productTab.Controls.Add((New-Label '尺寸' 870 408 50))
$script:Size = New-TextBox 920 408 100
$productTab.Controls.Add($script:Size)
$productTab.Controls.Add((New-Label '材质' 1025 408 50))
$script:Material = New-TextBox 1075 408 85
$productTab.Controls.Add($script:Material)
$productTab.Controls.Add((New-Label '其他属性（每行：属性名=属性值）' 15 473 260))
$script:AdditionalAttributes = New-TextBox 275 473 885 56 $true
$productTab.Controls.Add($script:AdditionalAttributes)

$productTab.Controls.Add((New-Label '履约方式' 15 443 85))
$script:Fulfillment = New-Combo @('amazon_mcf', 'seller') 100 443 180
$productTab.Controls.Add($script:Fulfillment)
$productTab.Controls.Add((New-Label '备货天数' 295 443 85))
$script:ReadyDays = New-TextBox 380 443 70
$script:ReadyDays.Text = '2'
$productTab.Controls.Add($script:ReadyDays)
$productTab.Controls.Add((New-Label '追踪承运商' 465 443 100))
$script:Carrier = New-TextBox 565 443 295
$productTab.Controls.Add($script:Carrier)
$script:CarrierApproved = New-Check '已确认 TikTok 日本认可' 875 443 250
$productTab.Controls.Add($script:CarrierApproved)

Add-Button $productTab '新建商品' 15 490 110 { Clear-ProductForm } | Out-Null
Add-Button $productTab '保存商品' 135 490 110 { try { Save-CurrentProduct } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '无法保存', 'OK', 'Warning') | Out-Null } } | Out-Null
$productTab.Controls.Add((New-Label '默认规则：库存100；包裹100g、10×10×10cm；日元售价=有效采集价×2.5×CNY/JPY汇率（四舍五入）。' 15 530 1125))
Add-Button $productTab '妙手 ERP 使用说明' 15 552 200 { [System.Windows.Forms.MessageBox]::Show('妙手 ERP OpenAPI 技能已安装。首次使用请在对应技能目录按 SKILL.md 配置本地授权，再使用货源采集、公共采集箱、店铺查询、TikTok认领和编辑流程。','妙手 ERP') | Out-Null } | Out-Null
Add-Button $productTab '复制妙手 ERP 链接' 225 552 190 { Set-Clipboard -Value 'https://www.91miaoshou.com/'; $script:Status.Text = '已复制妙手 ERP 链接；请手动在助手专用 Chrome 中打开。' } | Out-Null
Add-Button $productTab '预筛商品资料' 425 552 150 {
  try { Save-CurrentProduct; Start-NodeTask @('src\preflight.mjs', '--input', $script:CandidatesPath, '--output', $script:ReadyPath) 'preflight' }
  catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '无法开始筛查', 'OK', 'Warning') | Out-Null }
} | Out-Null
$productTab.Controls.Add((New-Label '妙手 ERP：公共采集箱 → TikTok 采集箱 → 编辑并保存草稿。最终发布前请人工审核。' 15 590 1125))

$workflowText = New-Object System.Windows.Forms.Label
$workflowText.Text = [String]::Join([Environment]::NewLine, @(
  '一键流程','','1. 填写选品关键词并点击“一键启动 Codex 流程”；助手准备自己的 Chrome 空白会话，不会自动打开网站。',
  '2. 请在该专用 Chrome 中手动登录、启用妙手插件，并打开 Amazon 商品页和妙手 ERP 页面；随后回助手点“继续运行”。资料保存在 E:\TikTok商品上架助手\runtime\browser-profile。',
  '2. 助手随后自动初筛、认领、编辑并保存商品资料。',
  '3. 资料保存到 E:\商品资料；图片存入 E:\商品资料\商品图片\ASIN。Codex 复核类目、日文内容、品牌和图片。',
  '4. Codex 复核完成后，点“复核后提交到 TikTok”，再确认提交。妙手发布任务异步处理。','',
  '目标店铺：ひよりセレクト（JP，20056043）。库存100；包裹100g、10×10×10cm；售价=人民币采集价×2.5×运行时 CNY/JPY 汇率。',
  '化妆品、食品、医药类和识别到的一线品牌会自动拦截。类目、翻译、价格依据或资料不足时交给 Codex。'
))
$workflowText.Location = New-Object System.Drawing.Point(25,25)
$workflowText.Size = New-Object System.Drawing.Size(1110,480)
$workflowText.Font = New-Object System.Drawing.Font('Microsoft YaHei UI',11)
$settingsTab.Controls.Add($workflowText)
Add-Button $settingsTab '复制妙手 ERP 链接' 25 525 190 { Set-Clipboard -Value 'https://www.91miaoshou.com/'; $script:Status.Text = '已复制妙手 ERP 链接；请手动在助手专用 Chrome 中打开。' } | Out-Null
$settingsTab.Controls.Add((New-Label '使用前按妙手技能 SKILL.md 设置本地 API 授权。商品先保存草稿，由你核对后再发布。' 25 570 900))
$script:Status = New-Label '助手已就绪。输入选品关键词后点击“一键启动”。' 24 884 970
$script:Status.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
$script:Form.Controls.Add($script:Status)
$script:ContinueButton = New-Object System.Windows.Forms.Button
$script:ContinueButton.Text = '继续妙手 ERP 操作'
$script:ContinueButton.Location = New-Object System.Drawing.Point(1080, 880)
$script:ContinueButton.Size = New-Object System.Drawing.Size(245, 36)
$script:ContinueButton.Enabled = $false
$script:ContinueButton.Visible = $false
$script:ContinueButton.Add_Click({
  if ($script:Task -and -not $script:Task.HasExited) {
    $script:Task.StandardInput.WriteLine('')
    $script:ContinueButton.Enabled = $false
    $script:Status.Text = '继续填写商品…'
  }
})
$script:Form.Controls.Add($script:ContinueButton)
$script:LogBox = New-Object System.Windows.Forms.RichTextBox
$script:LogBox.Location = New-Object System.Drawing.Point(24, 920)
$script:LogBox.Size = New-Object System.Drawing.Size(1300, 34)
$script:LogBox.ReadOnly = $true
$script:LogBox.Anchor = 'Bottom,Left,Right'
$script:Form.Controls.Add($script:LogBox)

$script:Grid.Add_SelectionChanged({
  if ($script:Grid.SelectedRows.Count -gt 0) {
    $index = [int]$script:Grid.SelectedRows[0].Tag
    if ($index -ge 0 -and $index -lt $script:Candidates.Count) { Set-FormFromCandidate $script:Candidates[$index] $index }
  }
})

function Apply-Theme($control) {
  if ($control -is [System.Windows.Forms.TabControl]) {
    $control.BackColor = $script:Palette.Background
    $control.ForeColor = $script:Palette.Text
  } elseif ($control -is [System.Windows.Forms.TabPage]) {
    $control.UseVisualStyleBackColor = $false
    $control.BackColor = $script:Palette.Background
    $control.ForeColor = $script:Palette.Text
  } elseif ($control -is [System.Windows.Forms.Panel]) {
    if ($control.BackColor -eq [System.Drawing.SystemColors]::Control) { $control.BackColor = $script:Palette.Surface }
  } elseif ($control -is [System.Windows.Forms.Label]) {
    if ($control.ForeColor -eq [System.Drawing.SystemColors]::ControlText) { $control.ForeColor = $script:Palette.Text }
    $control.BackColor = [System.Drawing.Color]::Transparent
  } elseif ($control -is [System.Windows.Forms.TextBox]) {
    $control.BackColor = $script:Palette.Input
    $control.ForeColor = $script:Palette.Text
    $control.BorderStyle = 'FixedSingle'
  } elseif ($control -is [System.Windows.Forms.RichTextBox]) {
    $control.BackColor = $script:Palette.Input
    $control.ForeColor = $script:Palette.Text
    $control.BorderStyle = 'None'
  } elseif ($control -is [System.Windows.Forms.ComboBox]) {
    $control.BackColor = $script:Palette.Input
    $control.ForeColor = $script:Palette.Text
    $control.FlatStyle = 'Flat'
  } elseif ($control -is [System.Windows.Forms.CheckBox]) {
    $control.BackColor = $script:Palette.Background
    $control.ForeColor = $script:Palette.Text
  } elseif ($control -is [System.Windows.Forms.Button]) {
    $control.FlatStyle = 'Flat'
    $control.UseVisualStyleBackColor = $false
    $control.FlatAppearance.BorderColor = $script:Palette.Border
    $control.FlatAppearance.MouseOverBackColor = $script:Palette.Raised
    $control.Add_EnabledChanged({ param($sender, $eventArgs) Set-ButtonTheme $sender })
    $control.Add_Paint({
      param($sender, $eventArgs)
      if (-not $sender.Enabled) {
        $flags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis
        [System.Windows.Forms.TextRenderer]::DrawText($eventArgs.Graphics, $sender.Text, $sender.Font, $sender.ClientRectangle, $script:Palette.Muted, $flags)
      }
    })
    Set-ButtonTheme $control
  } elseif ($control -is [System.Windows.Forms.DataGridView]) {
    $control.BackgroundColor = $script:Palette.Background
    $control.GridColor = $script:Palette.Border
    $control.BorderStyle = 'None'
    $control.EnableHeadersVisualStyles = $false
    $control.ColumnHeadersDefaultCellStyle.BackColor = $script:Palette.Raised
    $control.ColumnHeadersDefaultCellStyle.ForeColor = $script:Palette.Text
    $control.ColumnHeadersDefaultCellStyle.SelectionBackColor = $script:Palette.Raised
    $control.DefaultCellStyle.BackColor = $script:Palette.Surface
    $control.DefaultCellStyle.ForeColor = $script:Palette.Text
    $control.DefaultCellStyle.SelectionBackColor = $script:Palette.GoldDim
    $control.DefaultCellStyle.SelectionForeColor = $script:Palette.Text
    $control.AlternatingRowsDefaultCellStyle.BackColor = $script:Palette.Raised
    $control.RowHeadersDefaultCellStyle.BackColor = $script:Palette.Raised
    $control.RowHeadersDefaultCellStyle.ForeColor = $script:Palette.Muted
  }
  foreach ($child in $control.Controls) { Apply-Theme $child }
}

function Set-ButtonTheme($button) {
  $button.UseVisualStyleBackColor = $false
  if (-not $button.Enabled) {
    $button.BackColor = $script:Palette.Raised
    $button.ForeColor = $script:Palette.Muted
    $button.FlatAppearance.BorderColor = $script:Palette.Border
  } elseif ($button.Text -eq '一键启动 Codex 流程') {
    $button.BackColor = $script:Palette.Gold
    $button.ForeColor = $script:Palette.Background
    $button.FlatAppearance.BorderColor = $script:Palette.Gold
  } elseif ($button.Text -eq '提交到 TikTok') {
    $button.BackColor = $script:Palette.Green
    $button.ForeColor = $script:Palette.Background
    $button.FlatAppearance.BorderColor = $script:Palette.Green
  } else {
    $button.BackColor = $script:Palette.Raised
    $button.ForeColor = $script:Palette.Text
    $button.FlatAppearance.BorderColor = $script:Palette.Border
  }
}

Add-Type -Namespace NativeUi -Name Windowing -MemberDefinition '[System.Runtime.InteropServices.DllImport("uxtheme.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)] public static extern int SetWindowTheme(System.IntPtr hWnd, string appName, string idList); [System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow(); [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int command); [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr hWnd);'

$tabs.Anchor = 'Top,Bottom,Left,Right'
$script:Status.Anchor = 'Bottom,Left'
$script:ContinueButton.Anchor = 'Bottom,Right'
$script:LogBox.Anchor = 'Bottom,Left,Right'
$tabStripFill = New-Object System.Windows.Forms.Panel
$tabStripFill.Location = New-Object System.Drawing.Point(438, 83)
$tabStripFill.Size = New-Object System.Drawing.Size(892, 36)
$tabStripFill.BackColor = $script:Palette.Background
$tabStripFill.Anchor = 'Top,Left,Right'
$script:Form.Controls.Add($tabStripFill)
$tabStripFill.BringToFront()
[void](Apply-Theme $script:Form)
$script:Form.Add_FormClosing({
  if ($script:Task -and -not $script:Task.HasExited) {
    $answer = [System.Windows.Forms.MessageBox]::Show('任务仍在运行。关闭窗口会中断当前商品操作，确定关闭吗？', '任务运行中', 'YesNo', 'Warning')
    if ($answer -ne 'Yes') { $_.Cancel = $true }
  }
})

Refresh-Grid
try { Refresh-SourceWatchGrid } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '来源复核列表', 'OK', 'Warning') | Out-Null }
if ($script:Candidates.Count -eq 0) { Clear-ProductForm }
$script:Form.Add_Shown({
  [void][NativeUi.Windowing]::SetWindowTheme($tabs.Handle, '', '')
  $tabs.Invalidate()
  $console = [NativeUi.Windowing]::GetConsoleWindow()
  if ($console -ne [IntPtr]::Zero) { [void][NativeUi.Windowing]::ShowWindow($console, 0) }
  [void][NativeUi.Windowing]::ShowWindow($script:Form.Handle, 5)
  [void][NativeUi.Windowing]::SetForegroundWindow($script:Form.Handle)
})
[void]$script:Form.ShowDialog()
