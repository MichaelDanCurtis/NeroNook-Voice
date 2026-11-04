import XCTest
import Foundation
import Darwin
@testable import VoiceAudio

@MainActor final class LocalDictationFramingTests: XCTestCase {
    private let firstText = "Hello, café 🌿."
    private let secondText = "Hello, café 🌿 — 你好."
    private let finalText = "Hello, café 🌿 — 你好. Done."

    private func fixture(_ mode: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-framing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let script = """
        import json,os,signal,struct,sys,time
        root,mode=sys.argv[1:3]
        signal.signal(signal.SIGTERM,lambda *_:os._exit(0))
        def marker(name):
            with open(os.path.join(root,name),'w') as f:f.write('observed')
        def raw(value):
            return json.dumps(value,ensure_ascii=False,separators=(',',':')).encode('utf-8')
        def output(data):
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
        def message(kind,text=''):
            return dict(type=kind,text=text)
        def emit(kind,text=''):
            output(raw(message(kind,text))+b'\\n')
        def read(size):
            value=b''
            while len(value)<size:
                piece=sys.stdin.buffer.read(size-len(value))
                if not piece:raise EOFError()
                value+=piece
            return value
        with open(os.path.join(root,'pid.tmp'),'w') as f:f.write(str(os.getpid()))
        os.replace(os.path.join(root,'pid.tmp'),os.path.join(root,'pid'))
        startup=[]
        if mode=='partial-before-ready':startup.append(message('partial','Too early.'))
        startup.append(message('ready','Authored readiness metadata.' if mode=='ready-metadata' else ''))
        if mode=='duplicate-ready':startup.append(message('ready'))
        output(b''.join(raw(value)+b'\\n' for value in startup))
        if mode=='premature-final':
            while not os.path.exists(os.path.join(root,'emit-early-final')):time.sleep(0.01)
            emit('final','Premature complete final.')
            marker('premature-final')
        packets=0
        while True:
            size=struct.unpack('<I',read(4))[0]
            if size==0:break
            data=read(size)
            assert size%4==0 and all(value==0 for value in data)
            packets+=1
            if mode=='valid':
                emit('partial','Hello, café 🌿.' if packets==1 else 'Hello, café 🌿 — 你好.')
            if mode=='fragment' and packets==1:
                output(raw(message('partial','Hello, café 🌿.')))
                marker('fragment-written')
                while not os.path.exists(os.path.join(root,'allow-newline')):time.sleep(0.01)
                output(b'\\n')
                marker('newline-written')
        if mode=='malformed-before-final':output(b'{this-is-not-json}\\n')
        if mode=='unknown-record':emit('unexpected','An unknown response.')
        if mode=='oversized-partial':emit('partial','a'*2049)
        if mode=='post-final':
            emit('final','First completed final.')
            emit('partial','Unexpected later partial.')
        if mode!='premature-final':
            encoded=raw(message('final','Hello, café 🌿 — 你好. Done.'))
            output(encoded if mode=='unframed-final' else encoded+b'\\n')
        if mode=='truncated-tail':output(b'garbage{"type":')
        """
        try script.write(to: root.appendingPathComponent("worker.py"), atomically: true, encoding: .utf8)
        return root
    }
    private func arguments(_ root: URL, _ mode: String) -> [String] {
        ["-u", root.appendingPathComponent("worker.py").path, root.path, mode]
    }
    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw NSError(domain: "LocalDictationFramingTests", code: 1) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func assertRetired(_ stream: LocalDictationStream, root: URL,
                               file: StaticString = #filePath, line: UInt = #line) async throws {
        let text = try String(contentsOf: root.appendingPathComponent("pid"), encoding: .utf8)
        let pid = try XCTUnwrap(pid_t(text), file: file, line: line)
        stream.cancel()
        let original = try XCTUnwrap(stream.retirementCompletion(), file: file, line: line)
        await original.value
        let present = kill(pid, 0), presenceError = errno
        var status: Int32 = 0
        let waited = waitpid(pid, &status, WNOHANG), waitError = errno
        XCTAssertEqual(present, -1, "Authored helper still present", file: file, line: line)
        XCTAssertEqual(presenceError, ESRCH, file: file, line: line)
        XCTAssertEqual(waited, -1, "Original process wait did not reap helper", file: file, line: line)
        XCTAssertEqual(waitError, ECHILD, file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stream.transcriptLogURL.path), file: file, line: line)
        try FileManager.default.removeItem(at: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), file: file, line: line)
    }
    private func reject(_ mode: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let root = try fixture(mode)
        defer { try? FileManager.default.removeItem(at: root) }
        let stream = try LocalDictationStream(); defer { stream.cancel() }
        var rejected = false
        do {
            try await stream.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: arguments(root, mode))
            _ = try await stream.finish(Data(repeating: 0, count: 4096))
        } catch { rejected = true }
        XCTAssertTrue(rejected, "Accepted corrupt stream: \(mode)", file: file, line: line)
        try await assertRetired(stream, root: root, file: file, line: line)
    }
    func testMalformedCompleteRecordBeforeFinalCannotBeHidden() async throws { try await reject("malformed-before-final") }
    func testTruncatedGarbageAfterFinalCannotBeHidden() async throws { try await reject("truncated-tail") }
    func testUnframedFinalWithoutLineFeedCannotComplete() async throws { try await reject("unframed-final") }
    func testPartialAndReplacementFinalAfterFinalCannotComplete() async throws { try await reject("post-final") }
    func testUnknownRecordBeforeFinalCannotBeHidden() async throws { try await reject("unknown-record") }
    func testOversizedEarlierPartialCannotBeHiddenByShortFinal() async throws { try await reject("oversized-partial") }
    func testPartialBeforeReadyCannotComplete() async throws { try await reject("partial-before-ready") }
    func testDuplicateReadyCannotComplete() async throws { try await reject("duplicate-ready") }

    func testOrderedUnicodePartialsAndFinalRemainExact() async throws {
        let root = try fixture("valid")
        defer { try? FileManager.default.removeItem(at: root) }
        let stream = try LocalDictationStream(); defer { stream.cancel() }
        try await stream.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: arguments(root, "valid"))
        var audio = Data(repeating: 0, count: 4096)
        var partials: [String] = [], failures: [String] = []
        stream.observe(audio: { audio }, partial: { partials.append($0) }, failure: { failures.append($0) })
        try await until { partials.contains(firstText) }
        audio = Data(repeating: 0, count: 8192)
        try await until { partials.contains(secondText) }
        XCTAssertEqual(partials, [firstText, secondText])
        let final = try await stream.finish(audio)
        XCTAssertEqual(final, finalText); XCTAssertTrue(failures.isEmpty)
        try await assertRetired(stream, root: root)
    }
    func testCompletePartialIsWithheldUntilItsLineFeedArrives() async throws {
        let root = try fixture("fragment")
        defer { try? FileManager.default.removeItem(at: root) }
        let stream = try LocalDictationStream(); defer { stream.cancel() }
        try await stream.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: arguments(root, "fragment"))
        let audio = Data(repeating: 0, count: 4096)
        var polls = 0
        var partials: [String] = [], failures: [String] = []
        stream.observe(audio: { polls += 1; return audio }, partial: { partials.append($0) }, failure: { failures.append($0) })
        try await until { FileManager.default.fileExists(atPath: root.appendingPathComponent("fragment-written").path) }
        let afterFragment = polls
        // At least two completed real observer polls have seen the held bytes
        // before this condition can pass; no guessed sleep substitutes for it.
        try await until { polls >= afterFragment + 3 }
        XCTAssertTrue(partials.isEmpty, "Published a complete JSON record before its framing LF")
        try Data().write(to: root.appendingPathComponent("allow-newline"))
        try await until { partials.contains(firstText) }
        XCTAssertEqual(partials, [firstText]); XCTAssertTrue(failures.isEmpty)
        let final = try await stream.finish(audio)
        XCTAssertEqual(final, finalText)
        try await assertRetired(stream, root: root)
    }
    func testUnsolicitedFinalBeforeFinishIsRejectedWithoutLivePolling() async throws {
        let root = try fixture("premature-final")
        defer { try? FileManager.default.removeItem(at: root) }
        let stream = try LocalDictationStream(); defer { stream.cancel() }
        try await stream.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: arguments(root, "premature-final"))
        try Data().write(to: root.appendingPathComponent("emit-early-final"))
        try await until { FileManager.default.fileExists(atPath: root.appendingPathComponent("premature-final").path) }
        var rejected = false
        do { _ = try await stream.finish(Data(repeating: 0, count: 4096)) }
        catch { rejected = true }
        XCTAssertTrue(rejected, "Accepted an unsolicited final already logged before end-of-input")
        try await assertRetired(stream, root: root)
    }
    func testReadinessTextIsMetadataAndNeverARecognizedPartial() async throws {
        let root = try fixture("ready-metadata")
        defer { try? FileManager.default.removeItem(at: root) }
        let stream = try LocalDictationStream(); defer { stream.cancel() }
        try await stream.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: arguments(root, "ready-metadata"))
        let audio = Data(repeating: 0, count: 4096)
        var polls = 0
        var partials: [String] = [], failures: [String] = []
        stream.observe(audio: { polls += 1; return audio }, partial: { partials.append($0) }, failure: { failures.append($0) })
        try await until { polls >= 3 }
        XCTAssertTrue(partials.isEmpty, "Published readiness metadata as recognized words")
        let final = try await stream.finish(audio)
        XCTAssertEqual(final, finalText); XCTAssertTrue(failures.isEmpty)
        try await assertRetired(stream, root: root)
    }
}
