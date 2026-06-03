import Foundation
import HeartechoAudio

struct HelperArguments {
    var graphURL = HeartechoHelperRuntime.defaultGraphURL()
    var frameCount = 512
    var publishAudio = false
    var createStarterGraphIfMissing = false
    var configSharedMemoryName = "/HeartechoHALSharedConfig"
    var audioSharedMemoryName = "/HeartechoHALAudioBuffers"
    var serve = false
    var iterationLimit: Int?
    var intervalMilliseconds = 10
}

do {
    let arguments = try parseArguments(Array(CommandLine.arguments.dropFirst()))
    let publicationOptions = HeartechoHelperRuntimeOptions(
        graphURL: arguments.graphURL,
        frameCount: arguments.frameCount,
        publishAudio: arguments.publishAudio,
        createStarterGraphIfMissing: arguments.createStarterGraphIfMissing,
        configSharedMemoryName: arguments.configSharedMemoryName,
        audioSharedMemoryName: arguments.audioSharedMemoryName
    )

    if arguments.serve {
        let runReport = try HeartechoHelperRuntime.run(options: HeartechoHelperRunLoopOptions(
            publicationOptions: publicationOptions,
            intervalMilliseconds: arguments.intervalMilliseconds,
            iterationLimit: arguments.iterationLimit
        )) { report in
            printPublication(report, prefix: "iteration")
        }

        print("HeartechoHelper run loop")
        print("- iterations: \(runReport.iterationCount)")
        print("- interval: \(runReport.intervalMilliseconds) ms")
        print("- frames: \(runReport.totalPublishedFrameCount)")
        if let lastPublication = runReport.lastPublication {
            print("- last graph: \(lastPublication.graphURL.path)")
        }
    } else {
        let report = try HeartechoHelperRuntime.publish(options: publicationOptions)
        print("HeartechoHelper publication")
        printPublication(report)
    }
} catch HelperError.helpRequested {
    printUsage()
} catch {
    fputs("HeartechoHelper failed: \(error)\n", stderr)
    printUsage()
    exit(1)
}

private func parseArguments(_ arguments: [String]) throws -> HelperArguments {
    var parsed = HelperArguments()
    var index = 0

    while index < arguments.count {
        let argument = arguments[index]

        switch argument {
        case "--help", "-h":
            throw HelperError.helpRequested
        case "--graph":
            parsed.graphURL = URL(fileURLWithPath: try value(after: argument, in: arguments, index: &index))
        case "--frames":
            let rawValue = try value(after: argument, in: arguments, index: &index)
            guard let frameCount = Int(rawValue), frameCount >= 0 else {
                throw HelperError.invalidValue(option: argument, value: rawValue)
            }
            parsed.frameCount = frameCount
        case "--publish-audio":
            parsed.publishAudio = true
        case "--init-starter-graph":
            parsed.createStarterGraphIfMissing = true
        case "--config-shm":
            parsed.configSharedMemoryName = try value(after: argument, in: arguments, index: &index)
        case "--audio-shm":
            parsed.audioSharedMemoryName = try value(after: argument, in: arguments, index: &index)
        case "--serve":
            parsed.serve = true
        case "--iterations":
            let rawValue = try value(after: argument, in: arguments, index: &index)
            guard let iterationLimit = Int(rawValue), iterationLimit > 0 else {
                throw HelperError.invalidValue(option: argument, value: rawValue)
            }
            parsed.iterationLimit = iterationLimit
        case "--interval-ms":
            let rawValue = try value(after: argument, in: arguments, index: &index)
            guard let intervalMilliseconds = Int(rawValue), intervalMilliseconds > 0 else {
                throw HelperError.invalidValue(option: argument, value: rawValue)
            }
            parsed.intervalMilliseconds = intervalMilliseconds
        default:
            throw HelperError.unknownOption(argument)
        }

        index += 1
    }

    return parsed
}

private func value(after option: String, in arguments: [String], index: inout Int) throws -> String {
    let valueIndex = index + 1
    guard arguments.indices.contains(valueIndex) else {
        throw HelperError.missingValue(option)
    }

    index = valueIndex
    return arguments[valueIndex]
}

private func printPublication(_ report: HeartechoHelperPublicationReport, prefix: String? = nil) {
    if let prefix {
        print("\(prefix): \(report.enabledDeviceCount)/\(report.deviceCount) devices, frames \(report.audioPublication?.totalPublishedFrameCount ?? 0)")
        return
    }

    print("- graph: \(report.graphURL.path)")
    print("- devices: \(report.enabledDeviceCount)/\(report.deviceCount) enabled")
    print("- config shared memory: \(report.configSharedMemoryName) (\(report.configByteCount) bytes)")
    if let audioPublication = report.audioPublication {
        print("- audio shared memory: \(audioPublication.sharedMemoryName ?? "-") (\(audioPublication.sharedMemoryByteCount ?? 0) bytes)")
        print("- audio buffers: \(audioPublication.publications.count), frames: \(audioPublication.totalPublishedFrameCount), live shared: \(audioPublication.didPublishSharedMemory)")
    } else {
        print("- audio shared memory: skipped")
    }
}

private func printUsage() {
    print("""
    Usage: swift run HeartechoHelper [options]

    Options:
      --graph PATH          RoutingGraph.json path. Defaults to Application Support/Heartecho/RoutingGraph.json.
      --publish-audio       Render silence through the graph and write live HAL audio shared memory.
      --init-starter-graph  Create a starter graph at --graph when it does not exist.
      --frames COUNT        Render frame count for --publish-audio. Defaults to 512.
      --config-shm NAME     POSIX shared-memory name for HAL config. Defaults to /HeartechoHALSharedConfig.
      --audio-shm NAME      POSIX shared-memory name for HAL audio. Defaults to /HeartechoHALAudioBuffers.
      --serve               Keep publishing config/audio in a run loop.
      --iterations COUNT    Stop --serve after COUNT iterations. Omit for continuous service mode.
      --interval-ms COUNT   Delay between --serve iterations. Defaults to 10 ms.
      --help                Show this help.
    """)
}

private enum HelperError: Error, CustomStringConvertible {
    case helpRequested
    case missingValue(String)
    case invalidValue(option: String, value: String)
    case unknownOption(String)

    var description: String {
        switch self {
        case .helpRequested:
            return "Help requested."
        case let .missingValue(option):
            return "Missing value for \(option)."
        case let .invalidValue(option, value):
            return "Invalid value '\(value)' for \(option)."
        case let .unknownOption(option):
            return "Unknown option \(option)."
        }
    }
}
