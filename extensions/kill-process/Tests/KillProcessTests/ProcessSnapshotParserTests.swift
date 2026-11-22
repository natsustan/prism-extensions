import Foundation
import Testing
@testable import KillProcess

@Suite("ProcessSnapshotParser")
struct ProcessSnapshotParserTests {
    @Test("parses macOS ps lines including spaces, Cryptex paths, relative comms, and comma decimals")
    func parsesOutput() {
        let sample = """
            1     0     0 Ss     0.1  25312 /sbin/launchd
          456     1    88 Ss     8.8 261120 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
        59193     1   501 S    177.4 224256 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/130/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)
          731     1   501 S      0,5 305152 /System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari
        60760   400   501 S      9.4 284672 agy
        61000   400   501 S+     0.0   4096 -zsh
        70001   400   501 Z      0.0      0 (defunct)
        70002   400   501 Z+     0.0      0 <defunct>
            0     0     0 Ss     0.0      0 kernel_task
        malformed line without numbers
        """

        let rows = ProcessSnapshotParser.parse(sample)
        #expect(rows.count == 6)

        #expect(rows[0] == ParsedPSRow(
            pid: 1, parentPID: 0, userID: 0, stat: "Ss",
            cpu: 0.1, memoryBytes: 25312 * 1024, comm: "/sbin/launchd"
        ))
        #expect(rows[2].pid == 59193)
        #expect(rows[2].cpu == 177.4)
        #expect(rows[2].comm == "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/130/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)")
        #expect(rows[3].cpu == 0.5)
        #expect(rows[3].comm == "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari")
        #expect(rows[4].comm == "agy")
        #expect(rows[5].comm == "-zsh")
    }
}
