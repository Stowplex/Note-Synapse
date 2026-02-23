# Tutorial: Add an MCP server

MCP allows NoteSynapse 's AI to connect to external world.

> **WARNING**: Malicious MCP servers can risk prompt injection, or other adverserial actions. Only connect to MCP servers that you trust.

> **DISCLAINER**: The MCP servers in this tutorial are selected for illustration only. It is NOT an endorsement for their quality and safety.

# Add an OAuth Compatible MCP Server
Here we use the arXiV MCP server hosted at Smithery as an example.

Go to settings -> AI settings -> MCP Settings
![](../../media/image_1771100111743_7d5a51a9-4c81-4228-9626-03938cc47744.png)

Click "Add MCP Endpoint"

![](../../media/image_1771100185977_a2d43411-f3e1-481c-81e1-568cc2c12710.png)

In the dialog, fill the name and URL to the MCP server (note the name "base url" is a bit misleading, it's actually the full URL to the MCP server).

![](../../media/image_1771100321221_5cd75529-02ba-4e84-9171-c39f05be4601.png)

## Set OAuth Login
Now it's time to go through the OAuth flow.

Select the OAuth tab, and click "Auto configure". This will perform OAuth discovery and auto client registration.

![](../../media/image_1771100432441_2670aa97-2284-491a-b690-b9864b721d86.png)

In the OAuth discovery screen, click "Discover"

![](../../media/image_1771100519907_fe94e42c-8c53-472f-bb53-d03ef1c20415.png)

This will allow NoteSynapse to probe the well-known OIDC endpoints. When it suceeds, you can view the information. 

Next, click "Register client":


!![](../../media/image_1771103226579_33307ec9-7671-44f5-a0ba-31e1f18d0b0a.png)

When it suceeds, you should see the client ID. Click "Apply" to exit the discovery screen.

![](../../media/image_1771103319676_d1272fac-8508-40bd-88b6-394012652d59.png)

In the MCP service screen, observe that client ID and client secrets are configured. You can now click the login button to go through the OAuth flow:

![](../../media/image_1771103395333_7d7cee35-36f9-4ffa-b110-2ccb6e30a969.png)

when you finish login flow, you should see the success message with OAuth token:

![](../../media/image_1771103444946_db1cbb7b-389d-4872-909c-a4afa6129621.png)

Click "Create" and you have finished creating an MCP Endpoint.


The last crucial step is to press "refresh tools". This will connect to your MCP server with the credentials configured. It will also get the list of tools available, which is necessary.

![](../../media/image_1771114584742_70745b83-2103-46f0-bb8e-7650ef55b5dd.png)

After it suceeds, you can select "View tools" to see the tool manifest.

![](../../media/image_1771114610636_03ecea2b-3909-46e5-b6a5-28aeb3030c5e.png)

Head to the chat screen, enable the MCP. And give it a try.

![](../../media/image_1771114626868_883e85f2-3ff0-47f0-b1fa-6584335686fa.png)

![](../../media/image_1771114765410_fea50775-d079-4dfd-890f-dad40b40722c.png)

# Add MCP with Custom Auth Header
 Note Synapse allows you to specify a custom JSON that will be merged to the request header.
 
 For example, for DataCommons MCP (GCP managed), you can specify the API key in header.
 
 ![](../../media/image_1771116485986_fc680f27-e7a9-4182-9ced-081cb199126a.png)
 
 You can then skip the OAuth steps, but still need to refresh tools. Then test it in the Chat screen.
 
 ![](../../media/image_1771116564051_a726e1be-e303-4c67-92cd-f25e92d84d56.png)
