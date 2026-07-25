import FluidAudio

/// FluidAudio's top-level `TokenTiming`, aliased under a distinct name.
///
/// `VocabularyRescorerHolder` imports BOTH FluidAudio and `JotVocabCore`, and
/// each module exports a top-level `TokenTiming` — so a bare `TokenTiming` there
/// is ambiguous. Normally you'd disambiguate with `FluidAudio.TokenTiming`, but
/// the module name `FluidAudio` is itself shadowed by a same-named type in that
/// module, so that qualification doesn't resolve. This alias is declared in a
/// file that imports ONLY FluidAudio, so the bare `TokenTiming` here binds
/// unambiguously to FluidAudio's; callers then name it `FluidAudioTokenTiming`.
public typealias FluidAudioTokenTiming = TokenTiming
