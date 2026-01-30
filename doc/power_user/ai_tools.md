# Building AI Tools: Geocoding Example

AI Tools are superpowers you give to Synapse. Instead of a user interface, you are building a **function** that the AI can trigger.

In this guide, we will build a **Geocoding Tool** that lets Synapse convert addresses (e.g., "Eiffel Tower") into Coordinates (Lat/Lng) using the Google Maps API.

## Pre-requisites
*   A Google Cloud API Key with **Geocoding API** enabled.
*   Note Synapse installed.

## Step 1: Gather Context (The "Clip")
The AI needs to know *how* to use the API. You don't need to read the docs; just let Synapse read them.

1.  Open the [Google Geocoding API Documentation](https://developers.google.com/maps/documentation/geocoding/start) in your browser.
2.  Use the **Note Synapse Web Clipper**.
3.  **Toggle Readability**: Ensure it's ON (Book icon) to get clean text.
4.  Save the note.

## Step 2: Create the Tool
1.  Open Synapse -> **Apps** (Bottom Nav) -> **+** (Create App).
2.  **Type**: Select **AI Tool**.
3.  **Name**: `Google Geocoding`.
4.  **Description**: `Converts addresses to coordinates`.
5.  **Context**: Tap "Add Notes" and select the **Geocoding API docs** you just clipped.
6.  **Steps / Instructions**:
    Enter the following prompt:
    ```text
    Create a tool that takes an 'address' string as input.
    Use the Google Geocoding API to fetch the location.
    API Key: YOUR_GOOGLE_API_KEY_HERE
    Return a JSON object with { lat, lng, formatted_address }.
    Handle errors gracefully.
    ```
7.  Tap **Create App**.

## Step 3: The Playground & Logic
Synapse will generate the code. Since this is an AI Tool, it doesn't have a UI. Instead, the "Playground" lets you **test the function**.

*   Detailed code is generated in `htmlContent`.
*   Look for `window.Synapse.tool.registered`. This is where the function lives.

**Example Generated Code (simplified):**
```javascript
window.Synapse.tool.registered.geocode = async ({ address }) => {
  const apiKey = 'YOUR_KEY'; // In production, never hardcode keys if sharing!
  const url = `https://maps.googleapis.com/maps/api/geocode/json?address=${encodeURIComponent(address)}&key=${apiKey}`;
  
  // Notice we use proxyFetch, not fetch, to avoid CORS issues
  const response = await window.Synapse.proxyFetch(url);
  if (response.status !== 'success') throw new Error(response.error);
  
  const data = JSON.parse(response.content.data);
  const result = data.results[0];
  return {
    lat: result.geometry.location.lat,
    lng: result.geometry.location.lng,
    formatted_address: result.formatted_address
  };
};
```

> [!TIP]
> **Why `proxyFetch`?**
> Standard `fetch` is blocked by CORS limits in mobile WebViews. `Synapse.proxyFetch` routes the request through the native app layer, bypassing these restrictions.

## Step 4: Testing & Usage
1.  **Playground**: You can manually invoke the function in the playground console to ensure it returns JSON.
2.  **Save** the app.

### Using it in Chat
1.  Go to a **Chat** or **Tree Conversation**.
2.  Ensure the tool is **Active** (Check the "Apps/Tools" list in the chat settings or ensure it's improved globally).
3.  Ask: *"Calculate the distance between the Eiffel Tower and the Empire State Building."*

**What happens:**
1.  The Planner sees your request requires location data.
2.  It sees the `Google Geocoding` tool description.
3.  It **calls your tool** twice (once for Paris, once for NYC).
4.  It uses the returned Lat/Lng to calculate the distance using its internal math logic.
5.  It answers you.

You just built a functional backend integration without writing a single line of backend code!
