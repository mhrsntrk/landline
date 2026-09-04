import XCTest
@testable import Landline

/// The startup command is written as steps and sent as one `&&`-joined string.
/// Two things have to hold forever: a host stored by any earlier build is a
/// one-step chain and keeps working, and a chain that reduces to nothing sends
/// no `cmd` at all so the daemon falls back to its own default.
final class StartupChainTests: XCTestCase {

    // MARK: Joining

    func testStepsJoinWithAnd() {
        let raw = "cd ~/project\ntmux attach -t main\nnpm run dev"
        XCTAssertEqual(
            StartupChain.command(raw),
            "cd ~/project && tmux attach -t main && npm run dev"
        )
    }

    /// `&&` and not `;`: a failed `cd` has to stop the chain, or
    /// the steps after it run in the wrong directory.
    func testJoinerIsAndNotSemicolon() {
        XCTAssertEqual(StartupChain.joiner, " && ")
        XCTAssertFalse(StartupChain.command("a\nb")!.contains(";"))
    }

    func testSingleStepSendsItselfUnchanged() {
        XCTAssertEqual(StartupChain.command("tmux new -A -s main"), "tmux new -A -s main")
    }

    /// A step may contain `&&` of its own; it is one step, and joining does not
    /// touch what is inside it.
    func testStepMayContainItsOwnOperators() {
        XCTAssertEqual(
            StartupChain.command("cd ~/project && ls\nnpm run dev"),
            "cd ~/project && ls && npm run dev"
        )
    }

    // MARK: Trimming and blanks

    func testStepsAreTrimmedAndBlanksDropped() {
        let raw = "  cd ~/project  \n\n\t\n  npm run dev\n"
        XCTAssertEqual(StartupChain.command(raw), "cd ~/project && npm run dev")
    }

    func testBlankRowsSurviveEditingButNotStorage() {
        // Rows are kept while editing, so clearing a field does not delete it.
        XCTAssertEqual(StartupChain.steps(in: "a\n\nb"), ["a", "", "b"])
        // Storage keeps only the steps.
        XCTAssertEqual(StartupChain.normalized("  a  \n\n b \n"), "a\nb")
    }

    func testNormalizedIsIdempotent() {
        let once = StartupChain.normalized("  a \n\n b ")
        XCTAssertEqual(StartupChain.normalized(once), once)
    }

    /// Windows line endings arrive by paste; they must not become a step.
    func testCarriageReturnsAreNotSteps() {
        XCTAssertEqual(StartupChain.command("a\r\nb"), "a && b")
    }

    // MARK: The empty chain

    func testEmptyChainSendsNothing() {
        XCTAssertNil(StartupChain.command(""))
        XCTAssertNil(StartupChain.command("   "))
        XCTAssertNil(StartupChain.command("\n\n\n"))
        XCTAssertNil(StartupChain.command("  \n \t \n "))
        XCTAssertEqual(StartupChain.normalized("\n \n"), "")
    }

    // MARK: Migration

    /// The value every existing host holds: one line, no newline anywhere.
    /// It must decode untouched and send itself, with no migration step in
    /// between that could get it wrong.
    func testStoredSingleLineValueIsAOneStepChain() throws {
        let document = #"[{"hostname":"studio.tail4f1a.ts.net","startCommand":"tmux new -A -s main"}]"#
        let host = try XCTUnwrap(Host.decodeList(from: Data(document.utf8)).first)
        XCTAssertEqual(host.startCommand, "tmux new -A -s main")
        XCTAssertEqual(StartupChain.steps(in: host.startCommand), ["tmux new -A -s main"])
        XCTAssertEqual(StartupChain.command(host.startCommand), "tmux new -A -s main")
        XCTAssertTrue(StartupChain.blockingSteps(inRaw: host.startCommand).isEmpty,
                      "a lone blocking step is the last step, so it is not a trap")
    }

    /// A host stored before `startCommand` existed at all.
    func testLegacyHostWithoutAStartCommandSendsNothing() throws {
        let document = #"[{"hostname":"studio.tail4f1a.ts.net"}]"#
        let host = try XCTUnwrap(Host.decodeList(from: Data(document.utf8)).first)
        XCTAssertEqual(host.startCommand, "")
        XCTAssertNil(StartupChain.command(host.startCommand))
    }

    func testMultiStepChainSurvivesARoundTrip() throws {
        var host = Host()
        host.hostname = "studio.tail4f1a.ts.net"
        host.startCommand = "cd ~/project\nnpm run dev"
        let decoded = try XCTUnwrap(Host.decodeList(from: Host.encodeList([host])).first)
        XCTAssertEqual(decoded.startCommand, "cd ~/project\nnpm run dev")
        XCTAssertEqual(StartupChain.command(decoded.startCommand), "cd ~/project && npm run dev")
    }

