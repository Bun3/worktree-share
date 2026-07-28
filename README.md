# worktree-share

여러 레포에서 **git worktree 를 만들 때 무거운 캐시·자산을 심링크(junction)로 공유**해
워크트리 디스크 낭비를 없애고 에디터/빌드 진입을 빠르게 하는 **범용 엔진**.

프레임워크에 종속되지 않는다. **무엇을 어떻게 공유할지는 각 레포 루트의
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
  examples/unity.worktree-share.json
각 레포:
  <repo>/.worktree-share.json   그 레포의 공유 규칙 (커밋해서 팀 공유)
```

## 설치 (한 번)

이 레포를 **고정 경로**에 한 번만 클론한다. 그 경로를 이 문서에서 `<engine-dir>` 로 표기한다
(팀/PC마다 자유, 예: `~/tools/worktree-share` 또는 원하는 위치).
```
git clone <this-repo-url> <engine-dir>
```
이후 업데이트는 `git -C <engine-dir> pull` 한 번. 모든 레포가 같은 엔진을 쓴다.

> 아래 예시의 `<engine-dir>` 는 클론한 실제 경로로 바꿔서 쓴다. Orca 훅 등에 넣을 땐
> 그 경로가 안 바뀌도록 안정적인 위치를 고르는 게 좋다.

## 레포에 적용

1. `examples/` 의 예시를 레포 루트에 `.worktree-share.json` 으로 복사해 수정하고 커밋.
2. 워크트리 만들 때 엔진을 호출 (아래 셋 중 하나).

### A) Orca 훅 (자동)

Orca → Settings → Repository hooks 에 (모든 레포 동일 명령):
- **Setup**  : `<engine-dir>\orca-setup.cmd`
- **Archive**: `<engine-dir>\orca-archive.cmd`

엔진이 `ORCA_WORKTREE_PATH` 로 대상 워크트리를, `git worktree list` 로 원본 레포를,
`<repo>/.worktree-share.json` 으로 규칙을 자동 인식한다. **레포마다 설정 바꿀 필요 없음.**

> ⚠ Orca 의 **"Wait for setup to complete before starting agent" 는 끄세요.** 켜면 Orca 가
> cmd 전용 시퀀싱 래퍼를 만드는데 셸이 cmd 가 아니면 깨진다. 끄면 setup(공유)은 그대로 돌고
> 에이전트는 정상 실행된다.
>
> 무거운 자산까지 공유(optional 항목)하려면 Setup 명령 끝에 `-IncludeOptional` 을 붙인다.
> (단, 아래 "격리 vs 공유" 를 반드시 읽고 결정할 것.)

### B) 수동 (CLI)

```powershell
# 워크트리 하나에 공유 적용 (원본/설정 자동 감지)
powershell -File <engine-dir>\share-worktree.ps1 -Worktree <워크트리경로>

# optional 항목(무거운 자산 등)까지
powershell -File <engine-dir>\share-worktree.ps1 -Worktree <경로> -IncludeOptional

# 제거 (junction 안전 해제 후)
powershell -File <engine-dir>\remove-worktree.ps1 -Worktree <경로> -DeleteBranch
```

## `.worktree-share.json` 스키마

레포 루트에 두는 설정 파일. `shares` 배열의 각 항목이 "어떤 경로를 어떤 방식으로 공유할지" 선언한다.

```jsonc
{
  "shares": [
    { "path": "unity/Library", "mode": "cache" },
    { "path": "unity/Assets", "mode": "link-children",
      "children": ["TextMesh Pro", "Firebase"], "optional": true },
    { "path": "unity/Packages", "mode": "link", "optional": true },
    { "path": "server/artifacts", "mode": "copy" }
  ]
}
```

| 필드 | 설명 |
|---|---|
| `path` | 레포 루트 기준 상대경로. 원본이 없으면 조용히 건너뜀. |
| `mode` | `link` / `copy` / `cache` / `link-children` (아래) |
| `copy` | (cache 전용) 공유하지 않고 복사할 자식 이름 목록. 생략 시 Unity 기본 lock 목록. |
| `children` | (link-children 전용) base 아래 junction 할 하위 폴더 이름들. |
| `optional` | `true` 면 `-IncludeOptional` 일 때만 적용. |

> ⚠ 실제 `.worktree-share.json` 은 **주석 없는 표준 JSON**이어야 한다 (Windows PowerShell 5.1
> `ConvertFrom-Json` 은 `//` 주석을 못 읽음). 메모는 `"_comment": "..."` 처럼 **키**로 남긴다
> (엔진은 모르는 키를 무시). 위 jsonc 블록의 `//` 는 이 문서 설명용일 뿐이다.

### mode 별 동작

먼저 반드시 알아야 할 개념:

