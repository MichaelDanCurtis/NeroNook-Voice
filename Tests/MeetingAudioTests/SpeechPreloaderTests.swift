import XCTest
import Foundation
import ModuleCore
@testable import VoiceAudio

final class SpeechPreloaderTests: XCTestCase {
    @MainActor private func fixture(hold: Duration = .seconds(10)) throws -> (SpeechPreloader, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NeroPreload-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("worker.py"), marker = folder.appendingPathComponent("input")
        try Data(Self.worker.utf8).write(to: script)
        let pool = SpeechPreloader(hold: hold) { service, _, _, _ in
            try await service.startPreparedWorker(executable: URL(fileURLWithPath:"/usr/bin/python3"),
                arguments:[script.path,marker.path], update:{ _ in }, failure:{ _ in })
        }
        return (pool, marker)
    }
    @MainActor func testPreparationHasNoAudioAndTransfersOnceToFreshCallbacks() async throws {
        let (pool, marker) = try fixture(); defer { pool.release() }
        let helper = URL(fileURLWithPath:"/authored-helper")
        try await pool.prepare(provider:.nemotron,locale:"en-US",helper:helper)
        XCTAssertTrue(pool.ready); XCTAssertFalse(FileManager.default.fileExists(atPath:marker.path))
        var received = ""
        let service = try XCTUnwrap(pool.take(provider:.nemotron,locale:"en-US",helper:helper,update:{received=$0.text},failure:{_ in}))
        defer { service.cancel() }
        XCTAssertFalse(pool.ready)
        XCTAssertNil(pool.take(provider:.nemotron,locale:"en-US",helper:helper,update:{_ in},failure:{_ in}))
        service.feed.append(.init(track:"mic",start:0,pcm:Data(repeating:0,count:640)))
        for _ in 0..<100 where received.isEmpty { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(received,"Prepared recognizer used")
        XCTAssertTrue(FileManager.default.fileExists(atPath:marker.path))
        try await service.finish()
    }
    @MainActor func testWrongModelLanguageOrHelperNeverBorrowsPreparedState() async throws {
        let (pool, _) = try fixture(); defer { pool.release() }
        let helper=URL(fileURLWithPath:"/authored-helper")
        for (provider,locale,path) in [(VoiceASRProvider.parakeet,"en-US",helper),(.nemotron,"fr-FR",helper),(.nemotron,"en-US",URL(fileURLWithPath:"/different"))] {
            try await pool.prepare(provider:.nemotron,locale:"en-US",helper:helper)
            XCTAssertNil(pool.take(provider:provider,locale:locale,helper:path,update:{_ in},failure:{_ in}))
            XCTAssertFalse(pool.ready)
        }
    }
    @MainActor func testIdleExpiryAndOtherModelWorkReleaseTheLease() async throws {
        let (pool, _) = try fixture(hold:.milliseconds(80)); defer { pool.release() }
        let helper=URL(fileURLWithPath:"/authored-helper")
        try await pool.prepare(provider:.nemotron,locale:"en-US",helper:helper)
        try await Task.sleep(for:.milliseconds(150)); XCTAssertFalse(pool.ready)
        let (longPool, _) = try fixture(); defer { longPool.release() }
        try await longPool.prepare(provider:.nemotron,locale:"en-US",helper:helper)
        try await LocalModelProcess.waitForAvailable()
        XCTAssertFalse(longPool.ready)
    }
    @MainActor func testReleaseDuringPreparationCannotPublishReadyLater() async throws {
        let pool = SpeechPreloader(hold:.seconds(10)) { _, _, _, _ in
            try await Task.sleep(for:.milliseconds(100))
        }
        let pending=Task { try await pool.prepare(provider:.nemotron,locale:"en-US",helper:URL(fileURLWithPath:"/unused")) }
        for _ in 0..<20 where !pool.preparing { await Task.yield() }
        pool.release()
        do { try await pending.value; XCTFail("Retired preparation succeeded") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(pool.ready); XCTAssertFalse(pool.preparing)
    }
    private static let worker = #"""
import sys,json,struct
from pathlib import Path
def emit(x): print(json.dumps(x),flush=True)
def read(n):
    b=b''
    while len(b)<n:
        q=sys.stdin.buffer.read(n-len(b))
        if not q: raise EOFError()
        b+=q
    return b
emit({'type':'ready','version':2})
while True:
    n=struct.unpack('<I',read(4))[0]
    if n==0: break
    h=json.loads(read(n));read(h['length']);Path(sys.argv[1]).touch()
    emit({'type':'final','track':'mic','start':h['start'],'end':h['start']+h['length']/64000,'text':'Prepared recognizer used'})
    emit({'type':'ack'})
emit({'type':'closed'})
"""#
}
