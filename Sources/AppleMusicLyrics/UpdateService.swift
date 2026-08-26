import CryptoKit
import Foundation

struct SemanticVersion: Comparable, Equatable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingPrefix("v")
        let core = normalized.split(separator: "-", maxSplits: 1).first ?? ""
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]),
              major >= 0, minor >= 0, patch >= 0 else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

struct AppUpdate: Equatable {
    let version: SemanticVersion
    let releasePageURL: URL
    let downloadURL: URL
    let assetName: String
    let checksumURL: URL
}

enum UpdateServiceError: LocalizedError, Equatable {
    case invalidCurrentVersion
    case invalidResponse
    case releaseDataInvalid
    case downloadUnavailable
    case checksumUnavailable
    case checksumMismatch
    case unableToSaveDownload

    var errorDescription: String? {
        switch self {
        case .invalidCurrentVersion: return "无法读取当前应用版本。"
        case .invalidResponse: return "更新服务器返回了无效响应。"
        case .releaseDataInvalid: return "无法解析最新版本信息。"
        case .downloadUnavailable: return "最新版本没有可用的 macOS 安装镜像。"
        case .checksumUnavailable: return "无法验证更新文件的完整性。"
        case .checksumMismatch: return "更新文件校验失败，下载内容可能不完整。"
        case .unableToSaveDownload: return "无法将更新文件保存到“下载”文件夹。"
        }
    }
}

final class UpdateService: @unchecked Sendable {
    static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/Takpap/apple-music-lyrics/releases/latest"
    )!

    private let session: URLSession
    private let currentVersion: SemanticVersion?
    private let downloadsDirectory: URL

    init(
        session: URLSession = .shared,
        currentVersion: String? = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String,
        downloadsDirectory: URL? = nil
    ) {
        self.session = session
        self.currentVersion = currentVersion.flatMap(SemanticVersion.init)
        self.downloadsDirectory = downloadsDirectory
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    func checkForUpdate() async throws -> AppUpdate? {
        guard currentVersion != nil else { throw UpdateServiceError.invalidCurrentVersion }
        var request = request(for: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        return try availableUpdate(from: data)
    }

    func availableUpdate(from data: Data) throws -> AppUpdate? {
        guard let currentVersion else { throw UpdateServiceError.invalidCurrentVersion }
        let release: GitHubRelease
        do {
            release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateServiceError.releaseDataInvalid
        }
        guard !release.draft, !release.prerelease,
              let version = SemanticVersion(release.tagName),
              version > currentVersion else { return nil }

        let dmg = release.assets.first {
            $0.name.hasSuffix("-macos-universal.dmg") && Self.isTrustedReleaseURL($0.downloadURL)
        }
        let checksum = release.assets.first {
            $0.name == "SHA256SUMS.txt" && Self.isTrustedReleaseURL($0.downloadURL)
        }
        guard let dmg else { throw UpdateServiceError.downloadUnavailable }
        guard let checksum else { throw UpdateServiceError.checksumUnavailable }
        guard Self.isTrustedReleaseURL(release.htmlURL) else {
            throw UpdateServiceError.releaseDataInvalid
        }
        return AppUpdate(
            version: version,
            releasePageURL: release.htmlURL,
            downloadURL: dmg.downloadURL,
            assetName: dmg.name,
            checksumURL: checksum.downloadURL
        )
    }

    func download(_ update: AppUpdate) async throws -> URL {
        guard Self.isTrustedReleaseURL(update.downloadURL),
              Self.isTrustedReleaseURL(update.checksumURL) else {
            throw UpdateServiceError.releaseDataInvalid
        }
        let (checksumData, checksumResponse) = try await session.data(
            for: request(for: update.checksumURL)
        )
        try Self.validate(checksumResponse)
        guard let checksumText = String(data: checksumData, encoding: .utf8),
              let expectedHash = Self.expectedSHA256(
                in: checksumText,
                for: update.assetName
              ) else { throw UpdateServiceError.checksumUnavailable }

        let (temporaryURL, downloadResponse) = try await session.download(
            for: request(for: update.downloadURL)
        )
        try Self.validate(downloadResponse)
        let data = try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
        let actualHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actualHash.caseInsensitiveCompare(expectedHash) == .orderedSame else {
            throw UpdateServiceError.checksumMismatch
        }

        let destination = uniqueDestination(for: update.assetName)
        do {
            try FileManager.default.createDirectory(
                at: downloadsDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            return destination
        } catch {
            throw UpdateServiceError.unableToSaveDownload
        }
    }

    static func expectedSHA256(in contents: String, for assetName: String) -> String? {
        for line in contents.components(separatedBy: .newlines) {
            let fields = line.split(whereSeparator: \Character.isWhitespace)
            guard fields.count >= 2 else { continue }
            let hash = String(fields[0])
            let name = fields.dropFirst().joined(separator: " ").trimmingPrefix("*")
            if name == assetName,
               hash.count == 64,
               hash.allSatisfy(\.isHexDigit) {
                return hash.lowercased()
            }
        }
        return nil
    }

    private func uniqueDestination(for assetName: String) -> URL {
        let original = downloadsDirectory.appendingPathComponent(assetName)
        guard FileManager.default.fileExists(atPath: original.path) else { return original }
        let base = original.deletingPathExtension().lastPathComponent
        let pathExtension = original.pathExtension
        for number in 2...999 {
            let name = pathExtension.isEmpty
                ? "\(base) \(number)"
                : "\(base) \(number).\(pathExtension)"
            let candidate = downloadsDirectory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return downloadsDirectory.appendingPathComponent(UUID().uuidString + ".dmg")
    }

    private func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(
            "Apple-Music-Lyrics/\(currentVersion?.description ?? "unknown")",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 30
        return request
    }

    private static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse,
              (200...299).contains(response.statusCode) else {
            throw UpdateServiceError.invalidResponse
        }
    }

    private static func isTrustedReleaseURL(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com"
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case draft
        case prerelease
        case assets
    }
}

private struct GitHubReleaseAsset: Decodable {
    let name: String
    let downloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case downloadURL = "browser_download_url"
    }
}

private extension String {
    func trimmingPrefix(_ prefix: Character) -> String {
        first == prefix ? String(dropFirst()) : self
    }

    func trimmingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}
