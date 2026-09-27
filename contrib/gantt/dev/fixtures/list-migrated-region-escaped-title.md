Titles that fight the grammar.

## Tasks

- [Fix [bug] **now**](synapseresource://note/n-e1?via=gantt) · 2026-10-01
- [a ］ b](synapseresource://note/n-e2?via=gantt) · 2026-10-02
- [［draft](synapseresource://note/n-e3?via=gantt) · 2026-10-03
- [◆ starts with a diamond](synapseresource://note/n-e4?via=gantt)

### Group ］ [x]
- ◆ [Ship it [v2]](synapseresource://note/n-e5?via=gantt) · 2026-10-09

```synapse-gantt
{"v":1,
"settings":{"listHeading":"Tasks"},
"groups":[
 {"id":"g1","title":"Group ] [x]"}
],
"tasks":[
 {"id":"t1","note":"n-e1","title":"Fix [bug] **now**","start":"2026-10-01"},
 {"id":"t2","note":"n-e2","title":"a ] b","start":"2026-10-02"},
 {"id":"t3","note":"n-e3","title":"[draft","start":"2026-10-03"},
 {"id":"t4","note":"n-e4","title":"◆ starts with a diamond"},
 {"id":"t5","note":"n-e5","title":"Ship it [v2]","start":"2026-10-09","group":"g1","milestone":true}
]}
```