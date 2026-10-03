# Dependencies to clean

```synapse-gantt
{"v":1,
"tasks":[
 {"id":"t1","note":"n-1","title":"A","after":["t3"]},
 {"id":"t2","note":"n-2","title":"B","after":["t1","t9","t2","t1"]},
 {"id":"t3","note":"n-3","title":"C","after":["t2"]},
 {"id":"t4","note":"n-1","title":"A again"},
 {"id":"t5","title":"No note, not a milestone"},
 {"id":"t6","note":"n-6","title":"Bad group","group":"g404"}
]}
```