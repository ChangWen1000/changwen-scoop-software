param(
    [string]$BucketDir = (Join-Path $PSScriptRoot 'bucket')
)

# ---------- 0. 准备 ----------

# 找到 scoop 的 checkver.ps1
$checkver = Join-Path (scoop prefix scoop) 'bin\checkver.ps1'
if (-not (Test-Path $checkver)) {
    Write-Error "找不到 checkver.ps1：$checkver"
    exit 1
}

if (-not (Test-Path $BucketDir)) {
    Write-Error "Bucket 目录不存在：$BucketDir"
    exit 1
}

# 读取所有 manifest
$manifests = Get-ChildItem $BucketDir -Filter '*.json'
if (-not $manifests) {
    Write-Host "bucket 目录下没有 json 文件。" -ForegroundColor Yellow
    exit 0
}

# ---------- 1. 读取本地版本 ----------

$apps = @()

foreach ($m in $manifests) {
    $name = [IO.Path]::GetFileNameWithoutExtension($m.Name)
    try {
        $json = Get-Content $m.FullName -Raw | ConvertFrom-Json
        $localVersion = $json.version
    } catch {
        Write-Warning "读取 $($m.Name) 出错，跳过：$_"
        continue
    }

    $apps += [PSCustomObject]@{
        Name          = $name
        LocalVersion  = $localVersion
        ManifestPath  = $m.FullName
        RelPath       = "bucket/$name.json"
    }
}

if (-not $apps) {
    Write-Host "没有有效的 manifest。" -ForegroundColor Yellow
    exit 0
}

# ---------- 2. 用 checkver 检查远端版本 ----------

Write-Host "正在检查远端版本（checkver）..." -ForegroundColor Cyan
$cvOutput = & $checkver -App * -Dir $BucketDir 2>&1

# 解析输出：形如 "ani: 5.2.0 ..."
$remoteMap = @{}

foreach ($line in $cvOutput) {
    if ($line -match '^(?<name>[^:]+):\s+(?<ver>\S+)') {
        $n = $matches['name'].Trim()
        $v = $matches['ver'].Trim()
        $remoteMap[$n] = $v
    }
}

foreach ($a in $apps) {
    if ($remoteMap.ContainsKey($a.Name)) {
        $a | Add-Member -NotePropertyName RemoteVersion -NotePropertyValue $remoteMap[$a.Name]
    } else {
        $a | Add-Member -NotePropertyName RemoteVersion -NotePropertyValue $null
    }

    $a | Add-Member -NotePropertyName Outdated -NotePropertyValue (
        $a.RemoteVersion -and ($a.RemoteVersion -ne $a.LocalVersion)
    )
}

$outdated = $apps | Where-Object { $_.Outdated }

if (-not $outdated) {
    Write-Host "所有 manifest 已是最新版本 ✅" -ForegroundColor Green
    exit 0
}

Write-Host ""
Write-Host "发现有新版本的软件：" -ForegroundColor Yellow
$outdated |
    Select-Object @{n='Name';e={$_.Name}},
                  @{n='Installed';e={$_.LocalVersion}},
                  @{n='Latest';e={$_.RemoteVersion}} |
    Format-Table -AutoSize

# ---------- 3. 问是否更新 manifest（只支持 y / n） ----------

Write-Host ""
$answer = Read-Host "是否更新上面这些软件的 manifest？(y/n)"

if ($answer -ne 'y') {
    Write-Host "用户选择不更新 manifest。" -ForegroundColor Yellow
    exit 0
}

$appsToUpdate = $outdated.Name

# ---------- 4. 对这些软件执行 checkver -Update ----------

Write-Host ""
foreach ($name in $appsToUpdate) {
    Write-Host "正在自动更新 manifest：$name ..." -ForegroundColor Cyan
    & $checkver -App $name -Dir $BucketDir -Update
}

# ---------- 5. 显示 git diff ----------

Set-Location $PSScriptRoot

Write-Host ""
Write-Host "下面是每个 manifest 的 git diff：" -ForegroundColor Yellow

$updatedApps = @()

foreach ($name in $appsToUpdate) {
    $relPath = "bucket/$name.json"
    Write-Host "`n==== git diff $relPath ====" -ForegroundColor Yellow
    $diff = git diff $relPath
    if ($diff) {
        $updatedApps += $name
        $diff | Out-Host
    } else {
        Write-Host "(没有变化，可能 autoupdate 没修改任何字段)" -ForegroundColor DarkYellow
    }
}

if (-not $updatedApps) {
    Write-Host "`n没有实际变更，不需要提交。" -ForegroundColor Yellow
    exit 0
}

# ---------- 6. 是否 git add / commit / push ----------

Write-Host ""
$confirm = Read-Host "是否 git add + commit + push 这些更新？(y/n)"

if ($confirm -ne 'y') {
    Write-Host "已保留本地修改，但未提交/推送。" -ForegroundColor Yellow
    exit 0
}

$paths = $updatedApps | ForEach-Object { "bucket/$_.json" }

Write-Host "`ngit add $($paths -join ' ')" -ForegroundColor Cyan
git add $paths

$commitMessage = "Auto update " + ($updatedApps -join '/')
Write-Host "git commit -m `"$commitMessage`"" -ForegroundColor Cyan
git commit -m $commitMessage

Write-Host "git push" -ForegroundColor Cyan
git push

Write-Host "`n全部完成 ✅" -ForegroundColor Green