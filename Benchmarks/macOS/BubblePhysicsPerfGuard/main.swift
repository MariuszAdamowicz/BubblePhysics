import Foundation

exit(await PerfGuard.run(arguments: Array(CommandLine.arguments.dropFirst())))
