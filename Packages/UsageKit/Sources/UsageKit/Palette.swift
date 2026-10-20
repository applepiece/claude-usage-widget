import AppKit

@MainActor public let clawdSalmon = NSColor(red: 0.86, green: 0.47, blue: 0.34, alpha: 1)
@MainActor public let usageOrange = NSColor(red: 0.94, green: 0.50, blue: 0.19, alpha: 1)
@MainActor public let usagePurple = NSColor(red: 0.68, green: 0.35, blue: 0.78, alpha: 1)
@MainActor public let usageRed = NSColor(red: 0.94, green: 0.28, blue: 0.44, alpha: 1)

@MainActor public let usageGreen = NSColor(red: 0.19, green: 0.66, blue: 0.36, alpha: 1)
@MainActor public let usageAmber = NSColor(red: 0.87, green: 0.57, blue: 0.10, alpha: 1)
@MainActor public func powerColor(_ used: Double?) -> NSColor {
    guard let used else { return .secondaryLabelColor }
    return used >= 90 ? usageRed : (used >= 70 ? usageAmber : usageGreen)
}

