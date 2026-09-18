import Foundation

/// Renders one creative and reports what happened.
///
/// Behind a protocol so the entire ad *pipeline* — index, directive interpretation, TTL,
/// outcome mapping — is testable with no UI, no network and no simulator. The presentation
/// layer is the one piece that genuinely needs a device.
protocol AdPresenter: Sendable {
    /// Present fullscreen and return once the player has dismissed it.
    ///
    /// Must never throw: a presentation problem is `.noAd` (I7), never an error. Returning
    /// `.noAd` is always a legal answer.
    func present(imageData: Data, clickURL: URL?, forcedViewSeconds: Int) async -> GogAdOutcome

    /// Remove any live ad surface immediately, resolving an in-flight `present` as `.noAd`.
    ///
    /// Mirrors Android's `GogAdOverlay.Teardown()`, and must match its two properties: safe
    /// when nothing is showing, and safe to call twice.
    ///
    /// Two callers: `GOG.shutdown()`, and the pipeline failsafe — which must take the surface
    /// down with it, or the caller resumes into gameplay under an ad nobody can dismiss.
    func teardown() async
}

extension AdPresenter {
    /// Presenters with no persistent surface — the no-op, test doubles — need nothing here.
    func teardown() async {}
}

/// Used when no presenter is available (Linux/CI, or a host that has not supplied one).
/// Always `.noAd`, so the pipeline stays exercisable end to end without a screen.
struct NoOpAdPresenter: AdPresenter {
    func present(imageData: Data, clickURL: URL?, forcedViewSeconds: Int) async -> GogAdOutcome {
        .noAd
    }
}
