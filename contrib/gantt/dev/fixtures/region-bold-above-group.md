Launch plan for the Q4 release. Owners are in each task note.

- **Read this first**
- **Discovery**
  - [Customer interviews](synapseresource://note/8f0c1e2a-5b7d-4c11-9a0e-2f6b3c9d1e01?via=gantt) · 2026-10-01 → 2026-10-09 · 3/5
  - [Competitive teardown](synapseresource://note/1b7d4e90-0c2a-4f5e-8d61-7a3b2c1d0e02?via=gantt) · 2026-10-05 → 2026-10-14 · 0/4
- **Build**
  - [Sync engine](synapseresource://note/77aa3c21-9e4f-4b6d-a0c8-5d2e1f3a4b03?via=gantt) · 2026-10-12 → 2026-11-06 · 6/10
  - ◆ [Beta cut](synapseresource://note/c3e98a10-6d5b-4e2f-b1a7-0c9d8e7f6a04?via=gantt) · 2026-11-09

```synapse-gantt
{"v":1,
"settings":{"progressSource":"checklist","progressSection":"## Checklist","progressStyle":"segments","weekStart":1,"holidays":["2026-12-25"]},
"groups":[
 {"id":"g1","title":"Discovery"},
 {"id":"g2","title":"Build","color":"teal"}
],
"tasks":[
 {"id":"t1","note":"8f0c1e2a-5b7d-4c11-9a0e-2f6b3c9d1e01","title":"Customer interviews","start":"2026-10-01","end":"2026-10-09","group":"g1"},
 {"id":"t2","note":"1b7d4e90-0c2a-4f5e-8d61-7a3b2c1d0e02","title":"Competitive teardown","start":"2026-10-05","end":"2026-10-14","group":"g1","color":"amber"},
 {"id":"t3","note":"77aa3c21-9e4f-4b6d-a0c8-5d2e1f3a4b03","title":"Sync engine","start":"2026-10-12","end":"2026-11-06","group":"g2","after":["t1"]},
 {"id":"t4","note":"c3e98a10-6d5b-4e2f-b1a7-0c9d8e7f6a04","title":"Beta cut","start":"2026-11-09","group":"g2","milestone":true,"after":["t3"]}
]}
```