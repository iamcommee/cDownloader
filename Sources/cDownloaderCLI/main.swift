import cDownloaderCore
import Foundation

/// `cdownloader`: starts downloads in cDownloader from the Terminal (IDM's `idman /d URL` equivalent).
func printError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

let command: CLICommand
do {
    command = try CommandLineParser.parse(Array(CommandLine.arguments.dropFirst()))
} catch CLIError.usage(let text) {
    printError(text)
    exit(CommandLineParser.usageExitCode)
} catch {
    printError(error.localizedDescription)
    exit(CommandLineParser.usageExitCode)
}

var request: IPCRequest
switch command {
case .help:
    print(CommandLineParser.usageText)
    exit(0)
case .startQueue:
    request = IPCRequest(type: .startQueue)
case .download(let url, let folder, let fileName, let quitAfter, let silent, let addOnly):
    request = IPCRequest(type: .add, downloads: [IncomingDownload(url: url, fileName: fileName)])
    request.folder = folder.map { ($0 as NSString).expandingTildeInPath }
    request.silent = silent
    request.addOnly = addOnly
    request.quitAfter = quitAfter
}

do {
    let reply = try AppLauncher.send(request)
    if !reply.ok {
        printError(reply.error ?? "cDownloader refused the request")
        exit(1)
    }
} catch let error as IPCError {
    printError(error.message)
    exit(CommandLineParser.unavailableExitCode)
} catch {
    printError(error.localizedDescription)
    exit(CommandLineParser.unavailableExitCode)
}