> **junction 은 그 폴더가 원본(main)을 가리키는 "통로"** 다. 워크트리에서 그 폴더를 **읽든 쓰든
> 실제로는 main 폴더에 작용**한다 → junction 건 것은 **main·모든 워크트리가 같은 실체를 공유**한다.
> **copy 는 그 시점의 독립 사본** → 워크트리가 자기 것을 갖고, 바꿔도 main 에 영향 없다.

| mode | 동작 | 공유/독립 | 쓰는 상황 |
|---|---|---|---|
| `link` | `path` 폴더를 **통째로 junction** | **공유** | 무겁고 잘 안 변하고 워크트리별로 다를 필요 없는 폴더 (예: 서드파티 SDK) |
| `copy` | `path` 폴더를 **통째로 독립 복사** | **독립** | 워크트리마다 달라야 하거나 배타 잠금이 필요 |
| `cache` | `path` 하위를 항목별로 판정(아래) | **혼합** | Unity `Library` 처럼 "대부분 공유 + 일부만 독립" |
| `link-children` | `path`(base) 하위의 `children` 만 각각 junction | **공유(선택)** | `Assets` 처럼 통째 공유는 안 되고 특정 하위만 |

**`cache` 판정 규칙** — `path` 하위 각 항목에 대해:
```
- 파일이면            → copy    (junction 은 폴더 전용; 파일은 작으니 복사)
- 이름이 copy 목록에  → copy    (독립 필요: DB / lock / 워크트리별 산출물)
- 그 외 디렉터리      → junction (공유: 무거운 안정 캐시)
```

**`link` vs `link-children`** — `Assets` 를 통째로 `link` 하면 `Assets/Scripts` 까지 공유돼 **격리가
깨진다.** 그래서 Assets 는 `link-children` 으로 **안 건드리는 서드파티 하위만** 골라 공유하고,
`Scripts`/`Editor` 등 편집 대상은 실제 파일로 남긴다.

---

## 격리 vs 공유 — 무엇을 junction 하면 안 되나 (반드시 읽기)

junction(공유) 폴더에 **새 파일을 추가하거나 수정하면, 그 변경이 main 폴더에 기록**된다. 그 결과:

- 내 워크트리 브랜치가 아니라 **main 작업트리에 얹힘** (main 의 `git status` 에 뜸)
- **다른 모든 워크트리에 즉시 반영** (서로 간섭)
- Unity 가 그 폴더에 `.meta` 를 쓰면 그것도 main 에 기록

그래서 원칙은 **"개발 중 새 파일을 추가·편집하는 폴더는 junction 금지"**, junction 은
**손 안 대는 읽기전용(서드파티 SDK/툴/캐시)** 에만.

### 폴더 유형별 판단

| 폴더 유형 | 예 | 권장 |
|---|---|---|
| 편집·추가 대상(내 콘텐츠) | `Assets/Scripts`, `Assets/Prefabs`, `Assets/Resources`, `Assets/Images`, `Assets/VFX` | **격리** (공유하지 말 것) |
| 읽기전용 서드파티 SDK/툴 | `TextMesh Pro`, `Firebase`, `Best HTTP`, `AmplifyShaderEditor` | `link`/`link-children` 공유 OK |
| 재생성되는 무거운 캐시 | `Library/ShaderCache`, `Library/PackageCache`, `Library/Bee` | `cache` 로 junction 공유 OK |
| 배타 잠금/워크트리별 산출물 | `Library/ArtifactDB`, `Library/ScriptAssemblies`, `Library/Artifacts` | `cache` 의 `copy` 로 독립 |

### 액션별 결과 (Unity 기준)

세 가지 상황을 **기본(Library 만 공유)** vs **`-IncludeOptional`(Assets/Packages 까지 junction)** 로 비교.

| 하는 일 | 기본 (권장) | `-IncludeOptional` 이고 대상 폴더가 junction 인 경우 |
|---|---|---|
| **PNG·prefab 추가** | ✅ 격리. 워크트리 안에만 생기고 자기 Library 로 임포트 | ❌ `Images`/`Prefabs`/`Resources` 가 junction → **main 에 기록**, 전 워크트리 노출, 내 브랜치엔 안 담김 |
| **플러그인(DLL 등) 추가** | ✅ 격리 (`Assets/Plugins` 가 실제 파일) | ❌ `Plugins` 가 junction → **main 에 새어나감** |
| **UPM 패키지 추가** | ✅ `Packages/manifest.json` 격리 → 워크트리별 다른 패키지셋 가능. 받은 내용은 `Library/PackageCache`(공유)라 재다운로드 안 함 | ❌ `Packages` 가 junction → **manifest 가 main 에 기록 = 전 워크트리 공통 패키지셋** |

