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

## Signing In to Sites

Some pages show nothing useful until you are signed in, and the clipper's webview starts out signed out. Save a login once and clipping that site works from then on.

Open **Settings → Web Logins**.

![](../../media/web_clipping/web_login_settings.png)

Tap **Add login**, type the site's address, and sign in the way you normally would. This is a real browser, so single sign-on, two-factor prompts and captchas all work. Your password is never handled or stored — only the session cookies the site gives back afterwards.

![](../../media/web_clipping/web_login_browser.png)

Once you are signed in, tap **Save login**. If a site hides its login form from phones, the toolbar's **Request desktop site** toggle switches the browser to a desktop user agent for that visit.

Sign in before you save. Saving fails only when the site handed over no cookies at all — so on a site that sets a cookie before you log in, saving while signed out still succeeds and leaves you with a login that authenticates nothing.

Clip the page as usual; Note Synapse restores that site's cookies before the page loads.

## Managing Saved Logins

The Web Logins screen lists each saved site and when you saved it.

![](../../media/web_clipping/web_logins_list.png)

Logins are saved per domain: signing in at `https://news.example.com/article` files one login under `example.com`, which is reused for any page on that domain. Whether it also authenticates a *different* subdomain is up to the site — cookies it pinned to `news.example.com` are only ever sent back there. Saving again for the same domain replaces what was there.

The timestamp counts up — `just now`, `5m ago`, `3h ago`, `14d ago` — and becomes a `YYYY-MM-DD` date once the login is 30 days old.

Nothing warns you when a login goes stale. Sites expire sessions on their own schedule, and when that happens clipping quietly returns the signed-out page instead. Add the login again to refresh it.

The trash icon removes the stored session and clears the cookies for the domain and for the host you signed in on. It confirms first, with "Delete the saved login for {domain}? Clipping pages on this site will no longer be authenticated." This is a local sign-out: the site is never told, and cookies on other subdomains are left alone. Note Synapse itself never uploads a saved login.

## Apps with Access

User apps (plugins) can ask to use a saved login, which is how NotebookLM Manager reaches your notebooks. The first time an app asks, Note Synapse shows **Allow use of your {domain} login?** and states the terms: the app will be able to make requests as you on that domain and any of its subdomains, and to read that login's cookies. It can read the cookie values themselves, so approve only apps you would be comfortable signing in on your behalf.

Approved apps are listed under **Apps with access** beneath their domain, each with a **Revoke** button. Revoking stops the app using the login until you approve it again, though it cannot recall cookie values the app has already read. Deleting the saved login and uninstalling the app both revoke access as well.