    // MARK: The blocking-step detector

    /// The chain that reads right and does the wrong thing: the dev server
    /// runs after tmux is detached, in the outer shell, outside tmux.
    func testTheReadsRightChainWarnsOnTheBlockingStep() {
        let blocking = StartupChain.blockingSteps(
            in: ["cd ~/project", "tmux attach -t main", "npm run dev"]
        )
        XCTAssertEqual(blocking.count, 1)
        XCTAssertEqual(blocking.first?.number, 2)
        XCTAssertEqual(blocking.first?.program, "tmux")
        XCTAssertEqual(blocking.first?.step, "tmux attach -t main")
    }

    /// The same trap through an alias, which is why the closed list carries
    /// names as well as programs.
    func testAnAliasThatAttachesIsCaughtToo() {
        let blocking = StartupChain.blockingSteps(in: ["cd ~/project", "tmuxon", "npm run dev"])
        XCTAssertEqual(blocking.count, 1)
        XCTAssertEqual(blocking.first?.number, 2)
        XCTAssertEqual(blocking.first?.program, "tmuxon")
    }

    /// The working shape: the same three steps with the blocking one last.
    /// Nothing here may warn, including `tmux new -d`, which does not attach,
    /// and `tmux new-window`, which returns immediately.
    func testTheCorrectedChainDoesNotWarn() {
        let steps = [
            "tmux new -A -d -s main -c ~/project",
            "tmux new-window -n dev -t main -c ~/project 'npm run dev'",
            "tmux attach -t main",
        ]
        XCTAssertTrue(StartupChain.blockingSteps(in: steps).isEmpty)
    }

    func testBlockingStepInLastPositionNeverWarns() {
        for program in ["tmuxon", "tmux", "tmux attach", "vim", "htop", "ssh box", "less log"] {
            XCTAssertTrue(
                StartupChain.blockingSteps(in: ["cd ~/project", program]).isEmpty,
                "\(program) is last, so nothing is waiting on it"
            )
        }
    }

    func testEveryListedBlockingProgramIsCaughtBeforeTheEnd() {
        let blockers = [
            "tmuxon", "screen", "screen -r", "ssh box", "vim a", "nvim a", "vi a",
            "emacs a", "nano a", "less log", "top", "htop", "btop",
            "watch -n1 date", "tail -f log", "tail -F log", "tail --follow log",
            "tail -n20 -f log",
        ]
        for step in blockers {
            let blocking = StartupChain.blockingSteps(in: [step, "echo done"])
            XCTAssertEqual(blocking.count, 1, "\(step) should warn when it is not last")
            XCTAssertEqual(blocking.first?.number, 1)
        }
    }

    /// tmux is the one that has to be read properly: it blocks when it
    /// attaches, and only then.
    func testTmuxIsJudgedBySubcommand() {
        func warns(_ step: String) -> Bool {
            !StartupChain.blockingSteps(in: [step, "echo done"]).isEmpty
        }
        // Attaching, in every spelling tmux accepts, plus bare tmux, which
        // attaches if it can and creates-and-attaches if it cannot.
        XCTAssertTrue(warns("tmux"))
        XCTAssertTrue(warns("tmux attach"))
        XCTAssertTrue(warns("tmux a"))
        XCTAssertTrue(warns("tmux at"))
        XCTAssertTrue(warns("tmux attach-session -t work"))
        XCTAssertTrue(warns("tmux -L work attach"), "a global flag with a value must not be read as the subcommand")
        XCTAssertTrue(warns("tmux -2 attach"))
        // Not attaching.
        XCTAssertFalse(warns("tmux new -d -s work"), "-d does not attach")
        XCTAssertFalse(warns("tmux new -A -d -s main -c ~/project"))
        XCTAssertFalse(warns("tmux new-window -n dev"))
        XCTAssertFalse(warns("tmux kill-server"))
        XCTAssertFalse(warns("tmux send-keys -t work 'echo hi' Enter"))
        XCTAssertFalse(warns("tmux has-session -t work"))
    }

    /// `tail` blocks only with a follow flag.
    func testTailOnlyWarnsWhenItFollows() {
        func warns(_ step: String) -> Bool {
            !StartupChain.blockingSteps(in: [step, "echo done"]).isEmpty
        }
        XCTAssertTrue(warns("tail -f /var/log/system.log"))
        XCTAssertFalse(warns("tail -n 100 /var/log/system.log"))
        XCTAssertFalse(warns("tail /var/log/system.log"))
    }

