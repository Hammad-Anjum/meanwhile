import Foundation
@testable import MeanwhileCore
import Testing

private func tempConfig() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("meanwhile-\(UUID().uuidString)/config.toml")
}

@Test func missingFileGivesDefaults() {
    let settings = UserSettings.load(from: tempConfig())
    #expect(settings == UserSettings())
    #expect(settings.questionsPerRound == 3 && settings.roundInterval == 120)
    #expect(settings.maxQuestions == 20 && settings.capScope == .turn)
}

@Test func savingKeepsCommentsAndOtherKeys() throws {
    let url = tempConfig()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "# mine\nprovider = \"codex\"\nquestions_per_round = 2  # small rounds\n".write(to: url, atomically: true, encoding: .utf8)

    var settings = UserSettings.load(from: url)
    #expect(settings.questionsPerRound == 2)
    try settings.set("round_interval", to: "90s")
    try settings.set("max_questions", to: "none")
    try settings.set("max_questions_per", to: "day")
    try settings.save(to: url)

    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("# mine") && text.contains("provider = \"codex\""))
    #expect(text.contains("round_interval = \"90s\"") && text.contains("max_questions = \"none\""))
    let reloaded = UserSettings.load(from: url)
    #expect(reloaded.roundInterval == 90 && reloaded.maxQuestions == nil && reloaded.capScope == .day)
    #expect(reloaded.questionsPerRound == 2)
}

@Test func valuesAreValidated() throws {
    var settings = UserSettings()
    try settings.set("round_interval", to: "2m")
    #expect(settings.roundInterval == 120)
    try settings.set("round_interval", to: "1.5m")
    #expect(settings.roundInterval == 90)
    try settings.set("round_interval", to: "300")
    #expect(settings.value(of: "round_interval") == "5m")
    #expect(throws: SettingsError.self) { try settings.set("round_interval", to: "5s") }
    #expect(throws: SettingsError.self) { try settings.set("questions_per_round", to: "0") }
    #expect(throws: SettingsError.self) { try settings.set("max_questions", to: "-3") }
    #expect(throws: SettingsError.self) { try settings.set("max_questions_per", to: "week") }
    #expect(throws: SettingsError.unknownKey("speed")) { try settings.set("speed", to: "1") }
    // A bad value in the file falls back to the default instead of failing.
    #expect(UserSettings.parse("questions_per_round = lots").first?.1 == "lots")
}

@Test func roundsStartWithTheTurnThenEveryInterval() {
    var settings = UserSettings()
    settings.roundInterval = 120
    let start = Date(timeIntervalSince1970: 1_000)
    // A round ending 40 s in waits for 2:00; one ending at 2:30 waits for 4:00.
    #expect(settings.nextRound(after: start.addingTimeInterval(40), turnStarted: start) == start.addingTimeInterval(120))
    #expect(settings.nextRound(after: start.addingTimeInterval(150), turnStarted: start) == start.addingTimeInterval(240))
    #expect(settings.nextRound(after: start.addingTimeInterval(120), turnStarted: start) == start.addingTimeInterval(240))
}

@Test func capCountsTheChosenScope() {
    var settings = UserSettings()
    settings.maxQuestions = 20
    #expect(!settings.capReached(thisTurn: 19, today: 50))
    #expect(settings.capReached(thisTurn: 20, today: 0))
    settings.capScope = .day
    #expect(settings.capReached(thisTurn: 0, today: 20))
    #expect(!settings.capReached(thisTurn: 30, today: 5))
    settings.maxQuestions = nil
    #expect(!settings.capReached(thisTurn: 1_000, today: 1_000))
}

@Test func shownTodayCountsForTheDailyCap() throws {
    let store = try ReviewStore(path: nil)
    let now = Date()
    _ = try store.logShown(cardID: "a", deck: "d", session: "s", why: nil, terms: [:], at: now.addingTimeInterval(-2 * 86_400))
    _ = try store.logShown(cardID: "b", deck: "d", session: "s", why: nil, terms: [:], at: now)
    _ = try store.logShown(cardID: "c", deck: "d", session: "s", why: nil, terms: [:], at: now)
    #expect(try store.shownCount(since: now.addingTimeInterval(-3_600)) == 2)
}
