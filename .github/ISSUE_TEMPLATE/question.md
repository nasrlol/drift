---
name: Question for nasr
about: Something you need and cannot find (data, API, access, constant, decision). See AGENTS.md.
title: "Question: <the question itself, ending with ?>"
labels: question
assignees: nasrlol
---

<!--
nasr only sees this text. Write it so he can answer in one line without opening your branch.
Short, plain words, no logs. One question per issue. Delete these comments.
-->

**Context:** <!-- One or two sentences: what you are building and why you need this. -->

**Question:** <!-- One question. Best if the answer is a value, yes / no, or a letter below. -->

**Options:**
- A: <!-- option --> (my pick, because ...)
- B: <!-- option -->

**Code:**
<!-- Paste the lines that matter (max ~10 per block), with file:line above each block and the
     permalink below it. The BLOCKED marker, the code that needs the answer, and the spec or
     notes.txt line if any. nasr must be able to answer from this text alone. -->
`source/game/<file>.odin:<from>-<to>`
```odin
<the lines>
```
https://github.com/nasrlol/drift/blob/<sha>/<file>#L<from>-L<to>

**Blocked until answered:** <!-- One line. -->

<!--
Example:

Context: I am building the weather grid in net.odin. It needs the map origin to turn grid points into lat / lon.
Question: Should net.odin take the projection constants from tools/bake_map instead of its own copy?
Options:
- A: Move LON0 / LAT0 / KM_PER_DEG to map.odin, bake_map and net.odin both use them (my pick, one source).
- B: Keep the copy in net.odin.
Code:
`source/game/net.odin:38-41`
```odin
// Same projection as tools/bake_map, inverted to get the lat / lon of each grid point.
MAP_LON0 :: 2.38
MAP_LAT0 :: 51.56
KM_PER_DEG :: 111.32
```
https://github.com/nasrlol/drift/blob/<sha>/source/game/net.odin#L38-L41

`tools/bake_map/main.odin:36-38`
```odin
LON0 :: 2.38
LAT0 :: 51.56
KM_PER_DEG :: 111.32
```
https://github.com/nasrlol/drift/blob/<sha>/tools/bake_map/main.odin#L36-L38

Blocked until answered: weather lat / lon per grid point.
-->
