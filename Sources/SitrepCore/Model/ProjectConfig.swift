import Foundation

/// A project's profiling configuration, read from `.sitrep/project.json`.
///
/// JSON rather than YAML because `JSONDecoder` is built in and YAML is not
/// (ARCHITECTURE #8). The cost is no comments, mitigated by `sitrep init`
/// generating the file rather than expecting it to be typed by hand.
public struct ProjectConfig: Codable, Sendable, Equatable {

    public let project: String
    public let scenarios: [Scenario]
    public let externalServices: [ExternalService]
    public let budget: Budget?

    /// One measurable way of running the project.
    ///
    /// A requirement without its workload definition is nearly as useless as a
    /// guess, so the command is part of the published record (SPEC).
    public struct Scenario: Codable, Sendable, Equatable {
        public let name: String
        /// argv, not a shell string — no quoting rules to get wrong, and no
        /// shell process interposed between us and the workload.
        public let command: [String]
        public let runs: Int?
        public let workingDirectory: String?

        public init(
            name: String, command: [String], runs: Int? = nil, workingDirectory: String? = nil
        ) {
            self.name = name
            self.command = command
            self.runs = runs
            self.workingDirectory = workingDirectory
        }
    }

    /// A pre-existing daemon that holds resources on the project's behalf.
    ///
    /// This is the case naive tree attribution gets wrong: when a project calls
    /// Ollama or LM Studio, the model's memory lives in a daemon that was
    /// already running, outside the spawned tree, and the wrapped client shows
    /// near-zero RAM (ARCHITECTURE #10).
    public struct ExternalService: Codable, Sendable, Equatable {
        public let name: String
        /// Substring matched against the executable path. A substring rather
        /// than a glob keeps config simple and covers the real cases —
        /// `Ollama.app`, `LM Studio`, `mlx`.
        public let executableContains: String

        public init(name: String, executableContains: String) {
            self.name = name
            self.executableContains = executableContains
        }
    }

    /// Declared limits. Recorded and compared against, never enforced — the
    /// policy engine ships dry-run and must be explicitly armed
    /// (ARCHITECTURE #12), and it is not built yet.
    public struct Budget: Codable, Sendable, Equatable {
        public let maxRAMBytes: UInt64?
        public let maxSwapOutsPerSecond: Double?
        public let maxCPU: Double?

        public init(
            maxRAMBytes: UInt64? = nil,
            maxSwapOutsPerSecond: Double? = nil,
            maxCPU: Double? = nil
        ) {
            self.maxRAMBytes = maxRAMBytes
            self.maxSwapOutsPerSecond = maxSwapOutsPerSecond
            self.maxCPU = maxCPU
        }
    }

    public init(
        project: String,
        scenarios: [Scenario],
        externalServices: [ExternalService] = [],
        budget: Budget? = nil
    ) {
        self.project = project
        self.scenarios = scenarios
        self.externalServices = externalServices
        self.budget = budget
    }

    /// Omitted arrays decode as empty rather than failing, so a minimal config
    /// with only a project and one scenario is valid.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        project = try container.decode(String.self, forKey: .project)
        scenarios = try container.decode([Scenario].self, forKey: .scenarios)
        externalServices = try container.decodeIfPresent(
            [ExternalService].self, forKey: .externalServices
        ) ?? []
        budget = try container.decodeIfPresent(Budget.self, forKey: .budget)
    }

    // MARK: - Files

    public static let directoryName = ".sitrep"
    public static let fileName = "project.json"

    public static func path(in directory: String) -> String {
        "\(directory)/\(directoryName)/\(fileName)"
    }

    public static func load(from directory: String) throws -> ProjectConfig {
        let file = path(in: directory)
        guard FileManager.default.fileExists(atPath: file) else {
            throw ConfigError.notFound(file)
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: file))
        do {
            return try JSONDecoder().decode(ProjectConfig.self, from: data)
        } catch {
            throw ConfigError.malformed(file, underlying: "\(error)")
        }
    }

    public func write(to directory: String) throws {
        try FileManager.default.createDirectory(
            atPath: "\(directory)/\(Self.directoryName)", withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: URL(fileURLWithPath: Self.path(in: directory)))
    }

    public func scenario(named name: String?) -> Scenario? {
        guard let name else { return scenarios.first }
        return scenarios.first { $0.name == name }
    }

    public enum ConfigError: Error, CustomStringConvertible {
        case notFound(String)
        case malformed(String, underlying: String)
        case noSuchScenario(String, available: [String])

        public var description: String {
            switch self {
            case let .notFound(path):
                "no config at \(path) — run 'sitrep init' to create one"
            case let .malformed(path, underlying):
                "could not parse \(path): \(underlying)"
            case let .noSuchScenario(name, available):
                "no scenario '\(name)'; available: \(available.joined(separator: ", "))"
            }
        }
    }
}
