import Foundation

enum MinuteDeepLink: Equatable {
    private static let scheme = "minute"

    case newMeeting
    case meeting(UUID)

    var url: URL {
        switch self {
        case .newMeeting:
            URL(string: "\(Self.scheme)://new-meeting")!
        case .meeting(let id):
            URL(string: "\(Self.scheme)://meeting/\(id.uuidString.lowercased())")!
        }
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        switch url.host?.lowercased() {
        case "new-meeting" where url.path.isEmpty:
            self = .newMeeting
        case "meeting":
            let components = url.pathComponents.filter { $0 != "/" }
            guard components.count == 1, let id = UUID(uuidString: components[0]) else { return nil }
            self = .meeting(id)
        default:
            return nil
        }
    }
}
