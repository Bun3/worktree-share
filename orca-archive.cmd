@echo off
REM Orca "archive" hook - runs right BEFORE Orca deletes a worktree/workspace.
REM Detaches junctions/symlinks (link only) so deletion cannot follow a junction
REM into the main repo and wipe shared originals. Configure this hook too.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0share-worktree.ps1" -Detach %*
exit /b %ERRORLEVEL%
