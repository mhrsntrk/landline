#!/usr/bin/env python3
"""Reproduce three audit findings against current source, without editing it.

Run from any directory: python3 docs/audit-repros-2026-09-08.py
Requires cached Rust dependencies, macOS, and Swift. Creates temporary copies,
spawns disposable /bin/sh PTYs, kills them, and retains evidence in /private/tmp.
The three assertions are expected to fail at commit 88eb996.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
AUTH_TEST = r"""
#[cfg(test)]
mod codex_audit_tests {
    use super::*;
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn audit_parallel_unlock_respects_ten_attempt_budget() {
        use argon2::password_hash::{rand_core::OsRng, PasswordHasher, SaltString};
        let hash = Argon2::default().hash_password(b"correct", &SaltString::generate(&mut OsRng)).unwrap().to_string();
        let gate = UnlockGate::new(hash);
        let mut tasks = Vec::new();
        for _ in 0..12 {
            let gate = gate.clone();
            tasks.push(tokio::spawn(async move { gate.verify("wrong".into()).await }));
        }
        let _ = tokio::time::timeout(Duration::from_secs(20), async {
            loop {
                if gate.state.lock().unwrap().failures >= 12 { break; }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        }).await;
        let failures = gate.state.lock().unwrap().failures;
        for task in tasks { task.abort(); }
        assert!(failures <= MAX_UNLOCK_FAILURES, "verified {failures} wrong guesses in one concurrent batch; budget is {MAX_UNLOCK_FAILURES}");
    }
}
"""
SESSION_TEST = r"""
#[cfg(all(test, unix))]
mod codex_audit_tests {
    use super::*;
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn audit_parallel_creation_respects_one_session_cap() {
        for round in 0..100 {
            let manager = SessionManager::new(1, 1024);
            let barrier = Arc::new(std::sync::Barrier::new(16));
            let handle = tokio::runtime::Handle::current();
            let mut threads = Vec::new();
            for _ in 0..16 {
                let manager = manager.clone(); let barrier = barrier.clone(); let handle = handle.clone();
                threads.push(std::thread::spawn(move || {
                    let _guard = handle.enter();
                    barrier.wait();
                    manager.attach(AttachArgs { session_id: None, program: "/bin/sh".into(), args: vec![], cwd: None, cols: 80, rows: 24 }).ok()
                }));
            }
            let attachments: Vec<_> = threads.into_iter().filter_map(|t| t.join().unwrap()).collect();
            let count = attachments.len();
            for a in &attachments { a.session.kill(); }
            let _ = tokio::time::timeout(Duration::from_secs(5), async {
                while !manager.list().is_empty() { tokio::time::sleep(Duration::from_millis(10)).await; }
            }).await;
            assert!(count <= 1, "round {round}: created {count} sessions with max_sessions=1");
        }
    }
}
"""
SWIFT_PROBE = r"""import Foundation
struct Host {
    var id = UUID()
    var lastSessionID: String? = nil
    var startCommand = ""
    var wsURL = URL(string: "wss://example.invalid/v1/shell")!
}
final class ProbeTransport: WebSocketTransport {
    var onMessage: ((Result<Data, Error>) -> Void)?
    var types: [UInt8] = []
    func connect(url: URL) {}
    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        types.append(data.first!); completion(nil)
    }
    func cancel() {}
}
let fake = ProbeTransport()
let connection = Connection(makeTransport: { fake })
connection.connect(host: Host(), cols: 80, rows: 24)
let payload = Data("{\"attempts_left\":10}".utf8)
var frame = Data([0x86, 0, 0, 0, UInt8(payload.count)])
frame.append(payload)
fake.onMessage?(.success(frame))
RunLoop.current.run(until: Date().addingTimeInterval(0.05))
print("state before resize: \(connection.state)")
connection.send(.resize(cols: 80, rows: 16))
print("sent frame types: \(fake.types), expected only [3] until unlock")
connection.disconnect(sendDetach: false)
exit(fake.types.contains(2) ? 1 : 0)
"""


def main():
    work = Path(tempfile.mkdtemp(prefix="landline-audit-", dir="/private/tmp"))
    for name in ("Cargo.toml", "Cargo.lock"):
        shutil.copy2(ROOT / name, work / name)
    shutil.copytree(ROOT / "crates", work / "crates")
    for name, extra in (("auth.rs", AUTH_TEST), ("session.rs", SESSION_TEST)):
        with (work / "crates/landlined/src" / name).open("a") as stream:
            stream.write(extra)
    rust = subprocess.run([
        "cargo", "test", "--offline", "--locked", "--manifest-path", str(work / "Cargo.toml"),
        "--target-dir", str(ROOT / "target"), "-p", "landlined", "audit_parallel", "--", "--nocapture"
    ], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (work / "rust-results.txt").write_text(rust.stdout)
    print(rust.stdout)
    (work / "main.swift").write_text(SWIFT_PROBE)
    subprocess.run([
        "swiftc", "-module-cache-path", str(work / "swift-cache"),
        str(ROOT / "ios/Landline/Protocol/Frame.swift"),
        str(ROOT / "ios/Landline/Net/Connection.swift"), str(work / "main.swift"),
        "-o", str(work / "handshake-probe")
    ], check=True)
    swift = subprocess.run([str(work / "handshake-probe")], capture_output=True, text=True)
    (work / "swift-results.txt").write_text(swift.stdout + swift.stderr)
    print(swift.stdout + swift.stderr)
    print(f"Evidence: {work}")
    print(f"Rust exit: {rust.returncode}; Swift exit: {swift.returncode} (expected 0 and 0 after fixes; 101 and 1 on the audited commit)")
    return int(rust.returncode != 0 or swift.returncode != 0)


if __name__ == "__main__":
    raise SystemExit(main())
