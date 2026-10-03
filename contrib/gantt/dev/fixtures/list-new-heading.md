Plan for the release.

## Tasks

- [Kickoff](synapseresource://note/n-kick?via=gantt) · 2026-09-30

### Discovery
- [Customer interviews](synapseresource://note/n-int?via=gantt) · 2026-10-01 → 2026-10-09
- [Competitive teardown](synapseresource://note/n-comp?via=gantt) · 2026-10-05 → 2026-10-14

### Build
- [Sync engine](synapseresource://note/n-sync?via=gantt) · 2026-10-12 → 2026-11-06

### Launch

### QA
- ◆ [Beta cut](synapseresource://note/n-beta?via=gantt) · 2026-11-09

```synapse-gantt
{"v":1,
"settings":{"listHeading":"Tasks"},
"groups":[
 {"id":"g1","title":"Discovery"},
 {"id":"g2","title":"Build","color":"teal"},
 {"id":"g3","title":"Launch"}
],
"tasks":[
 {"id":"t0","note":"n-kick","title":"Kickoff","start":"2026-09-30"},
 {"id":"t1","note":"n-int","title":"Customer interviews","start":"2026-10-01","end":"2026-10-09","group":"g1"},
 {"id":"t2","note":"n-comp","title":"Competitive teardown","start":"2026-10-05","end":"2026-10-14","group":"g1"},
 {"id":"t3","note":"n-sync","title":"Sync engine","start":"2026-10-12","end":"2026-11-06","group":"g2"},
 {"id":"t4","note":"n-beta","title":"Beta cut","start":"2026-11-09","group":"g2","milestone":true}
]}
```