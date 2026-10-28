import Foundation

/// Conservative English commitment reconciliation over ORIGINAL words. Summary
/// generation never supplies authority for a task owner, date or cancellation.
/// Unsupported/ambiguous phrasing is a review candidate, not an active task.
public enum MeetingActionReconciler {
    private struct TaskState {
        var task: String; var source: Int
        var owner = ""; var ownerSource = -1
        var deadline = ""; var deadlineSource = -1
        var status = "active"; var changeSource = -1
        var key: String { canonical(task) }
        var target: String { canonical(task.split(separator: " ").dropFirst().joined(separator: " ")) }
        var proposal: MeetingActionProposal {
            .init(task: task, taskSource: source, owner: owner, ownerSource: ownerSource,
                  deadline: deadline, deadlineSource: deadlineSource, status: status,
                  sources: Array(Set([source, ownerSource, deadlineSource, changeSource].filter { $0 >= 0 })).sorted())
        }
    }
    public static func proposals(_ transcript: MeetingTranscript) throws -> [MeetingActionProposal] {
        try transcript.validate()
        let lines = MeetingActionResolution.ordered(transcript)
        guard lines.reduce(0, { $0 + MeetingActionResolution.words($1).utf8.count }) <= 192_000 else {
            throw VoiceProblem.message("Task review exceeds the local transcript limit. Existing notes are retained.")
        }
        let names = Set(transcript.names.values.filter { !$0.isEmpty })
        let owners = (["I", "We"] + names.sorted(by: { $0.count > $1.count })).map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let commitment = try NSRegularExpression(pattern: "(?i)\\b(" + owners + ")(?:\\s+(?:will|shall)|['’]ll)\\s+")
        var tasks: [TaskState] = []
        for (index, line) in lines.enumerated() {
            let text = MeetingActionResolution.words(line)
            // A fresh explicit cancellation is not a new task called 'cancel'.
            var recognized = false
            for sentence in sentences(text) {
                let contextual = sentence.range(of: #"\b(if|might|could|should|consider(?:ed|ing)?|discuss(?:ed|ing)?|said|says|heard|example|quoted|hypothetical)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
                if !contextual, let cancel = capture(#"\b(?:cancel|cancelled|canceled|cancelling|canceling)\s+(.+)"#, sentence) {
                    let candidates = matching(cancel, tasks: tasks)
                    if candidates.count == 1 {
                        let found = candidates[0]; tasks[found].status = "cancelled"; tasks[found].changeSource = index
                        recognized = true
                    } else if !candidates.isEmpty {
                        for found in candidates { tasks[found].status = "uncertain"; tasks[found].changeSource = index }
                        recognized = true
                    }
                }
                if !contextual, let revision = captures(#"(?:^|,\s*)([^,]+?)\s+replaces\s+(.+?)\s+for\s+(.+)"#, sentence), revision.count == 3 {
                    let candidates = matching(revision[2], tasks: tasks)
                    if candidates.count == 1, isDate(revision[0]) {
                        let found = candidates[0]
                        tasks[found].deadline = revision[0]; tasks[found].deadlineSource = index; tasks[found].changeSource = index
                        recognized = true
                    }
                }
                if !contextual, let target = capture(#"\bno longer responsible for\s+(.+)"#, sentence) {
                    let candidates = matching(target, tasks: tasks)
                    if candidates.count == 1 {
                        let found = candidates[0]
                        let name = line.speaker.flatMap { transcript.names[$0] }
                        let previous = tasks[found].ownerSource >= 0 ? lines[tasks[found].ownerSource] : nil
                        let previousName = tasks[found].owner.lowercased() == "i" ? previous?.speaker.flatMap { transcript.names[$0] } : tasks[found].owner
                        if name == previousName {
                            tasks[found].owner = ""; tasks[found].ownerSource = -1
                        }
                        // A former owner's withdrawal does not cancel a takeover.
                        tasks[found].changeSource = index; recognized = true
                    }
                }
                let matches = commitment.matches(in: sentence, range: NSRange(sentence.startIndex..., in: sentence))
                for (offset, match) in matches.enumerated() {
                    guard let ownerRange = Range(match.range(at: 1), in: sentence),
                          let bodyStart = Range(match.range, in: sentence)?.upperBound else { continue }
                    let bodyEnd = offset + 1 < matches.count ? Range(matches[offset + 1].range, in: sentence)!.lowerBound : sentence.endIndex
                    var body = clean(String(sentence[bodyStart..<bodyEnd]))
                    if body.lowercased().hasPrefix("also ") { body = String(body.dropFirst(5)) }
                    let owner = String(sentence[ownerRange])
                    guard !body.isEmpty else { continue }
                    let prefix = String(sentence[..<Range(match.range, in: sentence)!.lowerBound]).lowercased()
                    let tentative = prefix.range(of: #"\b(if|maybe|perhaps|whether|said|says|example|quoted|quote|hypothetical|suppose)\b"#, options: .regularExpression) != nil || prefix.contains("\"") || prefix.contains("“") || prefix.contains("‘")
                    // 'If I will write the report, let me know' mentions the
                    // report task; the consequent is not part of its title.
                    if tentative, let comma = body.firstIndex(of: ",") { body = clean(String(body[..<comma])) }
                    let split = taskAndDeadline(body)
                    if let takeover = capture(#"^take\s+(?:over\s+)?(.+?)(?:\s+over)?\s+from\s+.+"#, split.task) {
                        let candidates = matching(takeover, tasks: tasks)
                        if candidates.count == 1, !tentative {
                            let found = candidates[0]
                            tasks[found].owner = owner; tasks[found].ownerSource = index
                            if !split.deadline.isEmpty { tasks[found].deadline = split.deadline; tasks[found].deadlineSource = index }
                            tasks[found].status = "active"; tasks[found].changeSource = index; recognized = true
                            continue
                        }
                    }
                    if split.task.lowercased().hasPrefix("not ") {
                        let candidates = matching(String(split.task.dropFirst(4)), tasks: tasks)
                        if candidates.count == 1 {
                            let found = candidates[0]
                            let prior = tasks[found].ownerSource >= 0 ? lines[tasks[found].ownerSource] : nil
                            let priorName = tasks[found].owner.lowercased() == "i" ? prior?.speaker.flatMap { transcript.names[$0] } : tasks[found].owner
                            let withdrawing = owner.lowercased() == "i" ? line.speaker.flatMap { transcript.names[$0] } : owner
                            if owner.lowercased() == "we" || (priorName != nil && priorName == withdrawing) {
                                tasks[found].status = "cancelled"; tasks[found].changeSource = index
                            }
                            recognized = true
                        }
                        continue
                    }
                    let task = clean(split.task)
                    guard !task.isEmpty, task.utf8.count <= 160 else { continue }
                    if let existing = tasks.firstIndex(where: { $0.key == canonical(task) }) {
                        if tasks[existing].status == "cancelled" {
                            tasks[existing].status = tentative ? "uncertain" : "active"
                            tasks[existing].owner = owner; tasks[existing].ownerSource = index
                            tasks[existing].deadline = split.deadline
                            tasks[existing].deadlineSource = split.deadline.isEmpty ? -1 : index
                        }
                        let previousOwner = tasks[existing].ownerSource >= 0 ? lines[tasks[existing].ownerSource] : nil
                        let previousName: String? = tasks[existing].owner.isEmpty ? nil : (tasks[existing].owner.lowercased() == "i" ? previousOwner?.speaker.flatMap { transcript.names[$0] } : tasks[existing].owner)
                        let newName = owner.lowercased() == "i" ? line.speaker.flatMap { transcript.names[$0] } : owner
                        // Different people promising identical work may be joint
                        // owners. Without explicit takeover, do not silently pick.
                        if previousName != newName && previousName != nil && newName != nil {
                            tasks[existing].owner = ""; tasks[existing].ownerSource = -1; tasks[existing].status = "uncertain"
                        } else {
                            tasks[existing].owner = owner; tasks[existing].ownerSource = index
                            if !tentative { tasks[existing].status = "active" }
                        }
                        if !split.deadline.isEmpty { tasks[existing].deadline = split.deadline; tasks[existing].deadlineSource = index }
                        tasks[existing].changeSource = index
                    } else {
                        tasks.append(.init(task: task, source: index, owner: owner, ownerSource: index,
                                           deadline: split.deadline, deadlineSource: split.deadline.isEmpty ? -1 : index,
                                           status: tentative ? "uncertain" : "active"))
                    }
                    recognized = true
                }
            }
            if !recognized, text.range(of: #"\b(will|promise|could|should|deadline|cancel|take over)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
                // Keep unsupported wording visible without inventing a promise.
                var quote = ""
                for c in text { if (quote + String(c)).utf8.count > 160 { break }; quote.append(c) }
                quote = quote.trimmingCharacters(in: .whitespacesAndNewlines)
                if !quote.isEmpty { tasks.append(.init(task: quote, source: index, status: "uncertain")) }
            }
            guard tasks.count <= 12 else { throw VoiceProblem.message("More than twelve task candidates need review. Existing notes are retained.") }
        }
        return tasks.map(\.proposal)
    }
    private static func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".;!?,")))
    }
    private static func sentences(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ".!?;")).map(clean).filter { !$0.isEmpty }
    }
    private static func canonical(_ value: String) -> String {
        value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter {
            !$0.isEmpty && !["a", "an", "the", "my", "our", "that", "this", "earlier", "promise", "commitment", "to", "for", "now", "still"].contains($0)
        }.joined(separator: " ")
    }
    private static func matching(_ target: String, tasks: [TaskState]) -> [Int] {
        let target = canonical(target)
        if ["it", "them", "that task", "this task"].contains(target) {
            return tasks.count == 1 ? [0] : []
        }
        return tasks.indices.filter {
            let noun = tasks[$0].target
            return !noun.isEmpty && (target == tasks[$0].key || target == noun || (" " + target + " ").contains(" " + tasks[$0].key + " ") || (" " + target + " ").contains(" " + noun + " "))
        }
    }
    private static func captures(_ pattern: String, _ text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }
    private static func capture(_ pattern: String, _ text: String) -> String? { captures(pattern, text)?.first }
    private static func isDate(_ value: String) -> Bool {
        value.range(of: #"^(?:(?:by|on|at|next|this|the)\s+)*(today|tomorrow|tonight|monday|tuesday|wednesday|thursday|friday|saturday|sunday|next|january|february|march|april|may|june|july|august|september|october|november|december|\d)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    private static func taskAndDeadline(_ body: String) -> (task: String, deadline: String) {
        let pattern = #"\s+((?:by|on|at|before|after)\s+.+|in\s+(?:\d+|one|two|three|four|five|six|a|an)\s+(?:minutes?|hours?|days?|weeks?|months?)|(?:today|tomorrow|tonight|next\s+\w+|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)\b.*)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let range = Range(match.range(at: 1), in: body) else { return (clean(body), "") }
        var deadline = clean(String(body[range]))
        for suffix in [" instead", " now"] where deadline.lowercased().hasSuffix(suffix) { deadline = String(deadline.dropLast(suffix.count)) }
        let dependency = deadline.lowercased().hasPrefix("after ") || deadline.lowercased().hasPrefix("before ")
        let relative = deadline.range(of: #"^in\s+"#, options: [.regularExpression, .caseInsensitive]) != nil
        guard dependency || relative || isDate(deadline), deadline.utf8.count <= 80 else { return (clean(body), "") }
        if deadline.lowercased().hasPrefix("by ") || deadline.lowercased().hasPrefix("on ") || deadline.lowercased().hasPrefix("at ") { deadline = String(deadline.dropFirst(3)) }
        return (clean(String(body[..<range.lowerBound])), deadline)
    }
}
