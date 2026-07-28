@echo off
REM Orca "setup" hook - runs right after Orca creates a new worktree/workspace.
REM Applies path sharing defined in <repo>/.worktree-share.json to the new worktree.
REM cwd = new worktree; env ORCA_WORKTREE_PATH = new worktree path.
REM Extra args (e.g. -IncludeOptional) are forwarded. Same command works for ANY repo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0share-worktree.ps1" %*
exit /b %ERRORLEVEL%
