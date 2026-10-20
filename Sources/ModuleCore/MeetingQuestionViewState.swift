import Foundation
import NookPluginSDK

/// Typed nested JSON avoids repeatedly escaping an entire evidence document.
public struct MeetingQuestionViewState: Codable {
    public var busy: Bool
    public var question: String
    public var status: String
    public var provider: String
    public var providers: [[String: String]]
    public var prepared: Bool
    public var coverage: String
    public var sources: [PluginEvidenceSource]
    public var answer: PluginEvidenceAnswer?
    public var highlight: String
    public var scope: String
    public var thread: String
    public var canAsk: Bool
    public var context: [PluginEvidenceExchange]
    public var history: [Turn]
    public var historyPage: Int
    public var historyPages: Int
    public var historyCount: Int
    public var canRestore: Bool
    public var filter: String
    public struct Turn: Codable {
        public let id: String
        public let question: String
        public let status: String
        public let when: String
        public let answer: PluginEvidenceAnswer?
        public let sources: [PluginEvidenceSource]
        public init(id: String, question: String, status: String, when: String, answer: PluginEvidenceAnswer?, sources: [PluginEvidenceSource]) {
            self.id = id; self.question = question; self.status = status; self.when = when; self.answer = answer; self.sources = sources
        }
    }
    public init(busy: Bool, question: String, status: String, provider: String, providers: [[String: String]], prepared: Bool,
                coverage: String, sources: [PluginEvidenceSource], answer: PluginEvidenceAnswer?, highlight: String,
                scope: String = "meeting", thread: String = "", canAsk: Bool = true, context: [PluginEvidenceExchange] = [], history: [Turn] = [], historyPage: Int = 0, historyPages: Int = 1, historyCount: Int = 0, canRestore: Bool = false, filter: String = "") {
        self.busy = busy; self.question = question; self.status = status; self.provider = provider; self.providers = providers
        self.prepared = prepared; self.coverage = coverage; self.sources = sources; self.answer = answer; self.highlight = highlight
        self.scope = scope; self.thread = thread; self.canAsk = canAsk; self.context = context; self.history = history
        self.historyPage = historyPage; self.historyPages = historyPages; self.historyCount = historyCount
        self.canRestore = canRestore; self.filter = filter
    }
}
