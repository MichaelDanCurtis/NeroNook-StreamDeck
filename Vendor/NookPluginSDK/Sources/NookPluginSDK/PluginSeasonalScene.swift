import Foundation

public enum PluginHoliday: String, Codable, CaseIterable, Sendable { case halloween, thanksgiving, christmas }
public enum PluginSeasonalLocale: String, Codable, CaseIterable, Sendable { case none, unitedStates }
public enum PluginSceneIntensity: String, Codable, CaseIterable, Sendable { case off, low, standard }
public struct PluginSeasonalPreferences: Codable, Equatable, Sendable {
    public var version = 1
    public var automatic = false
    public var holidays: Set<PluginHoliday> = [.halloween, .thanksgiving, .christmas]
    public var locale: PluginSeasonalLocale = .none
    public var intensity: PluginSceneIntensity = .low
    public var allowsExpandedCelebration = false
    public init() {}
    public func validate() throws { guard version == 1 else { throw ModuleProblem("Unsupported seasonal preferences.") } }
}
/// Passive scene data. It cannot open a window, take focus or request capture.
public struct PluginSeasonalScene: Codable, Equatable, Sendable {
    public var version = 1
    public var holiday: PluginHoliday
    public var year: Int
    public var day: Int
    public var totalDays: Int
    public var intensity: PluginSceneIntensity
    public var isHoliday: Bool { day == totalDays }
    public var decorations: [String] {
        switch holiday {
        case .christmas:
            let stages = ["tree", "present", "star", "lights", "ribbon", "secondPresent", "ornaments", "snow", "garland", "lantern", "sparkles", "celebration"]
            return Array(stages.prefix(day))
        case .halloween: return Array(["pumpkin", "leaves", "moon", "secondPumpkin", "stars", "lantern", "celebration"].prefix(day))
        case .thanksgiving: return Array(["leaves", "gourd", "turkey", "harvest", "lantern", "autumnBranches", "celebration"].prefix(day))
        }
    }
    /// Same holiday/year across timezone changes: never duplicate a celebration.
    public var celebrationKey: String { "\(holiday.rawValue).\(year)" }
    public var particleCap: Int { intensity == .off ? 0 : intensity == .low ? min(day, 6) : min(day * 2, 24) }
    public func validate() throws {
        guard version == 1, (1900...9999).contains(year), totalDays == (holiday == .christmas ? 12 : 7), (1...totalDays).contains(day) else { throw ModuleProblem("Invalid seasonal scene.") }
    }
    public static func resolve(date: Date, timeZone: TimeZone = .current, preferences: PluginSeasonalPreferences) -> Self? {
        guard preferences.automatic, (try? preferences.validate()) != nil else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let year = calendar.component(.year, from: date), today = calendar.startOfDay(for: date)
        guard (1900...9999).contains(year) else { return nil }
        for holiday in PluginHoliday.allCases where preferences.holidays.contains(holiday) {
            if holiday == .thanksgiving && preferences.locale != .unitedStates { continue }
            let month = holiday == .halloween ? 10 : holiday == .thanksgiving ? 11 : 12
            var day = holiday == .halloween ? 31 : 25
            if holiday == .thanksgiving {
                guard let first = calendar.date(from: DateComponents(year: year, month: 11, day: 1)) else { continue }
                day = 1 + (5 - calendar.component(.weekday, from: first) + 7) % 7 + 21
            }
            guard let target = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                  let distance = calendar.dateComponents([.day], from: today, to: target).day else { continue }
            let count = holiday == .christmas ? 12 : 7
            if (0..<count).contains(distance) { return Self(holiday: holiday, year: year, day: count - distance, totalDays: count, intensity: preferences.intensity) }
        }
        return nil
    }
}
/// A platform adapter may present an expanded scene only after an explicit
/// gesture. Preview never consumes the receipt or starts a celebration.
public struct PluginCelebrationLedger: Codable, Equatable, Sendable {
    public private(set) var keys: Set<String> = []
    public init() {}
    public mutating func request(scene: PluginSeasonalScene, preferences: PluginSeasonalPreferences, explicitGesture: Bool, preview: Bool = false) -> Bool {
        guard (try? scene.validate()) != nil, preferences.automatic, preferences.holidays.contains(scene.holiday),
              (scene.holiday != .thanksgiving || preferences.locale == .unitedStates),
              preferences.allowsExpandedCelebration, explicitGesture, scene.isHoliday, !preview,
              !keys.contains(scene.celebrationKey), keys.count < 64 else { return false }
        keys.insert(scene.celebrationKey); return true
    }
}

/// A finite entrance, never a repeating seasonal clock. Native adapters cancel
/// immediately on hidden/occluded/accessibility state and keep static decoration.
public enum PluginSeasonalAnimationPolicy {
    public static func duration(intensity: PluginSceneIntensity, visible: Bool, reducedMotion: Bool, reducedTransparency: Bool, increasedContrast: Bool) -> Double {
        guard visible, !reducedMotion, !reducedTransparency, !increasedContrast else { return 0 }
        return intensity == .off ? 0 : intensity == .low ? 0.8 : 1.2
    }
}