> **요점: 기본 상태(Library 만 공유)에서는 리소스·플러그인·UPM 추가가 전부 안전하게 격리된다.**
> 문제는 오직 그 대상 폴더를 `-IncludeOptional` 로 junction 했을 때만 생긴다.

### 왜 그런지 — 조금 더 자세히

- **PNG/prefab**: 새 에셋은 파일이 놓인 폴더에 물리적으로 생긴다. 그 폴더가 junction 이면
  파일 실체가 main 에 생기고, Unity 가 만드는 `.png.meta` (GUID 포함)도 main 에 기록된다.
  격리 폴더(실제 파일)면 파일·meta 모두 워크트리 안에만 생기고, 워크트리 자기 `SourceAssetDB`
  (cache 의 copy 라 독립)로 임포트되어 완전히 분리된다.
- **플러그인**: DLL/네이티브 라이브러리도 결국 `Assets/Plugins` 아래 파일이다. 위와 동일.
  플러그인이 요구하는 import 설정이 `.meta` 에 들어가므로, junction 이면 그 설정까지 main 공유됨.
- **UPM**: Package Manager 로 패키지를 추가하면 `Packages/manifest.json` 이 바뀌고, 실제 내용은
  `Library/PackageCache` 로 내려받는다.
  - `Packages` 격리(기본) → manifest 가 워크트리별 → 워크트리마다 다른 패키지셋 가능.
  - `Library/PackageCache` 공유(cache junction) → 같은 `이름@버전` 은 재다운로드 없이 재사용.
  - 즉 **manifest 는 독립, 다운로드 캐시는 공유**가 이상적이고, 기본 설정이 정확히 그 상태다.

### 권장 설정 패턴

**패턴 A — 가장 안전 (권장 기본):** `optional` 을 아예 안 켠다(= Library 만 공유). 에디터 즉시
진입 효과는 그대로 얻고, 모든 저작(리소스/플러그인/UPM)이 격리된다. 대가는 무거운 서드파티
폴더가 워크트리마다 디스크에 중복되는 것뿐(git 이 어차피 체크아웃한다).

**패턴 B — 디스크 절약 + 안전:** `link-children` 에는 **순수 읽기전용 서드파티만** 넣고,
편집 대상(`Prefabs`/`Resources`/`Images`/`VFX`/`StreamingAssets`, 필요 시 `Plugins`/`Spine`)은
빼서 격리한다. `Packages`·`ProjectSettings` 도 워크트리별로 달라질 수 있으면 junction 하지 않는다.

### UPM 을 정밀하게

manifest 를 격리(패턴 B: `Packages` junction 안 함)하면서 "패키지 재해석" churn 까지 없애려면,
`Library` cache 의 `copy` 에 `PackageManager` 를 추가한다. → 다운로드 캐시(`PackageCache`)는 계속
공유하고, 해석 상태(`PackageManager`)만 워크트리별 독립이 된다.

```jsonc
{ "path": "unity/Library", "mode": "cache",
  "copy": ["ArtifactDB","ArtifactDB-lock","SourceAssetDB","SourceAssetDB-lock",
           "Artifacts","TempArtifacts","ScriptAssemblies","StateCache",
           "ShaderCache.db","BuildPlayer.prefs","ilpp.pid","PackageManager"] }
```

### 안전 체크리스트

- [ ] 개발 중 **새 파일을 넣는 폴더**를 junction 목록에 안 넣었는가?
- [ ] `Assets` 를 `link`(통째)가 아니라 `link-children` 으로 필요한 하위만 잡았는가?
- [ ] 워크트리별로 다른 패키지셋이 필요하면 `Packages` 를 junction 하지 않았는가?
- [ ] 제거는 항상 `remove-worktree.ps1` / archive 훅(`-Detach`) 으로 하는가?

---

## ⚠ 제거 함정 (Windows junction)

junction 이 걸린 워크트리를 `git worktree remove` / `rm -rf` / `git clean -fdx` 로 그냥 지우면
링크를 따라가 **원본까지 삭제**될 수 있다. 반드시 `remove-worktree.ps1`(또는 archive 훅 =
`-Detach`)로 링크를 먼저 끊고 제거할 것.

## 예시 설정

`examples/` 참고 (각 레포 루트에 `.worktree-share.json` 으로 복사해서 수정):

- **`worktree-share.template.json`** — 4가지 mode 를 모두 보여주는 범용 템플릿 (주석 키 상세).
- **`unity.worktree-share.json`** — Unity 프로젝트용 **안전 설정 예시** (읽기전용 서드파티만
  공유, 저작 폴더 격리, UPM 독립). 각 항목에 "왜 이렇게 두는지" 를 `_comment` 로 달아둠.

레포마다 Unity 폴더명(`Client/`, `unity/`, `src/` …)이나 공유할 폴더가 달라도, 그 차이는 전부
설정 파일이 흡수하므로 **엔진은 손대지 않는다**.
