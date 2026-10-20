import Foundation

public enum PluginHoliday: String, Codable, CaseIterable, Sendable {
    case newYear, valentines, presidents, stPatricks, easter, mothersDay, memorial, fathersDay
    case juneteenth, independence, labor, columbus, halloween, veterans, thanksgiving, christmas
    public var title: String {
        switch self {
        case .newYear: return "New Year’s Day"
        case .valentines: return "Valentine’s Day"
        case .presidents: return "Presidents’ Day"
        case .stPatricks: return "St. Patrick’s Day"
        case .easter: return "Easter"
        case .mothersDay: return "Mother’s Day"
        case .memorial: return "Memorial Day"
        case .fathersDay: return "Father’s Day"
        case .juneteenth: return "Juneteenth"
        case .independence: return "Independence Day"
        case .labor: return "Labor Day"
        case .columbus: return "Columbus Day"
        case .halloween: return "Halloween"
        case .veterans: return "Veterans Day"
        case .thanksgiving: return "Thanksgiving"
        case .christmas: return "Christmas Day"
        }
    }
    public var stageDays: Int { self == .christmas ? 12 : [.newYear,.halloween,.thanksgiving].contains(self) ? 7 : 5 }
    public var isLegacyScene: Bool { [.halloween,.thanksgiving,.christmas].contains(self) }
    public var needsUSCalendar: Bool { [.presidents,.memorial,.juneteenth,.independence,.labor,.columbus,.veterans,.thanksgiving].contains(self) }
    public var isFederal: Bool { needsUSCalendar || [.newYear,.christmas].contains(self) }
    public var isReflective: Bool { [.memorial,.veterans].contains(self) }

