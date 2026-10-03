Plan for the release.

## Tasks

### Backlog

### Discovery
- [Customer interviews](synapseresource://note/n-int?via=gantt) · 2026-10-01 → 2026-10-09
- [Competitive teardown](synapseresource://note/n-comp?via=gantt) · 2026-10-05 → 2026-10-14

### Parked

### Build
- [Sync engine](synapseresource://note/n-sync?via=gantt) · 2026-10-12 → 2026-11-06
- ◆ [Beta cut](synapseresource://note/n-beta?via=gantt) · 2026-11-09

### Later

```synapse-gantt
{"v":1,
"settings":{"listHeading":"Tasks"},
"groups":[
 {"id":"ge1","title":"Backlog"},
 {"id":"g1","title":"Discovery"},
 {"id":"ge2","title":"Parked"},
 {"id":"g2","title":"Build"},
 {"id":"ge3","title":"Later"}
],
"tasks":[
 {"id":"t1","note":"n-int","title":"Customer interviews","start":"2026-10-01","end":"2026-10-09","group":"g1"},
 {"id":"t2","note":"n-comp","title":"Competitive teardown","start":"2026-10-05","end":"2026-10-14","group":"g1"},
 {"id":"t3","note":"n-sync","title":"Sync engine","start":"2026-10-12","end":"2026-11-06","group":"g2"},
 {"id":"t4","note":"n-beta","title":"Beta cut","start":"2026-11-09","group":"g2","milestone":true}
]}
```