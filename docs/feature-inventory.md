# IDM feature map

This page lists what Internet Download Manager 6.43 (build 15) does and where each feature lives in cDownloader. Use it to check that nothing important was left out, and to find the code behind a feature.

## Where the list comes from

The IDM installer (`idman643build15.exe`, 12.6 MB) is a small setup program carrying 191 compressed files. Unpacking it produced the program itself, its Windows add-ons, the browser add-ons for Chrome, Edge, Firefox and Opera, four help manuals and about 50 language files. The features below come from:

- the help manuals (`idman.chm`, `scheduler.chm`, `grabber.chm`, `tutor.chm`), which describe each feature in plain words,
- the English text file for translators (`Languages/template.lng`), which lists every menu item, button and message,
- the tips file, the default list of excluded addresses, and the Chrome add-on's settings file.

None of IDM's program code, artwork or name is used in cDownloader. Only the behavior was studied.

## Feature by feature

| IDM feature | What it does | In cDownloader | Code |
|---|---|---|---|
| Dynamic segmentation | Splits a file across connections and, whenever a connection is free, halves the biggest remaining piece; a connection that finishes takes over the next piece if nobody started it | Same rule | `Engine/SegmentPlanner.swift`, `Engine/DownloadJob.swift` |
| Connection reuse | Free connections help slow ones instead of reconnecting from scratch | Same rule; the Mac's network layer keeps connections open between requests | `Engine/HTTPTransport.swift` |
| Resume and crash safety | Saves positions several times a minute; resumes after a pause or a power cut | Saves every 5 seconds and on pause; checks the server's file tag (If-Range) and starts over when the file changed | `Engine/DownloadJob.swift` |
| "Ignore file date changes" | For servers that change a file's date on every request | Same option | `AppSettings.ignoreModificationTimeChanges` |
| Connections per server | A different connection limit for chosen servers | Same, with `*` wildcards | `Support/ConnectionRules.swift` |
| HTTP, HTTPS and FTP | Download protocols | All three; FTP in passive mode with resume | `Engine/HTTPTransport.swift`, `Engine/FTPTransport.swift` |
| Logins | Asks for a user name and password; "Site Logins" remembers them by address | Same; passwords in the Keychain | `Support/ConnectionRules.swift`, `Persistence/SecretStore.swift` |
| Proxy | Manual or system proxy, with exceptions | Same (HTTP, HTTPS, SOCKS) | `ProxyConfigurator` |
| Speed Limiter | Global limit, plus a limit per download from its progress window | Same, with the per-download limit in the details panel under the list | `Engine/SpeedLimiter.swift` |
| Download limits | "At most X MB every Y hours" | Same | `DownloadQuota` |
| Categories | Folders and file types per category, suggested automatically | Same six categories, editable | `Model/DownloadCategory.swift` |
| Queues | Main download queue, synchronization queue, any number of custom queues; N files at once; failed files move to the end; a lone failing file retries every 30 seconds | Same rules | `Queue/QueueRunner.swift` |
| Scheduler | Start and stop times, once or on chosen days, repeat synchronization every N minutes, retry limits, then quit, sleep, shut down or open a file | Same; "hang up the modem" left out (no dial-up on Macs) | `Queue/QueueScheduler.swift`, `SchedulerView.swift` |
| Browser integration | Takes over downloads by file type; keys to force or skip; excluded sites and addresses | Chrome, Edge and Brave add-on; Option skips by default | `Extension/rules.js`, `Extension/background.js` |
| Right-click menu | "Download with IDM", "Download all links with IDM" | Same, plus "Download selected links" and "Download this media" | `Extension/background.js` |
| Video download panel | A button over web players when a video is detected | Same; DRM-protected videos are labeled and never downloaded | `Extension/content.js` |
| Stream downloading | Downloads video streams | HLS (`.m3u8`) including AES-128 encryption; DASH is detected but not downloaded yet | `HLS/` |
| YouTube | Downloads YouTube videos from the video panel | Videos, Shorts and playlists in a chosen quality (best to 360p, or sound only) through yt-dlp, which comes with the app and updates itself daily; the YouTube sign-in from the add-on is passed along | `WebVideo/`, `Extension/content.js` |
| Facebook | Downloads Facebook videos from the video panel | Videos and reels in a chosen quality through the same yt-dlp, from video pages, feed posts that link to their video, right-clicked links and addresses pasted into the app; Facebook's own byte-range pieces are not offered as videos; the Facebook sign-in from the add-on is passed along | `WebVideo/FacebookLinks.swift`, `Extension/rules.js`, `Extension/content.js` |
| Video conversion | Converts downloaded video | `.ts` streams become `.mp4` when ffmpeg is installed | `StreamConverter` in `Services.swift` |
| Clipboard monitoring | Offers to download a copied link of a known type | Same, once per copy | `Input/ClipboardFilter.swift` |
| Drag and drop, drop target | Drop links on the window or a floating target | Same; finished files can be dragged out | `MainView.swift`, `ProgressViews.swift` |
| Download File Info dialog | Category, folder, name and description before starting; "Download Later" to a queue | Same, and it asks the server for the real name and size meanwhile | `AddDownloadViews.swift` |
| Progress window | Speed, time left, resume capability, a bar showing each connection's piece | A details panel under the list instead of a separate window: same bar (pink starts, blue done), speed, time left, resume capability, a per-download speed limit | `ProgressViews.swift` (`DownloadDetailsPanel`) |
| Download complete dialog | Open, open folder, drag the file | A banner in the main window that fades away, with Open, Show in Finder and a draggable icon; never opens a window | `ProgressViews.swift` (`CompletionBanner`) |
| Batch download | `file*.jpg` from 1 to N or a to z, with zero padding | Same | `Input/BatchPattern.swift` |
| Import and export | Import links from a text file; export lists (`.ef2`) | Same; reads and writes IDM's `.ef2` | `Input/LinkImporter.swift` |
| Zip preview | Lists a remote zip's contents and extracts single files | Same, including archives over 4 GB | `Zip/RemoteZipPreview.swift` |
| Site Grabber | Four-step wizard: start page, save folder, pages to explore, files to keep; saved and scheduled projects | Same steps and filters; does not run page scripts | `Grabber/` |
| Command line | `idman /d URL /p folder /f name /q /n /a`, `idman /s` | `cdownloader` with the same options (`-` or `/`) | `IPC/CommandLineParser.swift`, `Sources/cDownloaderCLI` |
| Antivirus check | Runs a scanner on finished files | Same, with `%f` for the file | `ScanRunner` |
| Sounds | A sound per event | Same, with the Mac's system sounds | `SoundPlayer` |
| Start with Windows, tray icon | Runs at startup, icon by the clock | Opens at login, menu bar icon; with the window closed it keeps running in the menu bar without a Dock icon | `LaunchAtLogin`, `MenuBarContent`, `DockIcon` |
| Customizable list and toolbar | Choose and order columns and buttons | Columns can be hidden, reordered and sorted | `DownloadTable.swift` |
| Refresh download address | Picks up a fresh link for an expired download | Same: mark the download, open the page again, and the next download with that name updates it | `DownloadLibrary.requestAddressRefresh` |

## Left out on purpose

| IDM part | Why |
|---|---|
| Network drivers ("advanced browser integration") and Internet Explorer hooks | Windows-only system parts; the browser add-on covers the same need on a Mac |
| Dial-up connection, redial and hang-up | Macs have no dial-up |
| Registration, serial numbers and update checks | Not needed for a self-built app |
| About 50 translations | The app is in English; its text is ready for translation |
| Firefox and Opera add-ons | You chose Chrome, Edge and Brave for this version |
