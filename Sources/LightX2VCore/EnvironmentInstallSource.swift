import Foundation

public enum EnvironmentInstallSource: String, CaseIterable, Identifiable, Sendable {
    case pypi, tsinghua
    public var id: String { rawValue }
    public var title: String { self == .pypi ? "pypi.org" : "pypi.tsinghua" }
    public var pipIndex: String {
        self == .pypi ? "https://pypi.org/simple" : "https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple"
    }
    public var distribution: MinicondaDistribution {
        if self == .pypi { return .official }
        return MinicondaDistribution(
            url: URL(string: "https://mirrors.tuna.tsinghua.edu.cn/anaconda/miniconda/")!.appendingPathComponent(MinicondaDistribution.official.url.lastPathComponent),
            sha256: MinicondaDistribution.official.sha256)
    }
}
