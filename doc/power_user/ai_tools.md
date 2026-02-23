# Tutorial: Create an AI Tool

The NoteSynapse allows you to create AI tools with natural language.

In this tutorial, we create an AI tool that invokes Google's Geocoding API and returns a list of places given a latitude/ longitude coordinates.

## Preparation

The LLM that implements the tool works best when it is given the context to work with. Here we'll use Note Synapse's Webclipper to save Google Geocoding's API.

First, copy Google's Geocoding API URL to clipboard:

```
https://developers.google.com/maps/documentation/geocoding/overview
```

Then, add note button -> New Note from Clipboard 

![](../media/image_1771125908599_f4ede7f3-95ba-42fa-93f7-e545059b6b75.png)

Click Extract -> Extract in Webview -> Create note

Now you have saved the documentation to geocoding API in note:

![](../media/image_1771135157685_c8eb5717-dde1-4b13-809e-6a387a5eccfc.png)

## Create the AI Tool

Tap the add button, and select the Create App option.

![](../media/image_1771139635206_42217ee3-4a22-4812-a85d-2f798ceb78c6.png)

The app's type should be AI tool, and you should select the option to attach a note.

![](../media/image_1771139713212_db108331-0f96-49a2-a549-ea4f6417b3ca.png)

Select the note about geocoding API that we clipped.

![](../media/image_1771139750580_de6095fc-9f47-49c1-8804-d2d62e369982.png)

Fill in the description, and the steps. The steps is also a perfect place to put down requirements.

![](../media/image_1771139790245_ecb3ae1d-9e73-404b-b517-4dbde3fec44b.png)

Click create app, and wait for it to finish. Once it's done, you will see the success screen.

![](../media/image_1771139825874_59541580-52dc-4e24-bd6f-0681a9b19f22.png)

Tap "To App" and you should be able to open the playground. All AI tools are required to have a playground for configuration and debugging.

![](../media/image_1771139897748_e64539d9-3631-40df-9749-12280dd00e67.png)

Set the API key and put down a coordinate to test.

![](../media/image_1771139958878_9b3db020-df45-48d3-8d4d-2edb48fbb9e9.png)

Now you can go to the chat screen and enable this tool, then test.

![](../media/image_1771140001323_1288d808-b35e-4ccb-a760-0f24e3755f7f.png)

![](../media/image_1771140011099_1e328418-de03-4da7-b333-f8612ef576c7.png)
