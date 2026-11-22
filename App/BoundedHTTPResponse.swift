import Foundation

/// The delegate receives decoded body chunks. Size and wall-clock limits apply
/// before a complete response is buffered, including chunked and gzip bodies.
enum BoundedHTTPResponse {
    static func data(for request: URLRequest, configuration: URLSessionConfiguration, maximumBytes: Int) async throws -> Data {
        precondition(maximumBytes > 0)
        let receiver = Receiver(maximumBytes: maximumBytes)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                receiver.begin(request: request, configuration: configuration, continuation: continuation)
            }
        } onCancel: { receiver.finish(.failure(CancellationError())) }
    }

    private final class Receiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private let maximumBytes: Int
        private var buffer = Data()
        private var completed = false
        private var continuation: CheckedContinuation<Data, Error>?
        private var session: URLSession?
        private var task: URLSessionDataTask?
        private var deadline: DispatchWorkItem?
        init(maximumBytes: Int) { self.maximumBytes = maximumBytes }
        func begin(request: URLRequest, configuration: URLSessionConfiguration, continuation: CheckedContinuation<Data, Error>) {
            lock.lock()
            guard !completed else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .userInitiated
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            self.session = session
            let task = session.dataTask(with: request); self.task = task
            let deadline = DispatchWorkItem { [weak self] in self?.finish(.failure(URLError(.timedOut))) }
            self.deadline = deadline
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + max(0.01, request.timeoutInterval), execute: deadline)
            task.resume()
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                finish(.failure(URLError(.badServerResponse))); completionHandler(.cancel); return
            }
            if response.expectedContentLength > Int64(maximumBytes) {
                finish(.failure(URLError(.dataLengthExceedsMaximum))); completionHandler(.cancel); return
            }
            let active = lock.withLock { !completed }
            completionHandler(active ? .allow : .cancel)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let excessive = lock.withLock {
                guard !completed else { return false }
                if data.count > maximumBytes - buffer.count { return true }
                buffer.append(data)
                return false
            }
            if excessive { finish(.failure(URLError(.dataLengthExceedsMaximum))) }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { finish(.failure(error)) }
            else { finish(.success(lock.withLock { buffer })) }
        }
        func finish(_ result: Result<Data, Error>) {
            lock.lock()
            guard !completed else { lock.unlock(); return }
            completed = true
            let continuation = self.continuation, session = self.session, task = self.task, deadline = self.deadline
            self.continuation = nil; self.session = nil; self.task = nil; self.deadline = nil; buffer = Data()
            lock.unlock()
            deadline?.cancel()
            if case .failure = result { task?.cancel(); session?.invalidateAndCancel() }
            else { session?.finishTasksAndInvalidate() }
            continuation?.resume(with: result)
        }
    }
}
