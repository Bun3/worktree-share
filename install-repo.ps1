<#
.SYNOPSIS
    레포에 Orca 워크트리 훅(orca.yaml)을 설치한다. 엔진이 템플릿을 소유하므로
    레포마다 손으로 복사할 필요가 없다.

.DESCRIPTION
    - <repo>/orca.yaml 을 생성/갱신한다. 훅은 환경변수 WORKTREE_SHARE_HOME 으로 엔진을 찾는다.
      커밋되는 파일에 개인 PC 경로를 굽지 않기 위해서다. 변수가 없는 PC는 조용히 건너뛴다.
    - <repo>/.worktree-share.json 이 없으면 예시를 복사해 둔다(내용은 레포에 맞게 직접 수정).
    - 둘 다 커밋 대상이다. 커밋은 하지 않는다.

.PARAMETER Repo      대상 레포 경로(여러 개 가능). 생략 시 현재 디렉터리.
.PARAMETER Example   .worktree-share.json 이 없을 때 복사할 예시. 기본 unity.
.PARAMETER Force     기존 orca.yaml 을 덮어쓴다.
#>
[CmdletBinding()]
param(
    [string[]]$Repo = @('.'),
    [ValidateSet('unity', 'template')] [string]$Example = 'unity',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$engine = $PSScriptRoot

$yaml = @'
# Orca 워크트리 훅 — worktree-share 엔진으로 무거운 캐시를 junction 공유한다.
# 이 파일은 <engine>/install-repo.ps1 이 생성했다. 엔진을 갱신했으면 다시 실행하면 된다.
# - 공유 규칙: 레포 루트의 .worktree-share.json (엔진이 자동으로 읽음)
# - 엔진 위치는 PC마다 환경변수 WORKTREE_SHARE_HOME 으로 지정한다(이 파일에 개인 경로를 남기지 않는다).
#   예: setx WORKTREE_SHARE_HOME "E:\Projects\worktree-share" 후 Orca 재시작
# - 변수가 없는 PC에서는 조용히 건너뛴다(워크트리는 정상 생성, 캐시만 새로 만들어짐).
# - archive 훅은 junction 을 먼저 끊어 원본 삭제 사고를 막는다.
# - Orca 는 각 줄을 "call <줄>" 로 감싼 runner 로 실행하는데 "call if ..." 는 실패한다.
#   그래서 줄마다 cmd /d /c 로 감싸고, 줄 사이에 변수를 넘기지 않도록 한 줄로 쓴다.
scripts:
  setup: |
    cmd /d /c if defined WORKTREE_SHARE_HOME (call "%WORKTREE_SHARE_HOME%\orca-setup.cmd") else (echo [worktree-share] WORKTREE_SHARE_HOME not set - skipped)
  archive: |
    cmd /d /c if defined WORKTREE_SHARE_HOME (call "%WORKTREE_SHARE_HOME%\orca-archive.cmd") else (echo [worktree-share] WORKTREE_SHARE_HOME not set - skipped)

'@

foreach ($r in $Repo) {
    $root = (Resolve-Path -LiteralPath $r).Path
    if (-not (Test-Path -LiteralPath (Join-Path $root '.git'))) {
        Write-Host "!  건너뜀 (git 레포 아님): $root" -ForegroundColor Yellow
        continue
    }

    $yamlPath = Join-Path $root 'orca.yaml'
    if ((Test-Path -LiteralPath $yamlPath) -and -not $Force) {
        $existing = Get-Content -LiteralPath $yamlPath -Raw
        if ($existing -notmatch 'worktree-share') {
            Write-Host "!  orca.yaml 이 이미 있고 worktree-share 훅이 아님 — 건너뜀: $yamlPath" -ForegroundColor Yellow
            Write-Host "   (덮어쓰려면 -Force, 아니면 scripts 블록을 직접 병합할 것)"
            continue
        }
    }
    # PS 5.1 의 -Encoding utf8 은 BOM 을 붙인다. YAML 파서가 걸릴 수 있어 BOM 없이 쓴다.
    [System.IO.File]::WriteAllText($yamlPath, $yaml, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "OK orca.yaml  $yamlPath" -ForegroundColor Green

    $cfgPath = Join-Path $root '.worktree-share.json'
    if (Test-Path -LiteralPath $cfgPath) {
        Write-Host "   .worktree-share.json 이미 있음 (유지)"
    } else {
        $src = Join-Path $engine "examples\$Example.worktree-share.json"
        if ($Example -eq 'template') { $src = Join-Path $engine 'examples\worktree-share.template.json' }
        Copy-Item -LiteralPath $src -Destination $cfgPath
        Write-Host "   .worktree-share.json 예시 복사됨 — 레포에 맞게 수정할 것" -ForegroundColor Cyan
    }
}
