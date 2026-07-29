import Foundation

/// Every transport, auth and decoding failure, reduced to what can actually be
/// told to somebody. The mapping happens once, here, so no view ever has to
/// interpret an error.
enum APIError: Error, Equatable {
    case offline
    case timedOut
    case notFound
    /// Credentials are missing, expired beyond refresh, or were rejected.
    case unauthorized
    case rateLimited
    case server(Int)
    case malformedResponse
    case noInstance
    case cancelled

    var message: String {
        switch self {
        case .offline:
            return "No internet connection."
        case .timedOut:
            return "The server took too long to respond."
        case .notFound:
            return "That video is no longer available."
        case .unauthorized:
            return "Your session expired. Sign in again."
        case .rateLimited:
            return "Too many requests — give it a moment."
        case .server(let code):
            return "The instance returned an error (\(code))."
        case .malformedResponse:
            return "Couldn't read the response from this instance."
        case .noInstance:
            return "Choose an instance first."
        case .cancelled:
            return "Cancelled."
        }
    }

    /// False where a Retry button would just fail the same way.
    var isRetryable: Bool {
        switch self {
        case .notFound, .cancelled, .noInstance, .unauthorized: return false
        default: return true
        }
    }

    static func from(_ error: Error) -> APIError {
        if let apiError = error as? APIError { return apiError }
        if error is DecodingError { return .malformedResponse }
        if error is CancellationError { return .cancelled }

        switch (error as? URLError)?.code {
        case .some(.notConnectedToInternet), .some(.dataNotAllowed),
             .some(.networkConnectionLost), .some(.cannotConnectToHost),
             .some(.cannotFindHost), .some(.dnsLookupFailed),
             .some(.secureConnectionFailed):
            return .offline
        case .some(.timedOut):
            return .timedOut
        case .some(.cancelled):
            return .cancelled
        default:
            return .malformedResponse
        }
    }
}
