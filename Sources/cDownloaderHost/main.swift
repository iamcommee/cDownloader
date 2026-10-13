import cDownloaderCore
import Foundation

/// Chrome native messaging host: reads framed JSON requests from the cDownloader browser add-on on stdin,
/// forwards them to the app over the local socket (opening the app if needed) and writes framed replies to stdout.
let input = FileHandle.standardInput
let output = FileHandle.standardOutput
var decoder = NativeMessagingCodec.Decoder()

func reply(_ value: IPCReply) {
    if let frame = try? NativeMessagingCodec.encode(value) {
        output.write(frame)
    }
}

/// Settings straight from disk, so the add-on can still decide what to take over while the app is closed.
func configFromDisk() -> BrowserConfig {
    let store = JSONStore(fileURL: AppPaths.settingsFile, defaultValue: { AppSettings() })
    return BrowserConfig(settings: store.load())
}

func handle(_ message: Data) -> IPCReply {
    guard let request = (try? JSONDecoder().decode(IPCRequest.self, from: message))?.sanitizedForBrowser() else {
        return IPCReply(ok: false, error: "Unknown message")
    }
    switch request.type {
    case .ping:
        return IPCReply(ok: true)
    case .getConfig:
        if let live = try? IPCClient.send(request, socketPath: AppPaths.socketPath, timeout: 2), live.ok {
            return live
        }
        return IPCReply(ok: true, config: configFromDisk())
    case .add, .startQueue, .showWindow:
        do {
            return try AppLauncher.send(request)
        } catch let error as IPCError {
            return IPCReply(ok: false, error: error.message)
        } catch {
            return IPCReply(ok: false, error: error.localizedDescription)
        }
    }
}

while true {
    let chunk = input.availableData
    if chunk.isEmpty { break }
    let messages: [Data]
    do {
        messages = try decoder.append(chunk)
    } catch {
        reply(IPCReply(ok: false, error: "Malformed message"))
        exit(1)
    }
    for message in messages {
        reply(handle(message))
    }
}
