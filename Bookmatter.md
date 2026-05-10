---
title: Bookmatter
author: adammharris
date: 2026-05-08
todo:
  - thing 1
  - thing 2
  - time: today
  - complex thing:
    - part 1
    - part 2
---
{
"title": "bookmatter",
"todo": [
  "thin 1",
  "thing 2",
  "time": "today,
  "complex thing":[
    "part1",
    "part2"
  ]
]}



# Bookmatter

Bookmatter is library and CLI intended to make parsing config files, whether standalone or embedded within another document (such as a markdown file) easy.

Bookmatter is currently in early alpha.

Planned features:
- JSON, YAML, TOML
- Normalized round-trip byte matching
- Edit in place, sorting, both in files and in other plain text files
- Optimized especially for the markdown frontmatter YAML convention
- Swap between different config flavors

Out of scope:
- Many advanced config language features
- References
- Multi-document files
- 