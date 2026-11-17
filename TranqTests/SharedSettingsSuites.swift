import Testing

/// Наборы, которые меняют общий `VoiceIntelligenceSettings.shared`, выполняются
/// последовательно: иначе один тест видит временные значения другого.
@Suite(.serialized)
enum SharedSettingsSuites {}
