import Foundation

/// «Стереть историю»: всё, где остаётся речь пользователя.
/// Заметки со звуком, журнал диктовок для «Вставить оригинал речи» и лог, куда пишутся распознанные тексты.
enum DataEraser {
    static func eraseAll(
        history: HistoryStore = .shared,
        journal: TranscriptJournal = .shared,
        logger: AppLogger = .shared
    ) {
        history.clearAll()
        journal.clear()
        logger.clear()
    }
}
