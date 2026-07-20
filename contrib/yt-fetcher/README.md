# YTFecher Plugin 

Retrieves video script from YouTube videos. It follows the method used in
[youtube-transcript-api](https://github.com/jdepoix/youtube-transcript-api/tree/master).

## Install

1. Import `plugins/YTFetcher.yaml` in the User App screen.
2. In AI conversation, enable the YTFetcher tool, and ask it questions, given a YouTube video URI.

## AI tools exposed

| Tool | Purpose |
|---|---|
| `fetch_youtube_data` | Downloads the transcript given a URI |

## How it works

The tool uses unofficial interfaces for YouTube, referencing the technique in the youtube-transcript-api.

## Development

Edit `plugins/yt_fetcher.html`, then run `plugins/build.sh` to regenerate `YTFetcher.yaml`.

## License

MIT.
