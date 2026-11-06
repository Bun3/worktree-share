<#
.SYNOPSIS
    설정(.worktree-share.json) 기반으로 워크트리에 경로를 공유(junction)/복사한다. (범용, 프레임워크 무관)

.DESCRIPTION
    엔진은 어떤 레포에도 종속되지 않는다. 각 레포 루트의 .worktree-share.json 이
    "무엇을 어떻게 공유할지"를 선언하고, 엔진은 그 경로만 참조해 적용한다.

    소스(main)는 대상 워크트리에서 `git worktree list` 첫 항목(메인 작업트리)으로 자동 감지한다.
    설정 파일도 그 main 루트에서 읽는다.

    == .worktree-share.json 스키마 ==
    {
      "shares": [
        { "path": "unity/Library", "mode": "cache" },              // 캐시: 자식 dir는 junction, 파일+lock은 복사
        { "path": "unity/Library", "mode": "cache",
          "copy": ["ArtifactDB","SourceAssetDB", ...],              // copy 생략 시 Unity 기본 lock 목록 사용
          "exclude": ["Bee"] },                                      // 공유하지 않음. 생략 시 ["Bee"], [] 면 제외 없음
        { "path": "unity/Packages", "mode": "link" },              // 통째로 junction
        { "path": "server/artifacts", "mode": "copy" },            // 통째로 복사(독립)
        { "path": "unity/Assets", "mode": "link-children",         // base 아래 children 각각 junction
          "children": ["Plugins","Firebase", ...], "optional": true }
      ]
    }
    - mode: link | copy | cache | link-children
    - optional:true 인 항목은 -IncludeOptional 을 줬을 때만 적용(무거운/git추적 자산 등)

.PARAMETER Worktree     적용 대상 워크트리. 미지정 시 $env:ORCA_WORKTREE_PATH -> 현재 디렉터리.
.PARAMETER MainRepo     공유 원본. 미지정 시 자동 감지.
.PARAMETER Config       설정 파일 경로. 미지정 시 <MainRepo>/.worktree-share.json.
.PARAMETER IncludeOptional  optional:true 항목까지 적용.
.PARAMETER Detach       공유 해제(teardown): 워크트리 내 junction/symlink 을 링크만 안전 제거.
#>
[CmdletBinding()]
param(
    [string] $Worktree,
    [string] $MainRepo,
    [string] $Config,
    [switch] $IncludeOptional,
    [switch] $Detach
)

$ErrorActionPreference = 'Stop'

# cache 모드에서 copy 미지정 시 쓰는 기본 목록 (Unity 표준 — 에디터가 배타 Lock 걸거나 워크트리별로 달라야 함)
$DefaultCacheCopy = @(
    'ArtifactDB', 'ArtifactDB-lock', 'SourceAssetDB', 'SourceAssetDB-lock',
    'Artifacts', 'TempArtifacts', 'ScriptAssemblies', 'StateCache',
    'ShaderCache.db', 'BuildPlayer.prefs', 'ilpp.pid'
)
# cache 모드에서 exclude 미지정 시 공유하지 않는 목록 (Bee dag 는 프로젝트 절대경로를 기록 → junction 하면 워크트리 삭제 후 main 컴파일 실패)
$DefaultCacheExclude = @('Bee')
$DefaultConfigName = '.worktree-share.json'

