import Foundation
import Darwin

enum MacHardware {
    /// Read once on the running Mac, independently of Python or model checks.
    static let sidebarDescription: String = {
        guard let brand = cpuBrand(), brand.hasPrefix("Apple ") else { return "Apple Silicon · MPS" }
        return "\(brand) · MPS"
    }()

    private static func cpuBrand() -> String? {
        let key = "machdep.cpu.brand_string"
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let result = bytes.withUnsafeMutableBytes {
            sysctlbyname(key, $0.baseAddress, &size, nil, 0)
        }
        guard result == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
