import Dispatch
import Foundation

/// Bridges the Darwin memory-pressure dispatch source into the actor-owned cache. The
/// source uses a private utility queue and never performs cache work on its callback.
final class MediaMemoryPressureMonitor: @unchecked Sendable {
    private let source: DispatchSourceMemoryPressure
    private let handler: @Sendable (MediaMemoryPressureLevel) -> Void

    init(handler: @escaping @Sendable (MediaMemoryPressureLevel) -> Void) {
        self.handler = handler
        source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue(
                label: "jp.rinkan.umis.media-memory-pressure",
                qos: .utility
            )
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let data = source.data
            if data.contains(.critical) {
                handler(.critical)
            } else if data.contains(.warning) {
                handler(.warning)
            }
        }
        source.resume()
    }

    deinit {
        source.setEventHandler {}
        source.cancel()
    }
}
