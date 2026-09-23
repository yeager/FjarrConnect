import AppKit

enum AboutPanel {
    static let repositoryURL = URL(string: "https://github.com/yeager/FjarrConnect")!

    static func credits(bundle: Bundle = .main) -> NSAttributedString {
        let author = bundle.localizedString(forKey: "about.author", value: nil, table: nil)
        let repository = bundle.localizedString(forKey: "about.repository", value: nil, table: nil)
        let result = NSMutableAttributedString(string: author + "\n\n" + repository)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        result.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: 0, length: result.length)
        )
        let range = NSRange(location: author.utf16.count + 2, length: repository.utf16.count)
        result.addAttribute(.link, value: repositoryURL, range: range)
        return result
    }

    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits()])
        NSApp.activate(ignoringOtherApps: true)
    }

    static func openRepository() {
        NSWorkspace.shared.open(repositoryURL)
    }
}
