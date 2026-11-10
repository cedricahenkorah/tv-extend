import Foundation
import Network

/// A TV found on the local network.
struct DiscoveredTV: Hashable {
    /// Bonjour service name, e.g. "Living Room TV (TV Extend)". Stable, used to remember the TV.
    let serviceName: String
    /// Friendly name from the TXT record, e.g. "Living Room TV".
    let displayName: String
    let endpoint: NWEndpoint
}

/// Watches the network for TVs running the TV Extend app (Bonjour `_tvextend._tcp`).
final class TVBrowser {
    static let serviceType = "_tvextend._tcp"

    /// Called on the main queue whenever the list changes.
    var onChange: (([DiscoveredTV]) -> Void)?
    private(set) var tvs: [DiscoveredTV] = []

    private let browser: NWBrowser

    init() {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.update(results)
        }
        browser.stateUpdateHandler = { state in
            switch state {
            case .failed(let error): NSLog("[browser] failed: %@", error.localizedDescription)
            case .waiting(let error): NSLog("[browser] waiting: %@", error.localizedDescription)
            default: break
            }
        }
    }

    func start() {
        browser.start(queue: .main)
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        tvs = results.compactMap { result -> DiscoveredTV? in
            guard case .service(let name, _, _, _) = result.endpoint else { return nil }
            var displayName = name
            if case .bonjour(let txt) = result.metadata, let friendly = txt["name"], !friendly.isEmpty {
                displayName = friendly
            }
            return DiscoveredTV(serviceName: name, displayName: displayName, endpoint: result.endpoint)
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        onChange?(tvs)
    }
}
