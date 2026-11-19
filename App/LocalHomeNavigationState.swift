import Foundation

/// The Home button's destination is independent of the application's startup preference.
enum LocalHomeTarget: Codable, Equatable, Sendable {
    static let storageKey = "local.home.selected.v1"
    case builtin
    case source(LocalHomeSourceSelection)
    case html(String)

    enum Resolution: Equatable {
        case available(LocalHomeTarget), waiting, unavailable
    }

    var isValid: Bool {
        switch self {
        case .builtin: true
        case .source(let selection):
            !selection.origin.isEmpty && !selection.sourceKey.isEmpty && URL(string: selection.origin) != nil
        case .html(let id): !id.isEmpty && id != "builtin"
        }
    }

    func resolve(sources: [LocalHomeSourceSelection], htmlIDs: Set<String>, loadingGroups: Set<Bool>) -> Resolution {
        guard isValid else { return .unavailable }
        switch self {
        case .builtin: return .available(self)
        case .html(let id): return htmlIDs.contains(id) ? .available(self) : .unavailable
        case .source(let selection):
            if sources.contains(selection) { return .available(self) }
            return loadingGroups.contains(selection.python) ? .waiting : .unavailable
        }
    }

    func save(defaults: UserDefaults = .standard) throws {
        guard isValid else { throw CocoaError(.coderInvalidValue) }
        defaults.set(try JSONEncoder().encode(self), forKey: Self.storageKey)
    }

    static func load(defaults: UserDefaults = .standard) -> Self? {
        guard let data = defaults.data(forKey: storageKey), data.count <= 65_536,
              let value = try? JSONDecoder().decode(Self.self, from: data), value.isValid else { return nil }
        if case .source(let selection) = value {
            return .source(LocalHomeSourceSelection(origin: selection.origin, sourceKey: selection.sourceKey, python: selection.python))
        }
        return value
    }
}

struct LocalHomeTapState: Sendable {
    static let doubleTapInterval: TimeInterval = 0.32
    enum Action: Equatable { case showHome, chooseHome, ignored }
    private var previousTap: TimeInterval?

    init() {}

    mutating func tap(at time: TimeInterval, blocked: Bool = false) -> Action {
        guard !blocked, time.isFinite, time >= 0 else { reset(); return .ignored }
        if let previousTap, time >= previousTap, time - previousTap <= Self.doubleTapInterval {
            reset()
            return .chooseHome
        }
        previousTap = time
        return .showHome
    }

    mutating func reset() { previousTap = nil }
}
