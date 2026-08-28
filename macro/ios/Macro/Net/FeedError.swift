import Foundation

/// Failures worth telling someone about, phrased for a person.
///
/// The network layer decides the wording once, here, rather than each screen
/// inventing its own sentence for the same `URLError`. A feed being down is
/// routine, so these lean towards "this source is quiet" over "ERROR".
enum FeedError: LocalizedError, Equatable {
    case badURL(String)
    case offline
    case timedOut
    case http(Int)
    /// The response arrived but nothing in it looked like a feed.
    case notAFeed
    case empty
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .badURL(let raw):
            return raw.isEmpty ? "This source has no address set." : "“\(raw)” is not a valid address."
        case .offline:
            return "No connection."
        case .timedOut:
            return "The source took too long to answer."
        case .http(let code):
            switch code {
            case 403, 401:
                return "The source refused the request (\(code)). It may be blocking app traffic."
            case 404:
                return "The feed address returned nothing (404). It may have moved."
            case 429:
                return "Rate limited by the source. Try again shortly."
            case 500...599:
                return "The source is having trouble (\(code))."
            default:
                return "The source answered with \(code)."
            }
        case .notAFeed:
            return "That address answered with a web page, not a feed — usually a block or a "
                + "consent screen."
        case .empty:
            // Reached when *every* address a source has parsed to nothing. An
            // RSS feed with no items is broken rather than quiet, so this says
            // what to do about it instead of describing the emptiness.
            return "The feed answered but contained no items. The address may have moved."
        case .transport(let message):
            return message
        }
    }

    /// Maps a `URLError` onto the cases worth distinguishing.
    static func from(_ error: Error) -> FeedError {
        if let feedError = error as? FeedError { return feedError }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return .transport(nsError.localizedDescription)
        }
        switch nsError.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
             NSURLErrorDataNotAllowed, NSURLErrorCannotConnectToHost:
            return .offline
        case NSURLErrorTimedOut:
            return .timedOut
        case NSURLErrorCancelled:
            return .transport("Cancelled.")
        default:
            return .transport(nsError.localizedDescription)
        }
    }
}
