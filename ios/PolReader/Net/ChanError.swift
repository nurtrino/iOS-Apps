import Foundation

/// Every transport and decoding failure, collapsed into the small set of things
/// a reader can actually be told.
///
/// The mapping from `URLError` and status codes happens here, in the network
/// layer, so that no view ever has to interpret an error — it just prints
/// `error.message` and offers Retry.
enum ChanError: Error, Equatable {
    case offline
    case timedOut
    /// 404. On a thread request this is the ordinary end of a thread's life,
    /// not a malfunction, so it gets its own sentence.
    case notFound
    case rateLimited
    case server(Int)
    case malformedResponse
    case cancelled

    /// The one user-facing sentence for this failure.
    var message: String {
        switch self {
        case .offline:
            return "No internet connection."
        case .timedOut:
            return "The request timed out."
        case .notFound:
            return "This thread has been pruned or deleted."
        case .rateLimited:
            return "Too many requests — waiting a moment before trying again."
        case .server(let code):
            return "4chan returned an error (\(code))."
        case .malformedResponse:
            return "Couldn't read the response from 4chan."
        case .cancelled:
            return "Request cancelled."
        }
    }

    /// False for failures where a Retry button is pointless.
    var isRetryable: Bool {
        switch self {
        case .notFound, .cancelled: return false
        default: return true
        }
    }

    static func from(_ error: Error) -> ChanError {
        if let chanError = error as? ChanError { return chanError }
        if error is DecodingError { return .malformedResponse }
        if error is CancellationError { return .cancelled }

        let urlError = error as? URLError
        switch urlError?.code {
        case .some(.notConnectedToInternet), .some(.dataNotAllowed),
             .some(.networkConnectionLost), .some(.cannotConnectToHost),
             .some(.cannotFindHost), .some(.dnsLookupFailed):
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