    /// The false-positive side, which matters more than the true-positive one:
    /// a warning that fires on someone's own script teaches them to ignore
    /// every warning, including the one that was right.
    func testOrdinaryStepsNeverWarn() {
        let harmless = [
            "cd ~/project",
            "cd /srv/www/site",
            "export PATH=/opt/homebrew/bin:$PATH",
            "source ~/.zshrc",
            "git pull",
            "echo tmuxon",
            "npm run build",
            "cargo build --release",
            "./deploy.sh",
            "/usr/local/bin/mytool --watch",
            "npm run dev",
            "pgrep tmux",
            "ls -la",
            "docker compose up -d",
            "kubectl get pods",
        ]
        for step in harmless {
            XCTAssertTrue(
                StartupChain.blockingSteps(in: [step, "echo done"]).isEmpty,
                "\(step) must not warn"
            )
        }
    }

    /// A word the detector has never heard of is safe. Guessing in the noisy
    /// direction is worse than staying quiet.
    func testUnknownProgramsAreTreatedAsSafe() {
        XCTAssertTrue(StartupChain.blockingSteps(in: ["frobnicate --all", "echo done"]).isEmpty)
        XCTAssertTrue(StartupChain.blockingSteps(in: ["tmuxonsteroids", "echo done"]).isEmpty,
                      "the match is on the whole word, not a prefix")
        XCTAssertTrue(StartupChain.blockingSteps(in: ["vimdiff a b", "echo done"]).isEmpty)
        XCTAssertTrue(StartupChain.blockingSteps(in: ["topgrade", "echo done"]).isEmpty)
        XCTAssertTrue(StartupChain.blockingSteps(in: ["lessc style.less", "echo done"]).isEmpty)
    }

    /// The first word is found past a path, a `sudo`, and an environment
    /// assignment, because that is still the same program.
    func testFirstWordIsFoundPastPathsSudoAndEnvironment() {
        func warns(_ step: String) -> Bool {
            !StartupChain.blockingSteps(in: [step, "echo done"]).isEmpty
        }
        XCTAssertTrue(warns("/usr/bin/vim notes.txt"))
        XCTAssertTrue(warns("~/bin/tmuxon"))
        XCTAssertTrue(warns("sudo htop"))
        XCTAssertTrue(warns("sudo /usr/bin/vim /etc/hosts"))
        XCTAssertTrue(warns("EDITOR=nano sudo vim /etc/hosts"))
        XCTAssertTrue(warns("TERM=xterm-256color tmux attach"))
        // An assignment on its own is not a program.
        XCTAssertFalse(warns("FOO=bar"))
        // A value that merely contains a blocking name is not the program.
        XCTAssertFalse(warns("EDITOR=vim git commit"))
    }

    /// Quoted arguments stay arguments. The corrected chain depends on this:
    /// the command inside `tmux new-window ... 'npm run dev'` is not a step.
    func testQuotedArgumentsAreNotReadAsPrograms() {
        func warns(_ step: String) -> Bool {
            !StartupChain.blockingSteps(in: [step, "echo done"]).isEmpty
        }
        XCTAssertFalse(warns("tmux new-window -n edit 'vim notes.txt'"))
        XCTAssertFalse(warns("echo \"htop\""))
    }

    // MARK: Numbering

    /// The number in the warning is the number in the gutter, so a blank row
    /// in the middle must not shift it.
    func testWarningNumbersMatchTheRowsAsDrawn() {
        let blocking = StartupChain.blockingSteps(in: ["cd ~/project", "", "vim notes", "npm run dev"])
        XCTAssertEqual(blocking.first?.number, 3)
    }

    /// A blank row after the blocking step is not a step waiting on it.
    func testTrailingBlankRowsDoNotMakeALastStepBlocking() {
        XCTAssertTrue(StartupChain.blockingSteps(in: ["cd ~/project", "tmux attach", "", "  "]).isEmpty)
    }

    func testEmptyAndSingleRowChainsNeverWarn() {
        XCTAssertTrue(StartupChain.blockingSteps(in: []).isEmpty)
        XCTAssertTrue(StartupChain.blockingSteps(in: [""]).isEmpty)
        XCTAssertTrue(StartupChain.blockingSteps(in: ["tmuxon"]).isEmpty)
    }

    func testEveryOffenderIsReportedNotJustTheFirst() {
        let blocking = StartupChain.blockingSteps(in: ["vim a", "htop", "echo done"])
        XCTAssertEqual(blocking.map(\.number), [1, 2])
        XCTAssertEqual(blocking.map(\.program), ["vim", "htop"])
    }
}
