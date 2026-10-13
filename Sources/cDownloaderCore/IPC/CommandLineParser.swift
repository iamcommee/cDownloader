import Foundation

public enum CLICommand: Sendable, Equatable {
    case download(url: URL, folder: String?, fileName: String?, quitAfter: Bool, silent: Bool, addOnly: Bool)
    case startQueue
    case help
}

public enum CLIError: Error, Equatable {
    case usage(String)
}

/// IDM-compatible command line: `-d URL [-p folder] [-f name] [-q] [-n] [-a]` or `-s`; "/d" style also works.
public enum CommandLineParser {
    public static let usageExitCode: Int32 = 64
    public static let unavailableExitCode: Int32 = 69

    public static let usageText = """
    Usage:
      cdownloader -d URL [-p folder] [-f filename] [-q] [-n] [-a]
      cdownloader -s

      -d URL       download a file
      -p folder    folder to save into
      -f filename  name to save as
      -q           quit cDownloader after this download succeeds
      -n           silent mode: no questions
      -a           add to the download queue without starting
      -s           start the main download queue
    Slash forms such as /d and /p are accepted too.
    """

    public static func parse(_ arguments: [String]) throws -> CLICommand {
        guard !arguments.isEmpty else { throw CLIError.usage(usageText) }
        var url: URL?
        var folder: String?
        var fileName: String?
        var quitAfter = false, silent = false, addOnly = false, startQueue = false, help = false
        var index = 0

        func value(for flag: String) throws -> String {
            index += 1
            guard index < arguments.count, option(arguments[index]) == nil else {
                throw CLIError.usage("Option \(flag) needs a value.\n\n\(usageText)")
            }
            return arguments[index]
        }

        while index < arguments.count {
            let raw = arguments[index]
            guard let letter = option(raw) else { throw CLIError.usage("Unexpected argument: \(raw)\n\n\(usageText)") }
            switch letter {
            case "d":
                let text = try value(for: raw)
                guard let parsed = URL(string: text), let scheme = parsed.scheme?.lowercased(),
                      ["http", "https", "ftp"].contains(scheme), parsed.host?.isEmpty == false
                else { throw CLIError.usage("Not a valid download address: \(text)") }
                url = parsed
            case "p": folder = try value(for: raw)
            case "f": fileName = try value(for: raw)
            case "q": quitAfter = true
            case "n": silent = true
            case "a": addOnly = true
            case "s": startQueue = true
            case "h": help = true
            default: throw CLIError.usage("Unknown option: \(raw)\n\n\(usageText)")
            }
            index += 1
        }

        if help { return .help }
        let downloadOptions = folder != nil || fileName != nil || quitAfter || silent || addOnly
        if startQueue {
            guard url == nil, !downloadOptions else { throw CLIError.usage("-s cannot be combined with download options.\n\n\(usageText)") }
            return .startQueue
        }
        guard let url else { throw CLIError.usage("Options -p, -f, -q, -n and -a only work together with -d URL.\n\n\(usageText)") }
        return .download(url: url, folder: folder, fileName: fileName, quitAfter: quitAfter, silent: silent, addOnly: addOnly)
    }

    /// "-d" or "/d" -> "d"; "--help", "-help" and "/?" -> "h"; anything else is not an option.
    private static func option(_ argument: String) -> Character? {
        if ["--help", "-help", "/?", "-?"].contains(argument) { return "h" }
        guard argument.count == 2, let first = argument.first, first == "-" || first == "/" else { return nil }
        return argument.last.map { Character($0.lowercased()) }
    }
}
