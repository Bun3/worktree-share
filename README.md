# worktree-share

여러 리포에서 **git worktree 를 만들 때 무거운 캐시·자산을 심링크(junction)로 공유**해
워크트리 디스크 낭비를 없애고 에디터/빌드 진입을 빠르게 하는 **범용 엔진**.

프레임워크에 종속되지 않는다. **무엇을 어떻게 공유할지는 각 리포 루트의
`.worktree-share.json` 이 선언**하고, 엔진은 그 경로만 참조해 적용한다. Unity 전용이 아니다
(node_modules, .venv, 빌드 캐시 등 무엇이든 가능).

## 구성

```
worktree-share/                 (이 레포 = 엔진, 한 벌만 유지)
  share-worktree.ps1            핵심 엔진: 설정 기반 공유 + -Detach 해제
  orca-setup.cmd                Orca "setup" 훅 래퍼 (ORCA_WORKTREE_PATH 사용)
  orca-archive.cmd              Orca "archive" 훅 래퍼 (-Detach)
  remove-worktree.ps1           junction 안전 해제 후 워크트리 제거
  examples/worktree-share.template.json
각 리포:
  <repo>/.worktree-share.json   그 리포의 공유 규칙 (커밋해서 팀 공유)
```

## 설치 (한 번)

이 레포를 **고정 경로**에 한 번만 클론한다. 그 경로를 이 문서에서 `<engine-dir>` 로 표기한다
(팀/PC마다 자유, 예: `~/tools/worktree-share` 또는 원하는 위치).
```
git clone <this-repo-url> <engine-dir>
```
이후 업데이트는 `git -C <engine-dir> pull` 한 번. 모든 리포가 같은 엔진을 쓴다.

> 아래 예시의 `<engine-dir>` 는 클론한 실제 경로로 바꿔서 쓴다. Orca 훅 등에 넣을 땐
> 그 경로가 안 바뀌도록 안정적인 위치를 고르는 게 좋다.

## 리포에 적용

1. `examples/worktree-share.template.json` 을 리포 루트에 `.worktree-share.json` 으로 복사해 수정하고 커밋.
2. 워크트리 만들 때 엔진을 호출 (아래 셋 중 하나).

### A) Orca 훅 (자동)

Orca → Settings → Repository hooks 에 (모든 리포 동일 명령):
- **Setup**  : `<engine-dir>\orca-setup.cmd`
- **Archive**: `<engine-dir>\orca-archive.cmd`

엔진이 `ORCA_WORKTREE_PATH` 로 대상 워크트리를, `git worktree list` 로 원본 리포를,
`<repo>/.worktree-share.json` 으로 규칙을 자동 인식한다. **리포마다 설정 바꿀 필요 없음.**

> ⚠ Orca 의 **"Wait for setup to complete before starting agent" 는 끄세요.** 켜면 Orca 가
> cmd 전용 시퀀싱 래퍼를 만드는데 셸이 cmd 가 아니면 깨진다. 끄면 setup(공유)은 그대로 돌고
> 에이전트는 정상 실행된다.

### B) 수동 (CLI)

```powershell
# 워크트리 하나에 공유 적용 (원본/설정 자동 감지)
powershell -File <engine-dir>\share-worktree.ps1 -Worktree <워크트리경로>

# optional 항목(무거운 자산 등)까지
... share-worktree.ps1 -Worktree <경로> -IncludeOptional

# 제거 (junction 안전 해제 후)
powershell -File <engine-dir>\remove-worktree.ps1 -Worktree <경로> -DeleteBranch
```

## `.worktree-share.json` 스키마

```jsonc
{
  "shares": [
    // 캐시 폴더: 자식 dir는 junction, 파일+lock DB는 복사(워크트리별 독립)
    { "path": "unity/Library", "mode": "cache",
      "copy": ["ArtifactDB","SourceAssetDB", "..."] },   // 생략 시 Unity 기본 lock 목록

    // base 아래 지정 폴더들만 각각 junction
    { "path": "unity/Assets", "mode": "link-children",
      "children": ["Plugins","Firebase"], "optional": true },

    { "path": "unity/Packages", "mode": "link" },         // 폴더 통째로 junction
    { "path": "server/artifacts", "mode": "copy" }        // 폴더 통째로 독립 복사
  ]
}
```

| mode | 동작 |
|------|------|
| `link` | `path` 폴더 통째로 junction (main → worktree) |
| `copy` | `path` 폴더 통째로 독립 복사 |
| `cache` | `path` 하위: 자식 dir는 junction, 파일 + `copy` 목록은 복사 |
| `link-children` | `path`(base) 하위의 `children` 각각을 junction |

- `optional: true` — `-IncludeOptional` 을 줬을 때만 적용 (무거운/ git 추적 자산 등).
- 경로는 리포 루트 기준 상대경로. 원본이 없으면 조용히 건너뜀.

## ⚠ 제거 함정 (Windows junction)

junction 이 걸린 워크트리를 `git worktree remove` / `rm -rf` / `git clean -fdx` 로 그냥 지우면
링크를 따라가 **원본까지 삭제**될 수 있다. 반드시 `remove-worktree.ps1`(또는 archive 훅 =
`-Detach`)로 링크를 먼저 끊고 제거할 것.

## 예시 설정

`examples/` 의 템플릿을 참고해 각 리포 루트에 `.worktree-share.json` 을 둔다. 리포마다
Unity 폴더명(`Client/`, `unity/`, `src/` …)이나 공유할 폴더가 달라도, 그 차이는 전부 이
설정 파일이 흡수하므로 **엔진은 손대지 않는다**.

- **Unity 프로젝트**: `<unity-dir>/Library` 를 `cache` 모드로 (Library 캐시 공유가 핵심).
  무거운 서드파티 에셋 폴더는 `link-children` + `optional:true` 로.
- **일반 프로젝트**: `node_modules`, `.venv`, 빌드 산출물 캐시 등을 `link`/`copy` 로.
