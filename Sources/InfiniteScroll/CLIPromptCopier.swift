import AppKit
import Foundation

enum CLIPromptCopier {
    static func copyToPasteboard() {
        guard let url = Bundle.main.url(forResource: "cli-prompt", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            NSLog("[CLIPromptCopier] cli-prompt.md not found in bundle")
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
