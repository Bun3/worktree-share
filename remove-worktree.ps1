<#
.SYNOPSIS
    junction 을 안전하게 해제한 뒤 워크트리를 제거한다. (범용)
.DESCRIPTION
    junction 이 걸린 워크트리를 `git worktree remove`/`rm`/`git clean -fdx` 로 그냥 지우면
    링크를 따라가 원본까지 삭제될 수 있다. 이 스크립트는 링크만 먼저 끊고 제거한다.
.EXAMPLE
    ./remove-worktree.ps1 -Worktree ..\worktrees\agent-0 -DeleteBranch
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Worktree,
    [switch] $DeleteBranch
)
$ErrorActionPreference = 'Stop'

function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments)] [string[]] $GitArgs)
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $out = & git @GitArgs 2>&1
        if ($out) { $out | ForEach-Object { Write-Host $_ } }
        if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') 실패 (exit $LASTEXITCODE)" }
    } finally { $ErrorActionPreference = $prev }
}

if (-not (Test-Path -LiteralPath $Worktree)) { Write-Host "ℹ  워크트리 없음: $Worktree" -ForegroundColor DarkGray; return }
$Worktree = (Resolve-Path -LiteralPath $Worktree).Path

# cwd 에 의존하지 않도록, 소유 저장소(메인 작업트리)를 워크트리에서 유도한다.
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
$branch  = (& git -C $Worktree rev-parse --abbrev-ref HEAD 2>$null)
$porc    = (& git -C $Worktree worktree list --porcelain 2>$null)
$ErrorActionPreference = $prev
$mainLine = $porc | Where-Object { $_ -like 'worktree *' } | Select-Object -First 1
$MainRepo = if ($mainLine) { ($mainLine -replace '^worktree ', '').Trim() } else { $Worktree }

# 1. junction/symlink 안전 해제 (share-worktree.ps1 재사용)
& (Join-Path $PSScriptRoot 'share-worktree.ps1') -Worktree $Worktree -Detach

# 2. 워크트리 제거 (소유 저장소 컨텍스트에서)
Invoke-Git -C $MainRepo worktree remove --force $Worktree
Write-Host "✅ 워크트리 제거: $Worktree" -ForegroundColor Green

# 3. (옵션) 브랜치 삭제
if ($DeleteBranch -and $branch -and $branch -ne 'HEAD') {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & git -C $MainRepo branch -D $branch 2>$null; $ok = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prev
    if ($ok) { Write-Host "🗑  브랜치 삭제: $branch" -ForegroundColor Green }
}
Invoke-Git -C $MainRepo worktree prune
