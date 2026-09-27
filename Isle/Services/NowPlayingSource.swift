//
//  NowPlayingSource.swift
//  Isle
//
//  Abstraction over "something that knows what is playing". Lets `MediaService`
//  prefer the capable-but-private backend and silently degrade to the public-but-
//  limited one without the UI ever knowing.
//

import Foundation

protocol NowPlayingSource: AnyObject {
    /// Human-readable name, for logs and the Settings pane.
    var name: String { get }

    /// Whether this backend can run at all on this machine.
    var isAvailable: Bool { get }

    /// Whether this backend has actually returned a track. A source can be available
    /// and still be useless (MediaRemote loads fine on macOS 15.4+ but may return an
    /// empty dictionary), which is the case the fallback exists for.
    var hasProducedData: Bool { get }

    /// Called on the main queue. `nil` means "nothing is playing".
    var onUpdate: ((NowPlayingInfo?) -> Void)? { get set }

    func start()
    func stop()
    func refresh()

    @discardableResult
    func send(_ command: MediaCommand) -> Bool
}