# ─── 헬퍼 ────────────────────────────────────────────────────
function Test-ReparsePoint([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    return [bool]((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)
}
function Remove-PathSafe([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (Test-ReparsePoint $Path) { [IO.Directory]::Delete($Path, $false) }   # 링크만 제거(원본 보존)
    else { Remove-Item -LiteralPath $Path -Recurse -Force }
}
function New-DirJunction([string] $Link, [string] $Target) {
    Remove-PathSafe $Link
    $parent = Split-Path -Parent $Link
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    New-Item -ItemType Junction -Path $Link -Target $Target | Out-Null
}
function Copy-PathInto([string] $Src, [string] $Dst) {
    $parent = Split-Path -Parent $Dst
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    if (-not (Test-Path -LiteralPath $Src -PathType Container)) {
        Remove-PathSafe $Dst
        Copy-Item -LiteralPath $Src -Destination $Dst -Force
        return
    }
    # 링크는 먼저 끊는다 — 남겨두면 /MIR 이 링크 너머 원본을 덮어쓴다
    if ((Test-ReparsePoint $Dst) -or (Test-Path -LiteralPath $Dst -PathType Leaf)) { Remove-PathSafe $Dst }
    # robocopy: 260자 넘는 경로(PackageCache 등)도 복사, /MIR 로 재실행 시 동기화, /XJ 로 원본 내 링크는 따라가지 않음
    & robocopy $Src $Dst /MIR /XJ /COPY:DAT /DCOPY:DAT /R:1 /W:1 /MT:16 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy 실패(exit $LASTEXITCODE): $Src -> $Dst" }
}
function Invoke-GitCapture {
    param([Parameter(ValueFromRemainingArguments)] [string[]] $GitArgs)
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { return (& git @GitArgs 2>$null) } finally { $ErrorActionPreference = $prev }
}

# ─── 대상 워크트리 결정 ──────────────────────────────────────
if (-not $Worktree) { $Worktree = if ($env:ORCA_WORKTREE_PATH) { $env:ORCA_WORKTREE_PATH } else { (Get-Location).Path } }
if (-not (Test-Path -LiteralPath $Worktree)) { throw "워크트리 경로 없음: $Worktree" }
$Worktree = (Resolve-Path -LiteralPath $Worktree).Path

# ─── Detach 모드 ─────────────────────────────────────────────
if ($Detach) {
    $reparse = Get-ChildItem -LiteralPath $Worktree -Recurse -Force -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
        Sort-Object { $_.FullName.Length } -Descending
    foreach ($rp in $reparse) {
        [IO.Directory]::Delete($rp.FullName, $false)
        Write-Host "✂  해제: $($rp.FullName)" -ForegroundColor DarkCyan
    }
    Write-Host "✅ 공유 해제 완료: $Worktree" -ForegroundColor Green
    return
}

# ─── 메인 저장소(공유 원본) 결정 ─────────────────────────────
if (-not $MainRepo) {
    $porcelain = Invoke-GitCapture -C $Worktree worktree list --porcelain
    $first = $porcelain | Where-Object { $_ -like 'worktree *' } | Select-Object -First 1
    if (-not $first) { throw 'git worktree 정보를 읽지 못했습니다.' }
    $MainRepo = ($first -replace '^worktree ', '').Trim()
}
$MainRepo = (Resolve-Path -LiteralPath $MainRepo).Path
if ($MainRepo -eq $Worktree) {
    Write-Host "ℹ  메인 작업트리에서는 공유를 적용하지 않습니다: $Worktree" -ForegroundColor Yellow
    return
}

# ─── 설정 로드 ───────────────────────────────────────────────
if (-not $Config) { $Config = Join-Path $MainRepo $DefaultConfigName }
if (-not (Test-Path -LiteralPath $Config)) {
    Write-Host "ℹ  설정 파일 없음: $Config — 공유할 항목이 없습니다." -ForegroundColor DarkGray
    return
}
$cfg = Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $cfg.shares) { Write-Host "ℹ  설정에 shares 항목이 없습니다: $Config" -ForegroundColor DarkGray; return }

# ─── 적용 ────────────────────────────────────────────────────
$linked = 0; $copied = 0; $skipped = 0
foreach ($s in $cfg.shares) {
    if ($s.optional -and -not $IncludeOptional) { continue }
    $mode = if ($s.mode) { [string]$s.mode } else { 'link' }
    $src  = Join-Path $MainRepo $s.path
    $dst  = Join-Path $Worktree $s.path

    if ($mode -ne 'link-children' -and -not (Test-Path -LiteralPath $src)) {
        Write-Host "·  건너뜀(원본 없음): $($s.path)" -ForegroundColor DarkGray; $skipped++; continue
    }

    switch ($mode) {
        'link' {
            New-DirJunction $dst $src; $linked++
            Write-Host "🔗 link  $($s.path)" -ForegroundColor Cyan
        }
        'copy' {
            Copy-PathInto $src $dst; $copied++
            Write-Host "📄 copy  $($s.path)" -ForegroundColor DarkYellow
        }
        'cache' {
            $copyNames = if ($s.copy) { @($s.copy) } else { $DefaultCacheCopy }
            New-Item -ItemType Directory -Force -Path $dst | Out-Null
            $l = 0; $c = 0
            $excludeNames = if ($null -ne $s.exclude) { @($s.exclude) } else { $DefaultCacheExclude }
            Get-ChildItem -LiteralPath $src -Force | Where-Object { $excludeNames -notcontains $_.Name } | ForEach-Object {
                $childDst = Join-Path $dst $_.Name
                if (($copyNames -contains $_.Name) -or (-not $_.PSIsContainer)) {
                    # 기존 대상을 지우고 복사 — 중단 후 재실행해도 dir 안에 중첩 복사되지 않는다
                    Write-Host "   📄 $($_.Name)" -ForegroundColor DarkGray
                    Copy-PathInto $_.FullName $childDst; $c++
                } else {
                    Write-Host "   🔗 $($_.Name)" -ForegroundColor DarkGray
                    New-DirJunction $childDst $_.FullName; $l++
                }
            }
            $linked += $l; $copied += $c
            Write-Host "🔗 cache $($s.path)  (junction ${l}개 / 복사 ${c}개)" -ForegroundColor Cyan
        }
        'link-children' {
            foreach ($name in @($s.children)) {
                $cSrc = Join-Path $src $name
                if (Test-Path -LiteralPath $cSrc) {
                    New-DirJunction (Join-Path $dst $name) $cSrc; $linked++
                    Write-Host "🔗 link  $($s.path)/$name" -ForegroundColor Cyan
                } else { $skipped++ }
            }
        }
        default { Write-Host "⚠  알 수 없는 mode '$mode' (path: $($s.path))" -ForegroundColor Yellow }
    }
}

Write-Host ""
Write-Host "✅ 공유 완료: $Worktree" -ForegroundColor Green
Write-Host "   원본: $MainRepo  |  설정: $(Split-Path -Leaf $Config)  |  junction ${linked} / 복사 ${copied} / 건너뜀 ${skipped}" -ForegroundColor Green
