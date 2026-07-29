import Foundation

/// An avatar or banner. PeerTube returns several sizes; `path` is relative to
/// the instance that served it.
struct ActorImage: Hashable, Decodable {
    let path: String?
    let width: Int?

    private enum CodingKeys: String, CodingKey {
        case path, width
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = c.lenientNonEmptyString(.path)
        width = c.lenientInt(.width)
    }
}

/// The parts of an actor — channel or account — shared by both.
///
/// `name` is the handle and `host` the instance it lives on. Both are needed:
/// federation means two different channels can share a display name, and the
/// handle alone is ambiguous across instances.
protocol PeerTubeActor {
    var name: String { get }
    var displayName: String { get }
    var host: String? { get }
    var avatars: [ActorImage] { get }
}

extension PeerTubeActor {
    /// `@channel@instance.tld`, the form PeerTube itself uses.
    var handle: String {
        guard let host, !host.isEmpty else { return "@\(name)" }
        return "@\(name)@\(host)"
    }

    /// Largest available avatar — these top out around 120px, so picking the
    /// biggest costs nothing and avoids a blurry circle on a retina screen.
    var bestAvatarPath: String? {
        avatars
            .sorted { ($0.width ?? 0) > ($1.width ?? 0) }
            .compactMap(\.path)
            .first
    }
}

struct ChannelSummary: Hashable, Decodable, PeerTubeActor {
    let id: Int?
    let name: String
    let displayName: String
    let url: String?
    let host: String?
    let avatars: [ActorImage]

    private enum CodingKeys: String, CodingKey {
        case id, name, displayName, url, host, avatars, avatar
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenientInt(.id)
        name = c.lenientNonEmptyString(.name) ?? ""
        displayName = c.lenientNonEmptyString(.displayName) ?? name
        url = c.lenientNonEmptyString(.url)
        host = c.lenientNonEmptyString(.host)

        // `avatars` is the modern array; older instances sent a single
        // `avatar` object instead.
        if let list = try? c.decodeIfPresent([ActorImage].self, forKey: .avatars), !list.isEmpty {
            avatars = list
        } else if let single = try? c.decodeIfPresent(ActorImage.self, forKey: .avatar) {
            avatars = [single]
        } else {
            avatars = []
        }
    }
}

struct AccountSummary: Hashable, Decodable, PeerTubeActor {
    let id: Int?
    let name: String
    let displayName: String
    let url: String?
    let host: String?
    let avatars: [ActorImage]

    private enum CodingKeys: String, CodingKey {
        case id, name, displayName, url, host, avatars, avatar
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenientInt(.id)
        name = c.lenientNonEmptyString(.name) ?? ""
        displayName = c.lenientNonEmptyString(.displayName) ?? name
        url = c.lenientNonEmptyString(.url)
        host = c.lenientNonEmptyString(.host)
        if let list = try? c.decodeIfPresent([ActorImage].self, forKey: .avatars), !list.isEmpty {
            avatars = list
        } else if let single = try? c.decodeIfPresent(ActorImage.self, forKey: .avatar) {
            avatars = [single]
        } else {
            avatars = []
        }
    }
}

/// The signed-in user, from `/users/me`.
struct CurrentUser: Hashable, Decodable {
    let id: Int?
    let username: String
    let email: String?
    let account: AccountSummary?

    private enum CodingKeys: String, CodingKey {
        case id, username, email, account
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenientInt(.id)
        username = c.lenientNonEmptyString(.username) ?? ""
        email = c.lenientNonEmptyString(.email)
        account = try? c.decodeIfPresent(AccountSummary.self, forKey: .account)
    }
}
