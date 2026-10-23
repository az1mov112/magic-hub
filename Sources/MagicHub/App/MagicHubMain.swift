import AppKit

@main
enum MagicHubMain {
    static func main() {
        // Режим помощника: тот же исполняемый файл, запущенный от root через sudo,
        // пишет в SMC (вентиляторы). Обычный запуск приложения сюда не попадает.
        let args = CommandLine.arguments
        if args.count > 1, args[1] == "--smc" {
            exit(SMCHelperCLI.run(Array(args.dropFirst(2))))
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
