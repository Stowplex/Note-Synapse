# Tutorial: Tag Filter

There are 2 paradigms of organizing files:

1. tags: cheap to create and update, but can get messy when many tags are created and does not reveal hierarchy of information.
2. folders: effectively groups information, builtin support for hierachy, but is less flexible when files need to be moved around. And it is tricky for a file to appear in two folders -- the solution typically is symlink which does not work well in mobile world.

Note Synapse features Tag Filter, which brings you the benefits of both worlds.

A tag filter is a matcher that matches a set of tags. For example, we can have a tag filter A matches tags [AI, Research].This representation creates a "virtual folder" concept out of the flat tags. And it's hierarchical by default -- If a tag filter B matches tags [AI], the set of notes that B selects is a superset of notes selected by A. This we have a hierachy \( A \subseteq B \).

Tag filters also fix the issue with multiple presence. For example, a note tagged [AI, Research, Learn] can appear both in [Learn] and [AI].

To create a tag filter, click the [+] button on the tag filter strip.

![](../../media/image_1771185062759_8dc13826-5f74-4271-a2a9-8fefb496634b.png)

You can create a bunch of tag filters, for example:
 
 Investment:
 
![](../../media/image_1771214337222_c5b1c668-3af1-4ec1-94c8-270898e19dfc.png)

Investiment - Tax:
![](../../media/image_1771214428866_d8d3f9b6-2286-4d8b-83e2-42f492ace274.png)

Investiment - Stock:
![](../../media/image_1771214392069_266e6248-ec1d-49d3-a58e-d5b82805c4cf.png)

Now note that they form a hierachy:

![](../../media/image_1771214670189_59b31589-1b57-487d-91ec-0f763f15f58c.png)

On the tag filter strip, by default tag filters are laid out flat:

![](../../media/image_1771214719448_3e74bc71-cd29-4f25-a01f-49626fb2f814.png)

![](../../media/image_1771214728581_7b3493fd-c791-4102-ac2e-c1600737ef38.png)

You can tap the hierachy icon on the left, which will turn the tag filters in the strip into hierarchy view. The status of this icon is memorized in settings so next time it remains your last set state. Note that when the hierarchy is activated, only top level tag filters are shown.  There is a small triangle on them to open up the hierachy.

![](../../media/image_1771214860367_766875b7-4cea-4e88-93d4-eaeadf1d838f.png)

![](../../media/image_1771214868309_f2e26b32-a1d2-40e9-9ca4-4f065eace154.png)

![](../../media/image_1771214875977_391b574f-865c-4730-a2ae-bb6ec6fff995.png)

When you long-press the hierarchy icon on the tag filter strip, you can open the tree view of the full hierarchy:

![](../../media/image_1771214935862_9fa04b48-c5e5-4c8f-a93a-d31222c8a201.png)

When you select a tag filter in the hierarchy, you can pin them so that they appear on the first among the tag strip.

![](../../media/image_1771214986075_96e3ccbb-a4a2-4166-8cf2-ede3d9554080.png)

![](../../media/image_1771214993792_223a756f-9d73-4b94-b52f-aaa4260715a3.png)

You can activate multiple tag filters at the same time. They will be OR'd together. You can remove your active tag filters by tapping on the filter icon.

![](../../media/image_1771215136650_a34b689f-4a4b-4366-bdca-677b0823f043.png)

![](../../media/image_1771215143521_79b3dd94-455d-4213-97de-3f9fbcc5f9f3.png)

**Tips**

You can apply tags to multiple notes at the same time by multi select them and select the three dot menu -> select tags

![](../../media/image_1771216078492_0ab10c3a-c48e-4caf-bda6-dca97b478189.png)

You can add tags directly from tag filters, which will apply the set of all tags in the filter.

![](../../media/image_1771216128545_705e6e99-6bed-4866-9a75-3a211a3d7a82.png)

![](../../media/image_1771216135828_5b0069c4-4155-41e0-aaf2-6eaf53c23e51.png)

![](../../media/image_1771216142806_a70c7949-9432-4ac4-8414-9f1c07be8e6e.png)
