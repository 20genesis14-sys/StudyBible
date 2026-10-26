# 003-sbz-search — smoke (2026-10-18)

- Card: evals/tasks/003-sbz-search.md (v1 (2026-10-18))
- Worktree: D:\StudyBible-eval\003-sbz-search-smoke, ветка eval/003-sbz-search-smoke (base e098ef155469d7631b4a55ca6ea64995ce01048d)
- Judge: 3/4 проверок пройдено

| Проверка | Результат | Детали |
|---|---|---|
| agent-rules | ✅ |  |
| flutter analyze | ✅ | exit=0 |
| ci.ps1 | ❌ | exit=1 |
| Workspace tests pass — `cargo test -p studybible-store` → exit 0 | ✅ | exit=0 running 6 tests |

Verdict: инфраструктурный прогон судьи без сессии агента — раннер
работает, ветка/запись/чеки в порядке.
Notes: ci.ps1 ❌ — не задача и не агент: свежий advisory
RUSTSEC-2026-0369 (zip 2.4.2) валит `cargo deny check` на любом
дереве с этим lock-файлом, включая base e098ef1. Решение (bump zip /
ignore в deny.toml) — за владельцем репозитория.
