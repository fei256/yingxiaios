import Foundation

@MainActor final class LocalMediaBadgeImporter {
    private let defaults: UserDefaults
    private let session: URLSession
    private var revision = UUID()
    private var work: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults; self.session = session
    }
    @discardableResult func start(address: String,
        completion: @escaping @MainActor (Result<LocalMediaBadgeStore, Error>) -> Void) throws -> Bool {
        guard work == nil else { return false }
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil, url.fragment == nil else {
            throw LocalMediaBadgeStore.BadgeError.invalidAddress
        }
        let previous = LocalMediaBadgeStore.load(defaults: defaults).sources.first { $0.address == address }
        let active = UUID(); revision = active
        work = Task { [weak self] in
            guard let self else { return }
            defer { if self.revision == active { self.work = nil } }
            do {
                let configuration = self.session.configuration
                let loading = Task.detached(priority: .userInitiated) {
                    let data = try await BoundedHTTPResponse.data(for: URLRequest(url: url, timeoutInterval: 30),
                        configuration: configuration, maximumBytes: LocalMediaBadgeStore.maximumDataBytes)
                    try Task.checkCancellation()
                    return try LocalMediaBadgeStore.validatedSource(address: address, data: data)
                }
                let source = try await withTaskCancellationHandler { try await loading.value } onCancel: { loading.cancel() }
                try Task.checkCancellation()
                guard self.revision == active else { return }
                // Other pages may have applied or removed a scheme during the request.
                var next = LocalMediaBadgeStore.load(defaults: self.defaults)
                guard next.sources.first(where: { $0.address == address }) == previous else {
                    throw LocalMediaBadgeStore.BadgeError.changed
                }
                try next.add(source)
                try next.save(defaults: self.defaults)
                completion(.success(next))
            } catch {
                guard self.revision == active, !Task.isCancelled, !(error is CancellationError) else { return }
                let failure: Error = (error as? URLError)?.code == .dataLengthExceedsMaximum
                    ? LocalMediaBadgeStore.BadgeError.invalidAddress : error
                completion(.failure(failure))
            }
        }
        return true
    }
    func cancel() {
        revision = UUID(); work?.cancel(); work = nil
    }
}
