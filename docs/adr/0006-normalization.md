# 0006. NFC for translations, originals as in the source

**English** | [Русский](0006-normalization.ru.md)

Status: accepted.

## Context

Unicode normalization reorders vowel-mark pairs in Hebrew.

## Decision

Translations are stored in NFC. Originals — as in the source. NFC and
other normalization apply only to search keys. Normalization levels are
named explicitly:

- Russian — case; ё = е; stress marks and soft hyphens; pre-reform
  ѣ, і, ѳ, ѵ;
- Hebrew — te'amim; vowel points; final letters; maqqef;
- Greek — case; accents and breathings; final sigma; iota subscript.

Originals are searched by lemma, Strong's and morphology, without
stemming.

## Consequences

Original texts are not distorted; search is tuned by levels.
