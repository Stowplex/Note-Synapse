# Tutorial: Clipping the web content

With Note Synapse, you can clip and save content from the web for offline reading.

You can copy the URL, then select the [+] button on the note main page. Select New Note from Clipboard.

Note Synapse will detect the URL and prompt for web extraction.

![](../../media/image_1771217967305_83fa62ce-4f98-4bd0-a669-ec97ce5052d3.png)

Here if you select As-Is the URL will be saved as text. We select "Extract" to save the web content.

By default, NoteSynapse loads the page inside a webview, then it applies Readability script to strip the irrelevant information.

This most of the time does a good job but sometimes it can be too aggressive or inaccurate. In our case, if omits the content in the expandable region, which are loaded just-in-time. Hence we need tap the Readability toggle to temporarily disable it.

![](../../media/image_1771218195518_7878fba9-6c8d-47c6-b0a4-a1f12086d61a.png)

When Readability is toggled off, you can scroll the page, expanding the collapsible area.

![](../../media/image_1771222293840_8d07adad-7b97-4c37-8bef-337eab7230b2.png)

Once these sections are expanded, you can toggle Readability back on and press extract. Note that extract with AI will by default give a summary, which is not useful for our case.

Then adjust the tags, select which media to download to local, and click create note.

You have successfully clipped a web page.

If Note Synapse detects that the URL points to a blob file, it will download it and add as attachment.

![](../../media/image_1771223366339_59302e78-3e21-4957-bb2f-b7ba3a0797bc.png)

![](../../media/image_1771223381613_8706a110-96c3-41fb-9a0a-a70d512eea08.png)
