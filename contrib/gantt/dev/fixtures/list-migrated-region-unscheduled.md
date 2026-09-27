All four rest shapes.

## Tasks

- [Plain](synapseresource://note/n-u1?via=gantt)
- [Counted](synapseresource://note/n-u2?via=gantt) · 3/5
- [One day](synapseresource://note/n-u3?via=gantt) · 2026-10-01
- [Ranged](synapseresource://note/n-u4?via=gantt) · 2026-10-01 → 2026-10-09 · 2/4
- ◆ [Gate](synapseresource://note/n-u5?via=gantt) · 2026-10-12 · 1/1

### Only a bare milestone

```synapse-gantt
{"v":1,
"settings":{"listHeading":"Tasks"},
"groups":[
 {"id":"g1","title":"Only a bare milestone"}
],
"tasks":[
 {"id":"t1","note":"n-u1","title":"Plain"},
 {"id":"t2","note":"n-u2","title":"Counted"},
 {"id":"t3","note":"n-u3","title":"One day","start":"2026-10-01"},
 {"id":"t4","note":"n-u4","title":"Ranged","start":"2026-10-01","end":"2026-10-09"},
 {"id":"t5","note":"n-u5","title":"Gate","start":"2026-10-12","milestone":true},
 {"id":"t6","title":"Freeze","start":"2026-10-20","milestone":true},
 {"id":"t7","title":"Board review","start":"2026-10-22","group":"g1","milestone":true}
]}
```