    /// Gregorian civil dates; Easter follows the Western ecclesiastical calendar.
    /// Workday observance shifts fixed federal dates only; no regional inference.
    public func date(year: Int, timeZone: TimeZone = .current, basis: PluginHolidayDateBasis = .actual) -> Date? {
        guard (1900...9999).contains(year) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        func fixed(_ month: Int, _ day: Int) -> Date? { calendar.date(from: DateComponents(year:year,month:month,day:day)) }
        func weekday(_ month: Int, _ weekday: Int, _ ordinal: Int) -> Date? {
            guard let first = fixed(month,1) else { return nil }
            if ordinal > 0 { return fixed(month,1+(weekday-calendar.component(.weekday,from:first)+7)%7+(ordinal-1)*7) }
            guard let range = calendar.range(of:.day,in:.month,for:first), let last = fixed(month,range.count) else { return nil }
            return fixed(month,range.count-(calendar.component(.weekday,from:last)-weekday+7)%7)
        }
        let actual: Date?
        switch self {
        case .newYear: actual=fixed(1,1)
        case .valentines: actual=fixed(2,14)
        case .presidents: actual=weekday(2,2,3)
        case .stPatricks: actual=fixed(3,17)
        case .easter:
            // Anonymous Gregorian computus (Meeus/Jones/Butcher).
            let a=year%19,b=year/100,c=year%100,d=b/4,e=b%4,f=(b+8)/25,g=(b-f+1)/3
            let h=(19*a+b-d-g+15)%30,i=c/4,k=c%4,l=(32+2*e+2*i-h-k)%7,m=(a+11*h+22*l)/451
            actual=fixed((h+l-7*m+114)/31,(h+l-7*m+114)%31+1)
        case .mothersDay: actual=weekday(5,1,2)
        case .memorial: actual=weekday(5,2,-1)
        case .fathersDay: actual=weekday(6,1,3)
        case .juneteenth: actual=fixed(6,19)
        case .independence: actual=fixed(7,4)
        case .labor: actual=weekday(9,2,1)
        case .columbus: actual=weekday(10,2,2)
        case .halloween: actual=fixed(10,31)
        case .veterans: actual=fixed(11,11)
        case .thanksgiving: actual=weekday(11,5,4)
        case .christmas: actual=fixed(12,25)
        }
        guard let actual, basis == .observedWorkday, isFederal else { return actual }
        let offset = calendar.component(.weekday,from:actual) == 7 ? -1 : calendar.component(.weekday,from:actual) == 1 ? 1 : 0
        return calendar.date(byAdding:.day,value:offset,to:actual)
    }
}
public enum PluginHolidayDateBasis: String, Codable, CaseIterable, Sendable { case actual, observedWorkday }
public enum PluginSeasonalLocale: String, Codable, CaseIterable, Sendable { case none, unitedStates }
public enum PluginSceneIntensity: String, Codable, CaseIterable, Sendable { case off, low, standard }
public struct PluginSeasonalPreferences: Codable, Equatable, Sendable {
    public var version = 1
    public var automatic = false
    // Existing selections stay intact when the optional calendar grows.
    public var holidays: Set<PluginHoliday> = [.halloween, .thanksgiving, .christmas]
    public var locale: PluginSeasonalLocale = .none
    public var intensity: PluginSceneIntensity = .low
    public var allowsExpandedCelebration = false
    public var dateBasis: PluginHolidayDateBasis = .actual
    public init() {}
    private enum CodingKeys: String, CodingKey { case version,automatic,holidays,locale,intensity,allowsExpandedCelebration,dateBasis }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        version = try c.decode(Int.self,forKey:.version)
        automatic = try c.decode(Bool.self,forKey:.automatic)
        holidays = try c.decode(Set<PluginHoliday>.self,forKey:.holidays)
        locale = try c.decode(PluginSeasonalLocale.self,forKey:.locale)
        intensity = try c.decode(PluginSceneIntensity.self,forKey:.intensity)
        allowsExpandedCelebration = try c.decode(Bool.self,forKey:.allowsExpandedCelebration)
        dateBasis = try c.decodeIfPresent(PluginHolidayDateBasis.self,forKey:.dateBasis) ?? .actual
    }
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
        let stages: [String]
        switch holiday {
        case .christmas: stages=["tree","present","star","lights","ribbon","secondPresent","ornaments","snow","garland","lantern","sparkles","celebration"]
        case .halloween: stages=["pumpkin","leaves","moon","secondPumpkin","stars","lantern","celebration"]
        case .thanksgiving: stages=["leaves","gourd","turkey","harvest","lantern","autumnBranches","celebration"]
        default: stages=["scene","accent","ribbon","lights","occasion","stars","celebration"]
        }
        return Array(stages.prefix(max(0,day)))
    }
    public var celebrationKey: String { "\(holiday.rawValue).\(year)" }
    public var particleCap: Int { intensity == .off || holiday.isReflective ? 0 : intensity == .low ? min(day,6) : min(day*2,24) }
    public func validate() throws {
        guard version == 1, (1900...9999).contains(year), totalDays == holiday.stageDays,
              (1...totalDays).contains(day) else { throw ModuleProblem("Invalid seasonal scene.") }
    }
    /// A local review value, without enabling a preference or authorizing a celebration.
    public static func preview(holiday:PluginHoliday,year:Int = 2026,day:Int,intensity:PluginSceneIntensity = .standard) throws -> Self {
        let value=Self(holiday:holiday,year:year,day:day,totalDays:holiday.stageDays,intensity:intensity)
        try value.validate();return value
    }
    public static func resolve(date: Date, timeZone: TimeZone = .current, preferences: PluginSeasonalPreferences) -> Self? {
        guard preferences.automatic, (try? preferences.validate()) != nil else { return nil }
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=timeZone
        let year=calendar.component(.year,from:date),today=calendar.startOfDay(for:date)
        guard (1900...9999).contains(year) else { return nil }
        var choices: [(Int,Self)] = []
        for candidateYear in [year-1,year,year+1] where (1900...9999).contains(candidateYear) {
            for holiday in PluginHoliday.allCases where preferences.holidays.contains(holiday) {
                if holiday.needsUSCalendar && preferences.locale != .unitedStates { continue }
                guard let target=holiday.date(year:candidateYear,timeZone:timeZone,basis:preferences.dateBasis),
                      let distance=calendar.dateComponents([.day],from:today,to:target).day,
                      (0..<holiday.stageDays).contains(distance) else { continue }
                choices.append((distance,Self(holiday:holiday,year:candidateYear,day:holiday.stageDays-distance,totalDays:holiday.stageDays,intensity:preferences.intensity)))
            }
        }
        // Closest occasion wins; deterministic ties avoid two scenes at once.
        return choices.sorted { $0.0 == $1.0 ? $0.1.holiday.rawValue < $1.1.holiday.rawValue : $0.0 < $1.0 }.first?.1
    }
}
/// A platform adapter may present an expanded scene only after an explicit
/// gesture. Preview never consumes the receipt or starts a celebration.
public struct PluginCelebrationLedger: Codable, Equatable, Sendable {
    public private(set) var keys: Set<String> = []
    public init() {}
    private enum CodingKeys:String,CodingKey { case keys }
    public init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        keys=try c.decode(Set<String>.self,forKey:.keys)
        guard keys.count <= 64,keys.allSatisfy({ key in
            let parts=key.split(separator:".",omittingEmptySubsequences:false)
            return parts.count == 2 && PluginHoliday(rawValue:String(parts[0])) != nil && Int(parts[1]).map { (1900...9999).contains($0) } == true
        }) else { throw ModuleProblem("Invalid celebration receipts.") }
    }
    public mutating func request(scene: PluginSeasonalScene, preferences: PluginSeasonalPreferences, explicitGesture: Bool, preview: Bool = false) -> Bool {
        guard (try? scene.validate()) != nil, preferences.automatic, preferences.holidays.contains(scene.holiday),
              (!scene.holiday.needsUSCalendar || preferences.locale == .unitedStates),
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
