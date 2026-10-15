# cDownloader

cDownloader is a download manager for the Mac. It is modeled on Internet Download Manager (IDM) for Windows: it downloads files faster by fetching several pieces at the same time, picks up where it left off after a pause or a crash, and can take over downloads from Chrome, Edge and Brave.

It was rebuilt from scratch by studying what IDM does (its help files, menus and settings), not by copying its code, name or artwork.

## What it does

- **Faster downloads.** A file is fetched over up to 32 connections at once. When one connection finishes its piece, it helps the slowest one by splitting the biggest remaining piece in half, the same trick IDM uses.
- **Resume anywhere.** Progress is saved every few seconds. After a pause, a lost connection or a power cut, the download continues from where it stopped, as long as the server allows it. If the file changed on the server, cDownloader notices and starts over.
- **Organized.** Files are sorted into categories (Compressed, Documents, Music, Programs, Video), each with its own folder.
- **Queues and a scheduler.** Queues download a set number of files at a time. They can start and stop at set times, retry failed files, and then quit the app, sleep or shut down the Mac. A synchronization queue re-downloads files only when they changed on the server.
- **Speed limiter and quotas.** Limit the total speed or one download's speed, or cap how much is downloaded every few hours.
- **Browser add-on.** Takes over downloads of chosen file types and adds right-click items ("Download with cDownloader", "Download all links"). It also shows a "Download this video" button on web videos. Hold Option while clicking a link to let the browser download it instead.
- **YouTube.** Downloads YouTube videos, Shorts and whole playlists in the quality you pick: the best available, 1080p, 720p, 480p, 360p, or sound only. The "Download video" button appears on YouTube pages, right-clicking a YouTube link works, and a playlist link offers every video in it. The work is done by yt-dlp, a free tool that comes with cDownloader and keeps itself up to date (see "Video tools are included" below).
- **Facebook.** Downloads Facebook videos and reels in the same qualities, through the same yt-dlp. The "Download video" button appears on a Facebook video page, and on a video in the feed when its post links to the video. Right-clicking a Facebook video link works, and so does pasting a Facebook video address into the app (watch pages, a page's videos, reels, share links and `fb.watch` short links). Downloads started from the browser add-on pass your Facebook sign-in along, so videos that only your friends or groups can see download too.
- **Video streams.** Downloads HLS streams (the `.m3u8` playlists many sites use), including the standard encrypted kind. The result is turned into an `.mp4` by ffmpeg, which comes with cDownloader. Videos protected with DRM (copy protection) are labeled as protected and are never downloaded.
- **Site grabber.** A four-step wizard that explores a website and lists every file of the types you want, for example all PDFs, ready to download in one go.
- **Stays out of the way.** Closing the window keeps cDownloader downloading in the menu bar (the arrow icon at the top of the screen), without a Dock icon, like a tray app on Windows. The icon opens the window again or quits. A download's progress shows in a panel under the list, and a finished download shows a short banner in the window instead of popping up windows. Deleting a download can also move its file to the Trash.
- **More.** Batch downloads (`photo*.jpg` from 1 to 100), zip preview (see and extract single files from a remote zip without downloading all of it), clipboard watching, drag and drop, a floating drop target, a menu bar icon, saved site logins (passwords stay in the Mac's Keychain), proxy settings, sounds, notifications, a virus-scan hook, and import and export of link lists, including IDM's `.ef2` format.

## Build it

You need a Mac with macOS 14 or newer and Xcode 16 or newer (it was built with Xcode 27 and Swift 6.4).

```bash
scripts/build-app.sh
```

This creates one file: `dist/cDownloader.dmg`, the installer. Open it and drag cDownloader into Applications, or give it to other people (see "Install it" below).

The first build also downloads the video tools the app includes (about 150 MB, see "Video tools are included"). Each download is checked against a known checksum (a fingerprint of the file), so a changed file is refused. They are kept in `.build/tools-cache`, so later builds work offline.

## Install it

Give people `dist/cDownloader.dmg`. They open it, drag cDownloader onto the Applications shortcut next to it, and open the app. That's all: everything for YouTube, Facebook and video streams is included. The app takes about 250 MB, mostly for the video tools, and the installer about 145 MB. An installer works on the same kind of Mac it was built on: one built on an Apple Silicon Mac (M1 or newer) does not run on an older Intel Mac, and the other way round.

The build has a free signature (an "ad-hoc" signature), not one registered with Apple. So the first time someone opens it, macOS says it could not check the app. They click "Done", then go to System Settings > Privacy & Security and click "Open Anyway" next to cDownloader. This is needed once. The note "How to Install" in the installer window explains it step by step. Signing the app with a paid Apple Developer ID, and having Apple check it, would remove this step.

## Connect your browser

1. Open cDownloader once. It registers its browser helper with Chrome, Edge, Brave, Chromium and Vivaldi.
2. In the browser, open `chrome://extensions` (or `edge://extensions`, `brave://extensions`).
3. Turn on **Developer mode** and click **Load unpacked**.
4. Choose the add-on folder. In cDownloader, **Settings > Browser > Show Add-on Folder** opens it (it is inside the app, at `cDownloader.app/Contents/Resources/Extension`).

The add-on's popup shows **Connected** when everything works.

## Video tools are included

YouTube and Facebook do not serve a video as one plain file: picture and sound come as separate pieces, and YouTube changes how it hands them out every few weeks. cDownloader leaves that to free tools that it carries inside the app, so nobody installs anything:

| Tool | What it does |
|---|---|
| yt-dlp | Downloads YouTube and Facebook videos. Its makers keep up with both sites' changes. |
| deno | Runs the small scripts YouTube uses to hide its video addresses, on behalf of yt-dlp. |
| ffmpeg and ffprobe | Join picture and sound into one `.mp4`, and turn video streams into `.mp4` files. |

**yt-dlp updates itself.** An old yt-dlp stops working when YouTube changes something, so cDownloader keeps its own copy in `~/Library/Application Support/cDownloader/Tools` and checks for a newer one once a day, quietly. A new version is only used once it has been downloaded completely and starts correctly, so a failed update never breaks YouTube downloads. The app runs this copy rather than the one inside the app for a second reason too: macOS refuses to start the copy inside the app when the app was downloaded through a browser, but a copy the app made itself starts fine.

**Settings > Video Sites** shows the yt-dlp version in use and sets the default quality. The licenses of the included tools are inside the app, in `Contents/Resources/Licenses`.

**For developers:** to include newer versions, change the versions, addresses and checksums at the top of `scripts/fetch-tools.sh`. When the app runs without the included tools (for example with `swift run`), it uses copies installed with Homebrew instead (`brew install yt-dlp deno ffmpeg`).

On some networks YouTube asks to "confirm you're not a bot". Downloads started from the browser add-on pass your YouTube sign-in along (as a file only you can read, deleted as soon as yt-dlp finishes), which usually satisfies it. For addresses you add in the app itself, choose your browser under **Settings > Video Sites** so yt-dlp can read the sign-in there; macOS may ask for your password the first time. The same goes for Facebook videos that need you to be signed in: the add-on passes your Facebook sign-in along, and the browser chosen under **Settings > Video Sites** covers addresses added in the app.

YouTube's terms allow downloading only where YouTube offers a download button or the owner gave permission, for example your own videos or videos under a Creative Commons license. Paid and copy-protected videos are not downloaded. On Facebook too, download only videos that are yours or that you have permission to save.

## Use it from the Terminal

The command-line tool lives inside the app. To use it everywhere, link it once:

```bash
sudo ln -s /Applications/cDownloader.app/Contents/Helpers/cdownloader /usr/local/bin/cdownloader
```

It understands IDM's options, with either `-` or `/` in front:

```bash
cdownloader -d https://example.com/file.zip            # download, asking where to save
cdownloader -d https://example.com/file.zip -p ~/Desktop -n   # save to the Desktop, no questions
cdownloader -d https://example.com/file.zip -a         # add to the queue without starting
cdownloader -s                                         # start the main queue
```

`-f name` sets the file name and `-q` quits cDownloader after the download. If cDownloader is not open, the tool opens it in the background.

## Run the tests

```bash
swift test                          # the app's logic (downloads, queues, grabber and more)
cd Extension && node --test         # the browser add-on's rules
```

The tests run against small web and FTP servers started inside the test run, so they need no internet connection.

## How the project is laid out

| Folder | What is in it |
|---|---|
| `Sources/cDownloaderCore` | Everything that is not a screen: the download engine, FTP, HLS streams, queues, the scheduler, the site grabber, zip preview, saving, and the connection to the browser and Terminal |
| `Sources/cDownloader` | The Mac app's windows and menus (SwiftUI) |
| `Sources/cDownloaderHost` | The small helper that the browser add-on talks to |
| `Sources/cDownloaderCLI` | The `cdownloader` Terminal command |
| `Extension` | The Chrome, Edge and Brave add-on |
| `Tests` | Automated tests and the small test servers |
| `scripts` | Building the app and the installer, fetching the included video tools, and drawing the icons (`make-icons.swift`) |
| `Resources` | The app's icon and settings file, the license texts of the included tools, and the installer's "How to Install" note |
| `docs/feature-inventory.md` | Every IDM feature and where it is in cDownloader |

Your downloads list and settings are saved in `~/Library/Application Support/cDownloader`, next to the app's own up-to-date copy of yt-dlp.

## Known limits

- DASH video streams (separate audio and video tracks, used by some large video sites) are detected but not downloaded yet. YouTube is the exception, through yt-dlp.
- YouTube and Facebook downloads depend on yt-dlp. When either site changes something, they can fail until a fixed yt-dlp comes out and the app's daily check picks it up.
- In Facebook's feed, the "Download video" button appears only when the post links to its own video. If it does not show, open the video first (click its date or time), or right-click the link to the video and choose "Download with cDownloader".
- Live streams that have no end are not supported.
- The site grabber reads links from the page's HTML. It does not run the page's JavaScript, so links that scripts create are missed.
- FTP uses passive mode only. Encrypted FTP (FTPS) is not supported.
- The app's text is in English only, but it is ready for translation.
- "Force shut down" asks apps to quit like a normal shut down, so an app with unsaved work can still stop it.
- Windows-only parts of IDM (network drivers, Internet Explorer hooks, dial-up) have no Mac equivalent and were left out.
