import Foundation

if CommandLine.arguments.contains("--help") {
    print(BenchOptions.usage)
    exit(0)
}

do {
    let options = try BenchOptions.parse(CommandLine.arguments)
    let runner = BenchRunner(options: options)
    let code = try await runner.run()
    exit(code)
} catch let failure as BenchFailure {
    BenchIO.printError("KoeBridgeBench: \(failure.localizedDescription)")
    if case .usage = failure {
        exit(2)
    }
    exit(1)
} catch {
    BenchIO.printError("KoeBridgeBench: \(error.localizedDescription)")
    exit(1)
}
