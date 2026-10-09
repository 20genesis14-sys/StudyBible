# 0009. Extensions: narrow API v1

**English** | [Русский](0009-extensions-narrow-api.ru.md)

Status: accepted.

## Context

Five extension levels — a classification. A wide API frozen in 1.0
cannot be narrowed later; iOS does not allow downloadable executable
code.

## Decision

API v1: data from plugins, a batched output pipeline (per chapter or
screen), UI extension points where the app draws. Canvas and a plugin's
own UI — after 1.0. A full UI replacement is an alternative frontend,
not a plugin. The technology is chosen by API v1. SemVer, permissions.
Executable plugins are not promised on iOS.

## Consequences

The format and API specification for API v1 — also in English.
